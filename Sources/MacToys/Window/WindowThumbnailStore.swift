// SPDX-License-Identifier: MIT

import AppKit
import ScreenCaptureKit
import VideoToolbox

/// 周期任务静默预热共享池；消费方只在缺图时请求一次，展示期间不订阅刷新。
final class WindowThumbnailStore {
    static let shared = WindowThumbnailStore()
    static let interval: TimeInterval = 2

    struct Key: Hashable {
        let pid: pid_t
        let windowID: CGWindowID
    }

    struct Window: Equatable {
        let key: Key
        let title: String
        let size: CGSize
    }

    typealias Enumerate = @MainActor () async throws -> [Window]
    typealias Capture = @MainActor (Window) async throws -> NSImage?
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)

    private let enumerate: Enumerate
    private let backend: PeriodicWindowCapture
    private let capture: Capture
    private let allowed: () -> Bool
    private let schedule: Schedule
    private let images: ImageCache<Key>
    private struct CaptureJob {
        let id = UUID()
        let window: Window
        let revision: Int
        var invalidated = false
        var urgent: Bool
        var completions: [(NSImage?) -> Void]
        var task: Task<Void, Never>?
    }
    private var active: [Key: CaptureJob] = [:]
    private var pending: [CaptureJob] = []
    private var catalogTask: (id: UUID, revision: Int, task: Task<[Window], Error>)?
    private var refreshes: [Key: UUID] = [:]
    private(set) var completedRounds = 0
    private var cancelTick: (() -> Void)?
    private var round: Task<Void, Never>?
    private var revision = 0
    private var cadenceRevision = 0
    private var pressure: DispatchSourceMemoryPressure?
    private(set) var windows: [Window] = []
    private(set) var enabled = false
    private(set) var hasCompletedRound = false
    var recordingAllowed: Bool { allowed() }

    init(enumerate: Enumerate? = nil, capture: Capture? = nil,
         allowed: @escaping () -> Bool = { Permissions.screenRecording },
         schedule: @escaping Schedule = WindowThumbnailStore.after,
         observeMemoryPressure: Bool = true) {
        let backend = PeriodicWindowCapture()
        self.backend = backend
        self.enumerate = enumerate ?? { try await backend.windows() }
        self.capture = capture ?? { try await backend.capture($0) }
        self.allowed = allowed
        self.schedule = schedule
        images = ImageCache(countLimit: 60, byteLimit: 32 << 20, observeMemoryPressure: false)
        if observeMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in self?.releaseCachedImages() }
            source.resume()
            pressure = source
        }
    }

    /// 原位置预览借用周期枚举得到的 SCWindow 与截图门限，不新增窗口列表轮询或缓存。
    @MainActor func peekSnapshot(pid: pid_t, windowID: CGWindowID) async -> DockWindowPeekSnapshot? {
        guard enabled, allowed(), !Task.isCancelled else { return nil }
        let ticket = revision
        let snapshot = try? await backend.peekSnapshot(key: .init(pid: pid, windowID: windowID))
        guard enabled, allowed(), revision == ticket, !Task.isCancelled else { return nil }
        return snapshot
    }

    func apply(enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        cadenceRevision += 1
        revision += 1
        cancelTick?()
        cancelTick = nil
        if enabled {
            beginRound()
            arm(cadenceRevision)
        } else {
            // 取消本地等待，重新启用仍须等本轮清理后才能开始，避免周期重叠。
            round?.cancel()
            windows = []
            releaseCachedImages()
        }
    }

    /// 命中直接返回；缺图立即加入优先队列，与周期任务合并同一窗口的请求。
    /// 无编号时只接受同应用唯一同名窗口，不能根据标题猜另一个窗口。
    @MainActor func requestImage(pid: pid_t, windowID: CGWindowID?, title: String = "") async -> NSImage? {
        guard enabled, allowed(), !Task.isCancelled else { return nil }
        if let image = image(pid: pid, windowID: windowID, title: title) { return image }
        let ticket = revision
        var target = matchingWindow(pid: pid, windowID: windowID, title: title)
        if target == nil {
            do { _ = try await loadCatalog() }
            catch { return nil }
            guard enabled, revision == ticket, allowed(), !Task.isCancelled else { return nil }
            if let image = image(pid: pid, windowID: windowID, title: title) { return image }
            target = matchingWindow(pid: pid, windowID: windowID, title: title)
        }
        guard let target else { return nil }
        let result = await captureImage(target, urgent: true)
        guard enabled, revision == ticket, allowed(), !Task.isCancelled else { return nil }
        return result
    }

    /// 尺寸变化后跳过旧图，重新枚举以取得新的 SCWindow 和尺寸；旧图保留至成功替换。
    @MainActor func refreshImage(pid: pid_t, windowID: CGWindowID?, title: String = "") async -> NSImage? {
        guard enabled, allowed(), !Task.isCancelled else { return nil }
        guard let key = windowID.map({ Key(pid: pid, windowID: $0) })
                ?? matchingWindow(pid: pid, windowID: nil, title: title)?.key else { return nil }
        let token = UUID(), ticket = revision
        refreshes[key] = token
        defer { if refreshes[key] == token { refreshes[key] = nil } }
        invalidateCapture(key)
        // 事件发生前的系统枚举不能用作新尺寸的快照，也不与其并发枚举。
        if let previous = catalogTask {
            _ = try? await previous.task.value
            if catalogTask?.id == previous.id { catalogTask = nil }
        }
        guard enabled, revision == ticket, refreshes[key] == token, !Task.isCancelled else { return nil }
        do { _ = try await loadCatalog() }
        catch { return nil }
        guard enabled, revision == ticket, refreshes[key] == token, !Task.isCancelled,
              let target = matchingWindow(pid: key.pid, windowID: key.windowID, title: title) else { return nil }
        // 等待枚举期间周期任务可能再次启动旧快照的截图，不能复用它。
        invalidateCapture(key)
        let image = await withTaskCancellationHandler {
            await captureImage(target, urgent: true)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.refreshes[key] == token else { return }
                self.invalidateCapture(key)
            }
        }
        guard enabled, revision == ticket, refreshes[key] == token, !Task.isCancelled else { return nil }
        return image
    }

    private func invalidateCapture(_ key: Key) {
        active[key]?.invalidated = true
        let discarded = pending.filter { $0.window.key == key }
        pending.removeAll { $0.window.key == key }
        discarded.forEach { job in job.completions.forEach { $0(nil) } }
    }

    private func matchingWindow(pid: pid_t, windowID: CGWindowID?, title: String) -> Window? {
        if let windowID { return windows.first { $0.key == Key(pid: pid, windowID: windowID) } }
        guard !title.isEmpty else { return nil }
        let matches = windows.filter { $0.key.pid == pid && $0.title == title }
        return matches.count == 1 ? matches[0] : nil
    }

    func image(pid: pid_t, windowID: CGWindowID?, title: String = "") -> NSImage? {
        if let windowID { return images[Key(pid: pid, windowID: windowID)] }
        // 最小化窗口偶尔缺少 AX 编号，仅接受同 App 唯一同名窗口。
        guard !title.isEmpty else { return nil }
        let matches = windows.filter { $0.key.pid == pid && $0.title == title }
        return matches.count == 1 ? images[matches[0].key] : nil
    }

    func releaseCachedImages() {
        revision += 1
        refreshes = [:]
        round?.cancel()
        catalogTask?.task.cancel()
        for job in active.values { job.task?.cancel() }
        let discarded = pending
        pending = []
        for job in discarded { job.completions.forEach { $0(nil) } }
        images.removeAll()
        hasCompletedRound = false
        // 清池不影响两个面板已经持有的图片，也不改变固定刷新节奏。
    }

    private func arm(_ ticket: Int) {
        cancelTick = schedule(Self.interval) { [weak self] in
            guard let self, self.enabled, self.cadenceRevision == ticket else { return }
            self.cancelTick = nil
            self.beginRound()
            self.arm(ticket)
        }
    }

    private func beginRound() {
        guard enabled else { return }
        guard allowed() else {
            round?.cancel()
            windows = []
            releaseCachedImages()
            return
        }
        guard round == nil else { return }
        let ticket = revision
        round = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.round = nil }
            do {
                let catalog = try await self.loadCatalog()
                try Task.checkCancellation()
                guard self.enabled, self.revision == ticket, self.allowed() else { return }
                var iterator = catalog.makeIterator()
                await withTaskGroup(of: (Key, NSImage?).self) { group in
                    func add(_ window: Window) {
                        group.addTask { @MainActor in
                            guard !Task.isCancelled else { return (window.key, nil) }
                            return (window.key, await self.captureImage(window, urgent: false))
                        }
                    }
                    for _ in 0..<2 {
                        if let window = iterator.next() { add(window) }
                    }
                    while await group.next() != nil {
                        guard !Task.isCancelled, self.enabled, self.revision == ticket, self.allowed() else {
                            group.cancelAll()
                            continue
                        }
                        if let window = iterator.next() { add(window) }
                    }
                }
                try Task.checkCancellation()
                guard self.enabled, self.revision == ticket, self.allowed() else { return }
                self.hasCompletedRound = true
                self.completedRounds += 1
            } catch is CancellationError {
                // 关闭功能或内存压力取消本轮，不发布过期结果。
            } catch WindowCaptureRequestError.busy {
                // 上次系统枚举尚未返回，本轮保留缓存，不继续堆积请求或日志。
            } catch {
                Log.thumbnails.error("Window enumeration failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 周期枚举与新窗口缺图查询共用在途任务，避免重复枚举和 backend busy。
    @MainActor private func loadCatalog() async throws -> [Window] {
        let entry: (id: UUID, revision: Int, task: Task<[Window], Error>)
        if let current = catalogTask, current.revision == revision, !current.task.isCancelled {
            entry = current
        } else {
            let enumerate = self.enumerate
            entry = (UUID(), revision, Task { @MainActor in try await enumerate() })
            catalogTask = entry
        }
        defer { if catalogTask?.id == entry.id { catalogTask = nil } }
        let catalog = try await entry.task.value
        guard enabled, revision == entry.revision, allowed() else { throw CancellationError() }
        var seen = Set<Key>()
        windows = catalog.filter { seen.insert($0.key).inserted }
        let keys = Set(windows.map(\.key))
        images.remove(where: { !keys.contains($0) })
        return windows
    }

    @MainActor private func captureImage(_ window: Window, urgent: Bool) async -> NSImage? {
        guard enabled, allowed(), !Task.isCancelled, windows.contains(window) else { return nil }
        return await withCheckedContinuation { continuation in
            let finish: (NSImage?) -> Void = { continuation.resume(returning: $0) }
            if var job = active[window.key], job.revision == revision, !job.invalidated,
               job.window == window, job.task?.isCancelled == false {
                job.completions.append(finish)
                active[window.key] = job
            } else if let index = pending.firstIndex(where: { $0.window == window && $0.revision == revision }) {
                pending[index].urgent = pending[index].urgent || urgent
                pending[index].completions.append(finish)
            } else {
                pending.append(CaptureJob(window: window, revision: revision, urgent: urgent, completions: [finish]))
            }
            drainCaptures()
        }
    }

    @MainActor private func drainCaptures() {
        while active.count < 2 {
            // 同一编号的旧代任务退出前不能启动新代任务，避免超出底层上限。
            guard let index = pending.indices.filter({ active[pending[$0].window.key] == nil })
                .min(by: { pending[$0].urgent && !pending[$1].urgent }) else { return }
            var job = pending.remove(at: index)
            let capture = self.capture
            let id = job.id
            let window = job.window
            job.task = Task { @MainActor [weak self] in
                var result: NSImage?
                do { result = try await capture(window) }
                catch is CancellationError {}
                catch WindowCaptureRequestError.busy {}
                catch {
                    Log.thumbnails.error("Capture failed pid=\(window.key.pid) window=\(window.key.windowID): \(String(describing: error), privacy: .public)")
                }
                guard let self, let finished = self.active[window.key], finished.id == id else { return }
                self.active[window.key] = nil
                let valid = self.enabled && self.revision == finished.revision && !finished.invalidated
                    && self.windows.contains(window) && self.allowed() && !Task.isCancelled
                let image = valid ? result : nil
                if let image { self.images[window.key] = image }
                finished.completions.forEach { $0(image) }
                self.drainCaptures()
            }
            active[window.key] = job
        }
    }

    static func after(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }

    /// 系统截图可能返回完整 Retina 位图，缓存前必须限制实际像素成本。
    static func cardImage(from source: CGImage, size: CGSize) -> NSImage? {
        let scale = min(1, min(480 / CGFloat(source.width), 320 / CGFloat(source.height)))
        let width = max(1, Int(CGFloat(source.width) * scale))
        let height = max(1, Int(CGFloat(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = size
        let card = NSImage(size: size)
        card.addRepresentation(bitmap)
        return card
    }

    deinit {
        cancelTick?()
        round?.cancel()
        catalogTask?.task.cancel()
        for job in active.values { job.task?.cancel() }
        pressure?.cancel()
    }
}

/// 一次展示的图片快照：同步取池中最新图，缺图只补一次；池更新不替换已取到的图。
final class WindowThumbnailPresentation<ID: Hashable> {
    struct Request {
        let id: ID
        let pid: pid_t
        let windowID: CGWindowID?
        let title: String
    }

    private let store: WindowThumbnailStore
    private var revision = 0
    private var tasks: [ID: Task<Void, Never>] = [:]
    private var attempted: Set<ID> = []
    private(set) var images: [ID: NSImage] = [:]
    var onImage: (ID, NSImage) -> Void = { _, _ in }
    var onSettled: () -> Void = {}
    var isLoading: Bool { !tasks.isEmpty }

    init(store: WindowThumbnailStore) { self.store = store }

    func reset() {
        revision += 1
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        attempted = []
        images = [:]
    }

    /// 保留当前画面；取消旧的缺图请求，显式刷新成功后再替换。
    func prepareRefresh(_ id: ID) {
        tasks.removeValue(forKey: id)?.cancel()
        attempted.insert(id)
    }

    func replaceImage(_ image: NSImage, for id: ID) {
        prepareRefresh(id)
        images[id] = image
        onImage(id, image)
    }

    func load(_ requests: [Request]) {
        let ids = Set(requests.map(\.id))
        for id in Array(tasks.keys) where !ids.contains(id) {
            tasks.removeValue(forKey: id)?.cancel()
        }
        images = images.filter { ids.contains($0.key) }
        attempted.formIntersection(ids)
        for request in requests where images[request.id] == nil && !attempted.contains(request.id) {
            attempted.insert(request.id)
            if let image = store.image(pid: request.pid, windowID: request.windowID, title: request.title) {
                images[request.id] = image
                continue
            }
            let ticket = revision
            let store = self.store
            tasks[request.id] = Task { @MainActor [weak self] in
                let image = await store.requestImage(pid: request.pid, windowID: request.windowID, title: request.title)
                guard let self, !Task.isCancelled, self.revision == ticket else { return }
                self.tasks[request.id] = nil
                if let image {
                    self.images[request.id] = image
                    self.onImage(request.id, image)
                }
                if self.tasks.isEmpty { self.onSettled() }
            }
        }
    }

    deinit { tasks.values.forEach { $0.cancel() } }
}

/// 周期预热与缺图请求共用系统窗口列表、截图并发限制和后台位图转换。
private final class PeriodicWindowCapture {
    private var available: [WindowThumbnailStore.Key: SCWindow] = [:]
    private let enumerations = WindowCaptureGate(limit: 1)
    private let captures = WindowCaptureGate(limit: 2)
    private let peekCaptures = WindowCaptureGate(limit: 1)
    private let conversionQueue = DispatchQueue(label: "MacToys.ThumbnailConversion", qos: .utility,
                                                 autoreleaseFrequency: .workItem)

    @MainActor func peekSnapshot(key: WindowThumbnailStore.Key) async throws -> DockWindowPeekSnapshot? {
        guard let window = available[key], let frame = Self.visibleFrame(for: key) else { return nil }
        let appKitFrame = ScreenGeometry.appKitRect(frame)
        guard let screen = NSScreen.screens.max(by: {
            Self.overlap($0.frame, appKitFrame) < Self.overlap($1.frame, appKitFrame)
        }), screen.frame.intersects(appKitFrame) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // 使用窗口实际像素倍率；跨 Retina/普通屏时也不能先降采样再放大。
        let scale = max(CGFloat(filter.pointPixelScale), screen.backingScaleFactor)
        let pixels = DockWindowPeekSnapshot.pixelSize(for: frame.size, scale: scale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        // 高清截图最多一个在途；繁忙时可取消地等待，不放大低清缩略图冒充原图。
        let image: CGImage = try await peekCaptures.value(timeout: 2, waitForSlot: true) { finish in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                Task { @MainActor in
                    if let error { finish(.failure(error)) }
                    else if let image { finish(.success(image)) }
                    else { finish(.failure(WindowCaptureRequestError.missingContent)) }
                }
            }
        }
        try Task.checkCancellation()
        guard image.width >= configuration.width, image.height >= configuration.height,
              let latest = Self.visibleFrame(for: key), latest.size == frame.size else { return nil }
        return DockWindowPeekSnapshot(image: NSImage(cgImage: image, size: latest.size), frame: latest)
    }

    private static func overlap(_ screen: CGRect, _ window: CGRect) -> CGFloat {
        let intersection = screen.intersection(window)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    /// 只展示当前桌面真实可见的窗口；最小化或其他 Space 的窗口仍保留原缩略图功能。
    private static func visibleFrame(for key: WindowThumbnailStore.Key) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], key.windowID)
                as? [[String: Any]])?.first,
              info[kCGWindowNumber as String] as? CGWindowID == key.windowID,
              info[kCGWindowOwnerPID as String] as? pid_t == key.pid,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              info[kCGWindowLayer as String] as? Int == 0,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds),
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width >= 60, frame.height >= 40 else { return nil }
        return frame
    }

    @MainActor func windows() async throws -> [WindowThumbnailStore.Window] {
        let content: SCShareableContent = try await enumerations.value(timeout: 3) { finish in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
                Task { @MainActor in
                    if let error { finish(.failure(error)) }
                    else if let content { finish(.success(content)) }
                    else { finish(.failure(WindowCaptureRequestError.missingContent)) }
                }
            }
        }
        try Task.checkCancellation()
        let apps = Set(NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid()
        }.map(\.processIdentifier))
        let selected = content.windows.filter {
            $0.windowLayer == 0 && apps.contains($0.owningApplication?.processID ?? 0)
                && $0.frame.width >= 60 && $0.frame.height >= 40
        }
        available = Dictionary(selected.map {
            (WindowThumbnailStore.Key(pid: $0.owningApplication!.processID, windowID: $0.windowID), $0)
        }, uniquingKeysWith: { first, _ in first })
        return selected.map {
            .init(key: .init(pid: $0.owningApplication!.processID, windowID: $0.windowID),
                  title: $0.title ?? "", size: $0.frame.size)
        }
    }

    @MainActor func capture(_ target: WindowThumbnailStore.Window) async throws -> NSImage? {
        guard let window = available[target.key] else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = min(480 / max(target.size.width, 1), 320 / max(target.size.height, 1))
        configuration.width = max(1, Int(target.size.width * scale))
        configuration.height = max(1, Int(target.size.height * scale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let sample: CMSampleBuffer = try await captures.value(timeout: 1) { finish in
            SCScreenshotManager.captureSampleBuffer(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) { sample, error in
                Task { @MainActor in
                    if let error { finish(.failure(error)) }
                    else if let sample { finish(.success(sample)) }
                    else { finish(.failure(WindowCaptureRequestError.missingContent)) }
                }
            }
        }
        try Task.checkCancellation()
        guard sample.isValid, let buffer = sample.imageBuffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int,
           status != SCFrameStatus.complete.rawValue && status != SCFrameStatus.started.rawValue { return nil }
        // VT 创建的 CGImage 可能到 CGContext.draw 时才转换像素，两步都放到后台。
        let card: NSImage? = await withCheckedContinuation { continuation in
            conversionQueue.async(execute: DispatchWorkItem {
                let image: NSImage? = autoreleasepool {
                    var source: CGImage?
                    guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &source) == noErr,
                          let source else { return nil }
                    return WindowThumbnailStore.cardImage(from: source, size: target.size)
                }
                continuation.resume(returning: image)
            })
        }
        try Task.checkCancellation()
        return card
    }
}

enum WindowCaptureRequestError: Error {
    case timedOut
    case missingContent
    case busy
}

/// 超时/取消只结束本地等待；系统回调真正返回前仍占用名额，避免每轮堆积底层请求。
@MainActor
final class WindowCaptureGate {
    private let limit: Int
    private var active = Set<UUID>()

    nonisolated init(limit: Int) { self.limit = limit }

    private var waiting: [(id: UUID, start: () -> Void)] = []

    func value<Value>(timeout: TimeInterval,
                      waitForSlot: Bool = false,
                      schedule: @escaping WindowThumbnailStore.Schedule = WindowThumbnailStore.after,
                      start: @escaping (@escaping (Result<Value, Error>) -> Void) throws -> Void) async throws -> Value {
        try Task.checkCancellation()
        guard waitForSlot || active.count < limit else { throw WindowCaptureRequestError.busy }
        let token = UUID()
        let request = WindowCaptureRequest<Value>(timeout: timeout, schedule: schedule)
        return try await request.value { finish in
            self.waiting.append((token, { [self] in
                active.insert(token)
                do {
                    try start { [self] result in
                        guard active.remove(token) != nil else { return }
                        finish(result)
                        drain()
                    }
                } catch {
                    active.remove(token)
                    finish(.failure(error))
                    drain()
                }
            }))
            self.drain()
        } cleanup: {
            self.waiting.removeAll { $0.id == token }
        }
    }

    private func drain() {
        while active.count < limit, !waiting.isEmpty {
            waiting.removeFirst().start()
        }
    }
}

/// 回调、超时和取消只能完成一次；迟到的系统回调不能阻塞或覆盖下一轮。
@MainActor
final class WindowCaptureRequest<Value> {
    private let timeout: TimeInterval
    private let schedule: WindowThumbnailStore.Schedule
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelTimeout: (() -> Void)?
    private var cleanup: (() -> Void)?

    init(timeout: TimeInterval, schedule: @escaping WindowThumbnailStore.Schedule = WindowThumbnailStore.after) {
        self.timeout = timeout
        self.schedule = schedule
    }

    func value(start: (@escaping (Result<Value, Error>) -> Void) throws -> Void,
               cleanup: @escaping () -> Void = {}) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.cleanup = cleanup
                cancelTimeout = schedule(timeout) { [weak self] in
                    self?.finish(.failure(WindowCaptureRequestError.timedOut))
                }
                do {
                    try start { [weak self] in self?.finish($0) }
                } catch {
                    finish(.failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        cancelTimeout?()
        cancelTimeout = nil
        let cleanup = self.cleanup
        self.cleanup = nil
        cleanup?()
        continuation.resume(with: result)
    }
}

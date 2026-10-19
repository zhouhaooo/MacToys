// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// Dock 的识别和窗口查询在后台运行；UI 在主线程读取共享周期缩略图。
final class DockPreviewController {
    let clicks = DockClickInterceptor()
    private var singleWindowToggle = false
    private let model = DockPreviewModel()
    private var previewPanel: DockPreviewPanel?
    private var windowPeek: DockWindowPeekController?
    private var windowPeekEnabled = true
    private var peekBorderWidth: Double = 5
    private var peekCornerRadius: Double = 10
    private var panel: DockPreviewPanel {
        if let previewPanel { return previewPanel }
        let panel = DockPreviewPanel(model: model)
        previewPanel = panel
        return panel
    }
    private let resolverQueue = DispatchQueue(label: "MacToys.DockPreview", qos: .userInitiated)
    private let predictionQueue = DispatchQueue(label: "MacToys.DockPrediction", qos: .utility)
    private let catalog = DockPreviewCatalog()
    private let windowObserver = DockWindowObserver()
    private var resizeTokens: [AXUIElement: UUID] = [:]
    private var resizeWakeups: [AXUIElement: DispatchWorkItem] = [:]
    private var resizeTasks: [AXUIElement: Task<Void, Never>] = [:]
    private var enabled = false
    private var hoverWakeup: DispatchWorkItem?
    private var dockRevealRetry: DispatchWorkItem?
    private var revealDeadline: TimeInterval = 0
    private var resolvedPoint: CGPoint?
    private var resolvedHit: DockAppHit?
    private var dockFrame: CGRect?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private let thumbnailPresentation = WindowThumbnailPresentation<AXUIElement>(store: .shared)
    private var monitor: Any?
    private var localMonitor: Any?
    private var hover = DockHoverState()
    private var prediction = DockPointerPrediction()
    private var predictedPoint: CGPoint?
    private var predicting = false
    private var nextPredictionAt: TimeInterval = 0
    private var placement = DockPreviewPlacement()
    private var currentHit: DockAppHit?
    private var pendingHit: DockAppHit?
    private var resolving = false
    private var nextResolutionAt: TimeInterval = 0
    private var pointerUpdate: DispatchWorkItem?
    private var revision = 0
    private var dismissal = 0
    private var suppressUntil: TimeInterval = 0
    private var suppressionWakeup: DispatchWorkItem?
    private var previewAnimation = DockPreviewAnimation.materialize
    private var showEmptyApps = true
    private var excludedApps: Set<String> = []

    init() {
        thumbnailPresentation.onImage = { [weak self] id, image in
            guard let self, let hit = self.currentHit, self.model.windows.contains(where: { $0.id == id }) else { return }
            let screen = (NSScreen.screens.first { $0.frame.intersects(hit.frame) } ?? NSScreen.main)?.visibleFrame ?? .zero
            let previousSize = self.model.size(screen: screen)
            self.model.thumbnails[id] = image
            if self.model.size(screen: screen) != previousSize { self.reposition(hit, animated: true) }
        }
        model.onChoose = { [weak self] in self?.choose($0) }
        model.onClose = { [weak self] in self?.perform(.close, preview: $0) }
        model.onMinimize = { [weak self] in self?.perform(.minimize, preview: $0) }
        clicks.onClick = { [weak self] hit, point, down, up in
            self?.clickDock(hit, point: point, down: down, up: up)
        }
        model.onOpenApp = { [weak self] in self?.openApp() }
        model.hoverState.onChange = { [weak self] id in
            guard let self else { return }
            guard let id, self.windowPeekEnabled, self.model.visible, self.model.recordingAllowed,
                  let preview = self.model.windows.first(where: { $0.id == id }),
                  let windowID = preview.windowID else {
                self.windowPeek?.hide()
                return
            }
            if self.windowPeek == nil { self.windowPeek = DockWindowPeekController() }
            self.windowPeek?.apply(borderWidth: self.peekBorderWidth, cornerRadius: self.peekCornerRadius)
            self.windowPeek?.hover(pid: preview.window.pid, windowID: windowID)
        }
        catalog.onLoad = { [weak self] pid, _ in self?.catalogLoaded(pid) }
        windowObserver.onDestroyed = { [weak self] pid, window in
            self?.windowDestroyed(pid: pid, window: window)
        }
        windowObserver.onResized = { [weak self] pid, window in
            self?.windowResized(pid: pid, window: window)
        }
    }

    func apply(config: DockConfig) {
        windowPeekEnabled = config.dockWindowPeek
        peekBorderWidth = config.dockPeekBorderWidth
        peekCornerRadius = config.dockPeekCornerRadius
        windowPeek?.apply(borderWidth: peekBorderWidth, cornerRadius: peekCornerRadius)
        if !windowPeekEnabled { windowPeek?.hide() }
        previewAnimation = config.dockPreviewAnimation
        model.showWindowButtons = config.dockWindowButtons
        model.middleClickClose = config.dockMiddleClickClose
        singleWindowToggle = config.dockSingleWindowToggle
        if !singleWindowToggle { clicks.target.set(nil) }
        let height = CGFloat(DockConfig.normalizedDockPreviewHeight(config.dockPreviewHeight))
        if model.previewHeight != height {
            withAnimation(Self.reduceMotion ? nil : AppAnimation.easeOut(duration: 0.18)) {
                model.previewHeight = height
                if let hit = currentHit { reposition(hit, animated: true) }
            }
        }
        if showEmptyApps != config.dockShowEmptyApps || excludedApps != Set(config.dockExcludedApps) {
            dismiss(animated: false)
            cancelResizeRefreshes()
            windowObserver.stop()
            catalog.reset()
        }
        showEmptyApps = config.dockShowEmptyApps
        excludedApps = Set(config.dockExcludedApps)
        updateClickTarget(resolvedHit)
        guard config.dockPreview, Permissions.accessibility else { stop(); return }
        guard !enabled else { return }
        enabled = true
        // 接近 Dock 时才预热面板，空闲启动不分配整屏玻璃宿主。
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .mouseMoved]) { [weak self] event in
            if event.type == .mouseMoved { self?.pointerMoved() }
            else { self?.dismiss(animated: true) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .mouseMoved]) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved { self.pointerMoved() }
            else {
                self.model.clearHover()
                if event.window !== self.previewPanel { self.dismiss(animated: true) }
            }
            return event
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if name == NSWorkspace.activeSpaceDidChangeNotification || name == NSWorkspace.didWakeNotification {
                    self.dismiss(animated: false)
                } else if name == NSWorkspace.didTerminateApplicationNotification,
                          let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    if self.currentHit?.pid == app.processIdentifier { self.dismiss(animated: true) }
                }
                self.clicks.target.set(nil)
                self.resolvedPoint = nil
                self.resolvedHit = nil
                self.dockFrame = nil
                self.catalog.reset()
                self.prediction.reset()
                self.predictedPoint = nil
                self.pointerMoved()
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.dismiss(animated: false)
            self?.cancelResizeRefreshes()
            self?.windowObserver.stop()
            self?.clicks.target.set(nil)
            self?.resolvedPoint = nil
            self?.resolvedHit = nil
            self?.dockFrame = nil
            self?.prediction.reset()
            self?.predictedPoint = nil
            self?.catalog.reset()
        }
        pointerMoved()
    }

    func stop() {
        cancelResizeRefreshes()
        windowObserver.stop()
        clicks.target.set(nil)
        enabled = false
        hoverWakeup?.cancel()
        hoverWakeup = nil
        dockRevealRetry?.cancel()
        dockRevealRetry = nil
        suppressionWakeup?.cancel()
        suppressionWakeup = nil
        resolvedPoint = nil
        resolvedHit = nil
        dockFrame = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        pointerUpdate?.cancel()
        pointerUpdate = nil
        nextResolutionAt = 0
        prediction.reset()
        predictedPoint = nil
        nextPredictionAt = 0
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
        dismiss(animated: false)
        catalog.reset()
    }

    private func pointerMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        predictedPoint = prediction.target(point: NSEvent.mouseLocation, now: now, screens: NSScreen.screens.map(\.frame))
        if let panel = previewPanel, !panel.surfaceFrame.contains(NSEvent.mouseLocation) {
            model.clearHover()
        }
        revealDeadline = now + 0.6
        tick()
    }

    /// 预测查询与真实命中分队列，慢预测不会挡住已经到达图标的指针。
    private func prefetchPredictedApp(now: TimeInterval) {
        guard !predicting, now >= nextPredictionAt, let point = predictedPoint else { return }
        predictedPoint = nil
        predicting = true
        nextPredictionAt = now + 0.08
        let ticket = revision
        predictionQueue.async { [weak self] in
            let hit = DockHitResolver.app(at: point)
            DispatchQueue.main.async {
                guard let self else { return }
                self.predicting = false
                guard self.enabled, ticket == self.revision, let hit,
                      hit.bundleID.map({ !self.excludedApps.contains($0) }) ?? true else { return }
                self.catalog.request(pid: hit.pid, name: hit.name, priority: .prediction)
                self.preparePanel(for: hit)
            }
        }
    }

    private func preparePanel(for hit: DockAppHit) {
        guard previewPanel?.isVisible != true else { return }
        let panel = self.panel
        panel.ignoresMouseEvents = true
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(hit.frame) }) {
            panel.prepareCanvas(screen: screen.frame)
        }
    }

    private func isPreviewPassage(_ point: CGPoint) -> Bool {
        guard model.visible, let hit = currentHit, let panel = previewPanel else { return false }
        return DockPreviewGeometry.isPassage(point: point, icon: hit.frame, surface: panel.surfaceFrame)
    }

    private func scheduleHoverWakeup() {
        hoverWakeup?.cancel()
        hoverWakeup = nil
        guard let deadline = hover.nextDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hoverWakeup = nil
            self?.tick()
        }
        hoverWakeup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    /// 自动隐藏的 Dock 尚未露出时，只在本次边缘移动后的短时间重试。
    private func retryDockReveal() {
        guard dockRevealRetry == nil, ProcessInfo.processInfo.systemUptime < revealDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.dockRevealRetry = nil
            self?.resolvedPoint = nil
            self?.tick()
        }
        dockRevealRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func tick() {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now < suppressUntil {
            if suppressionWakeup == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.suppressionWakeup = nil
                    self?.pointerMoved()
                }
                suppressionWakeup = work
                DispatchQueue.main.asyncAfter(deadline: .now() + suppressUntil - now, execute: work)
            }
            return
        }
        let point = NSEvent.mouseLocation
        if NSEvent.pressedMouseButtons != 0 {
            if model.visible, panel.surfaceFrame.contains(point) { return }
            dismiss(animated: true)
            suppressUntil = now + 0.35
            return
        }
        // 透明画布只用于动画，不阻挡 Dock 或后面的应用。
        if let panel = previewPanel { panel.ignoresMouseEvents = !model.visible || !panel.surfaceFrame.contains(point) }
        // 画面由共享周期缓存更新，命中查询继续由移动事件驱动。
        if currentHit != nil, panel.surfaceFrame.contains(point) || isPreviewPassage(point) {
            clicks.target.set(nil)
            pendingHit = currentHit
            _ = hover.shouldHide(inside: true, now: now)
            scheduleHoverWakeup()
            return
        }
        if let hit = currentHit {
            let inside = DockPreviewGeometry.acceptsResolvedHit(frame: hit.frame, pointer: point)
            // 已知 Dock 区域时，离开即开始退场；图标间隙仍保留一秒的接续时间。
            let onDock = dockFrame?.contains(point) ?? true
            if hover.trackPresence(inside: inside, onDock: onDock, now: now) { dismiss(animated: true) }
            scheduleHoverWakeup()
        }
        let nearDock = NSScreen.screens.contains { screen in
            let f = screen.frame
            return f.contains(point) && (point.y < f.minY + 220 || point.x < f.minX + 220 || point.x > f.maxX - 220)
        }
        guard nearDock else { clicks.target.set(nil); receive(nil, point: point, onDock: false); return }
        prefetchPredictedApp(now: now)
        if let hit = resolvedHit, resolvedPoint == point || hit.frame.insetBy(dx: 8, dy: 8).contains(point) {
            updateClickTarget(hit)
            receive(hit, point: point)
            return
        }
        guard !resolving else { return }
        // 合并高频鼠标事件，最多每帧查询一次；不设置常驻悬停轮询。
        let wait = nextResolutionAt - now
        if wait > 0 {
            guard pointerUpdate == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pointerUpdate = nil
                guard self.enabled else { return }
                self.tick()
            }
            pointerUpdate = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        pointerUpdate?.cancel()
        pointerUpdate = nil
        nextResolutionAt = now + 1.0 / 60
        resolving = true
        let ticket = revision
        resolverQueue.async { [weak self] in
            let resolution = DockHitResolver.resolve(at: point)
            let hit = resolution.app
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolving = false
                guard self.enabled else { return }
                // 旧浮窗到期关闭可能发生在这次查询期间；仍需处理指针当前停留的新 App。
                guard ticket == self.revision else { self.tick(); return }
                let latestPoint = NSEvent.mouseLocation
                self.updateClickTarget(hit)
                self.resolvedPoint = point
                self.resolvedHit = hit
                if let frame = resolution.dockFrame { self.dockFrame = frame }
                if hit == nil { self.retryDockReveal() }
                // 同一图标内移动仍接受结果；换图标则立即查当前位置，不等下一轮计时器。
                if let hit {
                    guard DockPreviewGeometry.acceptsResolvedHit(frame: hit.frame, pointer: latestPoint) else {
                        self.tick()
                        return
                    }
                    self.receive(hit, point: latestPoint)
                } else if latestPoint != point {
                    self.tick()
                } else {
                    self.receive(nil, point: latestPoint, onDock: resolution.dockFrame?.contains(latestPoint) ?? false)
                }
            }
        }
    }

    private func receive(_ hit: DockAppHit?, point: CGPoint, onDock: Bool = true) {
        defer { scheduleHoverWakeup() }
        let now = ProcessInfo.processInfo.systemUptime
        if let hit {
            if let id = hit.bundleID, excludedApps.contains(id) {
                // 不切换到排除 App，沿用离开 Dock 的延迟关闭时序。
                pendingHit = nil
                catalog.cancelPending()
                guard currentHit != nil else { hover.reset(); return }
                if hover.shouldHide(inside: false, now: now) { dismiss(animated: true) }
                return
            }
            pendingHit = hit
            if hit.pid == currentHit?.pid {
                _ = hover.shouldShow(pid: hit.pid, current: hit.pid, now: now)
                // Dock 放大产生的图标位置变化不移动预览；锚点保持初次悬停的位置。
                return
            }
            // 先启动后台查询，再并行准备画布；实际命中后不再等待悬停确认。
            catalog.request(pid: hit.pid, name: hit.name, priority: .hover)
            preparePanel(for: hit)
            // 首次画布布局期间鼠标仍可能跨过图标，不能立即显示已经过期的命中。
            guard DockPreviewGeometry.acceptsResolvedHit(frame: hit.frame, pointer: NSEvent.mouseLocation) else {
                tick()
                return
            }
            if hover.shouldShow(pid: hit.pid, current: currentHit?.pid, now: now) {
                if let windows = catalog.windows(for: hit.pid) { present(hit, windows: windows) }
                else if showEmptyApps { present(hit, windows: [], loading: hit.pid > 0) }
            }
        } else {
            pendingHit = nil
            catalog.cancelPending()
            guard currentHit != nil else { hover.reset(); return }
            let inside = currentHit.map { DockPreviewGeometry.acceptsResolvedHit(frame: $0.frame, pointer: point) } ?? false
            if hover.shouldHide(inside: inside, onDock: onDock, now: now) { dismiss(animated: true) }
        }
    }

    private func catalogLoaded(_ pid: pid_t) {
        guard enabled else { return }
        let point = NSEvent.mouseLocation
        if let hit = currentHit, hit.pid == pid, pendingHit?.pid == pid,
           (DockPreviewGeometry.acceptsResolvedHit(frame: hit.frame, pointer: point)
            || panel.surfaceFrame.contains(point) || isPreviewPassage(point)),
           let windows = catalog.windows(for: pid) {
            present(hit, windows: windows)
        } else if let hit = pendingHit, hit.pid == pid,
           DockPreviewGeometry.acceptsResolvedHit(frame: hit.frame, pointer: point) {
            // 仅当前实际命中的应用可以显示；预测结果本身不会弹出面板。
            receive(hit, point: point)
        }
    }

    static func windows(of pid: pid_t, appName: String) -> [DockWindowPreview] {
        guard pid != getpid() else { return [] }
        let serverWindows = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
        let snapshots = WindowElement.windows(of: pid).map { window in
            DockWindowCatalog.Snapshot(window: window, windowID: window.windowID, title: window.title,
                                       size: window.size, isStandard: window.isStandard, minimized: window.isMinimized)
        }
        return DockWindowCatalog.previews(snapshots, appName: appName, serverWindows: serverWindows)
    }

    private func windowDestroyed(pid: pid_t, window: AXUIElement) {
        resizeTokens[window] = nil
        resizeWakeups.removeValue(forKey: window)?.cancel()
        resizeTasks.removeValue(forKey: window)?.cancel()
        catalog.invalidate(pid: pid)
        guard let hit = currentHit, hit.pid == pid, model.visible,
              model.windows.contains(where: { $0.id == window }) else { return }
        let remaining = model.windows.filter { $0.id != window }
        present(hit, windows: remaining)
    }

    private func cancelResizeRefreshes() {
        resizeTokens = [:]
        resizeWakeups.values.forEach { $0.cancel() }
        resizeWakeups = [:]
        resizeTasks.values.forEach { $0.cancel() }
        resizeTasks = [:]
    }

    private func windowResized(pid: pid_t, window: AXUIElement) {
        if model.hoveredID == window { model.clearHover() }
        catalog.invalidate(pid: pid)
        thumbnailPresentation.prepareRefresh(window)
        resizeWakeups.removeValue(forKey: window)?.cancel()
        resizeTasks.removeValue(forKey: window)?.cancel()
        let token = UUID()
        resizeTokens[window] = token
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled, self.resizeTokens[window] == token else { return }
            self.resizeWakeups[window] = nil
            self.resizeTasks[window] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.resizeTokens[window] == token {
                        self.resizeTokens[window] = nil
                        self.resizeTasks[window] = nil
                    }
                }
                let preview: DockWindowPreview? = await withCheckedContinuation { continuation in
                    self.resolverQueue.async(execute: DispatchWorkItem {
                        let element = WindowElement(element: window, pid: pid)
                        guard let size = element.size, size.width >= 60, size.height >= 40 else {
                            continuation.resume(returning: nil)
                            return
                        }
                        continuation.resume(returning: DockWindowPreview(windowID: element.windowID, window: element,
                            title: element.title ?? "", size: size, minimized: element.isMinimized))
                    })
                }
                guard let preview, !Task.isCancelled, self.resizeTokens[window] == token else { return }
                if let hit = self.currentHit, hit.pid == pid, self.model.visible {
                    let windows = self.model.windows.map { $0.id == window ? preview : $0 }
                    self.present(hit, windows: windows)
                }
                let image = await WindowThumbnailStore.shared.refreshImage(pid: pid,
                    windowID: preview.windowID, title: preview.title)
                guard !Task.isCancelled, self.resizeTokens[window] == token else { return }
                if let image, self.currentHit?.pid == pid, self.model.visible,
                   self.model.windows.contains(where: { $0.id == window }) {
                    self.thumbnailPresentation.replaceImage(image, for: window)
                }
            }
        }
        resizeWakeups[window] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func present(_ hit: DockAppHit, windows: [DockWindowPreview], loading: Bool = false) {
        // 空 App 不主动弹出预览；已展示的应用关闭最后一个窗口时保留面板并显示空状态。
        if windows.isEmpty, !loading, !showEmptyApps, currentHit?.pid != hit.pid { return }
        if currentHit?.pid != hit.pid, currentHit != nil { cancelResizeRefreshes() }
        windowObserver.update(pid: hit.pid, windows: windows.map(\.id))
        hover.reset()
        let switching = currentHit?.pid != hit.pid
        let changedWindows = model.windows.map(\.id) != windows.map(\.id)
            || model.windows.map(\.size) != windows.map(\.size)
        let wasVisible = panel.isVisible
        if switching {
            model.clearHover()
        } else if let hoveredID = model.hoveredID, !windows.contains(where: { $0.id == hoveredID }) {
            model.clearHover()
        }
        if !switching, !changedWindows, model.visible {
            // 清单校验保留本次展示已经取得的图片，只对新增卡片补图。
            // 编号、标题和最小化状态也要刷新；它们的变化不一定改变卡片布局。
            model.windows = windows
            loadThumbnails(windows)
            model.recordingAllowed = Permissions.screenRecording
            withAnimation(Self.reduceMotion ? nil : AppAnimation.easeOut(duration: 0.25)) { model.loading = loading }
            return
        }
        if switching || !model.visible { thumbnailPresentation.reset() }
        dismissal += 1
        currentHit = hit
        let entering = !model.visible
        let updateContent = {
            self.model.clearHover()
            self.model.appName = hit.name
            self.model.appIcon = hit.icon
            self.model.windows = windows
            self.model.hoveredID = nil
            self.model.recordingAllowed = Permissions.screenRecording
            self.loadThumbnails(windows)
            self.model.pid = hit.pid
            self.model.loading = loading
        }
        if entering {
            // 隐藏时完成内容和定位，再按当前设置播放整块面板的进场动画。
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                updateContent()
                model.animation = previewAnimation
                model.visible = false
                model.presented = true
                reposition(hit, animated: false)
            }
            if model.animation == .fly && !Self.reduceMotion {
                if !wasVisible { panel.prepareFlight() }
            } else {
                panel.cancelFlight()
            }
            if !wasVisible {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
            panel.contentView?.layoutSubtreeIfNeeded()
        } else {
            withAnimation(Self.reduceMotion ? nil : AppAnimation.easeOut(duration: 0.25)) {
                updateContent()
                if switching || changedWindows { reposition(hit, animated: true) }
            }
        }
        let entryToken = dismissal
        let reveal = { [weak self] in
            guard let self, entryToken == self.dismissal, self.currentHit?.pid == hit.pid else { return }
            if self.model.animation == .fly && !Self.reduceMotion {
                self.model.visible = true
                self.panel.animateFlight(visible: true)
            } else {
                withAnimation(Self.reduceMotion ? nil : AppAnimation.easeOut(duration: DockPreviewPanel.entryDuration)) {
                    self.model.visible = true
                }
            }
            self.panel.alphaValue = 1
        }
        if entering && !Self.reduceMotion {
            DispatchQueue.main.async(execute: reveal)
        } else {
            reveal()
        }
    }

    private func reposition(_ hit: DockAppHit, animated: Bool) {
        let screen = NSScreen.screens.first { $0.frame.intersects(hit.frame) } ?? NSScreen.main
        guard let screen else { return }
        let size = model.size(screen: screen.visibleFrame)
        let surface = placement.surface(size: size, icon: hit.frame, screen: screen.frame,
                                        visibleFrame: screen.visibleFrame, edge: hit.edge)
        if animated && !Self.reduceMotion {
            // 位置立即开始追向新图标，内容仍按 0.25 秒完成模糊显现。
            withAnimation(AppAnimation.easeOut(duration: 0.25)) {
                panel.prepareSurface(surface, animated: true, screen: screen.frame)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                panel.prepareSurface(surface, animated: false, screen: screen.frame)
            }
        }
        panel.setFlightOrigin(icon: hit.frame, screen: screen.frame, edge: hit.edge)
    }

    private func loadThumbnails(_ windows: [DockWindowPreview]) {
        thumbnailPresentation.load(windows.map {
            .init(id: $0.id, pid: $0.window.pid, windowID: $0.windowID, title: $0.title)
        })
        let images = thumbnailPresentation.images
        // 缓存命中同步用于首帧；同一批次的清单回调不重复发布相同图片。
        if model.thumbnails.count != images.count || images.contains(where: { model.thumbnails[$0.key] !== $0.value }) {
            model.thumbnails = images
        }
    }

    private func updateClickTarget(_ hit: DockAppHit?) {
        guard singleWindowToggle, let hit, hit.pid > 0,
              hit.bundleID.map({ !excludedApps.contains($0) }) ?? true else {
            clicks.target.set(nil)
            return
        }
        clicks.target.set(.init(hit: hit, frame: ScreenGeometry.appKitRect(hit.frame)))
    }

    private func clickDock(_ hit: DockAppHit, point: CGPoint, down: CGEvent, up: CGEvent) {
        guard enabled, singleWindowToggle else { DockClickInterceptor.replay(down: down, up: up); return }
        dismiss(animated: true)
        suppressUntil = ProcessInfo.processInfo.systemUptime + 0.6
        let appKitPoint = ScreenGeometry.axPoint(point)
        resolverQueue.async { [weak self] in
            // 点击时重新命中、枚举窗口并读取最小化和激活状态，不能用悬停缓存决定动作。
            let actual = DockHitResolver.app(at: appKitPoint)
            let windows = actual?.pid == hit.pid ? WindowElement.windows(of: hit.pid).filter { $0.isStandard || $0.isMinimized } : []
            let window = windows.count == 1 ? windows[0] : nil
            let minimized: Bool? = window?.element.value(kAXMinimizedAttribute)
            let action = DockSingleWindowAction.resolve(windowCount: windows.count, minimized: minimized,
                                                       fullScreen: window?.isFullScreen ?? false,
                                                       active: NSRunningApplication(processIdentifier: hit.pid)?.isActive == true)
            guard let self, self.clicks.target.get()?.hit.pid == hit.pid, let action, let window else {
                DispatchQueue.main.async { DockClickInterceptor.replay(down: down, up: up) }
                return
            }
            // 自定义最小化的查询与写入留在同一串行队列。
            let result: AXError
            switch action {
            case .restore:
                // 恢复动画和应用激活由 Dock 协调，避免恢复期间再次抬高和聚焦窗口。
                DispatchQueue.main.async {
                    DockClickInterceptor.replay(down: down, up: up)
                    self.catalog.reset()
                }
                return
            case .minimize:
                result = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            case .activate:
                result = .success
            }
            DispatchQueue.main.async {
                guard result == .success else { DockClickInterceptor.replay(down: down, up: up); return }
                if action == .activate {
                    NSRunningApplication(processIdentifier: hit.pid)?.unhide()
                    window.focus()
                }
                self.catalog.reset()
            }
        }
    }

    private enum WindowAction { case close, minimize }

    private func perform(_ action: WindowAction, preview: DockWindowPreview) {
        guard model.visible, currentHit?.pid == preview.window.pid,
              model.windows.contains(where: { $0.id == preview.id }) else { return }
        if action == .minimize {
            dismiss(animated: true)
            suppressUntil = ProcessInfo.processInfo.systemUptime + 0.6
        }
        resolverQueue.async { [weak self] in
            if action == .close { preview.window.close() }
            else { preview.window.minimize() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.catalog.invalidate(pid: preview.window.pid)
                // 关闭按钮和中键共用此路径；保留面板，并兼容未发送销毁通知或取消关闭的应用。
                if action == .close, let hit = self.currentHit, hit.pid == preview.window.pid, self.model.visible {
                    self.catalog.request(pid: hit.pid, name: hit.name, priority: .hover, refresh: true)
                }
            }
        }
    }

    private func choose(_ preview: DockWindowPreview) {
        dismiss(animated: true)
        suppressUntil = ProcessInfo.processInfo.systemUptime + 0.6
        let window = preview.window
        let pid = window.pid
        NSRunningApplication(processIdentifier: pid)?.unhide()
        if preview.minimized || window.isMinimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        window.focus()
        // 部分应用激活时会先恢复其原窗口，再次抬起所选窗口保证准确切换。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { window.focus() }
    }

    private func openApp() {
        guard let hit = currentHit else { return }
        dismiss(animated: true)
        suppressUntil = ProcessInfo.processInfo.systemUptime + 0.6
        NSWorkspace.shared.openApplication(at: hit.url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func dismiss(animated: Bool) {
        windowPeek?.hide()
        model.clearHover()
        thumbnailPresentation.reset()
        hoverWakeup?.cancel()
        hoverWakeup = nil
        hover.reset()
        placement.reset()
        pendingHit = nil
        predictedPoint = nil
        catalog.cancelPending()
        // 查询是否在途不代表面板还在显示；重复关闭不能打断同一次退场或使完成回调失效。
        guard currentHit != nil || model.visible else {
            if !animated {
                revision += 1
                dismissal += 1
                model.visible = false
                model.presented = false
                previewPanel?.orderOut(nil)
                previewPanel?.cancelFlight()
                model.releaseContent()
            }
            return
        }
        revision += 1
        currentHit = nil
        hover.reset()
        dismissal += 1
        let token = dismissal
        guard let panel = previewPanel, panel.isVisible else { model.releaseContent(); return }
        if animated && !Self.reduceMotion && model.animation == .fly {
            model.visible = false
            panel.animateFlight(visible: false) { [weak self] in
                guard let self, token == self.dismissal else { return }
                self.model.presented = false
                panel.orderOut(nil)
                panel.cancelFlight()
                self.model.releaseContent()
            }
        } else if animated && !Self.reduceMotion {
            // 整块玻璃与内容按所选样式退场，完成后再移除整个面板。
            withAnimation(AppAnimation.easeIn(duration: 0.25), completionCriteria: .removed) {
                model.visible = false
            } completion: { [weak self] in
                guard let self, token == self.dismissal else { return }
                self.model.presented = false
                self.panel.orderOut(nil)
                self.model.releaseContent()
            }
        } else {
            model.visible = false
            model.presented = false
            panel.orderOut(nil)
            panel.cancelFlight()
            model.releaseContent()
        }
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

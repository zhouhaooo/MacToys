// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import Foundation

/// 剪贴板历史里的一条。
struct ClipboardItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    var id: UUID
    var kind: Kind
    /// 列表文字。大文本仅保留开头，完整内容通过 textFile 按需读取；图片为 nil。
    var text: String?
    /// 其他格式的数据文件（例如带格式的 RTF、HTML），键是剪贴板类型，值是文件名。
    var extraFiles: [String: String]
    /// 图片文件名（PNG）。
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    /// 内容的指纹，用来去重。
    var fingerprint: String
    var created: Date
    var lastUsed: Date
    /// 从哪个应用复制的
    var sourceApp: String?
    /// 大文本在 blob 中，text 只保留列表和拼音查询用的开头。
    var textFile: String? = nil
    var storageBytes: Int? = nil
}

/// 从剪贴板读出来、还没存盘的内容。
struct ClipboardCapture {
    var kind: ClipboardItem.Kind
    var text: String?
    /// 剪贴板类型 → 数据
    var extras: [String: Data] = [:]
    var png: Data?
    var imageSize: CGSize?
    var fingerprint: String
    var sourceApp: String?
}

/// 剪贴板历史的存储。内容只保存在本机：
/// ~/Library/Application Support/MacToys/Clipboard/ 下面一个 history.json 加若干数据文件。
/// 元数据与 UI 在主线程修改；blob 和历史文件在 storageQueue 顺序处理。
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    let directory: URL
    private var indexes: [UUID: PinyinIndex] = [:]
    private var saveScheduled = false
    private var pendingRemovals: [ClipboardItem] = []
    /// 只由 storageQueue 使用：元数据写失败时保留，下一次成功保存再清理。
    private var deferredRemovals: [ClipboardItem] = []
    private let storageQueue = DispatchQueue(label: "MacToys.ClipboardStore", qos: .utility, autoreleaseFrequency: .workItem)
    private var searchCancellation = WorkCancellation()
    private let loadedHistory = Locked<[ClipboardItem]?>(nil)
    private var isLoading = false
    private var clearLoadedHistory = false
    private let canSaveHistory = Locked(true)
    private var pendingCaptures: [(ClipboardCapture, Date)] = []
    private let preparedCaptures = Locked<[(String, ClipboardItem, Date, Int)]>([])
    private let pendingWriteBytes = Locked(0)
    private var pendingLoadBytes = 0
    private var currentMaxItems = 200
    private var captureRevision = 0
    private var captureCancellation = WorkCancellation()
    private let maxHistoryBytes: Int
    static let defaultHistoryBytes = 64 << 20
    private static let inlineTextBytes = 16 << 10

    private var historyFile: URL { directory.appendingPathComponent("history.json") }
    private var blobDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    init(directory: URL? = nil, maxHistoryBytes: Int = ClipboardStore.defaultHistoryBytes,
         loadInBackground: Bool? = nil) {
        self.maxHistoryBytes = maxHistoryBytes
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("MacToys/Clipboard", isDirectory: true)
        }
        if !(loadInBackground ?? (directory == nil)) {
            items = storageQueue.sync { readHistory() }
        } else {
            isLoading = true
            storageQueue.async { [weak self] in
                guard let self else { return }
                self.loadedHistory.set(self.readHistory())
                DispatchQueue.main.async { [weak self] in self?.finishLoading() }
            }
        }
    }

    private func finishLoading() {
        guard isLoading, let history = loadedHistory.update({ value -> [ClipboardItem]? in
            defer { value = nil }
            return value
        }) else { return }
        if clearLoadedHistory {
            for item in history { removeFiles(of: item) }
            items = []
            clearLoadedHistory = false
            scheduleSave()
        } else { items = history }
        isLoading = false
        trim(maxItems: currentMaxItems)
        let pending = pendingCaptures
        pendingCaptures = []
        pendingLoadBytes = 0
        for (capture, now) in pending { addInBackground(capture, maxItems: currentMaxItems, now: now) }
    }

    /// 列表只保留摘要；粘贴时才读取完整文本。
    func fullText(for item: ClipboardItem) -> String? {
        guard let file = item.textFile else { return item.text }
        return storageQueue.sync { try? String(contentsOf: blobDirectory.appendingPathComponent(file), encoding: .utf8) }
    }

    // MARK: - 读取

    /// 按最近使用时间排序。
    var sortedItems: [ClipboardItem] {
        items.sorted { a, b in
            return a.lastUsed > b.lastUsed
        }
    }

    func search(_ query: String, completion: @escaping ([ClipboardItem]) -> Void) {
        searchCancellation.cancel()
        let token = WorkCancellation()
        searchCancellation = token
        let sorted = sortedItems
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { completion(sorted); return }
        let direct = Set(sorted.filter { $0.kind == .text && index(for: $0).matches(q) }.map(\.id))
        let blobDirectory = self.blobDirectory
        storageQueue.async {
            let lower = q.lowercased().filter { !$0.isWhitespace }
            var matches: [ClipboardItem] = []
            for item in sorted where item.kind == .text {
                guard !token.isCancelled else { return }
                if direct.contains(item.id) { matches.append(item); continue }
                if let file = item.textFile,
                   let text = try? String(contentsOf: blobDirectory.appendingPathComponent(file), encoding: .utf8),
                   text.lowercased().contains(lower) { matches.append(item) }
            }
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                completion(matches)
            }
        }
    }

    func cancelSearch() { searchCancellation.cancel() }

    #if DEBUG || SELF_TEST
    /// 同步测试边界；正式 UI 使用可取消的异步全文匹配。
    func search(_ query: String) -> [ClipboardItem] {
        let sorted = sortedItems
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sorted }
        return sorted.filter { item in
            guard item.kind == .text else { return false }
            if index(for: item).matches(q) { return true }
            return item.textFile != nil && (fullText(for: item)?.lowercased().contains(q.lowercased().filter { !$0.isWhitespace }) ?? false)
        }
    }
    #endif

    private func index(for item: ClipboardItem) -> PinyinIndex {
        if let cached = indexes[item.id] { return cached }
        let index = PinyinIndex(text: item.text ?? "")
        indexes[item.id] = index
        return index
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        item.imageFile.map { blobDirectory.appendingPathComponent($0) }
    }

    func extraData(for item: ClipboardItem) -> [String: Data] {
        var result: [String: Data] = [:]
        for (type, file) in item.extraFiles {
            if let data = try? Data(contentsOf: blobDirectory.appendingPathComponent(file)) {
                result[type] = data
            }
        }
        return result
    }

    // MARK: - 修改

    /// 正式记录路径：写完 blob 才发布条目；串行队列保持复制顺序。
    func addInBackground(_ capture: ClipboardCapture, maxItems: Int, now: Date = Date()) {
        currentMaxItems = maxItems
        let bytes = (capture.text?.utf8.count ?? 0) + (capture.png?.count ?? 0) + capture.extras.values.reduce(0) { $0 + $1.count }
        if isLoading {
            guard pendingLoadBytes + bytes <= 64 << 20 else { return }
            pendingLoadBytes += bytes
            pendingCaptures.append((capture, now))
            return
        }
        if updateDuplicate(capture.fingerprint, now: now) { return }
        guard pendingWriteBytes.update({ value in
            guard value + bytes <= 64 << 20 else { return false }
            value += bytes
            return true
        }) else { return }
        let revision = captureRevision
        let cancellation = captureCancellation
        storageQueue.async { [weak self] in
            guard let self else { return }
            defer { self.pendingWriteBytes.update { $0 -= bytes } }
            guard !cancellation.isCancelled, let item = self.writeCapture(capture, now: now) else { return }
            self.preparedCaptures.update { $0.append((capture.fingerprint, item, now, revision)) }
            DispatchQueue.main.async { [weak self] in self?.finishPreparedCaptures() }
        }
    }

    private func finishPreparedCaptures() {
        let prepared = preparedCaptures.update { value -> [(String, ClipboardItem, Date, Int)] in
            defer { value = [] }
            return value
        }
        for (fingerprint, item, now, revision) in prepared {
            guard revision == captureRevision else { removeFiles(of: item); scheduleSave(); continue }
            if updateDuplicate(fingerprint, now: now) { removeFiles(of: item); continue }
            items.append(item)
            trim(maxItems: currentMaxItems)
            scheduleSave()
        }
    }

    #if DEBUG || SELF_TEST
    /// 自测、截图和单元测试的同步入口，不进入正式构建。
    func add(_ capture: ClipboardCapture, maxItems: Int, now: Date = Date()) {
        if updateDuplicate(capture.fingerprint, now: now) { return }
        guard let item = storageQueue.sync(execute: { writeCapture(capture, now: now) }) else { return }
        items.append(item)
        trim(maxItems: maxItems)
        scheduleSave()
    }
    #endif

    private func updateDuplicate(_ fingerprint: String, now: Date) -> Bool {
        guard let index = items.firstIndex(where: { $0.fingerprint == fingerprint }) else { return false }
        items[index].lastUsed = now
        scheduleSave()
        return true
    }

    private func writeCapture(_ capture: ClipboardCapture, now: Date) -> ClipboardItem? {
        let id = UUID()
        var item = ClipboardItem(
            id: id, kind: capture.kind, text: capture.text, extraFiles: [:],
            imageFile: nil, imageWidth: capture.imageSize.map { Int($0.width) },
            imageHeight: capture.imageSize.map { Int($0.height) }, fingerprint: capture.fingerprint,
            created: now, lastUsed: now, sourceApp: capture.sourceApp,
            storageBytes: (capture.text?.utf8.count ?? 0) + (capture.png?.count ?? 0)
                + capture.extras.values.reduce(0) { $0 + $1.count })
        do {
            try createPrivateDirectory(blobDirectory)
            try spillText(&item)
            if let png = capture.png {
                let name = "\(id.uuidString).png"
                try png.write(to: blobDirectory.appendingPathComponent(name), options: .atomic)
                item.imageFile = name
            }
            for (index, entry) in capture.extras.sorted(by: { $0.key < $1.key }).enumerated() {
                let name = "\(id.uuidString)-\(index).dat"
                try entry.value.write(to: blobDirectory.appendingPathComponent(name), options: .atomic)
                item.extraFiles[entry.key] = name
            }
            return item
        } catch {
            Log.clipboard.error("保存剪贴板内容失败：\(error.localizedDescription, privacy: .public)")
            deleteFiles(of: item)
            return nil
        }
    }

    private func spillText(_ item: inout ClipboardItem) throws {
        guard item.textFile == nil, let text = item.text, text.utf8.count > Self.inlineTextBytes else { return }
        let file = "\(item.id.uuidString).txt"
        try Data(text.utf8).write(to: blobDirectory.appendingPathComponent(file), options: .atomic)
        item.textFile = file
        item.text = String(text.prefix(PinyinIndex.maxIndexedCharacters))
    }

    func markUsed(_ id: UUID, now: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastUsed = now
        scheduleSave()
    }

    /// 清空所有历史，同时取消尚未发布的记录。
    func clearAll() {
        cancelPendingCaptures()
        if isLoading { clearLoadedHistory = true; return }
        for item in items { removeFiles(of: item) }
        items.removeAll()
        indexes.removeAll()
        scheduleSave()
    }

    func cancelPendingCaptures() {
        captureRevision += 1
        captureCancellation.cancel()
        captureCancellation = WorkCancellation()
        pendingCaptures = []
        pendingLoadBytes = 0
    }

    /// 超出数量或容量时删掉最久没用的。
    func trim(maxItems: Int) {
        currentMaxItems = maxItems
        guard !isLoading else { return }
        let sorted = sortedItems
        var bytes = 0
        var removing = Set<UUID>()
        for (position, item) in sorted.enumerated() {
            let size = item.storageBytes ?? item.text?.utf8.count ?? 0
            if position >= maxItems || bytes + size > maxHistoryBytes { removing.insert(item.id) }
            else { bytes += size }
        }
        guard !removing.isEmpty else { return }
        for item in items where removing.contains(item.id) {
            removeFiles(of: item)
            indexes[item.id] = nil
        }
        items.removeAll { removing.contains($0.id) }
        scheduleSave()
    }

    private func removeFiles(of item: ClipboardItem) {
        pendingRemovals.append(item)
    }

    private func deleteFiles(of item: ClipboardItem) {
        var files = Array(item.extraFiles.values)
        if let image = item.imageFile { files.append(image) }
        if let text = item.textFile { files.append(text) }
        for file in files {
            try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(file))
        }
    }

    // MARK: - 存盘

    private func readHistory() -> [ClipboardItem] {
        let data: Data
        do { data = try Data(contentsOf: historyFile) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue {
                removeUnreferencedFiles(items: [])
            } else {
                // 暂时读不了时不能把磁盘上的历史当成空记录覆盖或清理。
                canSaveHistory.set(false)
                Log.clipboard.error("读取剪贴板历史失败：\(error.localizedDescription, privacy: .public)")
            }
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var history: [ClipboardItem]
        do { history = try decoder.decode([ClipboardItem].self, from: data) }
        catch {
            Log.clipboard.error("读取剪贴板历史失败：\(error.localizedDescription, privacy: .public)")
            let stamp = Int(Date().timeIntervalSince1970)
            do {
                try FileManager.default.moveItem(at: historyFile, to: directory.appendingPathComponent("history-unreadable-\(stamp).json"))
            } catch { canSaveHistory.set(false) }
            return []
        }
        let original = history
        do {
            try createPrivateDirectory(blobDirectory)
            for index in history.indices {
                if history[index].storageBytes == nil {
                    var size = history[index].text?.utf8.count ?? 0
                    let files = Array(history[index].extraFiles.values) + [history[index].imageFile, history[index].textFile].compactMap { $0 }
                    for file in files {
                        size += (try? FileManager.default.attributesOfItem(atPath: blobDirectory.appendingPathComponent(file).path)[.size] as? NSNumber)?.intValue ?? 0
                    }
                    history[index].storageBytes = size
                }
                try spillText(&history[index])
            }
            if history != original { try writeHistory(history) }
            removeUnreferencedFiles(items: history)
            return history
        } catch {
            // 迁移/写入失败不是数据损坏，原始历史与文件仍可读取。
            Log.clipboard.error("迁移剪贴板历史失败：\(error.localizedDescription, privacy: .public)")
            return original
        }
    }

    /// 删掉历史记录里没有引用的数据文件（例如上次保存历史之前程序退出了）。
    private func removeUnreferencedFiles(items: [ClipboardItem]) {
        // 无法解码的历史备份可能仍引用 blob，保留供恢复。
        if let historyFiles = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
           historyFiles.contains(where: { $0.hasPrefix("history-unreadable-") && $0.hasSuffix(".json") }) { return }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: blobDirectory.path) else { return }
        var referenced = Set<String>()
        for item in items {
            referenced.formUnion(item.extraFiles.values)
            if let image = item.imageFile { referenced.insert(image) }
            if let text = item.textFile { referenced.insert(text) }
        }
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(file))
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.saveInBackground()
        }
    }

    private func saveInBackground() {
        guard !isLoading else { return }
        let snapshot = items, removals = pendingRemovals
        pendingRemovals = []
        storageQueue.async { [weak self] in self?.persist(snapshot, removals: removals) }
    }

    /// 退出/测试边界才同步等待，正常修改均由串行后台队列写盘。
    func saveNow() {
        if isLoading {
            storageQueue.sync {}
            finishLoading()
        }
        storageQueue.sync {}
        finishPreparedCaptures()
        let snapshot = items, removals = pendingRemovals
        pendingRemovals = []
        storageQueue.sync { persist(snapshot, removals: removals) }
    }

    private func persist(_ snapshot: [ClipboardItem], removals: [ClipboardItem]) {
        deferredRemovals.append(contentsOf: removals)
        do {
            try writeHistory(snapshot)
            for item in deferredRemovals { deleteFiles(of: item) }
            deferredRemovals = []
        }
        catch { Log.clipboard.error("保存剪贴板历史失败：\(error.localizedDescription, privacy: .public)") }
    }

    private func writeHistory(_ snapshot: [ClipboardItem]) throws {
        guard canSaveHistory.get() else { throw CocoaError(.fileReadNoPermission) }
        try createPrivateDirectory(directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: historyFile, options: .atomic)
    }

    /// 目录只允许当前用户读写。
    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    static func fingerprint(_ parts: [Data]) -> String {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

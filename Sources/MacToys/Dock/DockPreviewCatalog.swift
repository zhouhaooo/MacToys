// SPDX-License-Identifier: MIT

import AppKit

/// 预测和真实悬停共用查询；最多两个任务在途，预测只占一个，待查目标始终保留最新意图。
final class DockPreviewCatalog {
    enum Priority: Hashable { case hover, prediction }
    typealias Query = (pid_t, String) -> [DockWindowPreview]
    typealias Dispatch = (@escaping () -> Void) -> Void

    private struct Request {
        let id = UUID()
        let pid: pid_t
        let name: String
        var priority: Priority
        let revision: Int
        var invalidated = false
    }

    private let query: Query
    private let enqueue: Dispatch
    private let deliver: Dispatch
    private let now: () -> TimeInterval
    private var revision = 0
    private var active: [UUID: Request] = [:]
    private var pending: [Priority: Request] = [:]
    private var dirty: Set<pid_t> = []
    private var cache: [pid_t: (windows: [DockWindowPreview], time: TimeInterval)] = [:]
    var onLoad: (pid_t, [DockWindowPreview]) -> Void = { _, _ in }

    init(query: @escaping Query = DockPreviewController.windows,
         enqueue: Dispatch? = nil,
         deliver: @escaping Dispatch = { DispatchQueue.main.async(execute: $0) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let queue = DispatchQueue(label: "MacToys.DockWindows", qos: .userInitiated, attributes: .concurrent)
        self.query = query
        self.enqueue = enqueue ?? { queue.async(execute: $0) }
        self.deliver = deliver
        self.now = now
    }

    func windows(for pid: pid_t) -> [DockWindowPreview]? {
        guard let entry = cache[pid], now() - entry.time < 5 else { return nil }
        return entry.windows
    }

    func request(pid: pid_t, name: String, priority: Priority, refresh: Bool = false) {
        pending[priority] = nil
        guard pid > 0 else { return }
        if refresh { cache.removeValue(forKey: pid) }
        else if let entry = cache[pid], windows(for: pid) != nil {
            // 刚预测完直接使用；较早的缓存先显示、同时校验窗口是否已关闭或新增。
            if priority == .prediction || now() - entry.time < 0.5 { return }
        }
        if let (id, request) = active.first(where: {
            $0.value.pid == pid && $0.value.revision == revision && !$0.value.invalidated
        }) {
            if priority == .hover { active[id]?.priority = .hover }
            if refresh { dirty.insert(request.pid) }
            return
        }
        if priority == .prediction, pending[.hover]?.pid == pid { return }
        if priority == .hover, pending[.prediction]?.pid == pid { pending[.prediction] = nil }
        pending[priority] = Request(pid: pid, name: name, priority: priority, revision: revision)
        drain()
    }

    /// 清空代次但仍计入正在运行的 AX 调用，重新启用不会越过并发上限。
    func reset() {
        revision += 1
        cache = [:]
        pending = [:]
        dirty = []
    }

    func cancelPending() {
        pending = [:]
        dirty = []
    }

    /// 关闭通知使该应用的旧快照和在途结果失效；在途调用仍占并发名额。
    func invalidate(pid: pid_t) {
        cache.removeValue(forKey: pid)
        pending = pending.filter { $0.value.pid != pid }
        dirty.remove(pid)
        for id in Array(active.keys) where active[id]?.pid == pid {
            active[id]?.invalidated = true
        }
    }

    private func drain() {
        while active.count < 2 {
            let priority: Priority
            if pending[.hover] != nil { priority = .hover }
            else if pending[.prediction] != nil, !active.values.contains(where: { $0.priority == .prediction }) {
                priority = .prediction
            } else { return }
            guard let request = pending.removeValue(forKey: priority) else { return }
            active[request.id] = request
            let query = self.query
            let deliver = self.deliver
            enqueue { [weak self] in
                let windows = query(request.pid, request.name)
                deliver { [weak self] in self?.complete(request, windows: windows) }
            }
        }
    }

    private func complete(_ request: Request, windows: [DockWindowPreview]) {
        guard let finished = active.removeValue(forKey: request.id) else { return }
        if request.revision == revision, !finished.invalidated {
            let timestamp = now()
            cache = cache.filter { timestamp - $0.value.time < 5 }
            cache[request.pid] = (windows, timestamp)
            if cache.count > 12, let oldest = cache.min(by: { $0.value.time < $1.value.time })?.key {
                cache.removeValue(forKey: oldest)
            }
            let refresh = dirty.remove(request.pid) != nil
            onLoad(request.pid, windows)
            if refresh { self.request(pid: request.pid, name: request.name, priority: finished.priority, refresh: true) }
        }
        drain()
    }
}

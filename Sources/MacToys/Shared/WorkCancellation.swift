// SPDX-License-Identifier: MIT

import Foundation

/// 每轮工作单独持有；取消与新一轮任务互不影响。
final class WorkCancellation {
    private struct State {
        var cancelled = false
        var handlers: [UUID: () -> Void] = [:]
    }
    private let state = Locked(State())

    var isCancelled: Bool { state.get().cancelled }

    func cancel() {
        let handlers = state.update { value -> [() -> Void] in
            guard !value.cancelled else { return [] }
            value.cancelled = true
            let handlers = Array(value.handlers.values)
            value.handlers = [:]
            return handlers
        }
        handlers.forEach { $0() }
    }

    @discardableResult
    func onCancel(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        let cancelled = state.update { value -> Bool in
            if value.cancelled { return true }
            value.handlers[id] = handler
            return false
        }
        if cancelled { handler() }
        return id
    }

    func removeHandler(_ id: UUID) { state.update { $0.handlers.removeValue(forKey: id) } }
}

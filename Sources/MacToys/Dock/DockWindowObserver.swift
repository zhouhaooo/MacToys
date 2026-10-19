// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices

/// 监听最近展示的应用窗口；收起预览后仍保留，直到换应用或停止功能。
/// AX 注册和清理放到后台，通知通过主 RunLoop 送达，不读取已销毁元素的属性。
final class DockWindowObserver {
    enum Event { case destroyed, resized }
    typealias Observe = (pid_t, [AXUIElement], @escaping (AXUIElement, Event) -> Void) -> () -> Void

    private let observe: Observe
    private var cancel: (() -> Void)?
    private var revision = 0
    private var pid: pid_t?
    private var windows: Set<AXUIElement> = []
    var onDestroyed: (pid_t, AXUIElement) -> Void = { _, _ in }
    var onResized: (pid_t, AXUIElement) -> Void = { _, _ in }

    init(observe: @escaping Observe = DockWindowObserver.observe) {
        self.observe = observe
    }

    func update(pid: pid_t, windows: [AXUIElement]) {
        let elements = Set(windows)
        guard pid > 0, !elements.isEmpty else { stop(); return }
        guard self.pid != pid || self.windows != elements else { return }
        stop()
        self.pid = pid
        self.windows = elements
        let ticket = revision
        cancel = observe(pid, Array(elements)) { [weak self] element, event in
            guard let self, self.revision == ticket, self.pid == pid,
                  self.windows.contains(element) else { return }
            switch event {
            case .destroyed:
                self.windows.remove(element)
                self.onDestroyed(pid, element)
            case .resized:
                self.onResized(pid, element)
            }
        }
    }

    func stop() {
        revision += 1
        cancel?()
        cancel = nil
        pid = nil
        windows = []
    }

    deinit { cancel?() }

    private static let queue = DispatchQueue(label: "MacToys.DockWindowObserver", qos: .userInitiated)

    private static func observe(pid: pid_t, windows: [AXUIElement],
                                onEvent: @escaping (AXUIElement, Event) -> Void) -> () -> Void {
        guard let session = Session(pid: pid, onEvent: onEvent) else { return {} }
        CFRunLoopAddSource(CFRunLoopGetMain(), session.source, .commonModes)
        queue.async { session.register(windows) }
        return {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), session.source, .commonModes)
            // 与注册串行；清理结束前保留回调上下文，避免悬空指针。
            queue.async { session.unregister() }
        }
    }

    private final class Session {
        let observer: AXObserver
        let source: CFRunLoopSource
        let onEvent: (AXUIElement, Event) -> Void
        private var registered: [(AXUIElement, CFString)] = []

        init?(pid: pid_t, onEvent: @escaping (AXUIElement, Event) -> Void) {
            var observer: AXObserver?
            let result = AXObserverCreate(pid, { _, element, notification, context in
                guard let context else { return }
                let session = Unmanaged<Session>.fromOpaque(context).takeUnretainedValue()
                switch notification as String {
                case kAXUIElementDestroyedNotification: session.onEvent(element, .destroyed)
                case kAXWindowResizedNotification: session.onEvent(element, .resized)
                default: break
                }
            }, &observer)
            guard result == .success, let observer else { return nil }
            self.observer = observer
            source = AXObserverGetRunLoopSource(observer)
            self.onEvent = onEvent
        }

        func register(_ windows: [AXUIElement]) {
            for window in windows {
                for name in [kAXUIElementDestroyedNotification, kAXWindowResizedNotification] {
                    let notification = name as CFString
                    let result = AXObserverAddNotification(observer, window, notification,
                        Unmanaged.passUnretained(self).toOpaque())
                    if result == .success {
                        registered.append((window, notification))
                    } else if result == .invalidUIElement {
                        // 查询结束到监听建立之间，窗口可能已经关闭。
                        let notify = onEvent
                        DispatchQueue.main.async { notify(window, .destroyed) }
                        break
                    }
                }
            }
        }

        func unregister() {
            for (window, notification) in registered {
                AXObserverRemoveNotification(observer, window, notification)
            }
            registered = []
        }
    }
}

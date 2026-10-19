// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacToys

@Suite("Dock 窗口关闭通知")
struct DockWindowObserverTests {
    private final class Harness {
        var callbacks: [(AXUIElement, DockWindowObserver.Event) -> Void] = []
        var cancellations = 0
        var destroyed: [(pid_t, AXUIElement)] = []
        var resized: [AXUIElement] = []
        lazy var observer = DockWindowObserver { [unowned self] _, _, callback in
            callbacks.append(callback)
            return { [unowned self] in cancellations += 1 }
        }

        init() {
            observer.onDestroyed = { [unowned self] pid, window in destroyed.append((pid, window)) }
            observer.onResized = { [unowned self] _, window in resized.append(window) }
        }
    }

    @Test func onlyKnownWindowsDeliverOnceAndRemainingSubscriptionsAreReused() {
        let h = Harness()
        let first = AXUIElementCreateApplication(8101)
        let second = AXUIElementCreateApplication(8102)
        let unknown = AXUIElementCreateApplication(8103)
        h.observer.update(pid: 101, windows: [first, second])
        h.observer.update(pid: 101, windows: [second, first])
        #expect(h.callbacks.count == 1)
        h.callbacks[0](unknown, .destroyed)
        h.callbacks[0](first, .destroyed)
        h.callbacks[0](first, .destroyed)
        #expect(h.destroyed.count == 1)
        #expect(h.destroyed.first?.0 == 101 && h.destroyed.first?.1 == first)
        h.observer.update(pid: 101, windows: [second])
        #expect(h.callbacks.count == 1 && h.cancellations == 0)
        h.callbacks[0](second, .destroyed)
        #expect(h.destroyed.count == 2)
        h.observer.stop()
    }

    @Test func resizeKeepsSubscriptionUntilWindowIsDestroyed() {
        let h = Harness()
        let window = AXUIElementCreateApplication(8101)
        h.observer.update(pid: 101, windows: [window])
        h.callbacks[0](window, .resized)
        h.callbacks[0](window, .resized)
        #expect(h.resized == [window, window] && h.destroyed.isEmpty)
        h.callbacks[0](window, .destroyed)
        h.callbacks[0](window, .resized)
        #expect(h.resized.count == 2 && h.destroyed.count == 1)
        h.observer.stop()
    }

    @Test func switchingAndStoppingIgnoreQueuedNotificationsFromOldSessions() {
        let h = Harness()
        let first = AXUIElementCreateApplication(8101)
        let second = AXUIElementCreateApplication(8102)
        h.observer.update(pid: 101, windows: [first])
        h.observer.update(pid: 102, windows: [second])
        #expect(h.cancellations == 1)
        h.callbacks[0](first, .destroyed)
        #expect(h.destroyed.isEmpty)
        h.callbacks[1](second, .destroyed)
        #expect(h.destroyed.first?.0 == 102)
        h.observer.stop()
        h.callbacks[1](second, .destroyed)
        #expect(h.destroyed.count == 1 && h.cancellations == 2)
    }
}

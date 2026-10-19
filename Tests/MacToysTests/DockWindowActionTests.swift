// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacToys

@Suite("Dock 窗口操作")
struct DockWindowActionTests {
    @Test func optionsDecodeOldConfigsAndPersistIndependently() throws {
        let legacy = try JSONDecoder().decode(DockConfig.self, from: Data("{}".utf8))
        #expect(legacy.dockWindowButtons && legacy.dockMiddleClickClose && legacy.dockSingleWindowToggle)
        for index in 0..<3 {
            var config = legacy
            config.dockWindowButtons = index != 0
            config.dockMiddleClickClose = index != 1
            config.dockSingleWindowToggle = index != 2
            let saved = try JSONDecoder().decode(DockConfig.self, from: JSONEncoder().encode(config))
            #expect(saved == config)
        }
    }

    @Test func singleWindowRestoresMinimizedActivatesBackgroundAndMinimizesForeground() {
        for active in [false, true] {
            #expect(DockSingleWindowAction.resolve(windowCount: 1, minimized: true, fullScreen: false,
                                                  active: active) == .restore)
            #expect(DockSingleWindowAction.resolve(windowCount: 1, minimized: false, fullScreen: false,
                                                  active: active) == (active ? .minimize : .activate))
            for count in [0, 2, 3] {
                #expect(DockSingleWindowAction.resolve(windowCount: count, minimized: true, fullScreen: false,
                                                      active: active) == nil)
            }
            #expect(DockSingleWindowAction.resolve(windowCount: 1, minimized: nil, fullScreen: false,
                                                  active: active) == nil)
            #expect(DockSingleWindowAction.resolve(windowCount: 1, minimized: false, fullScreen: true,
                                                  active: active) == nil)
        }
    }

    @Test @MainActor func interceptorPassesUnrelatedClicksAndReleasesDraggingToDock() throws {
        let interceptor = DockClickInterceptor()
        let point = CGPoint(x: 120, y: 130)
        let down = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                       mouseCursorPosition: point, mouseButton: .left))
        let up = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                     mouseCursorPosition: point, mouseButton: .left))
        let drag = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                       mouseCursorPosition: point, mouseButton: .left))
        var posted: [CGEvent] = []
        #expect(!interceptor.handle(type: .leftMouseDown, event: down, postDragDown: { posted.append($0) }))
        let hit = DockAppHit(pid: 1234, name: "Fixture", icon: NSImage(),
                             url: URL(fileURLWithPath: "/Applications/Fixture.app"), bundleID: "test.fixture",
                             frame: CGRect(x: 100, y: 100, width: 50, height: 50), edge: .bottom)
        interceptor.target.set(.init(hit: hit, frame: CGRect(x: 100, y: 100, width: 50, height: 50)))
        down.flags = .maskCommand
        #expect(!interceptor.handle(type: .leftMouseDown, event: down, postDragDown: { posted.append($0) }))
        down.flags = []
        down.location = CGPoint(x: 50, y: 50)
        #expect(!interceptor.handle(type: .leftMouseDown, event: down, postDragDown: { posted.append($0) }))
        down.location = point
        #expect(interceptor.handle(type: .leftMouseDown, event: down, postDragDown: { posted.append($0) }))
        // 关闭功能后，已吞掉的按下仍能与拖动/松开正确配对。
        interceptor.target.set(nil)
        #expect(!interceptor.handle(type: .leftMouseDragged, event: drag, postDragDown: { posted.append($0) }))
        #expect(posted.count == 1 && Synthetic.isSynthetic(posted[0]))
        #expect(!interceptor.handle(type: .leftMouseUp, event: up, postDragDown: { posted.append($0) }))
        #expect(!interceptor.handle(type: .otherMouseDown, event: down, postDragDown: { posted.append($0) }))
    }

    @Test @MainActor func capturedClickRetainsOriginalAppUntilMouseUp() async throws {
        let interceptor = DockClickInterceptor()
        let point = CGPoint(x: 120, y: 130)
        let hit = DockAppHit(pid: 1234, name: "Fixture", icon: NSImage(),
                             url: URL(fileURLWithPath: "/Applications/Fixture.app"), bundleID: "test.fixture",
                             frame: CGRect(x: 100, y: 100, width: 50, height: 50), edge: .bottom)
        interceptor.target.set(.init(hit: hit, frame: hit.frame))
        var receivedPID: pid_t?
        interceptor.onClick = { clicked, _, _, _ in receivedPID = clicked.pid }
        let down = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                       mouseCursorPosition: point, mouseButton: .left))
        let up = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                     mouseCursorPosition: point, mouseButton: .left))
        #expect(interceptor.handle(type: .leftMouseDown, event: down, postDragDown: { _ in }))
        interceptor.target.set(nil)
        #expect(interceptor.handle(type: .leftMouseUp, event: up, postDragDown: { _ in }))
        await Task.yield()
        #expect(receivedPID == 1234)
        #expect(!interceptor.handle(type: .leftMouseUp, event: up, postDragDown: { _ in }))
    }

    @Test @MainActor func middleClickClosesOnlyVisibleEnabledCardAndConsumesRelease() {
        let monitor = DockMiddleClickMonitor()
        monitor.rect = CGRect(x: 50, y: 50, width: 100, height: 100)
        var closes = 0
        monitor.onClose = { closes += 1 }
        func consume(_ type: NSEvent.EventType, button: Int = 2,
                     point: CGPoint = CGPoint(x: 80, y: 80), visible: Bool = true) -> Bool {
            monitor.consumes(type: type, button: button, point: point, visible: visible)
        }
        #expect(!consume(.otherMouseDown))
        monitor.enabled = true
        #expect(!consume(.otherMouseDown, button: 3))
        #expect(!consume(.otherMouseDown, point: .zero))
        #expect(!consume(.otherMouseDown, visible: false))
        #expect(consume(.otherMouseDown) && closes == 1)
        monitor.enabled = false
        #expect(consume(.otherMouseUp))
        #expect(!consume(.otherMouseUp))
        #expect(!consume(.otherMouseDown))
    }
}

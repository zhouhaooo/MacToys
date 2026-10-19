// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacToys

@Suite("按窗口实际移动识别拖动")
struct WindowDragMotionTests {
    private let frame = CGRect(x: 300, y: 100, width: 900, height: 650)

    @Test func customDocumentHeaderBelowTitleBarTriggersEveryEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let start = CGPoint(x: 600, y: 300) // 距离窗口顶部 200 点的自绘文档标题。
        for (cursor, target) in [(CGPoint(x: 0, y: 500), WindowLayout.Position.leftHalf),
                                 (CGPoint(x: 1919, y: 500), .rightHalf),
                                 (CGPoint(x: 960, y: 0), .maximized)] {
            var motion = WindowDragMotion(frame: frame, cursor: start)
            let moved = frame.offsetBy(dx: cursor.x - start.x, dy: cursor.y - start.y)
            let phase = motion.update(frame: moved, cursor: cursor)
            #expect(phase == .moving)
            #expect(WindowLayout.dragTarget(cursor: cursor, screen: screen) == target)
        }
    }

    @Test func textSelectionAndFileDraggingToAnEdgeDoNotMoveWindow() {
        var motion = WindowDragMotion(frame: frame, cursor: CGPoint(x: 600, y: 300))
        for cursor in [CGPoint(x: 0, y: 500), CGPoint(x: 1919, y: 500), CGPoint(x: 960, y: 0)] {
            let phase = motion.update(frame: frame, cursor: cursor)
            #expect(phase == .waiting)
        }
    }

    @Test func resizingFromTopLeftIsRejectedEvenThoughOriginMoves() {
        var motion = WindowDragMotion(frame: frame, cursor: frame.origin)
        let resized = CGRect(x: 200, y: 50, width: 1000, height: 700)
        let phase = motion.update(frame: resized, cursor: resized.origin)
        #expect(phase == .resizing)
        let later = motion.update(frame: frame.offsetBy(dx: -300, dy: 0), cursor: .zero)
        #expect(later == .resizing)
    }

    @Test func waitsForDelayedWindowPositionAndKeepsMovingWhileCursorStopsAtEdge() {
        let start = CGPoint(x: 600, y: 300), edge = CGPoint(x: 0, y: 500)
        var motion = WindowDragMotion(frame: frame, cursor: start)
        let waiting = motion.update(frame: frame, cursor: edge)
        #expect(waiting == .waiting)
        let moved = frame.offsetBy(dx: -600, dy: 200)
        let moving = motion.update(frame: moved, cursor: edge)
        #expect(moving == .moving)
        let held = motion.update(frame: moved, cursor: edge)
        #expect(held == .moving)
    }

    @Test func ignoresRoundingAndWindowMovementWithoutMouseMovement() {
        let start = CGPoint(x: 600, y: 300)
        var motion = WindowDragMotion(frame: frame, cursor: start)
        let rounding = motion.update(frame: frame.offsetBy(dx: 1, dy: 0), cursor: CGPoint(x: 620, y: 300))
        #expect(rounding == .waiting)
        let automatic = motion.update(frame: frame.offsetBy(dx: 100, dy: 100), cursor: start)
        #expect(automatic == .waiting)
    }

    @Test func restoringSnappedWindowDoesNotCancelTheDragButLaterResizeDoes() {
        var motion = WindowDragMotion(frame: frame, cursor: CGPoint(x: 600, y: 300))
        let moving = motion.update(frame: frame.offsetBy(dx: 10, dy: 0), cursor: CGPoint(x: 610, y: 300))
        #expect(moving == .moving)
        let restored = CGRect(x: 280, y: 100, width: 700, height: 500)
        motion.rebase(afterRestoring: restored)
        let continuing = motion.update(frame: restored.offsetBy(dx: 20, dy: 0), cursor: CGPoint(x: 630, y: 300))
        #expect(continuing == .moving)
        let resizing = motion.update(frame: CGRect(x: 280, y: 100, width: 750, height: 500), cursor: CGPoint(x: 650, y: 300))
        #expect(resizing == .resizing)
    }
}

@Suite("未显示窗口编号")
@MainActor
struct WindowDragWindowNumberTests {
    private final class NumberedWindow: NSWindow {
        var reportedNumber = -1
        override var windowNumber: Int { reportedNumber }
    }

    @Test func unopenedWindowsDoNotCrashOrMatchAVisibleWindow() {
        let hidden = NumberedWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let visible = NumberedWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        visible.reportedNumber = 42
        #expect(OwnWindow(window: hidden).windowID == nil)
        #expect(OwnWindow(window: visible).windowID == 42)
        #expect(OwnWindow.matching(42, in: [hidden, visible]) === visible)
        #expect(OwnWindow.matching(99, in: [hidden, visible]) == nil)
        for invalid in [0, -1, Int.max] {
            hidden.reportedNumber = invalid
            #expect(OwnWindow(window: hidden).windowID == nil)
        }
    }
}

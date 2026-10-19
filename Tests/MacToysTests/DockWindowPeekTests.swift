// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacToys

@Suite("Dock 原位置预览") @MainActor
struct DockWindowPeekTests {
    private final class Harness {
        var delays: [() -> Void] = []
        var cancelled = Set<Int>()
        var waiting: [(CGWindowID, CheckedContinuation<DockWindowPeekSnapshot?, Never>)] = []
        var shown: [DockWindowPeekSnapshot] = []
        var hides = 0
        lazy var controller = DockWindowPeekController(capture: { [unowned self] _, id in
            await withCheckedContinuation { waiting.append((id, $0)) }
        }, schedule: { [unowned self] delay, action in
            #expect(delay == 0.25)
            let index = delays.count
            delays.append(action)
            return { self.cancelled.insert(index) }
        }, show: { [unowned self] in shown.append($0) }, dismiss: { [unowned self] in hides += 1 })
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("原位置预览未在预期时间完成")
    }

    private func snapshot(_ x: CGFloat) -> DockWindowPeekSnapshot {
        .init(image: NSImage(size: CGSize(width: 800, height: 600)),
              frame: CGRect(x: x, y: 100, width: 800, height: 600))
    }

    @Test func crossingCardsDoesNotCaptureAndCancelledCountdownCannotReopen() async {
        let h = Harness()
        h.controller.hover(pid: 100, windowID: 1)
        h.controller.hover(pid: 100, windowID: 1)
        #expect(h.delays.count == 1 && h.waiting.isEmpty)
        h.controller.hover(pid: 100, windowID: 2)
        #expect(h.cancelled.contains(0))
        h.controller.hide()
        h.delays.forEach { $0() }
        await Task.yield()
        #expect(h.waiting.isEmpty && h.shown.isEmpty)
    }

    @Test func lateCaptureCannotReplaceNewTargetAndExitReleasesPreview() async {
        let h = Harness()
        h.controller.hover(pid: 100, windowID: 1)
        h.delays[0]()
        await settle { h.waiting.count == 1 }
        h.controller.hover(pid: 100, windowID: 2)
        h.delays[1]()
        await settle { h.waiting.count == 2 }
        h.waiting[1].1.resume(returning: snapshot(-900))
        await settle { h.shown.count == 1 }
        h.waiting[0].1.resume(returning: snapshot(0))
        await Task.yield()
        #expect(h.shown.count == 1 && h.shown.first?.frame.minX == -900)
        h.controller.hide()
        #expect(h.hides == 3)
        h.controller.hover(pid: 100, windowID: 3)
        h.delays[2]()
        await settle { h.waiting.count == 3 }
        h.controller.hide()
        h.waiting[2].1.resume(returning: snapshot(50))
        await Task.yield()
        #expect(h.shown.count == 1)
    }

    @Test func failedCaptureDoesNotPollOrRetryUntilAnotherHover() async {
        let h = Harness()
        h.controller.hover(pid: 100, windowID: 1)
        h.delays[0]()
        await settle { h.waiting.count == 1 }
        h.waiting[0].1.resume(returning: nil)
        await Task.yield()
        h.controller.hover(pid: 100, windowID: 1)
        #expect(h.shown.isEmpty && h.delays.count == 1)
        h.controller.hide()
        h.controller.hover(pid: 100, windowID: 1)
        #expect(h.delays.count == 2)
        h.controller.hide()
    }

    @Test func hoverNotificationsFollowIdentityAndRemovalWithoutPublishingPanelChanges() {
        let model = DockPreviewModel()
        let preview = DockWindowPreview(windowID: 1,
            window: WindowElement(element: AXUIElementCreateApplication(12345), pid: 12345),
            title: "Test", size: CGSize(width: 800, height: 600), minimized: false)
        var changes: [AXUIElement?] = []
        model.hoverState.onChange = { changes.append($0) }
        model.pid = 12345
        model.windows = [preview]
        model.visible = true
        model.hover(preview, inside: true)
        model.hover(preview, inside: true)
        model.windows = []
        #expect(changes.count == 2 && changes[0] == preview.id && changes[1] == nil)
        model.clearHover()
        #expect(changes.count == 2)
    }

    @Test func previewKeepsOriginalMultiScreenGeometryAndCannotTakeFocusOrPointer() {
        let panel = DockWindowPeekPanel()
        defer { panel.orderOut(nil) }
        let serverFrame = CGRect(x: -1300, y: -700, width: 900, height: 600)
        let expected = ScreenGeometry.appKitRect(serverFrame)
        panel.setFrame(expected, display: false)
        #expect(panel.frame == expected)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain && panel.ignoresMouseEvents)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level.rawValue < DockPreviewPanel.presentationLevel.rawValue)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }
    @Test func nativeResolutionKeepsAllPixelsAndBorderIsFivePhysicalPixels() {
        #expect(DockWindowPeekSnapshot.pixelSize(for: CGSize(width: 3000, height: 2000), scale: 2)
                == CGSize(width: 6000, height: 4000))
        #expect(DockWindowPeekSnapshot.pixelSize(for: CGSize(width: 1920, height: 1080), scale: 1)
                == CGSize(width: 1920, height: 1080))
        for scale: CGFloat in [1, 2] {
            #expect(DockWindowPeekPanel.borderWidth(scale: scale) * scale == 5)
        }
        let panel = DockWindowPeekPanel()
        defer { panel.orderOut(nil) }
        let original = CGRect(x: 100, y: 100, width: 600, height: 400)
        panel.present(image: NSImage(size: original.size), windowFrame: original)
        let border = DockWindowPeekPanel.borderWidth(scale: panel.backingScaleFactor)
        #expect(panel.frame.contains(original.insetBy(dx: -border, dy: -border)))
        #expect(panel.imageView.frame.size == original.size)
        #expect(panel.frame.origin.x + panel.imageView.frame.origin.x == original.minX)
        #expect(panel.frame.origin.y + panel.imageView.frame.origin.y == original.minY)
    }

    @Test func peekSettingMigratesPersistsAndIsSearchable() throws {
        let old = try JSONDecoder().decode(DockConfig.self, from: Data("{}".utf8))
        #expect(old.dockWindowPeek)
        var config = old
        config.dockWindowPeek = false
        let saved = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(DockConfig.self, from: saved).dockWindowPeek == false)
        #expect(SettingsSearch.matches("悬停原位置").contains { $0.tab == .dock })
    }

    @Test func queuedNativeCaptureWaitsForRealCompletionAndCancelledWaitersNeverStart() async throws {
        let gate = WindowCaptureGate(limit: 1)
        var completions: [(Result<Int, Error>) -> Void] = []
        func capture() -> Task<Int, Error> {
            Task { @MainActor in
                try await gate.value(timeout: 2, waitForSlot: true) { completions.append($0) }
            }
        }
        let first = capture()
        await settle { completions.count == 1 }
        first.cancel()
        _ = await first.result
        let cancelled = capture()
        await Task.yield()
        cancelled.cancel()
        _ = await cancelled.result
        let current = capture()
        await Task.yield()
        #expect(completions.count == 1)
        completions[0](.success(1))
        await settle { completions.count == 2 }
        completions[1](.success(42))
        #expect(try await current.value == 42)
    }

    @Test func borderPreferencesMigrateClampPersistAndAppearInSearch() throws {
        let old = try JSONDecoder().decode(DockConfig.self, from: Data("{}".utf8))
        #expect(old.dockPeekBorderWidth == 5 && old.dockPeekCornerRadius == 10)
        let invalid = try JSONDecoder().decode(DockConfig.self,
            from: Data(#"{"dockPeekBorderWidth":200,"dockPeekCornerRadius":-5}"#.utf8))
        #expect(invalid.dockPeekBorderWidth == 20 && invalid.dockPeekCornerRadius == 0)
        #expect(DockConfig.normalizedPeekBorderWidth(.nan) == 5)
        #expect(DockConfig.normalizedPeekCornerRadius(.infinity) == 10)
        var config = old
        config.dockPeekBorderWidth = 8
        config.dockPeekCornerRadius = 24
        let restored = try JSONDecoder().decode(DockConfig.self, from: JSONEncoder().encode(config))
        #expect(restored == config)
        for term in ["预览边框宽度", "预览边框圆角"] {
            #expect(SettingsSearch.matches(term).contains { $0.tab == .dock })
        }
    }

    @Test func liveBorderChangesKeepOriginalImageAlignedWithoutRecapture() {
        let panel = DockWindowPeekPanel()
        defer { panel.orderOut(nil) }
        let original = CGRect(x: 100, y: 100, width: 600, height: 400)
        let image = NSImage(size: original.size)
        panel.present(image: image, windowFrame: original)
        for radius: CGFloat in [0, 24, 40] {
            panel.apply(borderPixels: 12, cornerRadius: radius)
            #expect(panel.borderPixels == 12 && panel.imageView.layer?.cornerRadius == radius)
            #expect(panel.imageView.image === image && panel.imageView.frame.size == original.size)
            #expect(panel.frame.minX + panel.imageView.frame.minX == original.minX)
            #expect(panel.frame.minY + panel.imageView.frame.minY == original.minY)
        }
        for scale: CGFloat in [1, 2] {
            #expect(DockWindowPeekPanel.borderWidth(scale: scale, pixels: 12) * scale == 12)
        }
    }

}

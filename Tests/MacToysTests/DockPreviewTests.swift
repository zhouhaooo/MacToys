// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import QuartzCore
import Observation
import SwiftUI
import Testing
@testable import MacToys

@Suite("Dock 窗口预览")
struct DockPreviewTests {
    @Test func removedGlassTintPreferenceIsIgnoredAndDroppedWhenSaving() throws {
        for value: Any in [30, 100, "invalid"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "dockGlassTintPercent": value, "dockPreviewHeight": 150, "dockShowEmptyApps": false
            ])
            let config = try JSONDecoder().decode(DockConfig.self, from: data)
            #expect(config.dockPreviewHeight == 150 && !config.dockShowEmptyApps)
            let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
            #expect(saved["dockGlassTintPercent"] == nil)
        }
    }

    @Test @MainActor func hoverUpdatesOnlyTheTwoAffectedCardsWithoutInvalidatingPanel() {
        let model = DockPreviewModel()
        model.pid = 1101
        model.visible = true
        let windows = (0..<3).map { index in
            DockWindowPreview(windowID: CGWindowID(index + 1),
                              window: WindowElement(element: AXUIElementCreateApplication(pid_t(21000 + index)), pid: 1101),
                              title: "Window \(index)", size: CGSize(width: 1200, height: 800), minimized: false)
        }
        model.windows = windows
        let selections = windows.map { model.hoverState.selection(for: $0.id) }
        #expect(model.hoverState.selection(for: windows[0].id) === selections[0])
        let panelUpdates = Locked(0)
        let subscription = model.objectWillChange.sink { panelUpdates.update { $0 += 1 } }
        defer { subscription.cancel() }

        model.hover(windows[0], inside: true)
        let changed = (0..<3).map { _ in Locked(0) }
        for index in selections.indices {
            withObservationTracking {
                _ = selections[index].selected
            } onChange: {
                changed[index].update { $0 += 1 }
            }
        }
        model.hover(windows[1], inside: true)
        // 先进入新卡片、后收到旧卡片退出时，新选择不能被清掉。
        model.hover(windows[0], inside: false)
        #expect(model.hoveredID == windows[1].id)
        #expect(selections.map(\.selected) == [false, true, false])
        #expect(changed.map { $0.get() } == [1, 1, 0])
        for index in 0..<120 {
            let current = windows[index % windows.count]
            model.hover(current, inside: true)
            model.hover(current, inside: true)
            #expect(model.hoveredID == current.id)
            #expect(selections.filter(\.selected).count == 1)
        }
        model.clearHover()
        #expect(selections.allSatisfy { !$0.selected })
        #expect(panelUpdates.get() == 0)
    }

    @Test @MainActor func removedAndOutgoingCardsCannotLeaveHoverSelectedOrSelectNewContent() {
        let model = DockPreviewModel()
        model.pid = 1102
        model.visible = true
        let first = DockWindowPreview(windowID: 1,
                                      window: WindowElement(element: AXUIElementCreateApplication(22001), pid: 1102),
                                      title: "First", size: CGSize(width: 800, height: 600), minimized: false)
        let second = DockWindowPreview(windowID: 2,
                                       window: WindowElement(element: AXUIElementCreateApplication(22002), pid: 1102),
                                       title: "Second", size: first.size, minimized: false)
        model.windows = [first, second]
        let oldSelection = model.hoverState.selection(for: first.id)
        model.hover(first, inside: true)
        #expect(oldSelection.selected)
        model.windows = [second]
        #expect(model.hoveredID == nil && !oldSelection.selected)
        model.hover(first, inside: true)
        #expect(model.hoveredID == nil)
        model.hover(second, inside: true)
        model.hover(first, inside: false)
        #expect(model.hoveredID == second.id)
        model.visible = false
        model.clearHover()
        model.hover(second, inside: true)
        #expect(model.hoveredID == nil)
        model.visible = true
        model.pid = 1103
        model.hover(second, inside: true)
        #expect(model.hoveredID == nil)
        model.releaseContent()
        #expect(!model.hoverState.selection(for: second.id).selected)
    }

    @Test func minimizedWindowsSurviveMissingNumberSizeAndStandardSubrole() throws {
        let window = WindowElement(element: AXUIElementCreateApplication(1001), pid: 1001)
        let snapshots = [DockWindowCatalog.Snapshot(window: window, windowID: nil, title: "Safari document",
                                                   size: nil, isStandard: false, minimized: true)]
        let previews = DockWindowCatalog.previews(snapshots, appName: "Safari", serverWindows: [])
        let preview = try #require(previews.first)
        #expect(previews.count == 1 && preview.windowID == nil && preview.minimized)
        #expect(preview.title == "Safari document")
        #expect(preview.size.width >= 60 && preview.size.height >= 40)
        #expect(CFEqual(preview.window.element, window.element))
    }

    @Test func missingPositionDoesNotPreventPreviewAndInvalidMinimizedSizesUseFallback() {
        let window = WindowElement(element: AXUIElementCreateApplication(1002), pid: 1002)
        for size in [CGSize(width: 900, height: 600), .zero, CGSize(width: CGFloat.nan, height: CGFloat.infinity)] {
            let snapshot = DockWindowCatalog.Snapshot(window: window, windowID: 12, title: "",
                                                     size: size, isStandard: true, minimized: true)
            let previews = DockWindowCatalog.previews([snapshot], appName: "WeCom", serverWindows: [])
            #expect(previews.count == 1)
            #expect(previews.first?.title == "WeCom")
            if size.width == 900 { #expect(previews.first?.size == size) }
        }
    }

    @Test func serverBoundsSupplySizeAndServerOnlyWindowsDoNotCreateCards() {
        let window = WindowElement(element: AXUIElementCreateApplication(1003), pid: 1003)
        let snapshot = DockWindowCatalog.Snapshot(window: window, windowID: 13, title: "Document",
                                                 size: nil, isStandard: true, minimized: false)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700).dictionaryRepresentation
        let server: [[String: Any]] = [[kCGWindowNumber as String: CGWindowID(13), kCGWindowBounds as String: bounds],
                                      [kCGWindowNumber as String: CGWindowID(99), kCGWindowBounds as String: bounds]]
        let previews = DockWindowCatalog.previews([snapshot], appName: "App", serverWindows: server)
        #expect(previews.count == 1 && previews.first?.size == CGSize(width: 1000, height: 700))
        #expect(DockWindowCatalog.previews([], appName: "App", serverWindows: server).isEmpty)
    }

    @Test func ordinaryPanelsAndTinyWindowsRemainExcluded() {
        let window = WindowElement(element: AXUIElementCreateApplication(1004), pid: 1004)
        for (standard, size) in [(false, CGSize(width: 900, height: 600)), (true, .zero)] {
            let snapshot = DockWindowCatalog.Snapshot(window: window, windowID: 14, title: "Panel",
                                                     size: size, isStandard: standard, minimized: false)
            #expect(DockWindowCatalog.previews([snapshot], appName: "App", serverWindows: []).isEmpty)
        }
    }

    @Test func minimizedCardIdentityAndCachedImageSurviveNumberChanges() throws {
        let window = WindowElement(element: AXUIElementCreateApplication(1005), pid: 1005)
        let minimized = DockWindowCatalog.Snapshot(window: window, windowID: nil, title: "Document",
                                                  size: nil, isStandard: false, minimized: true)
        let restoredWindow = WindowElement(element: AXUIElementCreateApplication(1005), pid: 1005)
        let restored = DockWindowCatalog.Snapshot(window: restoredWindow, windowID: 15, title: "Document",
                                                 size: CGSize(width: 1000, height: 700), isStandard: true, minimized: false)
        let before = try #require(DockWindowCatalog.previews([minimized], appName: "App", serverWindows: []).first)
        let after = try #require(DockWindowCatalog.previews([restored], appName: "App", serverWindows: []).first)
        let image = NSImage(size: CGSize(width: 10, height: 10))
        let thumbnails = [before.id: image]
        #expect(before.id == after.id && thumbnails[after.id] === image)
        #expect(after.windowID == 15 && !after.minimized)
    }

    @Test func unknownNumbersKeepAXOrderAndDuplicateAXWindowsAppearOnce() {
        let windows = (1006...1008).map { WindowElement(element: AXUIElementCreateApplication(pid_t($0)), pid: pid_t($0)) }
        let snapshots = windows.enumerated().map { index, window in
            DockWindowCatalog.Snapshot(window: window, windowID: index == 2 ? 16 : nil, title: "Window \(index)",
                                       size: CGSize(width: 800, height: 500), isStandard: true, minimized: index < 2)
        }
        let previews = DockWindowCatalog.previews(snapshots + [snapshots[0]], appName: "App",
                                                  serverWindows: [[kCGWindowNumber as String: CGWindowID(16)]])
        #expect(previews.map(\.title) == ["Window 2", "Window 0", "Window 1"])
    }

    @Test func positionsOnEveryDockEdgeAndScreen() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1200, y: 100, width: 1200, height: 800)] {
            let size = CGSize(width: 620, height: 208)
            let bottom = CGRect(x: screen.midX - 25, y: screen.minY, width: 50, height: 50)
            let above = DockPreviewGeometry.surface(size: size, icon: bottom, screen: screen, edge: .bottom)
            #expect(above.minY > bottom.maxY && screen.contains(above))
            let left = CGRect(x: screen.minX, y: screen.midY, width: 50, height: 50)
            let rightOf = DockPreviewGeometry.surface(size: size, icon: left, screen: screen, edge: .left)
            #expect(rightOf.minX > left.maxX && screen.contains(rightOf))
            let right = CGRect(x: screen.maxX - 50, y: screen.midY, width: 50, height: 50)
            let leftOf = DockPreviewGeometry.surface(size: size, icon: right, screen: screen, edge: .right)
            #expect(leftOf.maxX < right.minX && screen.contains(leftOf))
            let oversized = DockPreviewGeometry.surface(size: CGSize(width: 2000, height: 1000), icon: bottom, screen: screen, edge: .bottom)
            #expect(screen.contains(oversized))
        }
    }

    @Test func passageFromDockToPreviewRemainsOpen() {
        let icon = CGRect(x: 500, y: 0, width: 50, height: 50)
        let preview = CGRect(x: 300, y: 62, width: 450, height: 208)
        #expect(DockPreviewGeometry.keepsOpen(point: CGPoint(x: 525, y: 56), icon: icon, surface: preview))
        #expect(!DockPreviewGeometry.keepsOpen(point: CGPoint(x: 900, y: 400), icon: icon, surface: preview))
    }

    @Test func gapPassageCoversBottomLeftAndRightDockWithoutCoveringUnrelatedDesktop() {
        let bottomIcon = CGRect(x: 500, y: 0, width: 50, height: 50)
        let above = CGRect(x: 300, y: 62, width: 450, height: 208)
        for y: CGFloat in [50, 51, 54, 56, 60, 61] {
            #expect(DockPreviewGeometry.isPassage(point: CGPoint(x: 525, y: y), icon: bottomIcon, surface: above))
        }
        #expect(!DockPreviewGeometry.isPassage(point: CGPoint(x: 525, y: 30), icon: bottomIcon, surface: above))
        #expect(!DockPreviewGeometry.isPassage(point: CGPoint(x: 525, y: 100), icon: bottomIcon, surface: above))
        #expect(!DockPreviewGeometry.isPassage(point: CGPoint(x: 800, y: 56), icon: bottomIcon, surface: above))
        let leftIcon = CGRect(x: -1200, y: 500, width: 50, height: 50)
        let rightOf = CGRect(x: -1138, y: 400, width: 250, height: 200)
        #expect(DockPreviewGeometry.isPassage(point: CGPoint(x: -1144, y: 525), icon: leftIcon, surface: rightOf))
        let rightIcon = CGRect(x: 1150, y: 500, width: 50, height: 50)
        let leftOf = CGRect(x: 888, y: 400, width: 250, height: 200)
        #expect(DockPreviewGeometry.isPassage(point: CGPoint(x: 1144, y: 525), icon: rightIcon, surface: leftOf))
    }

    @Test func bottomPreviewKeepsYWhenSwitchingIconsAndResizingContents() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1200, y: 100, width: 1200, height: 800)] {
            var placement = DockPreviewPlacement()
            let visibleFrame = screen.insetBy(dx: 0, dy: 24)
            let first = placement.surface(size: CGSize(width: 260, height: 190),
                                          icon: CGRect(x: screen.midX - 32, y: screen.minY + 12, width: 64, height: 64),
                                          screen: screen, visibleFrame: visibleFrame, edge: .bottom)
            // 切换应用、Dock 放大/显现与窗口清单加载均不能改变预览的纵坐标。
            for (x, y, iconSize, width) in [(screen.minX + 80, screen.minY, CGFloat(48), CGFloat(112)),
                                           (screen.maxX - 160, screen.minY + 20, 96, 900),
                                           (screen.midX, screen.minY - 24, 64, 260)] {
                let icon = CGRect(x: x, y: y, width: iconSize, height: iconSize)
                let surface = placement.surface(size: CGSize(width: width, height: 190), icon: icon,
                                                screen: screen, visibleFrame: visibleFrame, edge: .bottom)
                let expected = DockPreviewGeometry.surface(size: surface.size, icon: icon, screen: visibleFrame, edge: .bottom)
                #expect(surface.minY == first.minY && surface.maxY == first.maxY)
                #expect(surface.minX == expected.minX && surface.width == width)
                #expect(visibleFrame.contains(surface))
            }
        }
    }

    @Test func bottomPreviewAnchorResetsAfterDismissalAndScreenChanges() {
        var placement = DockPreviewPlacement()
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let firstIcon = CGRect(x: 500, y: 12, width: 64, height: 64)
        let nextIcon = CGRect(x: 700, y: 0, width: 48, height: 48)
        let size = CGSize(width: 260, height: 190)
        let first = placement.surface(size: size, icon: firstIcon, screen: screen, visibleFrame: screen, edge: .bottom)
        placement.reset()
        let reopened = placement.surface(size: size, icon: nextIcon, screen: screen, visibleFrame: screen, edge: .bottom)
        #expect(reopened.minY == nextIcon.maxY + 12 && reopened.minY != first.minY)
        let otherScreen = CGRect(x: -1200, y: 100, width: 1200, height: 800)
        let otherIcon = CGRect(x: -600, y: 100, width: 64, height: 64)
        let moved = placement.surface(size: size, icon: otherIcon, screen: otherScreen, visibleFrame: otherScreen, edge: .bottom)
        #expect(moved.minY == otherIcon.maxY + 12 && otherScreen.contains(moved))
    }

    @Test func sideDockStillTracksIconsVerticallyAndClearsBottomAnchor() {
        var placement = DockPreviewPlacement()
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 260, height: 190)
        _ = placement.surface(size: size, icon: CGRect(x: 500, y: 0, width: 48, height: 48),
                              screen: screen, visibleFrame: screen, edge: .bottom)
        for edge in [DockPreviewGeometry.Edge.left, .right] {
            for y: CGFloat in [200, 500] {
                let icon = CGRect(x: edge == .left ? 0 : screen.maxX - 48, y: y, width: 48, height: 48)
                let surface = placement.surface(size: size, icon: icon, screen: screen, visibleFrame: screen, edge: edge)
                #expect(surface.midY == icon.midY && screen.contains(surface))
            }
        }
        let bottomIcon = CGRect(x: 500, y: 12, width: 96, height: 96)
        let bottom = placement.surface(size: size, icon: bottomIcon, screen: screen, visibleFrame: screen, edge: .bottom)
        #expect(bottom.minY == bottomIcon.maxY + 12)
    }

    @Test func rapidAppChangesShowImmediatelyAndLeavingHasGracePeriod() {
        var hover = DockHoverState()
        let result1 = hover.shouldShow(pid: 1, current: nil, now: 0)
        #expect(result1)
        let result2 = hover.shouldShow(pid: 2, current: nil, now: 0.01)
        #expect(result2)
        let result3 = hover.shouldShow(pid: 2, current: nil, now: 0.02)
        #expect(result3)
        let result4 = hover.shouldShow(pid: 2, current: nil, now: 0.19)
        #expect(result4)
        let result5 = hover.shouldShow(pid: 3, current: 2, now: 0.6)
        #expect(result5)
        let result6 = hover.shouldShow(pid: 3, current: 2, now: 0.68)
        #expect(result6)
        let result7 = !hover.shouldHide(inside: false, now: 1)
        #expect(result7)
        let result8 = !hover.shouldHide(inside: true, now: 1.2)
        #expect(result8)
        let result9 = !hover.shouldHide(inside: false, now: 1.3)
        #expect(result9)
        let result10 = hover.shouldHide(inside: false, now: 2.31)
        #expect(result10)
    }

    @Test func firstHitAndRapidSwitchesNeedNoConfirmationTimer() {
        var hover = DockHoverState()
        let initial = hover.shouldShow(pid: 1, current: nil, now: 0)
        let briefPass = hover.shouldShow(pid: 1, current: nil, now: 0.07)
        let ready = hover.shouldShow(pid: 1, current: nil, now: 0.09)
        let changed = hover.shouldShow(pid: 2, current: 1, now: 1)
        #expect(initial && briefPass && ready && changed)
        #expect(hover.nextDeadline == nil)
    }

    @Test func resolvedHitTracksTheIconInsteadOfCursorTravelDistance() {
        let icon = CGRect(x: 500, y: 0, width: 64, height: 64)
        // 指针在图标内移动超过旧的 25 点限制，结果仍有效。
        #expect(DockPreviewGeometry.acceptsResolvedHit(frame: icon, pointer: CGPoint(x: 550, y: 32)))
        // 移动不到 25 点但越过图标边缘时，不显示旧图标的预览。
        #expect(!DockPreviewGeometry.acceptsResolvedHit(frame: icon, pointer: CGPoint(x: 568, y: 32)))
    }

    @Test func ignoredAppHoverCancelsPendingSwitchAndUsesNormalDismissalDelay() {
        var hover = DockHoverState()
        _ = hover.shouldShow(pid: 2, current: 1, now: 0)
        #expect(hover.pendingPID == 2)
        let ignored = hover.shouldHide(inside: false, now: 0.1)
        #expect(!ignored && hover.pendingPID == nil)
        let waiting = hover.shouldHide(inside: false, now: 0.2)
        let closes = hover.shouldHide(inside: false, now: 1.11)
        #expect(!waiting && closes)
        hover.reset()
        _ = hover.shouldHide(inside: false, now: 1)
        let returned = hover.shouldShow(pid: 1, current: 1, now: 1.1)
        let leavesAgain = hover.shouldHide(inside: false, now: 1.15)
        #expect(!returned && !leavesAgain)
    }

    @Test @MainActor func thumbnailsUseWindowAspectRatioAndPanelFitsContents() {
        let portrait = DockPreviewModel.cardWidth(for: CGSize(width: 600, height: 1000))
        let landscape = DockPreviewModel.cardWidth(for: CGSize(width: 1600, height: 900))
        #expect(portrait < landscape)
        let model = DockPreviewModel()
        let dummy = WindowElement(element: AXUIElementCreateSystemWide(), pid: 0)
        model.windows = [.init(windowID: 1, window: dummy, title: "Preview", size: CGSize(width: 1600, height: 900), minimized: false)]
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(model.size(screen: screen).width == landscape + 4)
        model.windows = Array(repeating: model.windows[0], count: 10)
        #expect(model.size(screen: screen).width <= 900)
        model.windows = []
        #expect(model.size(screen: screen).width == model.layout.cardWidth(for: screen.size) + 4)
    }

    @Test @MainActor func emptyPlaceholderMatchesMaximizedWindowAtEveryHeightAndScreenRatio() {
        let model = DockPreviewModel()
        let window = WindowElement(element: AXUIElementCreateApplication(1010), pid: 1010)
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                       CGRect(x: 0, y: 0, width: 900, height: 1440)] {
            for height in DockConfig.dockPreviewHeights.map({ CGFloat($0) }) {
                model.previewHeight = height
                model.windows = []
                let placeholder = model.size(screen: screen)
                model.windows = [.init(windowID: 20, window: window, title: "Maximized",
                                       size: screen.size, minimized: false)]
                #expect(model.size(screen: screen) == placeholder)
            }
        }
    }

    @Test @MainActor func cachedImageRatioControlsBothCardAndPanel() {
        let model = DockPreviewModel()
        let window = WindowElement(element: AXUIElementCreateApplication(1011), pid: 1011)
        let preview = DockWindowPreview(windowID: 21, window: window, title: "Preview",
                                       size: CGSize(width: 600, height: 1000), minimized: false)
        model.windows = [preview]
        model.thumbnails[preview.id] = NSImage(size: CGSize(width: 1600, height: 1000))
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(model.size(screen: screen).width == 212)
        #expect(model.size(screen: screen).height == 165)
        model.thumbnails[preview.id] = NSImage(size: .zero)
        #expect(model.size(screen: screen).width == 87)
    }

    @Test @MainActor func narrowThumbnailsKeepOnlyTheirNormalSideInsets() {
        let model = DockPreviewModel()
        let window = WindowElement(element: AXUIElementCreateApplication(1013), pid: 1013)
        let preview = DockWindowPreview(windowID: 23, window: window, title: "Portrait",
                                       size: CGSize(width: 600, height: 1000), minimized: false)
        model.windows = [preview]
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for height in DockConfig.dockPreviewHeights.map({ CGFloat($0) }) {
            model.previewHeight = height
            for ratio: CGFloat in [0.25, 0.5, 0.6] {
                model.thumbnails[preview.id] = NSImage(size: CGSize(width: 1000 * ratio, height: 1000))
                let size = model.size(screen: screen)
                #expect(model.layout.thumbnailHeight == height)
                #expect(abs(size.width - height * ratio - 12) < 0.001)
                #expect(size.height == height + 40)
            }
        }
    }

    @Test @MainActor func wideImagesShrinkPanelHeightWhenWidthIsCapped() {
        let model = DockPreviewModel()
        let window = WindowElement(element: AXUIElementCreateApplication(1012), pid: 1012)
        let preview = DockWindowPreview(windowID: 22, window: window, title: "Wide",
                                       size: CGSize(width: 800, height: 600), minimized: false)
        model.windows = [preview]
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for height in DockConfig.dockPreviewHeights.map({ CGFloat($0) }) {
            model.previewHeight = height
            for ratio: CGFloat in [3, 5, 8] {
                let image = NSImage(size: CGSize(width: 600 * ratio, height: 600))
                model.thumbnails[preview.id] = image
                let size = model.size(screen: screen)
                let expectedHeight = min(height, (max(360, height * 2.6) - 8) / ratio)
                #expect(abs(size.height - expectedHeight - 40) < 0.001)
                #expect(abs((size.width - 12) / model.layout.thumbnailHeight - ratio) < 0.001)
            }
        }
    }

    @Test func emptyLoadingAndWindowPreviewsHaveTheSameHeight() {
        for hasWindows in [false, true] {
            for recordingAllowed in [false, true] {
                #expect(DockPreviewModel.height(hasWindows: hasWindows, recordingAllowed: recordingAllowed) == 165)
            }
        }
    }

    @Test func legacyConfigEnablesDockPreviewWithoutChangingSnapPreferences() throws {
        let config = try JSONDecoder().decode(DockConfig.self, from: Data(#"{"enabled":false,"snapAssist":false}"#.utf8))
        #expect(config.dockPreview)
        let disabled = try JSONDecoder().decode(DockConfig.self, from: Data(#"{"dockPreview":false}"#.utf8))
        #expect(!disabled.dockPreview)
        #expect(config.dockShowEmptyApps && config.dockExcludedApps.isEmpty)
        let preferences = try JSONDecoder().decode(DockConfig.self,
            from: Data(#"{"dockShowEmptyApps":false,"dockExcludedApps":["com.example.launcher"]}"#.utf8))
        let saved = try JSONDecoder().decode(DockConfig.self, from: JSONEncoder().encode(preferences))
        #expect(!saved.dockShowEmptyApps && saved.dockExcludedApps == ["com.example.launcher"])
    }

    @Test func desktopPreviewPreferencePersistsWithoutAffectingRemainingSettings() throws {
        let config = try JSONDecoder().decode(DockConfig.self,
            from: Data(#"{"dockWindowPeek":true,"dockShowEmptyApps":false}"#.utf8))
        #expect(config.dockPreview && !config.dockShowEmptyApps)
        let encoded = try JSONEncoder().encode(config)
        let saved = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(saved["dockWindowPeek"] as? Bool == config.dockWindowPeek)
    }

    @Test @MainActor func featurePanelsStayBelowDockAndSystemMenus() {
        let thumbnails = DockPreviewPanel(model: DockPreviewModel())
        let clipboard = ClipboardPanel()
        #expect(thumbnails.level.rawValue > clipboard.level.rawValue)
        for panel in [thumbnails, clipboard] {
            #expect(panel.level.rawValue < Int(CGWindowLevelForKey(.dockWindow)))
            #expect(panel.level.rawValue < Int(CGWindowLevelForKey(.mainMenuWindow)))
            #expect(panel.level.rawValue < Int(CGWindowLevelForKey(.statusWindow)))
            panel.orderOut(nil)
        }
    }

    @Test @MainActor func previewHeightAdjustsCardsAndPreservesWindowAspectRatio() {
        let model = DockPreviewModel()
        let window = WindowElement(element: AXUIElementCreateApplication(1009), pid: 1009)
        model.windows = [.init(windowID: 19, window: window, title: "Document",
                               size: CGSize(width: 900, height: 600), minimized: false)]
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for height in DockConfig.dockPreviewHeights.map({ CGFloat($0) }) {
            model.previewHeight = height
            #expect(model.layout.thumbnailHeight == height)
            #expect(model.layout.cardHeight == height + 34)
            #expect(model.size(screen: screen).height == height + 40)
            #expect(model.layout.cardWidth(for: model.windows[0].size) == height * 1.5 + 8)
            model.windows = []
            #expect(model.size(screen: screen).height == height + 40)
            model.windows = [.init(windowID: 19, window: window, title: "Document",
                                   size: CGSize(width: 900, height: 600), minimized: false)]
        }
    }

    @Test func previewHeightConfigDefaultsPersistsAndClampsInvalidValues() throws {
        let legacy = try JSONDecoder().decode(DockConfig.self, from: Data("{}".utf8))
        #expect(legacy.dockPreviewHeight == 125)
        #expect(legacy.dockPreviewAnimation == .materialize)
        let fly = try JSONDecoder().decode(DockConfig.self, from: Data(#"{"dockPreviewAnimation":"fly"}"#.utf8))
        #expect(fly.dockPreviewAnimation == .fly)
        let savedAnimation = try JSONDecoder().decode(DockConfig.self, from: JSONEncoder().encode(fly))
        #expect(savedAnimation.dockPreviewAnimation == .fly)
        let unknownAnimation = try JSONDecoder().decode(DockConfig.self,
            from: Data(#"{"dockPreviewAnimation":"unknown","dockPreviewHeight":175}"#.utf8))
        #expect(unknownAnimation.dockPreviewAnimation == .materialize && unknownAnimation.dockPreviewHeight == 175)
        let customized = try JSONDecoder().decode(DockConfig.self, from: Data(#"{"dockPreviewHeight":175}"#.utf8))
        let saved = try JSONDecoder().decode(DockConfig.self, from: JSONEncoder().encode(customized))
        #expect(saved.dockPreviewHeight == 175)
        let high = try JSONDecoder().decode(DockConfig.self, from: Data(#"{"dockPreviewHeight":9000}"#.utf8))
        let low = try JSONDecoder().decode(DockConfig.self, from: Data(#"{"dockPreviewHeight":-1}"#.utf8))
        #expect(high.dockPreviewHeight == 200 && low.dockPreviewHeight == 50)
        #expect(DockConfig.normalizedDockPreviewHeight(.nan) == 125)
        #expect(DockConfig.dockPreviewHeights == [50, 75, 100, 125, 150, 175, 200])
        #expect(DockConfig.normalizedDockPreviewHeight(156) == 150)
        #expect(DockConfig.normalizedDockPreviewHeight(136) == 125)
        #expect(DockConfig.normalizedDockPreviewHeight(138) == 150)
        #expect(DockConfig.normalizedDockPreviewHeight(240) == 200)
        let previous = try JSONDecoder().decode(DockConfig.self, from: Data(#"{"dockPreviewHeight":206}"#.utf8))
        #expect(previous.dockPreviewHeight == 200)
    }

    @Test func flightOriginHidesTheEntirePreviewBeyondItsOwnScreenEdge() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1920, y: -200, width: 1920, height: 1080)] {
            let surface = CGRect(x: screen.midX - 400, y: screen.minY + 140, width: 800, height: 190)
            let icon = CGRect(x: screen.midX - 32, y: screen.minY + 12, width: 64, height: 64)
            let size = CGSize(width: surface.width * DockPreviewGeometry.flightScale,
                              height: surface.height * DockPreviewGeometry.flightScale)
            for edge in [DockPreviewGeometry.Edge.bottom, .left, .right] {
                let origin = DockPreviewGeometry.flightOrigin(surface: surface, icon: icon, screen: screen, edge: edge)
                let hidden = CGRect(x: origin.x - size.width / 2, y: origin.y - size.height / 2,
                                    width: size.width, height: size.height)
                switch edge {
                case .bottom: #expect(hidden.maxY < screen.minY && hidden.midX == icon.midX)
                case .left: #expect(hidden.maxX < screen.minX && hidden.midY == icon.midY)
                case .right: #expect(hidden.minX > screen.maxX && hidden.midY == icon.midY)
                }
            }
        }
    }

    @Test @MainActor func hiddenCanvasPreparesScreenWithoutPresentingAndIsReused() {
        let model = DockPreviewModel()
        let panel = DockPreviewPanel(model: model)
        for screen in [CGRect(x: -1440, y: -200, width: 1440, height: 900),
                       CGRect(x: 0, y: 0, width: 1920, height: 1080)] {
            panel.prepareCanvas(screen: screen)
            let canvas = panel.frame
            #expect(canvas == screen.insetBy(dx: -DockPreviewPanel.margin, dy: -DockPreviewPanel.margin))
            #expect(!panel.isVisible && !model.presented && !model.visible)
            let surface = CGRect(x: screen.midX - 200, y: screen.minY + 100, width: 400, height: 165)
            panel.prepareSurface(surface, animated: false, screen: screen)
            #expect(panel.frame == canvas && panel.surfaceFrame == surface)
            #expect(model.surfaceRect.origin == CGPoint(x: surface.minX - canvas.minX, y: canvas.maxY - surface.maxY))
            #expect(model.contentWidth == surface.width)
        }
        panel.orderOut(nil)
    }

    @Test @MainActor func flightKeepsWindowGeometryAndHostsSwiftUI() {
        let panel = DockPreviewPanel(model: DockPreviewModel())
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let surface = CGRect(x: 200, y: 100, width: 500, height: 190)
        panel.prepareSurface(surface, animated: false, screen: screen)
        let frame = panel.frame
        panel.setFlightOrigin(icon: CGRect(x: 500, y: 0, width: 64, height: 64), screen: screen, edge: .bottom)
        panel.prepareFlight()
        panel.cancelFlight()
        #expect(panel.frame == frame && panel.surfaceFrame == surface)
        #expect(String(describing: type(of: panel.contentView!)).contains("NSHostingView"))
    }

    @Test @MainActor func previewKeepsActiveAppearanceWithoutTakingKeyboardFocusOrAddingRectangularShadow() {
        let model = DockPreviewModel()
        let panel = DockPreviewPanel(model: model)
        panel.setFrame(CGRect(x: 100, y: 100, width: 332, height: 280), display: false)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain && !panel.hasShadow && !panel.isOpaque)
        #expect(!panel.isKeyWindow && !panel.isMainWindow)
        // 直接调用 AppKit 的外观查询，避免只验证 SwiftUI 环境而漏掉玻璃失焦回归。
        let selector = NSSelectorFromString("_hasActiveAppearance")
        #expect(panel.responds(to: selector))
        typealias AppearanceQuery = @convention(c) (AnyObject, Selector) -> Bool
        let query = unsafeBitCast(panel.method(for: selector), to: AppearanceQuery.self)
        #expect(query(panel, selector))
        #expect(panel.surfaceFrame == CGRect(x: 136, y: 136, width: 260, height: 208))
        panel.orderOut(nil)
    }

    @Test @MainActor func firstVisiblePreviewCanLayoutClippedContentOnAnEmptyCanvas() {
        let model = DockPreviewModel()
        let element = AXUIElementCreateApplication(1012)
        model.pid = 1012
        model.windows = [.init(windowID: 21, window: WindowElement(element: element, pid: 1012),
                               title: "Visible", size: CGSize(width: 1200, height: 800), minimized: false)]
        model.presented = true
        model.visible = true
        let panel = DockPreviewPanel(model: model)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let surface = CGRect(x: 500, y: 200, width: 260, height: 190)
        panel.prepareSurface(surface, animated: false, screen: screen)
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(panel.surfaceFrame == surface)
        #expect(model.surfaceRect.width > 0 && model.surfaceRect.height > 0)
        #expect(model.surfaceRect.midX.isFinite && model.surfaceRect.midY.isFinite)
        panel.orderOut(nil)
    }

    @Test @MainActor func transitionCanvasContainsBothSurfacesAndPreservesScreenPosition() {
        let model = DockPreviewModel()
        let panel = DockPreviewPanel(model: model)
        let first = CGRect(x: 200, y: 150, width: 232, height: 208)
        let second = CGRect(x: 100, y: 150, width: 660, height: 208)
        panel.prepareSurface(first, animated: false)
        panel.prepareSurface(second, animated: true)
        #expect(panel.frame.contains(first.insetBy(dx: -36, dy: -36)))
        #expect(panel.frame.contains(second.insetBy(dx: -36, dy: -36)))
        #expect(panel.surfaceFrame == second)
        #expect(model.surfaceRect.width == second.width)
        #expect(model.surfaceRect.minX + panel.frame.minX == second.minX)
        #expect(panel.frame.maxY - model.surfaceRect.maxY == second.minY)
        panel.orderOut(nil)
    }

    @Test @MainActor func nearAndDistantAppsReuseSameScreenCanvas() {
        let model = DockPreviewModel()
        let panel = DockPreviewPanel(model: model)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.prepareSurface(CGRect(x: 200, y: 100, width: 260, height: 208), animated: false, screen: screen)
        let canvas = panel.frame
        for surface in [CGRect(x: 100, y: 100, width: 680, height: 208),
                        CGRect(x: 1100, y: 100, width: 240, height: 208)] {
            panel.prepareSurface(surface, animated: true, screen: screen)
            #expect(panel.frame == canvas)
            #expect(panel.surfaceFrame == surface)
        }
        panel.orderOut(nil)
    }

    @Test @MainActor func bottomPreviewCanvasKeepsLocalYDuringHorizontalTransitions() {
        let model = DockPreviewModel()
        let panel = DockPreviewPanel(model: model)
        let screen = CGRect(x: -1200, y: 100, width: 1200, height: 800)
        var placement = DockPreviewPlacement()
        let first = placement.surface(size: CGSize(width: 260, height: 190),
                                      icon: CGRect(x: -800, y: 112, width: 64, height: 64),
                                      screen: screen, visibleFrame: screen, edge: .bottom)
        panel.prepareSurface(first, animated: false, screen: screen)
        let canvas = panel.frame
        let localY = model.surfaceRect.minY
        for (icon, width) in [(CGRect(x: -1150, y: 100, width: 48, height: 48), CGFloat(680)),
                              (CGRect(x: -150, y: 120, width: 96, height: 96), 112)] {
            let surface = placement.surface(size: CGSize(width: width, height: 190), icon: icon,
                                            screen: screen, visibleFrame: screen, edge: .bottom)
            withAnimation(AppAnimation.easeOut(duration: 0.25)) {
                panel.prepareSurface(surface, animated: true, screen: screen)
            }
            #expect(panel.frame == canvas && panel.surfaceFrame.minY == first.minY)
            #expect(model.surfaceRect.minY == localY && model.surfaceRect.height == first.height)
            #expect(panel.frame.maxY - model.surfaceRect.maxY == first.minY)
        }
        panel.orderOut(nil)
    }
}

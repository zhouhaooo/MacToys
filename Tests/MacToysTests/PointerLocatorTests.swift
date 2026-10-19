import AppKit
import Testing
@testable import MacToys

struct PointerLocatorTests {
    @Test func doubleTapFollowsEffectiveMappingOnBothSides() {
        for swapped in [false, true] {
            for pair in ModifierMapping.pairs {
                var gesture = ModifierDoubleTap()
                let key = swapped ? pair.1 : pair.0
                let flags = (swapped ? CGEventFlags.maskCommand : .maskControl)
                    .union(CGEventFlags(rawValue: swapped ? pair.3 : pair.2))
                let result1 = !gesture.handle(type: .flagsChanged, key: key, flags: flags, time: 1, swapped: swapped, enabled: true)
                #expect(result1)
                let result2 = !gesture.handle(type: .flagsChanged, key: key, flags: [], time: 1.05, swapped: swapped, enabled: true)
                #expect(result2)
                let result3 = !gesture.handle(type: .flagsChanged, key: key, flags: flags, time: 1.2, swapped: swapped, enabled: true)
                #expect(result3)
                let result4 = gesture.handle(type: .flagsChanged, key: key, flags: [], time: 1.25, swapped: swapped, enabled: true)
                #expect(result4)
                // A third tap starts a fresh pair instead of triggering again.
                let result5 = !gesture.handle(type: .flagsChanged, key: key, flags: flags, time: 1.3, swapped: swapped, enabled: true)
                #expect(result5)
                let result6 = !gesture.handle(type: .flagsChanged, key: key, flags: [], time: 1.35, swapped: swapped, enabled: true)
                #expect(result6)
            }
        }
    }

    @Test func shortcutsOtherModifiersAndMouseActivityCancelTheGesture() {
        for interruption in [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .scrollWheel] {
            var gesture = ModifierDoubleTap()
            _ = gesture.handle(type: .flagsChanged, key: KeyCode.control, flags: .maskControl, time: 1, swapped: false, enabled: true)
            _ = gesture.handle(type: interruption, key: KeyCode.c, flags: [.maskControl, .maskShift], time: 1.02, swapped: false, enabled: true)
            let result7 = !gesture.handle(type: .flagsChanged, key: KeyCode.control, flags: [], time: 1.05, swapped: false, enabled: true)
            #expect(result7)
            _ = gesture.handle(type: .flagsChanged, key: KeyCode.control, flags: .maskControl, time: 1.2, swapped: false, enabled: true)
            let result8 = !gesture.handle(type: .flagsChanged, key: KeyCode.control, flags: [], time: 1.25, swapped: false, enabled: true)
            #expect(result8)
        }
    }

    @Test func slowLongDisabledWrongSideOrChangedMappingDoesNotTrigger() {
        for scenario in 0..<7 {
            var gesture = ModifierDoubleTap()
            let firstKey = scenario == 3 ? KeyCode.command : KeyCode.control
            let firstFlags: CGEventFlags = scenario == 3 ? .maskCommand : .maskControl
            _ = gesture.handle(type: .flagsChanged, key: firstKey, flags: firstFlags, time: 1, swapped: false, enabled: true)
            _ = gesture.handle(type: .flagsChanged, key: firstKey, flags: [], time: scenario == 1 ? 1.6 : 1.05, swapped: false, enabled: true)
            let swapped = scenario == 4
            let key = swapped ? KeyCode.command : (scenario == 5 ? KeyCode.rightControl : KeyCode.control)
            let flags: CGEventFlags = swapped ? .maskCommand : .maskControl
            let time = scenario == 0 || scenario == 1 ? 2.0 : 1.2
            if scenario == 6 { gesture.reset() }
            _ = gesture.handle(type: .flagsChanged, key: key, flags: flags, time: time, swapped: swapped, enabled: scenario != 2)
            let result9 = !gesture.handle(type: .flagsChanged, key: key, flags: [], time: time + 0.05, swapped: swapped, enabled: true)
            #expect(result9)
        }
    }

    @Test func pointerLocatorAloneKeepsEventTapAvailableAndPersists() throws {
        var config = AppConfig()
        config.keyboard.swapCommandControl = false
        config.keyboard.finderCut = false
        config.mouse.reverseScroll = false
        config.clipboard.enabled = false
        config.dock.dockPreview = false
        var policy = FeatureAvailability(accessibility: true, clipboardAllowed: false, screenRecording: false, config: config)
        #expect(policy.events)
        policy.config.mouse.locatePointer = false
        #expect(!policy.events)
        #expect(try JSONDecoder().decode(MouseConfig.self, from: Data("{}".utf8)).locatePointer)
        config.mouse.locatePointer = false
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(AppConfig.self, from: data) == config)
        #expect(SettingsSearch.matches("定位鼠标").contains { $0.tab == .mapping && $0.title == "定位鼠标" })
    }

    @Test func spotlightDurationMigratesClampsAndPersists() throws {
        let old = try JSONDecoder().decode(MouseConfig.self, from: Data(#"{"locatePointer":true}"#.utf8))
        #expect(old.locatePointerDuration == 3)
        for (saved, expected) in [(0.0, 1.0), (-5, 1), (45, 30), (7, 7)] {
            let json = "{\"locatePointerDuration\":\(saved)}"
            let config = try JSONDecoder().decode(MouseConfig.self, from: Data(json.utf8))
            #expect(config.locatePointerDuration == expected)
        }
        #expect(MouseConfig.normalizedLocatePointerDuration(.infinity) == 3)
        let suite = "mactoys.pointer-duration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigStore(defaults: defaults)
        store.config.mouse.locatePointerDuration = 8
        #expect(ConfigStore(defaults: defaults).config.mouse.locatePointerDuration == 8)
        #expect(SettingsSearch.matches("聚光灯持续时间").contains { $0.tab == .mapping && $0.title == "聚光灯持续时间" })
    }

    @MainActor @Test func fixedDeadlineClosesStationarySpotlightAndRetriggerRestartsIt() async throws {
        _ = NSApplication.shared
        let locator = PointerLocator()
        defer { locator.stop() }
        locator.show(duration: 1)
        #expect(locator.isVisible)
        try await Task.sleep(for: .milliseconds(700))
        locator.show(duration: 1)
        // The first presentation would have closed by now. Its cancelled timer
        // must not dismiss the new presentation before its own full interval.
        try await Task.sleep(for: .milliseconds(1400))
        #expect(locator.isVisible)
        try await Task.sleep(for: .milliseconds(900))
        #expect(!locator.isVisible)
    }

}

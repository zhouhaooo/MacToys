import Testing
import AppKit
@testable import MacToys

struct InputTests {
    let finder = AppIdentity(bundleID: "com.apple.finder", name: "Finder")
    let normal = AppIdentity(bundleID: "test.editor", name: "Editor")

    @Test func modifierMappingIsSymmetricAndPreservesOtherFlags() {
        for (control, command, controlBit, commandBit) in ModifierMapping.pairs {
            #expect(ModifierMapping.key(control) == command)
            #expect(ModifierMapping.key(command) == control)
            let flags = CGEventFlags.maskControl.union(.maskShift).union(.maskAlternate).union(CGEventFlags(rawValue: controlBit))
            let mapped = ModifierMapping.flags(flags)
            #expect(mapped.contains([.maskCommand, .maskShift, .maskAlternate]))
            #expect(!mapped.contains(.maskControl))
            #expect(mapped.rawValue & commandBit != 0)
            #expect(mapped.rawValue & controlBit == 0)
            #expect(ModifierMapping.flags(mapped) == flags)
        }
        let both: CGEventFlags = [.maskControl, .maskCommand, .maskAlphaShift]
        #expect(ModifierMapping.flags(both) == both)
    }
    @Test func heldModifierRetainsMappingAcrossAppAndConfigurationChanges() {
        var session = ModifierSession()
        let start = session.resolve(flags: .maskControl, requested: true)
        let held = session.resolve(flags: [.maskControl, .maskCommand], requested: false)
        let released = session.resolve(flags: [], requested: false)
        let next = session.resolve(flags: .maskCommand, requested: false)
        #expect(start && held && released && !next)
        session.reset()
        let restarted = session.resolve(flags: .maskCommand, requested: true)
        #expect(restarted)
    }
    @Test func shortcutsFollowEffectiveApplicationMapping() {
        for swap in [false, true] {
            var config = KeyboardConfig(); config.swapCommandControl = swap
            config.excludedApps = ["test.editor"]
            for app in [finder, normal] {
                let effective = config.swaps(in: app)
                let auxiliary: CGEventFlags = effective ? .maskCommand : .maskControl
                let action: CGEventFlags = effective ? .maskControl : .maskCommand
                let mapper = KeyMapper(config: config)
                #expect(mapper.action(key: KeyCode.v, flags: auxiliary, app: app, clipboard: true, focus: { .browsing }) == .clipboardHistory)
                #expect(mapper.action(key: KeyCode.v, flags: action, app: app, clipboard: true, focus: { .text }) == .pass)
                #expect(mapper.action(key: KeyCode.v, flags: auxiliary, app: app, clipboard: false, focus: { .browsing }) == .pass)
            }
        }
    }
    @Test func finderCutNeverRewritesTextOrUnknownFocus() {
        for enabled in [false, true] {
            var config = KeyboardConfig()
            config.finderCut = enabled
            let mapper = KeyMapper(config: config)
            for focus in [FocusKind.browsing, .text, .unknown, .other] {
                let browsing = focus == .browsing
                #expect(mapper.action(key: KeyCode.x, flags: .maskCommand, app: finder, clipboard: false, focus: { focus }) ==
                        (browsing && enabled ? .finderCut : .pass))
                #expect(mapper.action(key: KeyCode.v, flags: .maskCommand, app: finder, clipboard: false, focus: { focus }) ==
                        (browsing && enabled ? .finderPaste : .pass))
                #expect(mapper.action(key: KeyCode.x, flags: [], app: finder, clipboard: false, focus: { focus }) == .pass)
            }
        }
    }
    @Test func functionEnterAndArrowKeysKeepNativeActions() {
        for swap in [false, true] {
            var config = KeyboardConfig()
            config.swapCommandControl = swap
            let mapper = KeyMapper(config: config)
            for app in [finder, normal] {
                for key in [KeyCode.f2, KeyCode.returnKey, KeyCode.keypadEnter,
                            KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.upArrow, KeyCode.downArrow] {
                    for flags: CGEventFlags in [[], .maskControl, .maskCommand,
                                               [.maskControl, .maskShift], [.maskCommand, .maskShift]] {
                        #expect(mapper.action(key: key, flags: flags, app: app, clipboard: true,
                                              focus: { .browsing }) == .pass)
                    }
                }
            }
        }
    }
    @Test func noTerminalOrRemotePresetsAndFinderCanBeExcluded() {
        var config = KeyboardConfig(); config.swapCommandControl = true
        for id in ["com.apple.Terminal", "com.microsoft.rdc.macos", "com.parallels.desktop"] {
            #expect(config.swaps(in: AppIdentity(bundleID: id)))
        }
        config.excludedApps = ["com.apple.finder"]
        #expect(!config.swaps(in: finder))
        #expect(KeyMapper(config: config).action(key: KeyCode.x, flags: .maskCommand, app: finder, clipboard: false, focus: { .browsing }) == .pass)
    }
    @Test func scrollReversesBothAxesOnlyForDiscreteWheels() {
        let v = ScrollAxis(lines: 3, fixed: 3.5, points: 30)
        let h = ScrollAxis(lines: -2, fixed: -2.5, points: -20)
        for reverse in [false, true] {
            for continuous in [false, true] {
                let result = ScrollTransform.apply(vertical: v, horizontal: h, reverse: reverse, continuous: continuous)
                #expect(result.vertical == (reverse && !continuous ? v.negated : v))
                #expect(result.horizontal == (reverse && !continuous ? h.negated : h))
            }
        }
    }
    @Test func independentConfigPersistsAndSearchFindsEachSetting() throws {
        let suite = "mactoys.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigStore(defaults: defaults)
        #expect(!store.config.keyboard.swapCommandControl && store.config.keyboard.excludedApps.isEmpty)
        store.config.keyboard.swapCommandControl = true
        store.config.keyboard.finderCut = false
        store.config.window.enabled = false
        #expect(store.config.dock.dockPreview)
        #expect(ConfigStore(defaults: defaults).config == store.config)
        #expect(defaults.data(forKey: "config.v1") == nil)
        for item in SettingsSearch.items { #expect(SettingsSearch.matches(item.title).contains(where: { $0.id == item.id })) }
    }
}

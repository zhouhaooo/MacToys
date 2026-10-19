// SPDX-License-Identifier: MIT
import CoreGraphics

/// Shortcuts are evaluated in physical coordinates before modifier conversion.
enum KeyAction: Equatable {
    case pass, finderCut, finderPaste
    case clipboardHistory, locatePointer
}

struct KeyMapper {
    var config: KeyboardConfig

    func action(key: CGKeyCode, flags: CGEventFlags, app: AppIdentity,
                clipboard: Bool, localPanel: Bool = false,
                swapped: Bool? = nil, focus: () -> FocusKind) -> KeyAction {
        let swap = swapped ?? config.swaps(in: app)
        let mods = flags.intersection(.modifierKeys)
        let auxiliary: CGEventFlags = swap ? .maskCommand : .maskControl
        if key == KeyCode.v, mods == auxiliary, clipboard { return .clipboardHistory }
        if localPanel { return .pass }
        guard app.bundleID == AppCatalog.finder,
              !config.excludedApps.contains(AppCatalog.finder) else { return .pass }
        let action: CGEventFlags = swap ? .maskControl : .maskCommand
        let candidate: KeyAction
        switch (key, mods) {
        case (KeyCode.x, action) where config.finderCut: candidate = .finderCut
        case (KeyCode.v, action) where config.finderCut: candidate = .finderPaste
        default: return .pass
        }
        return focus() == .browsing ? candidate : .pass
    }
}

/// Both aggregate and left/right device flags must agree with the rewritten keycode.
enum ModifierMapping {
    static let pairs: [(CGKeyCode, CGKeyCode, UInt64, UInt64)] = [
        (KeyCode.control, KeyCode.command, 0x1, 0x8),
        (KeyCode.rightControl, KeyCode.rightCommand, 0x2000, 0x10)
    ]
    static func key(_ code: CGKeyCode) -> CGKeyCode {
        for (control, command, _, _) in pairs {
            if code == control { return command }
            if code == command { return control }
        }
        return code
    }
    static func flags(_ flags: CGEventFlags) -> CGEventFlags {
        var result = flags.subtracting([.maskCommand, .maskControl])
        if flags.contains(.maskCommand) { result.insert(.maskControl) }
        if flags.contains(.maskControl) { result.insert(.maskCommand) }
        var raw = result.rawValue
        for (_, _, control, command) in pairs {
            raw &= ~(control | command)
            if flags.rawValue & control != 0 { raw |= command }
            if flags.rawValue & command != 0 { raw |= control }
        }
        return CGEventFlags(rawValue: raw)
    }
}

/// Hold one mapping until Command/Control are fully released, even across app/config changes.
struct ModifierSession {
    private(set) var swapping: Bool? = nil
    mutating func resolve(flags: CGEventFlags, requested: Bool) -> Bool {
        let active = !flags.intersection([.maskControl, .maskCommand]).isEmpty
        if active, swapping == nil { swapping = requested }
        let result = swapping ?? requested
        if !active { swapping = nil }
        return result
    }
    mutating func reset() { swapping = nil }
}

// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation

/// Recognize two complete, unaccompanied taps of the same physical modifier.
/// Uses the effective mapping before events are rewritten for other apps.
struct ModifierDoubleTap {
    var interval: TimeInterval = 0.4
    private var pressed: (key: CGKeyCode, time: TimeInterval)?
    private var previous: (key: CGKeyCode, time: TimeInterval)?
    private var mapping: Bool?

    mutating func handle(type: CGEventType, key: CGKeyCode, flags: CGEventFlags,
                         time: TimeInterval, swapped: Bool, enabled: Bool) -> Bool {
        guard enabled else { reset(); return false }
        if mapping != swapped { reset(); mapping = swapped }
        guard type == .flagsChanged else { reset(); return false }

        let pair = ModifierMapping.pairs.first { swapped ? $0.1 == key : $0.0 == key }
        guard let pair else { reset(); return false }
        let expected: CGEventFlags = swapped ? .maskCommand : .maskControl
        let disallowed = flags.intersection(.modifierKeys).subtracting(expected)
        guard disallowed.isEmpty, !flags.contains(.maskSecondaryFn) else { reset(); return false }

        let deviceMask = ModifierMapping.pairs.reduce(UInt64(0)) { $0 | (swapped ? $1.3 : $1.2) }
        let deviceBit = swapped ? pair.3 : pair.2
        let down = flags.rawValue & deviceMask != 0
            ? flags.rawValue & deviceBit != 0 : flags.contains(expected)
        if down {
            guard pressed == nil else { reset(); return false }
            pressed = (key, time)
            return false
        }
        guard flags.intersection(.modifierKeys).isEmpty,
              let press = pressed, press.key == key,
              time >= press.time, time - press.time <= interval else { reset(); return false }
        pressed = nil
        if let first = previous, first.key == key,
           press.time >= first.time, press.time - first.time <= interval {
            reset()
            return true
        }
        previous = press
        return false
    }

    mutating func reset() {
        pressed = nil
        previous = nil
        mapping = nil
    }
}

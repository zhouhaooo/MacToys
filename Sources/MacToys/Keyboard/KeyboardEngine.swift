// SPDX-License-Identifier: MIT
import AppKit

final class KeyboardEngine {
    private let config: Locked<AppConfig>
    private let environment: FrontAppTracker
    private let inspector = FocusInspector()
    private let onAction: (KeyAction) -> Void
    private var actions: [CGKeyCode: KeyAction] = [:]
    private var swaps: [CGKeyCode: Bool] = [:]
    private var sent: [CGKeyCode: KeyStroke] = [:]
    private var modifiers: [CGKeyCode: CGKeyCode] = [:]
    private var session = ModifierSession()
    private var pointerGesture = ModifierDoubleTap()
    private let cut = Locked<Int?>(nil)
    private let cutGeneration = Locked(0)

    init(config: Locked<AppConfig>, environment: FrontAppTracker, onAction: @escaping (KeyAction) -> Void) {
        self.config = config; self.environment = environment; self.onAction = onAction
        pointerGesture.interval = NSEvent.doubleClickInterval
    }

    func mappedFlags(_ flags: CGEventFlags) -> CGEventFlags {
        let swap = session.resolve(flags: flags, requested: config.get().keyboard.swaps(in: environment.current.get()))
        return swap ? ModifierMapping.flags(flags) : flags
    }

    func handle(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let cfg = config.get()
        let app = environment.current.get()
        let physical = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let rawFlags = event.flags
        let swap = session.resolve(flags: rawFlags, requested: cfg.keyboard.swaps(in: app))
        if pointerGesture.handle(type: type, key: physical, flags: rawFlags,
                                 time: TimeInterval(event.timestamp) / 1_000_000_000,
                                 swapped: swap, enabled: cfg.mouse.locatePointer) {
            DispatchQueue.main.async { [onAction] in onAction(.locatePointer) }
        }
        if type == .flagsChanged {
            let mapped = swap ? ModifierMapping.key(physical) : physical
            if mapped != physical {
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(mapped))
                if let (_, _, ctrlBit, cmdBit) = ModifierMapping.pairs.first(where: { $0.0 == physical || $0.1 == physical }) {
                    let bit = physical == KeyCode.control || physical == KeyCode.rightControl ? ctrlBit : cmdBit
                    if rawFlags.rawValue & bit != 0 { modifiers[physical] = mapped } else { modifiers.removeValue(forKey: physical) }
                }
            }
            if swap { event.flags = ModifierMapping.flags(rawFlags) }
            return Unmanaged.passUnretained(event)
        }
        let down = type == .keyDown
        if !down {
            let action = actions.removeValue(forKey: physical) ?? .pass
            let originalSwap = swaps.removeValue(forKey: physical) ?? swap
            if let stroke = sent.removeValue(forKey: physical) {
                Synthetic.keyEvent(stroke, down: false, original: event)?.tapPostEvent(proxy)
                return nil
            }
            if action != .pass { return nil }
            if originalSwap { event.flags = ModifierMapping.flags(rawFlags) }
            return Unmanaged.passUnretained(event)
        }
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let action = actions[physical] ?? KeyMapper(config: cfg.keyboard).action(
            key: physical, flags: rawFlags, app: app,
            clipboard: cfg.clipboard.enabled,
            localPanel: environment.clipboardPanelActive.get() || environment.snapAssistActive.get(),
            swapped: swap, focus: { [inspector] in inspector.focusKind() })
        actions[physical] = action
        if swaps[physical] == nil { swaps[physical] = swap }
        switch action {
        case .pass:
            if swaps[physical] == true { event.flags = ModifierMapping.flags(rawFlags) }
            return Unmanaged.passUnretained(event)
        case .finderCut:
            if !repeated {
                let before = NSPasteboard.general.changeCount
                let generation = cutGeneration.update { $0 += 1; return $0 }
                cut.set(nil)
                send(KeyStroke(KeyCode.c, .maskCommand), physical: physical, event: event, proxy: proxy)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [cut, cutGeneration] in
                    guard cutGeneration.get() == generation else { return }
                    let now = NSPasteboard.general.changeCount
                    let files = NSPasteboard.general.types?.contains(.fileURL) == true
                    cut.set(now != before && files ? now : nil)
                }
            }
        case .finderPaste:
            if !repeated {
                cutGeneration.update { $0 += 1 }
                let moving = cut.update { value -> Bool in
                    defer { value = nil }
                    return value == NSPasteboard.general.changeCount
                }
                send(KeyStroke(KeyCode.v, moving ? [.maskCommand, .maskAlternate] : .maskCommand),
                     physical: physical, event: event, proxy: proxy)
            }
        case .clipboardHistory, .locatePointer:
            if !repeated { DispatchQueue.main.async { [onAction] in onAction(action) } }
        }
        return nil
    }

    private func send(_ stroke: KeyStroke, physical: CGKeyCode, event: CGEvent, proxy: CGEventTapProxy) {
        sent[physical] = stroke
        Synthetic.keyEvent(stroke, down: true, original: event)?.tapPostEvent(proxy)
    }

    private func release(_ post: (CGEvent) -> Void) {
        for stroke in sent.values { if let event = Synthetic.keyEvent(stroke, down: false) { post(event) } }
        for code in modifiers.values { if let event = Synthetic.modifierEvent(keyCode: code, flags: []) { post(event) } }
        actions.removeAll(); swaps.removeAll(); sent.removeAll(); modifiers.removeAll(); session.reset()
        pointerGesture.reset()
        cutGeneration.update { $0 += 1 }; cut.set(nil)
    }
    func reset(proxy: CGEventTapProxy) { release { $0.tapPostEvent(proxy) } }
    func cancelPointerGesture() { pointerGesture.reset() }
    func stop() { release { $0.post(tap: .cgSessionEventTap) } }
}

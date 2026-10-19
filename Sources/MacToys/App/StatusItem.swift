// SPDX-License-Identifier: MIT
import AppKit
import Combine

/// Left-click toggles Keep Awake; right-click opens the standard macOS menu.
final class StatusItemBridge: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let runtime: Runtime
    private var subscription: AnyCancellable?

    init(runtime: Runtime) {
        self.runtime = runtime
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        subscription = runtime.keepAwake.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        updateIcon()
    }

    private func updateIcon() {
        item.button?.image = StatusItemIcon.image(isActive: runtime.keepAwake.isActive)
        item.button?.toolTip = "MacToys · " + runtime.keepAwake.statusText
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            runtime.keepAwake.refresh()
            item.menu = makeMenu()
            button.performClick(nil)
            item.menu = nil
        } else {
            toggleKeepAwake()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: runtime.keepAwake.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let toggle = addItem(L("保持唤醒"), action: #selector(toggleKeepAwake), to: menu)
        toggle.state = runtime.keepAwake.isActive ? .on : .off

        let durationMenu = NSMenu()
        durationMenu.autoenablesItems = false
        for duration in KeepAwakeDuration.allCases {
            let option = addItem(duration.title, action: #selector(selectDuration(_:)), to: durationMenu)
            option.representedObject = duration.rawValue
            option.state = runtime.config.config.keepAwake.duration == duration ? .on : .off
        }
        let duration = NSMenuItem(title: L("唤醒时长"), action: nil, keyEquivalent: "")
        duration.submenu = durationMenu
        menu.addItem(duration)
        menu.addItem(.separator())
        let clipboard = addItem(L("剪贴板历史"), action: #selector(showClipboard), to: menu)
        clipboard.isEnabled = runtime.config.config.clipboard.enabled
        addItem(L("打开设置…"), action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        addItem(L("退出 MacToys"), action: #selector(quit), to: menu)
        return menu
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    @objc private func toggleKeepAwake() {
        if runtime.keepAwake.isActive { runtime.keepAwake.stop() }
        else { runtime.keepAwake.start(for: runtime.config.config.keepAwake.duration) }
    }

    @objc private func selectDuration(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let duration = KeepAwakeDuration(rawValue: rawValue) else { return }
        if runtime.keepAwake.isActive && !runtime.keepAwake.start(for: duration) { return }
        runtime.config.config.keepAwake.duration = duration
    }

    @objc private func showClipboard() { runtime.showClipboard() }
    @objc private func showSettings() { runtime.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

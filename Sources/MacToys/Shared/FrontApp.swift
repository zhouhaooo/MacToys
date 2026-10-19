// SPDX-License-Identifier: MIT
import AppKit

final class FrontAppTracker {
    static let shared = FrontAppTracker()
    let current = Locked(AppIdentity())
    let clipboardPanelActive = Locked(false)
    let snapAssistActive = Locked(false)
    private var observer: NSObjectProtocol?
    func start() {
        guard observer == nil else { return }
        update(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                self?.update(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
    }
    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil; clipboardPanelActive.set(false); snapAssistActive.set(false)
    }
    private func update(_ app: NSRunningApplication?) {
        current.set(AppIdentity(bundleID: app?.bundleIdentifier, name: app?.localizedName))
    }
    deinit { stop() }
}

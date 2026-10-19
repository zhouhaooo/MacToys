// SPDX-License-Identifier: MIT
import SwiftUI
import Combine

@main
struct MacToysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var locale = AppLocale.shared
    var body: some Scene {
        Window(L("MacToys 设置"), id: "settings") {
            SettingsView(runtime: Runtime.shared)
                .environment(\.locale, AppLanguage.uiLocale)
                .id(locale.revision)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 880, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {}
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Runtime.shared.start()
    }
    func applicationWillTerminate(_ notification: Notification) { Runtime.shared.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Settings is a single SwiftUI Window; keep menu-bar services alive when it closes.
        false
    }
    func applicationDidBecomeActive(_ notification: Notification) { Runtime.shared.refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Runtime.shared.showSettings(); return true
    }
}

/// Coordinates independent services; authorization never gates unrelated modules.
final class Runtime: ObservableObject {
    static let shared = Runtime()
    let config = ConfigStore.shared
    let state = AppState()
    let keepAwake = KeepAwakeController()
    private let pointerLocator = PointerLocator()
    lazy var clipboard = ClipboardController(configStore: config)
    private lazy var snapper = WindowSnapper(configStore: config)
    private lazy var dock = DockPreviewController()
    private lazy var events = EventTapService(
        keyboard: KeyboardEngine(config: config.snapshot, environment: .shared) { [weak self] action in
            switch action {
            case .clipboardHistory: self?.showClipboard()
            case .locatePointer:
                guard let self, self.config.config.mouse.locatePointer else { return }
                self.pointerLocator.show(duration: self.config.config.mouse.locatePointerDuration)
            default: break
            }
        }, mouse: MouseEngine(config: config.snapshot), dockClicks: dock.clicks)
    private var status: StatusItemBridge?
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private var applied: AppConfig?
    private var permissionSignature = ""
    var openSettings: (() -> Void)?

    func start() {
        guard !started else { return }
        started = true
        FrontAppTracker.shared.start()
        status = StatusItemBridge(runtime: self)
        subscription = config.$config.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.5
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.keepAwake.refresh(); self?.refresh() }
        refresh()
    }
    func refresh() {
        guard started else { return }
        state.refreshPermissions()
        let cfg = config.config
        let available = FeatureAvailability(accessibility: state.accessibilityGranted,
            clipboardAllowed: state.pasteboardAccess == .allowed, screenRecording: state.screenRecordingGranted, config: cfg)
        if available.events {
            state.eventTapRunning = events.isRunning || events.start()
        } else if state.eventTapRunning {
            events.stop(); state.eventTapRunning = false
        }
        let signature = "\(state.accessibilityGranted)-\(state.screenRecordingGranted)-\(state.pasteboardAccess)"
        let permissionsChanged = signature != permissionSignature
        permissionSignature = signature
        if applied?.clipboard != cfg.clipboard || permissionsChanged { clipboard.applyConfig() }
        if applied?.window != cfg.window || permissionsChanged { snapper.applyConfig() }
        if applied?.dock != cfg.dock || permissionsChanged { dock.apply(config: cfg.dock) }
        if !cfg.mouse.locatePointer || !available.events { pointerLocator.stop() }
        applied = cfg
        WindowThumbnailStore.shared.apply(enabled: available.thumbnails)
    }
    func showClipboard() {
        guard config.config.clipboard.enabled else { return }
        if clipboard.isVisible { clipboard.close() } else { clipboard.show() }
    }
    func showSettings() { openSettings?() }
    func stop() {
        timer?.invalidate(); timer = nil
        subscription = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        keepAwake.stop(); clipboard.stop(); clipboard.store.saveNow()
        dock.stop(); snapper.stop(); events.stop(); pointerLocator.stop()
        WindowThumbnailStore.shared.apply(enabled: false)
        FrontAppTracker.shared.stop(); config.saveNow(); started = false
    }
}

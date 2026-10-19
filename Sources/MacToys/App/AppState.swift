// SPDX-License-Identifier: MIT
import AppKit
import Combine
import ServiceManagement

final class AppState: ObservableObject {
    @Published var accessibilityGranted = false
    @Published var inputMonitoringGranted = false
    @Published var screenRecordingGranted = false
    @Published var pasteboardAccess = PasteboardAccess.Status.needsSetup
    @Published var eventTapRunning = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var problem: String?
    func refreshPermissions() {
        accessibilityGranted = Permissions.accessibility
        inputMonitoringGranted = Permissions.inputMonitoring
        screenRecordingGranted = Permissions.screenRecording
        pasteboardAccess = PasteboardAccess.status
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch { problem = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

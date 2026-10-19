import Testing
import Foundation
@testable import MacToys

struct PermissionTests {
    @Test func grantsAreIndependent() {
        for accessibility in [false, true] {
            for clipboard in [false, true] {
                for screen in [false, true] {
                    let policy = FeatureAvailability(accessibility: accessibility, clipboardAllowed: clipboard,
                                                     screenRecording: screen, config: AppConfig())
                    #expect(policy.keepAwake)
                    #expect(policy.events == accessibility)
                    #expect(policy.snapping == accessibility)
                    #expect(policy.dock == accessibility)
                    #expect(policy.clipboardRecording == clipboard)
                    #expect(policy.thumbnails == (screen && accessibility))
                }
            }
        }
    }
    @Test func thumbnailConsumersAndRecordingStopIndependently() {
        var policy = FeatureAvailability(accessibility: true, clipboardAllowed: true, screenRecording: true, config: AppConfig())
        policy.config.dock.dockPreview = false
        #expect(policy.thumbnails)
        policy.config.window.snapAssist = false
        #expect(!policy.thumbnails && policy.snapping)
        policy.config.clipboard.enabled = false
        #expect(!policy.clipboardRecording && policy.snapping)
        policy.accessibility = false
        #expect(!policy.events && policy.keepAwake)
    }
    @Test func partialConfigsPreserveKnownSettings() throws {
        let json = #"{"keyboard":{"finderCut":false,"excludedApps":["test.app","test.app"]},"window":{"enabled":false}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(!config.keyboard.finderCut)
        #expect(config.keyboard.excludedApps == ["test.app"])
        #expect(!config.window.enabled && config.window.snapAssist && config.dock.dockPreview)
        #expect(config.mouse.reverseScroll && !config.keyboard.swapCommandControl)
    }
}

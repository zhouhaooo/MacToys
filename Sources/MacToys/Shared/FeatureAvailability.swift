import Foundation

/// Pure capability policy. Missing one grant never blocks an unrelated feature.
struct FeatureAvailability {
    var accessibility: Bool
    var clipboardAllowed: Bool
    var screenRecording: Bool
    var config: AppConfig

    var events: Bool {
        accessibility && (config.keyboard.swapCommandControl || config.keyboard.finderCut
            || config.mouse.reverseScroll || config.mouse.locatePointer || config.clipboard.enabled
            || config.dock.dockPreview)
    }
    var clipboardRecording: Bool { config.clipboard.enabled && clipboardAllowed }
    var snapping: Bool { accessibility && config.window.enabled }
    var dock: Bool { accessibility && config.dock.dockPreview }
    var thumbnails: Bool {
        screenRecording && (dock || (snapping && config.window.snapAssist))
    }
    var keepAwake: Bool { true }
}

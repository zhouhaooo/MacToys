// SPDX-License-Identifier: MIT
import AppKit
import Combine

struct KeyboardConfig: Codable, Equatable {
    var swapCommandControl = false
    var finderCut = true
    var excludedApps: [String] = []

    private enum CodingKeys: String, CodingKey {
        case swapCommandControl, finderCut, excludedApps
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swapCommandControl = c.value(.swapCommandControl, default: false)
        finderCut = c.value(.finderCut, default: true)
        let saved = c.value(.excludedApps, default: [String]())
        var seen = Set<String>()
        excludedApps = saved.filter { seen.insert($0).inserted }
    }
    func swaps(in app: AppIdentity) -> Bool {
        swapCommandControl && !(app.bundleID.map(excludedApps.contains) ?? false)
    }
    var actionModifier: ShortcutModifier { swapCommandControl ? .control : .command }
    var auxiliaryModifier: ShortcutModifier { swapCommandControl ? .command : .control }
}

enum ShortcutModifier {
    case control, command
    var name: String { self == .control ? "Ctrl" : "Command" }
    var flags: CGEventFlags { self == .control ? .maskControl : .maskCommand }
}

struct MouseConfig: Codable, Equatable {
    var reverseScroll = true
    var locatePointer = true
    var locatePointerDuration: Double = 3
    static let locatePointerDurationRange: ClosedRange<Double> = 1...30
    static func normalizedLocatePointerDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 3 }
        return min(max(value.rounded(), locatePointerDurationRange.lowerBound), locatePointerDurationRange.upperBound)
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reverseScroll = c.value(.reverseScroll, default: true)
        locatePointer = c.value(.locatePointer, default: true)
        locatePointerDuration = Self.normalizedLocatePointerDuration(c.value(.locatePointerDuration, default: 3))
    }
}

struct WindowConfig: Codable, Equatable {
    var enabled = true
    var dragToSnap = true
    var snapAssist = true
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: true)
        dragToSnap = c.value(.dragToSnap, default: true)
        snapAssist = c.value(.snapAssist, default: true)
    }
}

struct ClipboardConfig: Codable, Equatable {
    var enabled = true
    /// 最多保存多少条。
    var maxItems = 200
    var recordImages = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipboardConfig()
        enabled = c.value(.enabled, default: d.enabled)
        maxItems = min(max(c.value(.maxItems, default: d.maxItems), 10), 1000)
        recordImages = c.value(.recordImages, default: d.recordImages)
    }
}

enum DockPreviewAnimation: String, Codable, CaseIterable {
    case materialize
    case fly
}

struct DockConfig: Codable, Equatable {
    /// Dock 悬停显示应用窗口，与分屏开关独立。
    var dockPreview = true
    var dockWindowPeek = true
    var dockPeekBorderWidth: Double = 5
    var dockPeekCornerRadius: Double = 10
    static let dockPeekBorderWidthRange: ClosedRange<Double> = 1...20
    static let dockPeekCornerRadiusRange: ClosedRange<Double> = 0...40
    static func normalizedPeekBorderWidth(_ value: Double) -> Double {
        value.isFinite ? min(max(value.rounded(), 1), 20) : 5
    }
    static func normalizedPeekCornerRadius(_ value: Double) -> Double {
        value.isFinite ? min(max(value.rounded(), 0), 40) : 10
    }
    /// 卡片中窗口图像的高度（点）；读取旧配置时归到最近的新档位。
    var dockPreviewHeight: Double = 125
    static let dockPreviewHeightRange: ClosedRange<Double> = 50...200
    static let dockPreviewHeights: [Double] = [50, 75, 100, 125, 150, 175, 200]
    static func normalizedDockPreviewHeight(_ value: Double) -> Double {
        guard value.isFinite else { return 125 }
        return dockPreviewHeights.min { abs($0 - value) < abs($1 - value) } ?? 125
    }
    var dockPreviewAnimation = DockPreviewAnimation.materialize
    var dockShowEmptyApps = true
    var dockWindowButtons = true
    var dockMiddleClickClose = true
    var dockSingleWindowToggle = true
    var dockExcludedApps: [String] = []
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockConfig()
        dockPreview = c.value(.dockPreview, default: d.dockPreview)
        dockWindowPeek = c.value(.dockWindowPeek, default: d.dockWindowPeek)
        dockPeekBorderWidth = Self.normalizedPeekBorderWidth(c.value(.dockPeekBorderWidth, default: d.dockPeekBorderWidth))
        dockPeekCornerRadius = Self.normalizedPeekCornerRadius(c.value(.dockPeekCornerRadius, default: d.dockPeekCornerRadius))
        dockPreviewHeight = Self.normalizedDockPreviewHeight(c.value(.dockPreviewHeight, default: d.dockPreviewHeight))
        dockPreviewAnimation = c.value(.dockPreviewAnimation, default: d.dockPreviewAnimation)
        dockShowEmptyApps = c.value(.dockShowEmptyApps, default: d.dockShowEmptyApps)
        dockWindowButtons = c.value(.dockWindowButtons, default: d.dockWindowButtons)
        dockMiddleClickClose = c.value(.dockMiddleClickClose, default: d.dockMiddleClickClose)
        dockSingleWindowToggle = c.value(.dockSingleWindowToggle, default: d.dockSingleWindowToggle)
        dockExcludedApps = c.value(.dockExcludedApps, default: d.dockExcludedApps)
    }
}

struct KeepAwakeConfig: Codable, Equatable {
    /// 记住下次单击开启时用的时长，不保存正在唤醒的状态。
    var duration = KeepAwakeDuration.unlimited

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = c.value(.duration, default: KeepAwakeConfig().duration)
    }
}


struct AppConfig: Codable, Equatable {
    var keyboard = KeyboardConfig()
    var mouse = MouseConfig()
    var clipboard = ClipboardConfig()
    var window = WindowConfig()
    var dock = DockConfig()
    var keepAwake = KeepAwakeConfig()
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyboard = c.value(.keyboard, default: KeyboardConfig())
        mouse = c.value(.mouse, default: MouseConfig())
        clipboard = c.value(.clipboard, default: ClipboardConfig())
        window = c.value(.window, default: WindowConfig())
        dock = c.value(.dock, default: DockConfig())
        keepAwake = c.value(.keepAwake, default: KeepAwakeConfig())
    }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    let snapshot: Locked<AppConfig>
    private let defaults: UserDefaults
    @Published var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            snapshot.set(config)
            saveNow()
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = defaults.data(forKey: "mactoys.config.v1")
            .flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) } ?? AppConfig()
        config = loaded
        snapshot = Locked(loaded)
    }
    func saveNow() {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: "mactoys.config.v1") }
    }
}

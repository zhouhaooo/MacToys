// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 功能面板只在普通窗口上方，始终给 Dock、菜单及系统提示让位。
enum AppPanelLevel {
    private static var ceiling: Int { Int(CGWindowLevelForKey(.dockWindow)) }
    static var utility: NSWindow.Level { NSWindow.Level(rawValue: ceiling - 3) }
    static var dockPreview: NSWindow.Level { NSWindow.Level(rawValue: ceiling - 1) }
}

/// 浮动面板的内容原地凝实/消散，和原生玻璃的 materialize 同步。
private struct PanelContentDissolve: ViewModifier {
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: blur).opacity(opacity)
    }
}

extension AnyTransition {
    static var panelContentDissolve: AnyTransition {
        .modifier(active: PanelContentDissolve(blur: 8, opacity: 0),
                  identity: PanelContentDissolve(blur: 0, opacity: 1))
    }
}

/// Dock 与窗口选择面板共用的图片边界和悬浮反馈。
private struct WindowThumbnailBorder: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct WindowThumbnailShadow: ViewModifier {
    let selected: Bool
    let subtle: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(selected ? (colorScheme == .dark ? (subtle ? 0.16 : 0.32) : (subtle ? 0.08 : 0.16)) : 0),
                       radius: selected ? (subtle ? 5 : 7) : 0, y: selected ? (subtle ? 2 : 4) : 0)
    }
}

private struct WindowPreviewLift: ViewModifier {
    let selected: Bool
    let subtle: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Dock 卡片常被快速扫过，进入和回落都要及时跟随指针。
        let duration = reduceMotion ? 0.12 : (subtle ? (selected ? 0.10 : 0.08) : 0.18)
        return content
            .scaleEffect(selected && !reduceMotion ? (subtle ? 1.012 : 1.025) : 1)
            .offset(y: selected && !reduceMotion && !subtle ? -2 : 0)
            .animation(AppAnimation.easeOut(duration: duration), value: selected)
            .zIndex(selected ? 1 : 0)
    }
}

extension View {
    func windowThumbnailBorder(cornerRadius: CGFloat = 11) -> some View {
        modifier(WindowThumbnailBorder(cornerRadius: cornerRadius))
    }
    func windowThumbnailShadow(selected: Bool, subtle: Bool = false) -> some View {
        modifier(WindowThumbnailShadow(selected: selected, subtle: subtle))
    }
    func windowPreviewLift(selected: Bool, subtle: Bool = false) -> some View {
        modifier(WindowPreviewLift(selected: selected, subtle: subtle))
    }
}

/// 面板内用轮廓标记选中和悬停，不往玻璃上叠加背景底色。
private struct PanelSelectionStyle: ViewModifier {
    let selected: Bool
    let hovered: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let strong = contrast == .increased
        content
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(selected ? (strong ? 0.65 : 0.24) : hovered ? 0.12 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 两个状态共用玻璃身份，让轮廓连续变形；整块玻璃不做淡出或模糊替换。
private struct NativeGlassReplacement<Value: Hashable>: ViewModifier {
    let value: Value
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        GlassEffectContainer(spacing: 0) {
            ZStack(alignment: .trailing) {
                content
                    .glassEffectID("control", in: namespace)
                    .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                    .transition(.identity)
            }
        }
        .animation(reduceMotion ? nil : AppAnimation.easeOut(), value: value)
    }
}

extension View {
    func panelSelection(selected: Bool, hovered: Bool = false) -> some View {
        modifier(PanelSelectionStyle(selected: selected, hovered: hovered))
    }

    func nativeGlassReplacement<Value: Hashable>(value: Value) -> some View {
        modifier(NativeGlassReplacement(value: value))
    }

}

/// 显式把颜色交给轻量玻璃；macOS 的标准玻璃按钮会按上下文忽略材质的 tint。
struct LightGlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var circular = false
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini: 4
        case .small: 8
        default: 12
        }
    }

    private var verticalPadding: CGFloat {
        switch controlSize {
        case .mini: 0
        case .small: 4
        default: 6
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = circular ? AnyShape(Circle()) : AnyShape(Capsule(style: .continuous))
        let glassTint = tint ?? (configuration.role == .destructive ? .red : nil)
        return configuration.label
            .foregroundStyle(isEnabled ? (glassTint == nil ? Color.primary : .white) : .secondary)
            .padding(.horizontal, circular ? 3 : horizontalPadding)
            .padding(.vertical, circular ? 3 : verticalPadding)
            .glassEffect(.clear.tint(isEnabled ? glassTint : nil).interactive(isEnabled), in: shape)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : AppAnimation.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LightGlassButtonStyle {
    static var lightGlass: Self { Self() }
    static func lightGlass(tint: Color?) -> Self { Self(tint: tint) }
    static var lightGlassCircle: Self { Self(circular: true) }
}

// MARK: - 鼠标停在上面

/// 为需要自定义反馈的紧凑按钮记录悬停状态。
final class HoverState: ObservableObject {
    @Published var isHovered = false
    #if DEBUG
    /// 截图用：所有按钮都画成鼠标停在上面的样子
    static var previewAll = false
    #endif
}

/// 禁用时不显示悬停反馈。
struct HoverReader<Content: View>: View {
    @StateObject private var state = HoverState()
    @Environment(\.isEnabled) private var isEnabled
    private let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    private var hovering: Bool {
        #if DEBUG
        if HoverState.previewAll { return isEnabled }
        #endif
        return state.isHovered && isEnabled
    }

    var body: some View {
        content(hovering)
            .animation(AppAnimation.easeOut(duration: 0.12), value: hovering)
            .onHover { inside in
                if state.isHovered != inside { state.isHovered = inside }
            }
    }
}

/// 文字链接（“打开系统设置”）：鼠标停在上面加下划线、换成手形指针，按下变淡。
/// color 为 nil 时用外面给的颜色
struct HoverLinkStyle: ButtonStyle {
    var color: Color? = Color(nsColor: .linkColor)

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .foregroundStyle(ifGiven: color)
                .underline(hovering)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .pointerStyle(.link)
        }
    }
}

extension ButtonStyle where Self == HoverLinkStyle {
    static var hoverLink: Self { HoverLinkStyle() }
}

/// 只有图标的按钮（列表里的 ⊖ 移除）：平时灰色，鼠标停在上面变成 color
struct HoverIconStyle: ButtonStyle {
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .foregroundStyle(hovering ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
        }
    }
}

extension View {
    /// 给了颜色才设，没给就用外面的
    @ViewBuilder func foregroundStyle(ifGiven color: Color?) -> some View {
        if let color {
            foregroundStyle(color)
        } else {
            self
        }
    }
}

/// 应用的图标和名字，按应用标识查，查过的记下来。只在主线程上使用。
enum AppInfo {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    static func name(_ bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
        }
        names[bundleID] = name
        return name
    }
}

extension Text {
    func settingsFooter() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}

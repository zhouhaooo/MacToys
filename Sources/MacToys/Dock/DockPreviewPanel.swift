// SPDX-License-Identifier: MIT

import AppKit
import QuartzCore
import Observation
import SwiftUI

struct DockWindowPreview: Identifiable {
    // AX 身份用于卡片和缓存；窗口编号只用于截图，最小化时可能不可读。
    var id: AXUIElement { window.element }
    let windowID: CGWindowID?
    let window: WindowElement
    let title: String
    let size: CGSize
    let minimized: Bool
}

/// 悬停只更新前后两张卡片，不向整块玻璃面板发布变化。
final class DockPreviewHoverState {
    @Observable final class Selection {
        fileprivate(set) var selected = false
    }

    private var selections: [AXUIElement: Selection] = [:]
    var onChange: (AXUIElement?) -> Void = { _ in }
    var hoveredID: AXUIElement? {
        didSet {
            guard oldValue != hoveredID else { return }
            if let oldValue { selections[oldValue]?.selected = false }
            if let hoveredID { selections[hoveredID]?.selected = true }
            onChange(hoveredID)
        }
    }

    func selection(for id: AXUIElement) -> Selection {
        if let selection = selections[id] { return selection }
        let selection = Selection()
        selection.selected = hoveredID == id
        selections[id] = selection
        return selection
    }

    func retain(_ ids: Set<AXUIElement>) {
        if let hoveredID, !ids.contains(hoveredID) { self.hoveredID = nil }
        selections = selections.filter { ids.contains($0.key) }
    }
}

final class DockPreviewModel: ObservableObject {
    @Published var pid: pid_t = 0
    @Published var appName = ""
    @Published var appIcon = NSImage()
    @Published var windows: [DockWindowPreview] = [] {
        didSet { hoverState.retain(Set(windows.map(\.id))) }
    }
    @Published var thumbnails: [AXUIElement: NSImage] = [:]
    @Published var recordingAllowed = false
    let hoverState = DockPreviewHoverState()
    var hoveredID: AXUIElement? {
        get { hoverState.hoveredID }
        set { hoverState.hoveredID = newValue }
    }
    @Published var contentWidth: CGFloat = 260
    @Published var surfaceRect = CGRect(x: 36, y: 36, width: 260, height: DockPreviewModel.surfaceHeight)
    @Published var animation = DockPreviewAnimation.materialize
    @Published var presented = false
    @Published var visible = false
    @Published var showWindowButtons = true
    @Published var middleClickClose = true
    var onClose: (DockWindowPreview) -> Void = { _ in }
    var onMinimize: (DockWindowPreview) -> Void = { _ in }
    var onChoose: (DockWindowPreview) -> Void = { _ in }
    var onOpenApp: () -> Void = {}
    @Published var loading = false
    @Published var previewHeight: CGFloat = DockPreviewModel.thumbnailHeight
    @Published var scrollOffset: CGFloat = 0
    var layout: Layout {
        let requested = Layout(thumbnailHeight: previewHeight)
        // 宽度达到上限后同步收紧高度，避免图片缩小而卡片仍保留整块空白。
        let height = windows.reduce(previewHeight) { height, window in
            let size = Self.previewSize(window, image: thumbnails[window.id])
            let width = requested.cardWidth(for: size) - 8
            guard previewHeight * (size.width / size.height) + 8 > max(360, previewHeight * 2.6) else { return height }
            return min(height, width * size.height / size.width)
        }
        return Layout(thumbnailHeight: height, widthLimit: max(360, previewHeight * 2.6))
    }

    static func previewSize(_ window: DockWindowPreview, image: NSImage?) -> CGSize {
        if let size = image?.size, size.width.isFinite, size.height.isFinite,
           size.width > 0, size.height > 0 { return size }
        return window.size
    }

    struct Layout {
        let thumbnailHeight: CGFloat
        var widthLimit: CGFloat? = nil
        var cardHeight: CGFloat { thumbnailHeight + 34 }
        var surfaceHeight: CGFloat { cardHeight + surfaceTopPadding + surfacePadding + 2 * rowPadding }
        func cardWidth(for size: CGSize) -> CGFloat {
            let ratio = max(size.width, 1) / max(size.height, 1)
            // 窄窗口也按截图比例收紧，只保留缩略图两侧各 4 点边距。
            return min(widthLimit ?? max(360, thumbnailHeight * 2.6), thumbnailHeight * ratio + 8)
        }
    }

    static let surfaceHeight: CGFloat = Layout(thumbnailHeight: thumbnailHeight).surfaceHeight
    static let thumbnailHeight: CGFloat = 125
    static let cardHeight: CGFloat = Layout(thumbnailHeight: thumbnailHeight).cardHeight
    // 两张卡片之间只保留各自的图片内边距，不再额外叠加一段空隙。
    static let spacing: CGFloat = 0
    static let surfacePadding: CGFloat = 1
    static let surfaceTopPadding: CGFloat = 3
    static let rowPadding: CGFloat = 1
    static let windowButtonSize: CGFloat = 16
    static let windowButtonInset: CGFloat = 4
    // 按钮内缩 4 点、缩略图距玻璃边缘 6 点，逐层加上内缩量以对齐圆角。
    static let thumbnailRadius: CGFloat = windowButtonSize / 2 + windowButtonInset
    static let cardRadius: CGFloat = thumbnailRadius + 4
    static let surfaceRadius: CGFloat = cardRadius + surfacePadding + rowPadding

    static func cardWidth(for size: CGSize) -> CGFloat {
        Layout(thumbnailHeight: thumbnailHeight).cardWidth(for: size)
    }

    /// 过渡中的旧卡片仍可能发出悬停回调；用 PID 和 AX 身份保护当前卡片。
    func hover(_ preview: DockWindowPreview, inside: Bool) {
        guard visible, pid == preview.window.pid else { return }
        if inside {
            guard hoveredID != preview.id, windows.contains(where: { $0.id == preview.id }) else { return }
            hoveredID = preview.id
        } else {
            guard hoveredID == preview.id else { return }
            hoveredID = nil
        }
    }

    func clearHover() {
        guard hoveredID != nil else { return }
        hoveredID = nil
    }

    func releaseContent() {
        windows = []
        thumbnails = [:]
        appIcon = NSImage()
        appName = ""
        hoveredID = nil
        loading = false
        scrollOffset = 0
    }

    func size(screen: CGRect) -> CGSize {
        let total = windows.reduce(CGFloat(0)) {
            $0 + layout.cardWidth(for: Self.previewSize($1, image: thumbnails[$1.id]))
        }
            + CGFloat(max(windows.count - 1, 0)) * Self.spacing + 2 * (Self.surfacePadding + Self.rowPadding)
        let placeholder = layout.cardWidth(for: screen.size) + 2 * (Self.surfacePadding + Self.rowPadding)
        return CGSize(width: min(windows.isEmpty ? placeholder : total, max(1, min(900, screen.width - 24))),
                      height: layout.surfaceHeight)
    }

    static func height(hasWindows: Bool, recordingAllowed: Bool) -> CGFloat {
        surfaceHeight
    }
}

/// 单个浮窗在 Dock 应用之间复用；不会在悬停时抢走当前应用的键盘焦点。
final class DockPreviewPanel: NSPanel {
    static let margin: CGFloat = 36
    static let entryDuration: TimeInterval = 0.14
    static let flightDuration: TimeInterval = 0.25
    /// 高于普通窗口和其他功能面板，但让 Dock 的放大、提示和系统菜单正常覆盖它。
    static var presentationLevel: NSWindow.Level {
        AppPanelLevel.dockPreview
    }
    private let model: DockPreviewModel
    private var targetSurface: CGRect?
    private var canvasScreen: CGRect?
    // 在 SwiftUI 与原生玻璃之外变换整个 AppKit 子树，内容始终按最终尺寸布局。
    private let flight = DockFlightState()
    private var flightOrigin = CGPoint.zero
    private var flightRevision = 0
    var surfaceFrame: CGRect { targetSurface ?? frame.insetBy(dx: Self.margin, dy: Self.margin) }

    init(model: DockPreviewModel) {
        self.model = model
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        // isFloatingPanel 会重置层级；最终层级必须在 Dock 下方。
        level = Self.presentationLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // 浮窗不获取键盘焦点，但整棵视图及材质统一使用活动外观。
        let host = NSHostingView(rootView: DockFlightView(model: model, flight: flight)
            .environment(\.appearsActive, true)
            .materialActiveAppearance(.active))
        host.safeAreaRegions = []
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // 原生玻璃查询 AppKit 窗口的活动外观，SwiftUI 环境不能覆盖它。
    // 私有 selector 仅用于此非激活浮窗；不伪造 key/main 状态，也不移动键盘焦点。
    @objc(_hasActiveAppearance)
    private dynamic func dockHasActiveAppearance() -> Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// 查询窗口期间先准备所属屏幕的透明画布，不排序窗口或挂载预测应用的卡片。
    func prepareCanvas(screen: CGRect) {
        guard !isVisible, canvasScreen != screen else { return }
        canvasScreen = screen
        setFrame(screen.insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
        contentView?.layoutSubtreeIfNeeded()
    }

    /// 同一屏幕复用固定透明画布，只动画玻璃卡片的位置和尺寸。
    func prepareSurface(_ surface: CGRect, animated: Bool, screen: CGRect? = nil) {
        guard surface != targetSurface else { return }
        // 首次布局没有旧卡片，直接使用目标尺寸，避免零窗口的 inset 产生负尺寸。
        let previous = targetSurface ?? surface
        targetSurface = surface
        let fixedCanvas = screen ?? canvasScreen
        let canvas = fixedCanvas?.insetBy(dx: -Self.margin, dy: -Self.margin)
            ?? (animated ? frame.union(surface.insetBy(dx: -Self.margin, dy: -Self.margin))
                              : surface.insetBy(dx: -Self.margin, dy: -Self.margin)
            )
        canvasScreen = fixedCanvas
        var transaction = Transaction()
        transaction.disablesAnimations = true
        if frame != canvas {
            withTransaction(transaction) {
                model.surfaceRect = Self.local(previous, in: canvas)
                setFrame(canvas, display: true)
            }
        }
        // 调用者在统一动画事务中设置 surfaceRect 和应用内容。
        model.surfaceRect = Self.local(surface, in: canvas)
        model.contentWidth = surface.width
    }

    func setFlightOrigin(icon: CGRect, screen: CGRect, edge: DockPreviewGeometry.Edge) {
        flightOrigin = DockPreviewGeometry.flightOrigin(surface: surfaceFrame, icon: icon, screen: screen, edge: edge)
    }

    func prepareFlight() {
        flightRevision += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { updateFlight(visible: false) }
    }
    func animateFlight(visible: Bool, completion: (() -> Void)? = nil) {
        flightRevision += 1
        let token = flightRevision
        // 飞入与飞出等时，使用互为时间反向的系统缓出、缓入曲线。
        let animation: Animation = visible
            ? AppAnimation.easeOut(duration: Self.flightDuration)
            : AppAnimation.easeIn(duration: Self.flightDuration)
        withAnimation(animation, completionCriteria: .removed) { updateFlight(visible: visible) } completion: { [weak self] in
            guard self?.flightRevision == token else { return }
            completion?()
        }
    }
    func cancelFlight() {
        flightRevision += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { updateFlight(visible: true) }
    }
    private func updateFlight(visible: Bool) {
        flight.scale = visible ? 1 : DockPreviewGeometry.flightScale
        flight.opacity = visible ? 1 : 0
        flight.anchor = CGPoint(x: surfaceFrame.midX - frame.minX, y: frame.maxY - surfaceFrame.midY)
        flight.offset = visible ? .zero : CGSize(width: flightOrigin.x - surfaceFrame.midX,
                                                height: surfaceFrame.midY - flightOrigin.y)
    }

    private static func local(_ surface: CGRect, in canvas: CGRect) -> CGRect {
        CGRect(x: surface.minX - canvas.minX, y: canvas.maxY - surface.maxY,
               width: surface.width, height: surface.height)
    }
}

final class DockFlightState: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var opacity: Double = 1
    @Published var anchor = CGPoint.zero
    @Published var offset = CGSize.zero
}
struct DockFlightView: View {
    @ObservedObject var model: DockPreviewModel
    @ObservedObject var flight: DockFlightState
    var body: some View {
        GeometryReader { geometry in
            DockPreviewView(model: model)
                .scaleEffect(flight.scale, anchor: UnitPoint(x: flight.anchor.x / max(geometry.size.width, 1),
                                                           y: flight.anchor.y / max(geometry.size.height, 1)))
                .offset(flight.offset)
                .opacity(flight.opacity)
        }
    }
}

struct DockPreviewView: View {
    @ObservedObject var model: DockPreviewModel
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let snapshot = DockPreviewSnapshot(pid: model.pid, appName: model.appName, appIcon: model.appIcon,
                                           windows: model.windows, thumbnails: model.thumbnails,
                                           recordingAllowed: model.recordingAllowed, hoverState: model.hoverState,
                                           width: model.contentWidth, loading: model.loading, layout: model.layout,
                                           scrollOffset: model.scrollOffset, showWindowButtons: model.showWindowButtons,
                                           middleClickClose: model.middleClickClose)
        let flies = model.animation == .fly && !reduceMotion
        GlassEffectContainer(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if model.presented {
                    ZStack {
                        // 飞行动画保持玻璃与内容挂载，整体缩放和位移，避免叠加原生凝实过渡。
                        if model.visible || flies {
                            ZStack(alignment: .center) {
                                DockPreviewSurface(snapshot: snapshot, part: .labels, onChoose: model.onChoose,
                                                   onClose: model.onClose, onMinimize: model.onMinimize,
                                                   onHover: { _, _ in }, onOpenApp: model.onOpenApp, onScroll: { _ in })
                                    .frame(width: snapshot.width, height: snapshot.height)
                                    .id(DockPreviewSnapshot.LayerIdentity(content: snapshot.identity, thumbnails: false))
                                    .transition(reduceMotion ? .opacity : .panelContentDissolve)
                                    .allowsHitTesting(snapshot.windows.isEmpty)
                                DockPreviewSurface(snapshot: snapshot, part: .thumbnails, onChoose: model.onChoose,
                                                   onClose: model.onClose, onMinimize: model.onMinimize,
                                                   onHover: { model.hover($0, inside: $1) }, onOpenApp: model.onOpenApp,
                                                   onScroll: { if snapshot.pid == model.pid { model.scrollOffset = $0 } })
                                    .frame(width: snapshot.width, height: snapshot.height)
                                    .id(DockPreviewSnapshot.LayerIdentity(content: snapshot.identity, thumbnails: true))
                                    .transition(reduceMotion ? .opacity : .panelContentDissolve)
                                    .allowsHitTesting(!snapshot.windows.isEmpty)
                            }
                            // 内容由面板包住并裁切，玻璃直接附着在同一个内容容器上。
                            .frame(width: model.surfaceRect.width, height: model.surfaceRect.height, alignment: .center)
                            .clipShape(RoundedRectangle(cornerRadius: DockPreviewModel.surfaceRadius, style: .continuous))
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DockPreviewModel.surfaceRadius, style: .continuous))
                            .glassEffectID("dock-preview", in: glassNamespace)
                            .glassEffectTransition(reduceMotion || flies ? .identity : .materialize)
                            // 整体退场也显式消散；子层的内容切换过渡不会在父容器移除时自动播放。
                            .transition(reduceMotion ? .opacity : .panelContentDissolve)
                        }
                    }
                    .frame(width: model.surfaceRect.width, height: model.surfaceRect.height, alignment: .center)
                    .allowsHitTesting(model.visible)
                    .position(x: model.surfaceRect.midX, y: model.surfaceRect.midY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: model.pid) { _, _ in model.scrollOffset = 0 }
    }
}

/// 值快照让旧应用在淡出期间保留自己的标题和缩略图，不会瞬间换成新应用。
private struct DockPreviewSnapshot {
    let pid: pid_t
    let appName: String
    let appIcon: NSImage
    let windows: [DockWindowPreview]
    let thumbnails: [AXUIElement: NSImage]
    let recordingAllowed: Bool
    let hoverState: DockPreviewHoverState
    let width: CGFloat
    let loading: Bool
    let layout: DockPreviewModel.Layout
    let scrollOffset: CGFloat
    let showWindowButtons: Bool
    let middleClickClose: Bool
    var height: CGFloat {
        layout.surfaceHeight
    }
    var viewportWidth: CGFloat { max(width - 2 * DockPreviewModel.surfacePadding, 1) }
    var rowWidth: CGFloat {
        windows.reduce(2 * DockPreviewModel.rowPadding) { $0 + layout.cardWidth(for: previewSize($1)) }
            + CGFloat(max(windows.count - 1, 0)) * DockPreviewModel.spacing
    }
    func previewSize(_ window: DockWindowPreview) -> CGSize {
        DockPreviewModel.previewSize(window, image: thumbnails[window.id])
    }
    struct Identity: Hashable {
        let pid: pid_t
        let loading: Bool
        let windows: [AXUIElement]
    }
    struct LayerIdentity: Hashable {
        let content: Identity
        let thumbnails: Bool
    }
    var identity: Identity { Identity(pid: pid, loading: loading, windows: windows.map(\.id)) }
}

private struct DockPreviewSurface: View {
    enum Part { case labels, thumbnails }
    let snapshot: DockPreviewSnapshot
    let part: Part
    let onChoose: (DockWindowPreview) -> Void
    let onClose: (DockWindowPreview) -> Void
    let onMinimize: (DockWindowPreview) -> Void
    let onHover: (DockWindowPreview, Bool) -> Void
    let onOpenApp: () -> Void
    let onScroll: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if snapshot.windows.isEmpty {
                if part == .labels {
                    VStack(alignment: .leading, spacing: 6) {
                        header(snapshot.appName)
                        VStack(spacing: snapshot.layout.thumbnailHeight < 100 ? 4 : 10) {
                            if snapshot.loading {
                                ProgressView().controlSize(.small)
                                Text(L("正在读取窗口…"))
                            } else {
                                if snapshot.layout.thumbnailHeight >= 100 {
                                    Image(systemName: "macwindow").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                                }
                                Text(L("没有打开的窗口")).foregroundStyle(.secondary)
                                Button(L("打开应用"), action: onOpenApp).buttonStyle(.lightGlass)
                                    .controlSize(snapshot.layout.thumbnailHeight < 100 ? .small : .regular)
                            }
                        }
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .frame(height: snapshot.layout.thumbnailHeight)
                    }
                    .padding(4)
                    .frame(width: max(snapshot.width - 2 * (DockPreviewModel.surfacePadding + DockPreviewModel.rowPadding), 1),
                           height: snapshot.layout.cardHeight)
                    .padding(DockPreviewModel.rowPadding)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if part == .labels {
                GeometryReader { _ in
                    HStack(spacing: DockPreviewModel.spacing) {
                        ForEach(snapshot.windows) { window in card(window) }
                    }
                    .padding(DockPreviewModel.rowPadding)
                    .frame(width: max(snapshot.rowWidth, snapshot.viewportWidth), alignment: .center)
                    .offset(x: -snapshot.scrollOffset)
                }
                .frame(height: snapshot.layout.cardHeight + 2 * DockPreviewModel.rowPadding)
                .clipped()
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: DockPreviewModel.spacing) {
                        ForEach(snapshot.windows) { window in
                            ZStack(alignment: .topLeading) {
                                Button { onChoose(window) } label: { card(window) }
                                    .buttonStyle(.plain)
                                    .help(window.title)
                                    .accessibilityLabel(window.title)
                                if snapshot.showWindowButtons {
                                    HStack(spacing: 5) {
                                        windowButton("xmark", title: L("关闭窗口"), tint: DockWindowButtonStyle.closeColor) { onClose(window) }
                                        windowButton("minus", title: L("最小化窗口"), tint: DockWindowButtonStyle.minimizeColor) { onMinimize(window) }
                                            .disabled(window.minimized)
                                    }
                                    .padding(.top, 30 + DockPreviewModel.windowButtonInset)
                                    .padding(.leading, 4 + DockPreviewModel.windowButtonInset)
                                }
                            }
                            // 操作按钮是卡片按钮的同级视图，点击不会顺带激活窗口。
                            .frame(width: snapshot.layout.cardWidth(for: snapshot.previewSize(window)), height: snapshot.layout.cardHeight)
                            .contentShape(Rectangle())
                            .modifier(DockMiddleClickModifier(enabled: snapshot.middleClickClose) { onClose(window) })
                            .onHover { onHover(window, $0) }
                            .onDisappear { onHover(window, false) }
                        }
                    }
                    .padding(DockPreviewModel.rowPadding)
                    .frame(width: max(snapshot.rowWidth, snapshot.viewportWidth), alignment: .center)
                }
                // 尺寸变化保持内容中心；窗口较多时仍从第一张开始，允许横向滚动。
                .defaultScrollAnchor(snapshot.rowWidth > snapshot.viewportWidth ? .leading : .center, for: .sizeChanges)
                .defaultScrollAnchor(.center, for: .alignment)
                .scrollIndicators(.never)
                .scrollClipDisabled()
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in onScroll(offset) }
                .frame(height: snapshot.layout.cardHeight + 2 * DockPreviewModel.rowPadding)
            }
        }
        .padding(.horizontal, DockPreviewModel.surfacePadding)
        .padding(.top, DockPreviewModel.surfaceTopPadding)
        .padding(.bottom, DockPreviewModel.surfacePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func windowButton(_ symbol: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: DockPreviewModel.windowButtonSize, height: DockPreviewModel.windowButtonSize)
        }
        .buttonStyle(DockWindowButtonStyle(tint: tint))
        .help(title)
        .accessibilityLabel(title)
    }

    private func card(_ window: DockWindowPreview) -> some View {
        DockPreviewCard(snapshot: snapshot, window: window, part: part,
                        selection: snapshot.hoverState.selection(for: window.id))
    }

    private func header(_ title: String) -> some View {
        DockPreviewCardHeader(appIcon: snapshot.appIcon, title: title, minimized: false)
    }
}


/// 只有选择状态变化的卡片重算，标题层与图片层共用同一份状态。
private struct DockPreviewCard: View {
    let snapshot: DockPreviewSnapshot
    let window: DockWindowPreview
    let part: DockPreviewSurface.Part
    let selection: DockPreviewHoverState.Selection

    var body: some View {
        let selected = selection.selected
        let thumbnailWidth = max(snapshot.layout.cardWidth(for: snapshot.previewSize(window)) - 8, 1)
        return VStack(alignment: .leading, spacing: 6) {
            if part == .labels { DockPreviewCardHeader(appIcon: snapshot.appIcon, title: window.title, minimized: window.minimized) }
            else { Color.clear.frame(height: 20) }
            ZStack {
                if part == .thumbnails {
                    if let image = snapshot.thumbnails[window.id] {
                        Image(nsImage: image).resizable().scaledToFit()
                            .windowThumbnailBorder(cornerRadius: DockPreviewModel.thumbnailRadius)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: window.minimized ? "minus.rectangle" : "macwindow")
                                .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                            if !snapshot.recordingAllowed {
                                Text(L("开启屏幕录制可显示缩略图"))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(width: thumbnailWidth, height: snapshot.layout.thumbnailHeight, alignment: .center)
                    }
                }
            }
            .frame(width: thumbnailWidth, height: snapshot.layout.thumbnailHeight, alignment: .center)
            .windowThumbnailShadow(selected: selected && part == .thumbnails, subtle: true)
        }
        .padding(4)
        .frame(width: snapshot.layout.cardWidth(for: snapshot.previewSize(window)), height: snapshot.layout.cardHeight)
        .windowPreviewLift(selected: selected, subtle: true)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contentShape(RoundedRectangle(cornerRadius: DockPreviewModel.cardRadius, style: .continuous))
    }
}

private struct DockPreviewCardHeader: View {
    let appIcon: NSImage
    let title: String
    let minimized: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: appIcon)
                .resizable().frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(title).lineLimit(1).truncationMode(.middle)
            if minimized {
                Image(systemName: "minus.rectangle").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 20)
    }
}

/// 经典交通灯颜色直接作为原生玻璃的 tint，形状和交互均由系统渲染。
private struct DockWindowButtonStyle: ButtonStyle {
    static let closeColor = Color(red: 1, green: 95.0 / 255, blue: 87.0 / 255)
    static let minimizeColor = Color(red: 1, green: 189.0 / 255, blue: 46.0 / 255)
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.black.opacity(0.75) : Color.secondary)
            .contentShape(Circle())
            // 复用外层 spacing 为 0 的 GlassEffectContainer，保持两个圆彼此独立。
            .glassEffect(.clear.tint(isEnabled ? tint : nil).interactive(isEnabled), in: Circle())
    }
}


/// SwiftUI supplies geometry; AppKit only observes the unsupported middle mouse button.
struct DockMiddleClickModifier: ViewModifier {
    let enabled: Bool
    let onClose: () -> Void
    @StateObject private var monitor = DockMiddleClickMonitor()
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { monitor.rect = $0 }
            .onAppear { monitor.enabled = enabled; monitor.onClose = onClose; monitor.start() }
            .onChange(of: enabled) { _, value in monitor.enabled = value }
            .onDisappear { monitor.stop() }
    }
}
final class DockMiddleClickMonitor: ObservableObject {
    var rect = CGRect.zero
    var enabled = false
    var onClose: () -> Void = {}
    private var observer: Any?
    private var pressed = false
    func start() {
        guard observer == nil else { return }
        observer = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self, let panel = event.window as? DockPreviewPanel,
                  let content = panel.contentView else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            let visible = panel.surfaceFrame.contains(panel.convertPoint(toScreen: event.locationInWindow))
            return self.consumes(type: event.type, button: event.buttonNumber, point: point, visible: visible) ? nil : event
        }
    }
    func consumes(type: NSEvent.EventType, button: Int, point: CGPoint, visible: Bool) -> Bool {
        guard button == 2 else { return false }
        if type == .otherMouseUp, pressed { pressed = false; return true }
        guard type == .otherMouseDown, enabled, visible, rect.contains(point) else { return false }
        pressed = true; onClose(); return true
    }
    func stop() {
        if let observer { NSEvent.removeMonitor(observer) }
        observer = nil; pressed = false
    }
    deinit { stop() }
}

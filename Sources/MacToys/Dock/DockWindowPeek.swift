// SPDX-License-Identifier: MIT

import AppKit
import QuartzCore

/// 参考 HyperDock 的独立非激活面板、延迟悬停与过期结果取消；见 THIRD_PARTY_NOTICES.md。
/// 原位置截图只持有当前一张，不放大共享的低分辨率卡片，也不启动实时流。
struct DockWindowPeekSnapshot {
    let image: NSImage
    /// 窗口服务器坐标，与 AX 一样以主屏幕左上角为原点。
    let frame: CGRect

    static func pixelSize(for size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
    }
}

final class DockWindowPeekController {
    typealias Capture = @MainActor (pid_t, CGWindowID) async -> DockWindowPeekSnapshot?
    private let surface: DockWindowPeekSurface
    private let capture: Capture
    private let schedule: WindowThumbnailStore.Schedule
    private let show: (DockWindowPeekSnapshot) -> Void
    private let dismiss: () -> Void
    private var target: WindowThumbnailStore.Key?
    private var revision = 0
    private var cancelDelay: (() -> Void)?
    private var task: Task<Void, Never>?

    /// UI 在首次成功截图时才分配；测试可注入截图、计时与展示边界。
    init(capture: @escaping Capture = { await WindowThumbnailStore.shared.peekSnapshot(pid: $0, windowID: $1) },
         schedule: @escaping WindowThumbnailStore.Schedule = WindowThumbnailStore.after,
         show: ((DockWindowPeekSnapshot) -> Void)? = nil, dismiss: (() -> Void)? = nil) {
        self.capture = capture
        self.schedule = schedule
        let surface = DockWindowPeekSurface()
        self.surface = surface
        self.show = show ?? { surface.show($0) }
        self.dismiss = dismiss ?? { surface.hide() }
    }

    func apply(borderWidth: Double, cornerRadius: Double) {
        surface.borderWidth = CGFloat(DockConfig.normalizedPeekBorderWidth(borderWidth))
        surface.cornerRadius = CGFloat(DockConfig.normalizedPeekCornerRadius(cornerRadius))
        surface.applyStyle()
    }

    func hover(pid: pid_t, windowID: CGWindowID) {
        let key = WindowThumbnailStore.Key(pid: pid, windowID: windowID)
        guard target != key else { return }
        hide()
        target = key
        let ticket = revision
        // 快速横穿卡片不截图；没有轮询或逐帧任务。
        cancelDelay = schedule(0.25) { [weak self] in
            guard let self, self.revision == ticket, self.target == key else { return }
            self.cancelDelay = nil
            self.task = Task { @MainActor [weak self] in
                guard let self else { return }
                let snapshot = await self.capture(pid, windowID)
                guard !Task.isCancelled, self.revision == ticket, self.target == key else { return }
                self.task = nil
                if let snapshot { self.show(snapshot) }
            }
        }
    }

    func hide() {
        revision += 1
        target = nil
        cancelDelay?()
        cancelDelay = nil
        task?.cancel()
        task = nil
        dismiss()
    }

    deinit {
        cancelDelay?()
        task?.cancel()
    }
}

private final class DockWindowPeekSurface {
    private var panel: DockWindowPeekPanel?
    var borderWidth: CGFloat = 5
    var cornerRadius: CGFloat = 10

    func applyStyle() {
        panel?.apply(borderPixels: borderWidth, cornerRadius: cornerRadius)
    }

    func show(_ snapshot: DockWindowPeekSnapshot) {
        let frame = ScreenGeometry.appKitRect(snapshot.frame)
        guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
              frame.width > 0, frame.height > 0,
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { hide(); return }
        let panel = self.panel ?? DockWindowPeekPanel()
        self.panel = panel
        applyStyle()
        // 不夹紧到主屏或移动到缩略图附近；多屏和跨屏窗口保留原始矩形。
        panel.present(image: snapshot.image, windowFrame: frame)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.imageView.image = nil
    }
}

final class DockWindowPeekPanel: NSPanel, NSWindowDelegate {
    let imageView = NSImageView()
    private let borderView = NSView()
    private(set) var borderPixels: CGFloat = 5
    private(set) var cornerRadius: CGFloat = 10

    func apply(borderPixels: CGFloat, cornerRadius: CGFloat) {
        self.borderPixels = CGFloat(DockConfig.normalizedPeekBorderWidth(Double(borderPixels)))
        self.cornerRadius = CGFloat(DockConfig.normalizedPeekCornerRadius(Double(cornerRadius)))
        updateGeometry()
    }
    static let borderColor = NSColor(srgbRed: 0.45, green: 0.78, blue: 1, alpha: 1)
    private var windowFrame: CGRect?
    private var updatingGeometry = false

    static func borderWidth(scale: CGFloat, pixels: CGFloat = 5) -> CGFloat { pixels / max(1, scale) }

    func present(image: NSImage, windowFrame: CGRect) {
        self.windowFrame = windowFrame
        imageView.image = image
        setFrame(windowFrame, display: false)
        updateGeometry()
    }

    private func updateGeometry() {
        guard let windowFrame, !updatingGeometry else { return }
        updatingGeometry = true
        defer { updatingGeometry = false }
        let scale = screen?.backingScaleFactor ?? backingScaleFactor
        let width = Self.borderWidth(scale: scale, pixels: borderPixels)
        // NSWindow 会对齐外框到整点；内容反向补偿，保持 Retina 像素与原窗口对齐。
        let outer = windowFrame.insetBy(dx: -width, dy: -width)
        setFrame(CGRect(x: floor(outer.minX), y: floor(outer.minY),
                        width: ceil(outer.maxX) - floor(outer.minX),
                        height: ceil(outer.maxY) - floor(outer.minY)), display: false)
        imageView.frame = CGRect(x: windowFrame.minX - frame.minX, y: windowFrame.minY - frame.minY,
                                 width: windowFrame.width, height: windowFrame.height)
        borderView.frame = CGRect(origin: .zero, size: frame.size)
        let radius = min(cornerRadius, min(windowFrame.width, windowFrame.height) / 2)
        imageView.layer?.cornerRadius = radius
        if let border = borderView.layer as? CAShapeLayer {
            border.lineWidth = width
            border.path = CGPath(roundedRect: imageView.frame.insetBy(dx: -width / 2, dy: -width / 2),
                                 cornerWidth: radius + width / 2, cornerHeight: radius + width / 2, transform: nil)
            border.contentsScale = scale
        }
        imageView.layer?.contentsScale = scale
    }

    func windowDidChangeBackingProperties(_ notification: Notification) { updateGeometry() }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        delegate = self
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: DockPreviewPanel.presentationLevel.rawValue - 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        let container = NSView()
        container.addSubview(imageView)
        let border = CAShapeLayer()
        border.strokeColor = Self.borderColor.cgColor
        border.fillColor = NSColor.clear.cgColor
        borderView.layer = border
        borderView.wantsLayer = true
        container.addSubview(borderView)
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

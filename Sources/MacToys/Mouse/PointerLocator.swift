// SPDX-License-Identifier: MIT
import AppKit
import QuartzCore

/// PowerToys-style spotlight: dim the desktop as a clear circle closes around
/// the pointer. Position updates are synchronized with the fastest display.
final class PointerLocator {
    private var panels: [PointerLocatorPanel] = []
    private var shades: [CAShapeLayer] = []
    private var tracking: CADisplayLink?
    private let displayTarget = PointerLocatorDisplayTarget()
    private var autoDismissal: DispatchWorkItem?
    private var dismissal: DispatchWorkItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastPoint = NSPoint.zero
    private var outerBounds = CGRect.zero
    private var reducedMotion = false
    private var dismissing = false

    private static let radius: CGFloat = 100
    private static let initialRadius: CGFloat = 900
    private static let duration: TimeInterval = 0.5

    var isVisible: Bool { panels.contains { $0.isVisible } }

    func show(duration: TimeInterval = 3) {
        stop()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let desktop = screens.reduce(CGRect.null) { $0.union($1.frame) }
        // Each shade is centered on the pointer; its outer rectangle must cover
        // every display even when the pointer sits at the opposite desktop edge.
        let extent = max(desktop.width, desktop.height) + Self.initialRadius
        outerBounds = CGRect(x: -extent, y: -extent, width: extent * 2, height: extent * 2)
        lastPoint = NSEvent.mouseLocation
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = CACurrentMediaTime()

        for screen in screens {
            let panel = PointerLocatorPanel(contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            panel.contentView = view
            guard let root = view.layer else { panel.close(); continue }
            root.masksToBounds = true

            let shade = CAShapeLayer()
            shade.bounds = outerBounds
            shade.position = CGPoint(x: lastPoint.x - screen.frame.minX, y: lastPoint.y - screen.frame.minY)
            shade.fillRule = .evenOdd
            shade.fillColor = NSColor.black.withAlphaComponent(0.5).cgColor
            shade.path = path(radius: Self.radius)
            root.addSublayer(shade)
            animate(shade, entering: true, at: now)
            shades.append(shade)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        guard !panels.isEmpty else { return }
        installDismissMonitors()
        guard let screen = screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) else { return }
        displayTarget.update = { [weak self] in self?.trackPointer() }
        let tracking = screen.displayLink(target: displayTarget, selector: #selector(PointerLocatorDisplayTarget.refresh(_:)))
        let frameRate = Float(screen.maximumFramesPerSecond)
        tracking.preferredFrameRateRange = CAFrameRateRange(minimum: frameRate, maximum: frameRate, preferred: frameRate)
        self.tracking = tracking
        tracking.add(to: .main, forMode: .common)
        // Count only the focused interval, after the entrance animation finishes.
        // This deadline is independent of pointer tracking and never resets on movement.
        let focusedDuration = MouseConfig.normalizedLocatePointerDuration(duration)
        let deadline = now + (reducedMotion ? 0.15 : Self.duration) + focusedDuration
        let autoDismissal = DispatchWorkItem { [weak self] in self?.dismiss() }
        self.autoDismissal = autoDismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - CACurrentMediaTime()), execute: autoDismissal)
    }

    private func path(radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(outerBounds)
        path.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        return path
    }

    private func animate(_ shade: CAShapeLayer, entering: Bool, at time: TimeInterval) {
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = entering ? 0 : (shade.presentation()?.opacity ?? 1)
        opacity.toValue = entering ? 1 : 0
        let group = CAAnimationGroup()
        if reducedMotion {
            group.animations = [opacity]
        } else {
            let aperture = CABasicAnimation(keyPath: "path")
            aperture.fromValue = entering ? path(radius: Self.initialRadius) : (shade.presentation()?.path ?? shade.path)
            aperture.toValue = path(radius: entering ? Self.radius : Self.initialRadius)
            group.animations = [opacity, aperture]
        }
        // Radius and darkness change together, matching the PowerToys zoom.
        group.duration = reducedMotion ? 0.15 : Self.duration
        group.beginTime = time
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.opacity = entering ? 1 : 0
        shade.add(group, forKey: "spotlight")
        CATransaction.commit()
    }

    private func trackPointer() {
        let point = NSEvent.mouseLocation
        if point != lastPoint {
            lastPoint = point
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (panel, shade) in zip(panels, shades) {
                shade.position = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
            }
            CATransaction.commit()
        }
    }

    private func installDismissMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.dismiss() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismiss()
            return event
        }
    }

    private func dismiss() {
        guard !panels.isEmpty, !dismissing else { return }
        dismissing = true
        stopTracking()
        let now = CACurrentMediaTime()
        shades.forEach { animate($0, entering: false, at: now) }
        let dismissal = DispatchWorkItem { [weak self] in self?.stop() }
        self.dismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + (reducedMotion ? 0.15 : Self.duration), execute: dismissal)
    }

    private func stopTracking() {
        autoDismissal?.cancel()
        autoDismissal = nil
        tracking?.invalidate()
        tracking = nil
        displayTarget.update = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func stop() {
        stopTracking()
        dismissal?.cancel()
        dismissal = nil
        panels.forEach { $0.close() }
        panels.removeAll()
        shades.removeAll()
        dismissing = false
    }
}

/// CADisplayLink retains its target. Keep the owner weak through the callback so
/// stopping the effect releases the display link without a controller cycle.
private final class PointerLocatorDisplayTarget: NSObject {
    var update: (() -> Void)?
    @objc func refresh(_ sender: CADisplayLink) { update?() }
}

private final class PointerLocatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

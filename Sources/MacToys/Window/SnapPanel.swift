// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 分屏的目标预览和窗口选择共用同一块玻璃，透明留白让高光在窗口内完整衰减。
final class SnapPanel: NSPanel {
    static let glassMargin: CGFloat = 32
    var onResignKey: () -> Void = {}

    init(interactive: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = !interactive
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        setSurfaceContent(Color.clear)
    }

    var surfaceFrame: CGRect { frame.insetBy(dx: Self.glassMargin, dy: Self.glassMargin) }

    func setSurfaceContent<Content: View>(_ content: Content) {
        let host = NSHostingView(rootView: content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(Self.glassMargin))
        host.safeAreaRegions = []
        contentView = host
    }

    func setSurfaceFrame(_ frame: CGRect, animated: Bool = false) {
        let windowFrame = frame.insetBy(dx: -Self.glassMargin, dy: -Self.glassMargin)
        if animated {
            animator().setFrame(windowFrame, display: true)
        } else {
            setFrame(windowFrame, display: true)
        }
    }

    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }

    // 留白可以越过屏幕边缘；系统若把整个透明窗口压回可见区，玻璃会向下错开一截。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }
}

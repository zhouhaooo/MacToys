// SPDX-License-Identifier: MIT

import CoreGraphics

/// 按可见卡片定位，透明阴影空间不参与光标间距或屏幕限制。
enum ClipboardPanelPosition {
    static func frame(anchor: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        let area = visible.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 6
        let candidates = [
            CGPoint(x: anchor.minX, y: anchor.minY - size.height - gap),
            CGPoint(x: anchor.minX, y: anchor.maxY + gap),
            CGPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2),
            CGPoint(x: anchor.minX - size.width - gap, y: anchor.midY - size.height / 2),
        ]
        func clamped(_ origin: CGPoint) -> CGRect {
            CGRect(x: min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width)),
                   y: min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height)),
                   width: size.width, height: size.height)
        }
        // 能完整放在下方或上方时优先，横向只做边缘修正。
        for origin in candidates.prefix(2) {
            if origin.y >= area.minY && origin.y + size.height <= area.maxY {
                return clamped(origin)
            }
        }
        // 上下都放不下：侧边就近放置，避免把光标夹在面板中间。
        for origin in candidates.suffix(2) {
            if origin.x >= area.minX && origin.x + size.width <= area.maxX {
                return clamped(origin)
            }
        }
        // 空间受限时选择离光标最近且遮挡最少的位置。
        return candidates.map(clamped).min { lhs, rhs in
            score(lhs, anchor: anchor) < score(rhs, anchor: anchor)
        } ?? clamped(candidates[0])
    }

    private static func score(_ frame: CGRect, anchor: CGRect) -> CGFloat {
        let point = CGPoint(x: anchor.midX, y: anchor.midY)
        let dx = max(frame.minX - point.x, point.x - frame.maxX, 0)
        let dy = max(frame.minY - point.y, point.y - frame.maxY, 0)
        let overlap = frame.intersects(anchor.insetBy(dx: -2, dy: -2)) ? CGFloat(10000) : 0
        return overlap + dx * dx + dy * dy
    }
}

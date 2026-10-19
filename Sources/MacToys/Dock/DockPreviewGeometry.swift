// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// 可见卡片的定位和悬停时序，与窗口透明阴影空间分开。
enum DockPreviewGeometry {
    enum Edge { case bottom, left, right }

    static let flightScale: CGFloat = 0.18

    /// 缩小后的整块预览完全藏到 Dock 所在的屏幕边缘外；双屏和负坐标仍以所属屏幕为准。
    static func flightOrigin(surface: CGRect, icon: CGRect, screen: CGRect, edge: Edge) -> CGPoint {
        let gap: CGFloat = 8
        switch edge {
        case .bottom:
            return CGPoint(x: icon.midX, y: screen.minY - surface.height * flightScale / 2 - gap)
        case .left:
            return CGPoint(x: screen.minX - surface.width * flightScale / 2 - gap, y: icon.midY)
        case .right:
            return CGPoint(x: screen.maxX + surface.width * flightScale / 2 + gap, y: icon.midY)
        }
    }

    /// AX 列表覆盖整条 Dock；向所属屏幕边缘补齐，包含底座和图标间隙。
    static func dockRegion(frame: CGRect, edge: Edge, screen: CGRect) -> CGRect {
        var region = frame.insetBy(dx: -6, dy: -6)
        switch edge {
        case .bottom:
            region.size.height = region.maxY - screen.minY
            region.origin.y = screen.minY
        case .left:
            region.size.width = region.maxX - screen.minX
            region.origin.x = screen.minX
        case .right:
            region.size.width = screen.maxX - region.minX
        }
        return region.intersection(screen)
    }

    static func surface(size: CGSize, icon: CGRect, screen: CGRect, edge: Edge, bottomY: CGFloat? = nil) -> CGRect {
        let gap: CGFloat = 12
        let size = CGSize(width: min(size.width, max(screen.width - 16, 1)),
                          height: min(size.height, max(screen.height - 16, 1)))
        var origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: icon.midX - size.width / 2, y: bottomY ?? (icon.maxY + gap))
        case .left: origin = CGPoint(x: icon.maxX + gap, y: icon.midY - size.height / 2)
        case .right: origin = CGPoint(x: icon.minX - size.width - gap, y: icon.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        return CGRect(origin: origin, size: size)
    }

    static func keepsOpen(point: CGPoint, icon: CGRect, surface: CGRect) -> Bool {
        // 包含图标到预览的通道，让鼠标越过间隙时不会先关闭面板。
        icon.union(surface).insetBy(dx: -6, dy: -6).contains(point)
    }

    /// 图标到玻璃卡片的缝隙通道；随方向插值宽度，避免覆盖整个包围矩形。
    static func isPassage(point: CGPoint, icon: CGRect, surface: CGRect) -> Bool {
        let margin: CGFloat = 6
        if icon.contains(point)
            || surface.contains(point) { return false }
        func between(_ along: CGFloat, start: CGFloat, end: CGFloat,
                     across: CGFloat, first: ClosedRange<CGFloat>, last: ClosedRange<CGFloat>) -> Bool {
            guard end > start, along >= start - margin, along <= end + margin else { return false }
            let progress = min(1, max(0, (along - start) / (end - start)))
            let lower = first.lowerBound + (last.lowerBound - first.lowerBound) * progress
            let upper = first.upperBound + (last.upperBound - first.upperBound) * progress
            return across >= lower - margin && across <= upper + margin
        }
        if surface.minY >= icon.maxY {
            return between(point.y, start: icon.maxY, end: surface.minY, across: point.x,
                           first: icon.minX...icon.maxX, last: surface.minX...surface.maxX)
        }
        if surface.minX >= icon.maxX {
            return between(point.x, start: icon.maxX, end: surface.minX, across: point.y,
                           first: icon.minY...icon.maxY, last: surface.minY...surface.maxY)
        }
        if icon.minX >= surface.maxX {
            return between(-point.x, start: -icon.minX, end: -surface.maxX, across: point.y,
                           first: icon.minY...icon.maxY, last: surface.minY...surface.maxY)
        }
        return false
    }

    /// 用当前指针是否仍在命中的图标内判断结果新旧，不按移动距离丢弃有效命中。
    static func acceptsResolvedHit(frame: CGRect, pointer: CGPoint) -> Bool {
        frame.insetBy(dx: -3, dy: -3).contains(pointer)
    }
}

/// 底部 Dock 在一次预览会话中共用纵向锚点，图标放大和应用切换只影响横坐标。
struct DockPreviewPlacement {
    private var bottomAnchor: (screen: CGRect, y: CGFloat)?

    mutating func surface(size: CGSize, icon: CGRect, screen: CGRect, visibleFrame: CGRect,
                          edge: DockPreviewGeometry.Edge) -> CGRect {
        let bottomY = bottomAnchor.flatMap { $0.screen == screen ? $0.y : nil }
        let surface = DockPreviewGeometry.surface(size: size, icon: icon, screen: visibleFrame,
                                                  edge: edge, bottomY: bottomY)
        if case .bottom = edge {
            bottomAnchor = (screen, surface.minY)
        } else {
            bottomAnchor = nil
        }
        return surface
    }

    mutating func reset() { bottomAnchor = nil }
}

/// 仅外推最近 120 毫秒内的移动；远离边缘、跨屏或停顿后不猜目标。
struct DockPointerPrediction {
    private var previous: (point: CGPoint, time: TimeInterval)?

    mutating func target(point: CGPoint, now: TimeInterval, screens: [CGRect]) -> CGPoint? {
        defer { previous = (point, now) }
        guard let previous, let screen = screens.first(where: { $0.contains(point) }),
              screen.contains(previous.point) else { return nil }
        let elapsed = now - previous.time
        guard elapsed >= 1.0 / 240, elapsed <= 0.12 else { return nil }
        let dx = point.x - previous.point.x, dy = point.y - previous.point.y
        let distance = hypot(dx, dy)
        guard distance >= 2 else { return nil }
        let factor = min(0.12 / elapsed, 160 / distance)
        // 快速移向边缘时落在图标所在的带状区域，避免外推到图标下方的屏幕最边缘。
        let target = CGPoint(x: min(max(point.x + dx * factor, screen.minX + 32), screen.maxX - 32),
                             y: min(max(point.y + dy * factor, screen.minY + 32), screen.maxY - 1))
        func edgeDistance(_ p: CGPoint) -> CGFloat {
            min(p.y - screen.minY, p.x - screen.minX, screen.maxX - p.x)
        }
        let currentDistance = edgeDistance(point), targetDistance = edgeDistance(target)
        guard currentDistance < 220, targetDistance < 160, targetDistance <= currentDistance + 2 else { return nil }
        return target
    }

    mutating func reset() { previous = nil }
}

struct DockHoverState {
    private(set) var pendingPID: Int32?
    private var outsideAt: TimeInterval?

    mutating func shouldShow(pid: Int32, current: Int32?, now: TimeInterval) -> Bool {
        if current == pid { pendingPID = nil; outsideAt = nil; return false }
        // 实际命中即可显示；窗口清单是否就绪由控制器判断，不再另等悬停确认。
        pendingPID = pid
        return true
    }

    mutating func shouldHide(inside: Bool, onDock: Bool = true, now: TimeInterval) -> Bool {
        pendingPID = nil
        return trackPresence(inside: inside, onDock: onDock, now: now)
    }

    /// 离开计时独立于新图标的窗口查询；经过空 App 不重置、不提前结束这段时间。
    mutating func trackPresence(inside: Bool, onDock: Bool = true, now: TimeInterval) -> Bool {
        if inside { outsideAt = nil; return false }
        if !onDock { outsideAt = nil; return true }
        if outsideAt == nil { outsideAt = now }
        return now - (outsideAt ?? now) >= 1
    }

    var nextDeadline: TimeInterval? {
        outsideAt.map { $0 + 1 }
    }

    mutating func reset() { self = DockHoverState() }
}

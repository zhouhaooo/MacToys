// SPDX-License-Identifier: MIT

import AppKit

/// 鼠标按下时的系统窗口。先读 Window Server 的位置，不依赖标题栏或内容控件的 AX 层级。
struct WindowDragSnapshot {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect

    private init?(info: [String: Any]) {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds), !frame.isEmpty,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
        self.id = id
        self.pid = pid
        self.frame = frame
    }

    static func under(_ point: CGPoint, windowID: CGWindowID?) -> WindowDragSnapshot? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // 事件给出的编号优先；模拟事件或部分自绘窗口没有编号，才按前后顺序找。
        if let windowID, let info = list.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }),
           let snapshot = Self(info: info), snapshot.frame.insetBy(dx: -2, dy: -2).contains(point) {
            return snapshot
        }
        return list.lazy.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { Self(info: $0) }.first { $0.frame.contains(point) }
    }

    /// 只查询按下时锁定的窗口；鼠标到了边缘、经过别的窗口时不重新命中测试。
    var currentFrame: CGRect? {
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        return list.first.flatMap { Self(info: $0)?.frame }
    }
}

/// 根据窗口实际位置、大小和鼠标变化识别移动，拖动起点可以在窗口的任何位置。
struct WindowDragMotion {
    enum Phase: Equatable { case waiting, moving, resizing }

    private var referenceFrame: CGRect
    private let startCursor: CGPoint
    private(set) var phase: Phase = .waiting

    init(frame: CGRect, cursor: CGPoint) {
        referenceFrame = frame
        startCursor = cursor
    }

    @discardableResult
    mutating func update(frame: CGRect, cursor: CGPoint) -> Phase {
        guard phase != .resizing else { return phase }
        // 容忍 Window Server 与 AX 的坐标舍入；从左上角改大小也会改变位置，必须先排除。
        if abs(frame.width - referenceFrame.width) > 2 || abs(frame.height - referenceFrame.height) > 2 {
            phase = .resizing
        } else if phase == .waiting,
                  max(abs(cursor.x - startCursor.x), abs(cursor.y - startCursor.y)) >= 2,
                  max(abs(frame.minX - referenceFrame.minX), abs(frame.minY - referenceFrame.minY)) >= 2 {
            phase = .moving
        }
        return phase
    }

    /// 分屏窗口被我们恢复大小后，接着跟踪同一次拖动。
    mutating func rebase(afterRestoring frame: CGRect) {
        referenceFrame = frame
    }
}

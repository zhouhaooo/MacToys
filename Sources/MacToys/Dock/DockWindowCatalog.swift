// SPDX-License-Identifier: MIT

import AppKit

/// AX 决定有哪些可恢复的窗口；窗口服务器只补充大小、截图编号和前后顺序。
enum DockWindowCatalog {
    struct Snapshot {
        let window: WindowElement
        let windowID: CGWindowID?
        let title: String?
        let size: CGSize?
        let isStandard: Bool
        let minimized: Bool
    }

    static func previews(_ snapshots: [Snapshot], appName: String,
                         serverWindows: [[String: Any]]) -> [DockWindowPreview] {
        var order: [CGWindowID: Int] = [:]
        var serverSizes: [CGWindowID: CGSize] = [:]
        for (index, info) in serverWindows.enumerated() {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            order[id] = index
            if let bounds = info[kCGWindowBounds as String] as? NSDictionary,
               let frame = CGRect(dictionaryRepresentation: bounds) {
                serverSizes[id] = frame.size
            }
        }
        var seen = Set<AXUIElement>()
        return snapshots.enumerated().compactMap { index, snapshot -> (Int, DockWindowPreview)? in
            guard snapshot.isStandard || snapshot.minimized,
                  let size = previewSize(axSize: snapshot.size,
                                         serverSize: snapshot.windowID.flatMap { serverSizes[$0] },
                                         minimized: snapshot.minimized),
                  seen.insert(snapshot.window.element).inserted else { return nil }
            let preview = DockWindowPreview(windowID: snapshot.windowID, window: snapshot.window,
                                            title: snapshot.title.flatMap { $0.isEmpty ? nil : $0 } ?? appName,
                                            size: size, minimized: snapshot.minimized)
            return (index, preview)
        }.sorted { lhs, rhs in
            let left = lhs.1.windowID.flatMap { order[$0] } ?? Int.max
            let right = rhs.1.windowID.flatMap { order[$0] } ?? Int.max
            return left == right ? lhs.0 < rhs.0 : left < right
        }.map { $0.1 }
    }

    private static func previewSize(axSize: CGSize?, serverSize: CGSize?, minimized: Bool) -> CGSize? {
        for size in [axSize, serverSize].compactMap({ $0 }) {
            if size.width.isFinite, size.height.isFinite, size.width >= 60, size.height >= 40 { return size }
        }
        // 已确认最小化的窗口仍可点击恢复，无尺寸时用默认比例显示占位卡片。
        return minimized ? CGSize(width: 640, height: 400) : nil
    }
}

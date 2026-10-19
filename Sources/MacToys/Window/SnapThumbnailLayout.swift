// SPDX-License-Identifier: MIT

import CoreGraphics

/// 等高、按窗口比例分配宽度的换行布局。显示和方向键导航共用同一份排列。
struct SnapThumbnailLayout {
    static let thumbnailHeight: CGFloat = 144
    static let spacing: CGFloat = 14
    let widths: [CGFloat]
    let rows: [[Int]]

    init(sizes: [CGSize], width: CGFloat) {
        let available = max(width, 1)
        widths = sizes.map { size in
            let ratio = max(size.width, 1) / max(size.height, 1)
            return min(available, max(88, Self.thumbnailHeight * ratio + 8))
        }
        var rows: [[Int]] = []
        var row: [Int] = []
        var used: CGFloat = 0
        for index in widths.indices {
            let next = widths[index] + (row.isEmpty ? 0 : Self.spacing)
            if !row.isEmpty, used + next > available {
                rows.append(row)
                row = []
                used = 0
            }
            used += widths[index] + (row.isEmpty ? 0 : Self.spacing)
            row.append(index)
        }
        if !row.isEmpty { rows.append(row) }
        self.rows = rows
    }

    func neighbor(of index: Int, direction: Int) -> Int? {
        guard let row = rows.firstIndex(where: { $0.contains(index) }),
              rows.indices.contains(row + direction) else { return nil }
        func centers(in row: [Int]) -> [Int: CGFloat] {
            let total = row.reduce(CGFloat(0)) { $0 + widths[$1] } + CGFloat(max(row.count - 1, 0)) * Self.spacing
            var x = -total / 2
            var centers: [Int: CGFloat] = [:]
            for item in row {
                centers[item] = x + widths[item] / 2
                x += widths[item] + Self.spacing
            }
            return centers
        }
        guard let x = centers(in: rows[row])[index] else { return nil }
        return centers(in: rows[row + direction]).min { abs($0.value - x) < abs($1.value - x) }?.key
    }
}

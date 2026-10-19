// SPDX-License-Identifier: MIT

import CoreGraphics
import Testing
@testable import MacToys

@Suite("窗口缩略图换行")
struct SnapThumbnailLayoutTests {
    @Test func preservesProportionsAndFitsEveryRow() {
        let sizes = [CGSize(width: 900, height: 900), CGSize(width: 1800, height: 900),
                     CGSize(width: 450, height: 900), CGSize(width: 900, height: 900)]
        let layout = SnapThumbnailLayout(sizes: sizes, width: 510)
        #expect(layout.widths == [152, 296, 88, 152])
        #expect(layout.rows == [[0, 1], [2, 3]])
        for row in layout.rows {
            let width = row.reduce(CGFloat(0)) { $0 + layout.widths[$1] }
                + CGFloat(max(row.count - 1, 0)) * SnapThumbnailLayout.spacing
            #expect(width <= 510)
        }
        #expect(layout.neighbor(of: 0, direction: 1) == 2)
        #expect(layout.neighbor(of: 1, direction: 1) == 3)
        #expect(layout.neighbor(of: 3, direction: -1) == 1)
        #expect(layout.neighbor(of: 0, direction: -1) == nil)
    }

    @Test func narrowPanelsAndEmptyLists() {
        let layout = SnapThumbnailLayout(sizes: [.init(width: 4000, height: 500), .zero], width: 120)
        #expect(layout.widths == [120, 120])
        #expect(layout.rows == [[0], [1]])
        #expect(SnapThumbnailLayout(sizes: [], width: 120).rows.isEmpty)
    }
}

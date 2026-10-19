// SPDX-License-Identifier: MIT
import CoreGraphics
import Testing
@testable import MacToys

@Suite("剪贴板就近定位")
struct ClipboardPanelPositionTests {
    let size = CGSize(width: 400, height: 460)

    @Test func usesBelowOrAboveWhenThereIsRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let high = CGRect(x: 500, y: 800, width: 1, height: 20)
        let below = ClipboardPanelPosition.frame(anchor: high, size: size, visible: visible)
        #expect(below.maxY == high.minY - 6)
        let low = CGRect(x: 500, y: 100, width: 1, height: 20)
        let above = ClipboardPanelPosition.frame(anchor: low, size: size, visible: visible)
        #expect(above.minY == low.maxY + 6)
    }

    @Test func prefersNearSideWhenNeitherAboveNorBelowFits() {
        let anchor = CGRect(x: 500, y: 350, width: 1, height: 20)
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 760)
        let frame = ClipboardPanelPosition.frame(anchor: anchor, size: size, visible: visible)
        #expect(frame.minX == anchor.maxX + 6)
        #expect(!frame.intersects(anchor) && visible.contains(frame))
    }

    @Test func clampsWithinSecondaryScreenWithNegativeOrigin() {
        let visible = CGRect(x: -1280, y: 100, width: 1280, height: 780)
        let anchor = CGRect(x: -25, y: 120, width: 1, height: 20)
        let frame = ClipboardPanelPosition.frame(anchor: anchor, size: size, visible: visible)
        #expect(visible.contains(frame))
        #expect(frame.maxX == visible.maxX - 8)
    }
}

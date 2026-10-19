import AppKit
import Testing
@testable import MacToys

struct ClipboardPanelLayoutTests {
    private func item(_ kind: ClipboardItem.Kind = .text) -> ClipboardItem {
        ClipboardItem(id: UUID(), kind: kind, text: "Clipboard", extraFiles: [:], fingerprint: UUID().uuidString,
                      created: .now, lastUsed: .now)
    }

    @Test func fewResultsFitWithoutTheOldEmptyCanvas() {
        let one = ClipboardPanelLayout.size(for: [item()])
        let two = ClipboardPanelLayout.size(for: [item(), item()])
        #expect(one.width == ClipboardPanel.size.width)
        #expect(one.height < 260 && two.height > one.height)
        #expect(ClipboardPanelLayout.size(for: []).height < ClipboardPanel.size.height)
    }

    @Test func imagesHaveRoomAndLongListsAreCapped() {
        let text = ClipboardPanelLayout.size(for: [item()])
        let image = ClipboardPanelLayout.size(for: [item(.image)])
        #expect(image.height - text.height == 40)
        #expect(ClipboardPanelLayout.size(for: (0..<200).map { _ in item(.image) }) == ClipboardPanel.size)
    }
    @Test func measuredWrappedTextGrowsPanelUntilScrollLimit() {
        let text = item()
        let short = ClipboardPanelLayout.size(for: [text])
        let wrapped = ClipboardPanelLayout.size(for: [text], rowHeights: [text.id: 120])
        #expect(wrapped.height > short.height)
        #expect(wrapped.height == ClipboardPanelLayout.headerHeight + 136 + ClipboardPanelLayout.footerHeight)
        #expect(ClipboardPanelLayout.size(for: [text], rowHeights: [text.id: 1000]) == ClipboardPanel.size)
    }
}

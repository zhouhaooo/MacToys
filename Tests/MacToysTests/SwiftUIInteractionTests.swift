import SwiftUI
import Testing
import AppKit
@testable import MacToys

@MainActor struct SwiftUIInteractionTests {
    @Test func snapAssistantKeyboardNavigationUsesSwiftUIKeys() {
        let model = SnapAssistModel()
        model.availableWidth = 800
        model.candidates = (1...3).map { id in
            .init(id: UInt32(id), window: WindowElement(element: AXUIElementCreateApplication(100), pid: 100),
                  title: "Window \(id)", appName: "Fixture", icon: NSImage(), size: CGSize(width: 800, height: 600))
        }
        var selected: UInt32?
        var cancelled = false
        model.onChoose = { selected = $0.id }
        model.onCancel = { cancelled = true }
        #expect(model.handleKey(.rightArrow) && model.selection == 1)
        #expect(model.handleKey(.tab, modifiers: .shift) && model.selection == 0)
        #expect(!model.handleKey(.leftArrow, modifiers: .command))
        #expect(model.handleKey(.return) && selected == 1)
        #expect(model.handleKey(.escape) && cancelled)
    }
    @Test func emptyAssistantStillAllowsEscape() {
        let model = SnapAssistModel()
        var cancelled = false
        model.onCancel = { cancelled = true }
        #expect(!model.handleKey(.return))
        #expect(model.handleKey(.escape) && cancelled)
    }
}

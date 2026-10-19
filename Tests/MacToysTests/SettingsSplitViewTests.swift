import AppKit
import SwiftUI
import Testing
@testable import MacToys

@MainActor struct SettingsSplitViewTests {
    @Test func toolbarKeepsStandardSidebarItemAcrossCollapseAndUpdates() throws {
        let controller = SettingsSplitController(sidebar: Text("Sidebar"), detail: Text("Detail"), title: "Mapping")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.installToolbar(in: window)
        let toolbar = try #require(window.toolbar)
        let button = try #require(toolbar.items.first { $0.itemIdentifier == .toggleSidebar })
        let identifiers = toolbar.items.map(\.itemIdentifier)
        #expect(identifiers.firstIndex(of: .toggleSidebar)! < identifiers.firstIndex(of: .sidebarTrackingSeparator)!)
        #expect(toolbar.displayMode == .iconOnly)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(!window.titlebarAppearsTransparent)
        #expect(!window.isOpaque)
        #expect(controller.splitViewItems[0].behavior == .sidebar)
        #expect(controller.splitViewItems[0].allowsFullHeightLayout)
        #expect(controller.sidebarHost.sceneBridgingOptions.isEmpty)
        #expect(controller.detailHost.sceneBridgingOptions.isEmpty)
        for _ in 0..<6 {
            controller.splitViewItems[0].isCollapsed.toggle()
            controller.sidebarHost.rootView = Text("Updated Sidebar")
            controller.detailHost.rootView = Text("Updated Detail")
            controller.updateTitle("Updated")
            controller.installToolbar(in: window)
            #expect(window.toolbar === toolbar)
            #expect(toolbar.items.first { $0.itemIdentifier == .toggleSidebar } === button)
            #expect(toolbar.items.filter { $0.itemIdentifier == .toggleSidebar }.count == 1)
            #expect(toolbar.items.map(\.itemIdentifier) == identifiers)
        }
        #expect(window.title == "Updated")
    }
}

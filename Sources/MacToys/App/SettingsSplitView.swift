// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// 分栏、跟踪分隔符和标准按钮由同一个控制器持有，显隐时不重新注册工具栏项。
struct SettingsSplitView<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    let title: String
    let sidebar: Sidebar
    let detail: Detail

    init(title: String, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.title = title
        self.sidebar = sidebar()
        self.detail = detail()
    }

    func makeNSViewController(context: Context) -> SettingsSplitController<Sidebar, Detail> {
        SettingsSplitController(sidebar: sidebar, detail: detail, title: title)
    }

    func updateNSViewController(_ controller: SettingsSplitController<Sidebar, Detail>, context: Context) {
        controller.sidebarHost.rootView = sidebar
        controller.detailHost.rootView = detail
        controller.updateTitle(title)
    }
}

final class SettingsSplitController<Sidebar: View, Detail: View>: NSSplitViewController, NSToolbarDelegate {
    let sidebarHost: NSHostingController<Sidebar>
    let detailHost: NSHostingController<Detail>
    private(set) lazy var settingsToolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "MacToys.Settings")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.isVisible = true
        toolbar.displayMode = .iconOnly
        return toolbar
    }()

    init(sidebar: Sidebar, detail: Detail, title: String) {
        sidebarHost = NSHostingController(rootView: sidebar)
        detailHost = NSHostingController(rootView: detail)
        super.init(nibName: nil, bundle: nil)
        self.title = title
        let split = SettingsWindowSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.onWindow = { [weak self] window in
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.splitView.window === window else { return }
                self.installToolbar(in: window)
            }
        }
        splitView = split
        // 内部 SwiftUI 内容不向窗口桥接工具栏，避免与标准 AppKit 项争夺所有权。
        sidebarHost.sceneBridgingOptions = []
        detailHost.sceneBridgingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 520
        addSplitViewItem(detailItem)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func installToolbar(in window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        // 使用系统标题栏的窗口内混合，让滚动内容在其下方模糊显现。
        window.titlebarAppearsTransparent = false
        window.isOpaque = false
        window.backgroundColor = .windowBackgroundColor
        if window.toolbar !== settingsToolbar { window.toolbar = settingsToolbar }
        if settingsToolbar.items.isEmpty {
            settingsToolbar.itemIdentifiers = toolbarDefaultItemIdentifiers(settingsToolbar)
        }
        settingsToolbar.displayMode = .iconOnly
        settingsToolbar.isVisible = true
        window.title = title ?? "MacToys"
    }

    func updateTitle(_ title: String) {
        self.title = title
        viewIfLoaded?.window?.title = title
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // 分隔符之前属于侧边栏；按钮始终保留同一个标准身份和视图。
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator]
    }
}

private final class SettingsWindowSplitView: NSSplitView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

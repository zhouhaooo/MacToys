// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI

/// 剪贴板历史：记录、弹出面板、选中后粘贴。只在主线程上使用。
final class ClipboardController {
    let store: ClipboardStore
    private let watcher: ClipboardWatcher
    private let configStore: ConfigStore
    private lazy var model = makeModel()
    private lazy var panel = makePanel()
    private var panelSizeSubscription: AnyCancellable?
    private var presentationAnchor: NSRect?
    /// 打开面板前的输入法。搜索支持中英文输入，关闭面板时恢复原输入源。
    private var savedInputSource: TISInputSource?

    init(configStore: ConfigStore, store: ClipboardStore = ClipboardStore()) {
        self.configStore = configStore
        self.store = store
        watcher = ClipboardWatcher(store: store, config: { configStore.config.clipboard })
    }

    /// 按配置开始或停止记录。
    func applyConfig() {
        let cfg = configStore.config.clipboard
        if cfg.enabled && PasteboardAccess.status == .allowed {
            watcher.start()
            store.trim(maxItems: cfg.maxItems)
        } else {
            watcher.stop()
            store.cancelPendingCaptures()
            hide()
        }
    }

    func stop() {
        watcher.flush()
        watcher.stop()
        hide()
    }

    var isVisible: Bool { panel.isVisible }
    func show() {
        guard configStore.config.clipboard.enabled else { return }
        // 已经开着：放到前面就行，别把原来的搜索框、输入法记录换掉
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        presentationAnchor = CaretLocator.caretRect() ?? {
            NSRect(origin: NSEvent.mouseLocation, size: .zero)
        }()
        model.prepareForShow()
        resize(panel, to: model.panelSize)
        savedInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        FrontAppTracker.shared.clipboardPanelActive.set(true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Esc 或再次按历史快捷键关闭面板。
    func close() { hide() }

    func hide() {
        FrontAppTracker.shared.clipboardPanelActive.set(false)
        if panel.isVisible { panel.orderOut(nil) }
        model.releaseThumbnails()
        restoreInputSource()
    }

    private func restoreInputSource() {
        guard let saved = savedInputSource else { return }
        savedInputSource = nil
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        if current.map({ CFEqual($0, saved) }) != true {
            TISSelectInputSource(saved)
        }
    }

    /// 把选中的条目放进剪贴板，再模拟 ⌘V 粘贴到原来的应用里。
    func paste(_ item: ClipboardItem) {
        hide()
        guard write(item) else { return }
        store.markUsed(item.id)
        guard Permissions.accessibility else { return }
        // 等面板消失、原来的窗口重新接收键盘输入，并且用户松开修饰键之后再粘贴。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Synthetic.afterModifiersReleased {
                Synthetic.tap(KeyStroke(KeyCode.v, .maskCommand))
            }
        }
    }

    /// 写进剪贴板。图片文件丢失等原因写不了时返回 false，这时不能再粘贴，否则会贴出剪贴板里原有的东西。
    private func write(_ item: ClipboardItem) -> Bool {
        let pasteboard = NSPasteboard.general
        let pbItem = NSPasteboardItem()
        switch item.kind {
        case .text:
            guard let text = store.fullText(for: item) else { return false }
            pbItem.setString(text, forType: .string)
            for (type, data) in store.extraData(for: item) {
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
        case .image:
            guard let url = store.imageURL(for: item), let png = try? Data(contentsOf: url) else {
                Log.clipboard.error("找不到图片文件，无法粘贴")
                return false
            }
            pbItem.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                pbItem.setData(tiff, forType: .tiff)
            }
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([pbItem])
        watcher.noteOwnWrite()
        return true
    }

    // MARK: - 面板

    private func makeModel() -> ClipboardPanelModel {
        let model = ClipboardPanelModel(store: store)
        model.onPaste = { [weak self] item in self?.paste(item) }
        model.onClose = { [weak self] in self?.close() }
        return model
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel()
        let host = NSHostingView(rootView: ClipboardPanelView(model: model))
        // 玻璃卡片和透明阴影空间由界面统一布局。
        host.safeAreaRegions = []
        panel.contentView = host
        panel.onResignKey = { [weak self] in self?.hide() }
        panelSizeSubscription = model.$results.combineLatest(model.$rowHeights)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak panel] results, rowHeights in
                guard let self, let panel, panel.isVisible else { return }
                self.resize(panel, to: ClipboardPanelLayout.size(for: results, rowHeights: rowHeights))
            }
        return panel
    }

    private func resize(_ panel: NSPanel, to size: NSSize) {
        panel.setContentSize(NSSize(width: size.width + ClipboardPanel.glassMargin * 2,
                                    height: size.height + ClipboardPanel.glassMargin * 2))
        position(panel, size: size)
    }

    /// 搜索和删除导致高度变化时，仍以打开面板前的光标定位。
    private func position(_ panel: NSPanel, size: NSSize) {
        let anchor = presentationAnchor ?? {
            let mouse = NSEvent.mouseLocation
            return NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
        }()
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin = ClipboardPanelPosition.frame(anchor: anchor, size: size, visible: visible).origin
        panel.setFrameOrigin(NSPoint(x: origin.x - ClipboardPanel.glassMargin,
                                     y: origin.y - ClipboardPanel.glassMargin))
    }
}

/// 通过辅助功能接口查询文字光标在屏幕上的位置。
enum CaretLocator {
    /// 返回 AppKit 坐标（原点在主屏幕左下角）。
    static func caretRect() -> NSRect? {
        guard Permissions.accessibility,
              let element = FocusInspector().focusedElement()
        else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue
        else { return nil }
        var range = CFRange()
        guard CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
              range.length == 0
        else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue
        ) == .success,
            let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.origin != .zero,
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width >= 0, rect.width <= 40, rect.height >= 0, rect.height <= 80
        else { return nil }

        // 辅助功能接口的坐标原点在主屏幕左上角，y 向下。
        guard let primary = NSScreen.screens.first else { return nil }
        let flippedY = primary.frame.maxY - rect.maxY
        let caret = NSRect(x: rect.minX, y: flippedY, width: rect.width, height: max(rect.height, 1))
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(caret.insetBy(dx: -1, dy: -1)) }) else { return nil }
        return caret
    }
}

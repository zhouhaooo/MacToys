// SPDX-License-Identifier: MIT

import AppKit
import Combine
import ImageIO
import SwiftUI

/// 剪贴板历史面板。不会把本程序切到前台，原来的应用保持在前台，选中后直接粘贴到它里面。
final class ClipboardPanel: NSPanel {
    /// 可见卡片大小；窗口四周另留透明空间，让玻璃阴影完整衰减。
    static let size = NSSize(width: ClipboardPanelLayout.width, height: ClipboardPanelLayout.headerHeight + ClipboardPanelLayout.maximumListHeight + ClipboardPanelLayout.footerHeight)
    static let glassMargin: CGFloat = 36
    static var windowSize: NSSize {
        NSSize(width: size.width + glassMargin * 2, height: size.height + glassMargin * 2)
    }

    var surfaceFrame: NSRect { frame.insetBy(dx: Self.glassMargin, dy: Self.glassMargin) }

    var onResignKey: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = AppPanelLevel.utility
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // 阴影由 SwiftUI 玻璃形状自己画，避免窗口边缘出现额外的背景光晕
        // 让按压序列完整交给按钮，避免 AppKit 背景拖动接走点击。
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // 透明阴影空间可以越过屏幕边缘，卡片位置由控制器限制。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// 面板的数据和操作。
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" {
        didSet {
            cancelClear()
            refresh()
        }
    }
    @Published private(set) var results: [ClipboardItem] = []
    @Published private(set) var confirmingClear = false
    @Published private(set) var rowHeights: [UUID: CGFloat] = [:]

    var panelSize: NSSize { ClipboardPanelLayout.size(for: results, rowHeights: rowHeights) }

    func measureRow(_ id: UUID, height: CGFloat) {
        let height = ceil(height)
        guard rowHeights[id] != height else { return }
        rowHeights[id] = height
    }
    @Published var selection = 0 {
        didSet {
            if selection != oldValue { cancelClear() }
        }
    }
    /// 鼠标停在哪一条上
    @Published var hoveredID: UUID?
    /// 每次打开面板时加一，搜索框据此重新获得焦点。
    @Published private(set) var focusToken = 0

    let store: ClipboardStore
    var onPaste: (ClipboardItem) -> Void = { _ in }
    var onClose: () -> Void = {}

    private let thumbnails = ImageCache<UUID>(countLimit: 48, byteLimit: 16 << 20)
    private var subscription: AnyCancellable?
    private var clearTimeout: DispatchWorkItem?
    private var searchGeneration = 0

    init(store: ClipboardStore) {
        self.store = store
        subscription = store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func prepareForShow() {
        hoveredID = nil
        query = ""
        selection = 0
        cancelClear()
        refresh()
        focusToken += 1
    }

    func refresh() {
        searchGeneration += 1
        let ticket = searchGeneration
        store.search(query) { [weak self] found in
            guard let self, ticket == self.searchGeneration else { return }
            self.results = found
            if self.selection >= found.count { self.selection = max(found.count - 1, 0) }
        }
        let ids = Set(store.items.map(\.id))
        thumbnails.remove { !ids.contains($0) }
        rowHeights = rowHeights.filter { ids.contains($0.key) }
    }

    var selectedItem: ClipboardItem? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func pasteSelected() {
        if let item = selectedItem { onPaste(item) }
    }

    /// 清空全部记录需要再次点击，搜索结果不会限制清空范围。
    func clearTapped() {
        guard !store.items.isEmpty else { return }
        guard confirmingClear else {
            cancelClear()
            confirmingClear = true
            let timeout = DispatchWorkItem { [weak self] in self?.confirmingClear = false }
            clearTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + max(3, NSEvent.doubleClickInterval + 2), execute: timeout)
            return
        }
        cancelClear()
        store.clearAll()
        query = ""
        selection = 0
        refresh()
    }

    func cancelClear() {
        clearTimeout?.cancel()
        clearTimeout = nil
        confirmingClear = false
    }

    func releaseThumbnails() {
        hoveredID = nil
        cancelClear()
        query = ""
        store.cancelSearch()
        searchGeneration += 1
        thumbnails.removeAll()
    }

    /// 缩略图，按需生成并缓存。
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard let url = store.imageURL(for: item),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails[item.id] = image
        return image
    }
}

/// 按 SwiftUI 实际测得的行高收起空白，长内容在列表中滚动查看。
enum ClipboardPanelLayout {
    static let width: CGFloat = 420
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 48
    static let controlHeight: CGFloat = 32
    static let maximumListHeight: CGFloat = 340

    static func size(for items: [ClipboardItem], rowHeights: [UUID: CGFloat] = [:]) -> NSSize {
        let contentHeight: CGFloat
        if items.isEmpty {
            contentHeight = 164
        } else {
            let rows = items.reduce(CGFloat(0)) { $0 + (rowHeights[$1.id] ?? ($1.kind == .image ? 84 : 44)) }
            contentHeight = min(rows + 16 + CGFloat(max(0, items.count - 1)) * 4, maximumListHeight)
        }
        return NSSize(width: width, height: headerHeight + contentHeight + footerHeight)
    }
}

// MARK: - 界面

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace
    @Namespace private var selectionNamespace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    searchBar
                    if model.results.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }
                .frame(height: model.panelSize.height - ClipboardPanelLayout.footerHeight)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .glassEffectID("history", in: glassNamespace)
                footer
            }
        }
        .frame(width: ClipboardPanelLayout.width, height: model.panelSize.height)
        .foregroundStyle(.primary)
        .padding(ClipboardPanel.glassMargin)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
            SearchField(
                text: $model.query,
                placeholder: L("搜索剪贴板"),
                focusToken: model.focusToken,
                onMove: { model.move($0) },
                onSubmit: { model.pasteSelected() },
                onCancel: { model.onClose() }
            )
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("清除搜索"))
                .accessibilityLabel(L("清除搜索"))
            } else {
                Text(L("%ld 条", model.results.count))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: ClipboardPanelLayout.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
                .padding(.horizontal, 16)
        }
        .help(L("支持拼音和首字母搜索"))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        ClipboardRow(model: model, item: item, isSelected: index == model.selection, selectionNamespace: selectionNamespace) {
                            model.cancelClear()
                            model.selection = index
                            model.pasteSelected()
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            model.measureRow(item.id, height: height)
                        }
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .animation(reduceMotion ? nil : AppAnimation.easeOut(duration: 0.18), value: model.selection)
            .onChange(of: model.selection) { _, newValue in
                guard model.results.indices.contains(newValue) else { return }
                proxy.scrollTo(model.results[newValue].id, anchor: .top)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .padding(.bottom, 4)
            Text(model.query.isEmpty ? L("还没有记录") : L("没有找到"))
                .font(.system(size: 13, weight: .semibold))
            Text(model.query.isEmpty ? L("复制的文字和图片会出现在这里") : L("换个关键词，或者试试拼音首字母"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 12) {
                KeyHint(key: "↑↓", action: L("选择"))
                KeyHint(key: "↵", action: L("粘贴"))
                KeyHint(key: "esc", action: L("关闭"))
            }
            .padding(.horizontal, 14)
            .frame(height: ClipboardPanelLayout.controlHeight)
            .glassEffect(.regular, in: Capsule())
            .glassEffectID("hints", in: glassNamespace)
            Spacer(minLength: 0)
            ClipboardClearButton(model: model)
        }
        .frame(height: ClipboardPanelLayout.footerHeight - 10)
    }
}

struct KeyHint: View {
    let key: String
    let action: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
            Text(action)
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

/// 两种内容共享玻璃身份，由系统在圆形与胶囊之间衔接材质。
private struct ClipboardClearButton: View {
    @ObservedObject var model: ClipboardPanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0)) {
                    model.clearTapped()
                }
            } label: {
                ZStack {
                    if model.confirmingClear {
                        Text(L("确认全部删除"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                            .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                            .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
                    }
                }
                .fixedSize()
                .padding(.horizontal, model.confirmingClear ? 12 : 0)
                .frame(minWidth: ClipboardPanelLayout.controlHeight)
                .frame(height: ClipboardPanelLayout.controlHeight)
                .clipShape(Capsule())
                .glassEffect(.regular.interactive(!model.store.items.isEmpty), in: Capsule())
                .glassEffectID("clear-history", in: glassNamespace)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: model.confirmingClear)
        .disabled(model.store.items.isEmpty)
        .help(L("全部删除"))
        .accessibilityLabel(model.confirmingClear ? L("确认全部删除") : L("全部删除"))
    }
}

private struct ClipboardRow: View {
    @ObservedObject var model: ClipboardPanelModel
    @Environment(\.colorSchemeContrast) private var contrast
    let item: ClipboardItem
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let onPaste: () -> Void

    private var hovering: Bool { model.hoveredID == item.id }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            sourceIcon
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.primary.opacity(contrast == .increased ? 0.16 : 0.065))
                    .matchedGeometryEffect(id: "selection", in: selectionNamespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.primary.opacity(0.035))
            }
        }
        .overlay {
            if contrast == .increased && isSelected {
                RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.5))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture(perform: onPaste)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text(L("粘贴")), onPaste)
        .onHover { inside in
            if inside {
                model.hoveredID = item.id
            } else if model.hoveredID == item.id {
                model.hoveredID = nil
            }
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let icon = AppInfo.icon(item.sourceApp) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: item.kind == .image ? "photo" : "text.alignleft")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image:
            if let image = model.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 64, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(height: 64, alignment: .leading)
            } else {
                Label(L("图片"), systemImage: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(height: 64)
            }
        }
    }

}

/// SwiftUI owns text input, focus and keyboard navigation.
struct SearchField: View {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($focused)
            .onAppear { focused = true }
            .onChange(of: focusToken) { _, _ in focused = true }
            .onSubmit(onSubmit)
            .onKeyPress(.upArrow) { onMove(-1); return .handled }
            .onKeyPress(.downArrow) { onMove(1); return .handled }
            .onExitCommand(perform: onCancel)
    }
}

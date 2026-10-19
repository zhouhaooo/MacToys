// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 贴靠助手：把窗口分到一半以后，在另一半列出其他窗口，点一个就放进去。
/// 窗口位置从辅助功能接口读；每次展示取共享池快照，缺图只补一次。只在主线程上用。
final class SnapAssist {
    private let retainsFocus: Bool
    private let onChoose: (WindowElement, CGRect) -> Void
    private let queryCandidates: (CGWindowID?) -> [SnapAssistModel.Candidate]
    private let model: SnapAssistModel
    private var panel: SnapPanel?
    private let thumbnails: WindowThumbnailStore
    private let thumbnailPresentation: WindowThumbnailPresentation<CGWindowID>
    private let windowQueue = DispatchQueue(label: "MacToys.SnapAssistWindows", qos: .userInitiated)
    private var excludedWindow: CGWindowID?
    private var revision = 0
    private var readingCandidates = false
    /// 要填的那一半（AX 坐标）
    private var area: CGRect = .zero

    init(thumbnails: WindowThumbnailStore = .shared,
         model: SnapAssistModel = SnapAssistModel(),
         queryCandidates: @escaping (CGWindowID?) -> [SnapAssistModel.Candidate] = { SnapAssist.candidates(excluding: $0) },
         retainsFocus: Bool = true,
         onChoose: @escaping (WindowElement, CGRect) -> Void) {
        self.retainsFocus = retainsFocus
        self.thumbnails = thumbnails
        self.thumbnailPresentation = WindowThumbnailPresentation(store: thumbnails)
        self.model = model
        self.queryCandidates = queryCandidates
        self.onChoose = onChoose
        thumbnailPresentation.onImage = { [weak self] id, image in
            guard let self, self.isVisible else { return }
            self.model.thumbnails[id] = image
        }
        thumbnailPresentation.onSettled = { [weak self] in self?.updatePreviewState() }
        model.onChoose = { [weak self] candidate in self?.choose(candidate) }
        model.onCancel = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(area: CGRect, excluding id: CGWindowID?) {
        revision += 1
        thumbnailPresentation.reset()
        excludedWindow = id
        self.area = area
        model.candidates = []
        model.thumbnails = [:]
        model.selection = 0
        model.previewState = .loading
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setSurfaceFrame(ScreenGeometry.appKitRect(area))
        FrontAppTracker.shared.snapAssistActive.set(true)
        panel.makeKeyAndOrderFront(nil)
        refreshCandidates()
    }

    func hide() {
        revision += 1
        thumbnailPresentation.reset()
        model.thumbnails = [:]
        FrontAppTracker.shared.snapAssistActive.set(false)
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.candidates = []
    }

    private func choose(_ candidate: SnapAssistModel.Candidate) {
        let area = self.area
        hide()
        onChoose(candidate.window, area)
    }

    private func makePanel() -> SnapPanel {
        let panel = SnapPanel(interactive: true)
        panel.setSurfaceContent(SnapAssistView(model: model))
        panel.onResignKey = { [weak self] in if self?.retainsFocus == true { self?.hide() } }
        return panel
    }

    private func loadThumbnails() {
        thumbnailPresentation.load(model.candidates.map {
            .init(id: $0.id, pid: $0.window.pid, windowID: $0.id, title: $0.title)
        })
        model.thumbnails = thumbnailPresentation.images
    }

    private func updatePreviewState() {
        if !thumbnails.recordingAllowed { model.previewState = .permissionRequired }
        else { model.previewState = thumbnailPresentation.isLoading ? .loading : .ready }
    }

    private func refreshCandidates() {
        guard !readingCandidates else { return }
        readingCandidates = true
        let ticket = revision
        let excluded = excludedWindow
        windowQueue.async { [weak self] in
            let candidates = self?.queryCandidates(excluded) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingCandidates = false
                guard self.isVisible else { return }
                guard self.revision == ticket else { self.refreshCandidates(); return }
                let previous = self.model.candidates
                let selected = previous.indices.contains(self.model.selection) ? previous[self.model.selection].id : nil
                self.model.candidates = candidates
                self.model.selection = candidates.firstIndex(where: { $0.id == selected }) ?? 0
                self.loadThumbnails()
                if candidates.isEmpty { self.hide(); return }
                self.updatePreviewState()
            }
        }
    }

    /// 屏幕上其他的普通窗口，从前到后排。
    static func candidates(excluding excluded: CGWindowID?) -> [SnapAssistModel.Candidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = getpid()
        var elementsByPID: [pid_t: [CGWindowID: WindowElement]] = [:]
        var result: [SnapAssistModel.Candidate] = []
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID, number != excluded,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 120, bounds.height >= 80,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
            else { continue }
            if elementsByPID[pid] == nil {
                var map: [CGWindowID: WindowElement] = [:]
                for window in WindowElement.windows(of: pid) {
                    if let id = window.windowID { map[id] = window }
                }
                elementsByPID[pid] = map
            }
            guard let window = elementsByPID[pid]?[number], window.isStandard, !window.isMinimized, window.isMovable else { continue }
            let appName = app.localizedName ?? ""
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? appName
            result.append(.init(id: number, window: window, title: title, appName: appName,
                                icon: app.icon ?? NSWorkspace.shared.icon(for: .application), size: bounds.size))
            if result.count >= 12 { break }
        }
        return result
    }
}
final class SnapAssistModel: ObservableObject {
    struct Candidate: Identifiable {
        let id: CGWindowID
        let window: WindowElement
        let title: String
        let appName: String
        let icon: NSImage
        let size: CGSize
    }

    @Published var candidates: [Candidate] = []
    @Published var selection = 0
    enum PreviewState { case loading, ready, permissionRequired }
    @Published var previewState: PreviewState = .loading
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var availableWidth: CGFloat = 0
    var layout: SnapThumbnailLayout { SnapThumbnailLayout(sizes: candidates.map(\.size), width: availableWidth) }
    var onChoose: (Candidate) -> Void = { _ in }
    var onCancel: () -> Void = {}

    /// SwiftUI key events keep navigation inside the SwiftUI focus system.
    func handleKey(_ key: KeyEquivalent, modifiers: EventModifiers = []) -> Bool {
        if key == .escape && modifiers.isEmpty { onCancel(); return true }
        guard !candidates.isEmpty, modifiers.subtracting(.shift).isEmpty else { return false }
        if key == .tab { move(modifiers.contains(.shift) ? -1 : 1); return true }
        guard modifiers.isEmpty else { return false }
        switch key {
        case .leftArrow: move(-1)
        case .rightArrow: move(1)
        case .downArrow: moveVertically(1)
        case .upArrow: moveVertically(-1)
        case .return: onChoose(candidates[selection])
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        let next = selection + delta
        if candidates.indices.contains(next) { selection = next }
    }

    private func moveVertically(_ direction: Int) {
        if let next = layout.neighbor(of: selection, direction: direction) { selection = next }
    }
}

struct SnapAssistView: View {
    @ObservedObject var model: SnapAssistModel
    @FocusState private var focused: Bool

    static let padding: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("选一个窗口放在这里"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(L("点击空白处跳过"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if model.previewState == .permissionRequired {
                Text(L("在通用设置中开启屏幕录制，可显示窗口缩略图"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: SnapThumbnailLayout.spacing) {
                            ForEach(model.layout.rows.indices, id: \.self) { row in
                                HStack(spacing: SnapThumbnailLayout.spacing) {
                                    ForEach(model.layout.rows[row], id: \.self) { index in
                                        let candidate = model.candidates[index]
                                        Button { model.onChoose(candidate) } label: {
                                            card(candidate, width: model.layout.widths[index], selected: index == model.selection)
                                        }
                                        .id(candidate.id)
                                        .buttonStyle(.plain)
                                        .onHover { inside in if inside { model.selection = index } }
                                        .help(candidate.title)
                                        .accessibilityLabel(candidate.title + ", " + candidate.appName)
                                        .accessibilityAddTraits(index == model.selection ? .isSelected : [])
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 2)
                        .frame(minHeight: geometry.size.height, alignment: .center)
                    }
                    .scrollIndicators(.never)
                    .scrollClipDisabled()
                    .onAppear { model.availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in model.availableWidth = width }
                    .onChange(of: model.selection) { _, index in
                        guard model.candidates.indices.contains(index) else { return }
                        proxy.scrollTo(model.candidates[index].id)
                    }
                }
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { model.onCancel() }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .tab, .escape], phases: [.down, .repeat]) { event in
            model.handleKey(event.key, modifiers: event.modifiers) ? .handled : .ignored
        }
    }

    private func card(_ candidate: SnapAssistModel.Candidate, width: CGFloat, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: candidate.icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(candidate.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(height: 20)
            Group {
                if let thumbnail = model.thumbnails[candidate.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .windowThumbnailBorder()
                } else if model.previewState == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "macwindow")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: max(width - 8, 1), height: SnapThumbnailLayout.thumbnailHeight)
            .windowThumbnailShadow(selected: selected)
        }
        .padding(4)
        .frame(width: width)
        .windowPreviewLift(selected: selected)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

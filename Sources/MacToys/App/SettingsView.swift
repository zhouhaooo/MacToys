// SPDX-License-Identifier: MIT
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case mapping, clipboard, window, dock, awake, general
    var id: Self { self }
    var title: String {
        switch self {
        case .mapping: L("键鼠映射")
        case .clipboard: L("剪贴板历史")
        case .window: L("分屏")
        case .dock: L("Dock 预览")
        case .awake: L("保持唤醒")
        case .general: L("通用")
        }
    }
    var symbol: String {
        switch self {
        case .mapping: "keyboard"
        case .clipboard: "clipboard"
        case .window: "rectangle.split.2x1"
        case .dock: "dock.rectangle"
        case .awake: "cup.and.saucer"
        case .general: "gearshape"
        }
    }
    var tint: Color {
        switch self {
        case .mapping: .purple
        case .clipboard: .orange
        case .window: .blue
        case .dock: .indigo
        case .awake: .brown
        case .general: .gray
        }
    }

}

struct SettingsView: View {
    let runtime: Runtime
    @ObservedObject private var config: ConfigStore
    @ObservedObject private var state: AppState
    @ObservedObject private var awake: KeepAwakeController
    @ObservedObject private var clipboard: ClipboardStore
    @State private var tab: SettingsTab = .mapping
    @State private var query = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var searchFocused: Bool
    @State private var clearConfirmation = false
    @State private var language = AppLanguage.current
    @State private var tilingConflict = NativeTiling.dragTilingEnabled
    @Environment(\.openWindow) private var openWindow

    init(runtime: Runtime) {
        self.runtime = runtime
        _config = ObservedObject(wrappedValue: runtime.config)
        _state = ObservedObject(wrappedValue: runtime.state)
        _awake = ObservedObject(wrappedValue: runtime.keepAwake)
        _clipboard = ObservedObject(wrappedValue: runtime.clipboard.store)
    }

    var body: some View {
        SettingsSplitView(title: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tab.title : L("搜索设置")) {
            sidebar
        } detail: {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    settingsPage
                } else {
                    searchResults
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 780, minHeight: 620)
        .containerBackground(for: .window) {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.thinMaterial)
            }
        }
        .background {
            Button(L("搜索设置")) { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden().frame(width: 0, height: 0)
        }
        .onAppear {
            runtime.openSettings = { openWindow(id: "settings"); NSApp.activate() }
            runtime.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            tilingConflict = NativeTiling.dragTilingEnabled
        }
        .confirmationDialog(L("清空剪贴板历史？"), isPresented: $clearConfirmation, titleVisibility: .visible) {
            Button(L("清空"), role: .destructive) { clipboard.clearAll() }
        } message: { Text(L("全部历史都会删除，清空后不能恢复。")) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 28, height: 28)
                Text("MacToys").font(.headline)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("搜索设置"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { query = ""; searchFocused = false }
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("清除搜索"))
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(searchFocused ? Color.accentColor.opacity(0.65) : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsTab.allCases) { item in
                        Button {
                            tab = item; query = ""; searchFocused = false
                        } label: {
                            HStack(spacing: 10) {
                                SettingsCategoryIcon(tab: item, size: 22)
                                Text(item.title)
                                    .font(.body.weight(tab == item ? .medium : .regular))
                                    .foregroundStyle(tab == item && query.isEmpty ? Color.white : Color.primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                            .background {
                                if tab == item && query.isEmpty {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(tab == item && query.isEmpty ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 12).padding(.top, 16)
    }

    private var settingsPage: some View {
        Form {
            switch tab {
            case .mapping: mappingPage
            case .clipboard: clipboardPage
            case .window: windowPage
            case .dock: dockPage
            case .awake: awakePage
            case .general: generalPage
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        // 恢复原生表单底色，内容区不透出桌面壁纸。
        .scrollContentBackground(.visible)
        .id(tab)
    }

    private var mappingPage: some View {
        Group {
            inputPermission
            Section(L("修饰键")) {
                settingToggle(L("Command / Ctrl 互换"), L("Ctrl+C 复制，Command+C 发送原生 Ctrl+C；左右两侧同时生效"), $config.config.keyboard.swapCommandControl)
            }
            Section("Finder") {
                settingToggle(L("剪切并移动文件"), L("%@+X 标记文件，%@+V 移动到当前位置", config.config.keyboard.actionModifier.name, config.config.keyboard.actionModifier.name), $config.config.keyboard.finderCut)
                Text(L("只在 Finder 文件列表中生效，不影响搜索与重命名输入。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("鼠标")) {
                settingToggle(L("反转鼠标滚轮方向"), L("所有鼠标统一生效；触控板和妙控鼠标连续滚动保持系统设置"), $config.config.mouse.reverseScroll)
                settingToggle(L("定位鼠标"), L("双击 %@，聚光灯收拢到鼠标位置", config.config.keyboard.auxiliaryModifier.name), $config.config.mouse.locatePointer)
                Stepper(value: $config.config.mouse.locatePointerDuration, in: MouseConfig.locatePointerDurationRange, step: 1) {
                    LabeledContent(L("聚光灯持续时间"), value: L("%ld 秒", Int(config.config.mouse.locatePointerDuration)))
                }
                .disabled(!config.config.mouse.locatePointer)
                Text(L("从聚光收拢完成后开始计时，移动或静止均不影响自动关闭。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("例外的应用")) {
                ExcludedAppsEditor(bundleIDs: $config.config.keyboard.excludedApps)
                Text(L("这些应用保留原生键位，滚轮反转继续生效。Ctrl+V 呼出历史，双击 Ctrl 定位鼠标。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var clipboardPage: some View {
        Group {
            inputPermission
            Section {
                settingToggle(L("剪贴板历史"), L("按 %@+V 呼出，支持拼音全拼和首字母搜索", config.config.keyboard.auxiliaryModifier.name), $config.config.clipboard.enabled)
            }
            if state.pasteboardAccess != .allowed {
                Section {
                    permissionRow(L("剪贴板读取"), L("允许后台记录复制的文字和图片"), false, request: PasteboardAccess.request)
                }
            }
            Section(L("记录")) {
                Picker(L("最多保存"), selection: $config.config.clipboard.maxItems) {
                    ForEach([50, 100, 200, 500, 1000], id: \.self) { Text(L("%ld 条", $0)).tag($0) }
                }
                settingToggle(L("记录图片"), L("截图、复制的图片"), $config.config.clipboard.recordImages)
                LabeledContent(L("已保存"), value: L("%ld 条", clipboard.items.count))
            }.disabled(!config.config.clipboard.enabled)
            Section(L("存储与清理")) {
                Text(L("内容只保存在这台电脑上，不记录密码管理器标记为隐藏的内容和 Finder 文件。"))
                Text(L("历史最多占用 64 MB，超出时移除最旧条目。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([clipboard.directory]) }
                    Spacer()
                    Button(L("清空历史…"), role: .destructive) { clearConfirmation = true }
                        .disabled(clipboard.items.isEmpty)
                }
            }
        }
    }
    private var windowPage: some View {
        Group {
            inputPermission
            Section {
                settingToggle(L("启用分屏"), L("拖动窗口到屏幕边缘以整理窗口"), $config.config.window.enabled)
            }
            Section(L("拖动与贴靠")) {
                settingToggle(L("拖到屏幕边缘分屏"), L("左右边缘半屏，顶部最大化，四角四分之一屏"), $config.config.window.dragToSnap)
                settingToggle(L("贴靠助手"), L("分好一半后，选择另一个窗口填入剩余区域"), $config.config.window.snapAssist)
            }.disabled(!config.config.window.enabled)
            Section(L("系统分屏")) {
                Text(tilingConflict ? L("系统拖动分屏已开启，会优先处理边缘拖动。") : L("系统拖动分屏已关闭，没有冲突。"))
                Button(L("打开系统设置"), action: NativeTiling.openSystemSettings)
            }
            thumbnailPermission
        }
    }
    private var dockPage: some View {
        Group {
            inputPermission
            Section {
                settingToggle(L("Dock 预览"), L("悬停预览窗口，点击卡片切换到对应窗口"), $config.config.dock.dockPreview)
            }
            Section(L("显示方式")) {
                Picker(L("预览图高度"), selection: $config.config.dock.dockPreviewHeight) {
                    ForEach(DockConfig.dockPreviewHeights, id: \.self) { Text(L("%ld 点", Int($0))).tag($0) }
                }
                Picker(L("进入和退出动画"), selection: $config.config.dock.dockPreviewAnimation) {
                    Text(L("凝实消散")).tag(DockPreviewAnimation.materialize)
                    Text(L("飞入飞出")).tag(DockPreviewAnimation.fly)
                }
                Toggle(L("App 没有窗口时显示占位面板"), isOn: $config.config.dock.dockShowEmptyApps)
            }.disabled(!config.config.dock.dockPreview)
            Section(L("悬停原位置预览")) {
                settingToggle(L("悬停缩略图时预览原窗口"),
                              L("悬停缩略图，在原位置清晰预览窗口"),
                              $config.config.dock.dockWindowPeek)
                Group {
                    Stepper(value: $config.config.dock.dockPeekBorderWidth, in: DockConfig.dockPeekBorderWidthRange, step: 1) {
                        HStack {
                            Text(L("预览边框宽度"))
                            Spacer()
                            Text(L("%ld 像素", Int(config.config.dock.dockPeekBorderWidth))).foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $config.config.dock.dockPeekCornerRadius, in: DockConfig.dockPeekCornerRadiusRange, step: 1) {
                        HStack {
                            Text(L("预览边框圆角"))
                            Spacer()
                            Text(L("%ld 点", Int(config.config.dock.dockPeekCornerRadius))).foregroundStyle(.secondary)
                        }
                    }
                }.disabled(!config.config.dock.dockWindowPeek)
            }.disabled(!config.config.dock.dockPreview)
            Section(L("窗口操作")) {
                Toggle(L("缩略图显示关闭、最小化按钮"), isOn: $config.config.dock.dockWindowButtons)
                Toggle(L("中键点击缩略图关闭窗口"), isOn: $config.config.dock.dockMiddleClickClose)
                Toggle(L("单窗口 App 点击 Dock 图标切换最小化"), isOn: $config.config.dock.dockSingleWindowToggle)
            }.disabled(!config.config.dock.dockPreview)
            Section(L("排除的 App")) {
                ExcludedAppsEditor(bundleIDs: $config.config.dock.dockExcludedApps)
            }.disabled(!config.config.dock.dockPreview)
            thumbnailPermission
        }
    }
    private var awakePage: some View {
        Section(L("保持唤醒")) {
            settingToggle(L("保持唤醒"), L("开启后屏幕和电脑不会因空闲而睡眠"), Binding(get: { awake.isActive }, set: {
                if $0 { awake.start(for: config.config.keepAwake.duration) } else { awake.stop() }
            }))
            Picker(L("唤醒时长"), selection: Binding(get: { config.config.keepAwake.duration }, set: {
                guard !awake.isActive || awake.start(for: $0) else { return }
                config.config.keepAwake.duration = $0
            })) {
                ForEach(KeepAwakeDuration.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent(L("当前状态"), value: awake.statusText)
            if let problem = awake.problem { Text(problem).foregroundStyle(.orange) }
            Text(L("单击菜单栏图标也能开关，右键打开菜单。开启时更改时长会重新计时，到期或退出后恢复正常睡眠。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("合盖和主动睡眠仍由系统处理。此功能不需要额外授权。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var generalPage: some View {
        Group {
            Section(L("启动与语言")) {
                Toggle(L("登录时自动启动"), isOn: Binding(get: { state.launchAtLogin }, set: state.setLaunchAtLogin))
                Picker(L("语言"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }.onChange(of: language) { _, next in next.apply() }
                if let problem = state.problem { Text(problem).foregroundStyle(.orange) }
            }
            Section(L("权限")) {
                permissionRow(L("辅助功能"), L("键鼠映射、直接粘贴、分屏与 Dock 窗口操作"), state.accessibilityGranted,
                              request: Permissions.requestAccessibility)
                permissionRow(L("输入监控"), L("系统事件监听；需要时在系统设置中允许"), state.inputMonitoringGranted,
                              request: Permissions.requestInputMonitoring)
                permissionRow(L("屏幕录制"), L("显示真实窗口缩略图；未授权时显示占位卡片"), state.screenRecordingGranted,
                              request: Permissions.requestScreenRecording)
                permissionRow(L("剪贴板读取"), L("设为始终允许后记录剪贴板历史"), state.pasteboardAccess == .allowed,
                              request: PasteboardAccess.request)
                Button(L("重新检查权限")) { runtime.refresh() }
                if state.accessibilityGranted && !state.eventTapRunning {
                    Text(L("事件监听未运行；请重新检查权限，必要时退出后再次打开。"))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section(L("关于")) {
                LabeledContent("MacToys", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
            }
        }
    }
    @ViewBuilder private var inputPermission: some View {
        if !state.accessibilityGranted {
            Section {
                permissionRow(L("需要辅助功能权限"), L("授权后启用输入改写和窗口操作，其他功能仍可使用"), false,
                              request: Permissions.requestAccessibility)
            }
        }
    }
    @ViewBuilder private var thumbnailPermission: some View {
        if !state.screenRecordingGranted {
            Section {
                permissionRow(L("窗口缩略图"), L("授权屏幕录制以显示真实画面，目前使用占位卡片"), false,
                              request: Permissions.requestScreenRecording)
            }
        }
    }
    private func permissionRow(_ title: String, _ detail: String, _ granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted { Label(L("已授权"), systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            else { Button(L("去授权"), action: request) }
        }
    }
    private func settingToggle(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }.accessibilityLabel(title).accessibilityHint(detail)
    }
    private var searchResults: some View {
        let results = SettingsSearch.matches(query)
        return List {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(results) { item in
                    Button { tab = item.tab; query = ""; searchFocused = false } label: {
                        HStack(spacing: 12) {
                            SettingsCategoryIcon(tab: item.tab, size: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L(item.title))
                                Text(item.tab.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .scrollContentBackground(.visible)
    }
}

private struct SettingsCategoryIcon: View {
    let tab: SettingsTab
    let size: CGFloat
    var body: some View {
        Image(systemName: tab.symbol)
            .font(.system(size: size * 0.53, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tab.tint, in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

struct ExcludedAppsEditor: View {
    @Binding var bundleIDs: [String]
    @State private var importing = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(bundleIDs, id: \.self) { id in
                HStack {
                    if let image = AppInfo.icon(id) { Image(nsImage: image).resizable().frame(width: 24, height: 24) }
                    Text(AppInfo.name(id))
                    Spacer()
                    Button { bundleIDs.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel(L("移除") + " " + AppInfo.name(id))
                }
            }
            HStack {
                Label(L("将应用拖到这里"), systemImage: "plus.app")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("添加应用…")) { importing = true }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.application], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): add(urls)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    private func add(_ urls: [URL]) {
        error = nil
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard url.pathExtension.lowercased() == "app", let id = Bundle(url: url)?.bundleIdentifier else {
                error = L("请选择有效的 .app 应用。"); continue
            }
            if !bundleIDs.contains(id) { bundleIDs.append(id) }
        }
    }
}

struct SettingsSearch {
    struct Item: Identifiable {
        let tab: SettingsTab
        let title: String
        var id: String { tab.rawValue + title }
    }
    static let items: [Item] = [
        .init(tab: .mapping, title: "Command / Ctrl 互换"), .init(tab: .mapping, title: "剪切并移动文件"),
        .init(tab: .mapping, title: "反转鼠标滚轮方向"), .init(tab: .mapping, title: "例外的应用"),
        .init(tab: .mapping, title: "定位鼠标"), .init(tab: .mapping, title: "聚光灯持续时间"),
        .init(tab: .clipboard, title: "剪贴板历史"), .init(tab: .clipboard, title: "最多保存"),
        .init(tab: .clipboard, title: "记录图片"), .init(tab: .clipboard, title: "清空历史…"),
        .init(tab: .window, title: "启用分屏"),
        .init(tab: .window, title: "拖到屏幕边缘分屏"), .init(tab: .window, title: "贴靠助手"),
        .init(tab: .window, title: "系统分屏"), .init(tab: .dock, title: "Dock 预览"),
        .init(tab: .dock, title: "预览图高度"),
        .init(tab: .dock, title: "悬停原位置预览"),
        .init(tab: .dock, title: "预览边框宽度"), .init(tab: .dock, title: "预览边框圆角"),
        .init(tab: .dock, title: "进入和退出动画"), .init(tab: .dock, title: "App 没有窗口时显示占位面板"),
        .init(tab: .dock, title: "缩略图显示关闭、最小化按钮"), .init(tab: .dock, title: "中键点击缩略图关闭窗口"),
        .init(tab: .dock, title: "单窗口 App 点击 Dock 图标切换最小化"), .init(tab: .dock, title: "排除的 App"),
        .init(tab: .awake, title: "保持唤醒"), .init(tab: .awake, title: "唤醒时长"),
        .init(tab: .general, title: "登录时自动启动"), .init(tab: .general, title: "语言"),
        .init(tab: .general, title: "辅助功能"), .init(tab: .general, title: "输入监控"),
        .init(tab: .general, title: "屏幕录制"), .init(tab: .general, title: "剪贴板读取"),
    ]
    static func matches(_ query: String) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            let text = L(item.title) + " " + item.title + " " + item.tab.title
            let latin = text.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? text
            let words = latin.lowercased().split(whereSeparator: \.isWhitespace)
            return text.localizedCaseInsensitiveContains(q) || words.joined().contains(q) || String(words.compactMap(\.first)).contains(q)
        }
    }
}

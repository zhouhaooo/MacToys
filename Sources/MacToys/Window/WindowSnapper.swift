// SPDX-License-Identifier: MIT

import AppKit

/// 分屏：边缘拖动调整窗口，分屏后由贴靠助手列出其他窗口。只在主线程上用。
final class WindowSnapper {
    private let configStore: ConfigStore
    private let preview = SnapPreview()
    private let stickyEdges = StickyEdges()
    private lazy var assist = SnapAssist { [weak self] window, area in
        self?.fill(area, with: window)
    }

    /// 每个窗口分屏前的样子，和分屏后的位置，用来恢复、判断它现在是不是分着屏
    private struct Record {
        var restoreFrame: CGRect?
        var snappedFrame: CGRect?
        var position: WindowLayout.Position?
        var updated = Date()
    }
    private var history: [CGWindowID: Record] = [:]

    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var dragTimer: Timer?
    private var dragGeneration = 0
    private var drag: DragState?
    private let ignoresNativeTiling = false
    /// 自测用：拖动时预览的位置（AX 坐标）
    private(set) var previewFrame: CGRect?

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    private var config: WindowConfig { configStore.config.window }

    /// 按配置开始或停止监听拖动。
    func applyConfig() {
        let wantsDrag = config.enabled && config.dragToSnap && Permissions.accessibility
        if wantsDrag && mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.handleMouse(event)
            }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.handleMouse(event)
                return event
            }
        } else if !wantsDrag {
            if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
            if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
            mouseMonitor = nil
            localMouseMonitor = nil
            cancelDrag()
        }
        if !config.enabled || !config.snapAssist || !Permissions.accessibility { assist.hide() }
        if !wantsDrag { stickyEdges.stop() }
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        mouseMonitor = nil
        localMouseMonitor = nil
        cancelDrag()
        stickyEdges.stop()
        assist.hide()
    }

    var isAssistVisible: Bool { assist.isVisible }

    /// 窗口现在分在哪：先看是不是还在我们上次放的位置，再按大小位置判断（例如被系统或别的工具分的屏）。
    private func position(of id: CGWindowID?, frame: CGRect, area: CGRect) -> WindowLayout.Position? {
        if let id, let record = history[id], let snapped = record.snappedFrame, let position = record.position,
           Self.same(frame, snapped) {
            return position
        }
        return WindowLayout.position(of: frame, in: area)
    }

    private static func same(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func snap(_ window: any SnappableWindow, id: CGWindowID?, from frame: CGRect, fromArea: CGRect,
                      to position: WindowLayout.Position, on screen: ScreenGeometry.Screen, showAssist: Bool) {
        var record = id.flatMap { history[$0] } ?? Record()
        // 从普通状态分屏时记下原来的样子；已经分着屏（换个位置）时保留最早的那个
        if self.position(of: id, frame: frame, area: fromArea) == nil { record.restoreFrame = frame }
        let target = position.frame(in: screen.area)
        var actual: CGRect?
        if window.isResizable {
            actual = window.setFrame(target)
        } else {
            // 改不了大小的窗口（例如计算器）放在那块区域的中间
            let size = frame.size
            let centered = CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2, width: size.width, height: size.height)
            actual = window.setFrame(WindowLayout.clamped(centered.integral, to: screen.area), resize: false)
        }
        // 窗口有最小尺寸、比目标大时，至少别跑出屏幕
        if let result = actual, !screen.area.insetBy(dx: -1, dy: -1).contains(result) {
            actual = window.setFrame(WindowLayout.clamped(result, to: screen.area), resize: false)
        }
        if let id {
            record.snappedFrame = actual ?? target
            record.position = position
            record.updated = Date()
            remember(id, record)
        }
        if showAssist, config.snapAssist, let opposite = position.opposite {
            assist.show(area: opposite.frame(in: screen.area), excluding: id)
        }
    }

    /// 贴靠助手里选了一个窗口：放进另一半，并切换到它。
    private func fill(_ area: CGRect, with window: WindowElement) {
        let screens = ScreenGeometry.screens()
        guard let frame = window.frame,
              let target = screens.first(where: { $0.area.contains(CGPoint(x: area.midX, y: area.midY)) }),
              let position = WindowLayout.position(of: area, in: target.area, tolerance: 1) else { return }
        let fromArea = ScreenGeometry.index(of: frame, in: screens).map { screens[$0].area } ?? target.area
        snap(window, id: window.windowID, from: frame, fromArea: fromArea, to: position, on: target, showAssist: false)
        window.focus()
    }

    private func remember(_ id: CGWindowID, _ record: Record) {
        history[id] = record
        // 关掉的窗口留下的记录，太多时去掉最旧的
        if history.count > 300, let oldest = history.min(by: { $0.value.updated < $1.value.updated })?.key {
            history[oldest] = nil
        }
    }

    // MARK: - 拖到屏幕边缘分屏

    private struct DragState {
        let snapshot: WindowDragSnapshot
        var motion: WindowDragMotion
        var window: (any SnappableWindow)?
        var lastSample: TimeInterval = 0
        var lastResolution: TimeInterval = -.infinity
        /// 拖之前的样子，分屏后恢复用
        var restoreFrame: CGRect
        var target: (position: WindowLayout.Position, screen: ScreenGeometry.Screen)?
    }

    private func handleMouse(_ event: NSEvent) {
        let point = ScreenGeometry.axPoint(NSEvent.mouseLocation)
        switch event.type {
        case .leftMouseDown:
            cancelDrag()
            // 系统自带的拖动分屏开着时让它来，两个一起会打架
            guard ignoresNativeTiling || !NativeTiling.dragTilingEnabled else { return }
            let number = event.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? 0
            guard let snapshot = WindowDragSnapshot.under(point, windowID: number > 0 ? CGWindowID(exactly: number) : nil) else { return }
            if snapshot.pid == getpid(), OwnWindow.matching(snapshot.id, in: NSApp.windows) is NSPanel { return }
            drag = DragState(snapshot: snapshot, motion: WindowDragMotion(frame: snapshot.frame, cursor: point), restoreFrame: snapshot.frame)
            // 自绘窗口可能在自己的拖动循环中吞掉 dragged/up；仅在按下期间轮询这一个窗口。
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                let cursor = ScreenGeometry.axPoint(NSEvent.mouseLocation)
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.finishDrag(cursor: cursor, modifiers: NSEvent.modifierFlags)
                } else {
                    self.updateDrag(cursor: cursor, modifiers: NSEvent.modifierFlags)
                }
            }
            dragTimer = timer
            RunLoop.main.add(timer, forMode: .common)

        case .leftMouseDragged:
            updateDrag(cursor: point, modifiers: event.modifierFlags)

        case .leftMouseUp:
            finishDrag(cursor: point, modifiers: event.modifierFlags)

        default:
            break
        }
    }

    private func cancelDrag() {
        dragGeneration += 1
        dragTimer?.invalidate()
        dragTimer = nil
        drag = nil
        preview.hide()
        previewFrame = nil
        stickyEdges.deactivate()
    }

    private func updateDrag(cursor: CGPoint, modifiers: NSEvent.ModifierFlags, force: Bool = false) {
        guard var state = drag else { return }
        // 系统的“按住 ⌥ 拖动平铺”开着时，按着 ⌥ 拖让给系统。
        if modifiers.contains(.option) && NativeTiling.optionAcceleratorEnabled && !ignoresNativeTiling {
            cancelDrag()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - state.lastSample >= 1.0 / 60 else { return }
        state.lastSample = now
        guard let frame = state.snapshot.currentFrame else {
            cancelDrag() // 窗口关闭了。
            return
        }
        switch state.motion.update(frame: frame, cursor: cursor) {
        case .waiting:
            drag = state // 选文字、拖文件时窗口没有移动，不调用 AX。
            return
        case .resizing:
            cancelDrag()
            return
        case .moving:
            break
        }
        if state.window == nil {
            guard now - state.lastResolution >= 0.15 else { drag = state; return }
            state.lastResolution = now
            if state.snapshot.pid == getpid() {
                guard let own = OwnWindow.matching(state.snapshot.id, in: NSApp.windows),
                      !(own is NSPanel), own.isMovable, !own.styleMask.contains(.fullScreen) else { cancelDrag(); return }
                state.window = OwnWindow(window: own)
            } else {
                guard let window = WindowElement.matching(state.snapshot, currentFrame: frame) else { drag = state; return }
                guard window.isMovable, !window.isFullScreen, !window.isMinimized else { cancelDrag(); return }
                state.window = window
            }
            stickyEdges.activate(screens: ScreenGeometry.screens().map(\.frame))
            if let window = state.window { unsnapIfNeeded(window, frame: frame, cursor: cursor, state: &state) }
        }
        updateTarget(cursor: cursor, state: &state)
        drag = state
    }

    private func finishDrag(cursor: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard drag != nil else { return } // 定时器可能已经处理了松开，随后到达的 up 事件不能取消待执行分屏。
        // 松开时再读一次：快速拖动或最后一下离开边缘，不能沿用旧的目标。
        updateDrag(cursor: cursor, modifiers: modifiers, force: true)
        let state = drag
        cancelDrag()
        guard let state, state.motion.phase == .moving, let target = state.target, let window = state.window else { return }
        let generation = dragGeneration
        let restoreFrame = state.restoreFrame
        // 等应用处理完这次拖动的最后一下再放；新的拖动或关闭功能会取消这次延迟操作。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.dragGeneration == generation, self.config.enabled, self.config.dragToSnap else { return }
            let screens = ScreenGeometry.screens()
            let fromArea = ScreenGeometry.index(of: restoreFrame, in: screens).map { screens[$0].area } ?? target.screen.area
            self.history[state.snapshot.id]?.snappedFrame = nil
            self.snap(window, id: state.snapshot.id, from: restoreFrame, fromArea: fromArea,
                      to: target.position, on: target.screen, showAssist: true)
        }
    }

    /// 拖动一个分着屏的窗口时，马上恢复原来的大小，窗口跟着鼠标走。
    private func unsnapIfNeeded(_ window: any SnappableWindow, frame: CGRect, cursor: CGPoint, state: inout DragState) {
        let id = state.snapshot.id
        let startFrame = state.snapshot.frame
        guard let record = history[id], let snapped = record.snappedFrame,
              abs(startFrame.width - snapped.width) <= 2, abs(startFrame.height - snapped.height) <= 2,
              let restore = record.restoreFrame else { return }
        let unsnapped = WindowLayout.unsnappedFrame(current: frame, restoreSize: restore.size, cursor: cursor)
        let actual = window.setFrame(unsnapped) ?? unsnapped
        state.restoreFrame = actual
        state.motion.rebase(afterRestoring: actual)
        history[id] = nil
    }

    private func updateTarget(cursor: CGPoint, state: inout DragState) {
        let screens = ScreenGeometry.screens()
        let target = WindowLayout.dragTarget(cursor: cursor, screens: screens.map(\.frame)).map { (position: $0.position, screen: screens[$0.screen]) }
        let changed = target?.position != state.target?.position || target?.screen.frame != state.target?.screen.frame
        state.target = target
        previewFrame = target.map { $0.position.frame(in: $0.screen.area) }
        guard changed else { return }
        if let target {
            preview.show(ScreenGeometry.appKitRect(target.position.frame(in: target.screen.area)))
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        } else {
            preview.hide()
        }
    }
}

/// macOS 15 起系统自带的拖动分屏（“系统设置 → 桌面与程序坞 → 将窗口拖到屏幕边缘以平铺”）。
/// 和我们的拖动分屏同时开着会打架：两边都去摆窗口。
enum NativeTiling {
    private static let domain = "com.apple.WindowManager"

    /// 拖到左右边、四个角平铺，或者拖到上边（菜单栏）填满屏幕，开着任何一个都会和我们抢
    static var dragTilingEnabled: Bool {
        guard #available(macOS 15, *) else { return false }
        return enabled("EnableTilingByEdgeDrag") || enabled("EnableTopTilingByEdgeDrag")
    }

    /// 按住 ⌥ 拖动时平铺。只在按着 ⌥ 时起作用，那时让给系统
    static var optionAcceleratorEnabled: Bool {
        guard #available(macOS 15, *) else { return false }
        return enabled("EnableTilingOptionAccelerator")
    }

    /// 没写过就是开着（系统默认）
    private static func enabled(_ key: String) -> Bool {
        guard let defaults = UserDefaults(suiteName: domain), defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    /// 用户在设置里点了按钮才调用：关掉系统自带的拖动分屏（和在系统设置里关掉一样）
    static func disableDragTiling() {
        guard let defaults = UserDefaults(suiteName: domain) else { return }
        for key in ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"] {
            defaults.set(false, forKey: key)
        }
        defaults.synchronize()
        Log.app.notice("分屏：关掉了系统自带的拖动分屏")
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 拖动时显示目标区域；透明留白容纳原生玻璃的外部高光。
final class SnapPreview {
    private lazy var panel = SnapPanel(interactive: false)

    func show(_ frame: CGRect) {
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AppAnimation.duration(0.12)
                context.timingFunction = AppAnimation.timingFunction
                panel.setSurfaceFrame(frame, animated: true)
            }
        } else {
            panel.setSurfaceFrame(frame)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

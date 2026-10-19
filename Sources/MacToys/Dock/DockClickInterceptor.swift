// SPDX-License-Identifier: MIT

import AppKit

/// 事件线程只检查主线程发布的 Dock 命中区域；AX 查询和窗口操作不进入拦截回调。
final class DockClickInterceptor {
    struct Target {
        let hit: DockAppHit
        let frame: CGRect // AX 屏幕坐标
    }
    let target = Locked<Target?>(nil)
    var onClick: (DockAppHit, CGPoint, CGEvent, CGEvent) -> Void = { _, _, _, _ in }
    private var pressed: (target: Target, down: CGEvent)?

    func handle(type: CGEventType, event: CGEvent, postDragDown: (CGEvent) -> Void) -> Bool {
        switch type {
        case .leftMouseDown:
            pressed = nil
            guard event.flags.intersection(.modifierKeys).isEmpty,
                  let target = target.get(), target.frame.contains(event.location),
                  let down = event.copy() else { return false }
            pressed = (target, down)
            return true
        case .leftMouseDragged:
            guard let press = pressed else { return false }
            pressed = nil
            // 一开始拖动就交还原始按下，Dock 的拖图标行为继续正常工作。
            press.down.setIntegerValueField(.eventSourceUserData, value: Synthetic.marker)
            postDragDown(press.down)
            return false
        case .leftMouseUp:
            guard let press = pressed, let up = event.copy() else { return false }
            pressed = nil
            guard press.target.frame.contains(event.location) else {
                Self.replay(down: press.down, up: up)
                return true
            }
            let point = press.down.location
            DispatchQueue.main.async { [weak self] in
                self?.onClick(press.target.hit, point, press.down, up)
            }
            return true
        default:
            return false
        }
    }

    static func replay(down: CGEvent, up: CGEvent) {
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: Synthetic.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

/// 状态读取失败、全屏窗口和多窗口应用继续使用 Dock 默认行为。
enum DockSingleWindowAction: Equatable {
    case restore, activate, minimize

    static func resolve(windowCount: Int, minimized: Bool?, fullScreen: Bool, active: Bool) -> Self? {
        guard windowCount == 1, let minimized, !fullScreen else { return nil }
        if minimized { return .restore }
        return active ? .minimize : .activate
    }
}

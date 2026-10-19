// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices

/// 系统权限：
/// - 辅助功能：改写按键、模拟粘贴、查询光标位置
/// - 输入监控：系统事件监听
/// - 读取剪贴板：见 PasteboardAccess
enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    /// 弹出系统的授权提示，同时把本程序加进“辅助功能”列表。
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    /// 把本程序加进“输入监控”列表，系统会弹出提示。
    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        openInputMonitoringSettings()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openPasteboardSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        // 已授权时系统不会再弹提示，仍需要导航到对应页供用户检查。
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    fileprivate static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 读取剪贴板的权限。
///
/// 从 macOS 15.4 起系统可以限制程序自动读取剪贴板：第一次读取时弹出询问，之后用户在
/// “系统设置 → 隐私与安全性 → 粘贴”里为每个程序选择“询问 / 始终允许 / 始终拒绝”。
/// 剪贴板历史要在后台记录每次复制，必须是“始终允许”，否则每次复制都会弹窗。
enum PasteboardAccess {
    enum Status: Equatable {
        case allowed
        /// 还没设置成“始终允许”
        case needsSetup
        case denied
    }

    static var status: Status {
        guard #available(macOS 15.4, *) else { return .allowed }
        return status(for: NSPasteboard.general.accessBehavior)
    }

    static func status(for behavior: NSPasteboard.AccessBehavior) -> Status {
        switch behavior {
        case .alwaysAllow:
            return .allowed
        case .alwaysDeny:
            return .denied
        case .ask:
            return .needsSetup
        case .default:
            // default 表示从未触发过系统询问，程序不能把它当成“始终允许”。
            return .needsSetup
        @unknown default:
            return .needsSetup
        }
    }

    /// 读一次剪贴板，让系统弹出询问并把本程序列进“系统设置”，再打开那一页。
    static func request() {
        _ = NSPasteboard.general.string(forType: .string)
        Permissions.openPasteboardSettings()
    }
}

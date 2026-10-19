// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices

struct DockAppHit {
    let pid: pid_t
    let name: String
    let icon: NSImage
    let url: URL
    let bundleID: String?
    /// AppKit 屏幕坐标。
    let frame: CGRect
    let edge: DockPreviewGeometry.Edge
}

/// 只通过 Dock 的辅助功能元素识别应用，不按本地化名字猜测。
enum DockHitResolver {
    struct Resolution {
        let app: DockAppHit?
        let dockFrame: CGRect?
    }

    static func app(at point: CGPoint) -> DockAppHit? {
        resolve(at: point).app
    }

    /// 同时识别 Dock 的列表区域；分隔线、废纸篓和图标间隙也算 Dock 内。
    static func resolve(at point: CGPoint) -> Resolution {
        let empty = Resolution(app: nil, dockFrame: nil)
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return empty }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.12)
        let axPoint = ScreenGeometry.axPoint(point)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(axPoint.x), Float(axPoint.y), &element) == .success,
              var current = element else { return empty }
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        let edge: DockPreviewGeometry.Edge = orientation == "left" ? .left : orientation == "right" ? .right : .bottom
        var hit: DockAppHit?
        var dockFrame: CGRect?
        for _ in 0..<10 {
            if current.string(kAXRoleAttribute) == kAXListRole as String, let frame = frame(of: current),
               let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                dockFrame = DockPreviewGeometry.dockRegion(frame: frame, edge: edge, screen: screen.frame)
                break
            }
            if current.string(kAXSubroleAttribute) == "AXApplicationDockItem",
               let url = applicationURL(current), let frame = frame(of: current),
               frame.insetBy(dx: -3, dy: -3).contains(point) {
                let running = NSWorkspace.shared.runningApplications.first {
                    $0.bundleURL?.standardizedFileURL == url.standardizedFileURL && !$0.isTerminated
                }
                let pid = running?.processIdentifier ?? -Int32((url.path.hashValue & 0x3fffffff) + 1)
                hit = DockAppHit(pid: pid, name: running?.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                 icon: running?.icon ?? NSWorkspace.shared.icon(forFile: url.path), url: url,
                                 bundleID: running?.bundleIdentifier ?? Bundle(url: url)?.bundleIdentifier, frame: frame, edge: edge)
            }
            guard let parent: AXUIElement = current.value(kAXParentAttribute) else { break }
            current = parent
        }
        return Resolution(app: hit, dockFrame: dockFrame)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: CGPoint = element.axValue(kAXPositionAttribute, type: .cgPoint),
              let size: CGSize = element.axValue(kAXSizeAttribute, type: .cgSize),
              size.width > 0, size.height > 0 else { return nil }
        return ScreenGeometry.appKitRect(CGRect(origin: position, size: size))
    }

    private static func applicationURL(_ element: AXUIElement) -> URL? {
        if let url: URL = element.value(kAXURLAttribute) { return url }
        if let string: String = element.value(kAXURLAttribute) {
            return string.hasPrefix("/") ? URL(fileURLWithPath: string) : URL(string: string)
        }
        return nil
    }
}

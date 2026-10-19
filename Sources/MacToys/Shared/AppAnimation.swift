// SPDX-License-Identifier: MIT

import QuartzCore
import SwiftUI

/// 进入和交互使用系统缓出曲线，退出使用缓入曲线，最多播放 0.3 秒。
enum AppAnimation {
    static let maximumDuration: TimeInterval = 0.3

    static func duration(_ requested: TimeInterval) -> TimeInterval {
        min(max(requested, 0), maximumDuration)
    }

    static func easeOut(duration requested: TimeInterval = maximumDuration) -> Animation {
        .easeOut(duration: duration(requested))
    }

    static func easeIn(duration requested: TimeInterval = maximumDuration) -> Animation {
        .easeIn(duration: duration(requested))
    }

    static var timingFunction: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    static var exitTimingFunction: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeIn) }
}

/// 系统负责阶段切换和插值；静态内容只应用整体变换，不按时钟逐帧重画。
final class AppAnimationTrigger: ObservableObject {
    @Published private(set) var value = 0
    func play() { value += 1 }
}

struct AppEntrance<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    var enabled = true
    var initialScale: CGFloat = 1
    var initialOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content.phaseAnimator([false, true, false], trigger: trigger) { view, starting in
            view
                .scaleEffect(enabled && starting ? initialScale : 1)
                .offset(y: enabled && starting ? initialOffset : 0)
                .opacity(enabled && starting ? 0 : 1)
        } animation: { starting in
            starting || !enabled ? nil : AppAnimation.easeOut()
        }
    }
}

// SPDX-License-Identifier: MIT

import Foundation
import Combine
import IOKit.pwr_mgt

enum KeepAwakeDuration: Int, Codable, CaseIterable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case fourHours = 14400
    case unlimited = 0

    var seconds: TimeInterval? { self == .unlimited ? nil : TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .fifteenMinutes: L("15 分钟")
        case .thirtyMinutes: L("30 分钟")
        case .oneHour: L("1 小时")
        case .twoHours: L("2 小时")
        case .fourHours: L("4 小时")
        case .unlimited: L("无限时")
        }
    }
}

/// 只阻止空闲导致的屏幕和系统睡眠；合盖和用户主动睡眠仍交给系统。只在主线程调用。
final class KeepAwakeController: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var deadline: Date?
    @Published private(set) var problem: String?
    var onChange: (() -> Void)?

    private var assertion: IOPMAssertionID?
    private var timer: Timer?
    private let now: () -> Date
    private let createAssertion: (TimeInterval?) -> IOPMAssertionID?
    private let releaseAssertion: (IOPMAssertionID) -> Void

    init(now: @escaping () -> Date = Date.init,
         createAssertion: @escaping (TimeInterval?) -> IOPMAssertionID? = KeepAwakeController.createAssertion,
         releaseAssertion: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        self.now = now
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
    }

    deinit {
        timer?.invalidate()
        if let assertion { releaseAssertion(assertion) }
    }

    var remainingMinutes: Int? {
        deadline.map { max(0, Int(ceil($0.timeIntervalSince(now()) / 60))) }
    }

    var statusText: String {
        guard isActive else { return L("保持唤醒：已关闭") }
        if let minutes = remainingMinutes { return L("保持唤醒：剩余 %ld 分钟", minutes) }
        return L("保持唤醒：无限时")
    }

    /// 先取得新的断言，再释放旧的；切换时长失败时保留原来的唤醒会话。
    @discardableResult
    func start(for duration: KeepAwakeDuration) -> Bool {
        guard let next = createAssertion(duration.seconds) else {
            problem = L("系统未能开启保持唤醒，请稍后重试。")
            return false
        }
        problem = nil
        timer?.invalidate()
        if let assertion { releaseAssertion(assertion) }
        assertion = next
        isActive = true
        deadline = duration.seconds.map { now().addingTimeInterval($0) }
        refresh()
        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let assertion { releaseAssertion(assertion) }
        assertion = nil
        isActive = false
        deadline = nil
        problem = nil
        onChange?()
    }

    /// 定时刷新及系统唤醒时检查截止时间，避免睡眠期间已到期的会话继续显示为开启。
    func refresh() {
        objectWillChange.send()
        timer?.invalidate()
        timer = nil
        if let deadline {
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { stop(); return }
            let timer = Timer(timeInterval: min(remaining, 60), repeats: false) { [weak self] _ in
                self?.refresh()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        onChange?()
    }

    private static func createAssertion(seconds: TimeInterval?) -> IOPMAssertionID? {
        var assertion = IOPMAssertionID(0)
        // 系统也负责超时关闭，即使主线程繁忙，计时结束后也不再阻止睡眠。
        // 用 TurnOff 而不是 Release，断言的释放始终由本控制器负责。
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            "MacToys Keep Awake" as CFString, nil, nil, nil,
            seconds ?? 0, kIOPMAssertionTimeoutActionTurnOff as CFString, &assertion
        )
        guard result == kIOReturnSuccess else {
            Log.app.error("无法开启保持唤醒：\(result)")
            return nil
        }
        return assertion
    }
}

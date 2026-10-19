// SPDX-License-Identifier: MIT

import AppKit
import IOKit.pwr_mgt
import Testing
@testable import MacToys

@Suite("保持唤醒") @MainActor
struct KeepAwakeTests {
    private final class Harness {
        var date = Date(timeIntervalSince1970: 1_000)
        var created: [TimeInterval?] = []
        var released: [IOPMAssertionID] = []
        var fails = false
        lazy var controller = KeepAwakeController(now: { self.date }, createAssertion: { seconds in
            self.created.append(seconds)
            return self.fails ? nil : IOPMAssertionID(self.created.count)
        }, releaseAssertion: { self.released.append($0) })
    }

    @Test func indefiniteSessionStopsAndReleasesOnlyOnce() {
        let h = Harness()
        #expect(!h.controller.isActive && h.controller.deadline == nil)
        #expect(h.controller.start(for: .unlimited))
        #expect(h.controller.isActive && h.controller.deadline == nil)
        #expect(h.created.count == 1 && h.created[0] == nil)
        h.date = h.date.addingTimeInterval(86_400)
        h.controller.refresh()
        #expect(h.controller.isActive)
        h.controller.stop()
        h.controller.stop()
        #expect(!h.controller.isActive && h.released == [1])
    }

    @Test func deadlineExpiresIncludingTimeSpentAsleep() {
        let h = Harness()
        var changes = 0
        h.controller.onChange = { changes += 1 }
        #expect(h.controller.start(for: .fifteenMinutes))
        #expect(h.created == [900])
        #expect(h.controller.remainingMinutes == 15)
        h.date = h.date.addingTimeInterval(899)
        h.controller.refresh()
        #expect(h.controller.isActive && h.controller.remainingMinutes == 1)
        h.date = h.date.addingTimeInterval(601)
        h.controller.refresh()
        #expect(!h.controller.isActive && h.controller.deadline == nil)
        #expect(h.released == [1] && changes == 3)
    }

    @Test func changingDurationReplacesAssertionAndRestartsCountdown() {
        let h = Harness()
        h.controller.start(for: .fifteenMinutes)
        h.date = h.date.addingTimeInterval(600)
        h.controller.start(for: .oneHour)
        #expect(h.controller.remainingMinutes == 60 && h.released == [1])
        h.date = h.date.addingTimeInterval(301)
        h.controller.refresh()
        #expect(h.controller.isActive && h.controller.remainingMinutes == 55)
        h.controller.start(for: .unlimited)
        #expect(h.controller.deadline == nil && h.released == [1, 2])
        h.controller.stop()
        #expect(h.released == [1, 2, 3])
    }

    @Test func failedStartDoesNotShowActiveOrDiscardExistingSession() {
        let h = Harness()
        h.fails = true
        #expect(!h.controller.start(for: .unlimited))
        #expect(!h.controller.isActive && h.released.isEmpty)
        #expect(h.controller.problem != nil)
        h.fails = false
        h.controller.start(for: .thirtyMinutes)
        let deadline = h.controller.deadline
        h.fails = true
        #expect(!h.controller.start(for: .twoHours))
        #expect(h.controller.isActive && h.controller.deadline == deadline && h.released.isEmpty)
        h.controller.stop()
        #expect(h.released == [2])
        #expect(h.controller.problem == nil)
    }

    @Test func releasingControllerReleasesPowerAssertion() {
        var released: [IOPMAssertionID] = []
        var controller: KeepAwakeController? = KeepAwakeController(
            createAssertion: { _ in 42 }, releaseAssertion: { released.append($0) }
        )
        controller?.start(for: .oneHour)
        controller = nil
        #expect(released == [42])
    }

    @Test func actualPowerAssertionPreventsIdleDisplaySleepAndIsReleased() throws {
        let controller = KeepAwakeController()
        defer { controller.stop() }
        #expect(controller.start(for: .fifteenMinutes))
        func assertions() throws -> [[String: Any]] {
            var value: Unmanaged<CFDictionary>?
            #expect(IOPMCopyAssertionsByProcess(&value) == kIOReturnSuccess)
            let dictionary = try #require(value?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
            return dictionary[NSNumber(value: getpid())] ?? []
        }
        let assertion = try #require(try assertions().first { $0[kIOPMAssertionNameKey] as? String == "MacToys Keep Awake" })
        #expect(assertion[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleDisplaySleep)
        #expect(assertion[kIOPMAssertionLevelKey] as? Int == Int(kIOPMAssertionLevelOn))
        #expect(assertion[kIOPMAssertionTimeoutKey] as? Double == 900)
        controller.stop()
        #expect(try assertions().allSatisfy { $0[kIOPMAssertionNameKey] as? String != "MacToys Keep Awake" })
    }

    @Test func oldAndInvalidDurationConfigsFallBackToIndefinite() throws {
        for json in [#"{}"#, #"{"keepAwake":{}}"#, #"{"keepAwake":{"duration":-1}}"#,
                     #"{"keepAwake":{"duration":"invalid"}}"#] {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
            #expect(config.keepAwake.duration == .unlimited)
        }
    }
}

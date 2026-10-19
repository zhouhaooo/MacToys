// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacToys

@Suite("Dock 预测预加载")
struct DockPreloadingTests {
    private final class Harness {
        var time: TimeInterval = 0
        var jobs: [() -> Void] = []
        var queries: [pid_t] = []
        var delivered: [pid_t] = []
        lazy var catalog = DockPreviewCatalog(query: { [unowned self] pid, _ in
            queries.append(pid)
            return []
        }, enqueue: { [unowned self] in jobs.append($0) }, deliver: { $0() },
           now: { [unowned self] in time })

        init() { catalog.onLoad = { [unowned self] pid, _ in delivered.append(pid) } }
        func finish(_ index: Int = 0) { jobs.remove(at: index)() }
        func request(_ pid: pid_t, _ priority: DockPreviewCatalog.Priority, refresh: Bool = false) {
            catalog.request(pid: pid, name: "App", priority: priority, refresh: refresh)
        }
    }

    @Test func hoverReusesInFlightPredictionAndFreshCache() {
        let h = Harness()
        h.request(101, .prediction)
        h.request(101, .hover)
        h.request(101, .hover)
        #expect(h.jobs.count == 1 && h.delivered.isEmpty)
        h.finish()
        h.request(101, .hover)
        #expect(h.jobs.isEmpty && h.queries == [101] && h.catalog.windows(for: 101) != nil)
        h.time = 5.01
        h.request(101, .hover)
        #expect(h.jobs.count == 1 && h.catalog.windows(for: 101) == nil)
    }

    @Test func slowPredictionLeavesRoomForActualHoverAndLatestHoverWins() {
        let h = Harness()
        h.request(101, .prediction)
        h.request(102, .prediction)
        h.request(103, .hover)
        h.request(104, .hover)
        h.request(105, .hover)
        #expect(h.jobs.count == 2)
        h.finish(1) // 真实悬停先结束，不用等待慢预测。
        #expect(h.queries == [103] && h.jobs.count == 2)
        h.finish(1)
        #expect(h.queries == [103, 105])
        h.finish()
        h.finish()
        #expect(h.queries == [103, 105, 101, 102] && h.jobs.isEmpty)
    }

    @Test func returningToActiveTargetDiscardsQueuedHoverForOldTarget() {
        let h = Harness()
        h.request(101, .prediction)
        h.request(102, .hover)
        h.request(103, .hover)
        h.request(102, .hover)
        h.finish(1)
        h.finish()
        #expect(h.queries == [102, 101] && h.jobs.isEmpty)
    }

    @Test func olderCacheAppearsImmediatelyAndRevalidatesInBackground() {
        let h = Harness()
        h.request(101, .prediction)
        h.finish()
        h.time = 1
        h.request(101, .hover)
        h.request(101, .hover)
        #expect(h.catalog.windows(for: 101) != nil && h.jobs.count == 1)
        h.finish()
        #expect(h.jobs.isEmpty && h.queries == [101, 101])
    }

    @Test func leavingCancelsQueuedWorkButKeepsCompletedPrefetchForReturn() {
        let h = Harness()
        h.request(101, .prediction)
        h.request(102, .prediction)
        h.catalog.cancelPending()
        h.finish()
        #expect(h.jobs.isEmpty && h.queries == [101] && h.catalog.windows(for: 101) != nil)
    }

    @Test func resetRejectsOldResultsAndRetainsConcurrencyLimit() {
        let h = Harness()
        h.request(101, .hover)
        h.request(102, .hover)
        h.catalog.reset()
        h.request(103, .hover)
        #expect(h.jobs.count == 2)
        h.finish()
        #expect(h.delivered.isEmpty && h.catalog.windows(for: 101) == nil && h.jobs.count == 2)
        h.finish()
        h.finish()
        #expect(h.delivered == [103] && h.catalog.windows(for: 102) == nil)
    }

    @Test func catalogInvalidationDuringQueryRefreshesExactlyOnce() {
        let h = Harness()
        h.request(101, .hover)
        h.request(101, .hover, refresh: true)
        h.request(101, .hover, refresh: true)
        h.finish()
        #expect(h.jobs.count == 1 && h.catalog.windows(for: 101) == nil)
        h.finish()
        #expect(h.jobs.isEmpty && h.queries == [101, 101] && h.catalog.windows(for: 101) != nil)
    }

    @Test func closedWindowInvalidatesOnlyItsAppAndRejectsLateResults() {
        let h = Harness()
        h.request(101, .hover)
        h.finish()
        h.request(102, .hover)
        h.finish()
        h.time = 1
        h.request(101, .hover)
        h.catalog.invalidate(pid: 101)
        #expect(h.catalog.windows(for: 101) == nil)
        #expect(h.catalog.windows(for: 102) != nil)
        h.finish()
        #expect(h.catalog.windows(for: 101) == nil)
        #expect(h.delivered == [101, 102])
        h.request(101, .hover)
        h.finish()
        #expect(h.delivered == [101, 102, 101])
    }

    @Test func invalidatedQueriesStillOccupyConcurrencySlots() {
        let h = Harness()
        h.request(101, .hover)
        h.request(102, .hover)
        h.catalog.invalidate(pid: 101)
        h.request(101, .hover)
        #expect(h.jobs.count == 2)
        h.finish()
        #expect(h.delivered.isEmpty && h.jobs.count == 2)
        h.finish()
        h.finish()
        #expect(h.delivered == [102, 101])
    }

    @Test func actualHitWaitsOnlyForInFlightWindowQuery() {
        let h = Harness()
        var hover = DockHoverState()
        h.request(101, .prediction)
        h.time = 0.03
        let entered = hover.shouldShow(pid: 101, current: nil, now: h.time)
        #expect(entered && hover.nextDeadline == nil)
        #expect(h.catalog.windows(for: 101) == nil)
        h.request(101, .hover)
        h.time = 0.06
        h.finish()
        #expect(h.catalog.windows(for: 101) != nil)
        let loadingFinished = hover.shouldShow(pid: 101, current: nil, now: h.time)
        #expect(loadingFinished && hover.nextDeadline == nil)
        #expect(h.jobs.isEmpty && h.queries == [101])
    }

    @Test func passingEmptyAppsOnDockKeepsOriginalOneSecondDismissalDeadline() {
        var hover = DockHoverState()
        let left = hover.trackPresence(inside: false, now: 1)
        let enteredEmpty = hover.shouldShow(pid: 102, current: 101, now: 1.05)
        #expect(!left && enteredEmpty && hover.nextDeadline == 2)
        // 空窗口结果不会调用 present/reset，换到下一个空图标也不延长期限。
        let crossedEmpty = hover.shouldShow(pid: 103, current: 101, now: 1.3)
        let beforeDeadline = hover.trackPresence(inside: false, now: 1.999)
        #expect(crossedEmpty && !beforeDeadline && hover.nextDeadline == 2)
        let deadline = hover.trackPresence(inside: false, now: 2)
        #expect(deadline)
    }

    @Test func leavingDockStartsExitImmediatelyEvenBeforeOneSecondDeadline() {
        var hover = DockHoverState()
        let onDock = hover.trackPresence(inside: false, onDock: true, now: 1)
        #expect(!onDock && hover.nextDeadline == 2)
        let leftDock = hover.shouldHide(inside: false, onDock: false, now: 1.1)
        #expect(leftDock && hover.nextDeadline == nil)
    }

    @Test func enteringPreviewOrItsPassageKeepsOpenOutsideDock() {
        var hover = DockHoverState()
        _ = hover.trackPresence(inside: false, onDock: true, now: 1)
        let enteredPreview = hover.shouldHide(inside: true, onDock: false, now: 1.1)
        #expect(!enteredPreview && hover.nextDeadline == nil)
    }

    @Test func dockRegionIncludesBaseAndGapsOnEveryEdgeWithoutCoveringDesktop() {
        let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let bottom = DockPreviewGeometry.dockRegion(frame: CGRect(x: -1000, y: 112, width: 600, height: 80),
                                                   edge: .bottom, screen: screen)
        #expect(bottom.contains(CGPoint(x: -700, y: 101)))
        #expect(bottom.contains(CGPoint(x: -900, y: 150)))
        #expect(!bottom.contains(CGPoint(x: -300, y: 150)))
        #expect(!bottom.contains(CGPoint(x: -700, y: 250)))
        let left = DockPreviewGeometry.dockRegion(frame: CGRect(x: -1428, y: 300, width: 80, height: 500),
                                                 edge: .left, screen: screen)
        #expect(left.contains(CGPoint(x: -1439, y: 500)))
        #expect(!left.contains(CGPoint(x: -1200, y: 500)))
        let right = DockPreviewGeometry.dockRegion(frame: CGRect(x: -92, y: 300, width: 80, height: 500),
                                                  edge: .right, screen: screen)
        #expect(right.contains(CGPoint(x: -1, y: 500)))
        #expect(!right.contains(CGPoint(x: -200, y: 500)))
        #expect(screen.contains(bottom) && screen.contains(left) && screen.contains(right))
    }

    @Test func reachingWindowedAppOrReturningToOriginalCancelsDismissal() {
        var hover = DockHoverState()
        _ = hover.trackPresence(inside: false, now: 1)
        _ = hover.shouldShow(pid: 102, current: 101, now: 1.1)
        let switchToWindowed = hover.shouldShow(pid: 103, current: 101, now: 1.3)
        #expect(switchToWindowed)
        hover.reset() // 有窗口的新 App 接管已显示的浮窗。
        #expect(hover.nextDeadline == nil)
        _ = hover.trackPresence(inside: false, now: 2)
        _ = hover.shouldShow(pid: 104, current: 103, now: 2.1)
        let returned = hover.shouldShow(pid: 103, current: 103, now: 2.2)
        #expect(!returned && hover.nextDeadline == nil)
    }

    @Test func predictionWorksOnAllDockEdgesAndOffsetScreens() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1200, y: 100, width: 1200, height: 800)] {
            for (start, end) in [
                (CGPoint(x: screen.midX, y: screen.minY + 170), CGPoint(x: screen.midX + 5, y: screen.minY + 140)),
                (CGPoint(x: screen.minX + 170, y: screen.midY), CGPoint(x: screen.minX + 140, y: screen.midY + 5)),
                (CGPoint(x: screen.maxX - 170, y: screen.midY), CGPoint(x: screen.maxX - 140, y: screen.midY + 5))
            ] {
                var prediction = DockPointerPrediction()
                #expect(prediction.target(point: start, now: 0, screens: [screen]) == nil)
                let target = prediction.target(point: end, now: 0.02, screens: [screen])
                #expect(target != nil && target != end && target.map(screen.contains) == true)
            }
        }
    }

    @Test func predictionIgnoresLeavingDockDesktopMovementPausesAndScreenCrossings() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for (start, end, elapsed) in [
            (CGPoint(x: 500, y: 80), CGPoint(x: 500, y: 110), 0.02),
            (CGPoint(x: 500, y: 500), CGPoint(x: 520, y: 470), 0.02),
            (CGPoint(x: 500, y: 100), CGPoint(x: 500, y: 80), 0.2),
            (CGPoint(x: -10, y: 100), CGPoint(x: 10, y: 80), 0.02),
            (CGPoint(x: 500, y: 100), CGPoint(x: 500.5, y: 100), 0.02)
        ] {
            var prediction = DockPointerPrediction()
            _ = prediction.target(point: start, now: 0, screens: [screen])
            #expect(prediction.target(point: end, now: elapsed, screens: [screen]) == nil)
        }
        var prediction = DockPointerPrediction()
        _ = prediction.target(point: CGPoint(x: 500, y: 100), now: 0, screens: [screen])
        prediction.reset()
        #expect(prediction.target(point: CGPoint(x: 500, y: 80), now: 0.02, screens: [screen]) == nil)
    }

    @Test func fastApproachPredictsIconBandInsteadOfOvershootingToScreenBorder() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        var prediction = DockPointerPrediction()
        _ = prediction.target(point: CGPoint(x: 500, y: 170), now: 0, screens: [screen])
        let target = prediction.target(point: CGPoint(x: 500, y: 140), now: 0.02, screens: [screen])
        #expect(target == CGPoint(x: 500, y: 32))
    }
}

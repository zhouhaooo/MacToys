// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacToys

@Suite("共享周期窗口缩略图") @MainActor
struct WindowThumbnailStoreTests {
    @MainActor private final class Clock {
        var work: [(TimeInterval, () -> Void)] = []
        var cancelled = Set<Int>()
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
            let index = work.count
            work.append((delay, action))
            return { self.cancelled.insert(index) }
        }
    }

    @MainActor private final class Backend {
        var windows: [WindowThumbnailStore.Window] = []
        var enumerations = 0
        var captures: [WindowThumbnailStore.Key] = []
        var waiting: [(WindowThumbnailStore.Key, CheckedContinuation<NSImage?, Never>)] = []
        var maximum = 0
        func enumerate() -> [WindowThumbnailStore.Window] {
            enumerations += 1
            return windows
        }
        func capture(_ window: WindowThumbnailStore.Window) async -> NSImage? {
            captures.append(window.key)
            return await withCheckedContinuation {
                waiting.append((window.key, $0))
                maximum = max(maximum, waiting.count)
            }
        }
        func finish(_ image: NSImage? = NSImage(size: CGSize(width: 10, height: 10))) {
            guard !waiting.isEmpty else { Issue.record("没有待完成的截图"); return }
            waiting.removeFirst().1.resume(returning: image)
        }
    }

    private func window(_ id: UInt32, pid: pid_t = 100, title: String = "Document") -> WindowThumbnailStore.Window {
        .init(key: .init(pid: pid, windowID: id), title: title, size: CGSize(width: 800, height: 600))
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("异步周期未在预期时间完成")
    }

    @Test func refreshRunsSilentlyAndReadingThePoolNeverTriggersCaptures() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = [window(1)]
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        #expect(store.image(pid: 100, windowID: 1) == nil && backend.captures.isEmpty)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { backend.waiting.count == 1 }
        #expect(clock.work.count == 1 && clock.work[0].0 == 2)
        let first = NSImage(size: CGSize(width: 10, height: 10))
        backend.finish(first)
        try await settle { store.completedRounds == 1 }
        let displayed = store.image(pid: 100, windowID: 1)
        #expect(displayed === first && backend.captures.count == 1)
        clock.work[0].1()
        try await settle { backend.waiting.count == 1 }
        let latest = NSImage(size: CGSize(width: 12, height: 12))
        backend.finish(latest)
        try await settle { store.completedRounds == 2 }
        #expect(store.image(pid: 100, windowID: 1) === latest && displayed === first)
        #expect(backend.enumerations == 2 && backend.captures.count == 2)
    }

    @Test func resizeRefreshBypassesCacheAndReenumeratesNewDimensions() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = [window(1)]
        var sizes: [CGSize] = []
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() }, capture: {
            sizes.append($0.size)
            return await backend.capture($0)
        }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { backend.waiting.count == 1 }
        let old = NSImage(size: CGSize(width: 800, height: 600))
        backend.finish(old)
        try await settle { store.completedRounds == 1 }
        let newSize = CGSize(width: 1200, height: 700)
        backend.windows = [.init(key: window(1).key, title: "Document", size: newSize)]
        let refresh = Task { await store.refreshImage(pid: 100, windowID: 1) }
        try await settle { backend.waiting.count == 1 }
        #expect(store.image(pid: 100, windowID: 1) === old)
        #expect(backend.enumerations == 2 && sizes.last == newSize)
        let latest = NSImage(size: newSize)
        backend.finish(latest)
        #expect(await refresh.value === latest)
        #expect(store.image(pid: 100, windowID: 1) === latest)
        #expect(clock.work.count == 1 && clock.work[0].0 == 2)
    }

    @Test func repeatedResizeRejectsOlderCapturesWithoutOverlappingSameWindow() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = [window(1)]
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { backend.waiting.count == 1 }
        let first = Task { await store.refreshImage(pid: 100, windowID: 1) }
        try await settle { backend.enumerations == 2 }
        for _ in 0..<10 { await Task.yield() }
        let second = Task { await store.refreshImage(pid: 100, windowID: 1) }
        try await settle { backend.enumerations == 3 }
        for _ in 0..<10 { await Task.yield() }
        #expect(backend.maximum == 1 && backend.captures.count == 1)
        backend.finish(NSImage(size: CGSize(width: 1, height: 1)))
        try await settle { backend.captures.count == 2 && backend.waiting.count == 1 }
        #expect(store.image(pid: 100, windowID: 1) == nil)
        let latest = NSImage(size: CGSize(width: 1200, height: 700))
        backend.finish(latest)
        #expect(await first.value == nil)
        #expect(await second.value === latest)
        #expect(store.image(pid: 100, windowID: 1) === latest && backend.maximum == 1)
    }

    @Test func explicitPresentationRefreshReplacesOnlyTarget() async throws {
        let clock = Clock()
        let old = NSImage(size: CGSize(width: 800, height: 600))
        let store = WindowThumbnailStore(enumerate: { [window(1), window(2)] }, capture: { _ in old },
            allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { store.completedRounds == 1 }
        let view = WindowThumbnailPresentation<Int>(store: store)
        let requests = [1, 2].map { WindowThumbnailPresentation<Int>.Request(
            id: $0, pid: 100, windowID: UInt32($0), title: "Document") }
        view.load(requests)
        view.prepareRefresh(1)
        #expect(view.images[1] === old && view.images[2] === old)
        let latest = NSImage(size: CGSize(width: 1200, height: 700))
        view.replaceImage(latest, for: 1)
        view.load(requests)
        #expect(view.images[1] === latest && view.images[2] === old)
        #expect(await store.refreshImage(pid: 100, windowID: 999) == nil)
    }

    @Test func failedOrCancelledResizeKeepsCachedImageAndRejectsLateCapture() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = [window(1)]
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { backend.waiting.count == 1 }
        let old = NSImage(size: CGSize(width: 800, height: 600))
        backend.finish(old)
        try await settle { store.completedRounds == 1 }
        let failure = Task { await store.refreshImage(pid: 100, windowID: 1) }
        try await settle { backend.waiting.count == 1 }
        backend.finish(nil)
        #expect(await failure.value == nil)
        #expect(store.image(pid: 100, windowID: 1) === old)
        let cancelled = Task { await store.refreshImage(pid: 100, windowID: 1) }
        try await settle { backend.waiting.count == 1 }
        cancelled.cancel()
        for _ in 0..<10 { await Task.yield() }
        backend.finish(NSImage(size: CGSize(width: 1, height: 1)))
        #expect(await cancelled.value == nil)
        #expect(store.image(pid: 100, windowID: 1) === old)
    }

    @Test func disablingSourceRejectsLateResultsAndStopsItsTimer() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = [window(1)]
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        try await settle { backend.waiting.count == 1 }
        store.apply(enabled: false)
        backend.finish()
        for _ in 0..<20 { await Task.yield() }
        clock.work[0].1()
        #expect(!store.enabled && store.windows.isEmpty && store.image(pid: 100, windowID: 1) == nil)
        #expect(backend.enumerations == 1 && clock.cancelled.contains(0))
    }

    @Test func slowCaptureRoundsNeverOverlapEvenAcrossDisableAndEnable() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = (1...3).map { window(UInt32($0)) }
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        try await settle { backend.waiting.count == 2 }
        #expect(backend.waiting.count == 2, "captures=\(backend.captures.count), maximum=\(backend.maximum)")
        clock.work[0].1()
        #expect(backend.enumerations == 1)
        store.apply(enabled: false)
        store.apply(enabled: true)
        clock.work[2].1()
        #expect(backend.enumerations == 1 && backend.maximum == 2)
        backend.finish()
        backend.finish()
        for _ in 0..<20 { await Task.yield() }
        clock.work[3].1()
        try await settle { backend.enumerations == 2 && backend.waiting.count == 2 }
        store.apply(enabled: false)
        backend.finish()
        backend.finish()
        #expect(backend.maximum == 2)
    }

    @Test func failurePreservesOldImageNextCycleReplacesItAndClosedWindowsAreRemoved() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = [window(1)]
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        try await settle { backend.waiting.count == 1 }
        let old = NSImage(size: CGSize(width: 10, height: 10))
        backend.finish(old)
        try await settle { store.hasCompletedRound }
        clock.work[0].1()
        try await settle { backend.waiting.count == 1 }
        backend.finish(nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(store.image(pid: 100, windowID: 1) === old)
        clock.work[1].1()
        try await settle { backend.waiting.count == 1 }
        let newest = NSImage(size: CGSize(width: 10, height: 10))
        backend.finish(newest)
        try await settle { store.image(pid: 100, windowID: 1) === newest }
        backend.windows = []
        clock.work[2].1()
        try await settle { store.windows.isEmpty }
        #expect(store.image(pid: 100, windowID: 1) == nil)
        store.apply(enabled: false)
    }

    @Test func identitiesSeparateAppsAndFallbackTitleMustBeUnique() async throws {
        let clock = Clock()
        let catalog = [window(1), window(1, pid: 200), window(2, title: "Other")]
        let store = WindowThumbnailStore(enumerate: { catalog },
            capture: { _ in NSImage(size: CGSize(width: 10, height: 10)) }, allowed: { true },
            schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        try await settle { store.hasCompletedRound }
        #expect(store.image(pid: 100, windowID: 1) !== store.image(pid: 200, windowID: 1))
        #expect(store.image(pid: 100, windowID: nil, title: "Document") === store.image(pid: 100, windowID: 1))
        #expect(store.image(pid: 100, windowID: 99, title: "Document") == nil)
        #expect(store.image(pid: 100, windowID: nil, title: "") == nil)
        store.apply(enabled: false)
    }

    @Test func memoryPressureClearsImagesAndNextScheduledRoundRebuildsWithoutRequest() async throws {
        let clock = Clock()
        var captures = 0
        let target = window(1)
        let store = WindowThumbnailStore(enumerate: { [target] },
            capture: { _ in captures += 1; return NSImage(size: CGSize(width: 10, height: 10)) },
            allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        try await settle { store.hasCompletedRound }
        store.releaseCachedImages()
        #expect(store.image(pid: 100, windowID: 1) == nil && captures == 1)
        clock.work[0].1()
        try await settle { store.hasCompletedRound && captures == 2 }
        #expect(store.image(pid: 100, windowID: 1) != nil)
        store.apply(enabled: false)
    }

    @Test func missingOrRevokedPermissionPreventsCaptureAndClearsCache() async throws {
        let clock = Clock()
        var allowed = false, captures = 0
        let target = window(1)
        let store = WindowThumbnailStore(enumerate: { [target] },
            capture: { _ in captures += 1; return NSImage(size: CGSize(width: 10, height: 10)) },
            allowed: { allowed }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        #expect(captures == 0)
        allowed = true
        clock.work[0].1()
        try await settle { store.hasCompletedRound }
        allowed = false
        clock.work[1].1()
        #expect(store.image(pid: 100, windowID: 1) == nil && captures == 1 && store.windows.isEmpty)
        store.apply(enabled: false)
    }

    @Test func snapAssistKeepsItsSnapshotUntilReopenedAndDoesNotQueryOnPoolRefresh() async throws {
        let clock = Clock()
        let target = window(1)
        var captures = 0, queries = 0
        var image = NSImage(size: CGSize(width: 10, height: 10))
        let store = WindowThumbnailStore(enumerate: { [target] }, capture: { _ in captures += 1; return image },
            allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { store.completedRounds == 1 }
        let first = store.image(pid: 100, windowID: 1)
        let model = SnapAssistModel()
        let candidate = SnapAssistModel.Candidate(id: 1,
            window: WindowElement(element: AXUIElementCreateApplication(100), pid: 100), title: "Document",
            appName: "App", icon: NSImage(), size: target.size)
        let assist = SnapAssist(thumbnails: store, model: model, queryCandidates: { _ in queries += 1; return [candidate] },
            retainsFocus: false, onChoose: { _, _ in })
        assist.show(area: CGRect(x: 100, y: 100, width: 600, height: 600), excluding: nil)
        try await settle { model.candidates.count == 1 }
        #expect(model.thumbnails[1] === first && captures == 1 && model.previewState == .ready)
        image = NSImage(size: CGSize(width: 12, height: 12))
        clock.work[0].1()
        try await settle { store.completedRounds == 2 }
        #expect(store.image(pid: 100, windowID: 1) === image)
        #expect(model.thumbnails[1] === first && queries == 1 && captures == 2)
        assist.hide()
        assist.show(area: CGRect(x: 100, y: 100, width: 600, height: 600), excluding: nil)
        try await settle { model.candidates.count == 1 }
        #expect(model.thumbnails[1] === image && queries == 2 && captures == 2)
        assist.hide()
        clock.work[1].1()
        try await settle { captures == 3 }
        #expect(store.enabled && !assist.isVisible && model.thumbnails.isEmpty)
    }

    @Test func cacheMissCapturesBeforeNextTickAndConcurrentConsumersShareTheInFlightImage() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = [window(1)]
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { backend.waiting.count == 1 }
        // 两个消费方和正在进行的周期截图共用同一张结果。
        let first = Task { await store.requestImage(pid: 100, windowID: 1) }
        let second = Task { await store.requestImage(pid: 100, windowID: 1) }
        for _ in 0..<20 { await Task.yield() }
        #expect(backend.captures.count == 1)
        let image = NSImage(size: CGSize(width: 10, height: 10))
        backend.finish(image)
        #expect(await first.value === image)
        #expect(await second.value === image)
        try await settle { store.completedRounds == 1 }
        #expect(await store.requestImage(pid: 100, windowID: 1) === image)
        #expect(backend.captures.count == 1 && backend.enumerations == 1)
        // 后续清池缺图可立即补拍，不用触发时钟。
        store.releaseCachedImages()
        let missing = Task { await store.requestImage(pid: 100, windowID: 1) }
        try await settle { backend.waiting.count == 1 }
        #expect(backend.captures.count == 2 && backend.enumerations == 1)
        backend.finish(image)
        #expect(await missing.value === image)
    }

    @Test func newWindowMissReenumeratesImmediatelyAndTitleFallbackNeverGuesses() async throws {
        let clock = Clock()
        var catalog = [window(1)]
        var enumerations = 0, captured: [UInt32] = []
        let image = NSImage(size: CGSize(width: 10, height: 10))
        let store = WindowThumbnailStore(enumerate: { enumerations += 1; return catalog },
            capture: { captured.append($0.key.windowID); return image }, allowed: { true },
            schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { store.completedRounds == 1 }
        catalog.append(window(2, title: "New"))
        #expect(await store.requestImage(pid: 100, windowID: 2) === image)
        #expect(enumerations == 2 && captured == [1, 2])
        store.releaseCachedImages()
        #expect(await store.requestImage(pid: 100, windowID: nil, title: "New") === image)
        catalog.append(window(3, title: "New"))
        _ = await store.requestImage(pid: 100, windowID: 999)
        let previous = captured.count
        #expect(await store.requestImage(pid: 100, windowID: nil, title: "New") == nil)
        #expect(await store.requestImage(pid: 200, windowID: 2) == nil)
        #expect(captured.count == previous)
    }

    @Test func urgentMissTakesNextFreeSlotAheadOfPeriodicWorkAndSharesGlobalLimit() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = (1...5).map { window(UInt32($0)) }
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        try await settle { backend.waiting.count == 2 }
        let request = Task { await store.requestImage(pid: 100, windowID: 5) }
        for _ in 0..<20 { await Task.yield() }
        #expect(backend.maximum == 2 && backend.captures.count == 2)
        backend.finish()
        try await settle { backend.captures.count >= 3 }
        #expect(backend.captures[2].windowID == 5 && backend.maximum == 2)
        store.apply(enabled: false)
        while !backend.waiting.isEmpty { backend.finish() }
        #expect(await request.value == nil)
    }

    @Test func presentationsForBothConsumersFreezeFirstImageAndRejectOldReplies() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = [window(1)]
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { backend.waiting.count == 1 }
        let dock = WindowThumbnailPresentation<String>(store: store)
        let assist = WindowThumbnailPresentation<UInt32>(store: store)
        var dockUpdates = 0, assistUpdates = 0
        dock.onImage = { _, _ in dockUpdates += 1 }
        assist.onImage = { _, _ in assistUpdates += 1 }
        let dockRequest = WindowThumbnailPresentation<String>.Request(id: "AX-window", pid: 100, windowID: 1, title: "Document")
        let assistRequest = WindowThumbnailPresentation<UInt32>.Request(id: 1, pid: 100, windowID: 1, title: "Document")
        dock.load([dockRequest]); assist.load([assistRequest])
        #expect(dock.isLoading && assist.isLoading)
        for _ in 0..<20 { await Task.yield() }
        let first = NSImage(size: CGSize(width: 10, height: 10))
        backend.finish(first)
        try await settle { !dock.isLoading && !assist.isLoading && store.completedRounds == 1 }
        #expect(dock.images["AX-window"] === first && assist.images[1] === first)
        #expect(dockUpdates == 1 && assistUpdates == 1 && backend.captures.count == 1)
        clock.work[0].1()
        try await settle { backend.waiting.count == 1 }
        let latest = NSImage(size: CGSize(width: 12, height: 12))
        backend.finish(latest)
        try await settle { store.completedRounds == 2 }
        dock.load([dockRequest]); assist.load([assistRequest])
        #expect(dock.images["AX-window"] === first && assist.images[1] === first)
        #expect(dockUpdates == 1 && assistUpdates == 1)
        dock.reset(); assist.reset()
        dock.load([dockRequest]); assist.load([assistRequest])
        #expect(dock.images["AX-window"] === latest && assist.images[1] === latest)
        #expect(!dock.isLoading && !assist.isLoading && backend.captures.count == 2)
        // 缺图结果在关闭后到达，仅写共享池，不能再影响原面板。
        dock.reset(); store.releaseCachedImages(); dock.load([dockRequest])
        try await settle { backend.waiting.count == 1 }
        dock.reset()
        backend.finish(latest)
        try await settle { store.image(pid: 100, windowID: 1) === latest }
        #expect(dock.images.isEmpty && dockUpdates == 1)
    }

    @Test func failedMissFinishesLoadingAndDoesNotRetryUntilNextPresentation() async throws {
        let clock = Clock()
        let target = window(1)
        var captures = 0
        let store = WindowThumbnailStore(enumerate: { [target] }, capture: { _ in captures += 1; return nil },
            allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { store.completedRounds == 1 }
        let view = WindowThumbnailPresentation<Int>(store: store)
        let request = WindowThumbnailPresentation<Int>.Request(id: 1, pid: 100, windowID: 1, title: "Document")
        view.load([request])
        try await settle { !view.isLoading }
        #expect(captures == 2 && view.images.isEmpty)
        view.load([request])
        #expect(!view.isLoading && captures == 2)
        view.reset(); view.load([request])
        try await settle { !view.isLoading }
        #expect(captures == 3)
    }

    @Test func missDuringInitialEnumerationSharesCatalogAndDisablingRejectsItsLateCapture() async throws {
        let clock = Clock()
        let backend = Backend()
        let target = window(1)
        var catalogReply: CheckedContinuation<[WindowThumbnailStore.Window], Never>?
        var enumerations = 0
        let store = WindowThumbnailStore(enumerate: {
            enumerations += 1
            return await withCheckedContinuation { catalogReply = $0 }
        }, capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        try await settle { catalogReply != nil }
        let request = Task { await store.requestImage(pid: 100, windowID: 1) }
        for _ in 0..<20 { await Task.yield() }
        #expect(enumerations == 1)
        catalogReply?.resume(returning: [target])
        try await settle { backend.waiting.count == 1 }
        store.apply(enabled: false)
        backend.finish()
        #expect(await request.value == nil)
        #expect(store.image(pid: 100, windowID: 1) == nil && backend.captures.count == 1)
    }

    @Test func snapAssistFillsMissingImageOnceAndDoesNotReplaceItOnNextRound() async throws {
        let backend = Backend(), clock = Clock()
        let target = window(1)
        backend.windows = [target]
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { backend.waiting.count == 1 }
        let model = SnapAssistModel()
        let candidate = SnapAssistModel.Candidate(id: 1,
            window: WindowElement(element: AXUIElementCreateApplication(100), pid: 100), title: "Document",
            appName: "App", icon: NSImage(), size: target.size)
        let assist = SnapAssist(thumbnails: store, model: model, queryCandidates: { _ in [candidate] }, retainsFocus: false, onChoose: { _, _ in })
        assist.show(area: CGRect(x: 100, y: 100, width: 600, height: 600), excluding: nil)
        try await settle { model.candidates.count == 1 }
        #expect(model.thumbnails.isEmpty && model.previewState == .loading)
        let first = NSImage(size: CGSize(width: 10, height: 10))
        backend.finish(first)
        try await settle { model.thumbnails[1] === first && model.previewState == .ready && store.completedRounds == 1 }
        #expect(backend.captures.count == 1)
        clock.work[0].1()
        try await settle { backend.waiting.count == 1 }
        backend.finish(NSImage(size: CGSize(width: 12, height: 12)))
        try await settle { store.completedRounds == 2 }
        #expect(model.thumbnails[1] === first)
        assist.hide()
    }

    @Test func duplicateTitlesCannotMixWindowsAndCacheRetainsMemoryLimit() async throws {
        let clock = Clock()
        let catalog = (1...70).map { window(UInt32($0)) }
        let store = WindowThumbnailStore(enumerate: { catalog },
            capture: { _ in NSImage(size: CGSize(width: 480, height: 320)) }, allowed: { true },
            schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        try await settle { store.hasCompletedRound }
        #expect(store.image(pid: 100, windowID: nil, title: "Document") == nil)
        let count = catalog.filter { store.image(pid: $0.key.pid, windowID: $0.key.windowID) != nil }.count
        #expect(count <= 60 && count * 480 * 320 * 4 <= 32 << 20)
        store.apply(enabled: false)
    }

    @Test func memoryPressureDuringCaptureDiscardsPendingImagesUntilNextCycle() async throws {
        let backend = Backend(), clock = Clock()
        backend.windows = [window(1)]
        let store = WindowThumbnailStore(enumerate: { backend.enumerate() },
            capture: { await backend.capture($0) }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        try await settle { backend.waiting.count == 1 }
        store.releaseCachedImages()
        backend.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(store.image(pid: 100, windowID: 1) == nil && !store.hasCompletedRound)
        clock.work[0].1()
        try await settle { backend.waiting.count == 1 }
        backend.finish()
        try await settle { store.hasCompletedRound }
        #expect(store.image(pid: 100, windowID: 1) != nil)
        store.apply(enabled: false)
    }

    @Test func stuckCaptureTimesOutPreservesCacheAndNextCycleUpdatesWithoutReopeningPanels() async throws {
        let clock = Clock(), deadlines = Clock()
        let target = window(1)
        var captures = 0, cleanups = 0
        var late: ((Result<NSImage?, Error>) -> Void)?
        let old = NSImage(size: CGSize(width: 10, height: 10))
        let newest = NSImage(size: CGSize(width: 12, height: 12))
        let store = WindowThumbnailStore(enumerate: { [target] }, capture: { _ in
            captures += 1
            if captures == 2 {
                let request = WindowCaptureRequest<NSImage?>(timeout: 1, schedule: deadlines.schedule)
                return try await request.value { late = $0 } cleanup: { cleanups += 1 }
            }
            return captures == 1 ? old : newest
        }, allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { store.hasCompletedRound }
        clock.work[0].1()
        try await settle { late != nil }
        #expect(store.image(pid: 100, windowID: 1) === old)
        deadlines.work[0].1()
        try await settle { cleanups == 1 }
        for _ in 0..<20 { await Task.yield() }
        clock.work[1].1()
        try await settle { captures == 3 && store.image(pid: 100, windowID: 1) === newest }
        #expect(store.image(pid: 100, windowID: 1) === newest)
        late?(.success(old))
        #expect(cleanups == 1 && store.image(pid: 100, windowID: 1) === newest)
    }

    @Test func stuckEnumerationTimesOutAndLateCatalogCannotReplaceNextRound() async throws {
        let clock = Clock(), deadlines = Clock()
        let target = window(1), stale = window(2)
        var enumerations = 0, cleanups = 0
        var late: ((Result<[WindowThumbnailStore.Window], Error>) -> Void)?
        let store = WindowThumbnailStore(enumerate: {
            enumerations += 1
            if enumerations == 1 {
                let request = WindowCaptureRequest<[WindowThumbnailStore.Window]>(timeout: 3, schedule: deadlines.schedule)
                return try await request.value { late = $0 } cleanup: { cleanups += 1 }
            }
            return [target]
        }, capture: { _ in NSImage(size: CGSize(width: 10, height: 10)) },
           allowed: { true }, schedule: clock.schedule, observeMemoryPressure: false)
        store.apply(enabled: true)
        defer { store.apply(enabled: false) }
        try await settle { late != nil }
        deadlines.work[0].1()
        try await settle { cleanups == 1 }
        for _ in 0..<20 { await Task.yield() }
        clock.work[0].1()
        try await settle { store.completedRounds == 1 }
        late?(.success([stale]))
        #expect(enumerations == 2 && store.windows == [target])
        #expect(store.image(pid: 100, windowID: 1) != nil && store.image(pid: 100, windowID: 2) == nil)
    }

    @Test func captureCancellationStopsImmediatelyAndIgnoresLateCompletion() async throws {
        let clock = Clock()
        let request = WindowCaptureRequest<Int>(timeout: 1, schedule: clock.schedule)
        var late: ((Result<Int, Error>) -> Void)?
        var cleanups = 0
        let task = Task { @MainActor in
            try await request.value { late = $0 } cleanup: { cleanups += 1 }
        }
        try await settle { late != nil }
        task.cancel()
        switch await task.result {
        case .success: Issue.record("取消后不应成功")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(cleanups == 1 && clock.cancelled.contains(0))
        late?(.success(1))
        clock.work[0].1()
        #expect(cleanups == 1)
    }

    @Test func captureSuccessAndStartFailureCancelTheirTimeoutAndCleanupOnce() async throws {
        enum Failure: Error { case start }
        let clock = Clock()
        var cleanups = 0
        let success = WindowCaptureRequest<Int>(timeout: 1, schedule: clock.schedule)
        let value = try await success.value { $0(.success(42)) } cleanup: { cleanups += 1 }
        #expect(value == 42 && cleanups == 1 && clock.cancelled.contains(0))
        clock.work[0].1()
        let failure = WindowCaptureRequest<Int>(timeout: 1, schedule: clock.schedule)
        do {
            _ = try await failure.value { _ in throw Failure.start } cleanup: { cleanups += 1 }
            Issue.record("启动失败不应成功")
        } catch { #expect(error is Failure) }
        #expect(cleanups == 2 && clock.cancelled.contains(1))
        clock.work[1].1()
        #expect(cleanups == 2)
    }

    @Test func underlyingRequestsStayBoundedAcrossTimeoutCancellationAndLateCallbacks() async throws {
        let clock = Clock(), gate = WindowCaptureGate(limit: 2)
        var callbacks: [(Result<Int, Error>) -> Void] = []
        func launch() -> Task<Int, Error> {
            Task { @MainActor in
                try await gate.value(timeout: 1, schedule: clock.schedule) { callbacks.append($0) }
            }
        }
        let first = launch(), second = launch()
        try await settle { callbacks.count == 2 }
        clock.work[0].1()
        second.cancel()
        switch await first.result {
        case .success: Issue.record("应超时")
        case .failure(let error): #expect(error as? WindowCaptureRequestError == .timedOut)
        }
        switch await second.result {
        case .success: Issue.record("应取消")
        case .failure(let error): #expect(error is CancellationError)
        }
        // 模拟很多后续周期：底层请求还没返回时不能继续发截图。
        for _ in 0..<100 {
            do {
                let _: Int = try await gate.value(timeout: 1, schedule: clock.schedule) { _ in
                    Issue.record("超时后超过底层并发上限")
                }
                Issue.record("应拒绝新请求")
            } catch { #expect(error as? WindowCaptureRequestError == .busy) }
        }
        callbacks[0](.success(1))
        let third = launch()
        try await settle { callbacks.count == 3 }
        callbacks[0](.success(1)) // 重复回调不能释放第三个请求的名额。
        do {
            let _: Int = try await gate.value(timeout: 1) { _ in Issue.record("重复回调释放了多余名额") }
        } catch { #expect(error as? WindowCaptureRequestError == .busy) }
        callbacks[1](.success(2))
        callbacks[2](.success(3))
        #expect(try await third.value == 3)
        let value: Int = try await gate.value(timeout: 1) { $0(.success(4)) }
        #expect(value == 4)
    }

    @Test func failedRequestStartReleasesUnderlyingSlot() async throws {
        enum Failure: Error { case start }
        let gate = WindowCaptureGate(limit: 1)
        do {
            let _: Int = try await gate.value(timeout: 1) { _ in throw Failure.start }
            Issue.record("应报告启动失败")
        } catch { #expect(error is Failure) }
        let value: Int = try await gate.value(timeout: 1) { $0(.success(42)) }
        #expect(value == 42)
    }

    @Test func oversizedRetinaScreenshotIsDownsampledBeforeEnteringSharedCache() throws {
        let context = try #require(CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 100, y: 100, width: 3800, height: 2800))
        let source = try #require(context.makeImage())
        let size = CGSize(width: 2000, height: 1500)
        let card = try #require(WindowThumbnailStore.cardImage(from: source, size: size))
        let image = try #require(card.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(image.width <= 480 && image.height <= 320 && card.size == size)
        #expect(ImageCache<WindowThumbnailStore.Key>.cost(of: card) <= 480 * 320 * 4)
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        let alpha = try #require(bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.alphaComponent)
        #expect(abs(alpha - 0.5) < 0.01)
    }
}

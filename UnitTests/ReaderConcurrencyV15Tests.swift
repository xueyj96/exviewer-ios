import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class ReaderConcurrencyV15Tests: XCTestCase {
    private struct Call {
        let id: UUID
        let page: Int
        let demand: MediaRequestDemand
        var priority: MediaRequestPriority { demand.priority }
    }

    @MainActor private final class ControlledLoader {
        private(set) var calls: [Call] = []
        private(set) var cancelled = Set<UUID>()
        private(set) var maxPendingCount = 0
        private var pending: [UUID: CheckedContinuation<URL, Error>] = [:]
        private let automaticLatencyNanoseconds: UInt64?

        init(automaticLatencyNanoseconds: UInt64? = nil) {
            self.automaticLatencyNanoseconds = automaticLatencyNanoseconds
        }

        func load(_ page: GalleryPage, _ demand: MediaRequestDemand) async throws -> URL {
            let id = UUID()
            let call = Call(id: id, page: page.index, demand: demand)
            calls.append(call)
            if let automaticLatencyNanoseconds {
                try await Task.sleep(nanoseconds: automaticLatencyNanoseconds)
                try Task.checkCancellation()
                return fixtureURL(for: call)
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else {
                        pending[id] = continuation
                        maxPendingCount = max(maxPendingCount, pending.count)
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    self.cancelled.insert(id)
                    self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        }

        func fixtureURL(for call: Call) -> URL {
            URL(fileURLWithPath: "/fixture/reader-v15-\(call.page)-\(call.id.uuidString).media")
        }

        func resolve(_ call: Call) {
            pending.removeValue(forKey: call.id)?.resume(returning: fixtureURL(for: call))
        }

        func resolve(_ call: Call, as url: URL) {
            pending.removeValue(forKey: call.id)?.resume(returning: url)
        }

        func reject(_ call: Call, with error: Error) {
            pending.removeValue(forKey: call.id)?.resume(throwing: error)
        }

        func last(_ page: Int) -> Call? { calls.last { $0.page == page } }
        func count(_ page: Int) -> Int { calls.filter { $0.page == page }.count }
        func pendingCount() -> Int { pending.count }
    }

    private func pages(_ count: Int = 160) -> [GalleryPage] {
        (1...count).map { index in
            GalleryPage(index: index, url: URL(string: "https://ehentai.org/s/fixture/1-\(index)")!)
        }
    }

    private func scope(owner: String = "reader-v15") -> ReaderMediaScope {
        ReaderMediaScope(galleryID: "ex:15", owner: owner, generation: UUID(), context: UUID())
    }

    private func waitUntil(timeoutMilliseconds: Int = 1_500,
                           _ condition: () -> Bool) async -> Bool {
        for _ in 0..<max(1, timeoutMilliseconds / 5) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func update(_ store: ReaderMediaStore,
                        loader: ControlledLoader,
                        scope: ReaderMediaScope,
                        pages: [GalleryPage],
                        current: Int,
                        prefetchCount: Int,
                        downloadConcurrency: Int,
                        preview: Int? = nil,
                        validateCachedFile: ((URL) -> Bool)? = nil) {
        store.update(scope: scope, pages: pages, current: current, prefetchCount: prefetchCount,
                     downloadConcurrency: downloadConcurrency, preview: preview,
                     validateCachedFile: validateCachedFile,
                     demandLoader: loader.load, isCurrent: { true })
    }

    private func reset(_ store: ReaderMediaStore, loader: ControlledLoader) async {
        store.reset()
        _ = await waitUntil { loader.pendingCount() == 0 }
    }

    func testConcurrency16StartsCurrentAndFifteenPrefetchesThenFillsForward() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope(), galleryPages = pages()
        defer { store.reset() }
        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 999, downloadConcurrency: 16)

        let sixteenStarted = await waitUntil { loader.calls.count == 16 }
        XCTAssertTrue(sixteenStarted, "Sixteen concurrent requests should start promptly")
        XCTAssertEqual(store.downloadConcurrency, 16)
        XCTAssertEqual(store.prefetchCount, 128, "A requested window of 999 should clamp to 128")
        XCTAssertEqual(Set(loader.calls.map(\.page)), Set(1...16))
        XCTAssertEqual(loader.calls.first(where: { $0.page == 1 })?.priority, .foreground)
        XCTAssertTrue(loader.calls.filter { (2...16).contains($0.page) }.allSatisfy { $0.priority == .prefetch })
        XCTAssertEqual(store.inflight.count, 16)
        XCTAssertLessThanOrEqual(loader.maxPendingCount, 16)

        for page in 2...4 {
            loader.resolve(try XCTUnwrap(loader.last(page)))
            let nextCount = page + 15
            let filled = await waitUntil { loader.calls.count == nextCount }
            XCTAssertTrue(filled, "Completing page \(page) should promptly fill one forward slot")
            XCTAssertLessThanOrEqual(store.inflight.count, 16)
            XCTAssertLessThanOrEqual(loader.maxPendingCount, 16)
        }
        XCTAssertEqual(loader.calls.count, 19, "Exactly three completed slots should add pages 17...19")
        XCTAssertEqual(Set(loader.calls.suffix(3).map(\.page)), Set(17...19))
        await reset(store, loader: loader)
    }

    func testConcurrencyReductionFinishesInWindowWorkBeforeRefillingBelowTarget() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope(), galleryPages = pages(32)
        defer { store.reset() }
        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 20, downloadConcurrency: 4)
        let initialStarted = await waitUntil { loader.calls.count == 4 }
        XCTAssertTrue(initialStarted)
        let call2 = try XCTUnwrap(loader.last(2))
        let call3 = try XCTUnwrap(loader.last(3))
        let call4 = try XCTUnwrap(loader.last(4))

        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 20, downloadConcurrency: 2)
        XCTAssertEqual(store.downloadConcurrency, 2)
        XCTAssertEqual(loader.calls.count, 4, "Reducing the target does not restart active in-window transfers")
        XCTAssertFalse(loader.cancelled.contains(call2.id))
        XCTAssertFalse(loader.cancelled.contains(call3.id))
        XCTAssertFalse(loader.cancelled.contains(call4.id))

        loader.resolve(call2)
        loader.resolve(call3)
        let atTarget = await waitUntil { store.inflight.count == 2 }
        XCTAssertTrue(atTarget)
        XCTAssertEqual(loader.calls.count, 4, "At the target concurrency, the store must not start replacement work")
        loader.resolve(call4)
        let refilled = await waitUntil { loader.calls.count == 5 }
        XCTAssertTrue(refilled, "Once active work drops below two, the forward window should refill")
        XCTAssertEqual(loader.last(5)?.priority, .prefetch)
        XCTAssertLessThanOrEqual(store.inflight.count, 2)
        await reset(store, loader: loader)
    }

    func testScopeJumpCancelsOldWindowAndStartsNewSixteenPageWindow() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope(), galleryPages = pages()
        defer { store.reset() }
        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 128, downloadConcurrency: 16)
        let oldWindowStarted = await waitUntil { loader.calls.count == 16 }
        XCTAssertTrue(oldWindowStarted)
        let oldCalls = Array(loader.calls)

        update(store, loader: loader, scope: identity, pages: galleryPages, current: 80,
               prefetchCount: 128, downloadConcurrency: 16)
        let newWindowStarted = await waitUntil { loader.calls.count == 32 }
        XCTAssertTrue(newWindowStarted, "Jumping should cancel and replace the old active window")
        let oldCancelled = await waitUntil { oldCalls.allSatisfy { loader.cancelled.contains($0.id) } }
        XCTAssertTrue(oldCancelled, "Every request outside the jumped-to window should be cancelled")
        XCTAssertEqual(Set(loader.calls.suffix(16).map(\.page)), Set(80...95))
        XCTAssertEqual(store.inflight.count, 16)
        await reset(store, loader: loader)
    }

    func testPreviewAndCurrentPromotionReuseTheSamePrefetchCall() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope(), galleryPages = pages(8)
        defer { store.reset() }
        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 4, downloadConcurrency: 2)
        let initialStarted = await waitUntil { loader.calls.count == 2 }
        XCTAssertTrue(initialStarted)
        let prefetch = try XCTUnwrap(loader.last(2))
        XCTAssertEqual(prefetch.priority, .prefetch)

        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 4, downloadConcurrency: 2, preview: 2)
        XCTAssertEqual(prefetch.priority, .foreground)
        XCTAssertEqual(store.inflight[2], .foreground)
        XCTAssertEqual(loader.count(2), 1)
        XCTAssertFalse(loader.cancelled.contains(prefetch.id))

        update(store, loader: loader, scope: identity, pages: galleryPages, current: 2,
               prefetchCount: 4, downloadConcurrency: 2)
        XCTAssertEqual(prefetch.priority, .foreground)
        XCTAssertEqual(store.inflight[2], .foreground)
        XCTAssertEqual(loader.count(2), 1, "Current handoff must retain the promoted transfer")
        XCTAssertFalse(loader.cancelled.contains(prefetch.id))

        loader.resolve(prefetch)
        let promotedPageCached = await waitUntil { store.files[2] != nil }
        XCTAssertTrue(promotedPageCached, "The promoted page should finish on the original loader call")
        XCTAssertEqual(store.files[2], loader.fixtureURL(for: prefetch))
        XCTAssertEqual(loader.count(2), 1)
        await reset(store, loader: loader)
    }

    func testCachedReversePageIsReusedWithoutBackwardSpeculation() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope(), galleryPages = pages(8)
        defer { store.reset() }
        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 1, downloadConcurrency: 2)
        let started = await waitUntil { loader.calls.count == 2 }
        XCTAssertTrue(started)
        let page1 = try XCTUnwrap(loader.last(1))
        let page2 = try XCTUnwrap(loader.last(2))
        loader.resolve(page1)
        loader.resolve(page2)
        let loaded = await waitUntil { store.files[1] != nil && store.files[2] != nil }
        XCTAssertTrue(loaded)

        update(store, loader: loader, scope: identity, pages: galleryPages, current: 2,
               prefetchCount: 0, downloadConcurrency: 2)
        XCTAssertEqual(store.files[1], loader.fixtureURL(for: page1), "Loaded preceding page stays available for reverse reading")
        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 0, downloadConcurrency: 2)
        XCTAssertEqual(loader.count(1), 1, "Returning to the cached previous page should not start backward speculation")
        XCTAssertEqual(store.files[1], loader.fixtureURL(for: page1))
        await reset(store, loader: loader)
    }

    func testDeletedCurrentCacheEntryReloadsOnceWithoutClearingOtherCachedPage() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope(), galleryPages = pages(8)
        var validFiles = Set<URL>()
        var checkedFiles = Set<URL>()
        let validate: (URL) -> Bool = { url in
            checkedFiles.insert(url)
            return validFiles.contains(url)
        }
        defer { store.reset() }
        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 1, downloadConcurrency: 2, validateCachedFile: validate)
        let started = await waitUntil { loader.calls.count == 2 }
        XCTAssertTrue(started)
        let originalCurrent = try XCTUnwrap(loader.last(1))
        let prefetched = try XCTUnwrap(loader.last(2))
        let originalURL = loader.fixtureURL(for: originalCurrent)
        let prefetchURL = loader.fixtureURL(for: prefetched)
        validFiles.formUnion([originalURL, prefetchURL])
        loader.resolve(originalCurrent, as: originalURL)
        loader.resolve(prefetched, as: prefetchURL)
        let loaded = await waitUntil { store.files[1] == originalURL && store.files[2] == prefetchURL }
        XCTAssertTrue(loaded)

        validFiles.remove(originalURL)
        checkedFiles.removeAll()
        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 1, downloadConcurrency: 2, validateCachedFile: validate)
        XCTAssertNil(store.files[1], "A deleted current cache file must be evicted")
        XCTAssertEqual(store.files[2], prefetchURL, "Validation is limited to current/preview, preserving other prefetched cache entries")
        XCTAssertTrue(checkedFiles.contains(originalURL))
        XCTAssertFalse(checkedFiles.contains(prefetchURL))

        let secondCurrentStarted = await waitUntil { loader.count(1) == 2 }
        XCTAssertTrue(secondCurrentStarted, "A missing current file should start one reload")
        let replacement = try XCTUnwrap(loader.last(1))
        let replacementURL = loader.fixtureURL(for: replacement)
        validFiles.insert(replacementURL)
        loader.resolve(replacement, as: replacementURL)
        let replaced = await waitUntil { store.files[1] == replacementURL }
        XCTAssertTrue(replaced)
        update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
               prefetchCount: 1, downloadConcurrency: 2, validateCachedFile: validate)
        XCTAssertEqual(loader.count(1), 2, "Revalidation of the restored current file must not create a reload loop")
        XCTAssertEqual(store.files[2], prefetchURL)
        await reset(store, loader: loader)
    }

    func testQuotaChallengeAndRateLimitPauseSpeculativeWindowUntilExplicitRetry() async throws {
        let stoppingErrors: [(String, Error)] = [
            ("quota", ViewerError.imageLimit),
            ("challenge", ViewerError.challenge),
            ("http-429", RequestFailure.http(.media, 429))
        ]

        for (label, error) in stoppingErrors {
            let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope(owner: "pause-\(label)"), galleryPages = pages()
            update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
                   prefetchCount: 128, downloadConcurrency: 16)
            let windowStarted = await waitUntil { loader.calls.count == 16 }
            XCTAssertTrue(windowStarted, "The 16-slot prefetch window should start for \(label)")
            let currentCall = try XCTUnwrap(loader.last(1))
            let rejectedPrefetch = try XCTUnwrap(loader.last(2))
            let speculativeCalls = loader.calls.filter { (3...16).contains($0.page) }
            loader.resolve(currentCall)
            let currentCached = await waitUntil { store.files[1] != nil }
            XCTAssertTrue(currentCached, "Current image should be cached before the speculative failure")
            loader.reject(rejectedPrefetch, with: error)

            let paused = await waitUntil { store.prefetchPaused }
            XCTAssertTrue(paused, "\(label) should pause the speculative window")
            let cancellationsFinished = await waitUntil {
                speculativeCalls.allSatisfy { loader.cancelled.contains($0.id) }
            }
            XCTAssertTrue(cancellationsFinished, "Outstanding speculative requests should be cancelled for \(label)")
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(loader.calls.count, 16, "A paused window must not refill automatically")
            XCTAssertEqual(store.files[1], loader.fixtureURL(for: currentCall), "Pausing speculative work must retain the current image")

            store.retry(page: 2)
            let retryStarted = await waitUntil { loader.count(2) == 2 }
            XCTAssertTrue(retryStarted, "Explicit retry should resume the paused window")
            XCTAssertFalse(store.prefetchPaused)
            XCTAssertEqual(loader.last(2)?.priority, .prefetch)
            XCTAssertEqual(store.files[1], loader.fixtureURL(for: currentCall))
            await reset(store, loader: loader)
        }
    }

    func testLocalSimulatedPipelineConcurrency16BeatsConcurrency2ForSame17Files() async throws {
        func run(concurrency: Int) async -> TimeInterval? {
            let store = ReaderMediaStore()
            let loader = ControlledLoader(automaticLatencyNanoseconds: 40_000_000)
            let identity = scope(owner: "simulated-throughput-\(concurrency)")
            let galleryPages = pages(17)
            update(store, loader: loader, scope: identity, pages: galleryPages, current: 1,
                   prefetchCount: 32, downloadConcurrency: concurrency)
            let startedAt = ProcessInfo.processInfo.systemUptime
            let completed = await waitUntil(timeoutMilliseconds: 3_000) {
                Set(store.files.keys).isSuperset(of: Set(1...17))
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            await reset(store, loader: loader)
            guard completed else { return nil }
            return elapsed
        }

        guard let serialLikeTime = await run(concurrency: 2) else {
            XCTFail("The concurrency-2 local simulation did not finish the same 17 files within 3 seconds")
            return
        }
        guard let parallelTime = await run(concurrency: 16) else {
            XCTFail("The concurrency-16 local simulation did not finish the same 17 files within 3 seconds")
            return
        }
        print("Reader V15 local simulated pipeline (40ms async loader, 17 local fixtures; not real-network throughput): concurrency=2 \(String(format: "%.3f", serialLikeTime))s, concurrency=16 \(String(format: "%.3f", parallelTime))s")
        XCTAssertLessThan(parallelTime, serialLikeTime / 2,
                          "In this fixed-latency local simulation, 16-way concurrency should finish at least twice as fast as 2-way concurrency")
    }
}

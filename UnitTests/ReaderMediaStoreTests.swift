import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class ReaderMediaStoreTests: XCTestCase {
    private actor GateEvents {
        private var order: [String] = []
        func append(_ value: String) { order.append(value) }
        func values() -> [String] { order }
    }

    private struct Call {
        var id: UUID
        var page: Int
        var priority: MediaRequestPriority
    }

    @MainActor private final class ControlledLoader {
        var calls: [Call] = []
        var pending: [UUID: CheckedContinuation<URL, Error>] = [:]
        var cancelledCalls = Set<UUID>()
        var ignoreCancellation = false

        func load(_ page: GalleryPage, _ priority: MediaRequestPriority) async throws -> URL {
            let id = UUID()
            calls.append(Call(id: id, page: page.index, priority: priority))
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { pending[id] = continuation }
                }
            } onCancel: {
                Task { @MainActor in
                    self.cancelledCalls.insert(id)
                    guard !self.ignoreCancellation, let continuation = self.pending.removeValue(forKey: id) else { return }
                    continuation.resume(throwing: CancellationError())
                }
            }
        }

        func resolve(_ call: Call, as marker: String) {
            pending.removeValue(forKey: call.id)?.resume(returning: URL(fileURLWithPath: "/fixture/\(marker)-\(call.page).media"))
        }

        func reject(_ call: Call) {
            pending.removeValue(forKey: call.id)?.resume(throwing: RequestFailure.http(.media, 503))
        }

        func last(_ page: Int) -> Call? { calls.last { $0.page == page } }
        func wasCancelled(_ call: Call) -> Bool { cancelledCalls.contains(call.id) }
    }

    private func pages(_ count: Int = 12) -> [GalleryPage] {
        (1...count).map { index in
            GalleryPage(index: index, url: URL(string: "https://ehentai.org/s/fixture/1-\(index)")!)
        }
    }

    private func scope(owner: String = "owner-a", generation: UUID = UUID(), context: UUID = UUID()) -> ReaderMediaScope {
        ReaderMediaScope(galleryID: "ex:1", owner: owner, generation: generation, context: context)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 5_000_000)
        await Task.yield()
    }

    private func waitForLoaderCalls(_ loader: ControlledLoader, count: Int) async -> Bool {
        for _ in 0..<100 {
            if loader.calls.count >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return loader.calls.count >= count
    }

    func testZeroPrefetchLoadsOnlyCurrentPage() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), scope = scope()
        store.update(scope: scope, pages: pages(), current: 4, prefetchCount: 0,
                     loader: { try await loader.load($0, $1) }, isCurrent: { true })
        await settle()
        XCTAssertEqual(loader.calls.map(\.page), [4])
        XCTAssertEqual(loader.calls.first?.priority, .foreground)
        loader.resolve(try XCTUnwrap(loader.calls.first), as: "current")
        await settle()
        XCTAssertEqual(Set(store.files.keys), [4])
        XCTAssertTrue(store.inflight.isEmpty)
        store.reset()
    }

    func testSixPrefetchBoundaryAndSinglePrefetchPump() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), scope = scope()
        store.update(scope: scope, pages: pages(), current: 1, prefetchCount: 6,
                     loader: { try await loader.load($0, $1) }, isCurrent: { true })
        XCTAssertEqual(store.prefetchCount, 6, "The configured six-page window is preserved independently of concurrency")
        let bothRequestsStarted = await waitForLoaderCalls(loader, count: 2)
        XCTAssertTrue(bothRequestsStarted, "The foreground page and first future prefetch should both start")
        XCTAssertEqual(loader.calls.map(\.page), [1, 2])
        XCTAssertEqual(store.inflight[1], .foreground)
        XCTAssertEqual(store.inflight[2], .prefetch)

        for index in 1...7 {
            let call = try XCTUnwrap(loader.last(index))
            loader.resolve(call, as: "window")
            await settle()
            XCTAssertLessThanOrEqual(store.inflight.count, 2)
            XCTAssertLessThanOrEqual(store.inflight.values.filter { $0 == .prefetch }.count, 1)
        }
        XCTAssertEqual(Set(store.files.keys), Set(1...7))
        XCTAssertFalse(loader.calls.contains { $0.page == 8 }, "Prefetch window is current plus six following pages")
        store.reset()
    }

    func testChangingRangeCancelsWorkAndZeroLeavesOnlyForeground() async {
        let store = ReaderMediaStore(), loader = ControlledLoader(), scope = scope()
        let update: (Int) -> Void = { count in
            store.update(scope: scope, pages: self.pages(), current: 3, prefetchCount: count,
                         loader: { try await loader.load($0, $1) }, isCurrent: { true })
        }
        update(4)
        let bothStarted = await waitForLoaderCalls(loader, count: 2)
        XCTAssertTrue(bothStarted)
        XCTAssertEqual(Set(store.inflight.keys), [3, 4])
        update(1)
        XCTAssertEqual(Set(store.inflight.keys), [3, 4])
        XCTAssertEqual(store.inflight[3], .foreground)
        XCTAssertEqual(store.inflight[4], .prefetch)
        update(0)
        XCTAssertEqual(Set(store.inflight.keys), [3])
        XCTAssertEqual(store.inflight[3], .foreground)
        await settle()
        XCTAssertTrue(loader.calls.contains { $0.page == 4 && $0.priority == .prefetch })
        store.reset()
    }

    func testRangeExpansionAndContractionPreserveTheSameForegroundRequest() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), scope = scope()
        let update: (Int) -> Void = { count in
            store.update(scope: scope, pages: self.pages(), current: 3, prefetchCount: count,
                         loader: { try await loader.load($0, $1) }, isCurrent: { true })
        }
        update(2)
        await settle()
        let current = try XCTUnwrap(loader.last(3))
        let future = try XCTUnwrap(loader.last(4))
        XCTAssertEqual(current.priority, .foreground)
        XCTAssertEqual(future.priority, .prefetch)

        update(6)
        await settle()
        XCTAssertEqual(loader.calls.filter { $0.page == 3 }.count, 1, "Expanding the prefetch range must keep the same current-page request")
        XCTAssertEqual(loader.calls.filter { $0.page == 4 }.count, 1, "An in-range prefetch must remain in flight")
        XCTAssertFalse(loader.wasCancelled(current))
        XCTAssertFalse(loader.wasCancelled(future))

        update(0)
        await settle()
        XCTAssertEqual(Set(store.inflight.keys), [3])
        XCTAssertEqual(loader.calls.filter { $0.page == 3 }.count, 1, "Contracting the range must not restart the current-page request")
        XCTAssertFalse(loader.wasCancelled(current), "The foreground load must survive both setting changes")
        XCTAssertTrue(loader.wasCancelled(future), "A now out-of-range prefetch should be cancelled")

        loader.resolve(current, as: "still-current")
        await settle()
        XCTAssertTrue(store.files[3]?.path.contains("still-current") == true)
        XCTAssertEqual(loader.calls.filter { $0.page == 3 }.count, 1)
        store.reset()
    }

    func testAdjacentPrefetchSurvivesPreviewCurrentAndPreviewReleaseRoleChanges() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope()
        let galleryPages = pages(4)
        let update: (Int, Int?) -> Void = { current, preview in
            store.update(scope: identity, pages: galleryPages, current: current, prefetchCount: 1,
                         preview: preview, loader: loader.load, isCurrent: { true })
        }

        update(1, nil)
        let initialRequestsStarted = await waitForLoaderCalls(loader, count: 2)
        XCTAssertTrue(initialRequestsStarted)
        let originalPrefetch = try XCTUnwrap(loader.last(2))
        XCTAssertEqual(originalPrefetch.priority, .prefetch)

        update(1, 2)
        await settle()
        XCTAssertEqual(store.inflight[2], .foreground)
        XCTAssertEqual(loader.calls.filter { $0.page == 2 }.count, 1, "Promoting an adjacent prefetch to preview must reuse its loader task")
        XCTAssertFalse(loader.wasCancelled(originalPrefetch))

        update(1, nil)
        await settle()
        XCTAssertEqual(store.inflight[2], .prefetch)
        XCTAssertEqual(loader.calls.filter { $0.page == 2 }.count, 1, "Releasing preview should downgrade the same task to prefetch")
        XCTAssertFalse(loader.wasCancelled(originalPrefetch), "A preview rebound must not cancel the neighboring request")

        update(2, nil)
        await settle()
        XCTAssertEqual(store.inflight[2], .foreground)
        XCTAssertEqual(loader.calls.filter { $0.page == 2 }.count, 1, "Handing the prefetched page to current must reuse its in-flight task")
        XCTAssertFalse(loader.wasCancelled(originalPrefetch))
        loader.resolve(originalPrefetch, as: "role-handoff")
        await settle()
        XCTAssertTrue(store.files[2]?.path.contains("role-handoff") == true)
        store.reset()
    }

    func testZeroPrefetchPreviewCacheSurvivesReleaseUntilCurrentHandoff() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope()
        let galleryPages = pages(3)
        let update: (Int, Int?) -> Void = { current, preview in
            store.update(scope: identity, pages: galleryPages, current: current, prefetchCount: 0,
                         preview: preview, loader: loader.load, isCurrent: { true })
        }
        update(1, nil)
        let currentStarted = await waitForLoaderCalls(loader, count: 1)
        XCTAssertTrue(currentStarted)
        loader.resolve(try XCTUnwrap(loader.last(1)), as: "current-one")
        await settle()

        update(1, 2)
        let previewStarted = await waitForLoaderCalls(loader, count: 2)
        XCTAssertTrue(previewStarted)
        let preview = try XCTUnwrap(loader.last(2))
        XCTAssertEqual(preview.priority, .foreground)
        loader.resolve(preview, as: "preview-two")
        await settle()
        let previewFile = try XCTUnwrap(store.files[2])

        update(1, nil)
        await settle()
        XCTAssertEqual(store.files[2], previewFile, "A completed explicit preview must survive finger release even with zero auto-prefetch")
        XCTAssertEqual(loader.calls.filter { $0.page == 2 }.count, 1)

        update(2, nil)
        await settle()
        XCTAssertEqual(store.files[2], previewFile, "The cached preview should transfer directly into the current-page role")
        XCTAssertEqual(loader.calls.filter { $0.page == 2 }.count, 1, "Current handoff must not reload a completed preview URL")
        store.reset()
    }

    func testReverseReadingReusesCachedPreviousPageWithoutRestart() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope()
        let galleryPages = pages(3)
        store.update(scope: identity, pages: galleryPages, current: 1, prefetchCount: 1,
                     loader: loader.load, isCurrent: { true })
        let bothRequestsStarted = await waitForLoaderCalls(loader, count: 2)
        XCTAssertTrue(bothRequestsStarted)
        loader.resolve(try XCTUnwrap(loader.last(1)), as: "page-one")
        loader.resolve(try XCTUnwrap(loader.last(2)), as: "page-two")
        await settle()
        let originalPageOne = try XCTUnwrap(store.files[1])
        XCTAssertNotNil(store.files[2])

        store.update(scope: identity, pages: galleryPages, current: 2, prefetchCount: 0,
                     loader: loader.load, isCurrent: { true })
        await settle()
        XCTAssertEqual(store.files[1], originalPageOne, "The loaded page before current is retained for reverse reading")
        store.update(scope: identity, pages: galleryPages, current: 1, prefetchCount: 0,
                     loader: loader.load, isCurrent: { true })
        await settle()
        XCTAssertEqual(store.files[1], originalPageOne)
        XCTAssertEqual(loader.calls.filter { $0.page == 1 }.count, 1, "Returning to the cached previous page must not restart its loader")
        store.reset()
    }

    func testJumpCancelsOldWindowAndStartsNewCurrentBeforePrefetch() async {
        let store = ReaderMediaStore(), loader = ControlledLoader(), scope = scope()
        let update: (Int) -> Void = { current in
            store.update(scope: scope, pages: self.pages(), current: current, prefetchCount: 3,
                         loader: { try await loader.load($0, $1) }, isCurrent: { true })
        }
        update(1)
        await settle()
        XCTAssertEqual(Set(store.inflight.keys), [1, 2])
        update(7)
        await settle()
        XCTAssertEqual(Set(store.inflight.keys), [7, 8])
        XCTAssertEqual(store.inflight[7], .foreground)
        XCTAssertEqual(store.inflight[8], .prefetch)
        XCTAssertEqual(loader.calls.suffix(2).map(\.page), [7, 8])
        store.reset()
    }

    func testSameScopePageMoveRetainsLocalCacheFileForThePreviousPage() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), scope = scope()
        let galleryPages = pages(3)
        store.update(scope: scope, pages: galleryPages, current: 1, prefetchCount: 0,
                     loader: { try await loader.load($0, $1) }, isCurrent: { true })
        await settle()

        let remotePageURL = try XCTUnwrap(galleryPages.first?.url)
        let current = try XCTUnwrap(loader.last(1))
        loader.resolve(current, as: "cache")
        await settle()

        let cachedFileURL = URL(fileURLWithPath: "/fixture/cache-1.media")
        XCTAssertNotEqual(remotePageURL, cachedFileURL, "The loader returns a local cache file, not the remote page URL")
        XCTAssertEqual(store.files[1], cachedFileURL)

        store.update(scope: scope, pages: galleryPages, current: 2, prefetchCount: 0,
                     loader: { try await loader.load($0, $1) }, isCurrent: { true })
        XCTAssertEqual(store.files[1], cachedFileURL, "A same-scope move should keep the loaded previous page's local cache file")
        store.reset()
    }

    func testScopeChangeBlocksLateResultsAndFailureDoesNotAutoRetry() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), oldScope = scope()
        loader.ignoreCancellation = true
        store.update(scope: oldScope, pages: pages(3), current: 1, prefetchCount: 0,
                     loader: { try await loader.load($0, $1) }, isCurrent: { true })
        await settle()
        let oldCall = try XCTUnwrap(loader.last(1))
        let newScope = scope(owner: "owner-b")
        store.update(scope: newScope, pages: pages(3), current: 1, prefetchCount: 1,
                     loader: { try await loader.load($0, $1) }, isCurrent: { true })
        await settle()
        XCTAssertTrue(loader.wasCancelled(oldCall), "Changing owner/scope still cancels the previous request")
        let newCall = try XCTUnwrap(loader.calls.last(where: { $0.page == 1 && $0.id != oldCall.id }))
        loader.resolve(oldCall, as: "stale")
        await settle()
        XCTAssertNil(store.files[1], "A result from the prior owner/scope must not be committed")
        loader.resolve(newCall, as: "current")
        await settle()
        XCTAssertTrue(store.files[1]?.path.contains("current") == true)

        let future = try XCTUnwrap(loader.last(2))
        loader.reject(future)
        await settle()
        let failedAttempts = loader.calls.filter { $0.page == 2 }.count
        XCTAssertNotNil(store.failures[2])
        await settle()
        XCTAssertEqual(loader.calls.filter { $0.page == 2 }.count, failedAttempts, "A failed prefetch must not retry automatically")
        store.retry(page: 2)
        await settle()
        XCTAssertEqual(loader.calls.filter { $0.page == 2 }.count, failedAttempts + 1, "Retry is explicit")
        loader.resolve(try XCTUnwrap(loader.last(2)), as: "retried")
        await settle()
        store.reset()
    }

    func testGalleryGenerationAndContextChangesCancelOldRequestsAndRejectLateFiles() async throws {
        let changes: [(String, (inout ReaderMediaScope) -> Void)] = [
            ("gallery", { $0.galleryID = "ex:2" }),
            ("generation", { $0.generation = UUID() }),
            ("context", { $0.context = UUID() })
        ]

        for (name, change) in changes {
            let store = ReaderMediaStore(), loader = ControlledLoader()
            loader.ignoreCancellation = true
            let originalScope = scope()
            store.update(scope: originalScope, pages: pages(2), current: 1, prefetchCount: 0,
                         loader: loader.load, isCurrent: { true })
            let initialStarted = await waitForLoaderCalls(loader, count: 1)
            XCTAssertTrue(initialStarted, "Initial request should start for \(name) identity check")
            let oldCall = try XCTUnwrap(loader.last(1))

            var changedScope = originalScope
            change(&changedScope)
            store.update(scope: changedScope, pages: pages(2), current: 1, prefetchCount: 0,
                         loader: loader.load, isCurrent: { true })
            let replacementStarted = await waitForLoaderCalls(loader, count: 2)
            XCTAssertTrue(replacementStarted, "Replacement request should start after \(name) changes")
            XCTAssertTrue(loader.wasCancelled(oldCall), "Changing \(name) must cancel the old request")
            let newCall = try XCTUnwrap(loader.calls.last(where: { $0.page == 1 && $0.id != oldCall.id }))

            loader.resolve(oldCall, as: "stale-\(name)")
            await settle()
            XCTAssertNil(store.files[1], "A late file from the previous \(name) must not be committed")
            loader.resolve(newCall, as: "current-\(name)")
            await settle()
            XCTAssertTrue(store.files[1]?.path.contains("current-\(name)") == true)
            store.reset()
        }
    }

    func testForegroundWaiterPrecedesPrefetchAndGateReservesOnePermit() async throws {
        let gate = TransferGate(limit: 3)
        try await gate.acquire(priority: .prefetch)
        try await gate.acquire()
        try await gate.acquire()
        let events = GateEvents()
        let low = Task {
            try await gate.acquire(priority: .prefetch)
            await events.append("prefetch")
            await gate.release(priority: .prefetch)
        }
        let foreground = Task {
            try await gate.acquire(priority: .foreground)
            await events.append("foreground")
            await gate.release(priority: .foreground)
        }
        await settle()
        await gate.release(priority: .prefetch)
        try await foreground.value
        let afterForeground = await events.values()
        XCTAssertEqual(afterForeground, ["foreground"], "Foreground work must run ahead of an already-waiting prefetch")
        await gate.release()
        await gate.release()
        try await low.value
        let completed = await events.values()
        XCTAssertEqual(completed, ["foreground", "prefetch"])
    }
    func testFingerDemandAtZeroPrefetchRetainsItsCompletedNeighborOnRelease() async throws {
        let store = ReaderMediaStore(), loader = ControlledLoader(), identity = scope()
        store.update(scope: identity, pages: pages(), current: 1, prefetchCount: 0,
                     loader: loader.load, isCurrent: { true })
        let currentStarted = await waitForLoaderCalls(loader, count: 1); XCTAssertTrue(currentStarted)
        let first = try XCTUnwrap(loader.last(1)); loader.resolve(first, as: "current")
        await settle()
        store.update(scope: identity, pages: pages(), current: 1, prefetchCount: 0, preview: 2,
                     loader: loader.load, isCurrent: { true })
        let previewStarted = await waitForLoaderCalls(loader, count: 2); XCTAssertTrue(previewStarted)
        let preview = try XCTUnwrap(loader.last(2))
        XCTAssertEqual(preview.priority, .foreground)
        XCTAssertEqual(loader.calls.map(\.page), [1, 2])
        loader.resolve(preview, as: "finger-demand"); await settle()
        XCTAssertNotNil(store.files[1]); XCTAssertNotNil(store.files[2])
        store.update(scope: identity, pages: pages(), current: 1, prefetchCount: 0,
                     loader: loader.load, isCurrent: { true })
        await settle()
        XCTAssertEqual(Set(store.files.keys), [1, 2], "Completed explicit demand remains reusable after a rebound; no automatic future load is started")
        XCTAssertEqual(loader.calls.count, 2)
        store.reset()
    }

}

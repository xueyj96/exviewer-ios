import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class ReaderConnectivityV18Tests: XCTestCase {
    private struct Call {
        let id: UUID
        let page: Int
        let priority: MediaRequestPriority
    }

    @MainActor private final class ControlledLoader {
        private(set) var calls: [Call] = []
        private(set) var cancelled = Set<UUID>()
        private var pending: [UUID: CheckedContinuation<URL, Error>] = [:]

        func load(_ page: GalleryPage, _ demand: MediaRequestDemand) async throws -> URL {
            let call = Call(id: UUID(), page: page.index, priority: demand.priority)
            calls.append(call)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { pending[call.id] = continuation }
                }
            } onCancel: {
                Task { @MainActor in
                    self.cancelled.insert(call.id)
                    self.pending.removeValue(forKey: call.id)?.resume(throwing: CancellationError())
                }
            }
        }

        func resolve(_ call: Call) {
            pending.removeValue(forKey: call.id)?.resume(returning: URL(fileURLWithPath: "/fixture/connectivity-\(call.page).jpg"))
        }

        func reject(_ call: Call, with error: Error) {
            pending.removeValue(forKey: call.id)?.resume(throwing: error)
        }

        func call(page: Int, attempt: Int = 1) -> Call? {
            calls.filter { $0.page == page }.dropFirst(attempt - 1).first
        }

    }

    private func pages(_ count: Int = 32) -> [GalleryPage] {
        (1...count).map { index in
            GalleryPage(index: index, url: URL(string: "https://ehentai.org/s/connectivity/1-\(index)")!)
        }
    }

    private func scope() -> ReaderMediaScope {
        ReaderMediaScope(galleryID: "ex:connectivity", owner: "owner-v18", generation: UUID(), context: UUID())
    }

    private func update(_ store: ReaderMediaStore, _ loader: ControlledLoader, scope: ReaderMediaScope,
                        current: Int, prefetchCount: Int = 128, concurrency: Int = 16) {
        store.update(scope: scope, pages: pages(), current: current, prefetchCount: prefetchCount,
                     downloadConcurrency: concurrency,
                     demandLoader: { try await loader.load($0, $1) }, isCurrent: { true })
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    func testLargePrefetchWindowStopsAndCancelsSpeculationAfterConnectionLoss() async throws {
        let store = ReaderMediaStore()
        let loader = ControlledLoader()
        let identity = scope()
        defer { store.reset() }

        update(store, loader, scope: identity, current: 1)
        let windowStarted = await waitUntil { loader.calls.count == 16 }
        XCTAssertTrue(windowStarted, "The 128-page window fills only the configured 16 concurrent slots")
        let current = try XCTUnwrap(loader.call(page: 1))
        let failed = try XCTUnwrap(loader.call(page: 2))
        XCTAssertEqual(failed.priority, .prefetch)
        XCTAssertEqual(store.prefetchCount, 128)

        loader.reject(failed, with: RequestFailure.transport(.media, URLError.networkConnectionLost.rawValue))
        let pausedAndCancelled = await waitUntil {
            store.prefetchPaused && (3...16).allSatisfy { page in
                loader.call(page: page).map { loader.cancelled.contains($0.id) } ?? false
            }
        }
        XCTAssertTrue(pausedAndCancelled, "A final -1005 response must pause the window and cancel its remaining speculative calls")
        XCTAssertFalse(loader.cancelled.contains(current.id), "The current foreground request must survive a background network failure")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(loader.calls.count, 16, "A paused window must not refill after cancellation settles")
        XCTAssertEqual(store.failures[2] as? RequestFailure,
                       RequestFailure.transport(.media, URLError.networkConnectionLost.rawValue))
    }

    func testOnlyForegroundStartedAfterNetworkPauseCanRestoreAutomaticPrefetch() async throws {
        let store = ReaderMediaStore()
        let loader = ControlledLoader()
        let identity = scope()
        defer { store.reset() }

        update(store, loader, scope: identity, current: 1)
        let started = await waitUntil { loader.calls.count == 16 }
        XCTAssertTrue(started)
        let oldCurrent = try XCTUnwrap(loader.call(page: 1))
        let failure = try XCTUnwrap(loader.call(page: 2))
        loader.reject(failure, with: RequestFailure.transport(.media, URLError.timedOut.rawValue))
        let paused = await waitUntil { store.prefetchPaused && store.failures[2] != nil }
        XCTAssertTrue(paused)

        // This foreground began before the network pause. Its later success is
        // valid media, but cannot establish that connectivity recovered.
        loader.resolve(oldCurrent)
        let oldCurrentCommitted = await waitUntil { store.files[1] != nil && store.inflight[1] == nil }
        XCTAssertTrue(oldCurrentCommitted)
        XCTAssertTrue(store.prefetchPaused)

        update(store, loader, scope: identity, current: 2)
        let newCurrentStarted = await waitUntil { loader.call(page: 2, attempt: 2) != nil }
        XCTAssertTrue(newCurrentStarted, "Moving to a failed prefetched page grants one fresh foreground attempt")
        let recoveredCurrent = try XCTUnwrap(loader.call(page: 2, attempt: 2))
        XCTAssertEqual(recoveredCurrent.priority, .foreground)
        loader.resolve(recoveredCurrent)
        let resumed = await waitUntil { !store.prefetchPaused && store.files[2] != nil && loader.call(page: 3, attempt: 2) != nil }
        XCTAssertTrue(resumed, "A current foreground started after the network pause can recover automatic prefetch on success")
        XCTAssertEqual(loader.call(page: 3, attempt: 2)?.priority, .prefetch)
    }

    func testTimeoutAndConnectionRefusedAlsoPausePageAndMediaRequests() async throws {
        let failures: [(String, RequestFailure)] = [
            ("timeout-page", .transport(.page, URLError.timedOut.rawValue)),
            ("refused-media", .transport(.media, URLError.cannotConnectToHost.rawValue))
        ]
        for (name, failure) in failures {
            let store = ReaderMediaStore()
            let loader = ControlledLoader()
            let identity = scope()
            update(store, loader, scope: identity, current: 1, prefetchCount: 3, concurrency: 4)
            let started = await waitUntil { loader.calls.count == 4 }
            XCTAssertTrue(started, "The bounded test window should start for \(name)")
            let failed = try XCTUnwrap(loader.call(page: 2))
            loader.reject(failed, with: failure)
            let cancelled = await waitUntil {
                store.prefetchPaused && [3, 4].allSatisfy { page in
                    loader.call(page: page).map { loader.cancelled.contains($0.id) } ?? false
                }
            }
            XCTAssertTrue(cancelled, "\(name) should pause automatic work and cancel outstanding prefetch")
            XCTAssertEqual(loader.calls.count, 4, "The cancelled window must not refill after \(name)")
            store.reset()
        }
    }

    func testRestrictedAnd429PausesNeedExplicitRetryEvenAfterNewCurrentSucceeds() async throws {
        let protectedFailures: [(String, Error)] = [
            ("authentication", ViewerError.authentication),
            ("challenge", ViewerError.challenge),
            ("http-429", RequestFailure.http(.media, 429))
        ]

        for (name, error) in protectedFailures {
            let store = ReaderMediaStore()
            let loader = ControlledLoader()
            let identity = scope()
            defer { store.reset() }

            update(store, loader, scope: identity, current: 1)
            let windowStarted = await waitUntil { loader.calls.count == 16 }
            XCTAssertTrue(windowStarted, "The test window should be full for \(name)")
            let current1 = try XCTUnwrap(loader.call(page: 1))
            let restricted = try XCTUnwrap(loader.call(page: 2))
            loader.reject(restricted, with: error)
            let paused = await waitUntil { store.prefetchPaused && store.failures[2] != nil }
            XCTAssertTrue(paused, "\(name) must establish a protected pause")

            // A later transport error from the already-running current request
            // cannot downgrade the hard pause.
            loader.reject(current1, with: RequestFailure.transport(.media, URLError.networkConnectionLost.rawValue))
            let olderCurrentFailed = await waitUntil { store.failures[1] != nil }
            XCTAssertTrue(olderCurrentFailed)
            XCTAssertTrue(store.prefetchPaused)

            // A new current foreground can load, but success still cannot clear
            // the protected pause.
            update(store, loader, scope: identity, current: 3)
            let nextStarted = await waitUntil { loader.call(page: 3, attempt: 2) != nil && store.inflight[3] == .foreground }
            XCTAssertTrue(nextStarted, "A visible page can still load while auto-prefetch is paused for \(name)")
            let current3 = try XCTUnwrap(loader.call(page: 3, attempt: 2))
            loader.resolve(current3)
            _ = await waitUntil { store.files[3] != nil && store.inflight[3] == nil }
            XCTAssertTrue(store.prefetchPaused, "Success must not auto-resume a protected \(name) pause")
            XCTAssertEqual(loader.calls.count, 17, "A current request may run, but speculative window must stay stopped for \(name)")

            update(store, loader, scope: identity, current: 2)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(loader.calls.filter { $0.page == 2 }.count, 1, "Visibility alone must not retry \(name)")
            store.retry(page: 2)
            let retried = await waitUntil { loader.calls.filter { $0.page == 2 }.count == 2 }
            XCTAssertTrue(retried, "Explicit retry should preserve the existing retry contract for \(name)")
            XCTAssertFalse(store.prefetchPaused)
            let retryCall = try XCTUnwrap(loader.call(page: 2, attempt: 2))
            XCTAssertEqual(retryCall.priority, .foreground)
            loader.resolve(retryCall)
        }
    }
}

import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class ReaderRecoveryV14Tests: XCTestCase {
    private struct Call {
        let id: UUID
        let page: Int
        let priority: MediaRequestPriority
    }

    @MainActor private final class ControlledLoader {
        private(set) var calls: [Call] = []
        private var pending: [UUID: CheckedContinuation<URL, Error>] = [:]

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
                    self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        }

        func resolve(_ call: Call) {
            pending.removeValue(forKey: call.id)?.resume(returning: URL(fileURLWithPath: "/fixture/page-\(call.page).media"))
        }

        func reject(_ call: Call, with error: Error) {
            pending.removeValue(forKey: call.id)?.resume(throwing: error)
        }

        func calls(for page: Int) -> [Call] { calls.filter { $0.page == page } }
    }

    @MainActor private final class GateControlledLoader {
        struct Call {
            let id: UUID
            let page: Int
            let demand: MediaRequestDemand
        }

        private(set) var calls: [Call] = []
        private(set) var acquired = Set<UUID>()
        private(set) var released = Set<UUID>()
        private(set) var cancelled = Set<UUID>()
        private var pending: [UUID: CheckedContinuation<URL, Error>] = [:]

        func load(_ page: GalleryPage, _ demand: MediaRequestDemand, gate: TransferGate) async throws -> URL {
            let id = UUID()
            calls.append(Call(id: id, page: page.index, demand: demand))
            return try await withTaskCancellationHandler {
                let lease = try await gate.acquire(request: demand)
                acquired.insert(id)
                do {
                    let url: URL = try await withCheckedThrowingContinuation { continuation in
                        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { pending[id] = continuation }
                    }
                    await gate.release(priority: lease)
                    released.insert(id)
                    return url
                } catch {
                    await gate.release(priority: lease)
                    released.insert(id)
                    throw error
                }
            } onCancel: {
                Task { @MainActor in
                    self.cancelled.insert(id)
                    self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        }

        func resolve(_ call: Call) {
            pending.removeValue(forKey: call.id)?.resume(returning: URL(fileURLWithPath: "/fixture/gated-page-\(call.page).media"))
        }

        func calls(for page: Int) -> [Call] { calls.filter { $0.page == page } }
    }

    private func pages() -> [GalleryPage] {
        (1...3).map { index in
            GalleryPage(index: index, url: URL(string: "https://ehentai.org/s/fixture/1-\(index)")!)
        }
    }

    private func scope() -> ReaderMediaScope {
        ReaderMediaScope(galleryID: "ex:1", owner: "owner-v14", generation: UUID(), context: UUID())
    }

    private func waitForCalls(_ loader: ControlledLoader, page: Int, count: Int) async -> Bool {
        // Bounded, short polling gives the MainActor request task a turn without
        // allowing a stuck continuation to hang the suite.
        for _ in 0..<100 {
            if loader.calls(for: page).count >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return loader.calls(for: page).count >= count
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    func testPromotingTimedOutPrefetchMakesOneFreshForegroundAttempt() async throws {
        let store = ReaderMediaStore()
        let loader = ControlledLoader()
        let identity = scope()
        let galleryPages = pages()
        let update: (Int) -> Void = { current in
            store.update(scope: identity, pages: galleryPages, current: current, prefetchCount: 1,
                        loader: loader.load, isCurrent: { true })
        }
        defer { store.reset() }

        update(1)
        let currentStarted = await waitForCalls(loader, page: 1, count: 1)
        let prefetchStarted = await waitForCalls(loader, page: 2, count: 1)
        XCTAssertTrue(currentStarted)
        XCTAssertTrue(prefetchStarted)
        let firstCurrent = try XCTUnwrap(loader.calls(for: 1).first)
        let failedPrefetch = try XCTUnwrap(loader.calls(for: 2).first)
        XCTAssertEqual(failedPrefetch.priority, .prefetch)
        loader.resolve(firstCurrent)
        loader.reject(failedPrefetch, with: RequestFailure.transport(.media, URLError.timedOut.rawValue))

        // Wait until the failed attempt has settled before handing page 2 to the reader.
        for _ in 0..<100 where store.failures[2] == nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(store.failures[2])
        update(2)

        let promotedStarted = await waitForCalls(loader, page: 2, count: 2)
        XCTAssertTrue(promotedStarted, "A recoverable timeout should get one fresh attempt on current-page promotion")
        let promoted = try XCTUnwrap(loader.calls(for: 2).last)
        XCTAssertEqual(promoted.priority, .foreground)
        XCTAssertEqual(loader.calls(for: 2).count, 2, "Promotion gets one fresh attempt, not a retry loop")
        loader.reject(promoted, with: RequestFailure.transport(.media, URLError.timedOut.rawValue))
        for _ in 0..<100 where store.failures[2] == nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(store.failures[2])
        update(2)
        update(3)
        update(2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(loader.calls(for: 2).count, 2, "One promotion retry consumes the recovery budget; repeat updates and away/back navigation must not retrigger it")
    }

    func testTerminalPrefetchFailuresDoNotRetryWhenPromotedOrUpdatedAgain() async throws {
        let terminalErrors: [(String, Error)] = [
            ("quota", ViewerError.imageLimit),
            ("challenge", ViewerError.challenge),
            ("http-429", RequestFailure.http(.media, 429)),
            ("http-403", RequestFailure.http(.media, 403)),
            ("tls-certificate", RequestFailure.transport(.media, URLError.serverCertificateUntrusted.rawValue))
        ]

        for (name, terminalError) in terminalErrors {
            let store = ReaderMediaStore()
            let loader = ControlledLoader()
            let identity = scope()
            let galleryPages = pages()
            let update: (Int) -> Void = { current in
                store.update(scope: identity, pages: galleryPages, current: current, prefetchCount: 1,
                            loader: loader.load, isCurrent: { true })
            }
            update(1)
            let currentStarted = await waitForCalls(loader, page: 1, count: 1)
            let prefetchStarted = await waitForCalls(loader, page: 2, count: 1)
            XCTAssertTrue(currentStarted, "Current load should start for \(name)")
            XCTAssertTrue(prefetchStarted, "Prefetch should start for \(name)")
            let current = try XCTUnwrap(loader.calls(for: 1).first)
            let prefetch = try XCTUnwrap(loader.calls(for: 2).first)
            loader.resolve(current)
            loader.reject(prefetch, with: terminalError)

            for _ in 0..<100 where store.failures[2] == nil {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertNotNil(store.failures[2], "The original terminal failure should remain visible for \(name)")
            update(2)
            update(2)
            for _ in 0..<20 { await Task.yield() }

            XCTAssertEqual(loader.calls(for: 2).count, 1, "A \(name) failure must not auto-retry on promotion or repeated current updates")
            store.reset()
        }
    }

    func testQueuedPrefetchDemandUpgradesInRealTransferGateWithoutRestart() async throws {
        let gate = TransferGate(limit: 3)
        let heldDemandA = MediaRequestDemand(priority: .foreground)
        let heldDemandB = MediaRequestDemand(priority: .foreground)
        let heldLeaseA = try await gate.acquire(request: heldDemandA)
        let heldLeaseB = try await gate.acquire(request: heldDemandB)
        var releasedHeldLeases = false
        defer {
            if !releasedHeldLeases {
                Task {
                    await gate.release(priority: heldLeaseA)
                    await gate.release(priority: heldLeaseB)
                }
            }
        }

        let store = ReaderMediaStore()
        let loader = GateControlledLoader()
        let identity = scope()
        let galleryPages = pages()
        let update: (Int, Int) -> Void = { current, prefetchCount in
            store.update(scope: identity, pages: galleryPages, current: current, prefetchCount: prefetchCount,
                         demandLoader: { page, demand in try await loader.load(page, demand, gate: gate) },
                         isCurrent: { true })
        }
        defer { store.reset() }

        update(1, 1)
        let currentAcquired = await waitUntil { loader.acquired.contains(where: { id in loader.calls.first(where: { $0.id == id })?.page == 1 }) }
        let prefetchQueued = await waitUntil { loader.calls(for: 2).count == 1 }
        XCTAssertTrue(currentAcquired, "Page 1 should use the third foreground permit")
        XCTAssertTrue(prefetchQueued, "Page 2 should enter the real gate's waiting queue")
        let currentCall = try XCTUnwrap(loader.calls(for: 1).first)
        let queuedPrefetch = try XCTUnwrap(loader.calls(for: 2).first)
        XCTAssertEqual(queuedPrefetch.demand.priority, .prefetch)
        XCTAssertFalse(loader.acquired.contains(queuedPrefetch.id), "The one remaining permit is reserved from prefetch while page 1 is active")

        loader.resolve(currentCall)
        let currentReleased = await waitUntil { loader.released.contains(currentCall.id) }
        XCTAssertTrue(currentReleased)
        XCTAssertFalse(loader.acquired.contains(queuedPrefetch.id), "Releasing page 1 leaves one permit, still reserved from prefetch")
        XCTAssertEqual(loader.calls(for: 2).count, 1)
        XCTAssertFalse(loader.cancelled.contains(queuedPrefetch.id))

        update(2, 0)
        let promotedAcquired = await waitUntil { loader.acquired.contains(queuedPrefetch.id) }
        XCTAssertTrue(promotedAcquired, "Promotion must upgrade the queued demand and acquire the free permit")
        XCTAssertEqual(loader.calls(for: 2).count, 1, "Promotion must keep the original queued loader invocation")
        XCTAssertFalse(loader.cancelled.contains(queuedPrefetch.id), "Promotion must not cancel and restart the queued transfer")

        loader.resolve(queuedPrefetch)
        let prefetchReleased = await waitUntil { loader.released.contains(queuedPrefetch.id) }
        XCTAssertTrue(prefetchReleased)
        XCTAssertNotNil(store.files[2])
        XCTAssertEqual(loader.calls(for: 2).count, 1)

        store.reset()
        await gate.release(priority: heldLeaseA)
        await gate.release(priority: heldLeaseB)
        releasedHeldLeases = true
    }
}

import XCTest
@testable import ExViewer

final class TransferGateV15Tests: XCTestCase {
    private actor Results {
        var leases: [MediaRequestPriority] = []
        func append(_ value: MediaRequestPriority) { leases.append(value) }
        func count() -> Int { leases.count }
    }
    private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }
    func testSixteenPermitsAreActuallyUsableAndSeventeenthWaits() async throws {
        let gate = TransferGate(limit: 16, prefetchLimit: 15, allowFullWithForeground: true), results = Results()
        let current = try await gate.acquire(request: MediaRequestDemand(priority: .foreground))
        let tasks = (0..<16).map { _ in Task {
            let lease = try await gate.acquire(request: MediaRequestDemand(priority: .prefetch))
            await results.append(lease)
        } }
        var releasedPrefetch = 0
        defer {
            tasks.forEach { $0.cancel() }
            let alreadyReleased = releasedPrefetch
            Task {
                for task in tasks { _ = try? await task.value }
                let acquired = await results.count()
                for _ in alreadyReleased..<acquired { await gate.release(priority: .prefetch) }
                await gate.release(priority: current)
            }
        }
        let full = await waitUntil {
            let count = await results.count(), queued = await gate.queuedCount
            return count == 15 && queued == 1
        }
        XCTAssertTrue(full, "One current plus fifteen preloads must hold sixteen real transfer permits")
        guard full else { return }
        let heldCount = await results.count()
        XCTAssertEqual(heldCount, 15)
        await gate.release(priority: .prefetch); releasedPrefetch += 1
        let next = await waitUntil { await results.count() == 16 }
        XCTAssertTrue(next, "The seventeenth transfer can start only after a permit is released")
    }
}

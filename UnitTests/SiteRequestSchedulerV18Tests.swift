import XCTest
@testable import ExViewer

@MainActor final class SiteRequestSchedulerV18Tests: XCTestCase {
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    func testBackgroundCannotTakeReservedForegroundSlotAndForegroundJumpsQueue() async throws {
        let scheduler = SiteRequestScheduler(searchInterval: 0)
        let first = try await scheduler.acquire(request: MediaRequestDemand(priority: .prefetch), search: false, limit: 2)
        let background = Task { try await scheduler.acquire(request: MediaRequestDemand(priority: .thumbnail), search: false, limit: 2) }
        let queued = await waitUntil { scheduler.queuedCount == 1 }
        XCTAssertTrue(queued)
        let foreground = Task { try await scheduler.acquire(request: MediaRequestDemand(priority: .foreground), search: false, limit: 2) }
        let foregroundLease = try await foreground.value
        XCTAssertEqual(scheduler.activeCount, 2)
        scheduler.release(foregroundLease)
        XCTAssertEqual(scheduler.queuedCount, 1, "A second background lease must not take the reserved slot")
        scheduler.release(first)
        let backgroundLease = try await background.value
        scheduler.release(backgroundLease)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testQueuedDemandPromotionKeepsSingleWaiterAndMovesItAhead() async throws {
        let scheduler = SiteRequestScheduler(searchInterval: 0)
        let first = try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 1)
        let prefetchDemand = MediaRequestDemand(priority: .prefetch)
        let prefetch = Task { try await scheduler.acquire(request: prefetchDemand, search: false, limit: 1) }
        let queuedPrefetch = await waitUntil { scheduler.queuedCount == 1 }
        XCTAssertTrue(queuedPrefetch)
        let foregroundDemand = MediaRequestDemand(priority: .thumbnail)
        let promoted = Task { try await scheduler.acquire(request: foregroundDemand, search: false, limit: 1) }
        let bothQueued = await waitUntil { scheduler.queuedCount == 2 }
        XCTAssertTrue(bothQueued)
        foregroundDemand.setPriority(.foreground)
        scheduler.release(first)
        let promotedLease = try await promoted.value
        XCTAssertEqual(scheduler.activeCount, 1)
        scheduler.release(promotedLease)
        let prefetchLease = try await prefetch.value
        scheduler.release(prefetchLease)
        XCTAssertEqual(scheduler.queuedCount, 0)
    }

    func testCanceledQueuedRequestLeavesNoWaiterOrLease() async throws {
        let scheduler = SiteRequestScheduler(searchInterval: 0)
        let first = try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 1)
        let pending = Task { try await scheduler.acquire(request: MediaRequestDemand(priority: .prefetch), search: false, limit: 1) }
        let queued = await waitUntil { scheduler.queuedCount == 1 }
        XCTAssertTrue(queued)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(scheduler.queuedCount, 0)
        XCTAssertEqual(scheduler.activeCount, 1)
        scheduler.release(first)
        XCTAssertEqual(scheduler.activeCount, 0)
    }

    func testLimitOneAllowsSerialBackground() async throws {
        let scheduler = SiteRequestScheduler(searchInterval: 0)
        let first = try await scheduler.acquire(request: MediaRequestDemand(priority: .prefetch), search: false, limit: 1)
        let second = Task { try await scheduler.acquire(request: MediaRequestDemand(priority: .thumbnail), search: false, limit: 1) }
        let queued = await waitUntil { scheduler.queuedCount == 1 }
        XCTAssertTrue(queued)
        scheduler.release(first)
        let secondLease = try await second.value
        let third = Task { try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 1) }
        let queuedAgain = await waitUntil { scheduler.queuedCount == 1 }
        XCTAssertTrue(queuedAgain)
        XCTAssertEqual(scheduler.activeCount, 1)
        scheduler.release(secondLease)
        let thirdLease = try await third.value
        scheduler.release(thirdLease)
    }

    func testSearchStartsAreSpacedAndNonSearchCanUseAvailableSlot() async throws {
        let interval = 0.18
        let scheduler = SiteRequestScheduler(searchInterval: interval)
        let first = try await scheduler.acquire(request: MediaRequestDemand(), search: true, limit: 2)
        let firstStart = ProcessInfo.processInfo.systemUptime
        let nextSearch = Task { try await scheduler.acquire(request: MediaRequestDemand(), search: true, limit: 2) }
        let queued = await waitUntil { scheduler.queuedCount == 1 }
        XCTAssertTrue(queued)
        let nonSearch = Task { try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 2) }
        let nonSearchLease = try await nonSearch.value
        XCTAssertEqual(scheduler.activeCount, 2)
        scheduler.release(nonSearchLease)
        let nextSearchLease = try await nextSearch.value
        let secondStart = ProcessInfo.processInfo.systemUptime
        XCTAssertGreaterThanOrEqual(secondStart - firstStart, interval * 0.8)
        scheduler.release(first)
        scheduler.release(nextSearchLease)
    }

    func testCanceledPacedSearchDoesNotDelayNextSearch() async throws {
        let scheduler = SiteRequestScheduler(searchInterval: 0.15)
        let first = try await scheduler.acquire(request: MediaRequestDemand(), search: true, limit: 1)
        let canceled = Task { try await scheduler.acquire(request: MediaRequestDemand(), search: true, limit: 1) }
        let queued = await waitUntil { scheduler.queuedCount == 1 }
        XCTAssertTrue(queued)
        canceled.cancel()
        do { _ = try await canceled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        scheduler.release(first)
        let start = ProcessInfo.processInfo.systemUptime
        let next = try await scheduler.acquire(request: MediaRequestDemand(), search: true, limit: 1)
        let waitAfterPreviousDispatch = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(waitAfterPreviousDispatch, 0.08)
        XCTAssertLessThan(waitAfterPreviousDispatch, 0.25)
        scheduler.release(next)
    }

    func testQueueIsBoundedAtSixtyFourWaiters() async throws {
        let scheduler = SiteRequestScheduler(searchInterval: 0)
        let first = try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 1)
        let tasks = (0..<64).map { _ in
            Task { try await scheduler.acquire(request: MediaRequestDemand(priority: .prefetch), search: false, limit: 1) }
        }
        let full = await waitUntil { scheduler.queuedCount == 64 }
        XCTAssertTrue(full)
        do {
            _ = try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 1)
            XCTFail("Expected bounded queue rejection")
        } catch let failure as RequestFailure {
            XCTAssertEqual(failure, .pageQueueFull)
        }
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
        scheduler.release(first)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(scheduler.queuedCount, 0)
    }

    func testConcurrencyPolicyUsesOnlySupportedChoicesAndDefault() {
        XCTAssertEqual(SiteRequestPolicy.concurrencyChoices, [1, 2, 4])
        XCTAssertEqual(SiteRequestPolicy.clampedConcurrency(0), 1)
        XCTAssertEqual(SiteRequestPolicy.clampedConcurrency(1), 1)
        XCTAssertEqual(SiteRequestPolicy.clampedConcurrency(2), 2)
        XCTAssertEqual(SiteRequestPolicy.clampedConcurrency(3), 2)
        XCTAssertEqual(SiteRequestPolicy.clampedConcurrency(4), 4)
        XCTAssertEqual(SiteRequestPolicy.clampedConcurrency(16), 4)

        let suite = "SiteRequestSchedulerV18Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SiteRequestPolicy.configuredConcurrency(defaults: defaults), 2)
        defaults.set(4, forKey: SiteRequestPolicy.concurrencyKey)
        XCTAssertEqual(SiteRequestPolicy.configuredConcurrency(defaults: defaults), 4)
    }

    func testReducingLimitDoesNotCancelAlreadyActiveLeases() async throws {
        let scheduler = SiteRequestScheduler(searchInterval: 0)
        let one = try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 2)
        let two = try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 2)
        scheduler.setLimit(1)
        XCTAssertEqual(scheduler.activeCount, 2)
        let pending = Task { try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 1) }
        let queued = await waitUntil { scheduler.queuedCount == 1 }
        XCTAssertTrue(queued)
        XCTAssertEqual(scheduler.activeCount, 2)
        scheduler.release(one)
        XCTAssertEqual(scheduler.activeCount, 1)
        let stillQueued = scheduler.queuedCount
        XCTAssertEqual(stillQueued, 1)
        scheduler.release(two)
        let third = try await pending.value
        XCTAssertEqual(scheduler.activeCount, 1)
        scheduler.release(third)
    }

    func testForegroundCanUseReservedSlotWhenBackgroundQueueIsFull() async throws {
        let scheduler = SiteRequestScheduler(searchInterval: 0)
        let activeBackground = try await scheduler.acquire(request: MediaRequestDemand(priority: .prefetch), search: false, limit: 2)
        let queuedTasks = (0..<64).map { _ in
            Task { try await scheduler.acquire(request: MediaRequestDemand(priority: .thumbnail), search: false, limit: 2) }
        }
        let full = await waitUntil { scheduler.queuedCount == 64 }
        XCTAssertTrue(full)

        let foreground = try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 2)
        XCTAssertEqual(scheduler.activeCount, 2)
        XCTAssertEqual(scheduler.queuedCount, 64)
        scheduler.release(foreground)
        for task in queuedTasks { task.cancel() }
        for task in queuedTasks { _ = try? await task.value }
        scheduler.release(activeBackground)
        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(scheduler.queuedCount, 0)
    }

    func testQueuedSearchesRemainSpacedAfterConcurrencyGateOpens() async throws {
        let interval = 0.16
        let scheduler = SiteRequestScheduler(searchInterval: interval)
        let blocker = try await scheduler.acquire(request: MediaRequestDemand(), search: false, limit: 1)
        let first = Task {
            let lease = try await scheduler.acquire(request: MediaRequestDemand(), search: true, limit: 1)
            return (lease, ProcessInfo.processInfo.systemUptime)
        }
        let second = Task {
            let lease = try await scheduler.acquire(request: MediaRequestDemand(), search: true, limit: 1)
            return (lease, ProcessInfo.processInfo.systemUptime)
        }
        let queued = await waitUntil { scheduler.queuedCount == 2 }
        XCTAssertTrue(queued)
        scheduler.release(blocker)
        let (firstLease, firstStart) = try await first.value
        scheduler.release(firstLease)
        let (secondLease, secondStart) = try await second.value
        XCTAssertGreaterThanOrEqual(secondStart - firstStart, interval * 0.8)
        scheduler.release(secondLease)
    }
}

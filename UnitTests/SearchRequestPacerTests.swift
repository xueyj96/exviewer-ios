import XCTest
@testable import ExViewer

@MainActor final class SearchRequestPacerTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(condition())
    }

    func testCancelledWaitersDoNotReserveAdditionalDispatchSlots() async throws {
        let interval = 0.075
        let pacer = SearchRequestPacer(interval: interval)
        let first = Task { try await pacer.wait(); return ProcessInfo.processInfo.systemUptime }
        let firstStart = try await first.value

        let cancelledA = Task { try await pacer.wait() }
        let cancelledB = Task { try await pacer.wait() }
        try await Task.sleep(nanoseconds: 10_000_000)
        cancelledA.cancel(); cancelledB.cancel()
        do { try await cancelledA.value; XCTFail("Cancelled waiter A must not be dispatched") }
        catch is CancellationError { }
        do { try await cancelledB.value; XCTFail("Cancelled waiter B must not be dispatched") }
        catch is CancellationError { }

        let survivor = Task { try await pacer.wait(); return ProcessInfo.processInfo.systemUptime }
        let survivorStart = try await survivor.value
        let spacing = survivorStart - firstStart
        XCTAssertGreaterThanOrEqual(spacing, interval - 0.02, "The surviving waiter must respect real dispatch spacing")
        XCTAssertLessThan(spacing, interval * 1.8, "Cancelled waiters must not consume extra future slots")
    }

    func testForegroundWaiterPrecedesPrefetchAndEachReleaseKeepsInterval() async throws {
        let interval = 0.07
        let pacer = SearchRequestPacer(interval: interval)
        let first = Task { try await pacer.wait(priority: .foreground); return ("first", ProcessInfo.processInfo.systemUptime) }
        let firstStart = try await first.value

        let prefetch = Task { try await pacer.wait(priority: .prefetch); return ("prefetch", ProcessInfo.processInfo.systemUptime) }
        try await Task.sleep(nanoseconds: 8_000_000)
        let foreground = Task { try await pacer.wait(priority: .foreground); return ("foreground", ProcessInfo.processInfo.systemUptime) }
        let second = try await foreground.value
        let third = try await prefetch.value

        XCTAssertEqual([firstStart.0, second.0, third.0], ["first", "foreground", "prefetch"])
        XCTAssertGreaterThanOrEqual(second.1 - firstStart.1, interval - 0.02)
        XCTAssertGreaterThanOrEqual(third.1 - second.1, interval - 0.02, "Spacing is measured from each actual dispatch, not the original queue time")
    }
}

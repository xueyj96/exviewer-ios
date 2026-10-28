import XCTest
import ExViewerCore
@testable import ExViewer

final class MediaGateV14Tests: XCTestCase {
    private actor CompletionCount {
        private(set) var value = 0
        func mark() { value += 1 }
    }

    private actor PriorityResult {
        private(set) var lease: MediaRequestPriority?
        private(set) var failed = false
        private(set) var finished = false
        func record(_ lease: MediaRequestPriority) { self.lease = lease }
        func fail() { failed = true }
        func finish() { finished = true }
    }

    private func waitUntil(timeoutMilliseconds: Int = 2_000,
                           condition: @escaping () async -> Bool) async -> Bool {
        let attempts = max(1, timeoutMilliseconds / 10)
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private func acquireBounded(_ gate: TransferGate,
                                demand: MediaRequestDemand) async -> MediaRequestPriority? {
        let result = PriorityResult()
        let task = Task {
            do { await result.record(try await gate.acquire(request: demand)) }
            catch { await result.fail() }
            await result.finish()
        }
        let completed = await waitUntil { await result.finished }
        if !completed {
            task.cancel()
            _ = await waitUntil {
                let finished = await result.finished
                let queued = await gate.queuedCount
                return finished && queued == 0
            }
        }
        return await result.lease
    }

    func testForegroundAcquiresWithQueueFullOfThumbnailsAndCancellationDrainsQueue() async throws {
        let gate = TransferGate(limit: 3)
        guard let heldA = await acquireBounded(gate, demand: MediaRequestDemand(priority: .thumbnail)) else {
            XCTFail("First thumbnail permit should be acquired within the bound")
            return
        }
        guard let heldB = await acquireBounded(gate, demand: MediaRequestDemand(priority: .thumbnail)) else {
            XCTFail("Second thumbnail permit should be acquired within the bound")
            await gate.release(priority: heldA)
            return
        }
        let foregroundResult = PriorityResult()

        let completions = CompletionCount()
        let waiters = (0..<64).map { _ in
            let demand = MediaRequestDemand(priority: .thumbnail)
            return Task {
                do {
                    let lease = try await gate.acquire(request: demand)
                    await gate.release(priority: lease)
                } catch {
                    // Cancellation is the expected way to drain this full queue.
                }
                await completions.mark()
            }
        }

        let queueFilled = await waitUntil { await gate.queuedCount == 64 }
        XCTAssertTrue(queueFilled, "All 64 thumbnails should be represented in the queue")
        let foreground = Task {
            do { await foregroundResult.record(try await gate.acquire(request: MediaRequestDemand(priority: .foreground))) }
            catch { await foregroundResult.fail() }
            await foregroundResult.finish()
        }
        let foregroundAcquired = await waitUntil {
            let lease = await foregroundResult.lease
            let failed = await foregroundResult.failed
            let finished = await foregroundResult.finished
            return lease != nil || failed || finished
        }
        let foregroundFailed = await foregroundResult.failed
        XCTAssertTrue(foregroundAcquired && !foregroundFailed, "Foreground must acquire the free third permit despite a full thumbnail queue")
        let foregroundLease = await foregroundResult.lease
        let queueAfterForeground = await gate.queuedCount
        XCTAssertEqual(queueAfterForeground, 64, "Granting foreground must leave the 64 thumbnails queued")

        waiters.forEach { $0.cancel() }
        let drained = await waitUntil {
            let queued = await gate.queuedCount
            let completed = await completions.value
            return queued == 0 && completed == 64
        }
        XCTAssertTrue(drained, "Cancellation should resume and drain all queued waiters within the bound")

        foreground.cancel()
        let foregroundFinished = await waitUntil { await foregroundResult.finished }
        XCTAssertTrue(foregroundFinished, "The foreground acquisition task should finish or cancel within the bound")
        let recordedForegroundLease = await foregroundResult.lease
        let finalForegroundLease = recordedForegroundLease ?? foregroundLease
        let finalQueueDrained = await waitUntil { await gate.queuedCount == 0 }
        XCTAssertTrue(finalQueueDrained, "All cancelled acquisition waiters should be removed before permits are released")
        if let finalForegroundLease { await gate.release(priority: finalForegroundLease) }
        await gate.release(priority: heldA)
        await gate.release(priority: heldB)
        _ = foreground
    }

    func testPromotedActivePrefetchReleasesOriginalLeaseAndResetsPrefetchBudget() async throws {
        let gate = TransferGate(limit: 3)
        let activeDemand = MediaRequestDemand(priority: .prefetch)
        guard let originalLease = await acquireBounded(gate, demand: activeDemand) else {
            XCTFail("Initial prefetch permit should be acquired within the bound")
            return
        }
        XCTAssertEqual(originalLease, .prefetch)
        activeDemand.setPriority(.foreground)

        // Releasing the original lease must restore the prefetch budget even
        // though the mutable demand has since become foreground.
        await gate.release(priority: originalLease)

        let nextResult = PriorityResult()
        let nextDemand = MediaRequestDemand(priority: .prefetch)
        let next = Task {
            do { await nextResult.record(try await gate.acquire(request: nextDemand)) }
            catch { await nextResult.fail() }
            await nextResult.finish()
        }
        let acquired = await waitUntil {
            let lease = await nextResult.lease
            let failed = await nextResult.failed
            let finished = await nextResult.finished
            return lease != nil || failed || finished
        }
        XCTAssertTrue(acquired, "The next prefetch should acquire immediately after the original prefetch lease is released")
        let nextFailed = await nextResult.failed
        XCTAssertFalse(nextFailed)
        var nextLease = await nextResult.lease
        XCTAssertEqual(nextLease, .prefetch)
        if nextLease == nil {
            next.cancel()
            let drained = await waitUntil {
                let queued = await gate.queuedCount
                let finished = await nextResult.finished
                return queued == 0 && finished
            }
            XCTAssertTrue(drained, "A failed or timed-out prefetch waiter must be removable")
            nextLease = await nextResult.lease
        }
        if let nextLease { await gate.release(priority: nextLease) }
        let queueEmpty = await gate.queuedCount == 0
        XCTAssertTrue(queueEmpty, "No prefetch waiter or permit should leak after the lease check")
        _ = next
    }

    @MainActor func testPageStage503RetriesPageResolutionBut429DoesNot() async throws {
        let mediaFile = URL(fileURLWithPath: "/fixture/media-v14.png")
        let imageURL = URL(string: "https://fixture.hath.network/page-loader-v14.png")!
        var pages503 = 0
        var media503 = 0
        let recovered = try await PageMediaLoader.file(resolvePage: {
            pages503 += 1
            if pages503 == 1 { throw RequestFailure.http(.page, 503) }
            return try EHParser.image("<img id='img' src='\(imageURL.absoluteString)'>", base: GallerySite.ex.baseURL)
        }, loadMedia: { _ in
            media503 += 1
            return mediaFile
        }, isCurrent: { true })
        XCTAssertEqual(recovered, mediaFile)
        XCTAssertEqual(pages503, 2)
        XCTAssertEqual(media503, 1)

        var pages429 = 0
        var media429 = 0
        do {
            _ = try await PageMediaLoader.file(resolvePage: {
                pages429 += 1
                throw RequestFailure.http(.page, 429)
            }, loadMedia: { _ in
                media429 += 1
                return mediaFile
            }, isCurrent: { true })
            XCTFail("HTTP 429 should remain terminal for automatic page retry")
        } catch {
            XCTAssertEqual(error as? RequestFailure, .http(.page, 429))
        }
        XCTAssertEqual(pages429, 1)
        XCTAssertEqual(media429, 0)
    }
}

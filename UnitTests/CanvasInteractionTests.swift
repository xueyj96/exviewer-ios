import XCTest
@testable import ExViewer

@MainActor
final class CanvasInteractionTests: XCTestCase {
    private func coordinator(_ actions: CanvasInteractions) -> MediaCanvas.Coordinator {
        .init(onZoomChanged: nil, onImageSizeChanged: nil, interactions: actions, onPresentation: nil)
    }

    func testDoubleTapCanBeConsumedOrFallThroughToZoomUsingLatestHandler() {
        var points: [CGPoint] = []
        let coordinator = coordinator(.init(doubleTap: { point in points.append(point); return point.x == 50 }))
        let callbacks = coordinator.canvasInteractions
        XCTAssertEqual(callbacks.doubleTap?(CGPoint(x: 50, y: 50)), true)
        XCTAssertEqual(callbacks.doubleTap?(CGPoint(x: 10, y: 50)), false)
        XCTAssertEqual(points.count, 2)
        coordinator.interactions = .init(doubleTap: { _ in false })
        XCTAssertEqual(callbacks.doubleTap?(CGPoint(x: 50, y: 50)), false)
        XCTAssertEqual(points.count, 2, "A replaced handler must not be called")
    }

    func testQueuedTapAndLongPressAreDiscardedAfterCanvasInvalidation() async {
        var calls = 0
        let coordinator = coordinator(.init(singleTap: { _ in calls += 1 }, longPress: { calls += 1 }))
        coordinator.reportTap(.zero)
        coordinator.reportLongPress()
        coordinator.invalidatePendingReports()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(calls, 0)
    }

    func testValidLongPressReportsOnlyLongPressAndEmptyHandlersStayInactive() async {
        var taps = 0, holds = 0
        let coordinator = coordinator(.init(singleTap: { _ in taps += 1 }, longPress: { holds += 1 }))
        coordinator.canvasInteractions.longPress?()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(holds, 1)
        XCTAssertEqual(taps, 0)
        let empty = self.coordinator(.init()).canvasInteractions
        XCTAssertNil(empty.singleTap)
        XCTAssertNil(empty.longPress)
        XCTAssertEqual(empty.doubleTap?(.zero), false)
    }
}

import XCTest
@testable import ExViewer

final class ReaderPagingTests: XCTestCase {
    func testTapZonesFollowBothAxesAndReverseReadingOrder() {
        let viewport = CGRect(x: 20, y: 100, width: 400, height: 800)
        for direction in ReaderDirection.allCases {
            for cross in [0.08, 0.5, 0.92] {
                for (position, expected) in [(0.15, ReaderTapAction.previous), (0.85, .next)] {
                    let axis = direction.reverseOrder ? 1 - position : position
                    let point = CGPoint(x: viewport.minX + viewport.width * (direction.horizontal ? axis : cross),
                                        y: viewport.minY + viewport.height * (direction.horizontal ? cross : axis))
                    XCTAssertEqual(ReaderTapPolicy.action(at: point, in: viewport, direction: direction, mode: .singlePage), expected)
                }
            }
        }
    }

    func testMiddleStripAndItsBoundariesIdentifyCenterInEveryDirection() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        for direction in ReaderDirection.allCases {
            for position in [0.3, 0.5, 0.7] {
                for cross in [0.08, 0.5, 0.92] {
                    let point = CGPoint(x: viewport.width * (direction.horizontal ? position : cross),
                                        y: viewport.height * (direction.horizontal ? cross : position))
                    XCTAssertEqual(ReaderTapPolicy.action(at: point, in: viewport, direction: direction, mode: .singlePage), .center)
                }
            }
        }
    }

    func testInvalidAndOutsideTapCoordinatesDoNotPerformActions() {
        let viewport = CGRect(x: 20, y: 100, width: 400, height: 800)
        for point in [CGPoint(x: 19, y: 400), CGPoint(x: 200, y: 99), CGPoint(x: 421, y: 400),
                      CGPoint(x: 200, y: 901), CGPoint(x: CGFloat.nan, y: 400), CGPoint(x: 200, y: CGFloat.infinity)] {
            XCTAssertNil(ReaderTapPolicy.action(at: point, in: viewport, direction: .leftToRight, mode: .singlePage))
        }
        for invalid in [CGRect.zero, CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)] {
            XCTAssertNil(ReaderTapPolicy.action(at: .zero, in: invalid, direction: .leftToRight, mode: .singlePage))
        }
    }

    func testContinuousModeRetainsItsCenterTapAndDoesNotGainPageTapZones() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        for direction in ReaderDirection.allCases {
            XCTAssertEqual(ReaderTapPolicy.action(at: CGPoint(x: 200, y: 400), in: viewport, direction: direction, mode: .continuous), .center)
            for point in [CGPoint(x: 30, y: 400), CGPoint(x: 370, y: 400), CGPoint(x: 200, y: 30), CGPoint(x: 200, y: 770)] {
                XCTAssertNil(ReaderTapPolicy.action(at: point, in: viewport, direction: direction, mode: .continuous))
            }
        }
    }

    func testFastScrollTargetsItsProjectedPageWithoutLimitingToAdjacentPage() {
        let frames = (0..<10).map { CGRect(x: 0, y: CGFloat($0 * 400), width: 300, height: 400) }
        let target = ReaderSnapPolicy.offset(proposed: 2030, viewport: 400, content: 4000,
                                             ranges: frames, horizontal: false, zoomed: false)
        XCTAssertEqual(target, 2000)
    }
    func testLongPageInteriorIsFreeAndItsEndCanSnap() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 1800)
        XCTAssertNil(ReaderSnapPolicy.offset(proposed: 350, viewport: 600, content: 2200,
                                             ranges: [frame], horizontal: false, zoomed: false))
        XCTAssertEqual(ReaderSnapPolicy.offset(proposed: 1250, viewport: 600, content: 2200,
                                               ranges: [frame], horizontal: false, zoomed: false), 1200)
    }
    func testZoomAndUnknownDistantFramesCannotForceASnap() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 500)
        XCTAssertNil(ReaderSnapPolicy.offset(proposed: 30, viewport: 300, content: 4000,
                                             ranges: [frame], horizontal: false, zoomed: true))
        XCTAssertNil(ReaderSnapPolicy.offset(proposed: 2500, viewport: 300, content: 4000,
                                             ranges: [frame], horizontal: false, zoomed: false))
    }
    func testShortHorizontalPageMatchesCenteredScrollPosition() {
        XCTAssertEqual(ReaderSnapPolicy.offset(proposed: 325, viewport: 300, content: 2000,
                                               ranges: [CGRect(x: 360, y: 0, width: 200, height: 300)],
                                               horizontal: true, zoomed: false), 310)
    }
    func testReverseMiddleShortPageDoesNotCollapseOntoContentStart() {
        // Physical order is page3, page2, page1. Page2 must retain its own
        // top-aligned stop even though its trailing alignment would be < 0.
        let frames = [CGRect(x: 0, y: 0, width: 400, height: 400),
                      CGRect(x: 0, y: 402, width: 400, height: 200),
                      CGRect(x: 0, y: 604, width: 400, height: 600)]
        XCTAssertEqual(ReaderSnapPolicy.offset(proposed: 390, viewport: 700, content: 1204,
                                               ranges: frames, horizontal: false, zoomed: false), 402)
    }
    func testSlideTravelsAlongAllFourDirectionsAndReversesForBack() {
        let size = CGSize(width: 320, height: 600)
        XCTAssertEqual(ReaderSlidePolicy.travel(direction: .leftToRight, forward: true, size: size), CGSize(width: 320, height: 0))
        XCTAssertEqual(ReaderSlidePolicy.travel(direction: .rightToLeft, forward: true, size: size), CGSize(width: -320, height: 0))
        XCTAssertEqual(ReaderSlidePolicy.travel(direction: .topToBottom, forward: true, size: size), CGSize(width: 0, height: 600))
        XCTAssertEqual(ReaderSlidePolicy.travel(direction: .bottomToTop, forward: true, size: size), CGSize(width: 0, height: -600))
        for direction in ReaderDirection.allCases {
            let forward = ReaderSlidePolicy.travel(direction: direction, forward: true, size: size)
            let back = ReaderSlidePolicy.travel(direction: direction, forward: false, size: size)
            XCTAssertEqual(forward.width, -back.width); XCTAssertEqual(forward.height, -back.height)
        }
    }
    func testInteractiveDragMapsAllDirectionsAndKeepsShortDragsCancelled() {
        XCTAssertEqual(ReaderDragPolicy.pageDelta(offset: -100, direction: .leftToRight), 1)
        XCTAssertEqual(ReaderDragPolicy.pageDelta(offset: 100, direction: .rightToLeft), 1)
        XCTAssertEqual(ReaderDragPolicy.pageDelta(offset: -100, direction: .topToBottom), 1)
        XCTAssertEqual(ReaderDragPolicy.pageDelta(offset: 100, direction: .bottomToTop), 1)
        XCTAssertFalse(ReaderDragPolicy.commits(offset: 32, predicted: 800, extent: 400))
        XCTAssertFalse(ReaderDragPolicy.commits(offset: 45, predicted: 45, extent: 400))
        XCTAssertTrue(ReaderDragPolicy.commits(offset: 110, predicted: 110, extent: 400))
        XCTAssertTrue(ReaderDragPolicy.commits(offset: -40, predicted: -250, extent: 400))
        XCTAssertEqual(ReaderDragPolicy.boundedOffset(200, extent: 400, hasNeighbor: true), 200)
        XCTAssertEqual(ReaderDragPolicy.boundedOffset(200, extent: 400, hasNeighbor: false), 32)
    }

    func testNeighborReboundKeepsItsSideAtZeroInEveryDirection() {
        let size = CGSize(width: 400, height: 800)
        for direction in ReaderDirection.allCases {
            for neighbor in [1, 3] {
                let origin = ReaderDragPolicy.pageOffset(index: neighbor, current: 2, direction: direction, size: size, translation: 0)
                for translation in [-30.0, 30.0] {
                    let moving = ReaderDragPolicy.pageOffset(index: neighbor, current: 2, direction: direction, size: size, translation: translation)
                    let axisOrigin = direction.horizontal ? origin.width : origin.height
                    let axisMoving = direction.horizontal ? moving.width : moving.height
                    XCTAssertEqual(axisMoving - axisOrigin, translation)
                    XCTAssertGreaterThan(axisMoving * axisOrigin, 0, "Returning to zero must keep the neighbor on its original side")
                }
            }
        }
    }

    func testCommittedNeighborAndPreviousCanvasKeepTheirPhysicalPositionsAtHandoff() {
        let size = CGSize(width: 400, height: 800)
        for direction in ReaderDirection.allCases {
            for target in [1, 3] {
                let travel = ReaderSlidePolicy.travel(direction: direction, forward: target > 2, size: size)
                let end = -(direction.horizontal ? travel.width : travel.height)
                for index in [2, target] {
                    let before = ReaderDragPolicy.pageOffset(index: index, current: 2, direction: direction, size: size, translation: end)
                    let after = ReaderDragPolicy.pageOffset(index: index, current: target, direction: direction, size: size, translation: 0)
                    XCTAssertEqual(before, after, "The same keyed Canvas must not jump during current-page handoff")
                }
            }
        }
    }

}

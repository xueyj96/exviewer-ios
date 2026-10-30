import XCTest
import Combine
import ExViewerCore
@testable import ExViewer

@MainActor final class FeedViewportTests: XCTestCase {
    func testEqualHeightColumnsAlwaysChooseTheSameAnchorRegardlessOfDictionaryOrder() {
        let viewport = GalleryFeedViewport(space: "qa", height: 800, topOcclusion: 120)
        let cells = [("right", CGRect(x: 200, y: 130, width: 180, height: 200)),
                     ("left", CGRect(x: 10, y: 130, width: 180, height: 300))]
        XCTAssertEqual(viewport.nearestVisibleAnchor(in: Dictionary(uniqueKeysWithValues: cells)), "left")
        XCTAssertEqual(viewport.nearestVisibleAnchor(in: Dictionary(uniqueKeysWithValues: cells.reversed())), "left")
    }

    func testAnchorExcludesCoveredAndOffscreenRowsAndPreservesMarkerAlignment() {
        let viewport = GalleryFeedViewport(space: "qa", height: 800, topOcclusion: 120)
        let cells = ["covered": CGRect(x: 0, y: 0, width: 100, height: 110),
                     "visible": CGRect(x: 0, y: 100, width: 100, height: 200),
                     "below": CGRect(x: 0, y: 801, width: 100, height: 200)]
        XCTAssertEqual(viewport.nearestVisibleAnchor(in: cells), "visible")
        XCTAssertEqual(viewport.restorationAlignment.y, 120 / 799.0, accuracy: 0.0001)
        XCTAssertNil(GalleryFeedViewport(space: "qa", height: 100, topOcclusion: 120).nearestVisibleAnchor(in: cells))
    }

    func testRepeatedViewportFramesPublishOnlyActualAnchorTransitions() throws {
        let anchors = (0..<240).map { "ex:\($0 / 40 + 1)" }
        func entry() -> DiscoveryEntry {
            .init(query: SearchQuery(), site: .ex, lane: 0, savedID: nil, requestURL: GallerySite.ex.baseURL)
        }
        let before = entry(), after = entry()
        var directEvents = 0, deduplicatedEvents = 0
        let oldSubscription = before.objectWillChange.sink { directEvents += 1 }
        let newSubscription = after.objectWillChange.sink { deduplicatedEvents += 1 }
        for anchor in anchors { before.scrollAnchor = anchor; after.updateVisibleAnchor(anchor) }
        XCTAssertEqual(directEvents, 240)
        XCTAssertEqual(deduplicatedEvents, 6)
        XCTAssertEqual(before.scrollAnchor, after.scrollAnchor)
        withExtendedLifetime((oldSubscription, newSubscription)) {}
        let data = try JSONSerialization.data(withJSONObject: ["viewport_frames": anchors.count, "direct_publications": directEvents, "deduplicated_publications": deduplicatedEvents, "same_latest_anchor": before.scrollAnchor == after.scrollAnchor], options: .prettyPrinted)
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "feed-anchor-publication-comparison"; evidence.lifetime = .keepAlways; add(evidence)
    }
}

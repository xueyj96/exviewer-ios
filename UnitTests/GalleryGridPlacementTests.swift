import XCTest
@testable import ExViewer

final class GalleryGridPlacementTests: XCTestCase {
    func testInitialEqualHeightsAlternateWithDeterministicTies() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d"], aspects: [:])
        XCTAssertEqual(layout.columns, [["a", "c"], ["b", "d"]])
    }

    func testLateAspectUpdatesDoNotRedistributeExistingCards() {
        var layout = GalleryGridPlacement()
        let ids = ["a", "b", "c", "d"]
        layout.update(ids: ids, aspects: [:])
        let original = layout.columns
        layout.update(ids: ids, aspects: ["a": 0.2, "b": 3, "c": 0.3, "d": 2])
        XCTAssertEqual(layout.columns, original)
    }

    func testAppendUsesCurrentHeightsButPreservesAllExistingMemberships() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d"], aspects: [:])
        layout.update(ids: ["a", "b", "c", "d", "e", "f"],
                      aspects: ["a": 0.3, "c": 0.3, "b": 2, "d": 2, "e": 1, "f": 1])
        XCTAssertEqual(layout.columns, [["a", "c"], ["b", "d", "e", "f"]])
    }

    func testRemovalClosesGapsWithoutMovingSurvivorsBetweenColumns() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d"], aspects: [:])
        layout.update(ids: ["a", "c", "d"], aspects: ["a": 2, "c": 2, "d": 0.2])
        XCTAssertEqual(layout.columns, [["a", "c"], ["d"]])
    }

    func testPrependAndExplicitReorderResetToTheNewResultOrder() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "b", "c", "d"], aspects: [:])
        layout.update(ids: ["x", "a", "b", "c", "d"], aspects: [:])
        XCTAssertEqual(layout.columns, [["x", "b", "d"], ["a", "c"]])
        layout.update(ids: ["d", "c", "b", "a", "x"], aspects: [:])
        XCTAssertEqual(layout.columns, [["d", "b", "x"], ["c", "a"]])
    }

    func testDuplicateAndInvalidAspectInputsRemainFiniteAndEmptyResets() {
        var layout = GalleryGridPlacement()
        layout.update(ids: ["a", "a", "b"], aspects: ["a": .nan, "b": 0])
        XCTAssertEqual(layout.order, ["a", "b"])
        XCTAssertEqual(layout.columns, [["a"], ["b"]])
        layout.update(ids: [], aspects: [:])
        XCTAssertEqual(layout.columns, [[], []])
        layout.update(ids: ["new"], aspects: [:])
        XCTAssertEqual(layout.columns, [["new"], []])
    }

    func testThousandCardPagedFeedKeepsMembershipAfterEveryAppend() {
        var layout = GalleryGridPlacement()
        for count in stride(from: 40, through: 1_000, by: 40) {
            let previous = Dictionary(uniqueKeysWithValues: layout.columns.enumerated().flatMap { column, ids in ids.map { ($0, column) } })
            let ids = (0..<count).map(String.init)
            let aspects = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in (id, index.isMultiple(of: 3) ? 0.3 : 2.0) })
            layout.update(ids: ids, aspects: aspects)
            let current = Dictionary(uniqueKeysWithValues: layout.columns.enumerated().flatMap { column, ids in ids.map { ($0, column) } })
            XCTAssertEqual(current.count, count)
            for (id, column) in previous { XCTAssertEqual(current[id], column) }
        }
    }
}

import XCTest
import ExViewerCore
@testable import ExViewer

final class LibrarySelectionTests: XCTestCase {
    @MainActor func testLargeSelectionFixtureIsNeutralUniqueAndLocal() {
        let galleries = LibrarySelectionQA.galleries
        XCTAssertEqual(galleries.count, 600)
        XCTAssertEqual(Set(galleries.map(\.id)).count, galleries.count)
        XCTAssertTrue(galleries.allSatisfy { $0.tagsComplete && $0.cover?.isFileURL == true })

        let selection = Set(galleries.map(\.id))
        XCTAssertEqual(selection.count, galleries.count)
        XCTAssertTrue(selection.contains(galleries[0].id))
        XCTAssertTrue(selection.contains(galleries[599].id))
    }

    @MainActor func testLargeSelectionBlockedTagWorkloadIsQAOnlyAndDoesNotFilterSamples() {
        let blocked = LibrarySelectionQA.blockedTags
        XCTAssertEqual(blocked.count, 250)
        XCTAssertEqual(Set(blocked.map(\.id)).count, blocked.count)
        XCTAssertFalse(LibrarySelectionQA.seedsBlockedTags(isQA: false, arguments: ["--qa-library-large-selection"]))
        XCTAssertFalse(LibrarySelectionQA.seedsBlockedTags(isQA: true, arguments: []))
        XCTAssertTrue(LibrarySelectionQA.seedsBlockedTags(isQA: true, arguments: ["--qa-library-large-selection"]))

        let blockedIDs = Set(blocked.map(\.id))
        let result = LibrarySelectionPolicy.filtered(LibrarySelectionQA.galleries, blocked: blockedIDs)
        XCTAssertEqual(result.visible.count, 600)
        XCTAssertEqual(result.unknown, 0)
        XCTAssertTrue(blocked.allSatisfy { $0.namespace == "qa-unmatched" })
    }

    func testSelectionOperationsOnlyChangeTargetedIDsAndClearTheLoadedSet() {
        let untouched: Set<String> = ["other-context"]
        let one = LibrarySelectionPolicy.toggled("gallery-1", in: untouched)
        XCTAssertEqual(one, ["other-context", "gallery-1"])
        XCTAssertEqual(LibrarySelectionPolicy.toggled("gallery-1", in: one), untouched)

        let loaded = (0..<600).map { "gallery-\($0)" }
        let all = LibrarySelectionPolicy.selectAllOrClear(loaded, current: untouched)
        XCTAssertEqual(all.count, 601)
        XCTAssertTrue(all.contains("other-context"))
        XCTAssertEqual(LibrarySelectionPolicy.selectAllOrClear(loaded, current: all), untouched)
    }

    func testSameCountContentReplacementAndBlockChangesProduceFreshVisibleData() {
        let blockedTag = GalleryTag(namespace: "artist", name: "hidden")
        var original = Gallery(ref: .init(site: .ex, gid: 77, token: "fixture"), title: "Original", tags: [], cover: nil)
        original.tagsComplete = true
        let initial = LibrarySelectionPolicy.filtered([original], blocked: [blockedTag.id])
        XCTAssertEqual(initial.visible.map(\.title), ["Original"])
        XCTAssertEqual(initial.unknown, 0)

        var replacement = original
        replacement.title = "Replacement metadata"
        replacement.tags = [blockedTag]
        let replaced = LibrarySelectionPolicy.filtered([replacement], blocked: [blockedTag.id])
        XCTAssertTrue(replaced.visible.isEmpty, "Same-ID, same-count metadata changes must recalculate tag visibility")

        let unblocked = LibrarySelectionPolicy.filtered([replacement], blocked: [])
        XCTAssertEqual(unblocked.visible.map(\.title), ["Replacement metadata"])
    }
}

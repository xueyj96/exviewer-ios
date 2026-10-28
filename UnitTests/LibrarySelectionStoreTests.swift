import Combine
import XCTest
@testable import ExViewer

final class LibrarySelectionStoreTests: XCTestCase {
    @MainActor
    func testSingleTogglePublishesOnlyTargetEntryAndIndependentSummary() {
        let store = LibrarySelectionStore()
        store.updateLoadedIDs(["a", "b"])
        let first = store.entry(for: "a")
        let second = store.entry(for: "b")
        store.beginSelecting("a")

        var storeUpdates = 0
        var summaryUpdates = 0
        var firstUpdates = 0
        var secondUpdates = 0
        let storeToken = store.objectWillChange.sink { _ in storeUpdates += 1 }
        let summaryToken = store.summary.objectWillChange.sink { _ in summaryUpdates += 1 }
        let firstToken = first.objectWillChange.sink { _ in firstUpdates += 1 }
        let secondToken = second.objectWillChange.sink { _ in secondUpdates += 1 }

        store.toggle("a")

        XCTAssertEqual(store.selectedIDs, [])
        XCTAssertFalse(first.isSelected)
        XCTAssertFalse(second.isSelected)
        XCTAssertEqual(store.summary.value.count, 0)
        XCTAssertFalse(store.summary.value.allLoadedSelected)
        XCTAssertEqual(storeUpdates, 0, "A tile toggle must not publish from the parent selection store")
        XCTAssertEqual(summaryUpdates, 1, "The count/toolbar summary should publish once")
        XCTAssertEqual(firstUpdates, 1, "Only the changed tile entry should publish")
        XCTAssertEqual(secondUpdates, 0)

        withExtendedLifetime([storeToken, summaryToken, firstToken, secondToken]) { }
    }

    @MainActor
    func testBulkSelectionTracksLoadedIDsAndUpdatesOnlyExistingEntries() {
        let store = LibrarySelectionStore()
        let loaded = Set((0..<600).map { "gallery-\($0)" })
        store.updateLoadedIDs(loaded)
        let first = store.entry(for: "gallery-0")
        let last = store.entry(for: "gallery-599")
        var firstUpdates = 0
        var lastUpdates = 0
        let firstToken = first.objectWillChange.sink { _ in firstUpdates += 1 }
        let lastToken = last.objectWillChange.sink { _ in lastUpdates += 1 }

        store.toggleAllLoaded()
        XCTAssertEqual(store.selectedIDs.count, 600)
        XCTAssertTrue(store.summary.value.allLoadedSelected)
        XCTAssertTrue(first.isSelected)
        XCTAssertTrue(last.isSelected)
        XCTAssertEqual(firstUpdates, 1)
        XCTAssertEqual(lastUpdates, 1)

        store.toggleAllLoaded()
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertFalse(store.summary.value.allLoadedSelected)
        XCTAssertFalse(first.isSelected)
        XCTAssertFalse(last.isSelected)
        withExtendedLifetime([firstToken, lastToken]) { }
    }

    @MainActor
    func testDatasetAppendPreservesSelectionAndContextClearRemovesIt() {
        let store = LibrarySelectionStore()
        store.updateLoadedIDs(["a", "b"])
        store.beginSelecting("a")
        let stableEntry = store.entry(for: "a")

        store.updateLoadedIDs(["a", "b", "c"])
        XCTAssertEqual(store.selectedIDs, ["a"])
        XCTAssertFalse(store.summary.value.allLoadedSelected)
        XCTAssertTrue(store.entry(for: "a") === stableEntry)

        store.clear()
        store.updateLoadedIDs(["x", "y"])
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertEqual(store.summary.value.count, 0)
        XCTAssertFalse(store.entry(for: "a").isSelected)
    }

    @MainActor
    func testConfirmedBatchRemovalLeavesOtherSelectionsUntouched() {
        let store = LibrarySelectionStore()
        store.updateLoadedIDs(["a", "b", "c"])
        store.beginSelecting("a")
        store.toggle("b")
        let a = store.entry(for: "a")
        let b = store.entry(for: "b")

        store.remove(["a"])

        XCTAssertEqual(store.selectedIDs, ["b"])
        XCTAssertEqual(store.summary.value.count, 1)
        XCTAssertFalse(a.isSelected)
        XCTAssertTrue(b.isSelected)
    }

    @MainActor
    func testDatasetReplacementDropsSelectionsOutsideVisibleIDsAndRejectsStaleTaps() {
        let store = LibrarySelectionStore()
        store.updateLoadedIDs(["a", "b"])
        XCTAssertTrue(store.beginSelecting("a"))
        store.toggle("b")
        let staleEntry = store.entry(for: "a")
        let currentEntry = store.entry(for: "b")

        store.updateLoadedIDs(["b", "c"])

        XCTAssertEqual(store.selectedIDs, ["b"])
        XCTAssertEqual(store.summary.value.count, 1)
        XCTAssertFalse(staleEntry.isSelected)
        XCTAssertTrue(currentEntry.isSelected)
        XCTAssertFalse(store.toggle("a"), "A tap from a stale cell must not restore an unloaded ID")
        XCTAssertFalse(store.beginSelecting("a"), "A stale long press must not begin management")
        XCTAssertEqual(store.selectedIDs, ["b"])
    }
}

import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class LibrarySortingTests: XCTestCase {
    private func gallery(_ id: Int64, _ title: String) -> Gallery {
        var value = Gallery(ref: .init(site: .ex, gid: id, token: "fixture"), title: title)
        value.tagsComplete = true; return value
    }
    private var values: [Gallery] { [gallery(1, "Beta 10"), gallery(4, "Never Read"), gallery(3, "Alpha 10"), gallery(2, "Alpha 2")] }
    private var history: [ReadingRecord] {
        [ReadingRecord(gallery: values[0], page: 7, date: Date(timeIntervalSince1970: 100)),
         ReadingRecord(gallery: values[2], page: 4, date: Date(timeIntervalSince1970: 300)),
         ReadingRecord(gallery: values[3], page: 2, date: Date(timeIntervalSince1970: 200))]
    }
    func testHistoryUsesRecordedDatesAndNaturalTitleOrderWithoutChangingPages() {
        XCTAssertEqual(LibrarySorting.history(history, order: .recent).map(\.id), ["ex:3", "ex:2", "ex:1"])
        XCTAssertEqual(LibrarySorting.history(history, order: .oldest).map(\.id), ["ex:1", "ex:2", "ex:3"])
        XCTAssertEqual(LibrarySorting.history(history, order: .title).map(\.id), ["ex:2", "ex:3", "ex:1"])
        XCTAssertEqual(history.map(\.page), [7, 4, 2])
    }
    func testOriginalOrderAndUnreadTailAreStableForBookmarksAndDownloads() {
        let expected: [LibrarySortOrder: [Int64]] = [.original: [1, 4, 3, 2], .title: [2, 3, 1, 4], .recent: [3, 2, 1, 4]]
        let records = values.map { DownloadRecord(gallery: $0, status: .paused, completed: [1: "page1.png"], total: 9) }
        for (order, ids) in expected {
            XCTAssertEqual(LibrarySorting.galleries(values, order: order, history: history).map(\.ref.gid), ids)
            let sorted = LibrarySorting.downloads(records, order: order, history: history)
            XCTAssertEqual(sorted.map(\.gallery.ref.gid), ids)
            XCTAssertTrue(sorted.allSatisfy { $0.status == .paused && $0.completed == [1: "page1.png"] && $0.total == 9 })
        }
    }
    func testMissingHistoryAndEqualKeysRetainOriginalRelativeOrder() {
        let a = gallery(5, "same"), b = gallery(6, "same"), c = gallery(7, "unread")
        let same = Date(timeIntervalSince1970: 500)
        let read = [ReadingRecord(gallery: a, page: 1, date: same), ReadingRecord(gallery: b, page: 1, date: same)]
        XCTAssertEqual(LibrarySorting.galleries([b, c, a], order: .recent, history: read).map(\.ref.gid), [6, 5, 7])
        XCTAssertEqual(LibrarySorting.galleries([b, a], order: .title, history: []).map(\.ref.gid), [6, 5])
        XCTAssertEqual(LibrarySorting.galleries(values, order: .recent, history: []).map(\.id), values.map(\.id))
        XCTAssertTrue(LibrarySorting.history([], order: .recent).isEmpty)
        XCTAssertTrue(LibrarySorting.downloads([], order: .title, history: history).isEmpty)
    }
    func testDuplicateHistoryUsesLatestKnownReadingWithoutInventingUnreadDates() {
        var old = history[1]; old.date = Date(timeIntervalSince1970: 50)
        let sorted = LibrarySorting.galleries(values, order: .recent, history: history + [old])
        XCTAssertEqual(sorted.map(\.ref.gid), [3, 2, 1, 4])
    }
    func testPreferencesPersistIndependentlyByOwnerAndSectionWithSafeDefaults() throws {
        let suite = "LibrarySortingTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LibrarySortPreferences(owner: "a1", defaults: defaults)
        XCTAssertEqual(first.order(for: .history), .recent)
        XCTAssertEqual(first.order(for: .bookmarks), .original)
        XCTAssertEqual(first.order(for: .downloads), .original)
        first.set(.title, for: .history); first.set(.recent, for: .bookmarks)
        let reloaded = LibrarySortPreferences(owner: "a1", defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reloaded.order(for: .history), .title); XCTAssertEqual(reloaded.order(for: .bookmarks), .recent)
        XCTAssertEqual(reloaded.order(for: .downloads), .original)
        XCTAssertEqual(LibrarySortPreferences(owner: "b2", defaults: defaults).order(for: .history), .recent)
        first.set(.oldest, for: .bookmarks)
        XCTAssertEqual(first.order(for: .bookmarks), .recent, "Unsupported choices must not overwrite preferences")
        defaults.set("future-value", forKey: "library.sort.v1.a1.history")
        XCTAssertEqual(first.order(for: .history), .recent)
        XCTAssertEqual(defaults.string(forKey: "library.sort.v1.a1.history"), "future-value")
    }
    func testLegacyLibraryAndSeparateSearchHistoryRemainByteIdenticalAfterSorting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("guest"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var original = LibrarySnapshot(); original.history = history; original.bookmarks = values
        original.downloads = values.map { .init(gallery: $0, status: .paused, total: 9) }
        let libraryFile = directory.appendingPathComponent("library.json")
        let bytes = try JSONEncoder().encode(original); try bytes.write(to: libraryFile)
        var query = SearchQuery(); query.text = "coast"; query.minRating = 3
        let recent = RecentSearchRecord(site: .ex, query: query, date: Date(timeIntervalSince1970: 600))
        let entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recent))
        let searches = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [entry]])
        let searchFile = directory.appendingPathComponent("recent-searches.json"); try searches.write(to: searchFile)
        let store = LibraryStore(qa: false, storageRoot: root)
        XCTAssertNil(store.error); XCTAssertNil(store.searchHistoryError)
        for order in LibrarySortOrder.allCases {
            _ = LibrarySorting.history(store.snapshot.history, order: order)
            _ = LibrarySorting.galleries(store.snapshot.bookmarks, order: order, history: store.snapshot.history)
            _ = LibrarySorting.downloads(store.snapshot.downloads, order: order, history: store.snapshot.history)
        }
        XCTAssertEqual(try Data(contentsOf: libraryFile), bytes)
        XCTAssertEqual(try Data(contentsOf: searchFile), searches)
        XCTAssertEqual(store.recentSearches.first?.query, query)
        XCTAssertEqual(store.snapshot.history.map(\.page), [7, 4, 2])
    }
    func testSelectionIdentitySurvivesReorderingAndLoadedAppendAtRepresentativeScale() {
        let list = (1...600).map { gallery(Int64($0), "Title \(601 - $0)") }
        let selection = LibrarySelectionStore(); selection.updateLoadedIDs(Set(list.map(\.id)))
        XCTAssertTrue(selection.beginSelecting(list[19].id)); selection.toggle(list[99].id)
        let entry = selection.entry(for: list[19].id)
        for order in [LibrarySortOrder.title, .recent, .original] {
            let sorted = LibrarySorting.galleries(list, order: order, history: [])
            selection.updateLoadedIDs(Set(sorted.map(\.id)))
            XCTAssertEqual(selection.selectedIDs, [list[19].id, list[99].id])
            XCTAssertTrue(selection.entry(for: list[19].id) === entry)
        }
        selection.updateLoadedIDs(Set((list + [gallery(601, "Next batch")]).map(\.id)))
        XCTAssertEqual(selection.selectedIDs.count, 2)
    }
}

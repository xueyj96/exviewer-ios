import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class SearchSortingTests: XCTestCase {
    func testChangingOrderKeepsLoadedPagesAndAnInFlightContinuationWithoutRestarting() async throws {
        let session = SiteSession(qa: true)
        var query = SearchQuery(); query.text = "coast"
        let navigation = DiscoveryNavigation(query: query)
        try navigation.startCurrent(session: session, qa: true)
        let original = navigation.current, source = original.pager.items
        original.scrollAnchor = source[2].id
        let cursor = original.pager.next
        original.pager.more(session: session)
        XCTAssertTrue(original.pager.loading)

        query.sortOrder = .title
        XCTAssertFalse(try navigation.submit(query: query, site: .ex, lane: 0, savedID: nil, session: session, qa: true))
        let sorted = navigation.current
        XCTAssertTrue(sorted.pager === original.pager, "A local sort must not start or cancel a network request")
        XCTAssertEqual(sorted.pager.next, cursor)
        XCTAssertTrue(sorted.pager.loading); XCTAssertFalse(sorted.pager.interrupted)
        XCTAssertNil(sorted.scrollAnchor, "An explicit new ordering starts at its first result")
        XCTAssertTrue(navigation.history.isEmpty)
        XCTAssertEqual(sorted.displayedItems.map(\.id), SearchSortOrder.title.ordered(source).map(\.id))
        let initialRevision = sorted.sortedOrderRevision
        let visibleAnchor = sorted.displayedItems[1].id
        sorted.scrollAnchor = visibleAnchor

        let deadline = Date().addingTimeInterval(2)
        while sorted.pager.loading && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(sorted.pager.loading)
        XCTAssertEqual(sorted.pager.items.count, 6)
        XCTAssertEqual(sorted.displayedItems.map(\.id), SearchSortOrder.title.ordered(sorted.pager.items).map(\.id))
        XCTAssertGreaterThan(sorted.sortedOrderRevision, initialRevision, "A sorted append must restore the current visible card")
        XCTAssertEqual(sorted.scrollAnchor, visibleAnchor)
        query.sortOrder = .siteDefault
        try navigation.submit(query: query, site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        XCTAssertTrue(navigation.current.pager === original.pager)
        XCTAssertEqual(navigation.current.displayedItems.map(\.id), navigation.current.pager.items.map(\.id))
        XCTAssertEqual(navigation.current.pager.items.count, 6)
        XCTAssertEqual(navigation.current.sortedOrderRevision, 0, "Site-order append must keep the existing stable placement")
    }

    func testSavedAndRecentSearchesIncludeOrderAndPersistIndependentlyFromSiteCacheIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(qa: false, storageRoot: root)
        var query = SearchQuery(); query.text = "coast"
        XCTAssertTrue(store.recordSearch(query: query, site: .ex))
        let originalKey = try RecentSearchRecord.requestKey(site: .ex, query: query)
        let originalURL = try query.url(site: .ex)
        query.sortOrder = .ratingDescending
        XCTAssertTrue(store.recordSearch(query: query, site: .ex))
        XCTAssertEqual(store.recentSearches.count, 2)
        XCTAssertNotEqual(try RecentSearchRecord.requestKey(site: .ex, query: query), originalKey)
        XCTAssertEqual(try query.url(site: .ex), originalURL)
        let savedID = try XCTUnwrap(store.saveSearch(name: "High rating", site: .ex, query: query))
        XCTAssertEqual(store.savedSearch(matching: query, site: .ex)?.id, savedID)
        var different = query; different.sortOrder = .pagesAscending
        XCTAssertNil(store.savedSearch(matching: different, site: .ex))
        XCTAssertTrue(SearchPresentation.conditions(query).contains("评分从高到低 · 已加载结果"))

        let reloaded = LibraryStore(qa: false, storageRoot: root)
        XCTAssertNil(reloaded.error); XCTAssertNil(reloaded.searchHistoryError)
        XCTAssertEqual(reloaded.snapshot.saved.first?.query, query)
        XCTAssertEqual(reloaded.recentSearches.first?.query, query)
        XCTAssertTrue(reloaded.recordSearch(query: query, site: .ex))
        XCTAssertEqual(reloaded.recentSearches.count, 2, "An identical order updates one history record")
        var onlySort = SearchQuery(); onlySort.sortOrder = .pagesAscending
        XCTAssertTrue(reloaded.recordSearch(query: onlySort, site: .ex))
        XCTAssertNotNil(reloaded.saveSearch(name: "Short first", site: .ex, query: onlySort))
    }

    func testLegacyLibraryAndHistoryAreReadableAndNotRewrittenOnLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("guest")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var query = SearchQuery(); query.text = "legacy"; query.minRating = 3
        var snapshot = LibrarySnapshot(); snapshot.saved = [.init(name: "Existing", site: .ex, query: query)]
        var library = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var saved = try XCTUnwrap(library["saved"] as? [[String: Any]])
        var fields = try XCTUnwrap(saved[0]["query"] as? [String: Any]); fields.removeValue(forKey: "sortOrder")
        saved[0]["query"] = fields; library["saved"] = saved
        let libraryBytes = try JSONSerialization.data(withJSONObject: library)
        let history = ["version": 1, "entries": [["id": UUID().uuidString, "site": "ex", "date": 123, "query": fields]]] as [String: Any]
        let historyBytes = try JSONSerialization.data(withJSONObject: history)
        let libraryFile = directory.appendingPathComponent("library.json"), historyFile = directory.appendingPathComponent("recent-searches.json")
        try libraryBytes.write(to: libraryFile); try historyBytes.write(to: historyFile)
        let store = LibraryStore(qa: false, storageRoot: root)
        XCTAssertNil(store.error); XCTAssertNil(store.searchHistoryError)
        XCTAssertEqual(store.snapshot.saved.first?.query, query)
        XCTAssertEqual(store.recentSearches.first?.query, query)
        XCTAssertEqual(try Data(contentsOf: libraryFile), libraryBytes)
        XCTAssertEqual(try Data(contentsOf: historyFile), historyBytes)
    }
}

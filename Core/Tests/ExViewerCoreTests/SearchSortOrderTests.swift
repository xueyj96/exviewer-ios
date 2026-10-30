import XCTest
@testable import ExViewerCore

final class SearchSortOrderTests: XCTestCase {
    private func gallery(_ id: Int64, title: String = "Same", rating: Double? = nil, pages: Int? = nil) -> Gallery {
        Gallery(ref: .init(site: .ex, gid: id, token: "fixture"), title: title, pages: pages, rating: rating)
    }

    func testRatingsUseKnownAveragesAndKeepEqualOrUnknownValuesStable() {
        let values = [gallery(1, rating: nil), gallery(2, rating: 3), gallery(3, rating: 4.8),
                      gallery(4, rating: 4.8), gallery(5, rating: .nan), gallery(6, rating: 6)]
        XCTAssertEqual(SearchSortOrder.ratingDescending.ordered(values).map(\.ref.gid), [3, 4, 2, 1, 5, 6])
        XCTAssertEqual(SearchSortOrder.siteDefault.ordered(values).map(\.ref.gid), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(values.map(\.ref.gid), [1, 2, 3, 4, 5, 6], "Presentation sorting must not rewrite the source list")
    }

    func testPageOrdersAndNaturalTitlesPutUnknownPagesLast() {
        let values = [gallery(1, title: "Book 10", pages: 100), gallery(2, title: "Book 2", pages: 20),
                      gallery(3, title: "Book 2", pages: nil), gallery(4, title: "Book 3", pages: 20),
                      gallery(5, title: "Book 4", pages: 0)]
        XCTAssertEqual(SearchSortOrder.pagesDescending.ordered(values).map(\.ref.gid), [1, 2, 4, 3, 5])
        XCTAssertEqual(SearchSortOrder.pagesAscending.ordered(values).map(\.ref.gid), [2, 4, 1, 3, 5])
        XCTAssertEqual(SearchSortOrder.title.ordered(values).map(\.ref.gid), [2, 3, 4, 5, 1])
        for order in SearchSortOrder.allCases { XCTAssertTrue(order.ordered([]).isEmpty) }
    }

    func testLegacySavedSearchWithoutSortDecodesWithoutLosingAnyConditions() throws {
        var query = SearchQuery(); query.text = "coast"; query.artist = "sample"
        query.minRating = 3; query.minPages = 20; query.maxPages = 200
        query.rules = [.init(tag: .init(namespace: "language", name: "english"))]
        let saved = SavedSearch(name: "Existing", site: .ex, query: query)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var fields = try XCTUnwrap(legacy["query"] as? [String: Any]); fields.removeValue(forKey: "sortOrder")
        legacy["query"] = fields
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded, saved)
        XCTAssertEqual(decoded.query.sortOrder, .siteDefault)
        fields["sortOrder"] = "unrecognized-future-order"; legacy["query"] = fields
        XCTAssertThrowsError(try JSONDecoder().decode(SavedSearch.self, from: JSONSerialization.data(withJSONObject: legacy)))
    }

    func testSortRoundTripsAndNeverChangesTheSiteRequestOrConditionLimit() throws {
        var query = SearchQuery(); query.text = "one two three four five"
        let url = try query.url(site: .ex), expression = try query.expression()
        for order in SearchSortOrder.allCases {
            query.sortOrder = order
            let saved = SavedSearch(name: order.name, site: .ex, query: query)
            XCTAssertEqual(try JSONDecoder().decode(SavedSearch.self, from: JSONEncoder().encode(saved)), saved)
            XCTAssertEqual(try query.url(site: .ex), url)
            XCTAssertEqual(try query.expression(), expression)
            XCTAssertEqual(try SearchInputParser.parse("coast language:english", preserving: query).query.sortOrder, order)
        }
        XCTAssertFalse(SearchQuery().hasSettings)
        var onlySort = SearchQuery(); onlySort.sortOrder = .pagesAscending
        XCTAssertTrue(onlySort.hasSettings)
        XCTAssertEqual(onlySort.count, 0, "Local ordering is not an additional site filter")
    }
}

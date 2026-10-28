import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor
final class DiscoveryNavigationTests: XCTestCase {
    func testPagedEntriesRestoreItemsCursorAndAnchorAcrossBackNavigation() async throws {
        let session = SiteSession(qa: true)
        let navigation = DiscoveryNavigation()
        try navigation.startCurrent(session: session, qa: true)

        let entryA = navigation.current
        entryA.pager.more(session: session)
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(entryA.pager.items.count, 6)
        entryA.scrollAnchor = QASamples.additionalGalleries[0].id
        let aIDs = entryA.pager.items.map(\.id)
        let aNext = entryA.pager.next

        var queryB = SearchQuery(); queryB.text = "entry B"
        _ = try navigation.submit(query: queryB, site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        let entryB = navigation.current
        entryB.scrollAnchor = QASamples.galleries[2].id
        let bIDs = entryB.pager.items.map(\.id)
        let bNext = try XCTUnwrap(entryB.pager.next)

        var queryC = SearchQuery(); queryC.text = "entry C"
        _ = try navigation.submit(query: queryC, site: .eh, lane: 0, savedID: nil, session: session, qa: true)
        XCTAssertEqual(navigation.current.query.text, "entry C")

        XCTAssertTrue(navigation.back())
        XCTAssertTrue(navigation.current === entryB)
        XCTAssertEqual(navigation.current.query, queryB)
        XCTAssertEqual(navigation.current.pager.items.map(\.id), bIDs)
        XCTAssertEqual(navigation.current.pager.next, bNext)
        XCTAssertEqual(navigation.current.scrollAnchor, QASamples.galleries[2].id)

        XCTAssertTrue(navigation.back())
        XCTAssertTrue(navigation.current === entryA)
        XCTAssertEqual(navigation.current.pager.items.map(\.id), aIDs)
        XCTAssertEqual(navigation.current.pager.next, aNext)
        XCTAssertEqual(navigation.current.scrollAnchor, QASamples.additionalGalleries[0].id)
    }

    func testCancelledQAPaginationCannotAppendAfterSubmittingAnotherEntry() async throws {
        let session = SiteSession(qa: true)
        let navigation = DiscoveryNavigation()
        try navigation.startCurrent(session: session, qa: true)
        let oldEntry = navigation.current
        let oldIDs = oldEntry.pager.items.map(\.id)

        oldEntry.pager.more(session: session)
        var query = SearchQuery(); query.text = "new entry"
        _ = try navigation.submit(query: query, site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        try await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertTrue(oldEntry.pager.interrupted)
        XCTAssertEqual(oldEntry.pager.items.map(\.id), oldIDs)
        XCTAssertEqual(navigation.current.query.text, "new entry")
        XCTAssertEqual(navigation.current.pager.items.map(\.id), QASamples.galleries.map(\.id))
        XCTAssertTrue(navigation.back())
        XCTAssertTrue(navigation.current.pager.interrupted)
        XCTAssertEqual(navigation.current.pager.items.map(\.id), oldIDs)
        oldEntry.pager.retry(session: session)
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertFalse(oldEntry.pager.interrupted)
        XCTAssertEqual(oldEntry.pager.items.count, 6)
    }

    func testInvalidQueryDoesNotChangeCurrentEntryOrHistory() throws {
        let session = SiteSession(qa: true)
        let navigation = DiscoveryNavigation()
        let original = navigation.current
        var invalid = SearchQuery(); invalid.text = String(repeating: "x", count: 250)

        XCTAssertThrowsError(try navigation.submit(query: invalid, site: .ex, lane: 0, savedID: nil, session: session, qa: true))
        XCTAssertTrue(navigation.current === original)
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertEqual(navigation.history.count, 0)
    }

    func testLatestAndPopularReuseTheirOwnPagedEntriesAndAnchors() async throws {
        let session = SiteSession(qa: true)
        let navigation = DiscoveryNavigation()
        try navigation.startCurrent(session: session, qa: true)
        let latest = navigation.current
        latest.pager.more(session: session)
        try await Task.sleep(nanoseconds: 220_000_000)
        latest.scrollAnchor = QASamples.additionalGalleries[0].id
        let latestIDs = latest.pager.items.map(\.id)

        try navigation.submit(query: SearchQuery(), site: .ex, lane: 1, savedID: nil, session: session, qa: true)
        let popular = navigation.current
        popular.scrollAnchor = QASamples.galleries[1].id
        try navigation.submit(query: SearchQuery(), site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        XCTAssertTrue(navigation.current === latest)
        XCTAssertEqual(navigation.current.pager.items.map(\.id), latestIDs)
        XCTAssertEqual(navigation.current.scrollAnchor, QASamples.additionalGalleries[0].id)

        try navigation.submit(query: SearchQuery(), site: .ex, lane: 1, savedID: nil, session: session, qa: true)
        XCTAssertTrue(navigation.current === popular)
        XCTAssertEqual(navigation.current.scrollAnchor, QASamples.galleries[1].id)
    }
}

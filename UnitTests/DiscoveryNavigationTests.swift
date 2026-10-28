import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor
final class DiscoveryNavigationTests: XCTestCase {
    func testUnstartedVisitorEntryCanStartWhenRestoredFromHistory() throws {
        let session = SiteSession(qa: true), navigation = DiscoveryNavigation()
        let initial = navigation.current
        var query = SearchQuery(); query.text = "visitor search"
        try navigation.submit(query: query, site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        XCTAssertTrue(navigation.back())
        XCTAssertTrue(navigation.current === initial)
        XCTAssertFalse(initial.didStart)
        try navigation.startCurrent(session: session, qa: true)
        XCTAssertTrue(initial.didStart)
        XCTAssertFalse(initial.pager.items.isEmpty)
        XCTAssertTrue(navigation.forward())
        XCTAssertEqual(navigation.current.query.text, "visitor search")
    }

    func testBackAndForwardKeepEntryObjectsLoadedPagesAndAnchors() async throws {
        let session = SiteSession(qa: true), navigation = DiscoveryNavigation()
        try navigation.startCurrent(session: session, qa: true)
        let first = navigation.current
        first.pager.more(session: session)
        try await Task.sleep(nanoseconds: 220_000_000)
        first.scrollAnchor = QASamples.additionalGalleries[0].id
        let firstIDs = first.pager.items.map(\.id)
        var query = SearchQuery(); query.text = "second"
        try navigation.submit(query: query, site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        let second = navigation.current; second.scrollAnchor = QASamples.galleries[1].id
        let secondNext = second.pager.next
        XCTAssertTrue(navigation.back())
        XCTAssertTrue(navigation.canGoForward)
        XCTAssertTrue(navigation.current === first)
        XCTAssertEqual(navigation.current.pager.items.map(\.id), firstIDs)
        XCTAssertEqual(navigation.current.scrollAnchor, QASamples.additionalGalleries[0].id)
        XCTAssertTrue(navigation.forward())
        XCTAssertTrue(navigation.current === second)
        XCTAssertEqual(navigation.current.query, query)
        XCTAssertEqual(navigation.current.pager.next, secondNext)
        XCTAssertEqual(navigation.current.scrollAnchor, QASamples.galleries[1].id)
        XCTAssertFalse(navigation.forward())
        XCTAssertFalse(navigation.canGoForward)
    }

    func testOnlyValidNewNavigationDiscardsForwardBranch() throws {
        let session = SiteSession(qa: true), navigation = DiscoveryNavigation()
        try navigation.startCurrent(session: session, qa: true)
        var second = SearchQuery(); second.text = "second"
        try navigation.submit(query: second, site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        XCTAssertTrue(navigation.back())
        let original = navigation.current, future = navigation.forwardHistory
        var invalid = SearchQuery(); invalid.text = String(repeating: "x", count: 250)
        XCTAssertThrowsError(try navigation.submit(query: invalid, site: .ex, lane: 0, savedID: nil, session: session, qa: true))
        XCTAssertTrue(navigation.current === original)
        XCTAssertEqual(navigation.forwardHistory.map(\.id), future.map(\.id))
        XCTAssertFalse(try navigation.submit(query: original.query, site: .ex, lane: 0, savedID: nil, session: session, qa: true))
        XCTAssertTrue(navigation.canGoForward)
        var third = SearchQuery(); third.text = "new branch"
        try navigation.submit(query: third, site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        XCTAssertFalse(navigation.canGoForward)
        XCTAssertFalse(navigation.forward())
    }

    func testExplicitNavigationReusesForwardEntryBeforeDiscardingBranch() throws {
        let session = SiteSession(qa: true), navigation = DiscoveryNavigation()
        try navigation.startCurrent(session: session, qa: true)
        var query = SearchQuery(); query.text = "paused"
        try navigation.submit(query: query, site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        let paused = navigation.current; paused.scrollAnchor = QASamples.galleries[1].id
        XCTAssertTrue(navigation.back())
        try navigation.submit(query: query, site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        XCTAssertTrue(navigation.current === paused)
        XCTAssertEqual(navigation.current.scrollAnchor, QASamples.galleries[1].id)
        XCTAssertFalse(navigation.canGoForward)
    }

    func testCombinedBackForwardTrailStaysBounded() throws {
        let session = SiteSession(qa: true), navigation = DiscoveryNavigation()
        try navigation.startCurrent(session: session, qa: true)
        for i in 0..<50 {
            var query = SearchQuery(); query.text = "entry \(i)"
            try navigation.submit(query: query, site: .ex, lane: 0, savedID: nil, session: session, qa: true)
        }
        XCTAssertEqual(navigation.history.count, DiscoveryNavigation.historyLimit)
        for _ in 0..<10 { XCTAssertTrue(navigation.back()) }
        XCTAssertEqual(navigation.history.count + navigation.forwardHistory.count, DiscoveryNavigation.historyLimit)
        for _ in 0..<5 { XCTAssertTrue(navigation.forward()) }
        XCTAssertEqual(navigation.history.count + navigation.forwardHistory.count, DiscoveryNavigation.historyLimit)
    }

    func testHistorySwipeRequiresHorizontalIntentAndAvailableDestination() {
        func action(_ x: Double, _ y: Double, _ predicted: Double, back: Bool = true, forward: Bool = true) -> DiscoveryHistorySwipe.Direction? {
            DiscoveryHistorySwipe.committedDirection(horizontal: x, vertical: y, predictedHorizontal: predicted, canGoBack: back, canGoForward: forward)
        }
        XCTAssertEqual(action(100, 10, 100), .back)
        XCTAssertEqual(action(-100, 10, -100), .forward)
        XCTAssertEqual(action(35, 0, 180), .back)
        XCTAssertNil(action(35, 0, -180))
        XCTAssertNil(action(35, 0, 40))
        XCTAssertNil(action(30, 150, 250))
        XCTAssertNil(action(100, 100, 150))
        XCTAssertNil(action(100, 0, 150, back: false))
        XCTAssertNil(action(-100, 0, -150, forward: false))
    }

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

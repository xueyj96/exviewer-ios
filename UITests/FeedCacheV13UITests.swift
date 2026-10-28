import XCTest

final class FeedCacheV13UITests: XCTestCase {
    private func launch(_ app: XCUIApplication, runID: String, offline: Bool = false) {
        app.launchArguments = ["--qa", "--screen", "browse", "--qa-feed-cache", "--qa-feed-cache-run", runID]
        if offline { app.launchArguments.append("--qa-feed-cache-offline") }
        app.launch()
    }

    private func state(_ app: XCUIApplication, _ lane: String) -> XCUIElement {
        app.descendants(matching: .any)["feed.qa.state.\(lane)"]
    }

    private func waitForState(_ app: XCUIApplication, lane: String, contains value: String, timeout: TimeInterval = 12) {
        let element = state(app, lane)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing QA feed state for \(lane)")
        let predicate = NSPredicate(format: "value CONTAINS %@", value)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func openFavorites(_ app: XCUIApplication) {
        app.buttons["main.tab.library"].tap()
        let scope = app.segmentedControls["library.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 8))
        scope.buttons["站点收藏"].tap()
        XCTAssertTrue(app.staticTexts["QA Feed Favorites 01"].waitForExistence(timeout: 12))
    }

    func testDiskSnapshotShowsBeforeOfflineRevalidationForBothFeeds() {
        let runID = UUID().uuidString
        let app = XCUIApplication()
        launch(app, runID: runID)
        XCTAssertTrue(app.staticTexts["QA Feed Discover 01"].waitForExistence(timeout: 15))
        waitForState(app, lane: "discover", contains: "loading=false;items=24")
        openFavorites(app)
        waitForState(app, lane: "favorites", contains: "loading=false;items=24")

        app.terminate()
        launch(app, runID: runID, offline: true)
        XCTAssertTrue(app.staticTexts["QA Feed Discover 01"].waitForExistence(timeout: 8))
        waitForState(app, lane: "discover", contains: "cached=true;loading=true", timeout: 8)
        waitForState(app, lane: "discover", contains: "failure=true", timeout: 18)
        XCTAssertTrue((state(app, "discover").value as? String)?.contains("items=24") == true)
        XCTAssertTrue(app.staticTexts["QA Feed Discover 01"].exists, "Offline revalidation must retain cached rows")

        openFavorites(app)
        waitForState(app, lane: "favorites", contains: "cached=true;loading=true", timeout: 8)
        waitForState(app, lane: "favorites", contains: "failure=true", timeout: 18)
        XCTAssertTrue((state(app, "favorites").value as? String)?.contains("items=24") == true)
        XCTAssertTrue(app.staticTexts["QA Feed Favorites 01"].exists, "Favorites snapshot must survive failed revalidation")
    }

    func testEarlyPreloadAppendsOneDistinctSecondPage() {
        let app = XCUIApplication()
        launch(app, runID: UUID().uuidString)
        XCTAssertTrue(app.staticTexts["QA Feed Discover 01"].waitForExistence(timeout: 15))
        for _ in 0..<14 {
            if (state(app, "discover").value as? String)?.contains("items=48") == true { break }
            app.swipeUp()
        }
        waitForState(app, lane: "discover", contains: "items=48", timeout: 10)
        XCTAssertFalse(app.staticTexts["QA Feed Discover 24"].isHittable, "The next batch should arrive while the tail of the first page is still ahead")
        for _ in 0..<6 { if app.staticTexts["QA Feed Discover 25"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["QA Feed Discover 25"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "QA Feed Discover 25")).count, 1)
        waitForState(app, lane: "discover", contains: "items=48;next=false;failure=false")
    }
}

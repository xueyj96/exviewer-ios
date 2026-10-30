import XCTest

final class StoredBookmarkCoversV30UITests: XCTestCase {
    func testPersistedBookmarksRestoreCoversAfterReopenAndSort() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-stored-bookmark-covers", "--qa-reset-library-sort"]
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12))
        app.buttons["main.tab.library"].tap()
        let scope = app.segmentedControls["library.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5)); scope.buttons["本机内容"].tap()
        for id in [1, 2, 3] {
            let cover = app.buttons["favorites.gallery.\(id)"]
            for _ in 0..<4 { if cover.exists && cover.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(cover.waitForExistence(timeout: 5))
            let loaded = NSPredicate(format: "label CONTAINS %@", "封面已载入")
            expectation(for: loaded, evaluatedWith: cover)
            waitForExpectations(timeout: 8)
            XCTAssertGreaterThan(cover.frame.width, 60); XCTAssertGreaterThan(cover.frame.height, 60)
        }
        let menu = app.descendants(matching: .any)["library.sort.bookmarks"].firstMatch
        for _ in 0..<4 { if menu.isHittable { break }; app.swipeDown() }
        menu.tap(); app.buttons["标题"].firstMatch.tap()
        let cover = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(cover.label.contains("封面已载入"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "stored-bookmarks.restored-covers"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["main.tab.discover"].tap(); app.buttons["discover.history"].tap()
        XCTAssertTrue(app.navigationBars["阅读历史"].waitForExistence(timeout: 5))
        let historyShot = XCTAttachment(screenshot: app.screenshot()); historyShot.name = "stored-history.restored-cover"; historyShot.lifetime = .keepAlways; add(historyShot)
    }

    func testUnavailableStoredCoverShowsRetryWithoutBlockingBookmarkBrowsing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-stored-bookmark-covers", "--qa-stored-cover-missing"]
        app.launch(); XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12))
        app.buttons["main.tab.library"].tap(); app.segmentedControls["library.scope"].buttons["本机内容"].tap()
        let cover = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        let retry = app.buttons["重新载入封面"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 8)); retry.tap()
        XCTAssertTrue(app.staticTexts["本机书签"].exists)
        let link = app.buttons["favorites.gallery.1"]
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5))
    }
}

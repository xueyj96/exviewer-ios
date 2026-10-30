import XCTest

final class LibrarySortingV28UITests: XCTestCase {
    private func openLibrary(seed: Bool = true, reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa"] + (seed ? ["--qa-library-sort"] : []) + (reset ? ["--qa-reset-library-sort"] : []) + extra
        app.launch(); XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12)); app.buttons["main.tab.library"].tap()
        let picker = app.segmentedControls["library.scope"]; XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.buttons["本机内容"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.sort.downloads"].firstMatch.waitForExistence(timeout: 5)); return app
    }
    private func openHistory(_ app: XCUIApplication) {
        app.buttons["main.tab.discover"].tap()
        app.buttons["discover.history"].tap()
        XCTAssertTrue(app.navigationBars["阅读历史"].waitForExistence(timeout: 5))
    }
    private func choose(_ app: XCUIApplication, section: String, title: String, up: Bool = true) {
        let menu = app.descendants(matching: .any)[section == "history" ? "reading-history.sort" : "library.sort.\(section)"].firstMatch
        for _ in 0..<12 { if menu.exists && menu.isHittable { break }; if up { app.swipeUp() } else { app.swipeDown() } }
        XCTAssertTrue(menu.exists && menu.isHittable); menu.tap()
        let choice = app.buttons[title].firstMatch; XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        XCTAssertEqual(menu.value as? String, title)
    }
    private func assertHistory(_ app: XCUIApplication, _ ids: [Int]) {
        let rows = ids.map { app.buttons["reading-history.item.\($0)"] }
        for row in rows { XCTAssertTrue(row.exists) }
        XCTAssertLessThan(rows[0].frame.minY, rows[1].frame.minY); XCTAssertLessThan(rows[1].frame.minY, rows[2].frame.minY)
    }
    func testHistorySortPersistsAcrossDetailReturnTabReturnAndRelaunch() {
        let app = openLibrary(); openHistory(app); assertHistory(app, [7203, 7202, 7201])
        choose(app, section: "history", title: "最早阅读"); assertHistory(app, [7201, 7202, 7203])
        choose(app, section: "history", title: "标题"); assertHistory(app, [7202, 7203, 7201])
        app.buttons["reading-history.item.7202"].tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5)); app.buttons["BackButton"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["reading-history.sort"].firstMatch.value as? String, "标题")
        app.buttons["reading-history.close"].tap()
        app.buttons["main.tab.library"].tap(); openHistory(app)
        XCTAssertEqual(app.descendants(matching: .any)["reading-history.sort"].firstMatch.value as? String, "标题")
        app.terminate()
        let relaunched = openLibrary(reset: false); openHistory(relaunched)
        XCTAssertEqual(relaunched.descendants(matching: .any)["reading-history.sort"].firstMatch.value as? String, "标题")
        assertHistory(relaunched, [7202, 7203, 7201])
    }
    func testDownloadAndBookmarkMenusAreIndependentAndUnreadItemsFollowReadItems() {
        let app = openLibrary()
        choose(app, section: "downloads", title: "最近阅读")
        let read = app.descendants(matching: .any)["library.download.item.7203"].firstMatch
        let unread = app.descendants(matching: .any)["library.download.item.7204"].firstMatch
        XCTAssertTrue(read.exists); XCTAssertTrue(unread.exists); XCTAssertLessThan(read.frame.minY, unread.frame.minY)
        choose(app, section: "bookmarks", title: "标题")
        let alpha = app.buttons["favorites.gallery.7202"]
        for _ in 0..<5 { if alpha.exists && alpha.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(alpha.exists)
        choose(app, section: "bookmarks", title: "最近阅读", up: false)
        let latest = app.buttons["favorites.gallery.7203"], next = app.buttons["favorites.gallery.7202"]
        XCTAssertTrue(latest.exists); XCTAssertTrue(next.exists); XCTAssertLessThan(latest.frame.minX, next.frame.minX)
        choose(app, section: "downloads", title: "标题", up: false)
        openHistory(app)
        XCTAssertEqual(app.descendants(matching: .any)["reading-history.sort"].firstMatch.value as? String, "最近阅读")
        app.terminate()
        let reopened = openLibrary(reset: false)
        choose(reopened, section: "downloads", title: "标题")
        choose(reopened, section: "bookmarks", title: "最近阅读")
    }
    func testEmptyLocalLibraryAndLargeTypeMenusKeepClearLabelsAndHitAreas() {
        let empty = openLibrary(seed: false)
        choose(empty, section: "downloads", title: "最近阅读")
        choose(empty, section: "bookmarks", title: "标题")
        openHistory(empty)
        XCTAssertTrue(empty.staticTexts["暂无阅读记录"].waitForExistence(timeout: 5))
        choose(empty, section: "history", title: "标题")
        empty.terminate()
        let large = openLibrary(extra: ["--qa-dark", "--qa-large-type"]); openHistory(large)
        let menu = large.descendants(matching: .any)["reading-history.sort"].firstMatch
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44); XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        choose(large, section: "history", title: "最早阅读")
        let shot = XCTAttachment(screenshot: large.screenshot()); shot.name = "history.dark-large"; shot.lifetime = .keepAlways; add(shot)
    }
    func testFavoriteSelectionHasExplicitExitAndPlainTapKeepsBrowsing() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-library-large-selection"]; app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12)); app.buttons["main.tab.library"].tap()
        let first = app.buttons["favorites.gallery.10000"]; XCTAssertTrue(first.waitForExistence(timeout: 8)); first.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5))
        app.buttons["favorites.select.10001"].tap(); XCTAssertTrue(app.staticTexts["已选 2 项"].waitForExistence(timeout: 5))
        let exit = app.buttons["favorites.edit"]; XCTAssertEqual(exit.label, "退出多选"); exit.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5)); app.buttons["BackButton"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5))
        app.buttons["favorites.select.10000"].tap(); XCTAssertTrue(app.staticTexts["已选 0 项"].waitForExistence(timeout: 5))
        exit.tap(); XCTAssertTrue(first.waitForExistence(timeout: 5))
    }
}

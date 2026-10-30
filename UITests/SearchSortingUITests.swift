import XCTest

final class SearchSortingUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-search-sort", "--qa-tags-offline"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        return app
    }

    private func startDraft(_ app: XCUIApplication) {
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("coast")
    }

    private func chooseOrder(_ app: XCUIApplication, _ title: String) {
        app.buttons["compose.filters"].tap()
        let picker = app.buttons["compose.sort-order"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        for _ in 0..<3 { if picker.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(picker.isHittable); picker.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3)); choice.tap()
        XCTAssertTrue(picker.label.contains(title))
        XCTAssertTrue(app.staticTexts["compose.sort-scope"].exists)
        app.buttons["BackButton"].tap()
    }

    private func resultStatus(_ app: XCUIApplication, includes title: String) {
        let status = app.staticTexts["discover.sort-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5)); XCTAssertTrue(status.label.contains(title))
    }

    func testSearchSettingsApplyOrderingAndRestoringSiteOrderUsesExistingResults() {
        let app = launch(); startDraft(app)
        chooseOrder(app, "评分从高到低")
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("评分从高到低") == true)
        app.buttons["compose.apply"].tap()
        resultStatus(app, includes: "评分从高到低 · 已加载结果")
        let first = app.buttons["gallery.open.2"], second = app.buttons["gallery.open.4"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.exists)
        XCTAssertLessThan(first.frame.minX, second.frame.minX)
        XCTAssertLessThan(first.frame.minY, app.buttons["gallery.open.1"].frame.minY)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "search-sort.applied"; shot.lifetime = .keepAlways; add(shot)

        app.buttons["discover.search-entry"].tap(); chooseOrder(app, "站点顺序")
        app.buttons["compose.apply"].tap()
        resultStatus(app, includes: "站点顺序")
        XCTAssertLessThan(app.buttons["gallery.open.1"].frame.minX, first.frame.minX)
        XCTAssertLessThan(app.buttons["gallery.open.1"].frame.minY, app.buttons["gallery.open.4"].frame.minY)
    }

    func testSavedCombinationAndHistoryKeepOrderAndCancelledDraftDoesNotApplyIt() {
        let app = launch(); startDraft(app)
        chooseOrder(app, "页数从少到多"); app.buttons["compose.apply"].tap()
        resultStatus(app, includes: "页数从少到多")
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.save-favorite"].tap()
        XCTAssertTrue(app.textFields["search.save.name"].waitForExistence(timeout: 5))
        app.buttons["search.save.confirm"].tap()
        chooseOrder(app, "标题顺序")
        XCTAssertEqual(app.descendants(matching: .any)["compose.loaded-state"].firstMatch.value as? String, "已修改")
        app.buttons["compose.cancel"].tap()
        resultStatus(app, includes: "页数从少到多")

        app.buttons["discover.search-entry"].tap(); app.buttons["compose.records"].tap()
        app.segmentedControls["compose.records-tabs"].buttons["常用组合"].tap()
        let common = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load.")).firstMatch
        XCTAssertTrue(common.waitForExistence(timeout: 5)); XCTAssertTrue(common.label.contains("页数从少到多")); common.tap()
        let loaded = app.descendants(matching: .any)["compose.loaded-state"].firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 5)); XCTAssertEqual(loaded.value as? String, "已载入")
        chooseOrder(app, "标题顺序"); app.buttons["compose.apply"].tap()
        resultStatus(app, includes: "标题顺序")
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.records"].tap()
        app.segmentedControls["compose.records-tabs"].buttons["最近搜索"].tap()
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load."))
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.element(boundBy: 0).label.contains("标题顺序"))
        XCTAssertTrue(history.element(boundBy: 1).label.contains("页数从少到多"))
        history.element(boundBy: 1).tap()
        XCTAssertTrue((app.buttons["compose.filters"].value as? String)?.contains("页数从少到多") == true)
        app.buttons["compose.cancel"].tap(); resultStatus(app, includes: "标题顺序")
    }

    func testSortSettingRemainsReachableInDarkLargeType() {
        let app = launch(["--qa-dark", "--qa-large-type"]); startDraft(app)
        chooseOrder(app, "页数从多到少")
        app.buttons["compose.filters"].tap()
        let picker = app.buttons["compose.sort-order"]
        for _ in 0..<3 { if picker.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(picker.isHittable); XCTAssertGreaterThanOrEqual(picker.frame.height, 44)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "search-sort.settings.dark-large"; shot.lifetime = .keepAlways; add(shot)
    }
}

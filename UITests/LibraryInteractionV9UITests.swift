import XCTest

final class LibraryInteractionV9UITests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchFavorites(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences"] + extraArguments
        app.launch()
        let library = app.buttons["main.tab.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 12))
        library.tap()
        let first = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 0.8)
        XCTAssertEqual(selectedCount(app), 1)
        app.buttons["favorites.select.1"].tap()
        XCTAssertTrue(app.staticTexts["已选 0 项"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["favorites.select.1"].waitForExistence(timeout: 5))
        return app
    }

    private func waitForSelection(_ expected: String, in app: XCUIApplication, timeout: TimeInterval = 3) {
        let count = app.staticTexts[expected]
        let visible = NSPredicate { _, _ in count.exists && count.isHittable }
        expectation(for: visible, evaluatedWith: count)
        waitForExpectations(timeout: timeout)
    }

    private func selectionCounter(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已选 ")).firstMatch
    }

    private func selectedCount(_ app: XCUIApplication) -> Int {
        let counter = selectionCounter(app)
        XCTAssertTrue(counter.waitForExistence(timeout: 3))
        let pieces = counter.label.split(separator: " ")
        guard pieces.count >= 2, let count = Int(pieces[1]) else {
            XCTFail("Unexpected selection counter: \(counter.label)")
            return -1
        }
        return count
    }

    private func selectionTiles(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "favorites.select.")).allElementsBoundByIndex
            .filter(\.exists)
    }

    private func assertSelectedTileCount(_ expected: Int, in app: XCUIApplication) {
        waitForSelection("已选 \(expected) 项", in: app)
        XCTAssertEqual(selectedCount(app), expected)
        let selected = selectionTiles(app).filter { ($0.value as? String) == "已选中" }.count
        XCTAssertEqual(selected, expected, "The number of selected tile states must match the live counter")
    }

    /// End-to-end XCTest timing from a real tile tap until the updated selection
    /// count is visible to accessibility. The measurement includes XCTest tap,
    /// AX query, and automatic wait overhead; it does not claim pure SwiftUI time.
    func testLibrarySelectionTapResponse() {
        let app = launchFavorites()
        let tile = app.buttons["favorites.select.1"]
        measure(metrics: [XCTClockMetric()]) {
            let wasSelected = (tile.value as? String) == "已选中"
            tile.tap()
            waitForSelection(wasSelected ? "已选 0 项" : "已选 1 项", in: app)
        }
    }

    func testBaselineRepresentativeScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences"]
        app.launchArguments += (ProcessInfo.processInfo.environment["EXVIEWER_VISUAL_ARGS"] ?? "").split(separator: " ").map(String.init)
        app.launch()
        let gallery = app.staticTexts["海岸线 · 插画与速写"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 15))
        capture(app, "build9.discovery")
        gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        capture(app, "build9.detail")
        for _ in 0..<5 { if read.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(read.isHittable); read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
        capture(app, "build9.reader")
        app.buttons["reader.settings"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        capture(app, "build9.reader-settings")
        app.navigationBars["阅读设置"].buttons["完成"].tap()
        LoadingSettingsUIHelpers.setPrefetch(3, in: app)
        XCTAssertEqual(LoadingSettingsUIHelpers.prefetchCount(in: app), 3)
        capture(app, "build9.account-loading-settings-prefetch")
        LoadingSettingsUIHelpers.returnToReader(in: app)
        XCTAssertFalse(app.buttons["reader.prefetch-menu"].exists)
        app.buttons["reader.close"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 8))
        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        capture(app, "build9.search-composer")
        let addTag = app.buttons["compose.add-tag"]
        for _ in 0..<5 { if addTag.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(addTag.isHittable); addTag.tap()
        let tagInput = app.textFields["tag.name"]
        XCTAssertTrue(tagInput.waitForExistence(timeout: 5))
        tagInput.tap(); tagInput.typeText("英语\n")
        XCTAssertTrue(app.buttons["tag.suggestion.language:english"].waitForExistence(timeout: 8))
        capture(app, "build9.tag-suggestions")
        app.buttons["tag.cancel"].tap()
        app.buttons["compose.cancel"].tap()
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(app.buttons["favorites.gallery.1"].waitForExistence(timeout: 8))
        capture(app, "build9.library-normal")
        let firstFavorite = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(firstFavorite.waitForExistence(timeout: 5))
        firstFavorite.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5))
        capture(app, "build9.library-selection")
    }

    func testLibraryFavoritesSelectionAndConfirmationStayLocalInQA() {
        let app = launchFavorites()
        let tiles = selectionTiles(app)
        XCTAssertGreaterThanOrEqual(tiles.count, 2)
        let first = app.buttons["favorites.select.1"]
        let second = app.buttons["favorites.select.2"]
        XCTAssertGreaterThanOrEqual(first.frame.width, 44)
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)
        first.tap()
        XCTAssertEqual(first.value as? String, "已选中")
        assertSelectedTileCount(1, in: app)
        second.tap()
        XCTAssertEqual(second.value as? String, "已选中")
        assertSelectedTileCount(2, in: app)

        let allLoadedCount = selectionTiles(app).count
        app.buttons["favorites.select-all"].tap()
        XCTAssertGreaterThanOrEqual(allLoadedCount, 2)
        assertSelectedTileCount(allLoadedCount, in: app)
        XCTAssertEqual(selectionTiles(app).count, allLoadedCount, "Select all should cover the actual loaded selection tiles")
        app.buttons["favorites.select-all"].tap()
        assertSelectedTileCount(0, in: app)

        first.tap(); second.tap()
        assertSelectedTileCount(2, in: app)
        app.buttons["favorites.remove"].tap()
        XCTAssertTrue(app.buttons["移除所选收藏"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        assertSelectedTileCount(2, in: app)
        app.buttons["favorites.edit"].tap()
        XCTAssertTrue(app.staticTexts["海岸线 · 插画与速写"].waitForExistence(timeout: 5), "Leaving selection mode must preserve the QA favorites")
    }

    func testLongPressEntersLocalSelectionAndPlainTapStillOpensDetail() {
        let app = launchFavorites()
        app.buttons["favorites.edit"].tap()
        let gallery = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        gallery.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["画廊详情"].exists)
        XCTAssertEqual(app.buttons["favorites.select.1"].value as? String, "已选中")
        XCTAssertFalse(app.staticTexts["画廊详情"].exists, "A long press selects the gallery without following the navigation link")

        app.buttons["favorites.select.2"].tap()
        assertSelectedTileCount(2, in: app)
        app.swipeUp()
        assertSelectedTileCount(2, in: app)

        app.swipeDown()
        app.buttons["favorites.select.1"].tap()
        assertSelectedTileCount(1, in: app)
        app.buttons["favorites.remove"].tap()
        XCTAssertTrue(app.buttons["移除所选收藏"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        assertSelectedTileCount(1, in: app)
        app.buttons["favorites.edit"].tap()

        let normalGallery = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(normalGallery.waitForExistence(timeout: 5))
        normalGallery.tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5), "A regular tap must still open the gallery")
    }

    func testLocalMultiSelectRespondsWhileDelayedCoverFixturesArePending() {
        let app = launchFavorites(extraArguments: ["--qa-library-delayed-covers"])
        let first = app.buttons["favorites.select.1"]
        let second = app.buttons["favorites.select.2"]
        XCTAssertTrue(first.label.contains("封面载入中"))
        first.tap()
        assertSelectedTileCount(1, in: app)
        second.tap()
        assertSelectedTileCount(2, in: app)
        XCTAssertTrue(first.label.contains("封面载入中"), "Selection must update while image loading is still pending")
        app.swipeUp()
        assertSelectedTileCount(2, in: app)
        app.swipeDown()
        first.tap()
        assertSelectedTileCount(1, in: app)
        app.buttons["favorites.edit"].tap()
        let normalFirst = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(normalFirst.waitForExistence(timeout: 5))
        normalFirst.press(forDuration: 0.8)
        assertSelectedTileCount(1, in: app)
        app.buttons["favorites.select.1"].tap()
        assertSelectedTileCount(0, in: app)
        XCTAssertTrue(app.buttons["favorites.select.1"].label.contains("封面载入中"))
    }
}

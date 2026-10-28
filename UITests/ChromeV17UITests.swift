import XCTest

final class ChromeV17UITests: XCTestCase {
    private func openRecords(_ app: XCUIApplication, tab: String) {
        if !app.navigationBars["记录与常用"].exists {
            let entry = app.buttons["compose.records"]
            XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        }
        XCTAssertTrue(app.navigationBars["记录与常用"].waitForExistence(timeout: 5))
        let picker = app.segmentedControls["compose.records-tabs"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.buttons[tab].tap()
    }

    private func openSearchHistory(_ app: XCUIApplication) { openRecords(app, tab: "最近搜索") }
    private func openFavorites(_ app: XCUIApplication) { openRecords(app, tab: "常用组合") }
    private func feedback(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["compose.loaded-state"].firstMatch
    }

    private func nameFavorite(_ app: XCUIApplication, _ name: String) {
        let input = app.textFields["search.save.name"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let old = input.value as? String, old != input.placeholderValue {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        input.typeText(name)
        app.buttons["search.save.confirm"].tap()
    }

    func testRecentSearchLoadsFullTagConditionsAndSavesAsCommon() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast language:english -other:city")
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load."))
        let row = rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("coast")); XCTAssertTrue(row.label.contains("language:english")); XCTAssertTrue(row.label.contains("排除"))
        XCTAssertEqual(row.label.components(separatedBy: "coast").count - 1, 1, "A record must show its condition summary only once")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.save.")).firstMatch.tap()
        nameFavorite(app, "常用海岸")
        openFavorites(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load.")).firstMatch.label.contains("常用海岸"))
        openSearchHistory(app); row.tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        XCTAssertEqual(feedback(app).value as? String, "已载入")
        app.buttons["compose.apply"].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已执行：EX · coast")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 6)); XCTAssertTrue(summary.label.contains("排除 other:city"))
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        XCTAssertEqual(rows.count, 1, "Rerunning the same full conditions must update one record")
    }

    func testCancelDraftDoesNotCreateSearchHistory() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]; XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("cancelled draft")
        app.buttons["compose.cancel"].tap()
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        XCTAssertTrue(app.staticTexts["search-history.empty"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).count, 0)
    }

    func testHistoryLoadShowsSourceAndModifiedDraftWithoutExecuting() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast language:english -other:city")
        submitHistorySearch(app, "mountain")
        let executed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已执行：EX · mountain")).firstMatch
        XCTAssertTrue(executed.waitForExistence(timeout: 5)); let previousSearch = executed.label
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load."))
        let coast = rows.matching(NSPredicate(format: "label CONTAINS %@", "coast")).firstMatch
        coast.tap()
        let state = feedback(app)
        XCTAssertTrue(state.waitForExistence(timeout: 5)); XCTAssertTrue(state.isHittable)
        XCTAssertTrue(state.label.contains("从最近搜索载入")); XCTAssertEqual(state.value as? String, "已载入")
        XCTAssertFalse(app.staticTexts["compose.loaded-title"].exists, "The source must not repeat its title and description in a large panel")
        let input = app.textFields["compose.text"]
        XCTAssertEqual(input.value as? String, "coast")
        let filters = app.buttons["compose.filters"]
        XCTAssertTrue((filters.value as? String)?.contains("包含 language:english") == true)
        XCTAssertTrue((filters.value as? String)?.contains("排除 other:city") == true)
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); input.typeText(" revised")
        XCTAssertEqual(state.value as? String, "已修改")
        XCTAssertTrue(app.navigationBars["组合搜索"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "build25.main.loaded-and-modified"; shot.lifetime = .keepAlways; add(shot)
        openSearchHistory(app); XCTAssertEqual(coast.value as? String, "已修改")
        app.buttons["BackButton"].tap()
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(app.staticTexts[previousSearch].waitForExistence(timeout: 5), "Cancelling must retain the complete prior executed search")
        app.buttons["discover.search-entry"].tap()
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "mountain")
    }

    func testFavoriteLoadStaysDistinctFromHistoryAndKeepsOriginalUntilSaved() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast language:english -other:city")
        app.buttons["discover.search-entry"].tap(); app.buttons["compose.save-favorite"].tap()
        nameFavorite(app, "海岸收藏"); openFavorites(app)
        let common = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load.")).firstMatch
        XCTAssertTrue(common.label.contains("海岸收藏")); common.tap()
        XCTAssertTrue(feedback(app).waitForExistence(timeout: 5))
        XCTAssertTrue(feedback(app).label.contains("从常用组合载入")); XCTAssertEqual(feedback(app).value as? String, "已载入")
        let input = app.textFields["compose.text"]
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); input.typeText(" changed")
        XCTAssertEqual(feedback(app).value as? String, "已修改")
        app.buttons["compose.cancel"].tap()
        app.buttons["discover.search-entry"].tap(); openFavorites(app); common.tap()
        XCTAssertEqual(input.value as? String, "coast", "Editing must not overwrite the stored combination")
        XCTAssertEqual(feedback(app).value as? String, "已载入")
        openSearchHistory(app)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch.tap()
        XCTAssertTrue(feedback(app).label.contains("从最近搜索载入"))
        openFavorites(app); XCTAssertNotEqual(common.value as? String, "已载入")
        openSearchHistory(app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch.value as? String, "已载入")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "build25.records.source-distinction"; shot.lifetime = .keepAlways; add(shot)
    }

    func testAllFavoriteCombinationsRemainReachableFromRecordsPage() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        for index in 1...4 {
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            if let old = input.value as? String, old != input.placeholderValue {
                input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
            }
            input.typeText("preset\(index)"); app.buttons["compose.save-favorite"].tap(); nameFavorite(app, "组合\(index)")
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compose.favorite.")).count, 0, "The main page must not expand saved combinations")
        openFavorites(app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load."))
        XCTAssertEqual(rows.count, 4)
        rows.matching(NSPredicate(format: "label CONTAINS %@", "组合4")).firstMatch.tap()
        XCTAssertTrue(feedback(app).waitForExistence(timeout: 5)); XCTAssertTrue(feedback(app).isHittable)
        XCTAssertTrue(feedback(app).label.contains("从常用组合载入")); XCTAssertEqual(input.value as? String, "preset4")
    }

    func testSaveCurrentDraftAsCommonWithoutExecutingAndClearOnlyHistory() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]; XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("forest language:english")
        app.buttons["compose.save-favorite"].tap(); nameFavorite(app, "常用森林")
        openSearchHistory(app); XCTAssertTrue(app.staticTexts["search-history.empty"].waitForExistence(timeout: 5))
        app.buttons["BackButton"].tap(); app.buttons["compose.apply"].tap()
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["search-history.clear"].tap(); app.buttons["清空搜索记录"].tap()
        XCTAssertTrue(app.staticTexts["search-history.empty"].waitForExistence(timeout: 5))
        openFavorites(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load.")).firstMatch.label.contains("常用森林"))
        XCTAssertFalse(app.buttons["search-history.clear"].exists, "Clear history must not become a clear-favorites action")
    }

    func testFilterPageKeepsDraftAndEditsInlineTagsWithoutExecuting() {
        continueAfterFailure = false
        let app = launch(["--qa-tags-offline"])
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]; XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("coast language:english -other:city")
        app.buttons["compose.filters"].tap()
        XCTAssertTrue(app.navigationBars["筛选条件"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["compose.apply"].isHittable, "Only the main page executes search")
        let remove = app.buttons["移除 other:city"]
        for _ in 0..<4 { if remove.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(remove.isHittable); remove.tap()
        let artist = app.textFields["compose.artist"]
        for _ in 0..<4 { if artist.isHittable { break }; app.swipeDown() }
        artist.tap(); artist.typeText("sample")
        app.buttons["BackButton"].tap()
        XCTAssertEqual(input.value as? String, "coast", "Inline tags must move into editable filter rules")
        let filters = app.buttons["compose.filters"]
        XCTAssertTrue((filters.value as? String)?.contains("作者 sample") == true)
        XCTAssertTrue((filters.value as? String)?.contains("language:english") == true)
        XCTAssertFalse((filters.value as? String)?.contains("other:city") == true)
        filters.tap(); XCTAssertEqual(artist.value as? String, "sample")
        let minimum = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "最少页数")).firstMatch
        for _ in 0..<7 { if minimum.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(minimum.isHittable); minimum.tap(); minimum.typeText("40")
        let maximum = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "最多页数")).firstMatch
        print("SEARCH25_FIELDS minimum=\(minimum.identifier),maximum=\(maximum.identifier)")
        maximum.tap(); maximum.typeText("100")
        app.buttons["BackButton"].tap()
        XCTAssertTrue((filters.value as? String)?.contains("40–100页") == true)
        app.buttons["compose.apply"].tap()
        let result = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已执行：EX · coast")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("作者 sample")); XCTAssertTrue(result.label.contains("40–100页"))
        XCTAssertFalse(result.label.contains("other:city"), "Removed inline tags must not reappear during search")
        let executed = result.label
        app.buttons["discover.search-entry"].tap(); filters.tap()
        for _ in 0..<7 { if minimum.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(minimum.value as? String, "40"); XCTAssertEqual(maximum.value as? String, "100")
        app.buttons["BackButton"].tap(); app.buttons["compose.cancel"].tap()
        XCTAssertTrue(app.staticTexts[executed].waitForExistence(timeout: 5))
    }

    func testCompactSearchPagesInDarkLargeType() {
        continueAfterFailure = false
        let app = launch(["--qa-dark", "--qa-large-type", "--qa-tags-offline"])
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast language:english -other:city")
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch.tap()
        XCTAssertTrue(feedback(app).waitForExistence(timeout: 5)); XCTAssertTrue(feedback(app).isHittable)
        XCTAssertTrue(app.buttons["compose.filters"].isHittable); XCTAssertTrue(app.buttons["compose.records"].isHittable)
        print("SEARCH25_TYPE fieldHeight=\(app.textFields["compose.text"].frame.height)")
        XCTAssertFalse(app.textFields["compose.artist"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).count, 0)
        let main = XCTAttachment(screenshot: app.screenshot()); main.name = "build25.main.dark-large"; main.lifetime = .keepAlways; add(main)
        app.buttons["compose.filters"].tap()
        XCTAssertTrue(app.navigationBars["筛选条件"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["BackButton"].isHittable)
        let filters = XCTAttachment(screenshot: app.screenshot()); filters.name = "build25.filters.dark-large"; filters.lifetime = .keepAlways; add(filters)
        app.buttons["BackButton"].tap(); openSearchHistory(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(row.isHittable)
        let records = XCTAttachment(screenshot: app.screenshot()); records.name = "build25.records.dark-large"; records.lifetime = .keepAlways; add(records)
    }

    private func submitHistorySearch(_ app: XCUIApplication, _ text: String) {
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        input.tap()
        if let old = input.value as? String, !old.isEmpty, old != input.placeholderValue {
            // Short keyword edits start with the caret at the end when tapping
            // the empty portion of the field; remove the previous draft first.
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        input.typeText(text)
        app.buttons["compose.apply"].tap()
    }

    private func historySwipe(_ app: XCUIApplication, right: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.2 : 0.8, dy: 0.62))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.8 : 0.2, dy: 0.62))
        start.press(forDuration: 0.04, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.08)
    }

    func testBrowseSwipeBackForwardAndNewSearchBranch() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast")
        XCTAssertTrue(app.staticTexts["已执行：EX · coast"].waitForExistence(timeout: 6))
        submitHistorySearch(app, "mountain")
        XCTAssertTrue(app.staticTexts["已执行：EX · mountain"].waitForExistence(timeout: 6))
        historySwipe(app, right: true)
        XCTAssertTrue(app.staticTexts["已执行：EX · coast"].waitForExistence(timeout: 6))
        historySwipe(app, right: false)
        XCTAssertTrue(app.staticTexts["已执行：EX · mountain"].waitForExistence(timeout: 6))
        historySwipe(app, right: true)
        XCTAssertTrue(app.staticTexts["已执行：EX · coast"].waitForExistence(timeout: 6))
        submitHistorySearch(app, "forest")
        XCTAssertTrue(app.staticTexts["已执行：EX · forest"].waitForExistence(timeout: 6))
        historySwipe(app, right: false)
        XCTAssertTrue(app.staticTexts["已执行：EX · forest"].exists)
    }

    func testBrowseSwipeLeavesVerticalScrollAndHeaderChipsUsable() {
        continueAfterFailure = false
        let app = launch(["--qa-feed-paging"])
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "language:english other:landscape ~artist:sample")
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已执行：")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 6))
        let original = summary.label
        let chips = app.scrollViews["discover.rule-chips"]
        XCTAssertTrue(chips.waitForExistence(timeout: 4))
        chips.swipeRight()
        XCTAssertEqual(summary.label, original)
        app.swipeUp()
        XCTAssertEqual(summary.label, original)
        let card = app.buttons["gallery.open.205"]
        for _ in 0..<8 { if card.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(card.isHittable, "Vertical feed scrolling must remain available")
        card.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.actions"].firstMatch.waitForExistence(timeout: 6))
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa"] + arguments
        app.launch()
        return app
    }

    private func openAccount(_ app: XCUIApplication) -> XCUIElement {
        let tab = app.buttons["main.tab.account"]
        XCTAssertTrue(tab.waitForExistence(timeout: 12))
        tab.tap()
        return app.segmentedControls["account.browser-site"]
    }

    func testRootTitlesAreRemovedAndSearchStillSubmits() {
        let app = launch()
        let search = app.buttons["discover.search-entry"]
        XCTAssertTrue(search.waitForExistence(timeout: 12))
        XCTAssertEqual(app.navigationBars.count, 0, "The discovery root should not retain an empty title bar")

        search.tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        input.tap()
        input.typeText("coast")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.staticTexts["已执行：EX · coast"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.navigationBars.count, 0)

        app.buttons["main.tab.library"].tap()
        XCTAssertEqual(app.navigationBars.count, 0, "The library root should not retain an empty title bar")
        app.buttons["main.tab.account"].tap()
        XCTAssertEqual(app.navigationBars.count, 0, "The account root should not retain an empty title bar")
    }

    func testSitePreferencePersistsAndUpdatesDiscoverySearch() {
        let app = launch()
        let sitePicker = openAccount(app)
        XCTAssertTrue(sitePicker.waitForExistence(timeout: 6))
        let eh = sitePicker.buttons["EH"]
        XCTAssertTrue(eh.waitForExistence(timeout: 4))
        eh.tap()
        XCTAssertTrue(eh.isSelected)

        app.terminate()
        let reopened = launch(["--qa-keep-site-preference"])
        XCTAssertTrue(reopened.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        reopened.buttons["discover.search-entry"].tap()
        let input = reopened.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        input.tap()
        input.typeText("persisted")
        reopened.buttons["compose.apply"].tap()
        XCTAssertTrue(reopened.staticTexts["已执行：EH · persisted"].waitForExistence(timeout: 8))
    }

    func testBottomBarLeavesFinalFeedItemReachable() {
        let app = launch(["--qa-feed-paging"])
        let bar = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 12))
        let last = app.staticTexts["浏览样例 · 12"]
        for _ in 0..<12 {
            if last.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(last.waitForExistence(timeout: 6))
        XCTAssertTrue(last.isHittable, "The last feed item should scroll above the compact bar")
        XCTAssertLessThanOrEqual(last.frame.maxY, bar.frame.minY + 1)
    }

    func testFloatingDiscoveryHeaderStaysUsableWhenFeedScrolls() {
        continueAfterFailure = false
        let app = launch(["--qa-feed-paging"])
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let search = app.buttons["discover.search-entry"]
        let first = app.buttons["gallery.open.1"]
        XCTAssertTrue(header.waitForExistence(timeout: 12))
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(first.frame.minY, header.frame.maxY - 1, "The initial row must start below the floating controls")
        let headerY = header.frame.minY
        let firstY = first.frame.minY

        app.swipeUp()
        XCTAssertEqual(header.frame.minY, headerY, accuracy: 1)
        if first.exists {
            XCTAssertLessThan(first.frame.minY, firstY - 40, "The feed should move independently of the header")
        }
        let scrolled = XCTAttachment(screenshot: app.screenshot())
        scrolled.name = "build17.discovery.floating-scrolled"
        scrolled.lifetime = .keepAlways
        add(scrolled)
        XCTAssertTrue(search.isHittable)

        let popular = app.buttons["热门"]
        XCTAssertTrue(popular.isHittable)
        popular.tap()
        XCTAssertTrue(popular.isSelected)
        search.tap()
        XCTAssertTrue(app.textFields["compose.text"].waitForExistence(timeout: 6))
    }

    func testFloatingFavoritesAndLocalScopeStayUsableWhenFeedScrolls() {
        continueAfterFailure = false
        let app = launch(["--qa-library-large-selection"])
        app.buttons["main.tab.library"].tap()
        let header = app.descendants(matching: .any)["favorites.header.floating"].firstMatch
        let scope = app.segmentedControls["library.scope"]
        let first = app.buttons["favorites.gallery.10000"]
        XCTAssertTrue(header.waitForExistence(timeout: 12))
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(first.frame.minY, header.frame.maxY - 1)
        let headerY = header.frame.minY
        app.swipeUp()
        XCTAssertEqual(header.frame.minY, headerY, accuracy: 1)
        XCTAssertTrue(scope.buttons["本机资料"].isHittable)
        let scrolled = XCTAttachment(screenshot: app.screenshot())
        scrolled.name = "build17.favorites.floating-scrolled"
        scrolled.lifetime = .keepAlways
        add(scrolled)

        scope.buttons["本机资料"].tap()
        let localHeader = app.descendants(matching: .any)["library.header.floating"].firstMatch
        XCTAssertTrue(localHeader.waitForExistence(timeout: 6))
        let localY = localHeader.frame.minY
        app.swipeUp()
        XCTAssertEqual(localHeader.frame.minY, localY, accuracy: 1)
        XCTAssertTrue(scope.buttons["站点收藏"].isHittable)
        scope.buttons["站点收藏"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 6))
    }

    func testReturningToScrolledFeedRestoresCardBelowFloatingHeader() {
        continueAfterFailure = false
        let app = launch(["--qa-feed-paging"])
        let header = app.descendants(matching: .any)["discover.header.floating"].firstMatch
        let card = app.buttons["gallery.open.205"]
        XCTAssertTrue(header.waitForExistence(timeout: 12))
        for _ in 0..<5 {
            if card.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(card.isHittable)
        for _ in 0..<5 {
            let distance = card.frame.minY - (header.frame.maxY + 1)
            if abs(distance) < 2 { break }
            let delta = max(-250, min(250, distance))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -delta)),
                        withVelocity: .slow, thenHoldForDuration: 0.4)
        }
        XCTAssertEqual(card.frame.minY, header.frame.maxY + 1, accuracy: 16, "Set up a user-visible card near the top before leaving the feed; the final restoration assertion remains strict")

        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        input.tap(); input.typeText("return position")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.back"].waitForExistence(timeout: 6))
        historySwipe(app, right: true)

        let restored = NSPredicate { _, _ in
            guard card.exists, card.isHittable else { return false }
            return card.frame.minY >= header.frame.maxY - 1 && card.frame.minY <= header.frame.maxY + 30
        }
        expectation(for: restored, evaluatedWith: card)
        waitForExpectations(timeout: 8)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "build17.discovery.restored-below-header"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

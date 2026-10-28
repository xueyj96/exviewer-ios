import XCTest

final class ChromeV17UITests: XCTestCase {
    private func openSearchHistory(_ app: XCUIApplication) {
        let button = app.buttons["compose.search-history"]
        for _ in 0..<4 { if button.isHittable { break }; app.swipeDown() }
        for _ in 0..<4 { if button.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(app.navigationBars["搜索记录"].waitForExistence(timeout: 5))
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
        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(app.textFields["compose.text"].waitForExistence(timeout: 5))
        openSearchHistory(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("coast")); XCTAssertTrue(row.label.contains("language:english")); XCTAssertTrue(row.label.contains("排除"))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.save.")).firstMatch.tap()
        nameFavorite(app, "常用海岸")
        XCTAssertTrue(app.navigationBars["搜索记录"].waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "coast")
        let common = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compose.favorite.")).firstMatch
        XCTAssertTrue(common.waitForExistence(timeout: 5)); XCTAssertTrue(common.label.contains("常用海岸"))
        app.buttons["compose.apply"].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已执行：EX · coast")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 6)); XCTAssertTrue(summary.label.contains("排除 other:city"))
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).count, 1, "Rerunning the same full conditions must update one record")
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
        XCTAssertTrue(executed.waitForExistence(timeout: 5))
        // Editing the keyword retains the previous tag filters. Compare the
        // complete actual search before/after cancellation, including them.
        let previousSearch = executed.label
        app.buttons["discover.search-entry"].tap()
        let records = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compose.recent."))
        let coast = records.matching(NSPredicate(format: "label CONTAINS %@", "coast")).firstMatch
        for _ in 0..<4 { if coast.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(coast.isHittable)
        coast.tap()

        let state = app.staticTexts["compose.loaded-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(state.isHittable, "Loading a row must scroll back to visible source feedback")
        XCTAssertEqual(state.label, "已载入")
        XCTAssertEqual(app.staticTexts["compose.loaded-title"].label, "coast")
        XCTAssertEqual(app.staticTexts["compose.loaded-hint"].label, "条件已载入，尚未搜索。")
        XCTAssertTrue(app.staticTexts["来自最近搜索"].exists)
        let input = app.textFields["compose.text"]
        XCTAssertEqual(input.value as? String, "coast")
        let summary = app.staticTexts["compose.current-summary"]
        XCTAssertTrue(summary.label.contains("包含 language:english"))
        XCTAssertTrue(summary.label.contains("排除 other:city"))
        XCTAssertEqual(coast.value as? String, "已载入")

        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        input.typeText(" revised")
        XCTAssertEqual(state.label, "已修改")
        XCTAssertEqual(coast.value as? String, "已修改")
        XCTAssertTrue(app.navigationBars["组合搜索"].exists, "Loading or editing a record must not execute it")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "build24.history.loaded-and-modified"; shot.lifetime = .keepAlways; add(shot)

        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(app.staticTexts[previousSearch].waitForExistence(timeout: 5), "Cancelling a loaded draft must keep the complete previous executed search")
        app.buttons["discover.search-entry"].tap()
        XCTAssertEqual(app.textFields["compose.text"].value as? String, "mountain")
    }

    func testFavoriteLoadStaysDistinctFromHistoryAndKeepsOriginalUntilSaved() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        submitHistorySearch(app, "coast language:english -other:city")
        app.buttons["discover.search-entry"].tap()
        app.buttons["compose.save-favorite"].tap()
        nameFavorite(app, "海岸收藏")
        let common = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compose.favorite.")).firstMatch
        XCTAssertTrue(common.waitForExistence(timeout: 5)); common.tap()
        let state = app.staticTexts["compose.loaded-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["来自常用组合"].exists)
        XCTAssertEqual(app.staticTexts["compose.loaded-title"].label, "海岸收藏")
        XCTAssertEqual(common.value as? String, "已载入")
        let input = app.textFields["compose.text"]
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap(); input.typeText(" changed")
        XCTAssertEqual(state.label, "已修改")
        app.buttons["compose.cancel"].tap()

        app.buttons["discover.search-entry"].tap(); common.tap()
        XCTAssertEqual(input.value as? String, "coast", "Editing a loaded favorite must not silently overwrite the saved combination")
        XCTAssertEqual(state.label, "已载入")
        openSearchHistory(app)
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        XCTAssertTrue(app.staticTexts["来自最近搜索"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["compose.loaded-title"].label, "coast")
        XCTAssertNotEqual(common.value as? String, "已载入", "Only the actual source row should stay selected, even when history and favorite have the same query")
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compose.recent.")).firstMatch
        XCTAssertEqual(recent.value as? String, "已载入")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "build24.history.source-distinction"; shot.lifetime = .keepAlways; add(shot)
    }

    func testAllFavoriteCombinationsRemainReachableFromVerticalPreview() {
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
            input.typeText("preset\(index)")
            app.buttons["compose.save-favorite"].tap()
            nameFavorite(app, "组合\(index)")
        }
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compose.favorite."))
        XCTAssertEqual(preview.count, 3, "The preview should stay compact while all saved combinations remain reachable")
        let all = app.buttons["compose.search-favorites"]
        for _ in 0..<4 { if all.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(all.isHittable); all.tap()
        XCTAssertTrue(app.navigationBars["常用组合"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-favorites.load."))
        XCTAssertEqual(rows.count, 4)
        rows.matching(NSPredicate(format: "label CONTAINS %@", "组合4")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["compose.loaded-state"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["compose.loaded-state"].isHittable)
        XCTAssertEqual(app.staticTexts["compose.loaded-title"].label, "组合4")
        XCTAssertEqual(input.value as? String, "preset4")
    }

    func testSaveCurrentDraftAsCommonWithoutExecutingAndClearOnlyHistory() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        let input = app.textFields["compose.text"]; XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("forest language:english")
        app.buttons["compose.save-favorite"].tap()
        nameFavorite(app, "常用森林")
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        openSearchHistory(app)
        XCTAssertTrue(app.staticTexts["search-history.empty"].waitForExistence(timeout: 5))
        app.buttons["search-history.close"].tap()
        app.buttons["compose.apply"].tap()
        app.buttons["discover.search-entry"].tap(); openSearchHistory(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-history.load.")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["search-history.clear"].tap(); app.buttons["清空搜索记录"].tap()
        XCTAssertTrue(app.staticTexts["search-history.empty"].waitForExistence(timeout: 5))
        app.buttons["search-history.close"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compose.favorite.")).firstMatch.label.contains("常用森林"))
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

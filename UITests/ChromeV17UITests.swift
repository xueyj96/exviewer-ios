import XCTest

final class ChromeV17UITests: XCTestCase {
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
        let back = app.buttons["discover.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 6))
        back.tap()

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

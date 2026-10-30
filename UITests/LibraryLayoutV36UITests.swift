import XCTest

final class LibraryLayoutV36UITests: XCTestCase {
    private func openLibrary(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-library-large-selection"] + arguments
        app.launch()
        let tab = app.buttons["main.tab.library"]
        XCTAssertTrue(tab.waitForExistence(timeout: 12)); tab.tap()
        if app.buttons["library.scope.menu"].exists {
            app.buttons["library.scope.menu"].tap(); app.buttons["library.scope.1"].tap()
        } else { app.segmentedControls["library.scope"].buttons["站点收藏"].tap() }
        XCTAssertTrue(app.buttons["favorites.gallery.10000"].waitForExistence(timeout: 12))
        return app
    }

    private func selectFirst(_ app: XCUIApplication) {
        app.buttons["favorites.gallery.10000"].press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5))
        let tabs = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: tabs)
        waitForExpectations(timeout: 5)
    }

    private func assertActions(_ app: XCUIApplication) {
        let bar = app.descendants(matching: .any)["favorites.actions"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        for name in ["favorites.select-all", "favorites.move", "favorites.remove"] {
            let button = app.buttons[name]
            XCTAssertTrue(button.exists && button.isHittable && button.isEnabled, name)
            XCTAssertGreaterThanOrEqual(button.frame.width + 0.000_001, 44, name)
            XCTAssertGreaterThanOrEqual(button.frame.height + 0.000_001, 44, name)
            XCTAssertGreaterThanOrEqual(button.frame.minX, 8, name)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 8, name)
            XCTAssertLessThanOrEqual(button.frame.maxY, app.frame.maxY - 10, name)
        }
        XCTAssertFalse(app.buttons["main.tab.library"].exists)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testBulkRemoveAndMoveAreReachableAndMainTabsRestoreAfterCompletion() {
        let app = openLibrary()
        selectFirst(app); assertActions(app)
        capture(app, "library36.bulk-actions")
        app.buttons["favorites.remove"].tap()
        XCTAssertTrue(app.buttons["移除所选收藏"].waitForExistence(timeout: 4))
        app.buttons["取消"].tap()
        assertActions(app)
        app.buttons["favorites.move"].tap()
        let destination = app.buttons["favorites.move-to.0"]
        XCTAssertTrue(destination.waitForExistence(timeout: 4)); destination.tap()
        XCTAssertTrue(app.buttons["确认移动"].waitForExistence(timeout: 4))
        app.buttons["取消"].tap()
        app.buttons["favorites.remove"].tap(); app.buttons["移除所选收藏"].tap()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["favorites.remove"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "未修改站点收藏")).firstMatch.waitForExistence(timeout: 5))
    }

    func testLargeTypeBulkActionsRemainSingleRowAndExitRestoresNavigation() {
        let app = openLibrary(["--qa-large-type", "--qa-dark"])
        selectFirst(app); assertActions(app)
        let all = app.buttons["favorites.select-all"], remove = app.buttons["favorites.remove"]
        XCTAssertEqual(all.frame.midY, remove.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(remove.frame.height, 48.000_001)
        capture(app, "library36.large-type-actions")
        remove.tap()
        XCTAssertTrue(app.buttons["移除所选收藏"].waitForExistence(timeout: 4)); app.buttons["取消"].tap()
        app.buttons["favorites.edit"].tap()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 5))
    }

    func testLateCoverRatiosDoNotMoveExistingCardsBetweenColumns() {
        let app = openLibrary(["--qa-grid-aspect-delay"])
        let ids = [10000, 10001, 10002, 10003]
        let initial = Dictionary(uniqueKeysWithValues: ids.map { id -> (Int, CGRect) in
            let card = app.buttons["favorites.gallery.\(id)"]
            XCTAssertTrue(card.waitForExistence(timeout: 4))
            return (id, card.frame)
        })
        // The landscape fixture starts at the unknown-cover fallback ratio.
        // Observe its actual layout change instead of an accessibility child
        // which NavigationLink may merge into the card itself.
        let landscape = app.buttons["favorites.gallery.10001"]
        expectation(for: NSPredicate { _, _ in
            landscape.frame.height < initial[10001]!.height - 20
        }, evaluatedWith: landscape)
        waitForExpectations(timeout: 20)
        for id in ids {
            XCTAssertEqual(app.buttons["favorites.gallery.\(id)"].frame.midX, initial[id]!.midX, accuracy: 1, "Cover resolution must not move card \(id) to the other column")
        }
        capture(app, "library36.stable-columns-after-covers")
    }

    func testOfflineReaderDoesNotStackItsControlsOverMainTabs() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-offline-layout"]
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12)); app.buttons["main.tab.library"].tap()
        app.segmentedControls["library.scope"].buttons["下载"].tap()
        let read = app.buttons["离线阅读"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 5)); read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 8))
        let tabs = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: tabs)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["reader.settings"].isHittable)
        capture(app, "library36.offline-reader")
        app.buttons["reader.close"].tap()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 5))
    }
}

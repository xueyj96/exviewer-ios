import XCTest

final class LibraryV10UITests: XCTestCase {
    private func launchLargeLibrary(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-library-large-selection"] + extraArguments
        app.launch()
        app.buttons["main.tab.library"].tap()
        let normal = app.buttons["favorites.gallery.10000"]
        XCTAssertTrue(normal.waitForExistence(timeout: 12))
        normal.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5))
        app.buttons["favorites.select.10000"].tap()
        XCTAssertTrue(app.staticTexts["已选 0 项"].waitForExistence(timeout: 5))
        let workload = app.descendants(matching: .any)["library.qa.workload"].firstMatch
        XCTAssertEqual(workload.value as? String, "galleries=600;blocked=250")
        return app
    }

    private func waitForCount(_ count: Int, in app: XCUIApplication) {
        let expected = app.staticTexts["已选 \(count) 项"]
        XCTAssertTrue(expected.waitForExistence(timeout: 5), "Expected visible selection count \(count)")
    }

    func testLargeLoadedSetSelectsAndClearsWithoutMutatingFavorites() {
        let app = launchLargeLibrary()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "favorites.select.")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        waitForCount(1, in: app)

        app.buttons["favorites.select-all"].tap()
        waitForCount(600, in: app)
        XCTAssertTrue(first.exists)
        app.swipeUp()
        waitForCount(600, in: app)
        app.buttons["favorites.select-all"].tap()
        waitForCount(0, in: app)
        XCTAssertTrue(app.staticTexts["中性样例 001 · 海岸线 · 插画与速写"].exists)
        XCTAssertTrue(app.buttons["favorites.edit"].exists)
    }

    /// End-to-end XCTest duration includes tap delivery, AX lookup and XCTest
    /// waiting. It is a reproducible UI check, not an isolated SwiftUI render time.
    func testLargeLibrarySelectionTapResponse() {
        let app = launchLargeLibrary()
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "favorites.select.")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        measure(metrics: [XCTClockMetric()]) {
            tile.tap()
            waitForCount(1, in: app)
            tile.tap()
            waitForCount(0, in: app)
        }
    }

    func testSelectionUpdatesWhileLargeFixtureCoversArePending() {
        let app = launchLargeLibrary(extraArguments: ["--qa-library-delayed-covers"])
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "favorites.select.")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        first.tap()
        waitForCount(1, in: app)
        XCTAssertTrue(first.label.contains("封面载入中"))
        app.buttons["favorites.select-all"].tap()
        waitForCount(600, in: app)
        app.buttons["favorites.select-all"].tap()
        waitForCount(0, in: app)
    }

    func testUnknownFavoriteResponseStopsProcessingAndOffersManualVerification() {
        let app = launchLargeLibrary(extraArguments: ["--qa-favorites-unknown-response"])

        let first = app.buttons["favorites.select.10000"]
        let second = app.buttons["favorites.select.10001"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap(); second.tap()
        waitForCount(2, in: app)
        app.buttons["favorites.remove"].tap()
        let confirmation = app.buttons["移除所选收藏"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()

        let unknown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "本批 2 项可能已生效，结果待核实")).firstMatch
        XCTAssertTrue(unknown.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["正在处理 2 项…"].exists, "The working indicator must end when the mutation fails")
        waitForCount(2, in: app)
        XCTAssertTrue(app.buttons["favorites.verify-refresh"].exists)
        let attempts = app.staticTexts["favorites.qa-attempt-count"]
        XCTAssertTrue(attempts.label.contains("1"), "The QA failure path must attempt one simulated request")

        let failureShot = XCTAttachment(screenshot: app.screenshot())
        failureShot.name = "build10.favorites.unknown-stopped"; failureShot.lifetime = .keepAlways; add(failureShot)
        app.buttons["favorites.verify-refresh"].tap()
        waitForCount(2, in: app)
        XCTAssertFalse(app.buttons["favorites.verify-refresh"].exists)
        XCTAssertTrue(attempts.label.contains("1"), "Manual refresh must not automatically resubmit the mutation")
    }
}

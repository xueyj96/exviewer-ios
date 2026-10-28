import XCTest

final class ReaderConcurrencyV15UITests: XCTestCase {
    private func openReader(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-reader-many", "--qa-reader-transition"] + arguments
        app.launch()
        let gallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 12))
        gallery.tap()
        XCTAssertTrue(app.buttons["在线阅读"].waitForExistence(timeout: 8))
        app.buttons["在线阅读"].tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.descendants(matching: .any)["reader.cache.qa"].waitForExistence(timeout: 8))
        return app
    }

    private func waitForCache(_ fragment: String, app: XCUIApplication, timeout: TimeInterval = 20) {
        let cache = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        let condition = NSPredicate { _, _ in (cache.value as? String)?.contains(fragment) == true }
        expectation(for: condition, evaluatedWith: cache)
        waitForExpectations(timeout: timeout)
    }

    private func cachedPages(_ diagnostic: String) -> Set<Int> {
        guard let field = diagnostic.components(separatedBy: ";").first(where: { $0.hasPrefix("files=") }) else { return [] }
        return Set(field.dropFirst("files=".count).split(separator: ",").compactMap { Int($0) })
    }

    func testMigratedDefaultsAndAccountLoadingSettingsChoices() {
        let app = openReader()
        XCTAssertFalse(app.buttons["reader.prefetch-menu"].exists, "Prefetch controls now live under Account settings")
        waitForCache("prefetch=32;", app: app)
        waitForCache("concurrency=16;", app: app)

        LoadingSettingsUIHelpers.open(in: app)
        let concurrency = app.segmentedControls["account.loading.concurrency"]
        XCTAssertEqual(concurrency.value as? String, "16")
        for value in [2, 4, 8, 16] {
            let option = concurrency.buttons["\(value)"]
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            option.tap()
            XCTAssertEqual(concurrency.value as? String, "\(value)", "Concurrency option \(value) should be selectable")
        }
        LoadingSettingsUIHelpers.setPrefetch(128, in: app)
        XCTAssertEqual(LoadingSettingsUIHelpers.prefetchCount(in: app), 128)
        LoadingSettingsUIHelpers.returnToReader(in: app)

        XCTAssertFalse(app.buttons["reader.prefetch-menu"].exists, "The reader toolbar no longer contains prefetch controls")
        waitForCache("prefetch=128;", app: app)
        waitForCache("concurrency=16;", app: app)
    }

    func testSlowQAReaderCapsAtSixteenInflightWithThirtyTwoPrefetch() {
        let app = openReader([
            "--qa-reader-large-window",
            "--qa-transfer-ms=8000",
            "--qa-prefetch=32",
            "--qa-concurrency=16"
        ])
        waitForCache("prefetch=32;", app: app)
        waitForCache("concurrency=16;", app: app)
        waitForCache("tasks=16;", app: app, timeout: 25)
        XCTAssertTrue(app.buttons["reader.page"].label.hasSuffix("/ 40"))
        let cache = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in
            self.cachedPages(cache.value as? String ?? "").contains(33)
        }, evaluatedWith: cache)
        waitForExpectations(timeout: 30)
        let loaded = cachedPages(cache.value as? String ?? "")
        XCTAssertTrue((1...33).allSatisfy { loaded.contains($0) }, "The configured window should include current page 1 and the next 32 pages")
        XCTAssertFalse(loaded.contains(34), "The next page beyond the 32-page forward window should not be prefetched")
    }

    func testZeroPrefetchDoesNotStartBackgroundRequests() {
        let app = openReader(["--qa-prefetch=0", "--qa-concurrency=16"])
        waitForCache("prefetch=0;", app: app)
        waitForCache("concurrency=16;", app: app)
        waitForCache("files=1;tasks=0;", app: app)
        let diagnostic = app.descendants(matching: .any)["reader.cache.qa"].firstMatch.value as? String ?? ""
        XCTAssertTrue(diagnostic.contains("files=1;"), "With prefetch off, only the current page should be requested")
    }
}

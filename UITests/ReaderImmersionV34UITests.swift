import XCTest

final class ReaderImmersionV34UITests: XCTestCase {
    private func openReader(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let prefetch = arguments.contains(where: { $0.hasPrefix("--qa-prefetch=") }) ? [] : ["--qa-prefetch=2"]
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-reader-many", "--qa-reader-transition"] + prefetch + arguments
        app.launch()
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 12)); gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8)); read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["reader.previous"].exists)
        XCTAssertFalse(app.buttons["reader.next"].exists)
        return app
    }

    private func coordinate(_ app: XCUIApplication, x: CGFloat = 0.5, y: CGFloat = 0.5) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .init(dx: x, dy: y))
    }

    private func page(_ number: Int, in app: XCUIApplication) {
        let state = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in (state.value as? String ?? "").hasPrefix("current=\(number);") }, evaluatedWith: state)
        waitForExpectations(timeout: 4)
    }

    private func chrome(_ shown: Bool, in app: XCUIApplication) {
        let header = app.descendants(matching: .any)["reader.header"].firstMatch
        let controls = app.descendants(matching: .any)["reader.controls.compact"].firstMatch
        expectation(for: NSPredicate { _, _ in header.exists == shown && controls.exists == shown }, evaluatedWith: app)
        waitForExpectations(timeout: 4)
        let systemChrome = app.descendants(matching: .any)["reader.system.chrome.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in (systemChrome.value as? String ?? "").hasPrefix("hidden=\(!shown);") }, evaluatedWith: systemChrome)
        waitForExpectations(timeout: 4)
        print("READER34_SYSTEM_CHROME shown=\(shown);actual=\(systemChrome.value ?? "unavailable")")
    }

    private func detailsAndReturn(_ app: XCUIApplication) {
        coordinate(app).doubleTap()
        XCTAssertTrue(app.navigationBars["画廊详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["detail.site-favorite"].exists)
        let read = app.buttons["返回阅读"]
        XCTAssertTrue(read.exists); read.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.single.canvas"].firstMatch.waitForExistence(timeout: 4))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testLoadedImageDoubleTapDetailsAndLongPressImmersionPreservePageAndZoom() {
        let app = openReader()
        let image = app.otherElements.matching(identifier: "media.static").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 6))
        coordinate(app).tap()
        page(1, in: app)
        XCTAssertFalse(app.navigationBars["阅读设置"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["reader.details"].firstMatch.exists)
        detailsAndReturn(app)
        page(1, in: app)
        capture(app, "reader34.no-arrows")

        coordinate(app).press(forDuration: 0.7)
        chrome(false, in: app)
        page(1, in: app)
        capture(app, "reader34.immersive")
        coordinate(app, x: 0.82, y: 0.36).tap()
        page(2, in: app)
        coordinate(app, x: 0.28).press(forDuration: 0.03,
            thenDragTo: coordinate(app, x: 0.72), withVelocity: .fast, thenHoldForDuration: 0.02)
        page(1, in: app)
        chrome(false, in: app)
        coordinate(app).press(forDuration: 0.7)
        chrome(true, in: app)
        page(1, in: app)

        coordinate(app, x: 0.18, y: 0.38).doubleTap()
        expectation(for: NSPredicate { _, _ in (image.value as? String ?? "").contains("zoomed") }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        page(1, in: app)
        XCTAssertFalse(app.descendants(matching: .any)["reader.details"].firstMatch.exists)
        coordinate(app, x: 0.82, y: 0.38).tap()
        page(1, in: app)
        coordinate(app, x: 0.18, y: 0.38).doubleTap()
        expectation(for: NSPredicate { _, _ in (image.value as? String ?? "").contains("fit") }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        app.buttons["reader.settings"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 4))
        app.buttons["完成"].tap()
        page(1, in: app)
    }

    func testMissingMetadataDoubleTapLongPressAndRetryRemainIndependent() {
        let app = openReader(["--qa-prefetch=0", "--qa-reader-paging", "--qa-reader-metadata-stall", "--qa-transfer-ms=15000"])
        coordinate(app, x: 0.82, y: 0.36).tap(); page(2, in: app)
        coordinate(app, x: 0.82, y: 0.64).tap(); page(3, in: app)
        let retry = app.buttons["reader.page.retry.3"]
        XCTAssertTrue(retry.waitForExistence(timeout: 4))
        retry.tap()
        page(3, in: app)
        chrome(true, in: app)
        XCTAssertFalse(app.descendants(matching: .any)["reader.details"].firstMatch.exists)
        detailsAndReturn(app)
        page(3, in: app)
        coordinate(app, y: 0.45).press(forDuration: 0.7)
        chrome(false, in: app)
        page(3, in: app)
        capture(app, "reader34.loading-immersive")
        coordinate(app, x: 0.82, y: 0.36).tap(); page(4, in: app)
        coordinate(app, x: 0.18, y: 0.64).tap(); page(3, in: app)
        coordinate(app, y: 0.45).press(forDuration: 0.7)
        chrome(true, in: app)
        app.buttons["reader.direction"].tap(); app.buttons["从上到下 ↓"].tap()
        coordinate(app, x: 0.64, y: 0.82).tap(); page(4, in: app)
        coordinate(app, x: 0.36, y: 0.18).tap(); page(3, in: app)
        XCTAssertFalse(app.buttons["reader.next"].exists)
    }

    func testContinuousReaderCanHideAndRestoreChromeWithoutChangingItsPage() {
        let app = openReader()
        app.buttons["reader.mode"].tap(); app.buttons["连续模式"].tap()
        page(1, in: app)
        coordinate(app).press(forDuration: 0.7)
        chrome(false, in: app)
        page(1, in: app)
        capture(app, "reader34.continuous-immersive")
        coordinate(app).press(forDuration: 0.7)
        chrome(true, in: app)
        page(1, in: app)
        XCTAssertFalse(app.buttons["reader.next"].exists)
        XCTAssertFalse(app.buttons["reader.previous"].exists)
    }
}

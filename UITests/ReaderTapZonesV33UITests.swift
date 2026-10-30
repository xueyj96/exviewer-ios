import XCTest

final class ReaderTapZonesV33UITests: XCTestCase {
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
        return app
    }

    private func page(_ value: Int, in app: XCUIApplication) {
        let element = app.buttons["reader.page"]
        expectation(for: NSPredicate { _, _ in element.label == "\(value) / 12" }, evaluatedWith: element)
        waitForExpectations(timeout: 4)
    }

    private func tap(_ app: XCUIApplication, x: CGFloat, y: CGFloat) {
        let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch
        XCTAssertTrue(canvas.exists)
        print("READER33_TAP canvasAX=\(canvas.frame);screen=\(app.frame);point=\(x),\(y);before=\(app.buttons["reader.page"].label)")
        // The accessibility container includes offscreen adjacent canvases;
        // taps must target the visible screen, as a reader's finger does.
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
        print("READER33_TAP after=\(app.buttons["reader.page"].label)")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testImageTapZonesFollowAllDirectionsAndPreserveZoomAndBounds() {
        let app = openReader()
        let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch
        let directions: [(String, Bool, Bool)] = [
            ("从左到右 →", true, false), ("从右到左 ←", true, true),
            ("从上到下 ↓", false, false), ("从下到上 ↑", false, true)
        ]
        for (title, horizontal, reverse) in directions {
            app.buttons["reader.direction"].tap(); app.buttons[title].tap()
            let forward: CGFloat = reverse ? 0.18 : 0.82
            let backward: CGFloat = 1 - forward
            tap(app, x: horizontal ? backward : 0.36, y: horizontal ? 0.36 : backward)
            page(1, in: app)
            tap(app, x: horizontal ? forward : 0.64, y: horizontal ? 0.64 : forward)
            page(2, in: app)
            XCTAssertFalse(app.navigationBars["阅读设置"].exists)
            tap(app, x: horizontal ? backward : 0.36, y: horizontal ? 0.36 : backward)
            page(1, in: app)
        }

        let header = app.descendants(matching: .any)["reader.header"].firstMatch
        XCTAssertTrue(header.exists)
        XCTAssertLessThanOrEqual(header.frame.height, 44.000_001)
        XCTAssertTrue(app.buttons["reader.close"].isHittable)
        XCTAssertLessThan(canvas.frame.minY, header.frame.minY, "Image viewport should extend behind the top controls")
        XCTAssertFalse(app.navigationBars["海岸线 · 插画与速写"].exists, "Reader uses floating controls without a native navigation background")
        capture(app, "reader33.transparent-header")

        app.buttons["reader.direction"].tap(); app.buttons["从左到右 →"].tap()
        let image = app.otherElements.matching(identifier: "media.static").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        image.doubleTap()
        expectation(for: NSPredicate { _, _ in (image.value as? String ?? "").contains("zoomed") }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        capture(app, "reader33.image-behind-header")
        tap(app, x: 0.82, y: 0.36)
        page(1, in: app)
        XCTAssertFalse(app.navigationBars["阅读设置"].exists)
        image.doubleTap()
        expectation(for: NSPredicate { _, _ in (image.value as? String ?? "").contains("fit") }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        app.sliders["reader.progress"].adjust(toNormalizedSliderPosition: 1)
        page(12, in: app)
        tap(app, x: 0.82, y: 0.36)
        page(12, in: app)
        tap(app, x: 0.5, y: 0.5)
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 4))
        capture(app, "reader33.center-settings")
        app.buttons["完成"].tap()
        page(12, in: app)
    }

    func testLoadingAndMissingMetadataTapsKeepWorkingWithoutTriggeringRetryOrSettings() {
        let app = openReader(["--qa-prefetch=0", "--qa-reader-paging", "--qa-reader-metadata-stall", "--qa-transfer-ms=15000"])
        tap(app, x: 0.82, y: 0.36)
        page(2, in: app)
        XCTAssertTrue(app.otherElements["reader.page.loading.2"].firstMatch.waitForExistence(timeout: 3))
        tap(app, x: 0.82, y: 0.64)
        page(3, in: app)
        let retry = app.buttons["reader.page.retry.3"]
        XCTAssertTrue(retry.waitForExistence(timeout: 4))
        retry.tap()
        page(3, in: app)
        XCTAssertFalse(app.navigationBars["阅读设置"].exists, "Retry should not also open reader settings")
        let diagnostic = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in (diagnostic.value as? String ?? "").contains("metadataCalls=2;") }, evaluatedWith: diagnostic)
        waitForExpectations(timeout: 4)
        tap(app, x: 0.82, y: 0.36)
        page(4, in: app)
        tap(app, x: 0.18, y: 0.64)
        page(3, in: app)
        app.buttons["reader.direction"].tap(); app.buttons["从上到下 ↓"].tap()
        tap(app, x: 0.64, y: 0.82)
        page(4, in: app)
        tap(app, x: 0.36, y: 0.18)
        page(3, in: app)
        tap(app, x: 0.64, y: 0.5)
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 4))
        capture(app, "reader33.loading-page-settings")
    }
}

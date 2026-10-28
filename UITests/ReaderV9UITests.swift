import XCTest

final class ReaderV9UITests: XCTestCase {
    private func launchReader(_ arguments: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa"] + (reset ? ["--qa-reset-reader-preferences"] : []) + arguments
        app.launch()
        let gallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 12)); gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8)); read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
        return app
    }
    private func page(_ label: String, _ app: XCUIApplication, timeout: TimeInterval = 8) {
        let control = app.buttons["reader.page"]
        expectation(for: NSPredicate { _, _ in control.label == label }, evaluatedWith: control)
        waitForExpectations(timeout: timeout)
        XCTAssertEqual(control.label, label)
    }
    private func settings(_ app: XCUIApplication, single: Bool? = nil) {
        app.buttons["reader.settings"].tap()
        let picker = app.segmentedControls["reader.settings.mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        if let single { picker.buttons[single ? "单页模式" : "连续模式"].tap() }
    }
    private func done(_ app: XCUIApplication) { app.navigationBars["阅读设置"].buttons["完成"].tap() }
    private func direction(_ title: String, _ app: XCUIApplication) {
        app.buttons["reader.direction"].tap(); app.buttons[title].tap()
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
    }
    private func cache(_ needle: String, _ app: XCUIApplication) {
        let state = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in (state.value as? String)?.contains(needle) == true }, evaluatedWith: state)
        waitForExpectations(timeout: 8)
    }
    func testSingleTurnsRapidReverseCancelAndJumpKeepImageIdentity() {
        let app = launchReader(["--qa-reader-many"])
        settings(app, single: true); done(app)
        for (menu, name) in [("从左到右 →", "从左到右"), ("从右到左 ←", "从右到左"), ("从上到下 ↓", "从上到下"), ("从下到上 ↑", "从下到上")] {
            direction(menu, app)
            app.buttons["下一页，\(name)"].tap(); page("2 / 12", app)
            let images = app.otherElements.matching(identifier: "media.static")
            let center = CGPoint(x: app.frame.midX, y: app.frame.midY)
            expectation(for: NSPredicate { _, _ in images.allElementsBoundByIndex.contains { $0.frame.contains(center) && ($0.value as? String)?.contains("reader-v8-page-2.png") == true } }, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            let image = images.allElementsBoundByIndex.first { $0.frame.contains(center) && ($0.value as? String)?.contains("reader-v8-page-2.png") == true } ?? images.firstMatch
            XCTAssertTrue((image.value as? String)?.contains("reader-v8-page-2.png") == true,
                          "Actual media values: \(app.otherElements.matching(identifier: "media.static").allElementsBoundByIndex.map { "value=\($0.value ?? "nil"), hittable=\($0.isHittable), frame=\($0.frame)" })")
            capture(app, "build9.single.\(name)")
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertEqual(app.buttons["reader.page"].label, "2 / 12", "A cancelled small drag keeps the current page")
            app.buttons["上一页，\(name)"].tap(); page("1 / 12", app)
        }
        direction("从左到右 →", app)
        app.buttons["下一页，从左到右"].tap(withNumberOfTaps: 3, numberOfTouches: 1)
        page("4 / 12", app)
        app.buttons["上一页，从左到右"].tap(withNumberOfTaps: 2, numberOfTouches: 1)
        page("2 / 12", app)
        app.sliders["reader.progress"].adjust(toNormalizedSliderPosition: 1)
        page("12 / 12", app)
        let center = CGPoint(x: app.frame.midX, y: app.frame.midY)
        XCTAssertTrue((app.otherElements.matching(identifier: "media.static").allElementsBoundByIndex.first { $0.frame.contains(center) }?.value as? String)?.contains("reader-v8-page-12.png") == true)
        capture(app, "build9.single.latest-jump")
    }

    func testPrefetchZeroMaximumAndPersistenceThroughRealSettings() {
        let app = launchReader(["--qa-reader-many"])
        settings(app); done(app)
        XCTAssertFalse(app.buttons["reader.prefetch-menu"].exists)
        LoadingSettingsUIHelpers.setPrefetch(0, in: app)
        LoadingSettingsUIHelpers.returnToReader(in: app)
        cache("prefetch=0;files=1;", app)
        XCTAssertTrue(app.otherElements["media.animated"].firstMatch.waitForExistence(timeout: 5))
        LoadingSettingsUIHelpers.setPrefetch(128, in: app)
        LoadingSettingsUIHelpers.returnToReader(in: app)
        cache("prefetch=128;", app)
        cache("files=1,2,3,4,5,6,7,8,9,10,11,12;", app)
        app.terminate()
        let reopened = launchReader(["--qa-reader-many"], reset: false)
        XCTAssertFalse(reopened.buttons["reader.prefetch-menu"].exists)
        cache("prefetch=128;", reopened)
        LoadingSettingsUIHelpers.open(in: reopened)
        XCTAssertEqual(LoadingSettingsUIHelpers.prefetchCount(in: reopened), 128)
        LoadingSettingsUIHelpers.setPrefetch(0, in: reopened)
        LoadingSettingsUIHelpers.returnToReader(in: reopened)
        cache("prefetch=0;files=1;", reopened)
    }

    func testLongImageInteriorDoesNotSnapBackAndZoomRemainsIndependent() {
        let app = launchReader(["--qa-reader-long-page"])
        direction("从上到下 ↓", app)
        app.buttons["下一页，从上到下"].tap(); page("2 / 3", app)
        let frames = app.descendants(matching: .any).matching(identifier: "reader.page.frame")
        let long = frames.allElementsBoundByIndex.first { ($0.value as? String) == "page 2" }
        XCTAssertNotNil(long)
        guard let long else { return }
        let before = long.frame.minY
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.43))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 3")
        XCTAssertLessThan(long.frame.minY, before - 40, "Stopping inside a long image must preserve its reading offset")
        capture(app, "build9.long-page.interior")
        let image = app.otherElements.matching(identifier: "media.static").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(image); image?.doubleTap()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue((image?.value as? String)?.contains("zoomed") == true)
        image?.swipeUp()
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 3")
    }

    func testPendingMetadataAppendCannotCancelANewerUnloadedJump() {
        let app = launchReader(["--qa-reader-paging", "--qa-reader-delay"])
        direction("从下到上 ↑", app)
        app.swipeDown(); page("2 / 3", app)
        app.buttons["reader.load-more"].tap()
        app.sliders["reader.progress"].adjust(toNormalizedSliderPosition: 1)
        page("3 / 3", app, timeout: 12)
    }

    func testReducedMotionDoesNotCreateSpatialPageTransition() {
        let app = launchReader(["--qa-reduce-motion"])
        settings(app, single: true); done(app)
        app.buttons["下一页，从左到右"].tap(); page("2 / 3", app)
        let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch
        XCTAssertTrue((canvas.value as? String)?.contains("settled; reduced=true") == true)
        capture(app, "build9.single.reduce-motion")
    }
}

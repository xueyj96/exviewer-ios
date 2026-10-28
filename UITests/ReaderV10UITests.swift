import XCTest

final class ReaderV10UITests: XCTestCase {
    private func launchReader(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reader-many"] + (reset ? ["--qa-reset-reader-preferences"] : [])
        app.launch()
        let gallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 12)); gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8)); read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
        app.buttons["reader.mode"].tap(); app.buttons["单页模式"].tap()
        return app
    }
    private func page(_ value: String, in app: XCUIApplication) {
        let control = app.buttons["reader.page"]
        expectation(for: NSPredicate { _, _ in control.label == value }, evaluatedWith: control)
        waitForExpectations(timeout: 8)
    }
    private func cache(_ value: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in (element.value as? String)?.contains(value) == true }, evaluatedWith: element)
        waitForExpectations(timeout: 8)
    }
    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector, hold: TimeInterval = 1) {
        app.coordinate(withNormalizedOffset: from).press(forDuration: 0.06,
            thenDragTo: app.coordinate(withNormalizedOffset: to), withVelocity: .slow,
            thenHoldForDuration: hold)
    }
    func testFingerDragsTwoActualPagesInAllFourDirections() {
        let app = launchReader()
        cache("files=1,2,3;", in: app)
        let directions: [(String, CGVector, CGVector)] = [
            ("从左到右 →", .init(dx: 0.70, dy: 0.5), .init(dx: 0.30, dy: 0.5)),
            ("从右到左 ←", .init(dx: 0.30, dy: 0.5), .init(dx: 0.70, dy: 0.5)),
            ("从上到下 ↓", .init(dx: 0.50, dy: 0.70), .init(dx: 0.50, dy: 0.30)),
            ("从下到上 ↑", .init(dx: 0.50, dy: 0.30), .init(dx: 0.50, dy: 0.70))]
        for (title, start, end) in directions {
            app.buttons["reader.direction"].tap(); app.buttons[title].tap()
            drag(app, from: start, to: end, hold: 1.4)
            page("2 / 12", in: app)
            let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch
            let evidence = canvas.value as? String ?? ""
            XCTAssertTrue(evidence.contains("lastDrag=1+2;offset="), evidence)
            XCTAssertTrue(evidence.contains("neighborFile=true"), evidence)
            XCTAssertFalse(app.navigationBars["阅读设置"].exists)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "build10.drag.\(title)"; shot.lifetime = .keepAlways; add(shot)
            drag(app, from: end, to: start)
            page("1 / 12", in: app)
        }
    }
    func testDirectPrefetchChoiceZeroDemandDragCancelZoomAndPersistence() {
        let app = launchReader()
        XCTAssertFalse(app.buttons["reader.prefetch-menu"].exists)
        LoadingSettingsUIHelpers.setPrefetch(0, in: app)
        LoadingSettingsUIHelpers.returnToReader(in: app)
        cache("prefetch=0;files=1,2;", in: app)
        drag(app, from: .init(dx: 0.5, dy: 0.5), to: .init(dx: 0.55, dy: 0.5))
        page("1 / 12", in: app)
        XCTAssertFalse(app.navigationBars["阅读设置"].exists)
        drag(app, from: .init(dx: 0.7, dy: 0.5), to: .init(dx: 0.3, dy: 0.5))
        page("2 / 12", in: app)
        cache("prefetch=0;files=1,2;", in: app)
        let image = app.otherElements["media.static"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5)); image.doubleTap()
        expectation(for: NSPredicate { _, _ in (image.value as? String)?.contains("zoomed") == true }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        drag(app, from: .init(dx: 0.7, dy: 0.5), to: .init(dx: 0.3, dy: 0.5), hold: 0.1)
        page("2 / 12", in: app)
        LoadingSettingsUIHelpers.setPrefetch(6, in: app)
        LoadingSettingsUIHelpers.returnToReader(in: app)
        cache("prefetch=6;", in: app)
        app.terminate()
        let reopened = launchReader(reset: false)
        XCTAssertFalse(reopened.buttons["reader.prefetch-menu"].exists)
        cache("prefetch=6;", in: reopened)
        LoadingSettingsUIHelpers.open(in: reopened)
        XCTAssertEqual(LoadingSettingsUIHelpers.prefetchCount(in: reopened), 6)
    }
}

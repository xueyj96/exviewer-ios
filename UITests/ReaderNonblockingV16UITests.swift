import XCTest
import UIKit

final class ReaderNonblockingV16UITests: XCTestCase {
    private func openReader(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--qa", "--qa-reset-reader-preferences", "--qa-reader-many", "--qa-reader-transition"
        ] + extraArguments
        app.launch()
        let gallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 12))
        gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 12))
        let mode = app.buttons["reader.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
        app.buttons["单页模式"].tap()
        return app
    }

    private func waitForPage(_ label: String, app: XCUIApplication, timeout: TimeInterval = 3) {
        let page = app.buttons["reader.page"]
        expectation(for: NSPredicate { _, _ in page.label == label }, evaluatedWith: page)
        waitForExpectations(timeout: timeout)
    }

    private func cacheValue(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["reader.cache.qa"].firstMatch.value as? String ?? ""
    }

    private func waitForLoadedPage(_ index: Int, app: XCUIApplication, timeout: TimeInterval = 12) {
        let cache = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in
            let value = cache.value as? String ?? ""
            guard let field = value.components(separatedBy: ";").first(where: { $0.hasPrefix("files=") }) else { return false }
            return Set(field.dropFirst("files=".count).split(separator: ",").compactMap { Int($0) }).contains(index)
        }, evaluatedWith: cache)
        waitForExpectations(timeout: timeout)
    }

    private func turnNext(_ app: XCUIApplication, to pageNumber: Int, timeout: TimeInterval = 2) {
        let next = app.buttons["reader.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 3), "The next control should remain available while a page is loading")
        next.tap()
        waitForPage("\(pageNumber) / 12", app: app, timeout: timeout)
    }

    private func turnPrevious(_ app: XCUIApplication, to pageNumber: Int, timeout: TimeInterval = 2) {
        let previous = app.buttons["reader.previous"]
        XCTAssertTrue(previous.waitForExistence(timeout: 3))
        previous.tap()
        waitForPage("\(pageNumber) / 12", app: app, timeout: timeout)
    }

    private func dragForward(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
            .press(forDuration: 0.03,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0.02)
    }

    private func loadingPlaceholder(_ page: Int, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["reader.page.loading.\(page)"].firstMatch
    }

    func testSlowUncachedTurnsCommitImmediatelyAndLateCompletionDoesNotJumpBack() {
        let app = openReader(["--qa-prefetch=0", "--qa-concurrency=16", "--qa-transfer-ms=10000", "--qa-transfer-progress"])
        dragForward(app)
        waitForPage("2 / 12", app: app, timeout: 2)
        let pageTwoPlaceholder = loadingPlaceholder(2, app: app)
        XCTAssertTrue(pageTwoPlaceholder.waitForExistence(timeout: 2), "Page 2 should commit with a visible loading placeholder before its delayed image finishes")
        XCTAssertTrue(pageTwoPlaceholder.staticTexts["25%"].waitForExistence(timeout: 2), "The controlled byte-progress fixture should be visible on the committed page")

        turnNext(app, to: 3, timeout: 2)
        XCTAssertTrue(loadingPlaceholder(3, app: app).waitForExistence(timeout: 2))
        turnPrevious(app, to: 2, timeout: 2)
        XCTAssertTrue(pageTwoPlaceholder.waitForExistence(timeout: 2))

        waitForLoadedPage(2, app: app, timeout: 12)
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 12", "A late image completion must populate page 2 in place without changing the selected page")
        XCTAssertFalse(loadingPlaceholder(2, app: app).exists, "The loading placeholder should disappear when the image arrives")
        let controls = app.descendants(matching: .any)["reader.controls.compact"].firstMatch
        XCTAssertLessThanOrEqual(controls.frame.height, 56)
        app.sliders["reader.progress"].adjust(toNormalizedSliderPosition: 1)
        waitForPage("12 / 12", app: app, timeout: 2)
        XCTAssertTrue(loadingPlaceholder(12, app: app).waitForExistence(timeout: 2), "The compact seek slider should also commit an unloaded page immediately")
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 3), "A loading page should retain the center-tap settings gesture")
        app.buttons["完成"].tap()
        XCTAssertEqual(app.buttons["reader.page"].label, "12 / 12")
    }

    func testUnknownMetadataPageCommitsAndCanBeLeftAndRevisitedWhileMetadataLoads() {
        let app = openReader(["--qa-reader-paging", "--qa-prefetch=0", "--qa-concurrency=16", "--qa-metadata-ms=8000"])
        turnNext(app, to: 2, timeout: 2)
        waitForLoadedPage(2, app: app, timeout: 3)

        turnNext(app, to: 3, timeout: 2)
        XCTAssertTrue(loadingPlaceholder(3, app: app).waitForExistence(timeout: 2), "Unknown page metadata should show an in-place placeholder")
        turnNext(app, to: 4, timeout: 2)
        XCTAssertTrue(loadingPlaceholder(4, app: app).waitForExistence(timeout: 2))
        turnPrevious(app, to: 3, timeout: 2)
        XCTAssertTrue(loadingPlaceholder(3, app: app).exists)

        waitForLoadedPage(3, app: app, timeout: 12)
        XCTAssertEqual(app.buttons["reader.page"].label, "3 / 12", "Metadata and image completion should populate the selected page without a late page jump")
        XCTAssertFalse(loadingPlaceholder(3, app: app).exists)
    }

    func testMissingPageMetadataShowsExplicitRetryInsteadOfAutoRetryLoop() {
        let app = openReader(["--qa-reader-paging", "--qa-prefetch=0", "--qa-reader-metadata-stall"])
        turnNext(app, to: 2, timeout: 2)
        waitForLoadedPage(2, app: app, timeout: 3)
        turnNext(app, to: 3, timeout: 2)

        let retry = app.buttons["reader.page.retry.3"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "A metadata response with no new page should expose an explicit retry")
        XCTAssertEqual(app.buttons["reader.page"].label, "3 / 12")
        let diagnostic = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        for _ in 0..<10 {
            XCTAssertTrue((diagnostic.value as? String ?? "").contains("metadataCalls=1;"), "No-progress metadata must not retry automatically")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(retry.exists)
        XCTAssertEqual(app.buttons["reader.page"].label, "3 / 12")
    }

    func testCachedNeighborRoundTripKeepsPresentationIdentity() {
        let app = openReader(["--qa-prefetch=2", "--qa-concurrency=16"])
        let diagnostic = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in
            let value = diagnostic.value as? String ?? ""
            guard let list = value.components(separatedBy: ";presentations=").last,
                  let presentation = list.components(separatedBy: ",").first(where: { $0.hasPrefix("2:") }) else { return false }
            return presentation.hasSuffix(":1")
        }, evaluatedWith: diagnostic)
        waitForExpectations(timeout: 12)
        let initial = cacheValue(app)
        let presentation = { (value: String) -> String? in
            guard let list = value.components(separatedBy: ";presentations=").last else { return nil }
            return list.components(separatedBy: ",").first(where: { $0.hasPrefix("2:") })
        }
        let identity = presentation(initial)
        XCTAssertNotNil(identity)

        turnNext(app, to: 2)
        XCTAssertEqual(presentation(cacheValue(app)), identity)
        turnPrevious(app, to: 1)
        turnNext(app, to: 2)
        XCTAssertEqual(presentation(cacheValue(app)), identity, "A cached neighboring page should retain its decoded presentation across a round trip")
    }

    func testSlowPlaceholdersCanBeTurnedAndReversedInAllFourDirections() {
        let app = openReader(["--qa-prefetch=0", "--qa-transfer-ms=15000"])
        let directions: [(String, CGVector, CGVector)] = [
            ("从左到右 →", .init(dx: 0.75, dy: 0.5), .init(dx: 0.25, dy: 0.5)),
            ("从右到左 ←", .init(dx: 0.25, dy: 0.5), .init(dx: 0.75, dy: 0.5)),
            ("从上到下 ↓", .init(dx: 0.5, dy: 0.72), .init(dx: 0.5, dy: 0.28)),
            ("从下到上 ↑", .init(dx: 0.5, dy: 0.28), .init(dx: 0.5, dy: 0.72))
        ]
        for (title, start, end) in directions {
            app.buttons["reader.direction"].tap(); app.buttons[title].tap()
            app.coordinate(withNormalizedOffset: start).press(forDuration: 0.03,
                thenDragTo: app.coordinate(withNormalizedOffset: end), withVelocity: .fast, thenHoldForDuration: 0.02)
            waitForPage("2 / 12", app: app, timeout: 2)
            XCTAssertTrue(loadingPlaceholder(2, app: app).exists)
            app.coordinate(withNormalizedOffset: end).press(forDuration: 0.03,
                thenDragTo: app.coordinate(withNormalizedOffset: start), withVelocity: .fast, thenHoldForDuration: 0.02)
            waitForPage("1 / 12", app: app, timeout: 2)
        }
    }
}

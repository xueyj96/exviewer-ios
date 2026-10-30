import XCTest

final class DetailActionLayoutV32UITests: XCTestCase {
    func testFavoriteActionsStaySingleLineWithSeparateGroupAndLargeType() {
        continueAfterFailure = false
        let cases: [(String, [String], String)] = [
            ("Favorites 0", [], "regular"),
            ("Favorites 0 · A deliberately long saved collection name for checking compact action layout", [], "long-group"),
            ("Favorites 0", ["--qa-dark", "--qa-large-type"], "dark-large")
        ]
        for (name, extra, tag) in cases {
            let app = XCUIApplication()
            app.launchArguments = ["--qa", "--qa-favorite-existing", "--qa-favorite-group=" + name] + extra
            app.launch()
            let card = app.buttons["gallery.open.1"]; XCTAssertTrue(card.waitForExistence(timeout: 12)); card.tap()
            let favorite = app.buttons["detail.site-favorite"], read = app.buttons["在线阅读"], more = app.buttons["detail.more"]
            let group = app.staticTexts["detail.favorite-group"]
            XCTAssertTrue(favorite.waitForExistence(timeout: 8)); XCTAssertTrue(group.waitForExistence(timeout: 5))
            XCTAssertTrue(favorite.label.contains("已收藏")); XCTAssertTrue(favorite.label.contains(name))
            XCTAssertTrue(group.label.contains(name))
            for button in [favorite, read, more] {
                // AX frame subtraction can report 44pt as43.99999999999994.
                // This tolerance isfar below a screen pixel;the target stays44pt.
                let precision: CGFloat = 0.000_001
                XCTAssertGreaterThanOrEqual(button.frame.height + precision, 44)
                XCTAssertLessThanOrEqual(button.frame.height, 48, "Actions must not grow into stacked text buttons")
                XCTAssertGreaterThanOrEqual(button.frame.width + precision, 44)
            }
            XCTAssertEqual(favorite.frame.midY, read.frame.midY, accuracy: 1)
            XCTAssertEqual(favorite.frame.midY, more.frame.midY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(group.frame.minY, favorite.frame.maxY, "Group must be outside thebutton")
            XCTAssertLessThanOrEqual(group.frame.maxX, more.frame.maxX + 1)
            XCTAssertLessThanOrEqual(group.frame.height, 44, "Long group isone truncatable secondary line")
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "detail32." + tag; shot.lifetime = .keepAlways; add(shot)
            favorite.tap()
            XCTAssertTrue(app.buttons["favorite.editor.group.0"].waitForExistence(timeout: 6))
            app.buttons["favorite.editor.cancel"].tap()
            XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
}

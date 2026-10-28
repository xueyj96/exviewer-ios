import XCTest

final class FlatChromeV19UITests: XCTestCase {
    func testFlatBackKeepsInteractivePopAndCanBeReentered() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--screen", "account"]
        app.launch()
        let storage = app.buttons["account.storage"]
        XCTAssertTrue(storage.waitForExistence(timeout: 10))
        storage.tap()
        let navigation = app.navigationBars["阅读与存储"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 6))
        let back = navigation.buttons["BackButton"]
        XCTAssertTrue(back.exists && back.isHittable)
        XCTAssertLessThanOrEqual(back.frame.width, 45)
        XCTAssertLessThanOrEqual(back.frame.height, 45)
        let diagnostic = app.descendants(matching: .any)["qa.navigation.flat"].firstMatch
        print("FLAT19_NAVIGATION \(diagnostic.exists ? String(describing: diagnostic.value) : "unavailable")")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "build19.account.flat-back"; shot.lifetime = .keepAlways; add(shot)

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        // Cancel an initial short, slow drag before performing a full return.
        edge.press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(navigation.exists)
        XCTAssertTrue(back.isHittable)
        edge.press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        print("FLAT19_AFTER_SWIPE \(diagnostic.exists ? String(describing: diagnostic.value) : "unavailable")")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: navigation)
        waitForExpectations(timeout: 6)
        XCTAssertTrue(storage.isHittable)
        storage.tap()
        XCTAssertTrue(navigation.waitForExistence(timeout: 6))
        back.tap()
        XCTAssertTrue(storage.waitForExistence(timeout: 6))
        XCTAssertTrue(storage.isHittable)
    }
}

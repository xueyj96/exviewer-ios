import XCTest

final class CompactMainTabsV16UITests: XCTestCase {
    func testCompactBarSwitchesAllRootTabsWithoutShowingNativeBar() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa"]
        app.launch()

        let bar = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 12))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "main.tabs.compact").count, 1)
        XCTAssertEqual(bar.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "main.tab.")).count, 3,
                       "Count navigation controls, excluding SwiftUI's private icon/text descendants")
        XCTAssertLessThanOrEqual(bar.frame.height, 56, "The compact tab bar should remain below 56 points tall")
        XCTAssertEqual(app.tabBars.count, 0, "The native tab bar should remain hidden")

        let tabs = ["main.tab.discover", "main.tab.library", "main.tab.account"]
        for (index, identifier) in tabs.enumerated() {
            let tab = app.buttons[identifier]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            XCTAssertTrue(tab.isHittable)
            tab.tap()
            XCTAssertTrue(tab.isSelected, "Tab \(identifier) should become selected")
            XCTAssertEqual(app.tabBars.count, 0)
            if index < tabs.count - 1 {
                XCTAssertTrue(bar.isHittable, "The compact bar should remain available after switching tabs")
            }
        }
    }
}

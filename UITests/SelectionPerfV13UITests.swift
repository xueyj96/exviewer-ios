import XCTest

/// Exercises the real QA library surface while SelectionPerformanceProbe is
/// enabled in the DEBUG simulator app. Probe events are in app process logs;
/// this test's accessibility observation is a separate, slower completion
/// signal and must not be read as the presentation time.
final class SelectionPerfV13UITests: XCTestCase {
    func testRealSelectionTapWithPassiveProbeAndVisibleStateEvidence() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--qa",
            "--qa-reset-reader-preferences",
            "--qa-library-large-selection",
            "--qa-perf"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 15))
        app.buttons["main.tab.library"].tap()

        let first = app.buttons["favorites.gallery.10000"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5))
        let initialState = XCTAttachment(screenshot: app.screenshot())
        initialState.name = "selection-perf-v13-before-toggle"
        initialState.lifetime = .keepAlways
        add(initialState)

        let target = app.buttons["favorites.select.10001"]
        XCTAssertTrue(target.waitForExistence(timeout: 8))
        let actionStart = ProcessInfo.processInfo.systemUptime
        target.tap()
        let selected = NSPredicate(format: "value == %@", "已选中")
        expectation(for: selected, evaluatedWith: target)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.staticTexts["已选 2 项"].waitForExistence(timeout: 5))
        let axObserved = ProcessInfo.processInfo.systemUptime
        print("SELECTION_PERF_XCTEST tap-to-accessibility-state=\(String(format: "%.6f", axObserved - actionStart))s; includes XCTest dispatch/query/wait")

        let updatedState = XCTAttachment(screenshot: app.screenshot())
        updatedState.name = "selection-perf-v13-after-toggle"
        updatedState.lifetime = .keepAlways
        add(updatedState)
    }
}

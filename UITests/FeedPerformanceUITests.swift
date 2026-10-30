import XCTest

final class FeedPerformanceUITests: XCTestCase {
    func testThousandItemFeedScrollMetrics() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-feed-performance", "--qa-tags-offline"]
        app.launch()
        let feed = app.scrollViews["discover.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["浏览性能样例 1"].waitForExistence(timeout: 8))
        func cycle() {
            for _ in 0..<4 { feed.swipeUp(velocity: .fast) }
            for _ in 0..<4 { feed.swipeDown(velocity: .fast) }
        }
        cycle() // Warm the same cover/geometry path before collecting samples.
        let options = XCTMeasureOptions(); options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app),
                          XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric],
                options: options) { cycle() }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "feed.performance.1000-neutral-items"; shot.lifetime = .keepAlways; add(shot)
    }
}

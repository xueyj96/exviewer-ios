import XCTest

/// Neutral, local-only measurements for the library feed. These are intended to
/// run against the frozen build-11 app first, then the integrated build-12 app.
/// XCTest timings include UI event delivery, accessibility queries, and waits.
final class LibraryV12UITests: XCTestCase {
    private let firstID = "10000"

    private func launchQA(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-library-large-selection"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 15))
        app.buttons["main.tab.library"].tap()
        let workload = app.descendants(matching: .any)["library.qa.workload"].firstMatch
        XCTAssertTrue(workload.waitForExistence(timeout: 15))
        XCTAssertEqual(workload.value as? String, "galleries=600;blocked=250")
        return app
    }

    private func waitCount(_ expected: Int, app: XCUIApplication, timeout: TimeInterval = 8) {
        XCTAssertTrue(app.staticTexts["已选 \(expected) 项"].waitForExistence(timeout: timeout),
                      "Selection counter did not reach \(expected)")
    }

    private func enterSelection(_ app: XCUIApplication) {
        let choice = app.buttons["favorites.edit"]
        if choice.exists && choice.label == "选择" {
            choice.tap()
            waitCount(0, app: app)
            return
        }
        let normalTile = app.buttons["favorites.gallery.\(firstID)"]
        XCTAssertTrue(normalTile.waitForExistence(timeout: 8))
        normalTile.press(forDuration: 0.8)
        waitCount(1, app: app)
    }

    private func stamp(_ name: String, since start: TimeInterval) {
        print("LIBRARY_V12_METRIC \(name)=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))s")
    }

    private func recordCoverAX(_ app: XCUIApplication, phase: String) {
        let cover = app.descendants(matching: .any)["cover.media.\(firstID)"].firstMatch
        if cover.exists, let value = cover.value as? String {
            print("LIBRARY_V12_COVER_STATE \(phase)=\(value)")
        } else {
            let media = app.otherElements["media.static"].firstMatch
            print("LIBRARY_V12_COVER_STATE \(phase)=UNKNOWN; cover.media AX value unavailable; media.static exists=\(media.exists)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "library-v12-\(phase)-cover-ax-unknown"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Measures process-cold launch and same-test relaunch with the same local
    /// QA fixture. No caches are cleared: the latter is a warm-state relaunch,
    /// not a claim about an OS-cold device.
    func testLibraryLaunchFirstVisibleAndInteractiveColdWarmMetrics() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-library-large-selection"]

        for phase in ["process-cold", "same-test-relaunch"] {
            if phase == "same-test-relaunch" { app.terminate() }
            let start = ProcessInfo.processInfo.systemUptime
            app.launch()
            let libraryTab = app.buttons["main.tab.library"]
            XCTAssertTrue(libraryTab.waitForExistence(timeout: 15))
            stamp("\(phase).tab-ready", since: start)
            libraryTab.tap()
            let workload = app.descendants(matching: .any)["library.qa.workload"].firstMatch
            XCTAssertTrue(workload.waitForExistence(timeout: 15))
            XCTAssertEqual(workload.value as? String, "galleries=600;blocked=250")
            let first = app.buttons["favorites.gallery.\(firstID)"]
            XCTAssertTrue(first.waitForExistence(timeout: 15))
            XCTAssertTrue(first.isHittable)
            stamp("\(phase).first-visible", since: start)

            enterSelection(app)
            let coverStart = ProcessInfo.processInfo.systemUptime
            let selectedTile = app.buttons["favorites.select.\(firstID)"]
            XCTAssertTrue(selectedTile.waitForExistence(timeout: 8))
            recordCoverAX(app, phase: phase)
            stamp("\(phase).cover-state-observed-or-unknown", since: coverStart)

            let selectionStart = ProcessInfo.processInfo.systemUptime
            if (selectedTile.value as? String) != "已选中" { selectedTile.tap() }
            waitCount(1, app: app)
            stamp("\(phase).interactive-one-selected", since: selectionStart)

            app.buttons["favorites.edit"].tap()
            XCTAssertTrue(app.buttons["favorites.gallery.\(firstID)"].waitForExistence(timeout: 8))
            app.buttons["main.tab.discover"].tap()
            let returnStart = ProcessInfo.processInfo.systemUptime
            app.buttons["main.tab.library"].tap()
            XCTAssertTrue(app.buttons["favorites.gallery.\(firstID)"].waitForExistence(timeout: 10))
            stamp("\(phase).same-process-library-return-first-retained", since: returnStart)
        }
    }

    /// Measures large-list scroll handoff and selection stability while the
    /// same 600 galleries / 250 nonmatching blocked tags are loaded.
    func testLargeLibraryScrollAndBatchSelectionMetrics() {
        let app = launchQA()
        enterSelection(app)
        let initialCount = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已选 ")).firstMatch
        XCTAssertTrue(initialCount.waitForExistence(timeout: 5))
        if (initialCount.label != "已选 1 项") {
            let first = app.buttons["favorites.select.\(firstID)"]
            first.tap()
            waitCount(1, app: app)
        }

        let scrollStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<4 { app.swipeUp() }
        for _ in 0..<4 { app.swipeDown() }
        waitCount(1, app: app)
        XCTAssertEqual(app.buttons["favorites.select.\(firstID)"].value as? String, "已选中")
        stamp("eight-swipes-roundtrip", since: scrollStart)

        let batchStart = ProcessInfo.processInfo.systemUptime
        app.buttons["favorites.select-all"].tap()
        waitCount(600, app: app, timeout: 20)
        stamp("select-all-600-visible", since: batchStart)
        XCTAssertEqual(app.descendants(matching: .any)["library.qa.workload"].value as? String,
                       "galleries=600;blocked=250")
    }

    /// Confirms that taps and mode entry remain responsive while all cover
    /// requests are held on local QA fixtures. This test does not wait for the
    /// delayed files and does not access the network.
    func testSelectionRespondsWithSlowLocalCoversPending() {
        let app = launchQA(extra: ["--qa-library-delayed-covers"])
        enterSelection(app)
        let first = app.buttons["favorites.select.\(firstID)"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(first.label.contains("封面载入中"))
        if (first.value as? String) != "已选中" {
            first.tap()
            waitCount(1, app: app)
        }
        let second = app.buttons["favorites.select.10001"]
        XCTAssertTrue(second.waitForExistence(timeout: 8))
        let toggleStart = ProcessInfo.processInfo.systemUptime
        second.tap()
        waitCount(2, app: app)
        stamp("slow-cover-pending-toggle-second", since: toggleStart)
        XCTAssertTrue(first.label.contains("封面载入中"))
        app.swipeUp(); app.swipeDown()
        waitCount(2, app: app)
        XCTAssertEqual(first.value as? String, "已选中")
        app.buttons["favorites.edit"].tap()
        XCTAssertTrue(app.buttons["favorites.gallery.\(firstID)"].waitForExistence(timeout: 8))
        app.buttons["favorites.gallery.\(firstID)"].press(forDuration: 0.8)
        waitCount(1, app: app)
        XCTAssertFalse(app.staticTexts["画廊详情"].exists, "Long press must enter selection without opening details")
        XCTAssertTrue(app.buttons["favorites.select.\(firstID)"].label.contains("封面载入中"))
    }
}

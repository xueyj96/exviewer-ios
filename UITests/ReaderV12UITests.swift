import XCTest

final class ReaderV12UITests: XCTestCase {
    private func cacheValue(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["reader.cache.qa"].firstMatch.value as? String ?? ""
    }

    private func presentation(_ page: Int, from diagnostic: String) -> String? {
        guard let list = diagnostic.components(separatedBy: ";presentations=").last else { return nil }
        return list.components(separatedBy: ",").first { $0.hasPrefix("\(page):") }
    }

    private func waitForCachedAndPresentedNeighbor(_ app: XCUIApplication) {
        let diagnostic = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        let ready = NSPredicate { _, _ in
            let value = diagnostic.value as? String ?? ""
            guard value.contains("files=1,2,3;") else { return false }
            return self.presentation(2, from: value) != nil
        }
        expectation(for: ready, evaluatedWith: diagnostic)
        waitForExpectations(timeout: 15)
    }

    private func waitForPageTwo(_ app: XCUIApplication) {
        let page = app.buttons["reader.page"]
        expectation(for: NSPredicate { _, _ in page.label == "2 / 12" }, evaluatedWith: page)
        waitForExpectations(timeout: 12)
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSlowDragToCachedNeighborKeepsTargetCanvasIdentity() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--qa",
            "--qa-reader-transition",
            "--qa-reader-many",
            "--qa-reset-reader-preferences",
            "--qa-prefetch=2",
            "--qa-pager-motion-marker"
        ]
        app.launch()

        let gallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 12))
        gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        read.tap()

        let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 12))
        waitForCachedAndPresentedNeighbor(app)
        XCTAssertEqual(app.buttons["reader.page"].label, "1 / 12")

        let startCache = cacheValue(app)
        let pageOneIdentity = presentation(1, from: startCache)
        let pageTwoIdentity = presentation(2, from: startCache)
        XCTAssertNotNil(pageOneIdentity)
        XCTAssertNotNil(pageTwoIdentity)
        XCTAssertTrue(pageTwoIdentity?.hasSuffix(":1") == true, "The preloaded target should already have one decoded canvas")
        let startCanvasState = canvas.value as? String ?? "nil"
        print("READER12_MOTION_START canvas=\(startCanvasState); canvasFrame=\(canvas.frame); appFrame=\(app.frame); page1=\(pageOneIdentity ?? "nil"); page2=\(pageTwoIdentity ?? "nil"); cache=\(startCache)")

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.5))
        start.press(forDuration: 0.03, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
        waitForPageTwo(app)

        let completedCache = cacheValue(app)
        let completedPageTwo = presentation(2, from: completedCache)
        XCTAssertEqual(completedPageTwo, pageTwoIdentity, "Page 2 must keep the decoded canvas created before the turn")
        XCTAssertTrue(completedPageTwo?.hasSuffix(":1") == true, "The cached target should not decode a second canvas during handoff")
        XCTAssertTrue((canvas.value as? String)?.contains("page 2") == true)
        XCTAssertTrue((canvas.value as? String)?.contains("lastDrag=1+2;offset=") == true, "The baseline must actually exercise the image drag, not an edge tap")
        XCTAssertTrue((canvas.value as? String)?.contains("extent=\(app.frame.width),") == true,
                      "The release must use the same positive viewport extent as the finger")
        XCTAssertTrue((canvas.value as? String)?.contains("release=commit=true,target=2,") == true)
        print("READER12_MOTION_END canvas=\(canvas.value ?? "nil"); page2=\(completedPageTwo ?? "nil"); cache=\(completedCache)")
        capture(app, named: "reader12.slow-cached-neighbor-handoff")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }

    func testSlowCachedReleasesUseTheFingerExtentInEveryDirectionAndCenterTapOpensSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reader-transition", "--qa-reader-many", "--qa-reset-reader-preferences", "--qa-prefetch=2"]
        app.launch()
        let gallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 12)); gallery.tap()
        XCTAssertTrue(app.buttons["在线阅读"].waitForExistence(timeout: 8)); app.buttons["在线阅读"].tap()
        waitForCachedAndPresentedNeighbor(app)
        let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch
        let directions: [(String, CGVector, CGVector, Double, Bool)] = [
            ("从左到右 →", .init(dx: 0.68, dy: 0.5), .init(dx: 0.36, dy: 0.5), 402, false),
            ("从右到左 ←", .init(dx: 0.32, dy: 0.5), .init(dx: 0.64, dy: 0.5), 402, true),
            ("从上到下 ↓", .init(dx: 0.5, dy: 0.62), .init(dx: 0.5, dy: 0.36), 634, false),
            ("从下到上 ↑", .init(dx: 0.5, dy: 0.36), .init(dx: 0.5, dy: 0.62), 634, true)
        ]
        for (title, start, end, extent, reverse) in directions {
            app.buttons["reader.direction"].tap(); app.buttons[title].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let identity = presentation(2, from: cacheValue(app))
            let a = app.coordinate(withNormalizedOffset: start)
            let b = app.coordinate(withNormalizedOffset: end)
            a.press(forDuration: 0.03, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.6)
            waitForPageTwo(app)
            let state = canvas.value as? String ?? ""
            XCTAssertTrue(state.contains("ready=true,extent=\(extent),"), state)
            XCTAssertTrue(state.contains("destination=\(reverse ? extent : -extent)"), state)
            XCTAssertEqual(presentation(2, from: cacheValue(app)), identity)
            print("READER12_DIRECTION_RELEASE \(title); \(state)")
            capture(app, named: "reader12.slow-release.\(title)")
            b.press(forDuration: 0.03, thenDragTo: a, withVelocity: .slow, thenHoldForDuration: 0.6)
            let page = app.buttons["reader.page"]
            expectation(for: NSPredicate { _, _ in page.label == "1 / 12" }, evaluatedWith: page)
            waitForExpectations(timeout: 8)
        }
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
    }
}

import XCTest

final class ReaderV8UITests: XCTestCase {
    private let galleryTitle = "海岸线 · 插画与速写"

    private func launchReaderThroughDiscovery(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences"] + extraArguments
        app.launch()

        let gallery = app.staticTexts[galleryTitle].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 15), "QA discovery gallery should appear")
        gallery.tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 8))
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8), "Enter through gallery details, not a reader launch shortcut")
        read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 15))
        return app
    }

    private func chooseMode(_ title: String, in app: XCUIApplication) {
        app.buttons["reader.settings"].tap()
        let modePicker = app.segmentedControls["reader.settings.mode"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 5))
        selectMode(title, picker: modePicker, app: app)
    }

    private func selectMode(_ title: String, picker: XCUIElement, app: XCUIApplication) {
        for _ in 0..<4 { if picker.buttons[title].isHittable { break }; app.swipeDown() }
        XCTAssertTrue(picker.buttons[title].isHittable, "Mode option \(title) should be reachable in the settings form")
        picker.buttons[title].tap()
        XCTAssertTrue(picker.buttons[title].isSelected)
    }

    private func chooseDirection(_ rawValue: String, in app: XCUIApplication) {
        let direction = app.buttons["reader.settings.direction.\(rawValue)"]
        XCTAssertTrue(direction.waitForExistence(timeout: 5), "Missing direction option \(rawValue)")
        for _ in 0..<4 { if direction.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(direction.isHittable, "Direction option \(rawValue) should be reachable in the settings form")
        direction.tap()
    }

    private func finishSettings(_ app: XCUIApplication) {
        app.navigationBars["阅读设置"].buttons["完成"].tap()
    }

    private func setDirection(_ rawValue: String, in app: XCUIApplication) {
        app.buttons["reader.settings"].tap()
        chooseDirection(rawValue, in: app)
        finishSettings(app)
    }

    private func waitForPage(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 6) {
        let page = app.buttons["reader.page"]
        let predicate = NSPredicate { _, _ in page.label == label }
        expectation(for: predicate, evaluatedWith: page)
        waitForExpectations(timeout: timeout)
    }

    private func visibleMedia(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let media = app.otherElements.matching(identifier: identifier)
        let visible = NSPredicate { _, _ in media.allElementsBoundByIndex.contains { $0.isHittable } }
        expectation(for: visible, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        return media.allElementsBoundByIndex.first { $0.isHittable } ?? media.firstMatch
    }

    private func assertMode(_ title: String, selected: Bool, in app: XCUIApplication) {
        app.buttons["reader.settings"].tap()
        let picker = app.segmentedControls["reader.settings.mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.buttons[title].isSelected, selected)
        finishSettings(app)
    }

    func testModeAndFourDirectionsAreIndependent() {
        let app = launchReaderThroughDiscovery()
        app.buttons["reader.settings"].tap()
        let picker = app.segmentedControls["reader.settings.mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        selectMode("连续模式", picker: picker, app: app)
        for raw in ["leftToRight", "rightToLeft", "topToBottom", "bottomToTop"] {
            chooseDirection(raw, in: app)
            XCTAssertTrue(picker.buttons["连续模式"].isSelected, "Changing \(raw) must not change reading mode")
        }
        selectMode("单页模式", picker: picker, app: app)
        for raw in ["leftToRight", "rightToLeft", "topToBottom", "bottomToTop"] {
            chooseDirection(raw, in: app)
            XCTAssertTrue(picker.buttons["单页模式"].isSelected, "Changing \(raw) must not change reading mode")
        }
        finishSettings(app)
        XCTAssertTrue(app.buttons["reader.direction"].label.contains("↑"))
    }

    func testSinglePageSwipeAndEdgeControlsFollowAllFourDirections() {
        let app = launchReaderThroughDiscovery()
        chooseMode("单页模式", in: app)
        finishSettings(app)

        let directions: [(raw: String, forwardSwipe: () -> Void, backwardSwipe: () -> Void, next: String, previous: String)] = [
            ("leftToRight", { app.swipeLeft() }, { app.swipeRight() }, "下一页，从左到右", "上一页，从左到右"),
            ("rightToLeft", { app.swipeRight() }, { app.swipeLeft() }, "下一页，从右到左", "上一页，从右到左"),
            ("topToBottom", { app.swipeUp() }, { app.swipeDown() }, "下一页，从上到下", "上一页，从上到下"),
            ("bottomToTop", { app.swipeDown() }, { app.swipeUp() }, "下一页，从下到上", "上一页，从下到上")
        ]

        for direction in directions {
            setDirection(direction.raw, in: app)
            direction.forwardSwipe()
            waitForPage("2 / 3", in: app)
            direction.backwardSwipe()
            waitForPage("1 / 3", in: app)
            app.buttons[direction.next].tap()
            waitForPage("2 / 3", in: app)
            app.buttons[direction.previous].tap()
            waitForPage("1 / 3", in: app)
        }

        setDirection("leftToRight", in: app)
        app.buttons["下一页，从左到右"].tap()
        waitForPage("2 / 3", in: app)
        let image = visibleMedia("media.static", in: app)
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        image.doubleTap()
        let zoomed = NSPredicate { _, _ in (image.value as? String)?.contains("zoomed") == true }
        expectation(for: zoomed, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        image.swipeLeft()
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 3", "Panning a zoomed single page must not turn the page")
        image.doubleTap()
        let fit = NSPredicate { _, _ in (image.value as? String)?.contains("fit") == true }
        expectation(for: fit, evaluatedWith: image)
        waitForExpectations(timeout: 5)
    }

    func testModeAndDirectionChangesKeepCurrentPageAndPersistAfterRelaunch() {
        let app = launchReaderThroughDiscovery()
        chooseMode("单页模式", in: app)
        chooseDirection("bottomToTop", in: app)
        finishSettings(app)
        app.buttons["下一页，从下到上"].tap()
        waitForPage("2 / 3", in: app)

        app.buttons["reader.settings"].tap()
        let modePicker = app.segmentedControls["reader.settings.mode"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 5))
        selectMode("连续模式", picker: modePicker, app: app)
        chooseDirection("topToBottom", in: app)
        finishSettings(app)
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 3")
        XCTAssertTrue(app.buttons["reader.direction"].label.contains("↓"))

        let pageNumber = app.buttons["reader.page"]
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        XCTAssertLessThanOrEqual(abs(pageNumber.frame.midX - window.frame.midX), 2.0, "Page count must remain screen-centered")
        for button in [app.buttons["reader.mode"], app.buttons["reader.direction"], app.buttons["reader.settings"], app.buttons["reader.bookmark"]] {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }

        app.terminate()
        app.launchArguments = ["--qa"]
        app.launch()
        let gallery = app.staticTexts[galleryTitle].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 15))
        gallery.tap()
        app.buttons["在线阅读"].tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["reader.direction"].label.contains("↓"))
        XCTAssertEqual(app.buttons["reader.page"].label, "1 / 3")
        assertMode("连续模式", selected: true, in: app)
    }

    func testContinuousZoomPanDoesNotScrollPageOrTriggerEdgeActionsAndUsesImagePixels() {
        let app = launchReaderThroughDiscovery()
        setDirection("topToBottom", in: app)
        app.swipeUp()
        waitForPage("2 / 3", in: app)

        let frames = app.descendants(matching: .any).matching(identifier: "reader.page.frame").allElementsBoundByIndex
        let landscape = frames.first { element in
            let frame = element.frame
            return frame.width > 0 && frame.height > 0 && abs(frame.height / frame.width - 0.5) < 0.08
        }
        XCTAssertNotNil(landscape, "The 720 x 360 QA fixture should lay out at its ImageIO pixel ratio")
        if let landscape {
            XCTAssertLessThan(landscape.frame.height, app.windows.firstMatch.frame.width * 0.62, "Landscape page must not reserve a portrait-height gap")
        }
        let orderedFrames = frames.map(\.frame).filter { $0.width > 0 && $0.height > 0 }.sorted { $0.minY < $1.minY }
        if orderedFrames.count >= 2 {
            XCTAssertLessThanOrEqual(orderedFrames[1].minY - orderedFrames[0].maxY, 8, "Adjacent continuous pages should use only a small inter-page gap")
        }

        let image = visibleMedia("media.static", in: app)
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        image.doubleTap()
        let zoomed = NSPredicate { _, _ in (image.value as? String)?.contains("zoomed") == true }
        expectation(for: zoomed, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        image.swipeDown()
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 3", "Panning a zoomed continuous image must not advance the reader")
        XCTAssertTrue(image.value as? String == nil || (image.value as? String)?.contains("zoomed") == true)
        image.doubleTap()
        let fit = NSPredicate { _, _ in (image.value as? String)?.contains("fit") == true }
        expectation(for: fit, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 3")
    }

    func testSeekHUDGestureAndReleaseCompletesAtTargetPage() {
        let app = launchReaderThroughDiscovery()
        let slider = app.sliders["reader.progress"]
        XCTAssertTrue(slider.waitForExistence(timeout: 8))
        slider.adjust(toNormalizedSliderPosition: 0)
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.035, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
        start.press(forDuration: 0.25, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2.0)
        waitForPage("3 / 3", in: app, timeout: 12)
        XCTAssertFalse(app.descendants(matching: .any)["reader.progress.hud"].exists, "HUD should dismiss after release and seek completion")
    }

    func testReverseContinuousLoadMoreKeepsPageAndCanSeekNewLastPage() {
        let app = launchReaderThroughDiscovery(extraArguments: ["--qa-reader-paging"])
        setDirection("bottomToTop", in: app)
        app.swipeDown()
        waitForPage("2 / 3", in: app)

        let loadMore = app.buttons["reader.load-more"]
        XCTAssertTrue(loadMore.waitForExistence(timeout: 5), "Reverse continuous layout must expose load-more before the reversed page sequence")
        for _ in 0..<4 { if loadMore.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(loadMore.isHittable, "Load-more at the reverse sequence boundary must be reachable")
        loadMore.tap()

        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 3", "Appending the next batch must preserve current page")
        let disappeared = NSPredicate { _, _ in !loadMore.exists }
        expectation(for: disappeared, evaluatedWith: loadMore)
        waitForExpectations(timeout: 5)
        let slider = app.sliders["reader.progress"]
        XCTAssertTrue(slider.exists)
        slider.adjust(toNormalizedSliderPosition: 1)
        waitForPage("3 / 3", in: app, timeout: 8)
    }

    func testPendingPaginationKeepsTheUsersNewerPageChoice() {
        let app = launchReaderThroughDiscovery(extraArguments: ["--qa-reader-paging", "--qa-reader-delay"])
        setDirection("bottomToTop", in: app)
        app.swipeDown()
        waitForPage("2 / 3", in: app)
        let loadMore = app.buttons["reader.load-more"]
        XCTAssertTrue(loadMore.waitForExistence(timeout: 5)); loadMore.tap()
        app.sliders["reader.progress"].adjust(toNormalizedSliderPosition: 0)
        waitForPage("1 / 3", in: app)
        let finished = NSPredicate { _, _ in !loadMore.exists }
        expectation(for: finished, evaluatedWith: loadMore)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(app.buttons["reader.page"].label, "1 / 3", "A delayed append must preserve the user's newer seek")
    }

    func testContinuousCanvasFollowsAllDirectionsAndLayoutChangesKeepPage() {
        let app = launchReaderThroughDiscovery()
        let directions: [(String, () -> Void, String)] = [
            ("leftToRight", { app.swipeLeft() }, "上一页，从左到右"),
            ("rightToLeft", { app.swipeRight() }, "上一页，从右到左"),
            ("topToBottom", { app.swipeUp() }, "上一页，从上到下"),
            ("bottomToTop", { app.swipeDown() }, "上一页，从下到上")
        ]
        for (direction, swipe, previous) in directions {
            setDirection(direction, in: app)
            if direction == "leftToRight" || direction == "rightToLeft" {
                // Continuous pages retain their pixel ratio; a wide image can
                // require more than one drag to cross its scroll target.
                for _ in 0..<4 {
                    if app.buttons["reader.page"].label == "2 / 3" { break }
                    let forward = direction == "leftToRight"
                    let start = app.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.72 : 0.28, dy: 0.5))
                    let end = app.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.18 : 0.82, dy: 0.5))
                    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
                    print("CONTINUOUS \(direction): \(app.buttons["reader.page"].label)")
                }
            } else if direction == "bottomToTop" {
                // A fast flick can legitimately cross several short pages.
                // Use a controlled slow drag to test the middle page's stop.
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.54))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
                print("CONTINUOUS bottomToTop controlled: \(app.buttons["reader.page"].label)")
            } else { swipe() }
            waitForPage("2 / 3", in: app)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Continuous canvas \(direction)"; attachment.lifetime = .keepAlways; add(attachment)
            app.buttons[previous].tap(); waitForPage("1 / 3", in: app)
        }
        setDirection("topToBottom", in: app)
        app.swipeUp(); waitForPage("2 / 3", in: app)
        Thread.sleep(forTimeInterval: 0.5)
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 3", "Layout after scrolling has stopped must not overwrite the current page")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.buttons["reader.page"].label, "2 / 3")
    }
}

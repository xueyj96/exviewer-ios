import XCTest

enum LoadingSettingsUIHelpers {
    static func open(in app: XCUIApplication) {
        let existingPrefetchSlider = app.sliders["account.loading.prefetch"]
        if existingPrefetchSlider.exists { return }

        let readerSettingsDone = app.navigationBars["阅读设置"].buttons["完成"]
        if readerSettingsDone.exists { readerSettingsDone.tap() }

        let readerClose = app.buttons["reader.close"]
        if readerClose.exists { readerClose.tap() }

        let accountTab = app.buttons["main.tab.account"]
        XCTAssertTrue(accountTab.waitForExistence(timeout: 8), "Account tab should be available")
        accountTab.tap()

        let storageLink = app.buttons["account.storage"]
        for _ in 0..<8 {
            if storageLink.exists && storageLink.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(storageLink.exists && storageLink.isHittable, "Reading and storage settings should be reachable from Account")
        storageLink.tap()
        XCTAssertTrue(app.sliders["account.loading.prefetch"].waitForExistence(timeout: 8))
    }

    static func returnToReader(in app: XCUIApplication) {
        let storageBack = app.navigationBars["阅读与存储"].buttons.element(boundBy: 0)
        if storageBack.exists { storageBack.tap() }

        let discoverTab = app.buttons["main.tab.discover"]
        XCTAssertTrue(discoverTab.waitForExistence(timeout: 8), "Discover tab should be available")
        discoverTab.tap()

        let onlineRead = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "在线阅读", "继续阅读")).firstMatch
        if !onlineRead.waitForExistence(timeout: 4) {
            let firstGallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
            XCTAssertTrue(firstGallery.waitForExistence(timeout: 8), "The first QA gallery should be available in Discover")
            firstGallery.tap()
        }
        XCTAssertTrue(onlineRead.waitForExistence(timeout: 8))
        onlineRead.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
    }

    static func setPrefetch(_ count: Int, in app: XCUIApplication) {
        XCTAssertTrue((0...128).contains(count), "Prefetch count must be within the account slider range")
        open(in: app)
        let slider = app.sliders["account.loading.prefetch"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if slider.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(slider.isHittable, "Account prefetch slider should be reachable")
        let previous = prefetchCount(in: app)
        if let previous, abs(previous - count) >= 16 {
            slider.adjust(toNormalizedSliderPosition: CGFloat(count) / 128.0)
            XCTAssertNotEqual(prefetchCount(in: app), previous, "Dragging the slider must update its image count")
        }
        if prefetchCount(in: app) != count {
            // LabeledContent merges the label and trailing button into one AX
            // frame. Hit the visible trailing count, rather than the row center.
            app.buttons["account.loading.prefetch-edit"].coordinate(withNormalizedOffset: .init(dx: 0.94, dy: 0.5)).tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 3))
            XCTAssertTrue(alert.staticTexts["预加载数量"].exists)
            let field = alert.textFields.element(boundBy: 0)
            // The native alert focuses this field and opens the number pad.
            // A second tap during its presentation can open the edit menu and
            // intercept synthesized typing. Wait for the keyboard first.
            if !app.keyboards.firstMatch.exists { field.tap() }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + String(count))
            XCTAssertEqual(field.value as? String, String(count))
            alert.buttons["保存"].tap()
            // The number-pad dismissal can relocate this native alert during
            // the first synthesized tap. Re-read the still-present alert first.
            if alert.exists { alert.buttons["保存"].tap() }
            XCTAssertFalse(alert.exists, "Saving the exact count must dismiss its alert")
        }
        XCTAssertEqual(prefetchCount(in: app), count, "Account prefetch slider should expose the chosen count")
    }

    static func prefetchCount(in app: XCUIApplication) -> Int? {
        // Preserve the slider's native percentage value for platform adjustment;
        // its accessibility label announces the actual count in image units.
        Int(app.sliders["account.loading.prefetch"].label.filter(\.isNumber))
    }

    static func chooseImageConcurrency(_ count: Int, in app: XCUIApplication) {
        XCTAssertTrue([2, 4, 8, 16].contains(count), "Unsupported image concurrency choice")
        open(in: app)
        let picker = app.segmentedControls["account.loading.concurrency"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let option = picker.buttons["\(count)"]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        for _ in 0..<5 {
            if option.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(option.isHittable, "Image concurrency choice should be reachable")
        option.tap()
        XCTAssertEqual(picker.value as? String, String(count))
    }

    static func chooseSitePageConcurrency(_ count: Int, in app: XCUIApplication) {
        XCTAssertTrue([1, 2, 4].contains(count), "Unsupported site page concurrency choice")
        open(in: app)
        let picker = app.segmentedControls["account.loading.site-concurrency"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let option = picker.buttons["\(count)"]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        for _ in 0..<5 {
            if option.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(option.isHittable, "Site page concurrency choice should be reachable")
        option.tap()
        XCTAssertEqual(picker.value as? String, String(count))
    }
}

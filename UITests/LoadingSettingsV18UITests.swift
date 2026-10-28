import XCTest

final class LoadingSettingsV18UITests: XCTestCase {
    func testAccountSliderAndBothConcurrencySettingsPersistIntoReader() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--screen", "account", "--qa-reset-reader-preferences"]
        app.launch()
        LoadingSettingsUIHelpers.setPrefetch(64, in: app)
        LoadingSettingsUIHelpers.chooseImageConcurrency(4, in: app)
        LoadingSettingsUIHelpers.chooseSitePageConcurrency(1, in: app)
        let settingsShot = XCTAttachment(screenshot: app.screenshot())
        settingsShot.name = "build18.account.loading-sliders"
        settingsShot.lifetime = .keepAlways; add(settingsShot)

        app.terminate()
        app.launchArguments = ["--qa", "--screen", "account"]
        app.launch()
        LoadingSettingsUIHelpers.open(in: app)
        XCTAssertEqual(LoadingSettingsUIHelpers.prefetchCount(in: app), 64)
        XCTAssertEqual(app.segmentedControls["account.loading.concurrency"].value as? String, "4")
        XCTAssertEqual(app.segmentedControls["account.loading.site-concurrency"].value as? String, "1")

        LoadingSettingsUIHelpers.returnToReader(in: app)
        let state = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 8))
        let applied = NSPredicate { _, _ in
            let value = state.value as? String ?? ""
            return value.contains("prefetch=64;") && value.contains("concurrency=4;")
        }
        expectation(for: applied, evaluatedWith: state); waitForExpectations(timeout: 8)
        XCTAssertFalse(app.buttons["reader.prefetch-menu"].exists)
        let close = app.buttons["reader.close"]
        XCTAssertTrue(close.exists && close.isHittable)
        XCTAssertLessThanOrEqual(close.frame.width, 45)
        XCTAssertLessThanOrEqual(close.frame.height, 45)
        let readerShot = XCTAttachment(screenshot: app.screenshot())
        readerShot.name = "build18.reader.small-clear-close"
        readerShot.lifetime = .keepAlways; add(readerShot)
    }

    func testNetworkPauseStopsAutomaticMetadataAndDoesNotBlockVisibleTurns() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--screen", "reader", "--qa-reset-reader-preferences",
                               "--qa-reader-transition", "--qa-reader-many", "--qa-reader-paging",
                               "--qa-reader-prefetch-timeout", "--qa-metadata-ms=3000"]
        app.launch()
        let page = app.buttons["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 12))
        let state = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 8))
        let stopped = NSPredicate { _, _ in
            let value = state.value as? String ?? ""
            return value.contains("automaticMetadata=false;") && value.contains("metadataLoading=false;")
        }
        expectation(for: stopped, evaluatedWith: state); waitForExpectations(timeout: 8)
        XCTAssertFalse(app.buttons["reader.prefetch-menu"].exists)
        app.buttons["reader.next"].tap()
        let second = NSPredicate { _, _ in page.label.hasSuffix("2 / 12") || page.label.hasSuffix("2 / 3") }
        expectation(for: second, evaluatedWith: page); waitForExpectations(timeout: 6)
        XCTAssertTrue(app.buttons["reader.close"].isHittable)
    }
}

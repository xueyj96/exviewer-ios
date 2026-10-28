import XCTest

final class ReaderNetworkV14UITests: XCTestCase {
    private func open(prefetch: Int, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-reader-many", "--qa-reader-transition"] + extra
        app.launch()
        LoadingSettingsUIHelpers.setPrefetch(prefetch, in: app)
        LoadingSettingsUIHelpers.returnToReader(in: app)
        return app
    }
    private func cacheContains(_ value: String, _ app: XCUIApplication) {
        let cache = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in (cache.value as? String)?.contains(value) == true }, evaluatedWith: cache)
        waitForExpectations(timeout: 20)
    }
    func testFailedPreloadRecoversWhenDraggedIntoView() {
        let app = open(prefetch: 2, extra: ["--qa-reader-prefetch-timeout", "--reader-network-metrics"])
        cacheContains("files=1,3;", app)
        app.coordinate(withNormalizedOffset: .init(dx: 0.75, dy: 0.5))
            .press(forDuration: 0.03, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.25, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.05)
        expectation(for: NSPredicate(format: "label == %@", "2 / 12"), evaluatedWith: app.buttons["reader.page"])
        waitForExpectations(timeout: 12)
        cacheContains("files=1,2", app)
        cacheContains("decoded=1,2", app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "reader14-recovered-next-page"; shot.lifetime = .keepAlways; add(shot)
    }
    func testPageMetadataPreloadsBeforeTheKnownBoundary() {
        let app = open(prefetch: 6, extra: ["--qa-reader-paging"])
        cacheContains("metadataCalls=1;metadataTask=false;", app)
        cacheContains("files=1,2,3,4,5,6,7;", app)
        XCTAssertEqual(app.buttons["reader.page"].label, "1 / 12", "Fetching the next page list must preserve reading position")
    }
    func testAccountPrefetchChangesApplyOnEachReaderOpening() {
        continueAfterFailure = false
        let app = open(prefetch: 6, extra: ["--qa-reader-paging", "--qa-metadata-ms=12000"])
        cacheContains("metadataCalls=1;", app)
        cacheContains("automaticMetadata=true;", app)
        LoadingSettingsUIHelpers.setPrefetch(0, in: app)
        LoadingSettingsUIHelpers.returnToReader(in: app)
        cacheContains("automaticMetadata=false;metadataLoading=false;", app)
        LoadingSettingsUIHelpers.setPrefetch(6, in: app)
        LoadingSettingsUIHelpers.returnToReader(in: app)
        // Account settings close the previous reader. A new reader owns a new
        // metadata cursor and must issue one request, without replaying the old one.
        cacheContains("metadataCalls=1;", app)
        cacheContains("files=1,2,3,4,5,6,7;", app)
        cacheContains("metadataCalls=1;metadataTask=false;automaticMetadata=false;", app)
        XCTAssertEqual(app.buttons["reader.page"].label, "1 / 12")
    }
}

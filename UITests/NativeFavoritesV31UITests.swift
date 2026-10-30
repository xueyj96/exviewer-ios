import XCTest

final class NativeFavoritesV31UITests: XCTestCase {
    private func detail(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa"] + extra; app.launch()
        let card = app.buttons["gallery.open.1"]; XCTAssertTrue(card.waitForExistence(timeout: 12)); card.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 8)); return app
    }
    private func open(_ app: XCUIApplication) {
        app.buttons["detail.site-favorite"].tap()
        XCTAssertTrue(app.buttons["favorite.editor.group.0"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.webViews.count, 0, "Routine favorite editing must use native controls")
    }
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<8 { if element.exists && element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testCancelDoesNotFavoriteAndLocalBookmarkLivesInMore() {
        let app = detail()
        XCTAssertTrue(app.buttons["detail.site-favorite"].label.contains("收藏到站点"))
        app.buttons["detail.more"].tap()
        let local = app.buttons["detail.local-bookmark"]; XCTAssertTrue(local.waitForExistence(timeout: 3)); local.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].label.contains("收藏到站点"))
        app.buttons["detail.more"].tap(); XCTAssertTrue(app.buttons["移除本机书签"].waitForExistence(timeout: 3)); app.buttons["移除本机书签"].tap()
        open(app); app.buttons["favorite.editor.group.1"].tap(); app.buttons["favorite.editor.cancel"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].label.contains("收藏到站点"))
        open(app); XCTAssertEqual(app.buttons["favorite.editor.group.1"].value as? String, "未选择")
        XCTAssertFalse(app.buttons["favorite.editor.save"].isEnabled)
        screenshot(app, "native-favorite.cancel-keeps-unfavorited")
    }
    func testNativeAddMoveNoteAndConfirmedRemovalUpdateDetailState() {
        let app = detail(); open(app)
        app.buttons["favorite.editor.group.1"].tap()
        let note = app.descendants(matching: .any)["favorite.editor.note"].firstMatch; reveal(app, note); note.tap(); note.typeText("Neutral saved note")
        app.buttons["favorite.editor.save"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["detail.site-favorite"].label.contains("待阅读"))
        open(app); XCTAssertEqual(app.buttons["favorite.editor.group.1"].value as? String, "已选择")
        let restoredNote = app.descendants(matching: .any)["favorite.editor.note"].firstMatch
        reveal(app, restoredNote); XCTAssertEqual(restoredNote.value as? String, "Neutral saved note")
        let destination = app.buttons["favorite.editor.group.2"]
        for _ in 0..<8 { if destination.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(destination.isHittable); destination.tap(); app.buttons["favorite.editor.save"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["detail.site-favorite"].label.contains("已读")); screenshot(app, "native-favorite.saved-detail")
        open(app); let remove = app.buttons["favorite.editor.remove"]; reveal(app, remove); remove.tap()
        let confirm = app.buttons["favorite.editor.confirm-remove"].firstMatch; XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["detail.site-favorite"].label.contains("收藏到站点"))
    }
    func testUnknownSubmissionKeepsSelectionAndRefreshOnlyConfirmsIt() {
        let app = detail(["--qa-favorite-unknown"]); open(app)
        app.buttons["favorite.editor.group.3"].tap(); app.buttons["favorite.editor.save"].tap()
        let error = app.staticTexts["favorite.editor.error"]; XCTAssertTrue(error.waitForExistence(timeout: 6))
        XCTAssertTrue(error.label.contains("尚未确认")); XCTAssertFalse(app.buttons["favorite.editor.save"].isEnabled)
        XCTAssertEqual(app.buttons["favorite.editor.group.3"].value as? String, "已选择")
        screenshot(app, "native-favorite.unknown-keeps-draft")
        app.buttons["favorite.editor.refresh"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["detail.site-favorite"].label.contains("画集"))
    }
    func testLostPostResponseIsReadBackAndDoesNotRequireResubmission() {
        let app = detail(["--qa-favorite-post-lost"]); open(app)
        app.buttons["favorite.editor.group.1"].tap(); app.buttons["favorite.editor.save"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["detail.site-favorite"].label.contains("待阅读")); XCTAssertEqual(app.webViews.count, 0)
    }
    func testExistingGroupAndNoteRemainEditableWithLargeTypeAndDarkAppearance() {
        let app = detail(["--qa-favorite-existing", "--qa-dark", "--qa-large-type"]); open(app)
        let group = app.buttons["favorite.editor.group.2"]
        XCTAssertEqual(group.value as? String, "已选择"); XCTAssertGreaterThanOrEqual(group.frame.height, 44)
        XCTAssertFalse(app.buttons["favorite.editor.save"].isEnabled)
        screenshot(app, "native-favorite.dark-large-groups")
        let note = app.descendants(matching: .any)["favorite.editor.note"].firstMatch; reveal(app, note)
        XCTAssertEqual(note.value as? String, "Existing neutral note")
        screenshot(app, "native-favorite.dark-large-existing-note")
        app.buttons["favorite.editor.cancel"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].label.contains("已读"))
    }
    func testInitialReadFailureOffersNativeReload() {
        let app = detail(["--qa-favorite-read-failure"]); app.buttons["detail.site-favorite"].tap()
        let reload = app.buttons["favorite.editor.refresh"]; XCTAssertTrue(reload.waitForExistence(timeout: 6)); reload.tap()
        XCTAssertTrue(app.buttons["favorite.editor.group.0"].waitForExistence(timeout: 6)); XCTAssertEqual(app.webViews.count, 0)
    }
    func testFavoriteListRefreshesAfterEditingFromAnotherTabAndFromItsOwnDetail() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-favorite-sync-list"]; app.launch()
        XCTAssertTrue(app.buttons["main.tab.library"].waitForExistence(timeout: 12)); app.buttons["main.tab.library"].tap()
        let empty = app.staticTexts["当前分组没有收藏结果。"]
        XCTAssertTrue(empty.waitForExistence(timeout: 6))
        app.buttons["main.tab.discover"].tap(); app.buttons["gallery.open.1"].tap(); open(app)
        app.buttons["favorite.editor.group.1"].tap(); app.buttons["favorite.editor.save"].tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6)); app.buttons["main.tab.library"].tap()
        let item = app.buttons["favorites.gallery.1"]; XCTAssertTrue(item.waitForExistence(timeout: 6)); item.tap(); open(app)
        let remove = app.buttons["favorite.editor.remove"]; reveal(app, remove); remove.tap()
        let confirm = app.buttons["favorite.editor.confirm-remove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.tap()
        XCTAssertTrue(app.buttons["detail.site-favorite"].waitForExistence(timeout: 6)); app.buttons["BackButton"].tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 6)); XCTAssertFalse(app.buttons["favorites.gallery.1"].exists)
    }
}

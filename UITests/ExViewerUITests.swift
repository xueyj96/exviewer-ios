import XCTest

final class ExViewerUITests: XCTestCase {
    private func launch(_ screen: String = "browse") -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--screen", screen]; app.launch(); return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.textFields[id].exists ? app.textFields[id] : app.textViews[id]
    }
    private func openComposer(_ app: XCUIApplication) -> XCUIElement {
        let entry = app.buttons["discover.search-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 12)); entry.tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        return field(app, "compose.text")
    }
    private func submit(_ app: XCUIApplication, text: String) {
        let input = openComposer(app); input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let current = input.value as? String, current != input.placeholderValue, !current.isEmpty {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        input.typeText(text); app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.navigationBars["组合搜索"].exists)
    }
    private func readThroughDetails(_ app: XCUIApplication) {
        let title = app.staticTexts["海岸线 · 插画与速写"]
        XCTAssertTrue(title.waitForExistence(timeout: 12)); title.tap()
        app.buttons["在线阅读"].tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
    }
    func testGalleryNavigationAndTags() {
        let app = launch()
        let title = app.staticTexts["海岸线 · 插画与速写"]
        XCTAssertTrue(title.waitForExistence(timeout: 15)); capture(app, "Native gallery list")
        title.tap()
        XCTAssertTrue(app.staticTexts["画廊详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["full color"].exists)
        capture(app, "Gallery details and real tag layout")
    }
    func testDiscoveryCombinesBrowsingAndTagSearch() {
        let app = launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 15))
        let compactTabs = app.descendants(matching: .any)["main.tabs.compact"].firstMatch
        XCTAssertTrue(compactTabs.waitForExistence(timeout: 15))
        XCTAssertEqual(compactTabs.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "main.tab.")).count, 3)
        app.segmentedControls.buttons["热门"].tap()
        app.staticTexts["海岸线 · 插画与速写"].tap()
        app.buttons["full color"].tap()
        XCTAssertTrue(app.buttons["包含 · other:full color  ×"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.navigationBars["画廊详情"].exists)
        app.buttons["discover.back"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["热门"].isSelected)
        capture(app, "Detail tag replaces discovery and returns to previous feed")
    }

    func testAnimationMovesWithoutChangingPageNumber() {
        let app = launch(); readThroughDetails(app)
        let image = app.otherElements["media.animated"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 12))
        let initial = image.value as? String
        let moved = NSPredicate { _, _ in (image.value as? String) != initial }
        expectation(for: moved, evaluatedWith: image); waitForExpectations(timeout: 4)
        XCTAssertEqual(app.buttons["reader.page"].label, "1 / 3")
        app.buttons["reader.direction"].tap(); app.buttons["从上到下 ↓"].tap()
        app.swipeUp()
        let changed = NSPredicate { _, _ in app.buttons["reader.page"].label != "1 / 3" }
        expectation(for: changed, evaluatedWith: app.buttons["reader.page"]); waitForExpectations(timeout: 6)
        capture(app, "Animated file is one page through real reading entry")
    }

    func testSaveAndReuseSearchCombination() {
        continueAfterFailure = false
        let app = launch()
        let input = openComposer(app); input.tap(); input.typeText("Landscape -other:watercolor")
        app.buttons["compose.filters"].tap()
        let artist = app.textFields["compose.artist"]; artist.tap(); artist.typeText("Mori")
        let titleScope = app.switches["关键词只匹配标题"]
        titleScope.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(titleScope.value as? String, "1")
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["排除 · other:watercolor  ×"].waitForExistence(timeout: 6))
        app.buttons["discover.save"].tap()
        let name = app.textFields["search.save.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let old = name.value as? String, old != name.placeholderValue { name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        name.typeText("Weekly art")
        app.buttons["search.save.confirm"].tap()
        let shortcut = app.buttons["载入组合编辑：Weekly art"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        submit(app, text: "Other")
        shortcut.tap()
        let restored = field(app, "compose.text")
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.value as? String, "Landscape")
        app.buttons["compose.filters"].tap()
        XCTAssertEqual(app.textFields["compose.artist"].value as? String, "Mori")
        XCTAssertEqual(app.switches["关键词只匹配标题"].value as? String, "1")
        app.buttons["BackButton"].tap()
        restored.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        restored.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Landscape".count))
        restored.typeText("Landscape edited")
        app.buttons["compose.save-favorite"].tap()
        XCTAssertTrue(app.navigationBars["编辑搜索组合"].waitForExistence(timeout: 5))
        app.buttons["search.save.confirm"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["compose.loaded-state"].firstMatch.value as? String, "已保存")
        app.buttons["compose.apply"].tap()
        shortcut.tap()
        let updated = field(app, "compose.text")
        XCTAssertTrue(updated.waitForExistence(timeout: 5))
        XCTAssertEqual(updated.value as? String, "Landscape edited")
        app.buttons["compose.cancel"].tap()
        capture(app, "Saved combination restores structured fields and updates explicitly")
    }

    func testTagBlockAndUndoAffectsNativeList() {
        let app = launch()
        let title = app.staticTexts["海岸线 · 插画与速写"]
        XCTAssertTrue(title.waitForExistence(timeout: 15)); title.tap()
        app.buttons["在线阅读"].tap()
        XCTAssertTrue(app.otherElements["media.animated"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["关闭"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["main.tab.library"].tap()
        app.segmentedControls["library.scope"].buttons["本机内容"].tap()
        XCTAssertTrue(app.staticTexts["海岸线 · 插画与速写"].waitForExistence(timeout: 5))
        app.buttons["main.tab.account"].tap()
        let tagSettings = app.buttons["account.tags"]
        XCTAssertTrue(tagSettings.waitForExistence(timeout: 5)); tagSettings.tap()
        let scope = app.segmentedControls.buttons["屏蔽标签"]
        XCTAssertTrue(scope.waitForExistence(timeout: 15)); scope.tap()
        app.buttons["tags.add"].tap()
        let tag = app.textFields["tag.name"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5)); tag.tap(); tag.typeText("full color")
        // The composer now starts in all namespaces. Choose the real local
        // dictionary candidate instead of relying on the old implicit "other".
        let candidate = app.buttons["tag.suggestion.other:full color"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 8)); candidate.tap()
        app.buttons["tag.confirm"].tap()
        app.buttons["main.tab.discover"].tap()
        let hidden = app.staticTexts["当前结果已被本机标签屏蔽。可到账号的「标签与屏蔽」调整。"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        app.buttons["main.tab.library"].tap()
        app.segmentedControls["library.scope"].buttons["本机内容"].tap()
        XCTAssertFalse(app.staticTexts["海岸线 · 插画与速写"].exists)
        app.buttons["main.tab.account"].tap()
        app.buttons["撤销"].tap()
        app.buttons["main.tab.discover"].tap()
        XCTAssertTrue(app.staticTexts["海岸线 · 插画与速写"].waitForExistence(timeout: 5))
    }
    func testAccountSeparatesSessionAndEXVerification() {
        let app = launch("account")
        XCTAssertTrue(app.buttons["account.login-management"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["登录"].exists)
        XCTAssertTrue(app.staticTexts["尚未取得当前额度"].exists)
        capture(app, "Compact account and separate site states")
        app.buttons["account.login-management"].tap()
        XCTAssertTrue(app.buttons["重新登录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["验证当前会话"].exists)
        XCTAssertFalse(app.buttons["account.ex-web"].exists)
        capture(app, "Login management and independent EX verification")
    }
    func testSiteFavoritesAndManualStoragePolicy() {
        let app = launch()
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(app.segmentedControls["library.scope"].buttons["站点收藏"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["海岸线 · 插画与速写"].exists)
        app.segmentedControls["library.scope"].buttons["本机内容"].tap()
        XCTAssertTrue(app.staticTexts["按设备可用空间保存，切到后台会暂停；下载内容不参与浏览缓存清理。"].waitForExistence(timeout: 5))
        capture(app, "Durable manual downloads outside browse cache")
    }
    func testWebViewSrcdocAndJavaScriptCompatibility() {
        let app = launch("web-compat")
        XCTAssertTrue(app.staticTexts["子页面兼容检查通过"].waitForExistence(timeout: 15))
        capture(app, "Local srcdoc frame and JavaScript compatibility")
    }
    func testFavoritesMultiSelectRequiresExplicitConfirmation() {
        let app = launch()
        app.buttons["main.tab.library"].tap()
        let first = app.buttons["favorites.gallery.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5))
        app.buttons["favorites.select.2"].tap()
        XCTAssertTrue(app.staticTexts["已选 2 项"].exists)
        app.buttons["favorites.remove"].tap()
        XCTAssertTrue(app.buttons["移除所选收藏"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["已选 2 项"].exists)
        app.buttons["favorites.move"].tap(); app.buttons["稍后阅读"].tap()
        app.buttons["确认移动"].tap()
        XCTAssertTrue(app.staticTexts["测试模式仅检查多选交互，未修改站点收藏。"].waitForExistence(timeout: 5))
        capture(app, "Favorites selection and explicit batch confirmation")
    }
    func testFeedLoadsNextBatchWhenScrollingDown() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-feed-paging", "--qa-reset-reader-preferences"]; app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        // Different feeds intentionally reuse the same fixture title. Bind to
        // each active feed's gallery control instead of a cached hidden label.
        func continueByScrolling(_ next: XCUIElement) {
            XCTAssertFalse(next.exists, "The app must not traverse unseen pages before scrolling")
            for _ in 0..<6 { if next.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            XCTAssertTrue(next.isHittable)
        }
        continueByScrolling(app.scrollViews["discover.feed"].buttons["gallery.open.101"])
        capture(app, "Discovery appends after actual downward browsing")
        submit(app, text: "Neutral query")
        XCTAssertTrue(app.staticTexts["已执行：EX · Neutral query"].waitForExistence(timeout: 5))
        let firstSearchResult = app.scrollViews["discover.feed"].buttons["gallery.open.1"]
        expectation(for: NSPredicate { _, _ in firstSearchResult.isHittable }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        continueByScrolling(app.scrollViews["discover.feed"].buttons["gallery.open.101"])
        capture(app, "Search results append in the same feed")
        app.buttons["main.tab.library"].tap()
        XCTAssertTrue(app.buttons["favorites.gallery.1"].waitForExistence(timeout: 10))
        continueByScrolling(app.buttons["favorites.gallery.101"])
        capture(app, "Favorites append after actual downward browsing")
    }
    func testInlineTagsBecomeSearchConditions() {
        let app = launch()
        submit(app, text: "title:Autumn language:chinese -other:city")
        XCTAssertTrue(app.buttons["包含 · language:chinese  ×"].exists)
        XCTAssertTrue(app.buttons["排除 · other:city  ×"].exists)
        let input = openComposer(app)
        XCTAssertEqual(input.value as? String, "Autumn")
        XCTAssertEqual(app.switches["关键词只匹配标题"].value as? String, "1")
        app.buttons["compose.cancel"].tap()
        capture(app, "Inline syntax remains compatible in combination input")
    }

    func testQuotaAndSponsorshipUseNativePages() {
        let app = launch("account")
        let quota = app.buttons["account.quota"]
        for _ in 0..<4 { if quota.isHittable { break }; app.swipeUp() }
        quota.tap()
        XCTAssertTrue(app.navigationBars["看图额度"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let sponsorship = app.buttons["account.sponsorship"]
        for _ in 0..<4 { if sponsorship.isHittable { break }; app.swipeUp() }
        sponsorship.tap()
        XCTAssertTrue(app.navigationBars["赞助与权益"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
        capture(app, "Native account quota and sponsorship pages")
    }
    func testLandscapeCoverUsesItsOwnAspectRatio() {
        let app = launch()
        let portrait = app.descendants(matching: .any)["gallery.cover.1"].firstMatch
        let landscape = app.descendants(matching: .any)["gallery.cover.2"].firstMatch
        XCTAssertTrue(portrait.waitForExistence(timeout: 10)); XCTAssertTrue(landscape.exists)
        let differentHeights = NSPredicate { _, _ in portrait.frame.height > landscape.frame.height * 1.5 }
        expectation(for: differentHeights, evaluatedWith: portrait); waitForExpectations(timeout: 5)
        capture(app, "Landscape and portrait covers retain natural aspect ratios")
    }
    func testComposerCancellationAndCompactCategoryGrid() {
        let app = launch()
        XCTAssertFalse(app.staticTexts["保存的组合会显示在这里"].exists)
        let input = openComposer(app); input.tap(); input.typeText("Cancelled draft")
        let first = app.buttons["compose.category.2"], second = app.buttons["compose.category.4"]
        for _ in 0..<5 { if first.isHittable && second.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(first.isHittable); XCTAssertTrue(second.isHittable)
        XCTAssertLessThan(abs(first.frame.minY - second.frame.minY), 4)
        XCTAssertGreaterThan(abs(first.frame.minX - second.frame.minX), 30)
        first.tap(); capture(app, "Compact category chips in real search composer")
        app.buttons["compose.cancel"].tap()
        XCTAssertFalse(app.buttons["discover.back"].exists)
        let reopened = openComposer(app)
        XCTAssertFalse((reopened.value as? String ?? "").contains("Cancelled draft"))
        for _ in 0..<5 { if first.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(first.value as? String, "已选择")
        app.buttons["compose.cancel"].tap()
    }
    func testMultipleSearchesReturnToPagedBrowsingAndScrollAnchor() {
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-feed-paging", "--qa-reset-reader-preferences"]; app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        let secondBatch = app.staticTexts["第二批 · 山间笔记"]
        for _ in 0..<6 { if secondBatch.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(secondBatch.isHittable)
        capture(app, "Paged browsing anchor before new conditions")
        submit(app, text: "First query")
        submit(app, text: "Second query")
        app.buttons["discover.back"].tap()
        let restored = openComposer(app)
        XCTAssertEqual(restored.value as? String, "First query")
        app.buttons["compose.cancel"].tap()
        app.buttons["discover.back"].tap()
        let anchorRestored = NSPredicate { _, _ in secondBatch.isHittable }
        expectation(for: anchorRestored, evaluatedWith: secondBatch); waitForExpectations(timeout: 6)
        XCTAssertFalse(app.buttons["discover.back"].exists)
        capture(app, "Multi-level return restores paged browsing anchor")
    }
    func testCardsUseNaturalTitleHeightAndOmitMissingMetadata() {
        let app = XCUIApplication(); app.launchArguments = ["--qa", "--qa-layout-cases", "--qa-reset-reader-preferences"]; app.launch()
        let short = app.descendants(matching: .any)["gallery.title.1"].firstMatch
        let long = app.descendants(matching: .any)["gallery.title.2"].firstMatch
        let metadata = app.descendants(matching: .any)["gallery.metadata.1"].firstMatch
        XCTAssertTrue(short.waitForExistence(timeout: 12)); XCTAssertTrue(long.exists); XCTAssertTrue(metadata.exists)
        XCTAssertLessThan(short.frame.height, long.frame.height)
        XCTAssertLessThanOrEqual(metadata.frame.minY - short.frame.maxY, 14)
        for _ in 0..<4 { if app.staticTexts["缺少元数据"].isHittable { break }; app.swipeUp() }
        XCTAssertFalse(app.descendants(matching: .any)["gallery.metadata.3"].firstMatch.exists)
        capture(app, "Short and long title spacing with missing metadata")
    }
    func testGalleryDetailUsesOneCompactActionRow() {
        let app = launch()
        let title = app.staticTexts["海岸线 · 插画与速写"]
        XCTAssertTrue(title.waitForExistence(timeout: 12)); title.tap()
        let read = app.buttons["在线阅读"], favorite = app.buttons["detail.site-favorite"], more = app.buttons["detail.more"]
        XCTAssertTrue(read.waitForExistence(timeout: 8))
        XCTAssertLessThan(abs(read.frame.midY - favorite.frame.midY), 6)
        XCTAssertLessThan(abs(read.frame.midY - more.frame.midY), 6)
        XCTAssertGreaterThanOrEqual(favorite.frame.height, 44)
        XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        XCTAssertTrue(app.staticTexts["作者 · preview studio"].exists)
        XCTAssertTrue(app.staticTexts["上传者 · Preview Studio"].exists)
        capture(app, "Compact detail actions and readable gallery metadata")
    }

}

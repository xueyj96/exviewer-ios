import XCTest

final class TagSuggestionsV9UITests: XCTestCase {
    private func launch(_ arguments: [String] = [], accessibilityTextSize: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences"] + arguments
        if accessibilityTextSize {
            app.launchArguments += ["--qa-large-type"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        return app
    }

    private func openTagEntry(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        let addTag = app.buttons["compose.add-tag"]
        for _ in 0..<5 { if addTag.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(addTag.isHittable)
        addTag.tap()
        XCTAssertTrue(app.navigationBars["添加标签"].waitForExistence(timeout: 5))
        return app.textFields["tag.name"]
    }

    func testDefaultAllFindsChineseNameOnlyInLocalDictionary() {
        let app = launch(["--qa-tags-offline"])
        let input = openTagEntry(app)
        XCTAssertTrue(app.buttons["tag.namespace.all"].isSelected)
        input.tap(); input.typeText("英语")

        let candidate = app.buttons["tag.suggestion.language:english"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 12))
        XCTAssertTrue((candidate.value as? String ?? "").contains("词库匹配，站点未验证"))
        XCTAssertFalse((candidate.value as? String ?? "").contains("E-Hentai 站点候选"))
        input.typeText("\n")
        let source = app.descendants(matching: .any)["tag.dictionary-disclosure"].firstMatch
        for _ in 0..<5 { if source.isHittable { break }; app.swipeUp() }
        source.tap()
        XCTAssertTrue(app.staticTexts["tag.dictionary-info"].label.contains("非全站标签目录"))
        XCTAssertTrue(app.staticTexts["tag.dictionary-info"].label.contains("v7.29356.1"))
    }

    func testLanguageQAFixtureSelectionAddsRuleWithExplicitFixtureStatus() {
        let app = launch(["--qa-tags-delayed"])
        let input = openTagEntry(app)
        app.buttons["tag.namespace.language"].tap()
        input.tap(); input.typeText("eng")

        let candidate = app.buttons["tag.suggestion.language:english"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 12))
        expectation(for: NSPredicate { _, _ in (candidate.value as? String ?? "").contains("QA 样例") }, evaluatedWith: candidate)
        waitForExpectations(timeout: 8)
        candidate.tap()
        let pendingStatus = app.staticTexts["tag.pending.status.language:english"]
        XCTAssertTrue(pendingStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(pendingStatus.label.contains("QA 样例，非真实站点匹配"))
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成，1 个标签")
        app.buttons["tag.confirm"].tap()

        XCTAssertTrue(app.staticTexts["language:english"].waitForExistence(timeout: 5))
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["包含 · language:english  ×"].waitForExistence(timeout: 8))
    }

    func testUnknownFreeTextRequiresExplicitUnverifiedAction() {
        let app = launch(["--qa-tags-offline"])
        let input = openTagEntry(app)
        app.buttons["tag.namespace.language"].tap()
        input.tap(); input.typeText("zz-no-real-tag")

        XCTAssertTrue(app.staticTexts["tag.no-results"].waitForExistence(timeout: 8))
        let add = app.buttons["tag.stage"]
        XCTAssertEqual(add.label, "添加未验证标签")
        add.tap()
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成，1 个标签")
        app.buttons["tag.confirm"].tap()
        XCTAssertTrue(app.staticTexts["language:zz-no-real-tag"].waitForExistence(timeout: 5))
        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["包含 · language:zz-no-real-tag  ×"].waitForExistence(timeout: 8))
    }

    func testDelayedOldSuggestionDoesNotReturnAfterInputChanges() {
        let app = launch(["--qa-tags-delayed"])
        let input = openTagEntry(app)
        app.buttons["tag.namespace.language"].tap()
        input.tap(); input.typeText("eng")
        let stale = app.buttons["tag.suggestion.language:english"]
        XCTAssertTrue(stale.waitForExistence(timeout: 5), "The local raw-name match should appear before the delayed QA response")
        input.tap(); input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3)); input.typeText("zz-no-match")

        let disappeared = NSPredicate { _, _ in !stale.exists }
        expectation(for: disappeared, evaluatedWith: stale)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(app.staticTexts["tag.no-results"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.7)
        XCTAssertFalse(stale.exists, "The delayed response for the old prefix must not repopulate the new input")
        XCTAssertEqual(app.buttons["tag.stage"].label, "添加未验证标签")
    }

    func testLongChineseCandidateRemainsTouchableAtAccessibilityTextSize() {
        let app = launch(["--qa-tags-offline"], accessibilityTextSize: true)
        let input = openTagEntry(app)
        input.tap(); input.typeText("danshi koukousei de urekko light novel")
        input.typeText("\n")

        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tag.suggestion.parody:"))
        let candidate = candidates.firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 12))
        for _ in 0..<4 { if candidate.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(candidate.isHittable)
        XCTAssertGreaterThanOrEqual(candidate.frame.height, 44)
        XCTAssertTrue(candidate.label.contains("身为男高中生") || candidate.label.contains("男高中生兼当红"))
        candidate.tap()
        let pendingStatus = app.staticTexts["tag.pending.status.parody:danshi koukousei de urekko light novel"]
        XCTAssertTrue(pendingStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(pendingStatus.label.contains("词库匹配，站点未验证"))
    }
}

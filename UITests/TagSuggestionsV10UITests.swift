import XCTest

final class TagSuggestionsV10UITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-tags-offline"]
        app.launchArguments += (ProcessInfo.processInfo.environment["EXVIEWER_VISUAL_ARGS"] ?? "").split(separator: " ").map(String.init)
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        let addTag = app.buttons["compose.add-tag"]
        for _ in 0..<5 { if addTag.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(addTag.isHittable)
        addTag.tap()
        XCTAssertTrue(app.navigationBars["添加标签"].waitForExistence(timeout: 5))
        return app
    }

    private func selectNamespace(_ app: XCUIApplication, _ namespace: String) {
        let target = app.buttons["tag.namespace.\(namespace)"]
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tag.namespace."))
        for leftward in [true, false] {
            for _ in 0..<6 {
                if target.exists && target.isHittable {
                    target.tap(); XCTAssertTrue(target.isSelected); return
                }
                guard let chip = chips.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) else {
                    app.swipeDown(); continue
                }
                let y = (chip.frame.midY - app.frame.minY) / app.frame.height
                let start = app.coordinate(withNormalizedOffset: .init(dx: leftward ? 0.82 : 0.18, dy: y))
                let end = app.coordinate(withNormalizedOffset: .init(dx: leftward ? 0.18 : 0.82, dy: y))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            }
        }
        XCTAssertTrue(target.exists && target.isHittable, "Namespace must be visible after actual scrolling")
        target.tap(); XCTAssertTrue(target.isSelected)
    }

    @discardableResult
    private func stage(_ app: XCUIApplication, namespace: String, value: String, match: String, fixtureID: String? = nil) -> String {
        selectNamespace(app, namespace)
        let mode = app.segmentedControls["tag.match"]
        mode.buttons[match].tap()
        let input = app.textFields["tag.name"]
        input.tap()
        let priorText = input.value as? String ?? ""
        if !priorText.isEmpty {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: priorText.count))
        }
        input.typeText(value)
        input.typeText("\n")
        let tagID = fixtureID ?? "\(namespace):\(value)"
        if fixtureID != nil {
            let candidate = app.buttons["tag.suggestion.\(tagID)"]
            XCTAssertTrue(candidate.waitForExistence(timeout: 8))
            candidate.tap()
            XCTAssertTrue(app.buttons["tag.pending.remove.\(tagID)"].waitForExistence(timeout: 5))
        } else {
            XCTAssertTrue(app.staticTexts["tag.no-results"].waitForExistence(timeout: 8))
            let add = app.buttons["tag.stage"]
            for _ in 0..<4 { if add.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(add.isHittable)
            add.tap()
        }
        return tagID
    }

    func testThreeTagsStayInOnePanelCanMixModesRemoveAndSubmitTogether() {
        let app = launch()
        let english = stage(app, namespace: "language", value: "eng", match: "包含", fixtureID: "language:english")
        XCTAssertTrue(app.buttons["tag.pending.remove.\(english)"].waitForExistence(timeout: 5))

        let artist = stage(app, namespace: "artist", value: "preview", match: "任一", fixtureID: "artist:preview")
        XCTAssertTrue(app.buttons["tag.pending.remove.\(artist)"].waitForExistence(timeout: 5))

        let unknown = stage(app, namespace: "other", value: "local-only-tag", match: "排除")
        XCTAssertTrue(app.buttons["tag.pending.remove.\(unknown)"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成，3 个标签")

        if app.keyboards.count > 0 { app.textFields["tag.name"].typeText("\n") }
        let removeEnglish = app.buttons["tag.pending.remove.\(english)"]
        for _ in 0..<8 {
            if removeEnglish.isHittable { break }
            if removeEnglish.frame.midY < app.frame.midY { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(removeEnglish.isHittable)
        let pendingShot = XCTAttachment(screenshot: app.screenshot())
        pendingShot.name = "build10.tags.pending3"; pendingShot.lifetime = .keepAlways; add(pendingShot)
        removeEnglish.tap()
        XCTAssertFalse(app.buttons["tag.pending.remove.\(english)"].exists)
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成，2 个标签")
        app.buttons["tag.confirm"].tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))

        app.buttons["compose.apply"].tap()
        XCTAssertTrue(app.buttons["任一 · artist:preview  ×"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["排除 · other:local-only-tag  ×"].exists)
        XCTAssertFalse(app.buttons["包含 · language:english  ×"].exists)
    }

    func testCancelDropsEveryPendingTagWithoutChangingComposerDraft() {
        let app = launch()
        stage(app, namespace: "language", value: "eng", match: "包含", fixtureID: "language:english")
        stage(app, namespace: "other", value: "cancel-me", match: "排除")
        app.buttons["tag.cancel"].tap()

        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["language:english"].exists)
        XCTAssertFalse(app.staticTexts["other:cancel-me"].exists)
        app.buttons["compose.cancel"].tap()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 5))
    }
}

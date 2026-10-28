import XCTest

final class TagSuggestionsV12UITests: XCTestCase {
    private func openComposer() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-tags-offline"]
        app.launch()
        XCTAssertTrue(app.buttons["discover.search-entry"].waitForExistence(timeout: 12))
        app.buttons["discover.search-entry"].tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        let add = app.buttons["compose.add-tag"]
        for _ in 0..<5 { if add.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(add.isHittable)
        add.tap()
        XCTAssertTrue(app.navigationBars["添加标签"].waitForExistence(timeout: 5))
        selectNamespace(app, "parody")
        return app
    }

    private func selectNamespace(_ app: XCUIApplication, _ namespace: String) {
        let target = app.buttons["tag.namespace.\(namespace)"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tag.namespace."))
        for leftward in [true, false] {
            for _ in 0..<6 {
                if target.isHittable { target.tap(); return }
                guard let chip = chips.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) else {
                    app.swipeDown(); continue
                }
                let y = (chip.frame.midY - app.frame.minY) / app.frame.height
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: leftward ? 0.82 : 0.18, dy: y))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: leftward ? 0.18 : 0.82, dy: y))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            }
        }
        XCTAssertTrue(target.isHittable, "Namespace must be visible after actual scrolling")
        target.tap()
    }

    private func typePrefix(_ app: XCUIApplication) {
        let input = app.textFields["tag.name"]
        input.tap()
        input.typeText("pre")
        input.typeText("\n")
    }

    private func tapCandidate(_ app: XCUIApplication, id: String) {
        let candidate = app.buttons["tag.suggestion.\(id)"]
        // Form virtualizes off-screen rows; a broad prefix has up to20 results.
        // Exercise scrolling to the actual candidate rather than waiting for an
        // off-screen accessibility node that has not been materialized yet.
        for _ in 0..<8 {
            if candidate.exists && candidate.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(candidate.exists && candidate.isHittable, "Expected reachable dictionary candidate \(id)")
        XCTAssertTrue((candidate.value as? String ?? "").contains("词库匹配，站点未验证"))
        candidate.tap()
        XCTAssertTrue((candidate.value as? String ?? "").contains("已加入待添加"))
        XCTAssertTrue(app.navigationBars["添加标签"].exists)
    }

    func testSamePrefixCanSelectTwoCandidatesThenCompleteToComposerDraft() {
        let app = openComposer()
        typePrefix(app)
        tapCandidate(app, id: "parody:pretty cure")

        let mode = app.segmentedControls["tag.match"]
        for _ in 0..<8 { if mode.exists && mode.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(mode.isHittable)
        XCTAssertEqual(app.textFields["tag.name"].value as? String, "pre", "Candidate selection must retain the original prefix")
        mode.buttons["任一"].tap()
        tapCandidate(app, id: "parody:pretty rhythm")
        XCTAssertEqual(app.buttons["tag.confirm"].label, "完成，2 个标签")

        app.buttons["tag.confirm"].tap()
        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["parody:pretty cure"].exists)
        XCTAssertTrue(app.staticTexts["parody:pretty rhythm"].exists)
        XCTAssertTrue(app.staticTexts["包含"].exists)
        XCTAssertTrue(app.staticTexts["任一"].exists)
        // Deliberately leave the composer open: tag selection edits only its draft.
    }

    func testCancelAfterSamePrefixMultiSelectLeavesComposerDraftEmpty() {
        let app = openComposer()
        typePrefix(app)
        tapCandidate(app, id: "parody:pretty cure")
        tapCandidate(app, id: "parody:pretty rhythm")
        app.buttons["tag.cancel"].tap()

        XCTAssertTrue(app.navigationBars["组合搜索"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["parody:pretty cure"].exists)
        XCTAssertFalse(app.staticTexts["parody:pretty rhythm"].exists)
        app.buttons["compose.cancel"].tap()
    }
}

import XCTest

final class ReaderPositionV35UITests: XCTestCase {
    private struct Pose {
        let viewport: CGRect
        let image: CGRect
        let zoom: CGFloat
        let offset: CGPoint
        let identity: String
    }

    private func openReader(transition: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-reader-many"] +
            (transition ? ["--qa-reader-transition", "--qa-prefetch=2"] : ["--qa-reader-long-page"])
        app.launch()
        let gallery = app.buttons["gallery.open.1"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 12)); gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8)); read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 10))
        return app
    }

    private func point(_ app: XCUIApplication, _ x: CGFloat = 0.5, _ y: CGFloat = 0.5) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .init(dx: x, dy: y))
    }

    private func media(_ app: XCUIApplication, file: String) -> XCUIElement {
        let images = app.otherElements.matching(identifier: "media.static")
        expectation(for: NSPredicate { _, _ in images.allElementsBoundByIndex.contains { ($0.value as? String ?? "").contains(file) && $0.frame.intersects(app.frame) } }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        return images.allElementsBoundByIndex.first { ($0.value as? String ?? "").contains(file) && $0.frame.intersects(app.frame) }!
    }

    private func pose(_ element: XCUIElement) -> Pose {
        let raw = element.value as? String ?? ""
        let fields = Dictionary(uniqueKeysWithValues: raw.split(separator: ";").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            return (pair[0].trimmingCharacters(in: .whitespaces), String(pair[1]))
        })
        func values(_ key: String, count: Int) -> [CGFloat] {
            let result = (fields[key] ?? "").split(separator: ",").compactMap { Double($0).map { CGFloat($0) } }
            XCTAssertEqual(result.count, count, raw)
            return result.count == count ? result : Array(repeating: .nan, count: count)
        }
        func rect(_ key: String) -> CGRect { let v = values(key, count: 4); return CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
        let offset = values("scrollOffset", count: 2)
        return Pose(viewport: rect("viewport"), image: rect("imageRect"), zoom: values("zoomScale", count: 1)[0],
                    offset: .init(x: offset[0], y: offset[1]), identity: fields["canvas"] ?? "")
    }

    private func same(_ actual: Pose, _ expected: Pose, label: String) {
        for (a, b) in zip([actual.viewport.minX, actual.viewport.minY, actual.viewport.width, actual.viewport.height,
                           actual.image.minX, actual.image.minY, actual.image.width, actual.image.height,
                           actual.zoom, actual.offset.x, actual.offset.y],
                          [expected.viewport.minX, expected.viewport.minY, expected.viewport.width, expected.viewport.height,
                           expected.image.minX, expected.image.minY, expected.image.width, expected.image.height,
                           expected.zoom, expected.offset.x, expected.offset.y]) {
            XCTAssertEqual(a, b, accuracy: 0.5, label)
        }
        XCTAssertEqual(actual.identity, expected.identity, "Toggling chrome must keep the same decoded canvas")
        print("READER35_POSE \(label);viewport=\(actual.viewport);image=\(actual.image);zoom=\(actual.zoom);offset=\(actual.offset);canvas=\(actual.identity)")
    }

    private func toggle(_ app: XCUIApplication, shown: Bool) {
        point(app).press(forDuration: 0.7)
        let header = app.descendants(matching: .any)["reader.header"].firstMatch
        expectation(for: NSPredicate { _, _ in header.exists == shown }, evaluatedWith: app)
        waitForExpectations(timeout: 4)
        let system = app.descendants(matching: .any)["reader.system.chrome.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in (system.value as? String ?? "").hasPrefix("hidden=\(!shown);") }, evaluatedWith: system)
        waitForExpectations(timeout: 4)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testFittedImageUsesTheWholeScreenAndDoesNotMoveWhenChromeToggles() {
        let app = openReader()
        let image = media(app, file: "reader-v11-page-1.png")
        let initial = pose(image)
        XCTAssertEqual(initial.viewport, app.frame)
        XCTAssertEqual(initial.image.midX, app.frame.midX, accuracy: 0.5)
        XCTAssertEqual(initial.image.midY, app.frame.midY, accuracy: 0.5)
        capture(app, "reader35.centered-normal")
        for iteration in 1...2 {
            toggle(app, shown: false)
            same(pose(image), initial, label: "fit.immersive.\(iteration)")
            capture(app, "reader35.centered-immersive.\(iteration)")
            toggle(app, shown: true)
            same(pose(image), initial, label: "fit.restored.\(iteration)")
        }
    }

    func testZoomAndPanStayAtTheSameScreenPositionWhenChromeToggles() {
        let app = openReader()
        let image = media(app, file: "reader-v11-page-1.png")
        point(app, 0.18, 0.38).doubleTap()
        expectation(for: NSPredicate { _, _ in (image.value as? String ?? "").contains("zoomed") }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        point(app, 0.65, 0.60).press(forDuration: 0.03, thenDragTo: point(app, 0.45, 0.52), withVelocity: .slow, thenHoldForDuration: 0.5)
        let initial = pose(image)
        XCTAssertGreaterThan(initial.zoom, 1)
        toggle(app, shown: false)
        same(pose(image), initial, label: "zoom.immersive")
        capture(app, "reader35.zoomed-immersive")
        toggle(app, shown: true)
        same(pose(image), initial, label: "zoom.restored")
    }

    func testContinuousLongPageKeepsItsScrolledPositionWhenChromeToggles() {
        let app = openReader(transition: false)
        app.buttons["reader.mode"].tap(); app.buttons["单页模式"].tap()
        app.buttons["reader.direction"].tap(); app.buttons["从上到下 ↓"].tap()
        point(app, 0.64, 0.82).tap()
        _ = media(app, file: "reader-v9-long-2.png")
        app.buttons["reader.mode"].tap(); app.buttons["连续模式"].tap()
        // Mode changes create a new canvas. Resolve it again and enter the
        // long page using visible gestures before measuring position.
        for attempt in 1...4 {
            let position = pose(media(app, file: "reader-v9-long-2.png")).image.minY
            print("READER35_SCROLL_SETUP attempt=\(attempt);longPageMinY=\(position)")
            if position < -20 { break }
            point(app, 0.60, 0.82).press(forDuration: 0.03, thenDragTo: point(app, 0.60, 0.25), withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        let image = media(app, file: "reader-v9-long-2.png")
        let initial = pose(image)
        XCTAssertGreaterThan(initial.image.height, app.frame.height)
        XCTAssertLessThan(initial.image.minY, -20, "Exercise a real position inside the long page")
        toggle(app, shown: false)
        same(pose(image), initial, label: "continuous.immersive")
        capture(app, "reader35.continuous-immersive")
        toggle(app, shown: true)
        same(pose(image), initial, label: "continuous.restored")
    }
}

import XCTest
import UIKit

final class ReaderV11UITests: XCTestCase {
    private func launch(prefetch: Int, delay: Int = 0, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--qa", "--qa-reset-reader-preferences", "--qa-reader-many", "--qa-reader-transition", "--qa-prefetch=\(prefetch)", "--qa-transfer-ms=\(delay)"] + arguments
        app.launch()
        let gallery = app.staticTexts["海岸线 · 插画与速写"].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 12)); gallery.tap()
        let read = app.buttons["在线阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 8)); read.tap()
        XCTAssertTrue(app.buttons["reader.page"].waitForExistence(timeout: 12))
        waitForCache("files=1", app)
        return app
    }
    private func waitForCache(_ value: String, _ app: XCUIApplication) {
        let cache = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in (cache.value as? String)?.contains(value) == true }, evaluatedWith: cache)
        waitForExpectations(timeout: 12)
    }
    private func waitForCachedPages(_ required: Set<Int>, _ app: XCUIApplication) {
        let cache = app.descendants(matching: .any)["reader.cache.qa"].firstMatch
        expectation(for: NSPredicate { _, _ in
            let diagnostic = cache.value as? String ?? ""
            let field = diagnostic.components(separatedBy: ";").first { $0.hasPrefix("files=") } ?? "files="
            let loaded = Set(field.dropFirst(6).split(separator: ",").compactMap { Int($0) })
            return required.isSubset(of: loaded)
        }, evaluatedWith: cache)
        waitForExpectations(timeout: 12)
    }
    private func waitForPage(_ value: String, _ app: XCUIApplication) {
        let page = app.buttons["reader.page"]
        expectation(for: NSPredicate { _, _ in page.label == value }, evaluatedWith: page)
        waitForExpectations(timeout: 12)
    }
    private func drag(_ app: XCUIApplication, from: CGVector = .init(dx: 0.72, dy: 0.5), to: CGVector = .init(dx: 0.28, dy: 0.5), velocity: XCUIGestureVelocity = .fast, hold: TimeInterval = 0.02) {
        app.coordinate(withNormalizedOffset: from).press(forDuration: 0.03, thenDragTo: app.coordinate(withNormalizedOffset: to), withVelocity: velocity, thenHoldForDuration: hold)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func visibleColorFraction(_ app: XCUIApplication) -> Double {
        let image = app.screenshot().image.cgImage!
        let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch.frame
        let scale = CGFloat(image.width) / app.frame.width
        let region = CGRect(x: canvas.minX, y: canvas.minY + canvas.height * 0.35, width: canvas.width, height: canvas.height * 0.30)
            .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        let crop = image.cropping(to: region)!
        var pixels = [UInt8](repeating: 0, count: 80 * 40 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 80 * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let bright = stride(from: 0, to: pixels.count, by: 4).filter { max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > 70 }.count
        return Double(bright) / Double(80 * 40)
    }
    private func checkSlowTarget(prefetch: Int) {
        let app = launch(prefetch: prefetch, delay: prefetch == 0 ? 6000 : 9000)
        waitForCache("files=1;", app)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        print("READER11_SLOW_DRAG_BEGIN \(Date().timeIntervalSince1970)")
        drag(app)
        capture(app, "reader11.slow-target.after-release")
        let visible = visibleColorFraction(app)
        print("READER11_SLOW_AFTER_RELEASE \(Date().timeIntervalSince1970) colorFraction=\(visible)")
        XCTAssertGreaterThan(visible, 0.4, "Current or target real image must remain visible while target is slow")
        waitForPage("2 / 12", app)
        waitForCachedPages([1, 2], app)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        capture(app, "reader11.slow-target.complete")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }
    func testSlowTargetKeepsARealImageVisibleUntilItCanFinish() { checkSlowTarget(prefetch: 0) }
    func testSlowTargetWithTwoPrefetchKeepsARealImageVisible() { checkSlowTarget(prefetch: 2) }
    func testSlowTargetWithSixPrefetchKeepsARealImageVisible() { checkSlowTarget(prefetch: 6) }

    private func presentation(_ page: Int, _ app: XCUIApplication) -> String? {
        let value = app.descendants(matching: .any)["reader.cache.qa"].firstMatch.value as? String ?? ""
        guard let suffix = value.components(separatedBy: ";presentations=").last else { return nil }
        return suffix.components(separatedBy: ",").first { $0.hasPrefix("\(page):") }
    }
    private func checkCachedHandoff(prefetch: Int) {
        let app = launch(prefetch: prefetch)
        drag(app); waitForPage("2 / 12", app)
        let identity = presentation(2, app)
        XCTAssertNotNil(identity); XCTAssertTrue(identity?.hasSuffix(":1") == true)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        drag(app, from: .init(dx: 0.28, dy: 0.5), to: .init(dx: 0.72, dy: 0.5))
        waitForPage("1 / 12", app)
        XCTAssertEqual(presentation(2, app), identity, "Cached adjacent Canvas stays alive when reading backward")
        drag(app); waitForPage("2 / 12", app)
        XCTAssertEqual(presentation(2, app), identity, "Returning to cached target must reuse the same decoded Canvas")
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        capture(app, "reader11.cached.prefetch\(prefetch)")
    }
    func testZeroPrefetchCachedRoundTripKeepsTheSameDecodedCanvas() { checkCachedHandoff(prefetch: 0) }
    func testSixPrefetchCachedRoundTripKeepsTheSameDecodedCanvas() { checkCachedHandoff(prefetch: 6) }

    func testFourDirectionsShortReboundFastReverseAndRepeatedDragsHaveNoBlank() {
        let app = launch(prefetch: 2)
        drag(app); waitForPage("2 / 12", app)
        let directions: [(String, CGVector, CGVector)] = [
            ("从左到右 →", .init(dx: 0.70, dy: 0.5), .init(dx: 0.30, dy: 0.5)),
            ("从右到左 ←", .init(dx: 0.30, dy: 0.5), .init(dx: 0.70, dy: 0.5)),
            ("从上到下 ↓", .init(dx: 0.50, dy: 0.65), .init(dx: 0.50, dy: 0.35)),
            ("从下到上 ↑", .init(dx: 0.50, dy: 0.35), .init(dx: 0.50, dy: 0.65))]
        for (title, start, end) in directions {
            app.buttons["reader.direction"].tap(); app.buttons[title].tap()
            for sign in [-1.0, 1.0] {
                let small = title.contains("左") || title.contains("右") ? CGVector(dx: 0.5 + sign * 0.04, dy: 0.5) : CGVector(dx: 0.5, dy: 0.5 + sign * 0.02)
                drag(app, from: .init(dx: 0.5, dy: 0.5), to: small, velocity: .slow, hold: 0.3)
                waitForPage("2 / 12", app)
                XCTAssertGreaterThan(visibleColorFraction(app), 0.7, "Rebound must retain real content: \(title)")
            }
            drag(app, from: start, to: end); waitForPage("3 / 12", app)
            XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
            drag(app, from: end, to: start); waitForPage("2 / 12", app)
            drag(app, from: start, to: end)
            drag(app, from: start, to: end); waitForPage("4 / 12", app)
            XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
            capture(app, "reader11.direction.\(title)")
            drag(app, from: end, to: start); waitForPage("3 / 12", app)
            drag(app, from: end, to: start); waitForPage("2 / 12", app)
        }
    }
    func testSlowPendingTurnCanBeCancelledByZoomThenProgressJumpWithoutLatePageChange() {
        let app = launch(prefetch: 0, delay: 6000)
        drag(app)
        let canvas = app.descendants(matching: .any)["reader.single.canvas"].firstMatch
        expectation(for: NSPredicate { _, _ in (canvas.value as? String)?.contains("; waiting;") == true }, evaluatedWith: canvas)
        waitForExpectations(timeout: 3)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        waitForPage("1 / 12", app)
        let image = app.otherElements["media.static"].firstMatch
        XCTAssertTrue(image.exists); image.doubleTap()
        expectation(for: NSPredicate { _, _ in (image.value as? String)?.contains("zoomed") == true }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        drag(app); waitForPage("1 / 12", app)
        app.sliders["reader.progress"].adjust(toNormalizedSliderPosition: 1)
        waitForPage("12 / 12", app)
        waitForCache("files=12;", app)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        XCTAssertTrue((app.otherElements["media.static"].firstMatch.value as? String)?.contains("reader-v11-page-12.png") == true)
        capture(app, "reader11.zoom-jump")
    }
    func testMissingNextMetadataStopsAfterOneAttemptAndKeepsCurrentPixels() {
        let app = launch(prefetch: 0, arguments: ["--qa-reader-paging", "--qa-reader-metadata-stall"])
        drag(app); waitForPage("2 / 12", app)
        drag(app)
        XCTAssertTrue(app.staticTexts["后续列表未返回第 3 页，当前图片已保留。"].waitForExistence(timeout: 5))
        waitForCache("metadataCalls=1;metadataTask=false;", app)
        waitForPage("2 / 12", app)
        XCTAssertGreaterThan(visibleColorFraction(app), 0.7)
        capture(app, "reader11.metadata-no-progress")
        waitForCache("metadataCalls=1;metadataTask=false;", app)
    }
}

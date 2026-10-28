import XCTest

/// Explicitly selected by the device runner after the user requested a real
/// reading test. Uses the installed account normally; never reads credentials.
final class PhysicalReaderNetworkV14UITests: XCTestCase {
    func testRealNetworkNextPagesAndWarmReturn() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This sample requires the paired physical iPhone")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["--reader-network-metrics"]
        app.launch()
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "gallery.open.")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 35), "A real gallery must be available before measuring reading")
        tile.tap()
        XCTAssertTrue(app.buttons["在线阅读"].waitForExistence(timeout: 15))
        app.buttons["在线阅读"].tap()
        let state = app.descendants(matching: .any)["reader.metrics.state"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 20))
        func current() -> Int {
            let value = state.value as? String ?? ""
            return Int(value.split(separator: ";").first(where: { $0.hasPrefix("current=") })?.split(separator: "=").last ?? "0") ?? 0
        }
        func ready(_ page: Int) -> Bool {
            let value = state.value as? String ?? ""
            let files = value.split(separator: ";").first(where: { $0.hasPrefix("files=") })?.split(separator: "=", omittingEmptySubsequences: false).last ?? ""
            let decoded = value.split(separator: ";").first(where: { $0.hasPrefix("decoded=") })?.split(separator: "=", omittingEmptySubsequences: false).last ?? ""
            return files.split(separator: ",").compactMap { Int($0) }.contains(page) && decoded.split(separator: ",").compactMap { Int($0) }.contains(page)
        }
        let first = current()
        XCTAssertGreaterThan(first, 0)
        expectation(for: NSPredicate { _, _ in ready(first) }, evaluatedWith: state)
        waitForExpectations(timeout: 75)
        let pageLabel = app.buttons["reader.page"].label
        let total = Int(pageLabel.split(separator: "/").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        let turns = min(3, max(0, total - first))
        XCTAssertGreaterThan(turns, 0, "A multi-page gallery is required for next-image measurement")
        for offset in 1...max(1, turns) {
            guard turns > 0 else { break }
            app.buttons["reader.next"].tap()
            let expected = first + offset
            expectation(for: NSPredicate { _, _ in current() == expected && ready(expected) }, evaluatedWith: state)
            waitForExpectations(timeout: 75)
            print("PHYSICAL_READER14 ready-page-offset=\(offset)")
        }
        if turns > 0 {
            app.buttons["reader.previous"].tap()
            let back = first + turns - 1
            expectation(for: NSPredicate { _, _ in current() == back && ready(back) }, evaluatedWith: state)
            waitForExpectations(timeout: 15)
            app.buttons["reader.next"].tap()
            expectation(for: NSPredicate { _, _ in current() == first + turns && ready(first + turns) }, evaluatedWith: state)
            waitForExpectations(timeout: 15)
        }
        for _ in 0..<turns { app.buttons["reader.previous"].tap() }
        expectation(for: NSPredicate { _, _ in current() == first }, evaluatedWith: state)
        waitForExpectations(timeout: 20)
        app.buttons["关闭"].tap()
        print("PHYSICAL_READER14 sample-complete forward-turns=\(turns); warm-roundtrip=\(turns > 0)")
        #endif
    }
}

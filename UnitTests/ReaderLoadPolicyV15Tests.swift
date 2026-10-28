import XCTest
@testable import ExViewer

final class ReaderLoadPolicyV15Tests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ReaderLoadPolicyV15Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testMigrationDefaultsMissingValuesToHighBufferAndConcurrency() {
        let defaults = makeDefaults()

        ReaderLoadPolicy.migrate(defaults: defaults)

        XCTAssertEqual(defaults.integer(forKey: "reader.prefetchCount"), 32)
        XCTAssertEqual(defaults.integer(forKey: "reader.downloadConcurrency"), 16)
        XCTAssertEqual(defaults.integer(forKey: "reader.loadPolicyVersion"), 1)
    }

    func testMigrationPreservesOffAndMapsPositiveLegacyValues() {
        let defaults = makeDefaults()
        defaults.set(0, forKey: "reader.prefetchCount")
        ReaderLoadPolicy.migrate(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "reader.prefetchCount"), 0)

        for legacyValue in 1...6 {
            let legacy = makeDefaults()
            legacy.set(legacyValue, forKey: "reader.prefetchCount")
            ReaderLoadPolicy.migrate(defaults: legacy)
            XCTAssertEqual(legacy.integer(forKey: "reader.prefetchCount"), 32, "legacy value \(legacyValue)")
        }
    }

    func testMigrationPreservesValidNewBufferAndClampsOutOfRange() {
        let valid = makeDefaults()
        valid.set(64, forKey: "reader.prefetchCount")
        ReaderLoadPolicy.migrate(defaults: valid)
        XCTAssertEqual(valid.integer(forKey: "reader.prefetchCount"), 64)

        let high = makeDefaults()
        high.set(300, forKey: "reader.prefetchCount")
        ReaderLoadPolicy.migrate(defaults: high)
        XCTAssertEqual(high.integer(forKey: "reader.prefetchCount"), 128)

        let low = makeDefaults()
        low.set(-3, forKey: "reader.prefetchCount")
        ReaderLoadPolicy.migrate(defaults: low)
        XCTAssertEqual(low.integer(forKey: "reader.prefetchCount"), 0)
    }

    func testMigrationIsIdempotentAndDoesNotOverwriteChosenValues() {
        let defaults = makeDefaults()
        defaults.set(8, forKey: "reader.prefetchCount")
        defaults.set(8, forKey: "reader.downloadConcurrency")
        ReaderLoadPolicy.migrate(defaults: defaults)
        defaults.set(64, forKey: "reader.prefetchCount")
        defaults.set(4, forKey: "reader.downloadConcurrency")

        ReaderLoadPolicy.migrate(defaults: defaults)

        XCTAssertEqual(defaults.integer(forKey: "reader.prefetchCount"), 64)
        XCTAssertEqual(defaults.integer(forKey: "reader.downloadConcurrency"), 4)
    }

    func testMigrationClampsConcurrencyBounds() {
        let low = makeDefaults()
        low.set(1, forKey: "reader.downloadConcurrency")
        ReaderLoadPolicy.migrate(defaults: low)
        XCTAssertEqual(low.integer(forKey: "reader.downloadConcurrency"), 2)

        let high = makeDefaults()
        high.set(24, forKey: "reader.downloadConcurrency")
        ReaderLoadPolicy.migrate(defaults: high)
        XCTAssertEqual(high.integer(forKey: "reader.downloadConcurrency"), 16)
    }
}

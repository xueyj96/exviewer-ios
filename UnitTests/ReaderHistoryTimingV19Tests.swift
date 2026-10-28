import XCTest
import ExViewerCore
@testable import ExViewer

final class ReaderHistoryTimingV19Tests: XCTestCase {
    @MainActor
    func testMeasureActualHistoryCommitAndVerifyReopenedFinalPage() throws {
        for (name, historyCount, bookmarkCount, tagCount) in [("small", 12, 12, 8), ("large", 500, 250, 24)] {
            let store = LibraryStore(qa: true)
            defer { try? FileManager.default.removeItem(at: store.directory.deletingLastPathComponent()) }
            let tags = (0..<tagCount).map { GalleryTag(namespace: "other", name: "neutral-fixture-tag-\($0)") }
            let galleries = (0..<max(historyCount, bookmarkCount)).map { index in
                Gallery(ref: .init(site: .ex, gid: Int64(index + 1), token: "preview"),
                        title: "Neutral reading history fixture \(index) " + String(repeating: "sample ", count: 10),
                        category: "Non-H", uploader: "Preview Studio", pages: 250, rating: 4.5, tags: tags)
            }
            var snapshot = LibrarySnapshot()
            snapshot.history = galleries.prefix(historyCount).map { ReadingRecord(gallery: $0, page: 1, date: Date(timeIntervalSince1970: 1)) }
            snapshot.bookmarks = Array(galleries.prefix(bookmarkCount))
            let file = store.directory.appendingPathComponent("library.json")
            let seed = try JSONEncoder().encode(snapshot)
            try seed.write(to: file, options: .atomic)
            store.load(owner: "guest")
            XCTAssertNil(store.error)
            var milliseconds: [Double] = []
            for page in 1...25 {
                let start = ProcessInfo.processInfo.systemUptime
                store.remember(galleries[0], page: page)
                milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
            XCTAssertNil(store.error)
            store.load(owner: "guest")
            XCTAssertNil(store.error)
            XCTAssertEqual(store.snapshot.history.count, historyCount)
            XCTAssertEqual(store.snapshot.history.first?.gallery.id, galleries[0].id)
            XCTAssertEqual(store.snapshot.history.first?.page, 25)
            XCTAssertEqual(store.snapshot.bookmarks.map(\.id), snapshot.bookmarks.map(\.id))
            let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let sorted = milliseconds.sorted()
            print("READER19_HISTORY_COMMIT workload=\(name) bytes=\(bytes) samples=25 medianMs=\(sorted[12]) maxMs=\(sorted.last ?? 0) rawMs=\(milliseconds)")

            try seed.write(to: file, options: .atomic)
            store.load(owner: "guest")
            let checkpoint = ReaderHistoryCheckpoint(isCurrent: { true }) { store.remember(galleries[0], page: $0) }
            var stagedMilliseconds: [Double] = []
            for page in 1...25 {
                let start = ProcessInfo.processInfo.systemUptime
                checkpoint.stage(page)
                stagedMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
            XCTAssertEqual(try Data(contentsOf: file), seed, "Page motion must not write the snapshot")
            let flushStart = ProcessInfo.processInfo.systemUptime
            checkpoint.flush()
            let flushMs = (ProcessInfo.processInfo.systemUptime - flushStart) * 1_000
            store.load(owner: "guest")
            XCTAssertNil(store.error)
            XCTAssertEqual(store.snapshot.history.first?.page, 25)
            XCTAssertEqual(store.snapshot.history.count, historyCount)
            XCTAssertEqual(store.snapshot.bookmarks.map(\.id), snapshot.bookmarks.map(\.id))
            let stagedSorted = stagedMilliseconds.sorted()
            print("READER19_HISTORY_STAGED workload=\(name) bytes=\(bytes) samples=25 medianMs=\(stagedSorted[12]) maxMs=\(stagedSorted.last ?? 0) settledFlushMs=\(flushMs)")
        }
    }

    @MainActor
    func testStaleContextAndDiscardCannotOverwriteReadingProgress() {
        var valid = true
        var committed: [Int] = []
        let checkpoint = ReaderHistoryCheckpoint(isCurrent: { valid }) { committed.append($0) }
        checkpoint.stage(2); checkpoint.stage(3)
        valid = false; checkpoint.flush()
        XCTAssertTrue(committed.isEmpty)
        valid = true
        checkpoint.stage(4); checkpoint.discard(); checkpoint.flush()
        XCTAssertTrue(committed.isEmpty)
        checkpoint.stage(0); checkpoint.stage(-1); checkpoint.flush()
        XCTAssertTrue(committed.isEmpty)
        checkpoint.stage(5); checkpoint.stage(6); checkpoint.flush(); checkpoint.flush()
        XCTAssertEqual(committed, [6])
        checkpoint.stage(7)
        checkpoint.finishMotion(fingerDown: true)
        XCTAssertEqual(committed, [6])
        checkpoint.finishMotion(fingerDown: false)
        XCTAssertEqual(committed, [6, 7])
    }
}

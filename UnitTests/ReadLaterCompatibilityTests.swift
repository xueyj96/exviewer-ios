import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class ReadLaterCompatibilityTests: XCTestCase {
    private let a = Gallery(ref: .init(site: .ex, gid: 41, token: "preview"), title: "Neutral A")
    private let b = Gallery(ref: .init(site: .ex, gid: 42, token: "preview"), title: "Neutral B")

    private func fixture(_ work: (URL, URL, Data) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("aa/library.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var old = LibrarySnapshot(); old.bookmarks = [a, b]
        old.history = [.init(gallery: a, page: 7, date: Date(timeIntervalSince1970: 123))]
        old.downloads = [.init(gallery: b, status: .paused, completed: [1: "page.media"], total: 3)]
        let bytes = try JSONEncoder().encode(old); try bytes.write(to: file)
        try work(root, file, bytes)
    }
    func testOldBookmarksBecomeReadLaterWithoutRewritingOrInventingDates() throws {
        try fixture { root, file, bytes in
            let store = LibraryStore(storageRoot: root)
            for _ in 0..<3 {
                store.load(owner: "aa")
                XCTAssertEqual(store.snapshot.readLater.map(\.id), [a.id, b.id])
                XCTAssertEqual(try Data(contentsOf: file), bytes)
                XCTAssertEqual(store.snapshot.history[0].date, Date(timeIntervalSince1970: 123))
                XCTAssertEqual(store.snapshot.history[0].page, 7)
                XCTAssertEqual(store.snapshot.downloads[0].completed, [1: "page.media"])
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertNotNil(object["bookmarks"]); XCTAssertNil(object["readLater"])
        }
    }
    func testIdempotentMembershipAndRemovalSurviveRestartWithoutResurrectingLegacyData() throws {
        try fixture { root, _, _ in
            let first = LibraryStore(storageRoot: root); first.load(owner: "aa")
            XCTAssertTrue(first.setReadLater(a, included: true)); XCTAssertTrue(first.setReadLater(a, included: true))
            XCTAssertEqual(first.snapshot.readLater.map(\.id), [a.id, b.id])
            XCTAssertTrue(first.setReadLater(a, included: false))
            let restarted = LibraryStore(storageRoot: root); restarted.load(owner: "aa")
            XCTAssertEqual(restarted.snapshot.readLater.map(\.id), [b.id])
            XCTAssertEqual(restarted.snapshot.history[0].page, 7)
            XCTAssertEqual(restarted.snapshot.downloads[0].id, b.id)
        }
    }
    func testAccountAndGuestCollectionsAreIsolatedAcrossSwitchAndRestart() throws {
        try fixture { root, _, _ in
            let store = LibraryStore(storageRoot: root); store.load(owner: "aa")
            store.load(owner: "bb"); XCTAssertTrue(store.snapshot.readLater.isEmpty)
            XCTAssertTrue(store.setReadLater(b, included: true))
            store.load(owner: "guest"); XCTAssertTrue(store.snapshot.readLater.isEmpty)
            store.load(owner: "aa"); XCTAssertEqual(store.snapshot.readLater.map(\.id), [a.id, b.id])
            let second = LibraryStore(storageRoot: root); second.load(owner: "bb")
            XCTAssertEqual(second.snapshot.readLater.map(\.id), [b.id]); XCTAssertTrue(second.snapshot.history.isEmpty)
        }
    }
    func testReadingCompletionDoesNotRemoveReadLaterAndBulkRemovalPreservesOtherData() throws {
        try fixture { root, _, _ in
            let store = LibraryStore(storageRoot: root); store.load(owner: "aa")
            store.remember(a, page: 999); XCTAssertTrue(store.containsReadLater(a))
            XCTAssertTrue(store.removeReadLater([a.id, b.id])); XCTAssertTrue(store.snapshot.readLater.isEmpty)
            XCTAssertEqual(store.snapshot.history[0].page, 999); XCTAssertEqual(store.snapshot.downloads.count, 1)
        }
    }
    func testSaveFailureRetainsMembershipAndDoesNotReportSuccess() throws {
        try fixture { root, file, bytes in
            let store = LibraryStore(storageRoot: root); store.load(owner: "aa"); store.error = "Controlled failure"
            XCTAssertFalse(store.setReadLater(a, included: false)); XCTAssertTrue(store.containsReadLater(a))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertTrue(store.readLaterNotice?.text.contains("未能保存") == true)
        }
    }
    func testSameStableIDCannotCreateDuplicatesWhenGalleryMetadataChanges() throws {
        try fixture { root, _, _ in
            let store = LibraryStore(storageRoot: root); store.load(owner: "aa")
            var changed = a; changed.title = "Updated neutral title"
            XCTAssertTrue(store.setReadLater(changed, included: true)); XCTAssertEqual(store.snapshot.readLater.count, 2)
            XCTAssertTrue(store.setReadLater(changed, included: false)); XCTAssertFalse(store.containsReadLater(a))
        }
    }
}

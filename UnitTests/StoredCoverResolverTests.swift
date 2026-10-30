import XCTest
import Foundation
import ExViewerCore
@testable import ExViewer

@MainActor final class StoredCoverResolverTests: XCTestCase {
    private func gallery(_ id: Int64) -> Gallery {
        var value = Gallery(ref: .init(site: .ex, gid: id, token: "preview"), title: "Neutral \(id)",
                            cover: URL(string: "https://ehgt.org/fixture-\(id).png"))
        value.tagsComplete = true; return value
    }
    private func resolved(_ batch: [Gallery]) -> [Gallery] {
        batch.map { item in var value = item; value.cover = URL(string: "https://ehgt.org/fixture-\(item.ref.gid).png"); return value }
    }
    private func waitUntil(_ test: () -> Bool) async {
        for _ in 0..<200 { if test() { return }; try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(test())
    }

    func testRealBookmarkSaveReopenRestoresCoverWithoutChangingSavedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stored-cover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(qa: true, storageRoot: root)
        let original = gallery(701); library.bookmark(original); library.remember(original, page: 3)
        let file = library.directory.appendingPathComponent("library.json"), before = try Data(contentsOf: file)
        let reopened = LibraryStore(qa: true, storageRoot: root)
        let saved = try XCTUnwrap(reopened.snapshot.bookmarks.first)
        XCTAssertNil(saved.cover); XCTAssertNil(reopened.snapshot.history.first?.gallery.cover)
        let resolver = StoredCoverResolver(batchDelay: 0, interval: 0)
        var calls = 0
        let fetch: StoredCoverResolver.Fetch = { batch in
            calls += 1
            // Exercise the actual gdata request and validated response merger.
            let request = try JSONSerialization.jsonObject(with: GalleryMetadata.request(batch)) as? [String: Any]
            XCTAssertEqual(request?["method"] as? String, "gdata")
            let body = Data(#"{"gmetadata":[{"gid":701,"thumb":"https://ehgt.org/fixture-701.png"}]}"#.utf8)
            return try GalleryMetadata.merge(body, into: batch)
        }
        let source = try await resolver.source(for: saved, context: "owner-a/session-1", fetch: fetch)
        XCTAssertEqual(source, original.cover)
        let historySource = try await resolver.source(for: XCTUnwrap(reopened.snapshot.history.first?.gallery), context: "owner-a/session-1", fetch: fetch)
        XCTAssertEqual(historySource, source); XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertNil(reopened.snapshot.bookmarks.first?.cover, "Transient source must remain in memory, outside library.json")
    }

    func testVisibleRequestsBatchAt25AndDuplicateConsumersShareOneSource() async throws {
        let resolver = StoredCoverResolver(batchDelay: 5_000_000, interval: 0)
        var batches: [[Int64]] = []
        let fetch: StoredCoverResolver.Fetch = { batch in batches.append(batch.map(\.ref.gid)); return self.resolved(batch) }
        let tasks = (1...60).map { id in Task { try await resolver.source(for: gallery(Int64(id)).stored, context: "owner-a", fetch: fetch) } }
        let duplicate = Task { try await resolver.source(for: gallery(1).stored, context: "owner-a", fetch: fetch) }
        for task in tasks { _ = try await task.value }; _ = try await duplicate.value
        XCTAssertEqual(batches.count, 3); XCTAssertTrue(batches.allSatisfy { $0.count <= 25 })
        XCTAssertEqual(batches.flatMap { $0 }.sorted(), (1...60).map(Int64.init))
    }

    func testCancellingOneConsumerKeepsTheOtherConsumerAndWarmResult() async throws {
        let resolver = StoredCoverResolver(batchDelay: 1_000_000, interval: 0)
        var reply: CheckedContinuation<[Gallery], Error>?
        var calls = 0
        let fetch: StoredCoverResolver.Fetch = { _ in calls += 1; return try await withCheckedThrowingContinuation { reply = $0 } }
        let first = Task { try await resolver.source(for: gallery(1).stored, context: "a", fetch: fetch) }
        let second = Task { try await resolver.source(for: gallery(1).stored, context: "a", fetch: fetch) }
        await waitUntil { reply != nil }; first.cancel()
        await Task.yield(); reply?.resume(returning: resolved([gallery(1)])); reply = nil
        do { _ = try await first.value; XCTFail("Cancelled view must detach") } catch is CancellationError { }
        let value = try await second.value
        let warm = try await resolver.source(for: gallery(1).stored, context: "a", fetch: fetch)
        XCTAssertEqual(warm, value); XCTAssertEqual(calls, 1)
    }

    func testAccountChangeRejectsLateSourceFromPreviousContext() async throws {
        let resolver = StoredCoverResolver(batchDelay: 0, interval: 0)
        var oldReply: CheckedContinuation<[Gallery], Error>?
        let old = Task { try await resolver.source(for: gallery(1).stored, context: "owner-a", fetch: { _ in
            try await withCheckedThrowingContinuation { oldReply = $0 }
        }) }
        await waitUntil { oldReply != nil }
        let current = try await resolver.source(for: gallery(1).stored, context: "owner-b", fetch: { self.resolved($0) })
        oldReply?.resume(returning: resolved([gallery(1)])); oldReply = nil
        do { _ = try await old.value; XCTFail("Previous account request must be invalidated") } catch is CancellationError { }
        var calls = 0
        let warm = try await resolver.source(for: gallery(1).stored, context: "owner-b", fetch: { calls += 1; return self.resolved($0) })
        XCTAssertEqual(current, warm); XCTAssertEqual(calls, 0)
    }

    func testMissingSourceShowsFailureAndExplicitRetryCanRecover() async throws {
        let resolver = StoredCoverResolver(batchDelay: 0, interval: 0)
        do {
            _ = try await resolver.source(for: gallery(1).stored, context: "a", fetch: { $0 })
            XCTFail("Missing metadata cover must not silently succeed")
        } catch { XCTAssertTrue(error is StoredCoverResolver.Failure) }
        var calls = 0
        let fetch: StoredCoverResolver.Fetch = { calls += 1; return self.resolved($0) }
        _ = try await resolver.source(for: gallery(1).stored, context: "a", fetch: fetch)
        resolver.invalidate(gallery(1).ref, context: "a")
        _ = try await resolver.source(for: gallery(1).stored, context: "a", fetch: fetch)
        XCTAssertEqual(calls, 2, "A failed media URL must be resolvable again on retry")
    }

    func testResolvedSourceCacheIsBoundedAndSessionChangesRefetch() async throws {
        let resolver = StoredCoverResolver(cacheLimit: 2, batchDelay: 0, interval: 0)
        var calls = 0
        let fetch: StoredCoverResolver.Fetch = { calls += 1; return self.resolved($0) }
        for id in 1...3 { _ = try await resolver.source(for: gallery(Int64(id)).stored, context: "owner/session1", fetch: fetch) }
        _ = try await resolver.source(for: gallery(1).stored, context: "owner/session1", fetch: fetch)
        XCTAssertEqual(calls, 4)
        _ = try await resolver.source(for: gallery(1).stored, context: "owner/session2", fetch: fetch)
        XCTAssertEqual(calls, 5)
    }
}

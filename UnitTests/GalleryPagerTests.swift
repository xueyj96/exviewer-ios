import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class GalleryPagerTests: XCTestCase {
    private func list(count: Int, start: Int = 1) -> String {
        "<div class='itg'><table>" + (start..<(start + count)).map {
            "<tr><td><a href='/g/\($0)/abcdef/'><div class='glink'>Neutral \($0)</div></a></td></tr>"
        }.joined() + "</table></div>"
    }

    private func metadata(_ data: Data) throws -> String {
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pairs = try XCTUnwrap(request["gidlist"] as? [[Any]])
        let values: [[String: Any]] = try pairs.map { pair in
            let gid = try XCTUnwrap(pair.first as? Int)
            return ["gid": gid, "title": "Enriched \(gid)", "filecount": "10", "tags": ["language:english"]]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["gmetadata": values]), as: UTF8.self)
    }

    private func waitUntil(timeout: TimeInterval = 6, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    func testFirstCompletedBatchAppearsBeforeLaterBatchesWithoutChangingCoverage() async throws {
        var requests = 0
        let pager = GalleryPager { _, search, body in
            if search { return self.list(count: 51) }
            requests += 1
            try await Task.sleep(nanoseconds: 30_000_000)
            return try self.metadata(XCTUnwrap(body))
        }
        let start = ProcessInfo.processInfo.systemUptime
        pager.reset(url: GallerySite.ex.baseURL, session: SiteSession(qa: true))
        try await waitUntil(timeout: 2) { pager.items.count == 25 }
        let first = ProcessInfo.processInfo.systemUptime - start
        XCTAssertTrue(pager.loading)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(pager.items.allSatisfy(\.tagsComplete))
        try await waitUntil { !pager.loading }
        let complete = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(pager.items.map(\.ref.gid), (1...51).map(Int64.init))
        XCTAssertEqual(requests, 3)
        XCTAssertNil(pager.failure)
        print("PAGER12_LOCAL_PIPELINE first25=\(first)s all51=\(complete)s; three30ms metadata responses; production1.3s interbatch pacing; no network")
    }

    func testMetadataFailurePreservesIncompleteRowsAndBlockedUnknownPolicy() async throws {
        var requests = 0
        let pager = GalleryPager { _, search, body in
            if search { return self.list(count: 26) }
            requests += 1
            if requests == 2 { throw URLError(.timedOut) }
            return try self.metadata(XCTUnwrap(body))
        }
        pager.reset(url: GallerySite.ex.baseURL, session: SiteSession(qa: true))
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.count, 26)
        XCTAssertEqual(pager.items.filter(\.tagsComplete).count, 25)
        let filtered = LibrarySelectionPolicy.filtered(pager.items, blocked: ["other:blocked"])
        XCTAssertEqual(filtered.visible.count, 25)
        XCTAssertEqual(filtered.unknown, 1)
        XCTAssertEqual(pager.items.last?.title, "Neutral 26")
    }

    func testResetDuringMetadataCannotAppendOldSourceAfterNewSource() async throws {
        let session = SiteSession(qa: true)
        var oldMetadataStarted = false
        let pager = GalleryPager { url, search, body in
            if search { return self.list(count: 1, start: url.path == "/new" ? 100 : 1) }
            let payload = try XCTUnwrap(body)
            let isOld = String(decoding: payload, as: UTF8.self).contains("[1,")
            if isOld {
                oldMetadataStarted = true
                // Simulate a transport that finishes despite cancellation.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return try self.metadata(payload)
        }
        pager.reset(url: GallerySite.ex.baseURL, session: session)
        try await waitUntil(timeout: 2) { oldMetadataStarted }
        pager.reset(url: URL(string: "https://exhentai.org/new")!, session: session)
        try await waitUntil(timeout: 2) { !pager.loading }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(pager.items.map(\.ref.gid), [100])
        XCTAssertNil(pager.failure)
    }

    func testInterruptedIncompleteBatchCanRecoverTagsOnRetryWithoutDuplicates() async throws {
        let session = SiteSession(qa: true)
        var requests = 0
        let pager = GalleryPager { _, search, body in
            if search { return self.list(count: 26) }
            requests += 1
            if requests == 1 { throw URLError(.timedOut) }
            return try self.metadata(XCTUnwrap(body))
        }
        pager.reset(url: GallerySite.ex.baseURL, session: session)
        try await waitUntil(timeout: 2) { pager.items.count == 25 }
        XCTAssertTrue(pager.items.allSatisfy { !$0.tagsComplete })
        pager.cancel()
        XCTAssertTrue(pager.interrupted)
        pager.retry(session: session)
        try await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.ref.gid), (1...26).map(Int64.init))
        XCTAssertTrue(pager.items.allSatisfy(\.tagsComplete))
        XCTAssertEqual(LibrarySelectionPolicy.filtered(pager.items, blocked: ["other:blocked"]).unknown, 0)
    }
}

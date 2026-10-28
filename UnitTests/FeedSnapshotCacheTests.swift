import XCTest
import CryptoKit
import ExViewerCore
@testable import ExViewer

@MainActor final class FeedSnapshotCacheTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func url(_ value: String) throws -> URL { try XCTUnwrap(URL(string: value)) }

    private func gallery(_ site: GallerySite, gid: Int64, title: String, cover: URL? = nil) -> Gallery {
        Gallery(ref: GalleryRef(site: site, gid: gid, token: "abcdef"), title: title, category: "Manga", cover: cover)
    }

    private func snapshot(owner: String, root: URL, site: GallerySite, gid: Int64, title: String,
                          next: URL? = nil, categories: [String: String] = [:], cover: URL? = nil) -> FeedSnapshot {
        FeedSnapshot(owner: owner, root: root, items: [gallery(site, gid: gid, title: title, cover: cover)], next: next, categories: categories)
    }

    private func diskFile(root: URL, owner: String, url: URL) throws -> URL {
        let digest = SHA256.hash(data: Data((owner + "\n" + url.absoluteString).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(owner, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(digest + ".json")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }

    func testOwnerSiteAndFavoriteGroupKeysRemainSeparateAfterCacheReconstruction() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ehAll = try url("https://e-hentai.org/favorites.php?favcat=0")
        let ehGroup = try url("https://e-hentai.org/favorites.php?favcat=1")
        let exAll = try url("https://exhentai.org/favorites.php?favcat=0")
        let ownerGroup = try url("https://e-hentai.org/favorites.php?favcat=0&f_search=owner-b")
        let cache = FeedSnapshotCache(root: root)
        let values = [
            ("a1b2", ehAll, GallerySite.eh, Int64(1), "EH all"),
            ("a1b2", ehGroup, GallerySite.eh, Int64(2), "EH group 1"),
            ("a1b2", exAll, GallerySite.ex, Int64(3), "EX all"),
            ("b2c3", ehAll, GallerySite.eh, Int64(4), "other owner")
        ]
        for (owner, feed, site, gid, title) in values {
            let expectedEpoch = await cache.epoch(owner: owner)
            let cover = try url("https://ehgt.org/cover-\(gid).webp")
            let cursor: URL?
            if feed == ehAll { cursor = try url("https://e-hentai.org/favorites.php?favcat=0&page=2") }
            else { cursor = nil }
            await cache.save(snapshot(owner: owner, root: feed, site: site, gid: gid, title: title,
                                      next: cursor, categories: ["0": "全部"], cover: cover), expectedEpoch: expectedEpoch)
        }

        let restarted = FeedSnapshotCache(root: root)
        for (owner, feed, _, _, expectedTitle) in values {
            let result = await restarted.read(owner: owner, url: feed)
            XCTAssertEqual(result?.items.first?.title, expectedTitle, "Disk lookup must remain scoped to owner, site, and group URL")
        }
        let persistedSnapshot = await restarted.read(owner: "a1b2", url: ehAll)
        let expectedCover = try url("https://ehgt.org/cover-1.webp")
        let expectedCursor = try url("https://e-hentai.org/favorites.php?favcat=0&page=2")
        XCTAssertEqual(persistedSnapshot?.items.first?.cover, expectedCover)
        XCTAssertEqual(persistedSnapshot?.next, expectedCursor)
        XCTAssertEqual(persistedSnapshot?.categories["0"], "全部")
        let missingGroup = await restarted.read(owner: "a1b2", url: ownerGroup)
        XCTAssertNil(missingGroup)
    }

    func testMalformedAndOversizedSnapshotFilesAreIgnored() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let malformedURL = try url("https://e-hentai.org/?f_search=malformed")
        let oversizedURL = try url("https://e-hentai.org/?f_search=oversized")
        let malformedFile = try diskFile(root: root, owner: "a1b2", url: malformedURL)
        let oversizedFile = try diskFile(root: root, owner: "a1b2", url: oversizedURL)
        try Data("{invalid json".utf8).write(to: malformedFile)
        try Data(repeating: 0x41, count: 4_000_001).write(to: oversizedFile)

        let cache = FeedSnapshotCache(root: root)
        let malformed = await cache.read(owner: "a1b2", url: malformedURL)
        let oversized = await cache.read(owner: "a1b2", url: oversizedURL)
        XCTAssertNil(malformed)
        XCTAssertNil(oversized)
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedFile.path), "An invalid record is ignored without destructive cleanup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oversizedFile.path), "An oversized record is ignored without deleting unrelated files")
    }

    func testFavoriteInvalidationRejectsAWriteUsingTheOldEpoch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let favorites = try url("https://e-hentai.org/favorites.php?favcat=0")
        let cache = FeedSnapshotCache(root: root)
        let staleSnapshot = snapshot(owner: "a1b2", root: favorites, site: .eh, gid: 7, title: "Before invalidation")
        let oldEpoch = await cache.epoch(owner: "a1b2")
        await cache.save(staleSnapshot, expectedEpoch: oldEpoch)
        let beforeInvalidation = await cache.read(owner: "a1b2", url: favorites)
        XCTAssertEqual(beforeInvalidation?.items.first?.title, "Before invalidation")

        await cache.invalidateFavorites(owner: "a1b2")
        let newEpoch = await cache.epoch(owner: "a1b2")
        XCTAssertEqual(newEpoch, oldEpoch + 1)
        await cache.save(staleSnapshot, expectedEpoch: oldEpoch)
        let afterStaleSave = await FeedSnapshotCache(root: root).read(owner: "a1b2", url: favorites)
        XCTAssertNil(afterStaleSave, "A stale completion must not repopulate invalidated favorites")

        let fresh = snapshot(owner: "a1b2", root: favorites, site: .eh, gid: 8, title: "After invalidation")
        await cache.save(fresh, expectedEpoch: newEpoch)
        let reloaded = await FeedSnapshotCache(root: root).read(owner: "a1b2", url: favorites)
        XCTAssertEqual(reloaded?.items.first?.title, "After invalidation")
    }

    func testCachedFirstPagePublishesBeforeOfflineLoadAndRefreshSharesOneRequest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = GallerySite.ex.baseURL
        let cursor = try url("https://exhentai.org/?next=81")
        let cache = FeedSnapshotCache(root: root)
        let stored = snapshot(owner: "guest", root: feed, site: .ex, gid: 81, title: "Offline snapshot",
                              next: cursor, categories: ["0": "全部", "1": "组一"])
        let cacheEpoch = await cache.epoch(owner: "guest")
        await cache.save(stored, expectedEpoch: cacheEpoch)

        var continuation: CheckedContinuation<String, Error>?
        var requestCount = 0
        let pager = GalleryPager(loadHTML: { _, search, _ in
            XCTAssertTrue(search)
            requestCount += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }, cache: FeedSnapshotCache(root: root))
        let session = SiteSession(qa: true)
        pager.reset(url: feed, session: session)
        await waitUntil { pager.items.first?.title == "Offline snapshot" && requestCount == 1 }
        XCTAssertTrue(pager.loading)
        XCTAssertEqual(pager.next, cursor)
        XCTAssertEqual(pager.categories["1"], "组一")
        XCTAssertNotNil(pager.cachedAt)

        pager.reset(url: feed, session: session)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(requestCount, 1, "Pull-to-refresh on the same loading root must share its in-flight fetch")

        continuation?.resume(throwing: URLError(.notConnectedToInternet))
        await waitUntil { !pager.loading }
        XCTAssertEqual(pager.items.map(\.title), ["Offline snapshot"], "A failed revalidation must preserve cached results")
        XCTAssertEqual(pager.next, cursor)
        XCTAssertNotNil(pager.failure)
    }

    func testFirstPageFailureRetriesRootBeforeFollowingItsCursor() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = GallerySite.ex.baseURL
        let cursor = try url("https://exhentai.org/?next=82")
        var rootAttempts = 0
        var searchURLs: [URL] = []
        let html = """
        <div class="itg"><table><tr><td><a href="/g/82/abcdef/"><div class="glink">First page row</div></a></td></tr></table></div>
        <a id="dnext" href="/?next=82">Next &gt;</a>
        """
        let pager = GalleryPager(loadHTML: { url, search, body in
            if search {
                searchURLs.append(url)
                if url == feed {
                    rootAttempts += 1
                    if rootAttempts == 1 { throw URLError(.timedOut) }
                    return html
                }
                if url == cursor { return "<p>No hits found</p>" }
                throw URLError(.badURL)
            }
            let request = try XCTUnwrap(body)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
            let ids = try XCTUnwrap(object["gidlist"] as? [[Any]])
            let gid = try XCTUnwrap(ids.first?.first as? Int)
            return "{\"gmetadata\":[{\"gid\":\(gid),\"title\":\"Metadata \(gid)\",\"filecount\":\"5\",\"tags\":[]}]}"
        }, cache: FeedSnapshotCache(root: root))
        let session = SiteSession(qa: true)

        pager.reset(url: feed, session: session)
        await waitUntil { !pager.loading }
        XCTAssertNotNil(pager.failure)
        XCTAssertTrue(pager.items.isEmpty)

        pager.retry(session: session)
        await waitUntil { !pager.loading }
        XCTAssertEqual(searchURLs, [feed, feed], "Retry must request page one again before using a continuation")
        XCTAssertEqual(pager.items.map(\.ref.gid), [82])
        XCTAssertEqual(pager.items.first?.title, "Metadata 82")
        XCTAssertEqual(pager.next, cursor)

        pager.more(session: session)
        await waitUntil { !pager.loading }
        XCTAssertEqual(searchURLs, [feed, feed, cursor], "The parsed next URL is followed only after page one succeeds")
        XCTAssertNil(pager.next)
    }

    func testLegacyRatingCacheIsIgnoredWhileUnfilteredSnapshotRemainsReadable() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var query = SearchQuery(); query.minRating = 3
        let filtered = try query.url(site: .ex)
        let plain = GallerySite.ex.baseURL
        var legacy = gallery(.ex, gid: 1, title: "Untrusted sprite average"); legacy.rating = 5
        for feed in [filtered, plain] {
            let stored = FeedSnapshot(owner: "guest", root: feed, items: [legacy], next: nil, categories: [:])
            try JSONEncoder().encode(stored).write(to: diskFile(root: root, owner: "guest", url: feed))
        }
        let cache = FeedSnapshotCache(root: root)
        let oldFiltered = await cache.read(owner: "guest", url: filtered)
        let unfiltered = await cache.read(owner: "guest", url: plain)
        XCTAssertNil(oldFiltered); XCTAssertEqual(unfiltered?.items.first?.rating, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try diskFile(root: root, owner: "guest", url: filtered).path))

        legacy.rating = 3
        await cache.save(.init(owner: "guest", root: filtered, items: [legacy], next: nil, categories: [:]), expectedEpoch: 0)
        let refreshed = await FeedSnapshotCache(root: root).read(owner: "guest", url: filtered)
        XCTAssertEqual(refreshed?.items.first?.rating, 3)
    }

    func testRatingFilteredCacheRejectsBelowThresholdAndUnknownAverages() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var query = SearchQuery(); query.minRating = 3
        let filtered = try query.url(site: .ex)
        let cache = FeedSnapshotCache(root: root)
        let ratings: [Double?] = [2.8, 2.9, 2.999, nil]
        for rating in ratings {
            var value = gallery(.ex, gid: 1, title: "Neutral"); value.rating = rating
            await cache.save(.init(owner: "guest", root: filtered, items: [value], next: nil, categories: [:]), expectedEpoch: 0)
            let result = await cache.read(owner: "guest", url: filtered)
            XCTAssertNil(result)
        }
    }
}

import XCTest
import Foundation
@testable import ExViewer

final class BrowseCacheIndexV17Tests: XCTestCase {
    private final class PNGProtocol: URLProtocol, @unchecked Sendable {
        private static let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cache.fixture.hath.network" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let client else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "image/png", "Content-Length": String(Self.png.count)])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Self.png)
            client.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseCacheIndexV17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: String, to url: URL, modified: Date) throws {
        try Data(data.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func rawModificationDate(_ url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    func testBootstrapBudgetAndLRURecencyChooseOldestUnpinnedFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldest = root.appendingPathComponent("cache-a")
        let newer = root.appendingPathComponent("cache-b")
        try write("aaaa", to: oldest, modified: Date(timeIntervalSince1970: 10))
        try write("bbbb", to: newer, modified: Date(timeIntervalSince1970: 20))

        let index = BrowseCacheIndex()
        try index.bootstrap(directory: root)
        XCTAssertTrue(index.isBootstrapped)
        XCTAssertEqual(index.usedBytes, 8)

        _ = index.touch(oldest, at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(index.oldestEvictable(pinnedPaths: [])?.url, newer)
        XCTAssertEqual(index.oldestEvictable(pinnedPaths: [newer.path])?.url, oldest,
                       "A pinned least-recent file is skipped while another entry can be evicted")
    }

    func testEvictionAccountingChangesOnlyAfterConfirmedRemovalAndHonorsByteBudget() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("cache-a")
        let second = root.appendingPathComponent("cache-b")
        try write("aaaa", to: first, modified: Date(timeIntervalSince1970: 10))
        try write("bbbb", to: second, modified: Date(timeIntervalSince1970: 20))

        let index = BrowseCacheIndex()
        try index.bootstrap(directory: root)
        let failedDelete = try XCTUnwrap(index.oldestEvictable(pinnedPaths: []))
        XCTAssertEqual(index.usedBytes, 8, "A failed or unconfirmed delete must not decrement used bytes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedDelete.url.path))

        var evicted: [URL] = []
        let budget: Int64 = 10, incomingSize: Int64 = 4
        while index.usedBytes > budget - incomingSize {
            let victim = try XCTUnwrap(index.oldestEvictable(pinnedPaths: []))
            try FileManager.default.removeItem(at: victim.url)
            index.confirmRemoved(victim.url)
            evicted.append(victim.url)
        }
        XCTAssertEqual(evicted, [first])
        XCTAssertEqual(index.usedBytes + incomingSize, 8)
    }

    func testPinnedPathsAreDirectOwnerFilesAndClearIsOwnerScoped() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerA = root.appendingPathComponent("owner-a", isDirectory: true)
        let ownerB = root.appendingPathComponent("owner-b", isDirectory: true)
        let offline = root.appendingPathComponent("offline", isDirectory: true)
        for dir in [ownerA, ownerB, offline] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let aFile = ownerA.appendingPathComponent("cache-a")
        let bFile = ownerB.appendingPathComponent("cache-b")
        let manualFile = offline.appendingPathComponent("manual")
        try Data("a".utf8).write(to: aFile)
        try Data("b".utf8).write(to: bFile)
        try Data("m".utf8).write(to: manualFile)

        let pins = BrowseCachePinRegistry()
        let contextA = UUID(), contextB = UUID()
        pins.setPinnedFiles([aFile, bFile, manualFile], owner: "owner-a", context: contextA, root: root)
        pins.setPinnedFiles([bFile], owner: "owner-b", context: contextB, root: root)
        XCTAssertEqual(pins.pinnedPaths(owner: "owner-a"), [aFile.path])
        XCTAssertEqual(pins.pinnedPaths(owner: "owner-b"), [bFile.path])

        pins.clear(owner: "owner-a")
        XCTAssertTrue(pins.pinnedPaths(owner: "owner-a").isEmpty)
        XCTAssertEqual(pins.pinnedPaths(owner: "owner-b"), [bFile.path])
        pins.releasePinnedFiles(context: contextB)
        XCTAssertTrue(pins.pinnedPaths(owner: "owner-b").isEmpty)
    }

    func testPerFileDeleteRechecksPinsAtTheDeletionBoundary() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = "owner-a"
        let ownerDirectory = root.appendingPathComponent(owner, isDirectory: true)
        try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)
        let file = ownerDirectory.appendingPathComponent("cache-a")
        try Data("cached".utf8).write(to: file)

        let pins = BrowseCachePinRegistry()
        let context = UUID()
        pins.setPinnedFiles([file], owner: owner, context: context, root: root)
        XCTAssertEqual(try pins.removeIfUnpinned(file, owner: owner, root: root), .pinned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        pins.releasePinnedFiles(context: context)
        XCTAssertEqual(try pins.removeIfUnpinned(file, owner: owner, root: root), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPinnedFileMtimePersistenceIsSkippedUntilUnpinned() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = "owner-a"
        let ownerDirectory = root.appendingPathComponent(owner, isDirectory: true)
        try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)
        let file = ownerDirectory.appendingPathComponent("cache-a")
        let original = Date(timeIntervalSince1970: 100)
        try write("cache", to: file, modified: original)
        let requested = Date(timeIntervalSince1970: 200)
        let pins = BrowseCachePinRegistry()
        let context = UUID()
        pins.setPinnedFiles([file], owner: owner, context: context, root: root)

        XCTAssertFalse(pins.persistAccessDateIfUnpinned(file, owner: owner, root: root, date: requested))
        let pinnedMtime = try rawModificationDate(file)
        XCTAssertEqual(pinnedMtime.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 1)

        pins.releasePinnedFiles(context: context)
        XCTAssertTrue(pins.persistAccessDateIfUnpinned(file, owner: owner, root: root, date: requested))
        let updatedMtime = try rawModificationDate(file)
        XCTAssertEqual(updatedMtime.timeIntervalSince1970, requested.timeIntervalSince1970, accuracy: 1)
    }

    func testHotRecencyUpdatesKeepHeapBoundedByLiveEntries() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cache-a")
        try write("cache", to: file, modified: Date(timeIntervalSince1970: 10))
        let index = BrowseCacheIndex()
        try index.bootstrap(directory: root)

        for tick in 1...1_000 {
            _ = index.touch(file, at: Date(timeIntervalSince1970: TimeInterval(tick + 10)))
        }
        XCTAssertLessThanOrEqual(index.heapNodeCount, max(64, index.entryCount * 3))
    }

    func testRepositoryClearRemovesOnlyThatOwnersCacheAndIndex() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PNGProtocol.self]
        let repository = MediaRepository(root: root, configuration: configuration, browseCacheBudget: 1_000_000)
        let url = URL(string: "https://cache.fixture.hath.network/owner-isolation.png")!

        let ownerAFile = try await repository.file(for: url, owner: "owner-a")
        let ownerBFile = try await repository.file(for: url, owner: "owner-b")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerAFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerBFile.path))
        XCTAssertNotEqual(ownerAFile.deletingLastPathComponent(), ownerBFile.deletingLastPathComponent())

        try await repository.clear(owner: "owner-a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerAFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerBFile.path))
    }
}

import XCTest
import Foundation
import ImageIO
@testable import ExViewer

final class MediaRepositoryV14Tests: XCTestCase {
    private final class ControlledURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var sequence = 0
        private static var instances: [Int: ControlledURLProtocol] = [:]
        private static var stoppedIDs = Set<Int>()

        private let instanceLock = NSLock()
        private var clientSnapshot: (any URLProtocolClient)?
        private var requestID: Int?
        private var stopped = false
        private var delivered = false

        private static let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "fixture.hath.network"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.sequence += 1
            let id = Self.sequence
            Self.lock.unlock()

            instanceLock.lock()
            requestID = id
            clientSnapshot = client
            instanceLock.unlock()

            Self.lock.lock()
            Self.instances[id] = self
            Self.lock.unlock()
        }

        override func stopLoading() {
            instanceLock.lock()
            stopped = true
            let id = requestID
            instanceLock.unlock()
            guard let id else { return }
            Self.lock.lock()
            Self.stoppedIDs.insert(id)
            Self.lock.unlock()
        }

        private func deliver() {
            instanceLock.lock()
            guard !delivered, !stopped,
                  let clientSnapshot, let url = request.url else {
                instanceLock.unlock()
                return
            }
            delivered = true
            instanceLock.unlock()

            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "image/png"])!
            clientSnapshot.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            clientSnapshot.urlProtocol(self, didLoad: Self.png)
            clientSnapshot.urlProtocolDidFinishLoading(self)
        }

        private func isPending() -> Bool {
            instanceLock.lock(); defer { instanceLock.unlock() }
            return !delivered && !stopped
        }

        static func reset() {
            lock.lock()
            instances.removeAll()
            stoppedIDs.removeAll()
            lock.unlock()
        }

        static func startedCount(for url: URL? = nil) -> Int {
            lock.lock(); defer { lock.unlock() }
            guard let url else { return instances.count }
            return instances.values.filter { $0.request.url == url }.count
        }

        static func stoppedCount(for url: URL? = nil) -> Int {
            lock.lock(); defer { lock.unlock() }
            guard let url else { return stoppedIDs.count }
            return instances.compactMap { id, instance in
                stoppedIDs.contains(id) && instance.request.url == url ? id : nil
            }.count
        }

        static func releaseOne(for url: URL) {
            lock.lock()
            let candidate = instances.sorted(by: { $0.key < $1.key }).first {
                $0.value.request.url == url && $0.value.isPending()
            }
            lock.unlock()
            candidate?.value.deliver()
        }

        static func releaseAll() {
            lock.lock(); let all = instances.sorted(by: { $0.key < $1.key }).map(\.value); lock.unlock()
            all.forEach { $0.deliver() }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func makeRepository() throws -> (MediaRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaRepositoryV14-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledURLProtocol.self]
        return (MediaRepository(root: root, configuration: configuration), root)
    }

    private func fixtureURL(_ label: String) -> URL {
        URL(string: "https://fixture.hath.network/\(label).png?case=\(UUID().uuidString)")!
    }

    private func assertDecodableImage(at url: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            XCTFail("Repository result is not an image source", file: file, line: line)
            return
        }
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 0, file: file, line: line)
    }

    func testSameOwnerURLSharesTransferAndOneCancellationLeavesOtherConsumer() async throws {
        ControlledURLProtocol.reset()
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { ControlledURLProtocol.releaseAll() }
        let url = fixtureURL("shared")
        let first = Task { try await repository.file(for: url, owner: "owner-a", request: MediaRequestDemand(priority: .foreground)) }
        let second = Task { try await repository.file(for: url, owner: "owner-a", request: MediaRequestDemand(priority: .foreground)) }
        defer { first.cancel(); second.cancel() }

        let oneTransferStarted = await waitUntil { ControlledURLProtocol.startedCount(for: url) == 1 }
        XCTAssertTrue(oneTransferStarted, "The shared URL should start one controlled transfer")
        // Let the actor register the second consumer while the first transfer is held.
        try? await Task.sleep(nanoseconds: 10_000_000)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("The cancelled consumer should finish with cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(ControlledURLProtocol.startedCount(for: url), 1)
        XCTAssertEqual(ControlledURLProtocol.stoppedCount(for: url), 0, "The shared transfer must remain active for the second consumer")
        ControlledURLProtocol.releaseOne(for: url)
        let secondFile = try await second.value
        assertDecodableImage(at: secondFile)
        let ownerDirectory = await repository.directory(owner: "owner-a")
        XCTAssertTrue(secondFile.path.hasPrefix(ownerDirectory.path))
        XCTAssertEqual(ControlledURLProtocol.startedCount(for: url), 1)
    }

    func testDifferentOwnersUseDistinctTransfersAndCachePaths() async throws {
        ControlledURLProtocol.reset()
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { ControlledURLProtocol.releaseAll() }
        let url = fixtureURL("owner-isolation")
        let first = Task { try await repository.file(for: url, owner: "owner-a", request: MediaRequestDemand(priority: .foreground)) }
        let second = Task { try await repository.file(for: url, owner: "owner-b", request: MediaRequestDemand(priority: .foreground)) }
        defer { first.cancel(); second.cancel() }

        let bothStarted = await waitUntil { ControlledURLProtocol.startedCount(for: url) == 2 }
        XCTAssertTrue(bothStarted, "Different owners must not share a transfer")
        ControlledURLProtocol.releaseOne(for: url)
        ControlledURLProtocol.releaseOne(for: url)
        let firstFile = try await first.value
        let secondFile = try await second.value
        assertDecodableImage(at: firstFile)
        assertDecodableImage(at: secondFile)
        XCTAssertNotEqual(firstFile, secondFile, "Cache destinations are owner scoped")
        let firstOwnerDirectory = await repository.directory(owner: "owner-a")
        let secondOwnerDirectory = await repository.directory(owner: "owner-b")
        XCTAssertTrue(firstFile.path.hasPrefix(firstOwnerDirectory.path))
        XCTAssertTrue(secondFile.path.hasPrefix(secondOwnerDirectory.path))
        XCTAssertEqual(ControlledURLProtocol.startedCount(for: url), 2)
    }

    func testTwoHeldThumbnailTransfersLeaveThirdPermitForForegroundReader() async throws {
        ControlledURLProtocol.reset()
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { ControlledURLProtocol.releaseAll() }
        let firstURL = fixtureURL("thumbnail-one")
        let secondURL = fixtureURL("thumbnail-two")
        let readerURL = fixtureURL("reader-current")
        let first = Task { try await repository.file(for: firstURL, owner: "thumb-a", request: MediaRequestDemand(priority: .thumbnail)) }
        let second = Task { try await repository.file(for: secondURL, owner: "thumb-b", request: MediaRequestDemand(priority: .thumbnail)) }
        defer { first.cancel(); second.cancel() }

        let thumbnailsStarted = await waitUntil { ControlledURLProtocol.startedCount() == 2 }
        XCTAssertTrue(thumbnailsStarted, "Both thumbnail transfers should occupy at most two permits")
        let reader = Task { try await repository.file(for: readerURL, owner: "reader", request: MediaRequestDemand(priority: .foreground)) }
        defer { reader.cancel() }
        let readerStartedWithoutRelease = await waitUntil { ControlledURLProtocol.startedCount(for: readerURL) == 1 }
        XCTAssertTrue(readerStartedWithoutRelease, "Foreground reader should start in the third permit while both thumbnails remain held")

        ControlledURLProtocol.releaseOne(for: firstURL)
        ControlledURLProtocol.releaseOne(for: secondURL)
        ControlledURLProtocol.releaseOne(for: readerURL)
        let files = try await (first.value, second.value, reader.value)
        assertDecodableImage(at: files.0)
        assertDecodableImage(at: files.1)
        assertDecodableImage(at: files.2)
        XCTAssertEqual(ControlledURLProtocol.startedCount(), 3)
    }

    func testClearOwnerCancelsHeldTransferWithoutRestoringCache() async throws {
        ControlledURLProtocol.reset()
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { ControlledURLProtocol.releaseAll() }
        let owner = "clear-owner"
        let url = fixtureURL("clear-held")
        let transfer = Task { try await repository.file(for: url, owner: owner, request: MediaRequestDemand(priority: .foreground)) }
        defer { transfer.cancel() }

        let started = await waitUntil { ControlledURLProtocol.startedCount(for: url) == 1 }
        XCTAssertTrue(started)
        try await repository.clear(owner: owner)
        let stopped = await waitUntil { ControlledURLProtocol.stoppedCount(for: url) == 1 }
        XCTAssertTrue(stopped, "Clearing the owner should cancel its in-flight transfer")
        ControlledURLProtocol.releaseAll()

        do {
            _ = try await transfer.value
            XCTFail("The cleared transfer must not complete successfully")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let ownerDirectory = await repository.directory(owner: owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerDirectory.path), "A late response must not recreate the cleared cache")
    }
}

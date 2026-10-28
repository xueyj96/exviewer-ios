import XCTest
import Foundation
import ImageIO
import ExViewerCore
@testable import ExViewer

@MainActor final class MediaLoadProgressV16Tests: XCTestCase {
    private final class PNGProtocol: URLProtocol, @unchecked Sendable {
        static let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "progress.fixture.hath.network"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let client else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "image/png",
                                                          "Content-Length": String(Self.png.count)])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Self.png)
            client.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { }
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MediaLoadProgress] = []
        func append(_ value: MediaLoadProgress) {
            lock.lock(); values.append(value); lock.unlock()
        }
        func snapshot() -> [MediaLoadProgress] {
            lock.lock(); defer { lock.unlock() }; return values
        }
    }

    @MainActor private final class HeldProgressLoader {
        var demands: [UUID: MediaRequestDemand] = [:]
        private var pending: [UUID: CheckedContinuation<URL, Error>] = [:]

        func load(_ page: GalleryPage, _ demand: MediaRequestDemand) async throws -> URL {
            _ = page.index
            return try await withCheckedThrowingContinuation { continuation in
                demands[demand.id] = demand
                pending[demand.id] = continuation
            }
        }

        func resolveAll() {
            for id in Array(pending.keys) {
                pending.removeValue(forKey: id)?.resume(returning: URL(fileURLWithPath: "/fixture/progress-\(id).png"))
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 5_000_000)
        await Task.yield()
    }

    func testFractionRequiresPositiveKnownLengthAndClamps() {
        XCTAssertNil(MediaLoadProgress().fraction)
        XCTAssertNil(MediaLoadProgress(phase: .transferring, completedBytes: 1, totalBytes: 0).fraction)
        XCTAssertEqual(MediaLoadProgress(phase: .transferring, completedBytes: 25, totalBytes: 100).fraction, 0.25)
        XCTAssertEqual(MediaLoadProgress(phase: .transferring, completedBytes: 120, totalBytes: 100).fraction, 1)
        XCTAssertEqual(MediaLoadProgress(phase: .transferring, completedBytes: -4, totalBytes: 100).fraction, 0)
    }

    func testForwardingRejectsReorderedAndDetachedSnapshotsAndAllowsNewBinding() {
        let consumer = MediaRequestDemand()
        let firstSource = MediaRequestDemand()
        let firstToken = UUID()
        consumer.beginProgressForwarding(source: firstSource.id, token: firstToken)
        let newer = MediaRequestDemand.ProgressSnapshot(
            producerUUID: firstSource.id, sequence: 2,
            value: MediaLoadProgress(phase: .transferring, completedBytes: 50, totalBytes: 100))
        let older = MediaRequestDemand.ProgressSnapshot(
            producerUUID: firstSource.id, sequence: 1,
            value: MediaLoadProgress(phase: .transferring, completedBytes: 25, totalBytes: 100))
        consumer.acceptForwardedProgress(newer, token: firstToken)
        consumer.acceptForwardedProgress(older, token: firstToken)
        XCTAssertEqual(consumer.progress, newer.value, "An older callback must not rewind a newer shared-flight snapshot")

        consumer.endProgressForwarding(token: firstToken)
        consumer.acceptForwardedProgress(
            MediaRequestDemand.ProgressSnapshot(producerUUID: firstSource.id, sequence: 3,
                                                value: MediaLoadProgress(phase: .transferring, completedBytes: 80, totalBytes: 100)),
            token: firstToken)
        XCTAssertEqual(consumer.progress, newer.value, "Callbacks after detach must be ignored")

        let secondToken = UUID()
        consumer.beginProgressForwarding(source: firstSource.id, token: secondToken)
        consumer.acceptForwardedProgress(newer, token: secondToken)
        let localReset = MediaLoadProgress(phase: .resolvingPage)
        consumer.reportProgress(localReset)
        consumer.acceptForwardedProgress(
            MediaRequestDemand.ProgressSnapshot(producerUUID: firstSource.id, sequence: 3,
                                                value: MediaLoadProgress(phase: .transferring, completedBytes: 80, totalBytes: 100)),
            token: secondToken)
        XCTAssertEqual(consumer.progress, localReset, "A direct local phase update ends forwarding for the old source")

        let retrySource = MediaRequestDemand()
        let retryToken = UUID()
        consumer.beginProgressForwarding(source: retrySource.id, token: retryToken)
        let reset = MediaRequestDemand.ProgressSnapshot(producerUUID: retrySource.id, sequence: 0,
                                                        value: MediaLoadProgress(phase: .resolvingPage))
        consumer.acceptForwardedProgress(reset, token: retryToken)
        XCTAssertEqual(consumer.progress, reset.value, "A new binding may reset progress to its initial phase")
    }

    func testFileTransferReportsRealBytesAndKnownTotal() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PNGProtocol.self]
        let client = MediaTransferClient(configuration: configuration)
        let demand = MediaRequestDemand()
        let observed = ProgressRecorder()
        let observer = demand.observeProgress { value in
            observed.append(value)
        }
        defer { demand.removeProgressObserver(observer) }

        let file = try await FileTransfer(limit: 64_000_000, client: client)
            .fetch(URL(string: "https://progress.fixture.hath.network/one.png")!, request: demand)
        defer { try? FileManager.default.removeItem(at: file) }

        let values = observed.snapshot()
        let transferred = try XCTUnwrap(values.last { $0.phase == .transferring && $0.completedBytes > 0 })
        XCTAssertEqual(transferred.completedBytes, Int64(PNGProtocol.png.count))
        XCTAssertEqual(transferred.totalBytes, Int64(PNGProtocol.png.count))
        XCTAssertEqual(transferred.fraction, 1)
        let source = CGImageSourceCreateWithURL(file as CFURL, nil)
        XCTAssertGreaterThan(source.map(CGImageSourceGetCount) ?? 0, 0)
    }

    func testOldGenerationProgressCannotReplaceCurrentPageProgress() async throws {
        let store = ReaderMediaStore()
        let page = GalleryPage(index: 1, url: URL(string: "https://ehentai.org/s/progress/1-1")!)
        let scopeA = ReaderMediaScope(galleryID: "ex:progress", owner: "owner", generation: UUID(), context: UUID())
        let scopeB = ReaderMediaScope(galleryID: "ex:progress", owner: "owner", generation: UUID(), context: UUID())
        let loader = HeldProgressLoader()

        store.update(scope: scopeA, pages: [page], current: 1, prefetchCount: 0,
                     demandLoader: { try await loader.load($0, $1) }, isCurrent: { true })
        let firstStarted = await waitUntil { loader.demands.count == 1 }
        XCTAssertTrue(firstStarted)
        let oldDemand = try XCTUnwrap(loader.demands.values.first)
        oldDemand.reportProgress(MediaLoadProgress(phase: .transferring, completedBytes: 20, totalBytes: 100))
        await settle()
        XCTAssertEqual(store.progress[1]?.completedBytes, 20)

        store.update(scope: scopeB, pages: [page], current: 1, prefetchCount: 0,
                     demandLoader: { try await loader.load($0, $1) }, isCurrent: { true })
        let secondStarted = await waitUntil { loader.demands.count == 2 }
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(store.progress[1]?.phase, .resolvingPage)

        oldDemand.reportProgress(MediaLoadProgress(phase: .transferring, completedBytes: 90, totalBytes: 100))
        await settle()
        XCTAssertEqual(store.progress[1]?.phase, .resolvingPage)
        XCTAssertEqual(store.progress[1]?.completedBytes, 0)

        loader.resolveAll()
        await settle()
        store.reset()
    }
}

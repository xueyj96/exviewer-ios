import XCTest
import ExViewerCore
@testable import ExViewer

final class ExViewerStorageTests: XCTestCase {
    func testSessionVaultRoundTripUsesAppKeychainIdentity() throws {
        let service = "com.xueyj.exviewer.qa.nonsecret-vault." + UUID().uuidString
        defer { try? SessionVault.delete(service: service) }
        XCTAssertTrue(try SessionVault.read(service: service).isEmpty)
        try SessionVault.save([], service: service)
        XCTAssertTrue(try SessionVault.read(service: service).isEmpty)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "qa_nonsecret", .value: "fixture", .domain: "example.invalid", .path: "/", .secure: "TRUE"]))
        try SessionVault.save([SessionCookie(cookie)], service: service)
        XCTAssertEqual(try SessionVault.read(service: service).map(\.name), ["qa_nonsecret"])
        try SessionVault.delete(service: service)
        XCTAssertTrue(try SessionVault.read(service: service).isEmpty)
    }

    @MainActor func testManualFileOverBrowseLimitIsReusedAndSurvivesCacheClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManualStorageTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("page-1.media")
        try FileManager.default.copyItem(at: QASamples.image(index: 2), to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 65_000_000)
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let repository = MediaRepository()
        let valid = await repository.hasValidManualFile(at: file)
        guard valid else { XCTFail("Local manual-file fixture is not decodable; network fallback must not run."); return }
        // Existing durable files must be reindexed without a network request or cache size check.
        let result = try await repository.saveManual(url: URL(string: "https://ehgt.org/manual-test.png")!, destination: file)
        XCTAssertEqual(result, file)
        try await repository.clear(owner: "storage-test-" + UUID().uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, 65_000_001)
    }

    @MainActor func testPersistenceFailureStopsWaitingQueue() async {
        let library = LibraryStore(qa: true)
        defer { try? FileManager.default.removeItem(at: library.directory.deletingLastPathComponent()) }
        let manager = DownloadManager(session: SiteSession(qa: true), library: library)
        let gallery = QASamples.galleries[0]
        manager.enqueue(gallery)
        // Fail before the deferred job starts; its waiting state cannot be committed away.
        library.error = "Test storage unavailable"
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNil(manager.running)
        XCTAssertEqual(library.snapshot.downloads.count, 1)
        XCTAssertEqual(library.snapshot.downloads.first?.status, .waiting)
    }

    @MainActor func testPausedTaskCannotWriteIntoAnotherLibrary() async {
        let library = LibraryStore(qa: true)
        let root = library.directory.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DownloadManager(session: SiteSession(qa: true), library: library)
        manager.enqueue(QASamples.galleries[0])
        manager.pauseAll()
        library.load(owner: "abcdef")
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNil(manager.running)
        XCTAssertTrue(library.snapshot.downloads.isEmpty)
        library.load(owner: "guest")
        XCTAssertEqual(library.snapshot.downloads.first?.status, .paused)
    }
}

final class MediaFixtureProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case http(Int, String), failure(URLError.Code), challenge, wait }
    private static let lock = NSLock()
    private static var reply: Reply = .failure(.unsupportedURL)
    static func use(_ value: Reply) { lock.lock(); reply = value; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "fixture.hath.network" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        Self.lock.lock(); let reply = Self.reply; Self.lock.unlock()
        switch reply {
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .challenge:
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html", "cf-mitigated": "challenge"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .http(let status, let mime):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
            client?.urlProtocolDidFinishLoading(self)
        case .wait: break
        }
    }
    override func stopLoading() { }
}

final class ExViewerMediaTests: XCTestCase {
    private func transfer(_ reply: MediaFixtureProtocol.Reply) -> FileTransfer {
        MediaFixtureProtocol.use(reply)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaFixtureProtocol.self]
        return FileTransfer(limit: 64_000_000, configuration: configuration)
    }
    private let media = URL(string: "https://fixture.hath.network:10443/nonsecret-image.png")!
    private func source() throws -> ImageSource {
        try EHParser.image("<img id='img' src='https://fixture.hath.network:10443/nonsecret-image.png'>", base: GallerySite.ex.baseURL)
    }

    func testTransportStatusSurvivesWithoutIncludingURL() async {
        for code: URLError.Code in [.timedOut, .cannotFindHost, .secureConnectionFailed, .notConnectedToInternet] {
            do { _ = try await transfer(.failure(code)).fetch(media); XCTFail("Expected transport failure") }
            catch {
                XCTAssertEqual(error as? RequestFailure, .transport(.media, code.rawValue))
                XCTAssertFalse(ErrorMessages.message(error).contains("fixture.hath.network"))
            }
        }
    }
    func testHTTPStatusAndQuotaRemainDistinct() async {
        for code in [429, 503, 509] {
            do { _ = try await transfer(.http(code, "image/png")).fetch(media); XCTFail("Expected HTTP failure") }
            catch {
                if code == 509 { XCTAssertEqual(error as? ViewerError, .imageLimit) }
                else { XCTAssertEqual(error as? RequestFailure, .http(.media, code)) }
            }
        }
    }
    func testUnexpectedHTMLIsNotReportedAsAnImageDecodeFailure() async {
        do { _ = try await transfer(.http(200, "text/html")).fetch(media); XCTFail("Expected non-image response") }
        catch { XCTAssertEqual(error as? RequestFailure, .nonImage) }
    }
    func testCancelledTransferRemainsCancellation() async {
        let loader = transfer(.wait)
        let task = Task { try await loader.fetch(media) }
        for _ in 0..<4 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testRecoverableMediaFailureResolvesPageOnlyOnceMore() async throws {
        var pages = 0, images = 0
        let file = URL(fileURLWithPath: "/nonsecret-fixture.media")
        let result = try await PageMediaLoader.file(resolvePage: {
            pages += 1; return try self.source()
        }, loadMedia: { _ in
            images += 1
            if images == 1 { throw RequestFailure.http(.media, 404) }
            return file
        }, isCurrent: { true })
        XCTAssertEqual(result, file); XCTAssertEqual(pages, 2); XCTAssertEqual(images, 2)
    }
    @MainActor func testQuotaVerificationAndRateLimitNeverAutoRetry() async {
        let errors: [Error] = [ViewerError.imageLimit, ViewerError.challenge, RequestFailure.http(.media, 403), RequestFailure.http(.media, 429)]
        for expected in errors {
            var pages = 0, images = 0
            do {
                _ = try await PageMediaLoader.file(resolvePage: {
                    pages += 1; return try self.source()
                }, loadMedia: { _ in images += 1; throw expected }, isCurrent: { true })
                XCTFail("Expected a terminal error")
            } catch { }
            XCTAssertEqual(pages, 1); XCTAssertEqual(images, 1)
        }
    }
    @MainActor func testAccountChangeStopsImagePageRefresh() async {
        var pages = 0, current = true
        do {
            _ = try await PageMediaLoader.file(resolvePage: {
                pages += 1; return try self.source()
            }, loadMedia: { _ in current = false; throw RequestFailure.http(.media, 404) }, isCurrent: { current })
            XCTFail("Expected stale session")
        } catch { XCTAssertEqual(error as? ViewerError, .stale) }
        XCTAssertEqual(pages, 1)
    }
    @MainActor func testActualMediaChallengeDoesNotEnterPageRefresh() async {
        var pages = 0, images = 0
        let loader = transfer(.challenge)
        do {
            _ = try await PageMediaLoader.file(resolvePage: { pages += 1; return try self.source() },
                                              loadMedia: { url in images += 1; return try await loader.fetch(url) },
                                              isCurrent: { true })
            XCTFail("Expected website verification")
        } catch { XCTAssertEqual(error as? ViewerError, .challenge) }
        XCTAssertEqual(pages, 1); XCTAssertEqual(images, 1)
    }
}

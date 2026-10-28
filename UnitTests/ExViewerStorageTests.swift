import XCTest
import ExViewerCore
@testable import ExViewer

final class ExViewerStorageTests: XCTestCase {
    private func historyRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SearchHistoryTest-" + UUID().uuidString)
    }

    @MainActor func testRecentSearchRoundTripPreservesLegacyLibraryAndManualFiles() throws {
        let root = historyRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(qa: true, storageRoot: root)
        var query = SearchQuery(); query.text = "coast"; query.titleOnly = true; query.artist = "Sample Artist"
        query.rules = [.init(tag: .init(namespace: "language", name: "English")), .init(tag: .init(namespace: "other", name: "city"), match: .exclude)]
        query.excludedCategories = [1, 32]; query.minRating = 4; query.minPages = 24; query.maxPages = 400; query.requireTorrent = true
        var legacy = LibrarySnapshot()
        legacy.saved = [.init(name: "Existing common", site: .ex, query: query)]
        legacy.favoriteTags = [.init(namespace: "language", name: "english")]
        legacy.blockedTags = [.init(namespace: "other", name: "city")]
        legacy.bookmarks = [QASamples.galleries[0]]
        let legacyData = try JSONEncoder().encode(legacy)
        let file = library.directory.appendingPathComponent("library.json")
        try legacyData.write(to: file)
        let manual = library.directory.appendingPathComponent("Offline/retained/page.media")
        try FileManager.default.createDirectory(at: manual.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manualData = Data("retained manual fixture".utf8); try manualData.write(to: manual)
        library.load(owner: "guest")
        XCTAssertTrue(library.recordSearch(query: query, site: .eh))
        XCTAssertEqual(try Data(contentsOf: file), legacyData, "Recent searches must not rewrite or migrate the original library")
        let reopened = LibraryStore(qa: true, storageRoot: root)
        XCTAssertNil(reopened.error); XCTAssertNil(reopened.searchHistoryError)
        XCTAssertEqual(reopened.recentSearches.count, 1)
        XCTAssertEqual(reopened.recentSearches.first?.query, query)
        XCTAssertEqual(reopened.recentSearches.first?.site, .eh)
        XCTAssertEqual(reopened.snapshot.saved.first?.name, "Existing common")
        XCTAssertEqual(reopened.snapshot.bookmarks.count, 1)
        XCTAssertEqual(try Data(contentsOf: manual), manualData)
        XCTAssertTrue(reopened.clearSearchHistory())
        XCTAssertEqual(try Data(contentsOf: file), legacyData)
        XCTAssertEqual(try Data(contentsOf: manual), manualData)
    }

    @MainActor func testRecentSearchDeduplicationUsesAllConditionsAndSite() throws {
        let root = historyRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(qa: true, storageRoot: root)
        var query = SearchQuery(); query.text = "coast"
        query.rules = [.init(tag: .init(namespace: "language", name: "ENGLISH")), .init(tag: .init(namespace: "other", name: "city"), match: .exclude)]
        XCTAssertTrue(library.recordSearch(query: query, site: .ex)); let id = library.recentSearches[0].id
        var equivalent = query; equivalent.rules.reverse(); equivalent.rules[1].tag.name = "english"
        XCTAssertTrue(library.recordSearch(query: equivalent, site: .ex))
        XCTAssertEqual(library.recentSearches.count, 1); XCTAssertEqual(library.recentSearches[0].id, id)
        var rated = query; rated.minRating = 4
        XCTAssertTrue(library.recordSearch(query: rated, site: .ex))
        XCTAssertTrue(library.recordSearch(query: query, site: .eh))
        XCTAssertEqual(library.recentSearches.count, 3)
        XCTAssertEqual(library.recentSearches[0].site, .eh)
        XCTAssertEqual(library.recentSearches[1].query.minRating, 4)
        let savedID = try XCTUnwrap(library.saveSearch(name: "Full conditions", site: .eh, query: query))
        XCTAssertEqual(library.savedSearch(matching: equivalent, site: .eh)?.id, savedID)
        XCTAssertEqual(library.snapshot.saved[0].query, query)
        XCTAssertTrue(library.deleteRecentSearch(library.recentSearches[0].id))
        XCTAssertEqual(library.snapshot.saved.count, 1)
    }

    @MainActor func testSearchHistoryIsBoundedAndSeparatedByAccount() {
        let root = historyRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(qa: true, storageRoot: root)
        XCTAssertFalse(library.recordSearch(query: SearchQuery(), site: .ex))
        var invalid = SearchQuery(); invalid.text = String(repeating: "x", count: 250)
        XCTAssertFalse(library.recordSearch(query: invalid, site: .ex))
        for i in 0..<105 { var query = SearchQuery(); query.text = "search \(i)"; XCTAssertTrue(library.recordSearch(query: query, site: .ex)) }
        XCTAssertEqual(library.recentSearches.count, LibraryStore.searchHistoryLimit)
        XCTAssertEqual(library.recentSearches.first?.query.text, "search 104")
        library.load(owner: "abcdef")
        XCTAssertTrue(library.recentSearches.isEmpty)
        var other = SearchQuery(); other.text = "other account"
        XCTAssertTrue(library.recordSearch(query: other, site: .eh))
        library.load(owner: "guest")
        XCTAssertEqual(library.recentSearches.count, LibraryStore.searchHistoryLimit)
        XCTAssertEqual(library.recentSearches.first?.query.text, "search 104")
    }

    @MainActor func testCorruptSearchHistoryIsPreservedWithoutBlockingFavorites() throws {
        let root = historyRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(qa: true, storageRoot: root)
        let file = library.directory.appendingPathComponent("recent-searches.json")
        let corrupt = Data("not a valid search history".utf8); try corrupt.write(to: file)
        library.load(owner: "guest")
        XCTAssertNotNil(library.searchHistoryError); XCTAssertNil(library.error)
        var query = SearchQuery(); query.text = "valid search"
        XCTAssertFalse(library.recordSearch(query: query, site: .ex))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertNotNil(library.saveSearch(name: "Still works", site: .ex, query: query))
        XCTAssertTrue(library.clearSearchHistory()); XCTAssertNil(library.searchHistoryError)
        XCTAssertTrue(library.recordSearch(query: query, site: .ex))
        XCTAssertEqual(library.snapshot.saved.count, 1)
    }

    @MainActor func testSearchHistoryWriteFailureKeepsExistingMemoryAndLibraryWritable() throws {
        let root = historyRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(qa: true, storageRoot: root)
        var query = SearchQuery(); query.text = "first"
        XCTAssertTrue(library.recordSearch(query: query, site: .ex))
        let file = library.directory.appendingPathComponent("recent-searches.json")
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("backup"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        query.text = "second"
        XCTAssertFalse(library.recordSearch(query: query, site: .ex))
        XCTAssertEqual(library.recentSearches.map(\.query.text), ["first"])
        XCTAssertNotNil(library.searchHistoryError); XCTAssertNil(library.error)
        XCTAssertNotNil(library.saveSearch(name: "Saved independently", site: .ex, query: query))
    }

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

import XCTest
import Foundation
import ExViewerCore
@testable import ExViewer

@MainActor final class SiteSessionV18Tests: XCTestCase {
    private final class PageProtocol: URLProtocol, @unchecked Sendable {
        enum Plan { case lost, hold, response(Int, String, [String: String]) }
        private static let lock = NSLock()
        private static var handler: (String, Int) -> Plan = { _, _ in .response(200, "<html>ok</html>", [:]) }
        private static var counts: [String: Int] = [:]
        private static var starts: [String: [TimeInterval]] = [:]
        private static var active: [ObjectIdentifier: Bool] = [:]
        private static var peak = 0
        private static var backgroundPeak = 0
        private let stateLock = NSLock()
        private var finished = false

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "e-hentai.org" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        static func reset(_ next: @escaping (String, Int) -> Plan) {
            lock.lock(); defer { lock.unlock() }
            handler = next; counts = [:]; starts = [:]; active = [:]; peak = 0; backgroundPeak = 0
        }
        static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
        static func times(_ path: String) -> [TimeInterval] { lock.lock(); defer { lock.unlock() }; return starts[path] ?? [] }
        static func peaks() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (peak, backgroundPeak) }
        static func total() -> Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }

        override func startLoading() {
            guard let url = request.url else { return }
            let path = url.path
            Self.lock.lock()
            let count = (Self.counts[path] ?? 0) + 1
            Self.counts[path] = count
            Self.starts[path, default: []].append(ProcessInfo.processInfo.systemUptime)
            Self.active[ObjectIdentifier(self)] = path.hasPrefix("/prefetch")
            Self.peak = max(Self.peak, Self.active.count)
            Self.backgroundPeak = max(Self.backgroundPeak, Self.active.values.filter { $0 }.count)
            let plan = Self.handler(path, count)
            Self.lock.unlock()
            switch plan {
            case .hold: return
            case .lost:
                complete()
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case let .response(status, body, headers):
                var headers = headers; headers["Content-Type"] = "text/html; charset=utf-8"
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                complete()
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() { complete() }
        private func complete() {
            stateLock.lock()
            guard !finished else { stateLock.unlock(); return }
            finished = true; stateLock.unlock()
            Self.lock.lock(); Self.active.removeValue(forKey: ObjectIdentifier(self)); Self.lock.unlock()
        }
    }

    private func session(interval: TimeInterval = 0, limit: Int = 2) -> SiteSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageProtocol.self]
        return SiteSession(qa: true, configuration: config, searchInterval: interval, pageConcurrencyLimit: { limit })
    }
    private func url(_ path: String) -> URL { URL(string: "https://e-hentai.org\(path)")! }
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 { if condition() { return true }; try? await Task.sleep(nanoseconds: 5_000_000) }
        return condition()
    }

    func testSearchConnectionLossRetriesOnceAndEveryActualDispatchRemainsPaced() async throws {
        XCTAssertEqual(URLError.networkConnectionLost.rawValue, -1005)
        PageProtocol.reset { _, count in count == 1 ? .lost : .response(200, "<html>recovered</html>", [:]) }
        let session = session(interval: 0.65)
        let result = try await session.html(url("/search-recover"), search: true)
        XCTAssertTrue(result.contains("recovered"))
        XCTAssertEqual(PageProtocol.count("/search-recover"), 2)
        let times = PageProtocol.times("/search-recover")
        XCTAssertEqual(times.count, 2)
        XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.64, "The retry must re-enter actual search dispatch pacing")
    }

    func testPersistentSearchConnectionLossStopsAfterTwoAttempts() async {
        PageProtocol.reset { _, _ in .lost }
        let session = session()
        do { _ = try await session.html(url("/search-lost"), search: true); XCTFail("Expected bounded failure") }
        catch { XCTAssertEqual(error as? RequestFailure, .transport(.page, -1005)) }
        XCTAssertEqual(PageProtocol.count("/search-lost"), 2)
    }

    func testFavoritePostConnectionLossIsNeverRetried() async {
        PageProtocol.reset { _, _ in .lost }
        let session = session()
        do {
            _ = try await session.html(url("/favorites.php"), method: "POST", body: Data("fixture=local".utf8))
            XCTFail("Expected uncertain POST failure")
        } catch { XCTAssertEqual(error as? RequestFailure, .transport(.page, -1005)) }
        XCTAssertEqual(PageProtocol.count("/favorites.php"), 1)
    }

    func testAuthenticationChallengeQuotaAndRateLimitDoNotRetry() async {
        let cases: [(Int, String, [String: String])] = [
            (401, "<html>auth</html>", [:]), (429, "<html>rate</html>", [:]),
            (503, "<html>unavailable</html>", [:]), (509, "<html>quota</html>", [:]),
            (403, "<html>just a moment...</html>", ["cf-mitigated": "challenge"])
        ]
        for (status, body, headers) in cases {
            PageProtocol.reset { _, _ in .response(status, body, headers) }
            let session = session()
            do { _ = try await session.html(url("/protected"), search: true); XCTFail("Expected failure for \(status)") }
            catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(PageProtocol.count("/protected"), 1, "HTTP \(status) must not auto-retry")
        }
    }

    func testReadingPipelineKeepsOneTwoAttemptBudgetWithoutNestedGetRetries() async {
        PageProtocol.reset { _, _ in .lost }
        let session = session()
        do {
            _ = try await PageMediaLoader.file(resolvePage: {
                _ = try await session.html(self.url("/reader-page"), recoverConnection: false)
                throw RequestFailure.nonImage
            }, loadMedia: { _ in URL(fileURLWithPath: "/local-fixture-never-loaded") }, isCurrent: { true })
            XCTFail("Expected bounded page failure")
        } catch { XCTAssertEqual(error as? RequestFailure, .transport(.page, -1005)) }
        XCTAssertEqual(PageProtocol.count("/reader-page"), 2, "PageMediaLoader and html must not multiply into four requests")
    }

    func testSixteenSpeculativePagesUseOneBackgroundSlotAndSearchPasses() async throws {
        PageProtocol.reset { path, _ in path.hasPrefix("/prefetch") ? .hold : .response(200, "<html>foreground</html>", [:]) }
        let session = session()
        let speculative = (0..<16).map { index in
            Task { try await session.html(self.url("/prefetch/\(index)"), request: MediaRequestDemand(priority: .prefetch)) }
        }
        defer { speculative.forEach { $0.cancel() } }
        let started = await waitUntil { PageProtocol.total() == 1 }
        XCTAssertTrue(started)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(PageProtocol.total(), 1, "Speculative HTML must not burst sixteen requests before media gating")
        let result = try await session.html(url("/foreground-search"), search: true)
        XCTAssertTrue(result.contains("foreground"))
        XCTAssertEqual(PageProtocol.count("/foreground-search"), 1)
        let peaks = PageProtocol.peaks()
        XCTAssertLessThanOrEqual(peaks.0, 2)
        XCTAssertEqual(peaks.1, 1)
        speculative.forEach { $0.cancel() }
        for request in speculative { _ = try? await request.value }
        XCTAssertEqual(PageProtocol.total(), 2, "Canceled queued prefetches must not reach transport")
    }
}

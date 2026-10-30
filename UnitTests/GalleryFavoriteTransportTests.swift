import XCTest
import Foundation
import ExViewerCore
@testable import ExViewer

@MainActor final class GalleryFavoriteTransportTests: XCTestCase {
    private final class ProtocolStub: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var observed: [String: String] = [:]
        private static var calls = 0
        private static var lose = false
        static func reset(lost: Bool = false) { lock.lock(); defer { lock.unlock() }; observed = [:]; calls = 0; lose = lost }
        static func snapshot() -> ([String: String], Int) { lock.lock(); defer { lock.unlock() }; return (observed, calls) }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            Self.calls += 1
            Self.observed = ["method": request.httpMethod ?? "", "origin": request.value(forHTTPHeaderField: "Origin") ?? "", "referer": request.value(forHTTPHeaderField: "Referer") ?? "", "contentType": request.value(forHTTPHeaderField: "Content-Type") ?? ""]
            let lost = Self.lose; Self.lock.unlock()
            if lost { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<html>neutral response</html>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func session() -> SiteSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProtocolStub.self]
        return SiteSession(qa: true, configuration: config, pageConcurrencyLimit: { 2 })
    }
    func testPopupPostHasSameOriginHeadersAndFormEncoding() async throws {
        ProtocolStub.reset()
        let url = try GalleryFavoriteForm.endpoint(for: .init(site: .ex, gid: 42, token: "preview"))
        _ = try await session().html(url, method: "POST", body: Data("favcat=1&update=1".utf8))
        let (headers, count) = ProtocolStub.snapshot()
        XCTAssertEqual(headers["method"], "POST"); XCTAssertEqual(headers["origin"], "https://exhentai.org")
        XCTAssertEqual(headers["referer"], url.absoluteString); XCTAssertEqual(headers["contentType"], "application/x-www-form-urlencoded")
        XCTAssertEqual(count, 1)
    }
    func testLostPopupPostIsNotRetriedByTransport() async throws {
        ProtocolStub.reset(lost: true)
        let url = try GalleryFavoriteForm.endpoint(for: .init(site: .eh, gid: 42, token: "preview"))
        do { _ = try await session().html(url, method: "POST", body: Data("favcat=1&update=1".utf8)); XCTFail("Expected connection failure") }
        catch { XCTAssertEqual(error as? RequestFailure, .transport(.page, URLError.networkConnectionLost.rawValue)) }
        XCTAssertEqual(ProtocolStub.snapshot().1, 1)
    }
    func testPopupWriteCannotRedirectToAnotherOrigin() throws {
        let url = try GalleryFavoriteForm.endpoint(for: .init(site: .ex, gid: 42, token: "preview"))
        let client = URLSession(configuration: .ephemeral); defer { client.invalidateAndCancel() }
        var source = URLRequest(url: url); source.httpMethod = "POST"
        let task = client.dataTask(with: source); defer { task.cancel() }
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        var called = false, rejected = false
        SafeRedirect().urlSession(client, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://e-hentai.org/gallerypopups.php")!)) { result in called = true; rejected = result == nil }
        XCTAssertTrue(called); XCTAssertTrue(rejected)
    }
}

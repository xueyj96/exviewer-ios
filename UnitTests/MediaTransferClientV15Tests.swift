import XCTest
import Foundation
import ImageIO
@testable import ExViewer

final class MediaTransferClientV15Tests: XCTestCase {
    private final class ControlledURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var instances: [String: ControlledURLProtocol] = [:]

        private let instanceLock = NSLock()
        private var clientSnapshot: (any URLProtocolClient)?
        private var stopped = false
        private var delivered = false

        private static let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "media-transfer.fixture.hath.network"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            instanceLock.lock()
            clientSnapshot = client
            instanceLock.unlock()

            guard let path = request.url?.path else { return }
            Self.lock.lock()
            Self.instances[path] = self
            Self.lock.unlock()

            // The cancellation case stays pending until URLSession cancels it.
            guard path != "/hold.png" else { return }
            deliver(path: path)
        }

        override func stopLoading() {
            instanceLock.lock()
            stopped = true
            instanceLock.unlock()
        }

        private func deliver(path: String) {
            instanceLock.lock()
            guard !delivered, !stopped,
                  let clientSnapshot, let url = request.url else {
                instanceLock.unlock()
                return
            }
            delivered = true
            instanceLock.unlock()

            let isHTML = path == "/html"
            let mime = isHTML ? "text/html" : "image/png"
            let body = isHTML ? Data("<html>not an image</html>".utf8) : Self.png
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": mime])!
            clientSnapshot.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            clientSnapshot.urlProtocol(self, didLoad: body)
            clientSnapshot.urlProtocolDidFinishLoading(self)
        }

        static func reset() {
            lock.lock(); instances.removeAll(); lock.unlock()
        }

        static func started(_ paths: Set<String>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return paths.allSatisfy { instances[$0] != nil }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func makeClient() -> MediaTransferClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledURLProtocol.self]
        return MediaTransferClient(configuration: configuration)
    }

    private func fixture(_ path: String) -> URL {
        URL(string: "https://media-transfer.fixture.hath.network\(path)")!
    }

    func testCancellingOneTaskDoesNotCancelAnotherTaskOnSharedClient() async throws {
        ControlledURLProtocol.reset()
        let client = makeClient()
        let heldTransfer = FileTransfer(limit: 64_000_000, client: client)
        let imageTransfer = FileTransfer(limit: 64_000_000, client: client)
        let held = Task { try await heldTransfer.fetch(fixture("/hold.png")) }
        let image = Task { try await imageTransfer.fetch(fixture("/image.png")) }
        defer { held.cancel(); image.cancel() }

        let bothStarted = await waitUntil { ControlledURLProtocol.started(["/hold.png", "/image.png"]) }
        XCTAssertTrue(bothStarted, "Both independent tasks should reach the controlled URLProtocol")
        held.cancel()
        do {
            _ = try await held.value
            XCTFail("The held task should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let imageFile = try await image.value
        defer { try? FileManager.default.removeItem(at: imageFile) }
        let source = CGImageSourceCreateWithURL(imageFile as CFURL, nil)
        XCTAssertNotNil(source)
        XCTAssertGreaterThan(source.map(CGImageSourceGetCount) ?? 0, 0)
    }

    func testNonImageResponseFailsOnlyItsOwnTask() async throws {
        ControlledURLProtocol.reset()
        let client = makeClient()
        let htmlTransfer = FileTransfer(limit: 64_000_000, client: client)
        let imageTransfer = FileTransfer(limit: 64_000_000, client: client)
        let html = Task { try await htmlTransfer.fetch(fixture("/html")) }
        let image = Task { try await imageTransfer.fetch(fixture("/image.png")) }
        defer { html.cancel(); image.cancel() }

        let bothStarted = await waitUntil { ControlledURLProtocol.started(["/html", "/image.png"]) }
        XCTAssertTrue(bothStarted, "Both independent tasks should reach the controlled URLProtocol")
        do {
            _ = try await html.value
            XCTFail("The HTML response must fail image MIME validation")
        } catch {
            XCTAssertEqual(error as? RequestFailure, .nonImage)
        }

        let imageFile = try await image.value
        defer { try? FileManager.default.removeItem(at: imageFile) }
        let source = CGImageSourceCreateWithURL(imageFile as CFURL, nil)
        XCTAssertNotNil(source)
        XCTAssertGreaterThan(source.map(CGImageSourceGetCount) ?? 0, 0)
    }
}

import XCTest
import UIKit
@testable import ExViewer

@MainActor final class StaticCoverTests: XCTestCase {
    private actor ControlledDecoder: StaticCoverImageDecoding {
        private var requests: [String] = []
        private var continuations: [String: CheckedContinuation<UIImage?, Never>] = [:]

        func thumbnail(for file: URL, maxPixelSize: Int) async -> UIImage? {
            await withCheckedContinuation { continuation in
                let key = file.standardizedFileURL.path
                requests.append(key)
                continuations[key] = continuation
            }
        }

        func waitForRequest(_ file: URL) async -> Bool {
            let key = file.standardizedFileURL.path
            for _ in 0..<100 {
                if requests.contains(key) { return true }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return requests.contains(key)
        }

        func resolve(_ file: URL, with image: UIImage?) {
            continuations.removeValue(forKey: file.standardizedFileURL.path)?.resume(returning: image)
        }
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 96, height: 144)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 144))
        }
    }

    private func fixture(_ name: String, color: UIColor = .systemBlue) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("exviewer-static-cover-\(UUID().uuidString)-\(name).png")
        let data = image(color).pngData()!
        try data.write(to: file, options: .atomic)
        return file
    }

    func testConcurrentAndWarmRequestsReuseDecodedSource() async throws {
        let file = try fixture("reuse")
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = StaticCoverImageCache()

        async let first = cache.thumbnail(for: file, maxPixelSize: 160)
        async let second = cache.thumbnail(for: file, maxPixelSize: 160)
        let (firstResult, secondResult) = await (first, second)
        let firstImage = try XCTUnwrap(firstResult)
        let secondImage = try XCTUnwrap(secondResult)
        XCTAssertTrue(firstImage === secondImage, "Concurrent waiters should receive the same singleflight decode")
        let concurrentDecodeCount = await cache.decodedImageCount()
        XCTAssertEqual(concurrentDecodeCount, 1)

        let warmResult = await cache.thumbnail(for: file, maxPixelSize: 160)
        let warm = try XCTUnwrap(warmResult)
        XCTAssertTrue(firstImage === warm, "A warm cache hit should return the retained decoded image")
        let warmDecodeCount = await cache.decodedImageCount()
        XCTAssertEqual(warmDecodeCount, 1, "The warm hit must not decode the file again")
    }

    func testCancelledOldFileCannotReplaceNewFileAndOldImageStaysUntilSuccess() async throws {
        let firstFile = try fixture("first", color: .systemRed)
        let oldFile = try fixture("old", color: .systemOrange)
        let newFile = try fixture("new", color: .systemGreen)
        defer {
            try? FileManager.default.removeItem(at: firstFile)
            try? FileManager.default.removeItem(at: oldFile)
            try? FileManager.default.removeItem(at: newFile)
        }

        let decoder = ControlledDecoder()
        let model = StaticCoverModel(decoder: decoder)
        let initial = Task { await model.load(file: firstFile, contextIdentity: "owner-a/session-1", requestIdentity: "gallery-first", maxPixelSize: 64) }
        let initialRequested = await decoder.waitForRequest(firstFile)
        XCTAssertTrue(initialRequested)
        await decoder.resolve(firstFile, with: image(.systemRed))
        await initial.value
        XCTAssertEqual(model.displayedFile, firstFile.standardizedFileURL)

        let stale = Task { await model.load(file: oldFile, contextIdentity: "owner-a/session-1", requestIdentity: "gallery-old", maxPixelSize: 64) }
        let staleRequested = await decoder.waitForRequest(oldFile)
        XCTAssertTrue(staleRequested)
        XCTAssertEqual(model.displayedFile, firstFile.standardizedFileURL, "Keep the prior cover while a same-context replacement decodes")

        stale.cancel()
        let current = Task { await model.load(file: newFile, contextIdentity: "owner-a/session-1", requestIdentity: "gallery-new", maxPixelSize: 64) }
        let currentRequested = await decoder.waitForRequest(newFile)
        XCTAssertTrue(currentRequested)
        await decoder.resolve(newFile, with: image(.systemGreen))
        await current.value
        XCTAssertEqual(model.displayedFile, newFile.standardizedFileURL)

        await decoder.resolve(oldFile, with: image(.systemOrange))
        await stale.value
        XCTAssertEqual(model.displayedFile, newFile.standardizedFileURL, "A late cancelled decode must not restore the older file")
    }

    func testDecodeFailureReportsToOwnerAndContextChangeClearsPriorAccountImage() async throws {
        let firstFile = try fixture("account-a")
        let invalidFile = FileManager.default.temporaryDirectory.appendingPathComponent("exviewer-invalid-\(UUID().uuidString).media")
        try Data("not an image".utf8).write(to: invalidFile, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: firstFile)
            try? FileManager.default.removeItem(at: invalidFile)
        }

        let cache = StaticCoverImageCache()
        let model = StaticCoverModel(decoder: cache)
        await model.load(file: firstFile, contextIdentity: "owner-a/session-1", requestIdentity: "gallery-a", maxPixelSize: 64)
        XCTAssertNotNil(model.image)

        var failureCallbackCount = 0
        await model.load(file: invalidFile, contextIdentity: "owner-a/session-1", requestIdentity: "gallery-invalid", maxPixelSize: 64) {
            failureCallbackCount += 1
        }
        XCTAssertEqual(failureCallbackCount, 1, "The owner gets the decode failure so it can show its existing retry/error UI")
        XCTAssertEqual(model.displayedFile, firstFile.standardizedFileURL, "A failed replacement must leave the previous image intact")
        XCTAssertEqual(model.failedRequestIdentity, "gallery-invalid")

        model.updateContext("owner-b/session-2")
        XCTAssertNil(model.image, "Switching owner/session must immediately hide pixels from the old account context")
        XCTAssertNil(model.displayedFile)
    }
}

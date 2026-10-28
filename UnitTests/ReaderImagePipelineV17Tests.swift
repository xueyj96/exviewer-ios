import XCTest
import Foundation
import CoreGraphics
import ImageIO
import ExViewerCore
@testable import ExViewer

final class ReaderImagePipelineV17Tests: XCTestCase {
    private final class DecodeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var mainThreadFlags: [Bool] = []
        func recordDecodeThread() {
            lock.lock(); count += 1; mainThreadFlags.append(Thread.isMainThread); lock.unlock()
        }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        var allDecodesWereOffMain: Bool { lock.lock(); defer { lock.unlock() }; return !mainThreadFlags.isEmpty && mainThreadFlags.allSatisfy { !$0 } }
    }

    private final class DecodeGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 2) == .success }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderImagePipelineV17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func image(width: Int = 64, height: Int = 64, red: UInt8 = 30, green: UInt8 = 80, blue: UInt8 = 180) throws -> CGImage {
        let pixels = [red, green, blue, UInt8(255)]
        let data = Data((0..<(width * height)).flatMap { _ in pixels }) as CFData
        guard let provider = CGDataProvider(data: data),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false,
                                   intent: .defaultIntent) else {
            throw ViewerError.unsupported
        }
        return result
    }

    private func writePNG(_ file: URL, image: CGImage) throws {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else {
            throw ViewerError.storage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ViewerError.storage }
    }

    private func writeGIF(_ file: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "com.compuserve.gif" as CFString, 2, nil) else {
            throw ViewerError.storage
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let red = try image(red: 240, green: 20, blue: 10)
        let blue = try image(red: 10, green: 20, blue: 240)
        let frameProperties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]]
        CGImageDestinationAddImage(destination, red, frameProperties as CFDictionary)
        CGImageDestinationAddImage(destination, blue, frameProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ViewerError.storage }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    func testDecodedFrameCacheReusesImageAndReportsByteCost() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("single.png")
        try writePNG(file, image: image())
        let counter = DecodeCounter()
        let pipeline = ReaderImagePipeline(beforeFrameDecode: { _, _ in counter.recordDecodeThread() })
        let asset = try await pipeline.open(file: file, demand: MediaRequestDemand(priority: .foreground))
        let first = try await pipeline.frame(asset: asset, index: 0, demand: MediaRequestDemand(priority: .foreground))
        let cached = try XCTUnwrap(pipeline.cachedFrame(asset: asset, index: 0))
        let second = try await pipeline.frame(asset: asset, index: 0, demand: MediaRequestDemand(priority: .prefetch))

        XCTAssertEqual(asset.frameCount, 1)
        XCTAssertEqual(asset.pixelSize.width, 64)
        XCTAssertEqual(asset.pixelSize.height, 64)
        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(first.decodedBytes, first.image.bytesPerRow * first.image.height)
        XCTAssertEqual(cached.decodedBytes, first.decodedBytes)
        XCTAssertTrue(first.image === second.image, "A cache hit should return the same decoded CGImage")
        XCTAssertEqual(counter.value, 1, "One frame should be decoded once while it remains cached")
        XCTAssertTrue(counter.allDecodesWereOffMain, "The production decode operation must run away from the main thread")
        XCTAssertEqual(pipeline.cachedByteCount(), first.decodedBytes)
    }

    func testByteBoundedLRUEvictsLeastRecentlyUsedFrame() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.png")
        let secondURL = directory.appendingPathComponent("second.png")
        try writePNG(firstURL, image: image())
        try writePNG(secondURL, image: image(red: 190, green: 140, blue: 10))
        let counter = DecodeCounter()
        let pipeline = ReaderImagePipeline(cacheLimitBytes: 20_000,
                                           beforeFrameDecode: { _, _ in counter.recordDecodeThread() })
        let demand = MediaRequestDemand(priority: .foreground)
        let firstAsset = try await pipeline.open(file: firstURL, demand: demand)
        let secondAsset = try await pipeline.open(file: secondURL, demand: demand)
        let first = try await pipeline.frame(asset: firstAsset, index: 0, demand: demand)
        _ = try await pipeline.frame(asset: secondAsset, index: 0, demand: demand)

        XCTAssertLessThanOrEqual(pipeline.cachedByteCount(), 20_000)
        XCTAssertNil(pipeline.cachedFrame(asset: firstAsset, index: 0), "The older frame should be evicted to honor the byte limit")
        _ = try await pipeline.frame(asset: firstAsset, index: 0, demand: demand)
        XCTAssertEqual(counter.value, 3, "Requesting the evicted frame should decode it again")
    }

    func testCancellingOneSharedFrameConsumerKeepsOtherConsumerAlive() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shared.png")
        try writePNG(file, image: image())
        let gate = DecodeGate()
        let counter = DecodeCounter()
        let pipeline = ReaderImagePipeline(beforeFrameDecode: { _, _ in
            counter.recordDecodeThread()
            gate.entered.signal()
            _ = gate.release.wait(timeout: .now() + 2)
        })
        let asset = try await pipeline.open(file: file, demand: MediaRequestDemand(priority: .foreground))
        let first = Task { try await pipeline.frame(asset: asset, index: 0, demand: MediaRequestDemand(priority: .prefetch)) }
        let entered = gate.waitUntilEntered()
        let second = Task { try await pipeline.frame(asset: asset, index: 0, demand: MediaRequestDemand(priority: .foreground)) }
        let shared = await waitUntil { pipeline.consumerCountForTesting(asset: asset, index: 0) == 2 }
        first.cancel()
        gate.release.signal()

        var firstWasCancelled = false
        do { _ = try await first.value }
        catch is CancellationError { firstWasCancelled = true }
        let result = try await second.value
        XCTAssertTrue(entered, "The controlled decode should have started")
        XCTAssertTrue(shared, "Both consumers should join the same in-flight decode")
        XCTAssertTrue(firstWasCancelled)
        XCTAssertEqual(result.index, 0)
        XCTAssertEqual(counter.value, 1, "Cancelling one consumer must not restart or cancel the shared operation")
    }

    func testAnimatedAssetOpensMetadataAndDecodesRequestedGIFFrames() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("two-frames.gif")
        try writeGIF(file)
        let pipeline = ReaderImagePipeline()
        let demand = MediaRequestDemand(priority: .foreground)
        let asset = try await pipeline.open(file: file, demand: demand)
        let frame0 = try await pipeline.frame(asset: asset, index: 0, demand: demand)
        let frame1 = try await pipeline.frame(asset: asset, index: 1, demand: demand)

        XCTAssertEqual(asset.frameCount, 2)
        XCTAssertEqual(frame0.index, 0)
        XCTAssertEqual(frame1.index, 1)
        XCTAssertEqual(frame0.image.width, frame1.image.width)
        XCTAssertGreaterThanOrEqual(frame0.duration, 0.02)
        XCTAssertGreaterThanOrEqual(frame1.duration, 0.02)
        XCTAssertFalse(frame0.image === frame1.image)
    }

    func testCacheClearDuringDecodePreventsOldWorkFromRefillingCache() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory-warning.png")
        try writePNG(file, image: image())
        let gate = DecodeGate()
        let counter = DecodeCounter()
        let pipeline = ReaderImagePipeline(beforeFrameDecode: { _, _ in
            counter.recordDecodeThread()
            gate.entered.signal()
            _ = gate.release.wait(timeout: .now() + 2)
        })
        let demand = MediaRequestDemand(priority: .foreground)
        let asset = try await pipeline.open(file: file, demand: demand)
        let pending = Task { try await pipeline.frame(asset: asset, index: 0, demand: demand) }
        let entered = gate.waitUntilEntered()
        pipeline.clearCache()
        gate.release.signal()
        _ = try await pending.value

        XCTAssertTrue(entered)
        XCTAssertNil(pipeline.cachedFrame(asset: asset, index: 0))
        XCTAssertEqual(pipeline.cachedByteCount(), 0)
        _ = try await pipeline.frame(asset: asset, index: 0, demand: demand)
        XCTAssertEqual(counter.value, 2, "A post-memory-warning request should decode into the new cache generation")
    }
}

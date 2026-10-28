import SwiftUI
import UIKit
import ImageIO

protocol StaticCoverImageDecoding: Sendable {
    func thumbnail(for file: URL, maxPixelSize: Int) async -> UIImage?
}

actor StaticCoverImageCache: StaticCoverImageDecoding {
    static let shared = StaticCoverImageCache()

    private struct Key: Hashable {
        let path: String
        let byteCount: Int64
        let modifiedAt: TimeInterval
        let maxPixelSize: Int
    }

    private struct Flight {
        let id: UUID
        let task: Task<UIImage?, Never>
    }

    private static let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ExViewer.StaticCover.ImageIO"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 64
        return cache
    }()
    private var flights: [Key: Flight] = [:]
    private var decodeCount = 0

    init() {}

    func thumbnail(for file: URL, maxPixelSize: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let size = min(1024, max(1, maxPixelSize))
        let values = try? FileManager.default.attributesOfItem(atPath: file.standardizedFileURL.path)
        let byteCount = (values?[.size] as? NSNumber)?.int64Value ?? -1
        let modifiedAt = (values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = Key(path: file.standardizedFileURL.path, byteCount: byteCount, modifiedAt: modifiedAt, maxPixelSize: size)
        let cacheKey = Self.stringKey(key) as NSString
        if let cached = images.object(forKey: cacheKey) { return cached }

        if let flight = flights[key] { return await flight.task.value }

        // Bound queued decoder work as well as its two active operations.
        // Off-screen SwiftUI tasks cancel while waiting; shared work already
        // decoding remains reusable by another visible card.
        while flights.count >= 16 {
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return nil }
            guard !Task.isCancelled else { return nil }
            if let cached = images.object(forKey: cacheKey) { return cached }
            if let flight = flights[key] { return await flight.task.value }
        }

        let flightID = UUID()
        let task = Task.detached(priority: .utility) { [weak self] in
            await self?.incrementDecodeCount()
            return await Self.decode(file: file, maxPixelSize: size)
        }
        flights[key] = Flight(id: flightID, task: task)
        let image = await task.value
        if flights[key]?.id == flightID {
            flights[key] = nil
            if let image {
                let cost = Self.cost(of: image)
                images.setObject(image, forKey: cacheKey, cost: cost)
            }
        }
        return image
    }

    func decodedImageCount() -> Int { decodeCount }

    private func incrementDecodeCount() { decodeCount += 1 }

    private static func decode(file: URL, maxPixelSize: Int) async -> UIImage? {
        await withCheckedContinuation { continuation in
            operationQueue.addOperation {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    continuation.resume(returning: nil); return
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: UIImage(cgImage: thumbnail))
            }
        }
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        return overflow ? 0 : cost
    }

    private static func stringKey(_ key: Key) -> String {
        "\(key.path)|\(key.byteCount)|\(key.modifiedAt.bitPattern)|\(key.maxPixelSize)"
    }
}

@MainActor
final class StaticCoverModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var displayedFile: URL?
    @Published private(set) var failedRequestIdentity: String?

    private let decoder: StaticCoverImageDecoding
    private var contextIdentity: String?
    private var requestToken = UUID()

    init(decoder: StaticCoverImageDecoding = StaticCoverImageCache.shared) {
        self.decoder = decoder
    }

    func updateContext(_ identity: String) {
        guard contextIdentity != identity else { return }
        contextIdentity = identity
        requestToken = UUID()
        image = nil
        displayedFile = nil
        failedRequestIdentity = nil
    }

    func load(file: URL, contextIdentity: String, requestIdentity: String, maxPixelSize: Int,
              onDecodeFailure: (() -> Void)? = nil) async {
        updateContext(contextIdentity)
        let token = UUID()
        requestToken = token
        failedRequestIdentity = nil
        let standardizedFile = file.standardizedFileURL
        let decoded = await decoder.thumbnail(for: standardizedFile, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled,
              requestToken == token,
              self.contextIdentity == contextIdentity else { return }
        if let decoded {
            image = decoded
            displayedFile = standardizedFile
            failedRequestIdentity = nil
        } else {
            failedRequestIdentity = requestIdentity
            onDecodeFailure?()
        }
    }

    func invalidateRequest() { requestToken = UUID() }
}

struct StaticCover: View {
    let file: URL
    let contextIdentity: String
    let requestIdentity: String
    var contentMode: ContentMode = .fit
    var onDecodeFailure: (() -> Void)? = nil

    @Environment(\.displayScale) private var displayScale
    @StateObject private var model = StaticCoverModel()

    var body: some View {
        GeometryReader { geometry in
            let pixels = max(geometry.size.width, geometry.size.height) * displayScale
            let targetSize = max(64, min(1024, Int(ceil(pixels / 64)) * 64))
            let request = LoadRequest(file: file.standardizedFileURL, context: contextIdentity,
                                      request: requestIdentity, maxPixelSize: targetSize)
            Group {
                if model.contextIdentityMatches(contextIdentity), let image = model.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            }
            .task(id: request) {
                await model.load(file: request.file, contextIdentity: request.context,
                                 requestIdentity: request.request, maxPixelSize: request.maxPixelSize,
                                 onDecodeFailure: onDecodeFailure)
            }
        }
        .onChange(of: contextIdentity) { _, newIdentity in model.updateContext(newIdentity) }
        .onDisappear { model.invalidateRequest() }
    }

    private struct LoadRequest: Hashable {
        let file: URL
        let context: String
        let request: String
        let maxPixelSize: Int
    }
}

private extension StaticCoverModel {
    func contextIdentityMatches(_ identity: String) -> Bool { contextIdentity == identity }
}

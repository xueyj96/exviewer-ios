import Foundation
import ImageIO
import CoreGraphics
import ExViewerCore

struct ReaderImageIdentity: Hashable, Sendable {
    let canonicalPath: String
    let modifiedAt: TimeInterval
    let byteCount: Int64
    let systemNumber: Int64
    let fileNumber: Int64
    let maxPixelSize: Int
}

/// A caller-owned handle to an ImageIO source. The pipeline and cache do not
/// keep assets alive after their callers and in-flight operations release them.
final class ReaderImageAsset: @unchecked Sendable {
    let identity: ReaderImageIdentity
    let frameCount: Int
    let pixelSize: CGSize
    private let source: CGImageSource
    private let sourceLock = NSLock()

    fileprivate init(identity: ReaderImageIdentity, frameCount: Int, pixelSize: CGSize, source: CGImageSource) {
        self.identity = identity
        self.frameCount = frameCount
        self.pixelSize = pixelSize
        self.source = source
    }

    fileprivate func withSource<T>(_ body: (CGImageSource) throws -> T) rethrows -> T {
        sourceLock.lock(); defer { sourceLock.unlock() }
        return try body(source)
    }
}

struct ReaderDecodedFrame: @unchecked Sendable {
    let image: CGImage
    let index: Int
    let duration: TimeInterval
    let decodedBytes: Int
}

/// ImageIO reader for the page canvas. All file inspection and image work is
/// performed by a small background OperationQueue; only immutable CGImages
/// cross back to callers for main-thread presentation.
final class ReaderImagePipeline: @unchecked Sendable {
    static let shared = ReaderImagePipeline()
    static let maximumPixelSize = 2048

    private struct FrameKey: Hashable {
        let identity: ReaderImageIdentity
        let index: Int
    }
    private struct CacheEntry {
        let frame: ReaderDecodedFrame
        let bytes: Int
        var lastUse: UInt64
    }
    private final class Consumer {
        let id: UUID
        let continuation: ResultContinuation<ReaderDecodedFrame>
        let cancellation: CancellationHandle
        let demand: MediaRequestDemand
        var demandObserver: UUID?
        init(id: UUID, continuation: ResultContinuation<ReaderDecodedFrame>, cancellation: CancellationHandle,
             demand: MediaRequestDemand) {
            self.id = id; self.continuation = continuation; self.cancellation = cancellation; self.demand = demand
        }
    }
    private final class FrameFlight {
        let operation: BlockOperation
        let cacheGeneration: UInt64
        var consumers: [UUID: Consumer] = [:]
        init(operation: BlockOperation, cacheGeneration: UInt64) {
            self.operation = operation; self.cacheGeneration = cacheGeneration
        }
    }

    private let lock = NSLock()
    private let operationQueue: OperationQueue
    private let maxPixelSize: Int
    private let cacheLimitBytes: Int
    private let maximumCachedFrames = 128
    private var frames: [FrameKey: CacheEntry] = [:]
    private var cacheBytes = 0
    private var useCounter: UInt64 = 0
    private var cacheGeneration: UInt64 = 0
    private var flights: [FrameKey: FrameFlight] = [:]

    /// `beforeFrameDecode` is an internal test seam for deterministic shared-
    /// consumer cancellation tests. Production callers use the default no-op.
    private let beforeFrameDecode: @Sendable (URL, Int) -> Void

    init(maxConcurrentOperations: Int = 2, cacheLimitBytes: Int = 64 * 1024 * 1024,
         maxPixelSize: Int = ReaderImagePipeline.maximumPixelSize,
         beforeFrameDecode: @escaping @Sendable (URL, Int) -> Void = { _, _ in }) {
        let queue = OperationQueue()
        queue.name = "ExViewer.Reader.ImageIO"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, maxConcurrentOperations)
        operationQueue = queue
        self.cacheLimitBytes = max(0, cacheLimitBytes)
        self.maxPixelSize = max(1, min(ReaderImagePipeline.maximumPixelSize, maxPixelSize))
        self.beforeFrameDecode = beforeFrameDecode
    }

    func open(file: URL, demand: MediaRequestDemand) async throws -> ReaderImageAsset {
        try await perform(demand: demand) { [maxPixelSize] in
            try Self.openSynchronously(file: file, maxPixelSize: maxPixelSize)
        }
    }

    func cachedFrame(asset: ReaderImageAsset, index: Int) -> ReaderDecodedFrame? {
        let key = FrameKey(identity: asset.identity, index: index)
        lock.lock(); defer { lock.unlock() }
        guard var entry = frames[key] else { return nil }
        useCounter &+= 1
        entry.lastUse = useCounter
        frames[key] = entry
        return entry.frame
    }

    func frame(asset: ReaderImageAsset, index: Int, demand: MediaRequestDemand) async throws -> ReaderDecodedFrame {
        guard index >= 0, index < asset.frameCount else { throw ViewerError.unsupported }
        try await perform(demand: demand) {
            guard Self.identity(for: URL(fileURLWithPath: asset.identity.canonicalPath), maxPixelSize: asset.identity.maxPixelSize) == asset.identity else {
                throw ViewerError.stale
            }
        }
        try Task.checkCancellation()
        let key = FrameKey(identity: asset.identity, index: index)
        if let cached = cachedFrame(asset: asset, index: index) { return cached }

        let consumerID = UUID()
        let cancellation = CancellationHandle()
        let continuation = ResultContinuation<ReaderDecodedFrame>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (checked: CheckedContinuation<ReaderDecodedFrame, Error>) in
                continuation.install(checked)
                if cancellation.isCancelled {
                    continuation.finish(.failure(CancellationError()))
                    return
                }

                var shouldEnqueue = false
                var flight: FrameFlight!
                lock.lock()
                if let cached = frames[key]?.frame {
                    useCounter &+= 1
                    frames[key]?.lastUse = useCounter
                    lock.unlock()
                    continuation.finish(.success(cached))
                    return
                }
                if let existing = flights[key] {
                    flight = existing
                } else {
                    let operation = BlockOperation {}
                    flight = FrameFlight(operation: operation, cacheGeneration: cacheGeneration)
                    flights[key] = flight
                    shouldEnqueue = true
                }
                let consumer = Consumer(id: consumerID, continuation: continuation, cancellation: cancellation, demand: demand)
                flight.consumers[consumerID] = consumer
                lock.unlock()

                cancellation.attach { [weak self] in self?.cancelConsumer(key: key, id: consumerID) }
                let demandObserver = demand.observe { [weak self] in self?.refreshPriority(for: key) }
                lock.lock()
                let stillAttached = flights[key]?.consumers[consumerID] != nil
                if stillAttached { flights[key]?.consumers[consumerID]?.demandObserver = demandObserver }
                lock.unlock()
                if !stillAttached { demand.removeObserver(demandObserver) }

                if shouldEnqueue { enqueue(flight, key: key, asset: asset) }
                else { refreshPriority(for: key) }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Memory-warning hook. Results queued before this call cannot refill the
    /// cleared LRU when they finish.
    func clearCache() {
        lock.lock(); cacheGeneration &+= 1; frames.removeAll(keepingCapacity: false); cacheBytes = 0; lock.unlock()
    }

    func cachedByteCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return cacheBytes
    }

    func consumerCountForTesting(asset: ReaderImageAsset, index: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return flights[FrameKey(identity: asset.identity, index: index)]?.consumers.count ?? 0
    }

    private func enqueue(_ flight: FrameFlight, key: FrameKey, asset: ReaderImageAsset) {
        flight.operation.addExecutionBlock { [weak self, weak flight] in
            guard let self, let flight, !flight.operation.isCancelled else { return }
            do {
                guard Self.identity(for: URL(fileURLWithPath: key.identity.canonicalPath), maxPixelSize: key.identity.maxPixelSize) == key.identity else {
                    throw ViewerError.stale
                }
                self.beforeFrameDecode(URL(fileURLWithPath: key.identity.canonicalPath), key.index)
                let decoded = try asset.withSource { source -> ReaderDecodedFrame in
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: key.identity.maxPixelSize,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ]
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, key.index, options as CFDictionary) else {
                        throw ViewerError.unsupported
                    }
                    let cost = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
                    guard !cost.overflow else { throw ViewerError.tooLarge }
                    let duration = Self.duration(source: source, index: key.index)
                    return ReaderDecodedFrame(image: image, index: key.index, duration: duration, decodedBytes: cost.partialValue)
                }
                guard Self.identity(for: URL(fileURLWithPath: key.identity.canonicalPath), maxPixelSize: key.identity.maxPixelSize) == key.identity else {
                    throw ViewerError.stale
                }
                self.finishFlight(key: key, flight: flight, result: .success(decoded))
            } catch {
                self.finishFlight(key: key, flight: flight, result: .failure(error))
            }
        }
        flight.operation.completionBlock = { [weak self, weak flight] in
            guard let self, let flight, flight.operation.isCancelled else { return }
            self.finishFlight(key: key, flight: flight, result: .failure(CancellationError()))
        }
        lock.lock(); let priority = priority(for: flight); lock.unlock()
        flight.operation.queuePriority = priority
        operationQueue.addOperation(flight.operation)
    }

    private func perform<Value>(demand: MediaRequestDemand, work: @escaping () throws -> Value) async throws -> Value {
        let cancellation = CancellationHandle()
        let continuation = ResultContinuation<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (checked: CheckedContinuation<Value, Error>) in
                continuation.install(checked)
                let operation = BlockOperation {
                    guard !cancellation.isCancelled else { continuation.finish(.failure(CancellationError())); return }
                    do { continuation.finish(.success(try work())) }
                    catch { continuation.finish(.failure(error)) }
                }
                cancellation.attach {
                    operation.cancel()
                    continuation.finish(.failure(CancellationError()))
                }
                let observer = demand.observe {
                    operation.queuePriority = Self.queuePriority(for: demand.priority)
                }
                operation.queuePriority = Self.queuePriority(for: demand.priority)
                operation.completionBlock = { [weak operation] in
                    demand.removeObserver(observer)
                    cancellation.detach()
                    if operation?.isCancelled == true { continuation.finish(.failure(CancellationError())) }
                }
                operationQueue.addOperation(operation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func finishFlight(key: FrameKey, flight: FrameFlight, result: Result<ReaderDecodedFrame, Error>) {
        lock.lock()
        guard flights[key] === flight else { lock.unlock(); return }
        flights[key] = nil
        if case .success(let frame) = result, flight.cacheGeneration == cacheGeneration {
            insert(frame, for: key)
        }
        let consumers = Array(flight.consumers.values)
        flight.consumers.removeAll()
        lock.unlock()
        for consumer in consumers {
            consumer.cancellation.detach()
            if let observer = consumer.demandObserver { consumer.demand.removeObserver(observer) }
            consumer.continuation.finish(result)
        }
    }

    private func cancelConsumer(key: FrameKey, id: UUID) {
        lock.lock()
        guard let flight = flights[key], let consumer = flight.consumers.removeValue(forKey: id) else { lock.unlock(); return }
        if flight.consumers.isEmpty {
            flights[key] = nil
            flight.operation.cancel()
        }
        lock.unlock()
        if let observer = consumer.demandObserver { consumer.demand.removeObserver(observer) }
        consumer.continuation.finish(.failure(CancellationError()))
    }

    private func refreshPriority(for key: FrameKey) {
        lock.lock(); defer { lock.unlock() }
        guard let flight = flights[key] else { return }
        flight.operation.queuePriority = priority(for: flight)
    }

    private func priority(for flight: FrameFlight) -> Operation.QueuePriority {
        let priority = flight.consumers.values.map { $0.demand.priority.rawValue }.min() ?? MediaRequestPriority.thumbnail.rawValue
        return Self.queuePriority(rawValue: priority)
    }

    private static func queuePriority(for demand: MediaRequestPriority) -> Operation.QueuePriority {
        queuePriority(rawValue: demand.rawValue)
    }
    private static func queuePriority(rawValue: Int) -> Operation.QueuePriority {
        switch rawValue {
        case MediaRequestPriority.foreground.rawValue: return .veryHigh
        case MediaRequestPriority.prefetch.rawValue: return .normal
        default: return .veryLow
        }
    }

    private func insert(_ frame: ReaderDecodedFrame, for key: FrameKey) {
        guard cacheLimitBytes > 0, frame.decodedBytes <= cacheLimitBytes else { return }
        if let old = frames.removeValue(forKey: key) { cacheBytes -= old.bytes }
        useCounter &+= 1
        frames[key] = CacheEntry(frame: frame, bytes: frame.decodedBytes, lastUse: useCounter)
        cacheBytes += frame.decodedBytes
        while cacheBytes > cacheLimitBytes || frames.count > maximumCachedFrames,
              let victim = frames.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            cacheBytes -= victim.value.bytes
            frames.removeValue(forKey: victim.key)
        }
    }

    private static func openSynchronously(file: URL, maxPixelSize: Int) throws -> ReaderImageAsset {
        let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
        guard let fileIdentity = identity(for: canonical, maxPixelSize: maxPixelSize),
              let source = CGImageSourceCreateWithURL(canonical as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw ViewerError.unsupported }
        guard identity(for: canonical, maxPixelSize: maxPixelSize) == fileIdentity else { throw ViewerError.stale }
        let pixelSize = pixelSize(source: source)
        return ReaderImageAsset(identity: fileIdentity, frameCount: CGImageSourceGetCount(source), pixelSize: pixelSize, source: source)
    }

    private static func pixelSize(source: CGImageSource) -> CGSize {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              rawWidth > 0, rawHeight > 0 else { return .zero }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            return CGSize(width: rawHeight, height: rawWidth)
        }
        return CGSize(width: rawWidth, height: rawHeight)
    }

    private static func identity(for file: URL, maxPixelSize: Int) -> ReaderImageIdentity? {
        let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
        guard let values = try? FileManager.default.attributesOfItem(atPath: canonical.path),
              let size = (values[.size] as? NSNumber)?.int64Value,
              let modified = values[.modificationDate] as? Date else { return nil }
        return ReaderImageIdentity(canonicalPath: canonical.path,
                                   modifiedAt: modified.timeIntervalSince1970,
                                   byteCount: size,
                                   systemNumber: (values[.systemNumber] as? NSNumber)?.int64Value ?? 0,
                                   fileNumber: (values[.systemFileNumber] as? NSNumber)?.int64Value ?? 0,
                                   maxPixelSize: maxPixelSize)
    }

    private static func duration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else { return 0.1 }
        for key in ["{GIF}", "{PNG}", "{WebP}"] {
            if let info = properties[key] as? [String: Any],
               let delay = (info["UnclampedDelayTime"] ?? info["DelayTime"]) as? NSNumber,
               delay.doubleValue > 0 { return max(0.02, min(10, delay.doubleValue)) }
        }
        return 0.1
    }
}

private final class ResultContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        lock.unlock()
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard case nil = self.result else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var callback: (@Sendable () -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ callback: @escaping @Sendable () -> Void) {
        lock.lock(); self.callback = callback; let runNow = cancelled; lock.unlock()
        if runNow { callback() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let callback = self.callback; self.callback = nil; lock.unlock()
        callback?()
    }
    func detach() { lock.lock(); callback = nil; lock.unlock() }
}


import Foundation

/// Explicitly enabled diagnostics for a real-device reading sample. Records
/// only random request IDs, phases, durations, byte counts and page numbers.
/// No URL, gallery/account identity, cookie, header or error text is collected.
final class ReaderNetworkMetrics: @unchecked Sendable {
    static var enabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--reader-network-metrics")
        #else
        false
        #endif
    }
    private struct Event: Codable {
        let request: UUID
        let sharedRequest: UUID?
        let phase: String
        let uptime: Double
        let milliseconds: Double
        let outcome: String
        let bytes: Int?
        let page: Int?
    }
    private struct Snapshot: Codable {
        let session: UUID
        let events: [Event]
    }
    private static let shared = ReaderNetworkMetrics()
    private let session = UUID()
    private let lock = NSLock()
    private var events: [Event] = []
    private let writer: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; return queue
    }()
    static func record(_ request: UUID, phase: String, started: TimeInterval? = nil,
                       outcome: String = "ok", bytes: Int? = nil, page: Int? = nil, sharedRequest: UUID? = nil) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        shared.append(Event(request: request, sharedRequest: sharedRequest, phase: phase, uptime: now,
                            milliseconds: started.map { max(0, now - $0) * 1000 } ?? 0,
                            outcome: outcome, bytes: bytes, page: page))
    }
    private func append(_ event: Event) {
        lock.lock(); events.append(event)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        let snapshot = Snapshot(session: session, events: events)
        lock.unlock()
        writer.addOperation {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ExViewerNetworkProbe", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: directory.appendingPathComponent("latest.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { /* Diagnostic persistence never affects reading. */ }
        }
    }
    @MainActor static func measure<T>(_ request: UUID, phase: String, page: Int? = nil,
                                      operation: () async throws -> T) async rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let value = try await operation()
            record(request, phase: phase, started: start, page: page); return value
        } catch {
            record(request, phase: phase, started: start, outcome: error is CancellationError ? "cancelled" : "failed", page: page)
            throw error
        }
    }
}

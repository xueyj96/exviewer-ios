import Foundation

enum SearchRequestPriority { case foreground, prefetch }

/// Enforces actual dispatch spacing. Cancelled waiters never reserve future
/// slots; foreground work takes the next available slot before prefetch work.
@MainActor final class SearchRequestPacer {
    private let interval: TimeInterval
    private var lastStart = -Double.infinity
    private var waiting: [(UUID, SearchRequestPriority, CheckedContinuation<Void, Error>)] = []
    private var timer: Task<Void, Never>?
    init(interval: TimeInterval = 3.1) { self.interval = interval }
    func wait(priority: SearchRequestPriority = .foreground) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, priority, continuation)); pump()
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
        try Task.checkCancellation()
    }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.0 == id }) { waiting.remove(at: index).2.resume(throwing: CancellationError()) }
        if waiting.isEmpty { timer?.cancel(); timer = nil }
    }
    private func pump() {
        guard !waiting.isEmpty else { return }
        let delay = interval - (ProcessInfo.processInfo.systemUptime - lastStart)
        if delay <= 0 {
            let index = waiting.firstIndex(where: { $0.1 == .foreground }) ?? 0
            let entry = waiting.remove(at: index); lastStart = ProcessInfo.processInfo.systemUptime
            entry.2.resume(); pump()
        } else if timer == nil {
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard !Task.isCancelled, let self else { return }; self.timer = nil; self.pump()
            }
        }
    }
}

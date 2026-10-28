import Foundation

enum MediaLoadPhase: Equatable, Sendable {
    case resolvingPage
    case queued
    case transferring
    case ready
}

struct MediaLoadProgress: Equatable, Sendable {
    var phase: MediaLoadPhase
    var completedBytes: Int64
    var totalBytes: Int64?

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    init(phase: MediaLoadPhase = .resolvingPage, completedBytes: Int64 = 0, totalBytes: Int64? = nil) {
        self.phase = phase
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    func replacingPhase(_ phase: MediaLoadPhase) -> MediaLoadProgress {
        MediaLoadProgress(phase: phase, completedBytes: completedBytes, totalBytes: totalBytes)
    }
}

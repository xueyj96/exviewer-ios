import Foundation

/// Coalesce checkpoints during page motion. The reader flushes at rest, before
/// dismissal and on backgrounding; LibraryStore retains its serialized commit.
@MainActor final class ReaderHistoryCheckpoint {
    private var pendingPage: Int?
    private let isCurrent: () -> Bool
    private let persist: (Int) -> Void

    init(isCurrent: @escaping () -> Bool, persist: @escaping (Int) -> Void) {
        self.isCurrent = isCurrent; self.persist = persist
    }

    func stage(_ page: Int) {
        guard page > 0, isCurrent() else { return }
        pendingPage = page
    }

    func discard() { pendingPage = nil }

    func finishMotion(fingerDown: Bool) {
        if !fingerDown { flush() }
    }

    func flush() {
        guard let page = pendingPage else { return }
        pendingPage = nil
        guard isCurrent() else { return }
        persist(page)
    }
}

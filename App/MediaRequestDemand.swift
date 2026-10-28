import Foundation

/// One request keeps its identity while an adjacent preload becomes visible.
/// Observers read the latest value; callbacks never execute under the lock.
final class MediaRequestDemand: @unchecked Sendable {
    struct ProgressSnapshot: Equatable, Sendable {
        let producerUUID: UUID
        let sequence: UInt64
        let value: MediaLoadProgress
    }

    let id: UUID
    private let lock = NSLock()
    private var value: MediaRequestPriority
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private var storedProgressSnapshot: ProgressSnapshot
    private var directProgressSequence: UInt64 = 0
    private struct ProgressForwarding {
        let source: UUID
        let token: UUID
        var lastSequence: UInt64?
    }
    private var progressForwarding: ProgressForwarding?
    private var progressObservers: [UUID: @Sendable (ProgressSnapshot) -> Void] = [:]

    init(priority: MediaRequestPriority = .foreground) {
        id = UUID()
        value = priority
        storedProgressSnapshot = ProgressSnapshot(producerUUID: id, sequence: 0, value: MediaLoadProgress())
    }
    var priority: MediaRequestPriority {
        lock.lock(); defer { lock.unlock() }; return value
    }
    func setPriority(_ priority: MediaRequestPriority) {
        lock.lock()
        guard value != priority else { lock.unlock(); return }
        value = priority
        let callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0() }
    }
    func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = callback; lock.unlock()
        callback()
        return id
    }
    func removeObserver(_ id: UUID) {
        lock.lock(); observers.removeValue(forKey: id); lock.unlock()
    }

    var progress: MediaLoadProgress {
        progressSnapshot.value
    }

    var progressSnapshot: ProgressSnapshot {
        lock.lock(); defer { lock.unlock() }; return storedProgressSnapshot
    }

    func reportProgress(_ progress: MediaLoadProgress) {
        lock.lock()
        progressForwarding = nil
        directProgressSequence &+= 1
        let snapshot = ProgressSnapshot(producerUUID: id, sequence: directProgressSequence, value: progress)
        storedProgressSnapshot = snapshot
        let callbacks = Array(progressObservers.values)
        lock.unlock()
        callbacks.forEach { $0(snapshot) }
    }

    func observeProgress(_ callback: @escaping @Sendable (MediaLoadProgress) -> Void) -> UUID {
        observeProgressSnapshot { callback($0.value) }
    }

    func observeProgressSnapshot(_ callback: @escaping @Sendable (ProgressSnapshot) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        progressObservers[id] = callback
        let current = storedProgressSnapshot
        lock.unlock()
        callback(current)
        return id
    }

    func beginProgressForwarding(source: UUID, token: UUID) {
        lock.lock()
        progressForwarding = ProgressForwarding(source: source, token: token, lastSequence: nil)
        lock.unlock()
    }

    func acceptForwardedProgress(_ snapshot: ProgressSnapshot, token: UUID) {
        lock.lock()
        guard var forwarding = progressForwarding,
              forwarding.token == token,
              forwarding.source == snapshot.producerUUID,
              forwarding.lastSequence.map({ snapshot.sequence > $0 }) ?? true else { lock.unlock(); return }
        forwarding.lastSequence = snapshot.sequence
        progressForwarding = forwarding
        storedProgressSnapshot = snapshot
        let callbacks = Array(progressObservers.values)
        lock.unlock()
        callbacks.forEach { $0(snapshot) }
    }

    func endProgressForwarding(token: UUID) {
        lock.lock()
        if progressForwarding?.token == token { progressForwarding = nil }
        lock.unlock()
    }

    func removeProgressObserver(_ id: UUID) {
        lock.lock(); progressObservers.removeValue(forKey: id); lock.unlock()
    }
}

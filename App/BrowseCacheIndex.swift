import Foundation

/// Actor-owned index for one owner's browse cache. Its heap avoids rescanning
/// file metadata and sorting every cache miss; stale heap nodes are discarded lazily.
final class BrowseCacheIndex {
    struct Entry: Equatable, Sendable {
        let url: URL
        let size: Int64
        let accessOrder: UInt64
        let lastAccessWriteAttempt: Date
    }

    private struct HeapNode {
        let path: String
        let order: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var heap: [HeapNode] = []
    private var nextOrder: UInt64 = 0
    private(set) var usedBytes: Int64 = 0
    private(set) var isBootstrapped = false
    var entryCount: Int { entries.count }
    var heapNodeCount: Int { heap.count }

    func bootstrap(directory: URL) throws {
        guard !isBootstrapped else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        )
        let files = try urls.compactMap { url -> (URL, Int64, Date)? in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { return nil }
            guard let size = values.fileSize, size >= 0, let modified = values.contentModificationDate else {
                throw CocoaError(.fileReadUnknown)
            }
            return (url.standardizedFileURL, Int64(size), modified)
        }.sorted { $0.2 < $1.2 }

        for (url, size, modified) in files {
            nextOrder &+= 1
            let entry = Entry(url: url, size: size, accessOrder: nextOrder, lastAccessWriteAttempt: modified)
            entries[url.path] = entry
            usedBytes = adding(size, to: usedBytes)
            push(HeapNode(path: url.path, order: nextOrder))
        }
        isBootstrapped = true
    }

    func entry(for url: URL) -> Entry? { entries[url.standardizedFileURL.path] }

    /// Updates in-memory recency and returns whether disk mtime is due for persistence.
    func touch(_ url: URL, at date: Date, persistenceInterval: TimeInterval = 45) -> Bool {
        let path = url.standardizedFileURL.path
        guard let old = entries[path] else { return false }
        nextOrder &+= 1
        entries[path] = Entry(url: old.url, size: old.size, accessOrder: nextOrder,
                              lastAccessWriteAttempt: old.lastAccessWriteAttempt)
        push(HeapNode(path: path, order: nextOrder))
        return date.timeIntervalSince(old.lastAccessWriteAttempt) >= persistenceInterval
    }

    func markAccessWriteAttempted(_ url: URL, at date: Date) {
        let path = url.standardizedFileURL.path
        guard let old = entries[path] else { return }
        entries[path] = Entry(url: old.url, size: old.size, accessOrder: old.accessOrder,
                              lastAccessWriteAttempt: date)
    }

    func record(_ url: URL, size: Int64, at date: Date) {
        let path = url.standardizedFileURL.path
        if let old = entries.removeValue(forKey: path) { usedBytes -= old.size }
        nextOrder &+= 1
        let entry = Entry(url: url.standardizedFileURL, size: max(0, size), accessOrder: nextOrder,
                          lastAccessWriteAttempt: date)
        entries[path] = entry
        usedBytes = adding(entry.size, to: usedBytes)
        push(HeapNode(path: path, order: nextOrder))
    }

    /// Returns the least-recently-used unpinned entry without changing accounting.
    func oldestEvictable(pinnedPaths: Set<String>) -> Entry? {
        var skipped: [HeapNode] = []
        var result: Entry?
        while let node = pop() {
            guard let entry = entries[node.path], entry.accessOrder == node.order else { continue }
            if pinnedPaths.contains(node.path) {
                skipped.append(node)
                continue
            }
            result = entry
            skipped.append(node)
            break
        }
        skipped.forEach { push($0) }
        return result
    }

    /// Call only after deletion succeeded or the path was confirmed missing.
    @discardableResult
    func confirmRemoved(_ url: URL) -> Bool {
        guard let entry = entries.removeValue(forKey: url.standardizedFileURL.path) else { return false }
        usedBytes = max(0, usedBytes - entry.size)
        compactHeapIfNeeded()
        return true
    }

    func contains(_ url: URL) -> Bool { entries[url.standardizedFileURL.path] != nil }

    private func adding(_ lhs: Int64, to rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }

    private func push(_ node: HeapNode) {
        heap.append(node)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].order < heap[parent].order else { break }
            heap.swapAt(child, parent)
            child = parent
        }
        compactHeapIfNeeded()
    }

    private func compactHeapIfNeeded() {
        let threshold = max(64, entries.count * 3)
        guard heap.count > threshold else { return }
        heap = entries.values.map { HeapNode(path: $0.url.path, order: $0.accessOrder) }
        heap.sort { $0.order < $1.order }
    }

    private func pop() -> HeapNode? {
        guard !heap.isEmpty else { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let root = heap[0]
        heap[0] = heap.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1, right = left + 1
            guard left < heap.count else { break }
            let child = right < heap.count && heap[right].order < heap[left].order ? right : left
            guard heap[child].order < heap[parent].order else { break }
            heap.swapAt(parent, child)
            parent = child
        }
        return root
    }
}

/// Synchronous, nonisolated pin registry. A context owns one owner-scoped set.
final class BrowseCachePinRegistry: @unchecked Sendable {
    enum DeleteResult: Equatable { case removed, pinned }
    private struct Binding {
        let owner: String
        let paths: Set<String>
    }

    private let lock = NSLock()
    private var bindings: [UUID: Binding] = [:]
    private var clearingOwners = Set<String>()

    func setPinnedFiles(_ files: Set<URL>, owner: String, context: UUID, root: URL) {
        let directory = root.appendingPathComponent(owner, isDirectory: true).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard directory.deletingLastPathComponent().path == rootPath else {
            releasePinnedFiles(context: context)
            return
        }
        lock.lock()
        guard !clearingOwners.contains(owner) else { lock.unlock(); return }
        let paths = Set(files.compactMap { file -> String? in
            let candidate = file.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory,
                  !candidate.lastPathComponent.isEmpty else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return candidate.path
        })
        bindings[context] = Binding(owner: owner, paths: paths)
        lock.unlock()
    }

    func releasePinnedFiles(context: UUID) {
        lock.lock(); bindings.removeValue(forKey: context); lock.unlock()
    }

    func pinnedPaths(owner: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return bindings.values.reduce(into: Set<String>()) { result, binding in
            if binding.owner == owner { result.formUnion(binding.paths) }
        }
    }

    /// Serializes one filesystem operation with pin changes; callers retry with
    /// a fresh LRU candidate if this path became pinned before deletion.
    func removeIfUnpinned(_ file: URL, owner: String, root: URL) throws -> DeleteResult {
        lock.lock(); defer { lock.unlock() }
        guard !clearingOwners.contains(owner) else { return .pinned }
        let directory = root.appendingPathComponent(owner, isDirectory: true).standardizedFileURL
        let candidate = file.standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else { return .pinned }
        if bindings.values.contains(where: { $0.owner == owner && $0.paths.contains(candidate.path) }) {
            return .pinned
        }
        do { try FileManager.default.removeItem(at: candidate) }
        catch {
            guard !FileManager.default.fileExists(atPath: candidate.path) else { throw CocoaError(.fileWriteUnknown) }
        }
        guard !FileManager.default.fileExists(atPath: candidate.path) else { throw CocoaError(.fileWriteUnknown) }
        return .removed
    }

    /// Returns false without touching mtime when this file is pinned or the owner is clearing.
    func persistAccessDateIfUnpinned(_ file: URL, owner: String, root: URL, date: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !clearingOwners.contains(owner) else { return false }
        let directory = root.appendingPathComponent(owner, isDirectory: true).standardizedFileURL
        let candidate = file.standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory,
              !bindings.values.contains(where: { $0.owner == owner && $0.paths.contains(candidate.path) }) else { return false }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: candidate.path)
        return true
    }

    func clear(owner: String) {
        lock.lock()
        bindings = bindings.filter { $0.value.owner != owner }
        lock.unlock()
    }

    func withOwnerCleared<T>(owner: String, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        clearingOwners.insert(owner)
        bindings = bindings.filter { $0.value.owner != owner }
        lock.unlock()
        defer {
            lock.lock(); clearingOwners.remove(owner); lock.unlock()
        }
        return try body()
    }
}

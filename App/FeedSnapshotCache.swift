import Foundation
import CryptoKit
import ExViewerCore

struct FeedSnapshot: Codable, Sendable {
    let version: Int
    let owner: String
    let root: URL
    let items: [Gallery]
    let next: URL?
    let categories: [String: String]
    let savedAt: Date
    init(owner: String, root: URL, items: [Gallery], next: URL?, categories: [String: String]) {
        version = 1; self.owner = owner; self.root = root; self.items = items
        self.next = next; self.categories = categories; savedAt = Date()
    }
}

/// Private, bounded first-page snapshots. They are always revalidated on use;
/// savedAt describes last-known content, never a claim that it is current.
actor FeedSnapshotCache {
    static let shared = FeedSnapshotCache()
    private let root: URL
    private let maxEntries = 12
    private let maxBytes = 20_000_000
    private let maxEntryBytes = 4_000_000
    private var epochs: [String: Int] = [:]
    private var memory: [String: (FeedSnapshot, Int)] = [:]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExViewerFeedCache", isDirectory: true)
    }
    func epoch(owner: String) -> Int { epochs[owner, default: 0] }
    private func key(owner: String, url: URL) -> String {
        SHA256.hash(data: Data((owner + "\n" + url.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func validOwner(_ owner: String) -> Bool {
        owner == "guest" || (!owner.isEmpty && owner.count <= 64 && owner.allSatisfy(\.isHexDigit))
    }
    private func valid(_ snapshot: FeedSnapshot, owner: String, url: URL) -> Bool {
        guard snapshot.version == 1, snapshot.owner == owner, snapshot.root == url,
              URLPolicy.account(url), let site = GallerySite.allCases.first(where: { $0.host == url.host }),
              snapshot.next.map({ URLPolicy.continuation($0, from: url) }) ?? true else { return false }
        return Set(snapshot.items.map(\.id)).count == snapshot.items.count &&
            snapshot.items.allSatisfy { $0.ref.site == site && ($0.cover.map(URLPolicy.media) ?? true) }
    }
    func read(owner: String, url: URL) -> FeedSnapshot? {
        guard validOwner(owner) else { return nil }
        let id = key(owner: owner, url: url)
        if let value = memory[id]?.0, valid(value, owner: owner, url: url) { return value }
        let file = root.appendingPathComponent(owner).appendingPathComponent(id + ".json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maxEntryBytes,
              let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(FeedSnapshot.self, from: data), valid(value, owner: owner, url: url) else { return nil }
        memory[id] = (value, data.count); trimMemory(); return value
    }
    func save(_ snapshot: FeedSnapshot, expectedEpoch: Int) {
        guard validOwner(snapshot.owner), epoch(owner: snapshot.owner) == expectedEpoch,
              valid(snapshot, owner: snapshot.owner, url: snapshot.root),
              let data = try? JSONEncoder().encode(snapshot), data.count <= maxEntryBytes else { return }
        let id = key(owner: snapshot.owner, url: snapshot.root)
        let directory = root.appendingPathComponent(snapshot.owner, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var excluded = directory; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
            try excluded.setResourceValues(attributes)
            try data.write(to: directory.appendingPathComponent(id + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            memory[id] = (snapshot, data.count); trimMemory()
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
                .compactMap { file -> (URL, Int, Date)? in
                    guard let v = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                    return (file, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
                }.sorted { $0.2 < $1.2 }
            var count = files.count, bytes = files.reduce(0) { $0 + $1.1 }
            for (file, size, _) in files where count > maxEntries || bytes > maxBytes {
                try? FileManager.default.removeItem(at: file); count -= 1; bytes -= size
                memory.removeValue(forKey: file.deletingPathExtension().lastPathComponent)
            }
        } catch { /* Cache failure must never clear visible content or prevent browsing. */ }
    }
    func invalidateFavorites(owner: String) {
        guard validOwner(owner) else { return }
        epochs[owner, default: 0] += 1
        memory = memory.filter { !($0.value.0.owner == owner && $0.value.0.root.path == "/favorites.php") }
        let directory = root.appendingPathComponent(owner, isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [] where file.pathExtension == "json" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxEntryBytes,
                  let data = try? Data(contentsOf: file), data.count <= maxEntryBytes,
                  let value = try? JSONDecoder().decode(FeedSnapshot.self, from: data), value.root.path == "/favorites.php" else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func trimMemory() {
        for entry in memory.sorted(by: { $0.value.0.savedAt < $1.value.0.savedAt }) {
            guard memory.count > maxEntries || memory.values.reduce(0, { $0 + $1.1 }) > maxBytes else { break }
            memory.removeValue(forKey: entry.key)
        }
    }
}

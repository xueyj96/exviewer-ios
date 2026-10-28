import Foundation
import ExViewerCore

struct ReadingRecord: Codable, Identifiable {
    var gallery: Gallery
    var page: Int
    var date: Date
    var id: String { gallery.id }
}
struct DownloadRecord: Codable, Identifiable {
    enum Status: String, Codable { case waiting, downloading, paused, complete, failed }
    var gallery: Gallery
    var status: Status
    var completed: [Int: String] = [:]
    var total: Int?
    var error: String?
    var id: String { gallery.id }
}
struct LibrarySnapshot: Codable {
    var version = 1
    var saved: [SavedSearch] = []
    var favoriteTags: [GalleryTag] = []
    var blockedTags: [GalleryTag] = []
    var bookmarks: [Gallery] = []
    var history: [ReadingRecord] = []
    var downloads: [DownloadRecord] = []
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published var error: String?
    @Published private(set) var owner = "guest"
    private let root: URL
    private let ephemeral: Bool
    var directory: URL { root.appendingPathComponent(owner, isDirectory: true) }
    var blockedIDs: Set<String> { Set(snapshot.blockedTags.map(\.id)) }
    init(qa: Bool = false) {
        ephemeral = qa
        root = qa ? FileManager.default.temporaryDirectory.appendingPathComponent("ExViewer-QA-" + UUID().uuidString) : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ExViewer", isDirectory: true)
        load(owner: "guest")
    }
    func load(owner: String) {
        guard owner == "guest" || owner.allSatisfy({ $0.isHexDigit }) else { return }
        self.owner = owner; snapshot = LibrarySnapshot(); error = nil
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var location = directory; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true; try location.setResourceValues(attributes)
            let file = directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count < 12_000_000 else { throw ViewerError.storage }
                let value = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
                guard value.version == 1 else { throw ViewerError.storage }
                snapshot = value
                for i in snapshot.downloads.indices where snapshot.downloads[i].status == .downloading { snapshot.downloads[i].status = .paused }
            }
            let offline = directory.appendingPathComponent("Offline", isDirectory: true)
            if FileManager.default.fileExists(atPath: offline.path) {
                let staged = try FileManager.default.contentsOfDirectory(at: offline, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent.hasSuffix(".pending-removal") }
                for item in staged {
                    let folder = String(item.lastPathComponent.dropFirst().dropLast(".pending-removal".count))
                    if let record = snapshot.downloads.first(where: { $0.id.replacingOccurrences(of: ":", with: "-") == folder }) {
                        let original = offlineDirectory(record.gallery)
                        guard !FileManager.default.fileExists(atPath: original.path) else { throw ViewerError.storage }
                        try FileManager.default.moveItem(at: item, to: original)
                    } else { try FileManager.default.removeItem(at: item) }
                }
            }
        } catch { self.error = "资料库暂时无法读取，原文件已保留。请重试，避免覆盖。" }
        if LibrarySelectionQA.seedsBlockedTags(isQA: ephemeral, arguments: ProcessInfo.processInfo.arguments) {
            var qaSnapshot = snapshot
            qaSnapshot.blockedTags = LibrarySelectionQA.blockedTags
            snapshot = qaSnapshot
        }
    }
    @discardableResult private func commit(_ mutate: (inout LibrarySnapshot) -> Void) -> Bool {
        guard error == nil else { return false }
        var copy = snapshot; mutate(&copy)
        do {
            let data = try JSONEncoder().encode(copy)
            guard data.count < 12_000_000 else { throw ViewerError.storage }
            try data.write(to: directory.appendingPathComponent("library.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            snapshot = copy
            return true
        } catch { self.error = "保存失败，当前资料保留。请检查本机空间。"; return false }
    }
    @discardableResult func saveSearch(name: String, site: GallerySite, query: SearchQuery, replacing: UUID? = nil) -> UUID? {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, replacing != nil || snapshot.saved.count < 200 else { return nil }
        if let replacing, !snapshot.saved.contains(where: { $0.id == replacing }) { return nil }
        var record = SavedSearch(name: name, site: site, query: query)
        if let replacing { record.id = replacing }
        let success = commit { value in
            if let index = value.saved.firstIndex(where: { $0.id == record.id }) { value.saved[index] = record }
            else { value.saved.append(record) }
        }
        return success ? record.id : nil
    }
    func deleteSearch(_ id: UUID) { commit { $0.saved.removeAll { $0.id == id } } }
    func pin(_ tag: GalleryTag) { commit { value in if !value.favoriteTags.contains(where: { $0.id == tag.id }) { value.favoriteTags.append(tag) } } }
    func unpin(_ tag: GalleryTag) { commit { $0.favoriteTags.removeAll { $0.id == tag.id } } }
    func block(_ tag: GalleryTag) { commit { value in if !value.blockedTags.contains(where: { $0.id == tag.id }) { value.blockedTags.append(tag) } } }
    func unblock(_ tag: GalleryTag) { commit { $0.blockedTags.removeAll { $0.id == tag.id } } }
    func bookmark(_ gallery: Gallery) { commit { value in if let index = value.bookmarks.firstIndex(where: { $0.id == gallery.id }) { value.bookmarks.remove(at: index) } else { value.bookmarks.insert(gallery.stored, at: 0) } } }
    func remember(_ gallery: Gallery, page: Int) {
        guard page > 0 else { return }
        commit { value in value.history.removeAll { $0.id == gallery.id }; value.history.insert(.init(gallery: gallery.stored, page: page, date: Date()), at: 0); value.history = Array(value.history.prefix(500)) }
    }
    func updateDownload(_ record: DownloadRecord) { commit { value in if let i = value.downloads.firstIndex(where: { $0.id == record.id }) { value.downloads[i] = record } else { value.downloads.append(record) } } }
    func offlineDirectory(_ gallery: Gallery) -> URL { directory.appendingPathComponent("Offline/" + gallery.id.replacingOccurrences(of: ":", with: "-"), isDirectory: true) }
    func removeDownload(_ record: DownloadRecord) {
        guard error == nil else { return }
        let path = offlineDirectory(record.gallery)
        let staged = path.deletingLastPathComponent().appendingPathComponent("." + path.lastPathComponent + ".pending-removal")
        do {
            let exists = FileManager.default.fileExists(atPath: path.path)
            if exists { try FileManager.default.moveItem(at: path, to: staged) }
            guard commit({ $0.downloads.removeAll { $0.id == record.id } }) else {
                if exists { try FileManager.default.moveItem(at: staged, to: path) }
                return
            }
            if exists { try FileManager.default.removeItem(at: staged) }
        }
        catch { self.error = "本机副本未能移除，请重试。" }
    }
}

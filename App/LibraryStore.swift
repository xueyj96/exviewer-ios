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

struct RecentSearchRecord: Codable, Identifiable {
    var id = UUID()
    var site: GallerySite
    var query: SearchQuery
    var date: Date

    static func requestKey(site: GallerySite, query: SearchQuery) throws -> String {
        var canonical = query
        canonical.rules.sort {
            $0.id == $1.id ? $0.match.rawValue < $1.match.rawValue : $0.id < $1.id
        }
        return try canonical.url(site: site).absoluteString
    }
}

private struct RecentSearchFile: Codable {
    var version = 1
    var entries: [RecentSearchRecord]
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published private(set) var recentSearches: [RecentSearchRecord] = []
    @Published private(set) var searchHistoryError: String?
    @Published var error: String?
    @Published private(set) var owner = "guest"
    private let root: URL
    private let ephemeral: Bool
    var directory: URL { root.appendingPathComponent(owner, isDirectory: true) }
    var blockedIDs: Set<String> { Set(snapshot.blockedTags.map(\.id)) }
    static let searchHistoryLimit = 100
    private var searchHistoryFile: URL { directory.appendingPathComponent("recent-searches.json") }
    init(qa: Bool = false, storageRoot: URL? = nil) {
        ephemeral = qa
        root = storageRoot ?? (qa ? FileManager.default.temporaryDirectory.appendingPathComponent("ExViewer-QA-" + UUID().uuidString) : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ExViewer", isDirectory: true))
        load(owner: "guest")
    }
    func load(owner: String) {
        guard owner == "guest" || owner.allSatisfy({ $0.isHexDigit }) else { return }
        self.owner = owner; snapshot = LibrarySnapshot(); error = nil
        recentSearches = []; searchHistoryError = nil
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
        loadSearchHistory()
        if LibrarySelectionQA.seedsBlockedTags(isQA: ephemeral, arguments: ProcessInfo.processInfo.arguments) {
            var qaSnapshot = snapshot
            qaSnapshot.blockedTags = LibrarySelectionQA.blockedTags
            snapshot = qaSnapshot
        }
    }

    private func loadSearchHistory() {
        guard FileManager.default.fileExists(atPath: searchHistoryFile.path) else { return }
        do {
            let data = try Data(contentsOf: searchHistoryFile)
            guard data.count < 256_000 else { throw ViewerError.storage }
            let file = try JSONDecoder().decode(RecentSearchFile.self, from: data)
            guard file.version == 1, file.entries.count <= Self.searchHistoryLimit,
                  Set(file.entries.map(\.id)).count == file.entries.count else { throw ViewerError.storage }
            for entry in file.entries {
                guard entry.query.count > 0 else { throw ViewerError.storage }
                _ = try entry.query.url(site: entry.site)
            }
            recentSearches = file.entries
        } catch { searchHistoryError = "搜索记录暂时无法读取，原文件已保留；可清空搜索记录后重新记录。" }
    }

    @discardableResult private func saveSearchHistory(_ entries: [RecentSearchRecord], resetting: Bool = false) -> Bool {
        guard searchHistoryError == nil || resetting else { return false }
        do {
            let data = try JSONEncoder().encode(RecentSearchFile(entries: entries))
            guard data.count < 256_000 else { throw ViewerError.storage }
            try data.write(to: searchHistoryFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            recentSearches = entries; searchHistoryError = nil
            return true
        } catch { searchHistoryError = "搜索记录保存失败，原有记录保留；请检查本机空间。"; return false }
    }

    @discardableResult func recordSearch(query: SearchQuery, site: GallerySite, date: Date = Date()) -> Bool {
        guard query.count > 0, let key = try? RecentSearchRecord.requestKey(site: site, query: query) else { return false }
        var entries = recentSearches
        let existing = entries.firstIndex { (try? RecentSearchRecord.requestKey(site: $0.site, query: $0.query)) == key }
        let id = existing.map { entries.remove(at: $0).id } ?? UUID()
        entries.insert(RecentSearchRecord(id: id, site: site, query: query, date: date), at: 0)
        return saveSearchHistory(Array(entries.prefix(Self.searchHistoryLimit)))
    }

    @discardableResult func deleteRecentSearch(_ id: UUID) -> Bool {
        saveSearchHistory(recentSearches.filter { $0.id != id })
    }

    @discardableResult func clearSearchHistory() -> Bool { saveSearchHistory([], resetting: true) }

    func savedSearch(matching query: SearchQuery, site: GallerySite) -> SavedSearch? {
        guard let key = try? RecentSearchRecord.requestKey(site: site, query: query) else { return nil }
        return snapshot.saved.first { (try? RecentSearchRecord.requestKey(site: $0.site, query: $0.query)) == key }
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


enum SearchPresentation {
    static func summary(_ query: SearchQuery, site: GallerySite) -> String {
        var values = [site == .ex ? "EX" : "EH"]
        if !query.text.isEmpty { values.append(query.text) }
        if query.titleOnly { values.append("仅标题") }
        if !query.artist.isEmpty { values.append("作者 \(query.artist)") }
        for match in [TagMatch.all, .any, .exclude] {
            let tags = query.rules.filter { $0.match == match }.map { $0.tag.label }
            if !tags.isEmpty { values.append("\(match.name) \(tags.joined(separator: "、"))") }
        }
        let categories = GalleryCategory.all.filter { query.excludedCategories.contains($0.id) }.map(\.name)
        if !categories.isEmpty { values.append("排除分类 \(categories.joined(separator: "、"))") }
        if let rating = query.minRating { values.append("≥\(rating)星") }
        if query.minPages != nil || query.maxPages != nil { values.append("\(query.minPages.map { String($0) } ?? "0")–\(query.maxPages.map { String($0) } ?? "不限")页") }
        if !query.uploader.isEmpty { values.append("上传者 \(query.uploader)") }
        if query.requireTorrent { values.append("torrent") }
        return values.joined(separator: " · ")
    }
}

import Foundation
import ExViewerCore

/// One session-local source for display state. No credentials, forms or queued
/// mutations are written to disk. A version prevents old reads undoing edits.
@MainActor final class SiteFavoriteCache: ObservableObject {
    struct Entry {
        let state: GalleryFavoriteState
        let form: GalleryFavoriteForm?
        let date: Date
        let version: UUID
    }
    @Published private(set) var revision = UUID()
    private var entries: [GalleryFavoriteScope: Entry] = [:]
    func entry(_ scope: GalleryFavoriteScope) -> Entry? { entries[scope] }
    func recent(_ scope: GalleryFavoriteScope, now: Date = Date()) -> Entry? {
        guard let value = entries[scope], value.state != .unknown,
              (0..<15).contains(now.timeIntervalSince(value.date)) else { return nil }
        return value
    }
    @discardableResult func put(_ state: GalleryFavoriteState, form: GalleryFavoriteForm? = nil,
                               scope: GalleryFavoriteScope, expectedVersion: UUID? = nil,
                               conditional: Bool = false, force: Bool = false) -> Bool {
        if conditional && entries[scope]?.version != expectedVersion { return false }
        entries = entries.filter { $0.key.owner == scope.owner && $0.key.generation == scope.generation }
        if entries[scope]?.state == state && form == nil && !force { return true }
        if entries.count >= 64, entries[scope] == nil,
           let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key { entries.removeValue(forKey: oldest) }
        entries[scope] = .init(state: state, form: form, date: Date(), version: UUID())
        revision = UUID(); return true
    }
}

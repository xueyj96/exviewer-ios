import Foundation
import ExViewerCore

struct GalleryFavoriteScope: Hashable {
    let reference: GalleryRef
    let owner: String
    let generation: UUID
    init(reference: GalleryRef, owner: String, generation: UUID) {
        self.reference = reference; self.owner = owner; self.generation = generation
    }
    @MainActor init(_ gallery: Gallery, _ session: SiteSession) {
        reference = gallery.ref; owner = session.owner; generation = session.generation
    }
}

/// Reading/display observes local state only. Favorite form network access
/// belongs to the explicitly opened editor, never to binding or notifications.
@MainActor final class GalleryFavoriteObservation: ObservableObject {
    @Published private(set) var state: GalleryFavoriteState = .unknown
    private var client: GalleryFavoriteClient?
    private var reference: GalleryRef?
    private var form: GalleryFavoriteForm?
    private var observedAt: Date?
    private weak var cache: SiteFavoriteCache?
    private var scope: GalleryFavoriteScope?
    private var cacheVersion: UUID?

    func bind(_ client: GalleryFavoriteClient, reference: GalleryRef,
              cache: SiteFavoriteCache? = nil, scope: GalleryFavoriteScope? = nil,
              now: Date = Date()) {
        cancel(); self.reference = reference
        self.cache = cache; self.scope = scope
        self.client = client; state = .unknown
        guard client.isCurrent() else { return }
        if let cache, let scope, let recent = cache.recent(scope, now: now) {
            state = recent.state; form = recent.form; observedAt = recent.date; cacheVersion = recent.version; return
        }
        if let cache, let scope { state = cache.entry(scope)?.state ?? .unknown }
        cacheVersion = scope.flatMap { cache?.entry($0)?.version }
    }
    func accept(_ value: GalleryFavoriteState, form verifiedForm: GalleryFavoriteForm? = nil) {
        guard client?.isCurrent() == true else { return }
        if let verifiedForm, verifiedForm.state == value, verifiedForm.reference == reference {
            form = verifiedForm; observedAt = Date()
        } else if form?.state != value { form = nil; observedAt = nil }
        state = value
        if let cache, let scope {
            cache.put(value, form: form?.state == value ? form : nil, scope: scope)
            cacheVersion = cache.entry(scope)?.version
        }
    }
    func cancel() { form = nil; observedAt = nil }
    private func beginChange() {
        cancel(); state = .unknown
        if let cache, let scope {
            cache.put(.unknown, scope: scope, force: true)
            cacheVersion = cache.entry(scope)?.version
        }
    }
    func syncFromCache() {
        guard client?.isCurrent() == true, let scope, let value = cache?.entry(scope), value.version != cacheVersion else { return }
        cancel(); cacheVersion = value.version; state = value.state; form = value.form; observedAt = value.date
    }

    /// A recent same-account form can be reused by an explicit editor. There
    /// are no display-side reads to await or start. Verification remains fresh.
    func preparation(_ upstream: GalleryFavoriteClient, reference: GalleryRef, now: Date = Date()) -> GalleryFavoritePreparation {
        let valid = self.reference == reference && client?.isCurrent() == true && upstream.isCurrent()
        let fresh = valid && observedAt.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < 15 } == true
        let initial = fresh ? form : nil
        let wrapped = GalleryFavoriteClient(isCurrent: upstream.isCurrent, read: {
            guard upstream.isCurrent() else { throw ViewerError.stale }
            return try await upstream.read()
        }, submit: upstream.submit, willSubmit: { [weak self] in
            self?.beginChange(); await upstream.willSubmit()
        }, didSubmit: upstream.didSubmit)
        return .init(client: wrapped, initialForm: initial)
    }
}

struct GalleryFavoritePreparation {
    let client: GalleryFavoriteClient
    let initialForm: GalleryFavoriteForm?
}

@MainActor func favoriteClient(for gallery: Gallery, session: SiteSession) -> GalleryFavoriteClient {
    AppMode.qa ? NativeFavoritesQA.client(reference: gallery.ref, session: session)
        : GalleryFavoriteClient.live(reference: gallery.ref, session: session)
}

func favoriteStateDescription(_ state: GalleryFavoriteState) -> String {
    switch state {
    case .unknown: return "状态待核实"
    case .notFavorited: return "未收藏"
    case .favorited(let group): return "已收藏，\(group)"
    }
}

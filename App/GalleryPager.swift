import Foundation
import ExViewerCore

@MainActor final class GalleryPager: ObservableObject {
    @Published private(set) var items: [Gallery] = []
    @Published private(set) var loading = false
    @Published private(set) var next: URL?
    @Published private(set) var failure: String?
    @Published private(set) var categories: [String: String] = [:]
    @Published private(set) var interrupted = false
    @Published private(set) var cachedAt: Date?
    private var context = UUID()
    private var task: Task<Void, Never>?
    private var loaded = Set<URL>()
    private var root: URL?
    private var qa = false
    private var sourceOwner = ""
    private var sourceGeneration: UUID?
    private var retryURL: URL?
    private var activeURL: URL?
    private var activePriority: SearchRequestPriority = .foreground
    private var minimumRating: Int? { root.flatMap(GalleryRatingFilter.minimum(in:)) }
    private var cacheEpoch = 0
    private let cache: FeedSnapshotCache?
    private let loadHTML: ((URL, Bool, Data?) async throws -> String)?
    init(loadHTML: ((URL, Bool, Data?) async throws -> String)? = nil, cache: FeedSnapshotCache? = nil) {
        if loadHTML == nil, FeedCacheQA.isEnabled {
            self.loadHTML = FeedCacheQA.loadHTML
            self.cache = cache ?? FeedCacheQA.cache
        } else {
            self.loadHTML = loadHTML
            self.cache = cache ?? (loadHTML == nil ? .shared : nil)
        }
    }
    struct NavigationSnapshot {
        let items: [Gallery]
        let next: URL?
        let failure: String?
        let categories: [String: String]
        let loaded: Set<URL>
        let root: URL?
        let qa: Bool
        let interrupted: Bool
        let owner: String
        let generation: UUID?
        let retryURL: URL?
        let cachedAt: Date?
        let cacheEpoch: Int
    }
    func cancel() {
        if loading { interrupted = true }
        task?.cancel(); task = nil; context = UUID(); loading = false; activeURL = nil
    }
    func pauseForSelection() { if loading { cancel() } }
    func navigationSnapshot() -> NavigationSnapshot {
        cancel()
        return .init(items: items, next: next, failure: failure, categories: categories,
                     loaded: loaded, root: root, qa: qa, interrupted: interrupted,
                     owner: sourceOwner, generation: sourceGeneration, retryURL: retryURL, cachedAt: cachedAt, cacheEpoch: cacheEpoch)
    }
    func restoreNavigationSnapshot(_ snapshot: NavigationSnapshot) {
        cancel(); items = snapshot.items; next = snapshot.next; failure = snapshot.failure
        categories = snapshot.categories; loaded = snapshot.loaded; root = snapshot.root
        qa = snapshot.qa; interrupted = snapshot.interrupted; sourceOwner = snapshot.owner
        sourceGeneration = snapshot.generation; retryURL = snapshot.retryURL; cachedAt = snapshot.cachedAt
        cacheEpoch = snapshot.cacheEpoch
    }
    func reset(url: URL, session: SiteSession, qa: Bool = false) {
        let same = root == url && sourceOwner == session.owner && sourceGeneration == session.generation
        // Repeated pull-to-refresh while this root is already loading shares
        // that request instead of cancelling and adding another queue slot.
        if same && loading && activeURL == url { return }
        let retained = same ? items : []
        cancel(); root = url; self.qa = qa && !FeedCacheQA.isEnabled; loaded = []; next = nil; failure = nil
        items = retained; if retained.isEmpty { categories = [:]; cachedAt = nil }
        sourceOwner = session.owner; sourceGeneration = session.generation; interrupted = false
        if self.qa {
            if url.path == "/favorites.php", ProcessInfo.processInfo.arguments.contains("--qa-favorite-sync-list") {
                let site = GallerySite.allCases.first { $0.host == url.host } ?? .ex
                items = NativeFavoritesQA.favorites(site: site)
                categories = Dictionary(uniqueKeysWithValues: NativeFavoritesQA.groups.enumerated().map { (String($0.offset), $0.element) })
                next = nil; return
            }
            items = QASamples.feedGalleries.filter { GalleryRatingFilter.includes($0, minimum: minimumRating) }; categories = ["0": "常用", "1": "稍后阅读"]
            let finiteFixture = ProcessInfo.processInfo.arguments.contains("--qa-feed-performance") || ProcessInfo.processInfo.arguments.contains("--qa-search-sort")
            next = finiteFixture ? nil : URL(string: "https://exhentai.org/?qa-page=2"); return
        }
        let current = context, account = session.generation, owner = session.owner
        loading = true; activeURL = url; activePriority = .foreground; retryURL = url
        task = Task {
            if let cache {
                let epoch = await cache.epoch(owner: owner)
                let snapshot = retained.isEmpty ? await cache.read(owner: owner, url: url) : nil
                guard isCurrent(current, account: account, owner: owner, session: session), !Task.isCancelled else { return }
                cacheEpoch = epoch
                if let snapshot {
                    items = snapshot.items; next = snapshot.next; categories = snapshot.categories; cachedAt = snapshot.savedAt
                }
            }
            await loadPage(url, session: session, current: current, account: account, owner: owner, priority: .foreground)
        }
    }
    func more(session: SiteSession, prefetch: Bool = false) {
        guard let next, !loading else { return }
        if qa {
            let current = context; loading = true; interrupted = false
            task = Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, current == context else { return }
                items += QASamples.additionalGalleries.filter { GalleryRatingFilter.includes($0, minimum: minimumRating) }; self.next = nil; loading = false; interrupted = false
            }
        } else { beginPage(next, session: session, priority: prefetch ? .prefetch : .foreground) }
    }
    func retry(session: SiteSession) {
        if qa {
            guard !loading else { return }
            if items.isEmpty, let root { reset(url: root, session: session, qa: true) }
            else { more(session: session) }
        } else if let target = retryURL ?? next ?? root, !loading { beginPage(target, session: session, priority: .foreground) }
    }
    func invalidateFavoriteCache(owner: String) async {
        await cache?.invalidateFavorites(owner: owner)
    }
    private func beginPage(_ url: URL, session: SiteSession, priority: SearchRequestPriority) {
        guard !loading, !loaded.contains(url), let root, URLPolicy.continuation(url, from: root),
              sourceOwner == session.owner, sourceGeneration == session.generation else { return }
        let current = context, account = session.generation, owner = session.owner
        loading = true; activeURL = url; activePriority = priority; retryURL = url
        failure = nil; interrupted = false
        task = Task { await loadPage(url, session: session, current: current, account: account, owner: owner, priority: priority) }
    }
    private func isCurrent(_ value: UUID, account: UUID, owner: String, session: SiteSession) -> Bool {
        value == context && account == session.generation && owner == session.owner
    }
    private func loadPage(_ url: URL, session: SiteSession, current: UUID, account: UUID, owner: String, priority: SearchRequestPriority) async {
        defer {
            if current == context { loading = false; activeURL = nil; task = nil }
        }
        do {
            let html = try await requestHTML(url, session: session, search: true, priority: priority)
            let parse = Task.detached(priority: .userInitiated) { try EHParser.list(html, base: url) }
            let list = try await withTaskCancellationHandler(operation: { try await parse.value }, onCancel: { parse.cancel() })
            guard isCurrent(current, account: account, owner: owner, session: session), !Task.isCancelled else { return }
            let replacingRoot = url == root
            let retainedRoot = replacingRoot && !items.isEmpty
            // Continuation URLs may omit filters; keep the original query's threshold.
            let minimum = minimumRating
            var unconfirmedRatings = false
            var pageItems: [Gallery] = []
            var positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
            categories = list.favoriteCategories
            for offset in stride(from: 0, to: list.items.count, by: 25) {
                try Task.checkCancellation()
                let batch = Array(list.items[offset..<min(offset + 25, list.items.count)])
                let enriched: [Gallery]
                do {
                    let body = try GalleryMetadata.request(batch)
                    let json = try await requestHTML(URL(string: "https://api.e-hentai.org/api.php")!, session: session, body: body, priority: priority)
                    let parse = Task.detached(priority: .userInitiated) { try GalleryMetadata.merge(Data(json.utf8), into: batch) }
                    enriched = try await withTaskCancellationHandler(operation: { try await parse.value }, onCancel: { parse.cancel() })
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if minimum != nil { throw error }
                    enriched = batch
                }
                try Task.checkCancellation()
                guard isCurrent(current, account: account, owner: owner, session: session) else { return }
                if minimum != nil, enriched.contains(where: { GalleryRatingFilter.average($0.rating) == nil }) {
                    unconfirmedRatings = true
                }
                let accepted = enriched.filter { GalleryRatingFilter.includes($0, minimum: minimum) }
                pageItems += accepted
                if !retainedRoot {
                    var updated = items
                    for gallery in accepted {
                        if let index = positions[gallery.id] {
                            if !updated[index].tagsComplete && gallery.tagsComplete { updated[index] = gallery }
                        } else { positions[gallery.id] = updated.count; updated.append(gallery) }
                    }
                    items = updated
                }
                if offset + 25 < list.items.count { try await Task.sleep(nanoseconds: 1_300_000_000) }
            }
            try Task.checkCancellation()
            guard isCurrent(current, account: account, owner: owner, session: session) else { return }
            if unconfirmedRatings { throw ViewerError.ratingUnavailable }
            if replacingRoot { items = pageItems; cachedAt = nil }
            loaded.insert(url); retryURL = nil
            next = list.next.flatMap { loaded.contains($0) ? nil : $0 }
            categories = list.favoriteCategories; interrupted = false
            if replacingRoot, let cache {
                await cache.save(.init(owner: owner, root: url, items: pageItems, next: next, categories: categories), expectedEpoch: cacheEpoch)
            }
        } catch is CancellationError { }
        catch {
            guard isCurrent(current, account: account, owner: owner, session: session) else { return }
            interrupted = false; failure = ErrorMessages.message(error, fallback: ViewerError.network.localizedDescription)
        }
    }
    private func requestHTML(_ url: URL, session: SiteSession, search: Bool = false, body: Data? = nil, priority: SearchRequestPriority) async throws -> String {
        if let loadHTML { return try await loadHTML(url, search, body) }
        return try await session.html(url, search: search, method: body == nil ? "GET" : "POST", body: body,
                                      contentType: body == nil ? "application/x-www-form-urlencoded" : "application/json", searchPriority: priority)
    }
}

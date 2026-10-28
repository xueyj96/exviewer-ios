import Foundation
import Combine
import ExViewerCore

@MainActor final class DiscoveryEntry: ObservableObject, Identifiable {
    let id = UUID()
    let query: SearchQuery
    let site: GallerySite
    let lane: Int
    let savedID: UUID?
    let requestURL: URL
    let pager = GalleryPager()
    @Published var scrollAnchor: String?
    private(set) var didStart = false

    init(query: SearchQuery, site: GallerySite, lane: Int, savedID: UUID?, requestURL: URL, scrollAnchor: String? = nil) {
        self.query = query
        self.site = site
        self.lane = lane
        self.savedID = savedID
        self.requestURL = requestURL
        self.scrollAnchor = scrollAnchor
    }

    func markStarted() { didStart = true }
}

/// Keeps one active feed and a bounded in-memory trail of paused feeds.
@MainActor final class DiscoveryNavigation: ObservableObject {
    static let historyLimit = 32
    @Published private(set) var current: DiscoveryEntry
    @Published private(set) var history: [DiscoveryEntry] = []
    var canGoBack: Bool { !history.isEmpty }

    init(query: SearchQuery = SearchQuery(), site: GallerySite = .ex, lane: Int = 0, savedID: UUID? = nil) {
        let url = (try? Self.requestURL(query: query, site: site, lane: lane)) ?? (try! SearchQuery().url(site: site))
        current = DiscoveryEntry(query: query, site: site, lane: lane, savedID: savedID, requestURL: url)
    }

    func startCurrent(session: SiteSession, qa: Bool) throws {
        guard !current.didStart else { return }
        let url = try Self.requestURL(query: current.query, site: current.site, lane: current.lane)
        guard url == current.requestURL else { throw ViewerError.invalidQuery("当前浏览条件已变化，请重新提交。") }
        current.markStarted()
        current.pager.reset(url: url, session: session, qa: qa)
    }

    /// Validates before changing history. Identical URLs reuse the current feed
    /// and replace only immutable request metadata when its saved-search identity changed.
    @discardableResult
    func submit(query: SearchQuery, site: GallerySite, lane: Int, savedID: UUID?, session: SiteSession, qa: Bool) throws -> Bool {
        let url = try Self.requestURL(query: query, site: site, lane: lane)
        if current.requestURL == url {
            if current.query == query, current.site == site, current.lane == lane, current.savedID == savedID {
                if !current.didStart { current.markStarted(); current.pager.reset(url: url, session: session, qa: qa) }
                return false
            }
            let old = current
            let snapshot = old.pager.navigationSnapshot()
            let replacement = DiscoveryEntry(query: query, site: site, lane: lane, savedID: savedID, requestURL: url, scrollAnchor: old.scrollAnchor)
            replacement.pager.restoreNavigationSnapshot(snapshot)
            if old.didStart { replacement.markStarted() }
            current = replacement
            if !replacement.didStart {
                replacement.markStarted()
                replacement.pager.reset(url: url, session: session, qa: qa)
            }
            return false
        }

        if let index = history.lastIndex(where: {
            $0.requestURL == url && $0.query == query && $0.site == site && $0.lane == lane && $0.savedID == savedID
        }) {
            let restored = history.remove(at: index)
            current.pager.cancel(); history.append(current); current = restored
            if restored.pager.interrupted { restored.pager.retry(session: session) }
            return true
        }

        current.pager.cancel()
        history.append(current)
        if history.count > Self.historyLimit {
            let excess = history.count - Self.historyLimit
            let removed = Array(history.prefix(excess))
            history.removeFirst(excess)
            removed.forEach { $0.pager.cancel() }
        }
        let entry = DiscoveryEntry(query: query, site: site, lane: lane, savedID: savedID, requestURL: url)
        entry.markStarted()
        current = entry
        entry.pager.reset(url: url, session: session, qa: qa)
        return true
    }

    @discardableResult
    func back() -> Bool {
        guard let previous = history.popLast() else { return false }
        current.pager.cancel()
        current = previous
        return true
    }

    static func requestURL(query: SearchQuery, site: GallerySite, lane: Int) throws -> URL {
        guard (0...1).contains(lane) else { throw ViewerError.invalidQuery("浏览范围无效。") }
        if query.count > 0 { return try query.url(site: site) }
        return lane == 1 ? site.baseURL.appendingPathComponent("popular") : try SearchQuery().url(site: site)
    }
}

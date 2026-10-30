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

    func updateVisibleAnchor(_ anchor: String) {
        guard scrollAnchor != anchor else { return }
        scrollAnchor = anchor
    }
}

/// Keeps one active feed and a bounded in-memory trail of paused feeds.
@MainActor final class DiscoveryNavigation: ObservableObject {
    static let historyLimit = 32
    @Published private(set) var current: DiscoveryEntry
    @Published private(set) var history: [DiscoveryEntry] = []
    @Published private(set) var forwardHistory: [DiscoveryEntry] = []
    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }

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

        let matches: (DiscoveryEntry) -> Bool = {
            $0.requestURL == url && $0.query == query && $0.site == site && $0.lane == lane && $0.savedID == savedID
        }
        let reusable: DiscoveryEntry?
        if let index = history.lastIndex(where: matches) {
            reusable = history.remove(at: index)
        } else if let index = forwardHistory.lastIndex(where: matches) {
            reusable = forwardHistory.remove(at: index)
        } else { reusable = nil }
        // A new navigation branches from the current page, like browser history.
        // Reuse a matching paused feed before discarding the abandoned branch.
        forwardHistory.forEach { $0.pager.cancel() }
        forwardHistory.removeAll()
        if let restored = reusable {
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
        forwardHistory.append(current)
        current = previous
        return true
    }

    @discardableResult
    func forward() -> Bool {
        guard let next = forwardHistory.popLast() else { return false }
        current.pager.cancel()
        history.append(current)
        current = next
        return true
    }

    static func requestURL(query: SearchQuery, site: GallerySite, lane: Int) throws -> URL {
        guard (0...1).contains(lane) else { throw ViewerError.invalidQuery("浏览范围无效。") }
        if query.count > 0 { return try query.url(site: site) }
        return lane == 1 ? site.baseURL.appendingPathComponent("popular") : try SearchQuery().url(site: site)
    }
}

enum DiscoveryHistorySwipe {
    enum Direction: Equatable { case back, forward }

    static func direction(horizontal: Double, vertical: Double, canGoBack: Bool, canGoForward: Bool) -> Direction? {
        guard abs(horizontal) >= 24, abs(horizontal) > abs(vertical) * 1.6 else { return nil }
        if horizontal > 0 { return canGoBack ? .back : nil }
        return canGoForward ? .forward : nil
    }

    static func committedDirection(horizontal: Double, vertical: Double, predictedHorizontal: Double,
                                   canGoBack: Bool, canGoForward: Bool) -> Direction? {
        guard let direction = direction(horizontal: horizontal, vertical: vertical, canGoBack: canGoBack, canGoForward: canGoForward) else { return nil }
        let flick = abs(horizontal) >= 30 && horizontal * predictedHorizontal > 0 && abs(predictedHorizontal) >= 120
        return abs(horizontal) >= 72 || flick ? direction : nil
    }
}

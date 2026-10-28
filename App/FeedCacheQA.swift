import Foundation
import SwiftUI

/// Deterministic local transport and isolated persistent cache for simulator QA.
/// It is intentionally inaccessible unless the app is in QA mode and the explicit
/// `--qa-feed-cache` launch argument is present.
enum FeedCacheQA {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isEnabled: Bool {
        AppMode.qa && arguments.contains("--qa-feed-cache")
    }

    private static var runID: String {
        guard let index = arguments.firstIndex(of: "--qa-feed-cache-run"),
              arguments.indices.contains(index + 1) else { return "default" }
        let candidate = arguments[index + 1]
        return candidate.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil
            ? candidate : "default"
    }

    static let cache: FeedSnapshotCache = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExViewerFeedCache-QA", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        return FeedSnapshotCache(root: base)
    }()

    static func stateIdentifier(for lane: String) -> String {
        "feed.qa.state.\(lane == "favorites" ? "favorites" : "discover")"
    }

    @MainActor static func stateValue(pager: GalleryPager) -> String {
        "cached=\(pager.cachedAt != nil);loading=\(pager.loading);items=\(pager.items.count);next=\(pager.next != nil);failure=\(pager.failure != nil)"
    }

    /// Loader signature matches GalleryPager's injected transport. API metadata
    /// requests are synthesized from their gids; list pages are selected by URL.
    static func loadHTML(_ url: URL, search: Bool, body: Data?) async throws -> String {
        guard isEnabled else { throw URLError(.unsupportedURL) }
        if arguments.contains("--qa-feed-cache-offline") {
            try await Task.sleep(nanoseconds: 12_000_000_000)
            try Task.checkCancellation()
            throw URLError(.notConnectedToInternet)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        try Task.checkCancellation()

        if let body, url.host == "api.e-hentai.org" {
            return metadataJSON(for: body)
        }
        guard search else { throw URLError(.unsupportedURL) }
        let favorites = url.path == "/favorites.php"
        let lane = favorites ? "Favorites" : "Discover"
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "qa-feed-page" })?.value == "2" ? 2 : 1
        let firstGID: Int64 = favorites ? 910_001 : 900_001
        let start = firstGID + Int64((page - 1) * 24)
        let rows = (0..<24).map { offset -> String in
            let gid = start + Int64(offset)
            let title = "QA Feed \(lane) \(String(format: "%02d", (page - 1) * 24 + offset + 1))"
            return """
            <tr><td><a href="/g/\(gid)/qaFeed\(gid)/"><div class="glink">\(title)</div><img src="https://ehgt.org/qa-\(gid).webp" alt="cover"></a><div>4 pages</div></td></tr>
            """
        }.joined()

        let next: String
        if page == 1 {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "qa-feed-page" }
            items.append(URLQueryItem(name: "qa-feed-page", value: "2"))
            components.queryItems = items
            next = "<a id=\"dnext\" href=\"\(components.url!.absoluteString)\">Next &gt;</a>"
        } else { next = "" }
        let categories = favorites ? "<select name=\"favcat\"><option value=\"all\">All</option></select>" : ""
        return "<html><body>\(categories)<div class=\"itg\"><table>\(rows)</table></div>\(next)</body></html>"
    }

    private static func metadataJSON(for body: Data) -> String {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let pairs = request["gidlist"] as? [[Any]] else { return "{\"gmetadata\":[]}" }
        let entries: [[String: Any]] = pairs.compactMap { pair in
            guard let raw = pair.first, let number = raw as? NSNumber else { return nil }
            let gid = number.int64Value
            let lane = gid >= 910_000 ? "Favorites" : "Discover"
            let firstGID: Int64 = lane == "Favorites" ? 910_001 : 900_001
            let index = Int(gid - firstGID + 1)
            return ["gid": gid, "title": "QA Feed \(lane) \(String(format: "%02d", index))",
                    "category": "Manga", "filecount": "4", "rating": "4.5",
                    "tags": ["other:neutralonlytag"]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["gmetadata": entries]),
              let result = String(data: data, encoding: .utf8) else { return "{\"gmetadata\":[]}" }
        return result
    }
}

struct FeedCacheQAStatus: View {
    @ObservedObject var pager: GalleryPager
    let lane: String

    var body: some View {
        Text(" ")
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Feed cache QA state")
            .accessibilityIdentifier(FeedCacheQA.stateIdentifier(for: lane))
            .accessibilityValue(FeedCacheQA.stateValue(pager: pager))
            .allowsHitTesting(false)
    }
}

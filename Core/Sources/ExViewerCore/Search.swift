import Foundation

public enum TagMatch: String, Codable, CaseIterable, Sendable {
    case all, any, exclude
    public var name: String { switch self { case .all: return "包含"; case .any: return "任一"; case .exclude: return "排除" } }
}
public struct TagRule: Codable, Hashable, Identifiable, Sendable {
    public var tag: GalleryTag
    public var match: TagMatch
    public var id: String { tag.id }
    public init(tag: GalleryTag, match: TagMatch = .all) { self.tag = tag; self.match = match }
}
public struct GalleryCategory: Identifiable, Sendable {
    public var id: Int
    public var name: String
    public static let all: [Self] = [
        .init(id: 2, name: "Doujinshi"), .init(id: 4, name: "Manga"), .init(id: 8, name: "Artist CG"),
        .init(id: 16, name: "Game CG"), .init(id: 512, name: "Western"), .init(id: 256, name: "Non-H"),
        .init(id: 32, name: "Image Set"), .init(id: 64, name: "Cosplay"), .init(id: 128, name: "Asian Porn"), .init(id: 1, name: "Misc")
    ]
}
public struct SearchQuery: Codable, Equatable, Sendable {
    public var text = ""
    public var titleOnly = false
    public var matchPhrase = false
    public var artist = ""
    public var uploader = ""
    public var rules: [TagRule] = []
    public var excludedCategories: Set<Int> = []
    public var minRating: Int? = nil
    public var minPages: Int? = nil
    public var maxPages: Int? = nil
    public var requireTorrent = false
    public init() {}

    private func quote(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\""), !text.contains("\\"), !text.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else {
            throw ViewerError.invalidQuery("条件中不能包含引号、反斜线或控制字符。")
        }
        return "\"" + text + "\""
    }
    public func expression() throws -> String {
        var terms: [String] = []
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = value.isEmpty ? [] : (matchPhrase ? [value] : value.split(whereSeparator: \.isWhitespace).map(String.init))
        for keyword in keywords { terms.append((titleOnly ? "title:" : "") + (try quote(keyword))) }
        if !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { terms.append("artist:" + (try quote(artist)) + "$") }
        if !uploader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { terms.append("uploader:" + (try quote(uploader))) }
        var includes = keywords.count + (artist.isEmpty ? 0 : 1)
        var excludes = 0
        for rule in rules {
            guard !rule.tag.name.isEmpty, rule.tag.namespace.allSatisfy({ $0.isASCII && $0.isLetter }) else { throw ViewerError.invalidQuery("请使用 namespace:tag 格式的有效标签。") }
            let prefix = rule.match == .exclude ? "-" : rule.match == .any ? "~" : ""
            terms.append(prefix + rule.tag.namespace + ":" + (try quote(rule.tag.name)) + "$")
            if rule.match == .exclude { excludes += 1 } else { includes += 1 }
        }
        guard includes <= 5, excludes <= 10 else { throw ViewerError.invalidQuery("站点每次最多支持 5 个包含条件和 10 个排除条件。") }
        let expression = terms.joined(separator: " ")
        guard expression.count <= 200 else { throw ViewerError.invalidQuery("搜索条件超过站点 200 字符限制，请减少条件。") }
        return expression
    }
    public func url(site: GallerySite, favorites: Bool = false) throws -> URL {
        if let minPages, minPages < 0 { throw ViewerError.invalidQuery("最小页数不能小于 0。") }
        if let maxPages, maxPages < 0 { throw ViewerError.invalidQuery("最大页数不能小于 0。") }
        if let minPages, let maxPages, minPages > maxPages { throw ViewerError.invalidQuery("最小页数不能大于最大页数。") }
        if let minRating, !(2...5).contains(minRating) { throw ViewerError.invalidQuery("最低评分应为 2 至 5 星。") }
        guard excludedCategories.isSubset(of: Set(GalleryCategory.all.map(\.id))), excludedCategories.count < 10 else { throw ViewerError.invalidQuery("请至少选择一个画廊分类。") }
        var components = URLComponents(url: site.baseURL.appendingPathComponent(favorites ? "favorites.php" : ""), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "f_search", value: try expression()), URLQueryItem(name: "inline_set", value: "dm_e")]
        if favorites { items.append(.init(name: "favcat", value: "all")) }
        if !excludedCategories.isEmpty { items.append(.init(name: "f_cats", value: String(excludedCategories.reduce(0, |)))) }
        if let minRating { items += [.init(name: "f_sr", value: "on"), .init(name: "f_srdd", value: String(minRating))] }
        if minPages != nil || maxPages != nil {
            items.append(.init(name: "f_sp", value: "on"))
            if let minPages { items.append(.init(name: "f_spf", value: String(minPages))) }
            if let maxPages { items.append(.init(name: "f_spt", value: String(maxPages))) }
        }
        if requireTorrent { items.append(.init(name: "f_storr", value: "on")) }
        components.queryItems = items
        return components.url!
    }
    public var count: Int { (text.isEmpty ? 0 : 1) + (artist.isEmpty ? 0 : 1) + (uploader.isEmpty ? 0 : 1) + rules.count + (excludedCategories.isEmpty ? 0 : 1) + (minRating == nil ? 0 : 1) + (minPages == nil && maxPages == nil ? 0 : 1) + (requireTorrent ? 1 : 0) }
    public var pageRangeWarning: String? {
        if let minPages, minPages > 1000 { return "站点可能拒绝过窄或超过 1000 页的范围。" }
        if let maxPages, maxPages < 10 { return "站点可能拒绝最大页数小于 10 的范围。" }
        if let minPages, let maxPages, maxPages - minPages < 20 || Double(minPages) > Double(maxPages) * 0.8 { return "站点可能拒绝过窄的页数范围。" }
        return nil
    }
}

public struct SavedSearch: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var site: GallerySite
    public var query: SearchQuery
    public init(name: String, site: GallerySite, query: SearchQuery) { id = UUID(); self.name = name; self.site = site; self.query = query }
}

public enum BlockDecision: Equatable, Sendable { case visible, blocked, unknown }
public enum TagFilter {
    public static func decision(tags: [GalleryTag], blocked: Set<String>, complete: Bool) -> BlockDecision {
        guard !blocked.isEmpty else { return .visible }
        if tags.contains(where: { blocked.contains($0.id) }) { return .blocked }
        return complete ? .visible : .unknown
    }
}

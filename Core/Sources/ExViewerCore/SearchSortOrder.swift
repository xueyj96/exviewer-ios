import Foundation

/// Local ordering of the loaded search results. Never sent as a site parameter.
public enum SearchSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case siteDefault, ratingDescending, pagesDescending, pagesAscending, title

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .siteDefault: return "站点顺序"
        case .ratingDescending: return "评分从高到低"
        case .pagesDescending: return "页数从多到少"
        case .pagesAscending: return "页数从少到多"
        case .title: return "标题顺序"
        }
    }
    public var summary: String { self == .siteDefault ? name : "\(name) · 已加载结果" }

    public func ordered(_ galleries: [Gallery]) -> [Gallery] {
        guard self != .siteDefault else { return galleries }
        return galleries.enumerated().sorted { lhs, rhs in
            let comparison: Bool?
            switch self {
            case .siteDefault: comparison = nil
            case .ratingDescending:
                comparison = Self.before(GalleryRatingFilter.average(lhs.element.rating),
                                         GalleryRatingFilter.average(rhs.element.rating), descending: true)
            case .pagesDescending, .pagesAscending:
                comparison = Self.before(lhs.element.pages.flatMap { $0 > 0 ? $0 : nil },
                                         rhs.element.pages.flatMap { $0 > 0 ? $0 : nil }, descending: self == .pagesDescending)
            case .title:
                let value = lhs.element.title.localizedStandardCompare(rhs.element.title)
                comparison = value == .orderedSame ? nil : value == .orderedAscending
            }
            // Equal or missing keys keep their relative site order.
            return comparison ?? (lhs.offset < rhs.offset)
        }.map(\.element)
    }

    private static func before<Value: Comparable>(_ lhs: Value?, _ rhs: Value?, descending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case let (a?, b?) where a != b: return descending ? a > b : a < b
        case (_?, nil): return true
        case (nil, _?): return false
        default: return nil
        }
    }
}

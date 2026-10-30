import Foundation
import ExViewerCore

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case original, recent, oldest, title
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "原有顺序"
        case .recent: return "最近阅读"
        case .oldest: return "最早阅读"
        case .title: return "标题"
        }
    }
}

enum LibrarySortSection: String, CaseIterable {
    case history, bookmarks, downloads
    var title: String {
        switch self { case .history: return "阅读历史"; case .bookmarks: return "稍后再读"; case .downloads: return "手动下载" }
    }
    var options: [LibrarySortOrder] { self == .history ? [.recent, .oldest, .title] : [.original, .title, .recent] }
    var defaultOrder: LibrarySortOrder { self == .history ? .recent : .original }
}

/// Separate preferences only. Sorting never rewrites library.json or timestamps.
struct LibrarySortPreferences {
    static let qaSuite = "ExViewer.LibrarySort.QA"
    let owner: String
    let defaults: UserDefaults
    private func key(_ section: LibrarySortSection) -> String { "library.sort.v1.\(owner).\(section.rawValue)" }
    func order(for section: LibrarySortSection) -> LibrarySortOrder {
        guard let raw = defaults.string(forKey: key(section)), let order = LibrarySortOrder(rawValue: raw),
              section.options.contains(order) else { return section.defaultOrder }
        return order
    }
    func set(_ order: LibrarySortOrder, for section: LibrarySortSection) {
        guard section.options.contains(order) else { return }
        defaults.set(order.rawValue, forKey: key(section))
    }
    func load() -> [LibrarySortSection: LibrarySortOrder] {
        Dictionary(uniqueKeysWithValues: LibrarySortSection.allCases.map { ($0, order(for: $0)) })
    }
}

enum LibrarySorting {
    static func history(_ values: [ReadingRecord], order: LibrarySortOrder) -> [ReadingRecord] {
        ordered(values, order: order, title: { $0.gallery.title }, date: { $0.date })
    }
    static func galleries(_ values: [Gallery], order: LibrarySortOrder, history: [ReadingRecord]) -> [Gallery] {
        let dates = latestDates(history)
        return ordered(values, order: order, title: { $0.title }, date: { dates[$0.id] })
    }
    static func downloads(_ values: [DownloadRecord], order: LibrarySortOrder, history: [ReadingRecord]) -> [DownloadRecord] {
        let dates = latestDates(history)
        return ordered(values, order: order, title: { $0.gallery.title }, date: { dates[$0.id] })
    }
    private static func latestDates(_ values: [ReadingRecord]) -> [String: Date] {
        values.reduce(into: [:]) { result, record in result[record.id] = max(result[record.id] ?? .distantPast, record.date) }
    }
    private static func ordered<Value>(_ values: [Value], order: LibrarySortOrder,
                                       title: (Value) -> String, date: (Value) -> Date?) -> [Value] {
        guard order != .original else { return values }
        return values.enumerated().sorted { lhs, rhs in
            if order == .title {
                let comparison = title(lhs.element).localizedStandardCompare(title(rhs.element))
                if comparison != .orderedSame { return comparison == .orderedAscending }
            } else {
                switch (date(lhs.element), date(rhs.element)) {
                case let (a?, b?) where a != b: return order == .recent ? a > b : a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

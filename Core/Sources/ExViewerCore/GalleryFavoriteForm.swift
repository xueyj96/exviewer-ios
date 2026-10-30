import Foundation
import SwiftSoup

public enum GalleryFavoriteState: Equatable, Sendable {
    case unknown, notFavorited, favorited(String)
}

public struct FavoriteGroup: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
}

public struct GalleryFavoriteRequest: Sendable {
    public let url: URL
    public let body: Data
}

/// A short-lived snapshot of the site's single-gallery form. Hidden values and
/// notes stay in memory; this type is deliberately not Codable.
public struct GalleryFavoriteForm: Sendable {
    public let reference: GalleryRef
    public let groups: [FavoriteGroup]
    public let selectedGroup: Int?
    public let note: String
    private let hidden: [(String, String)]
    private let submit: (String, String)

    public var state: GalleryFavoriteState {
        selectedGroup.flatMap { index in groups.first { $0.id == index } }
            .map { .favorited($0.name) } ?? .notFavorited
    }
    public static func endpoint(for reference: GalleryRef) throws -> URL {
        guard reference.gid > 0, !reference.token.isEmpty, reference.token.count <= 256,
              reference.token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ViewerError.invalidQuery("画廊引用无效。")
        }
        var url = URLComponents(url: reference.site.baseURL.appendingPathComponent("gallerypopups.php"), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "gid", value: String(reference.gid)), .init(name: "t", value: reference.token), .init(name: "act", value: "addfav")]
        return url.url!
    }
    public static func normalizedNote(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func read(_ html: String, reference: GalleryRef) throws -> Self {
        let url = try endpoint(for: reference)
        try EHParser.check(html)
        let doc = try SwiftSoup.parse(html, url.absoluteString)
        guard let field = try doc.select("textarea[name=favnote], input[name=favnote]").first() else { throw ViewerError.layoutChanged }
        var ancestor = field.parent()
        while ancestor != nil && ancestor?.tagName() != "form" { ancestor = ancestor?.parent() }
        guard let form = ancestor, try form.attr("method").lowercased() == "post" else { throw ViewerError.layoutChanged }
        let rawAction = try form.attr("action")
        if !rawAction.isEmpty {
            guard let action = URL(string: rawAction, relativeTo: url)?.absoluteURL,
                  URLPolicy.account(action), action.host == reference.site.host, action.path == "/gallerypopups.php" else { throw ViewerError.restricted }
            if let items = URLComponents(url: action, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty {
                for pair in [("gid", String(reference.gid)), ("t", reference.token), ("act", "addfav")] {
                    let values = items.filter { $0.name == pair.0 }.map(\.value)
                    guard values == [pair.1] else { throw ViewerError.restricted }
                }
            }
        }
        let rows = Array(try form.select(".nosel > div"))
        var groups: [FavoriteGroup] = []
        var selected: Int?
        var removable = false
        if rows.count == 10 || rows.count == 11 {
            for (index, row) in rows.enumerated() {
                guard let input = try row.select("input").first() else { throw ViewerError.layoutChanged }
                if index == 10 {
                    let marker = try row.attr("onclick") + input.attr("value") + row.text()
                    guard marker.lowercased().contains("favdel") || marker.lowercased().contains("remove from favorites") else { throw ViewerError.layoutChanged }
                    removable = true; continue
                }
                let value = try input.attr("value")
                if !value.isEmpty { guard value == String(index) || value == "fav\(index)" else { throw ViewerError.layoutChanged } }
                let label = try row.text().trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.count <= 200 else { throw ViewerError.layoutChanged }
                groups.append(.init(id: index, name: label.isEmpty ? "分组 \(index + 1)" : label))
                if input.hasAttr("checked") { guard selected == nil else { throw ViewerError.layoutChanged }; selected = index }
            }
        } else {
            for input in try form.select("input[type=radio][name=favcat]") {
                let value = try input.attr("value")
                if value == "favdel" { removable = true; continue }
                guard let index = Int(value), (0...9).contains(index), !groups.contains(where: { $0.id == index }) else { throw ViewerError.layoutChanged }
                let label = try input.parent()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard label.count <= 200 else { throw ViewerError.layoutChanged }
                groups.append(.init(id: index, name: label.isEmpty ? "分组 \(index + 1)" : label))
                if input.hasAttr("checked") { guard selected == nil else { throw ViewerError.layoutChanged }; selected = index }
            }
        }
        guard Set(groups.map(\.id)) == Set(0...9) else { throw ViewerError.layoutChanged }
        if removable && selected == nil {
            selected = try form.select("input[type=hidden][name=favcat]").first().flatMap { Int(try $0.attr("value")) }
            guard let selected, (0...9).contains(selected) else { throw ViewerError.layoutChanged }
        }
        let excluded = Set(["favcat", "favnote", "update", "submit", "apply"])
        let hidden = try form.select("input[type=hidden][name]").map { (try $0.attr("name"), try $0.attr("value")) }.filter { !excluded.contains($0.0) }
        guard hidden.count <= 20, hidden.allSatisfy({ !$0.0.isEmpty && $0.0.count <= 100 && $0.1.count <= 4096 }) else { throw ViewerError.layoutChanged }
        for pair in [("gid", String(reference.gid)), ("t", reference.token), ("act", "addfav")] {
            guard hidden.filter({ $0.0 == pair.0 }).allSatisfy({ $0.1 == pair.1 }) else { throw ViewerError.restricted }
        }
        let button = try form.select("input[type=submit][name], button[type=submit][name]").first()
        let buttonName = try button?.attr("name") ?? "submit"
        let buttonValue = try button?.attr("value") ?? "Apply Changes"
        guard ["submit", "apply"].contains(buttonName), buttonValue.count <= 100 else { throw ViewerError.layoutChanged }
        let note = normalizedNote(try field.val())
        guard note.utf8.count <= 4096 else { throw ViewerError.layoutChanged }
        return Self(reference: reference, groups: groups.sorted { $0.id < $1.id }, selectedGroup: removable ? selected : nil,
                    note: note, hidden: hidden,
                    submit: (buttonName, buttonValue.isEmpty ? "Apply Changes" : buttonValue))
    }

    public func request(action: FavoriteAction, note: String) throws -> GalleryFavoriteRequest {
        if case let .move(index) = action, !groups.contains(where: { $0.id == index }) { throw ViewerError.invalidQuery("请选择有效的收藏分组。") }
        let note = Self.normalizedNote(action == .remove ? "" : note)
        guard (note.utf8.count <= 200 || note == self.note), !note.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10].contains($0.value) }) else {
            throw ViewerError.invalidQuery("收藏备注过长或包含不支持的字符，请删减后保存。")
        }
        let value: String
        switch action { case .move(let index): value = String(index); case .remove: value = "favdel" }
        let pairs = hidden + [("favcat", value), ("favnote", note), submit, ("update", "1")]
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: safe)!.replacingOccurrences(of: "%20", with: "+") }
        return GalleryFavoriteRequest(url: try Self.endpoint(for: reference), body: Data(pairs.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&").utf8))
    }

    public func confirms(_ action: FavoriteAction, note: String) -> Bool {
        switch action {
        case .remove: return selectedGroup == nil
        case .move(let index): return selectedGroup == index && self.note == Self.normalizedNote(note)
        }
    }
}

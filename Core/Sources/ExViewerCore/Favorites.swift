import Foundation
import SwiftSoup

public enum FavoriteAction: Equatable, Sendable {
    case move(Int)
    case remove
    public var value: String { switch self { case .move(let index): return "fav\(index)"; case .remove: return "delete" } }
}

/// Explicit same-site form payload for the site's fixed bulk favorites protocol.
public struct FavoritesBatchRequest: Sendable {
    public let url: URL
    public let body: Data

    public init(url: URL, site: GallerySite, gids: [Int64], action: FavoriteAction) throws {
        guard URLPolicy.account(url), url.host?.lowercased() == site.host, url.path == "/favorites.php" else { throw ViewerError.restricted }
        guard !gids.isEmpty, gids.count <= 25, Set(gids).count == gids.count, gids.allSatisfy({ $0 > 0 }) else {
            throw ViewerError.invalidQuery("每批请选择 1 至 25 个有效收藏。")
        }
        if case .move(let index) = action, !(0...9).contains(index) { throw ViewerError.invalidQuery("收藏分组无效。") }
        let pairs = [("ddact", action.value)] + gids.map { ("modifygids[]", String($0)) } + [("apply", "Apply")]
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: safe)!.replacingOccurrences(of: "%20", with: "+") }
        self.url = url
        self.body = Data(pairs.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&").utf8)
    }
}

/// Runs one mutation at most once. Once `submit` starts, every failure means the request may have reached the server.
@MainActor public enum FavoritesSubmissionExecutor {
    public static func run<Value>(isCurrent: () -> Bool,
                                  submit: () async throws -> String,
                                  parse: (String) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard isCurrent() else { throw ViewerError.stale }
        let response: String
        do { response = try await submit() }
        catch { throw FavoritesSubmissionFailure(requestMayHaveBeenSent: true, underlying: error) }
        do {
            try Task.checkCancellation()
            guard isCurrent() else { throw ViewerError.stale }
            return try parse(response)
        } catch { throw FavoritesSubmissionFailure(requestMayHaveBeenSent: true, underlying: error) }
    }
}

public struct FavoritesSubmissionFailure: Error {
    public let requestMayHaveBeenSent: Bool
    public let underlying: Error
    public init(requestMayHaveBeenSent: Bool, underlying: Error) {
        self.requestMayHaveBeenSent = requestMayHaveBeenSent
        self.underlying = underlying
    }
}

/// Values from the site's own form stay in memory for one request only.
public struct FavoritesForm: Sendable {
    public let url: URL
    private let actions: Set<String>
    private let hidden: [(String, String)]
    public static func read(_ html: String, url: URL, site: GallerySite) throws -> Self {
        guard URLPolicy.account(url), url.host == site.host, url.path == "/favorites.php" else { throw ViewerError.restricted }
        try EHParser.check(html)
        let doc = try SwiftSoup.parse(html, url.absoluteString)
        guard let input = try doc.select("input[name='modifygids[]']").first() else { throw ViewerError.layoutChanged }
        var parent = input.parent()
        while parent != nil && parent?.tagName() != "form" { parent = parent?.parent() }
        guard let form = parent, try form.attr("method").lowercased() == "post" else { throw ViewerError.layoutChanged }
        let rawAction = try form.attr("action")
        guard let destination = URL(string: rawAction.isEmpty ? url.absoluteString : rawAction, relativeTo: url)?.absoluteURL,
              URLPolicy.account(destination), destination.host == site.host, destination.path == "/favorites.php" else { throw ViewerError.restricted }
        let values = Set(try form.select("select[name=ddact] option[value]").map { try $0.attr("value") })
        guard values.contains("delete"), (0...9).allSatisfy({ values.contains("fav\($0)") }) else { throw ViewerError.layoutChanged }
        let fields = try form.select("input[type=hidden][name]").map { (try $0.attr("name"), try $0.attr("value")) }
            .filter { !["ddact", "modifygids[]", "apply"].contains($0.0) }
        guard fields.count <= 20, fields.allSatisfy({ !$0.0.isEmpty && $0.0.count <= 100 && $0.1.count <= 4096 }) else { throw ViewerError.layoutChanged }
        return Self(url: destination, actions: values, hidden: fields)
    }
    public func body(gids: [Int64], action: FavoriteAction) throws -> Data {
        guard !gids.isEmpty, gids.count <= 25, Set(gids).count == gids.count, gids.allSatisfy({ $0 > 0 }), actions.contains(action.value) else { throw ViewerError.invalidQuery("每批请选择 1 至 25 个有效收藏。") }
        if case .move(let index) = action, !(0...9).contains(index) { throw ViewerError.invalidQuery("收藏分组无效。") }
        let pairs = hidden + [("ddact", action.value)] + gids.map { ("modifygids[]", String($0)) } + [("apply", "Apply")]
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: safe)!.replacingOccurrences(of: "%20", with: "+") }
        return Data(pairs.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&").utf8)
    }
}

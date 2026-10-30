import Foundation
import ExViewerCore

/// In-memory neutral server used only by the simulator's explicit QA mode.
@MainActor enum NativeFavoritesQA {
    static var groups: [String] { ["默认", "待阅读", QASamples.favoriteGroupName, "画集", "短篇", "长篇", "关注", "推荐", "整理中", "其他"] }
    private final class Record {
        var group: Int?
        var note: String
        var reads = 0
        var posts = 0
        var readbackFailures = 0
        init(existing: Bool) { group = existing ? 2 : nil; note = existing ? "Existing neutral note" : "" }
    }
    private static var records: [GalleryRef: Record] = [:]
    static func counts(reference: GalleryRef) -> String {
        "reads=\(records[reference]?.reads ?? 0);posts=\(records[reference]?.posts ?? 0)"
    }
    static func detailState(reference: GalleryRef) -> GalleryFavoriteState {
        precondition(AppMode.qa)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--qa-favorite-unauthenticated") { return .unknown }
        let record = records[reference] ?? Record(existing: args.contains("--qa-favorite-existing"))
        records[reference] = record
        return record.group.map { .favorited(groups[$0]) } ?? .notFavorited
    }
    static func favorites(site: GallerySite) -> [Gallery] {
        QASamples.galleries.filter { $0.ref.site == site && records[$0.ref]?.group != nil }
    }
    static func html(reference: GalleryRef, group: Int?, note: String) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let rows = groups.enumerated().map { index, name in
            let checked = group == index || (group == nil && index == 0) ? " checked" : ""
            return "<div onclick=\"favsel('\(index)')\"><input type='radio' name='favcat' value='\(index)'\(checked)>\(escape(name))</div>"
        }.joined()
        let remove = group == nil ? "" : "<div onclick=\"favsel('favdel')\"><input type='radio' name='favcat' value='favdel'>Remove from Favorites</div>"
        return "<html><form method='post'><div class='nosel'>\(rows)\(remove)</div><textarea name='favnote'>\(escape(note))</textarea><input type='hidden' name='update' value='1'><input type='submit' name='submit' value='Apply Changes'></form></html>"
    }
    static func client(reference: GalleryRef, session: SiteSession) -> GalleryFavoriteClient {
        precondition(AppMode.qa)
        let args = ProcessInfo.processInfo.arguments
        let record = records[reference] ?? Record(existing: args.contains("--qa-favorite-existing"))
        records[reference] = record
        let revision = session.generation, owner = session.owner
        var clientReads = 0
        return .init(isCurrent: { session.generation == revision && session.owner == owner }, read: {
            clientReads += 1
            record.reads += 1
            if args.contains("--qa-favorite-unauthenticated") { throw ViewerError.authentication }
            if args.contains("--qa-favorite-loading"), clientReads == 1 { try await Task.sleep(nanoseconds: 20_000_000_000) }
            if args.contains("--qa-favorite-read-failure"), clientReads == 1 { throw URLError(.timedOut) }
            if record.readbackFailures > 0 { record.readbackFailures -= 1; throw URLError(.timedOut) }
            return try GalleryFavoriteForm.read(html(reference: reference, group: record.group, note: record.note), reference: reference)
        }, submit: { request in
            record.posts += 1
            try await Task.sleep(nanoseconds: 80_000_000)
            let body = String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
            let fields = URLComponents(string: "https://example.invalid/?" + body)!.queryItems ?? []
            if !args.contains("--qa-favorite-unapplied") {
                let category = fields.first { $0.name == "favcat" }?.value ?? ""
                record.group = category == "favdel" ? nil : Int(category)
                record.note = record.group == nil ? "" : (fields.first { $0.name == "favnote" }?.value ?? "")
            }
            if args.contains("--qa-favorite-unknown") { record.readbackFailures = 1 }
            if args.contains("--qa-favorite-post-lost") { throw URLError(.networkConnectionLost) }
        }, didSubmit: { if session.generation == revision { session.favoriteChanged() } })
    }
}

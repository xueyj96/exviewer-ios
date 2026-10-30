import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class SiteFavoriteCacheTests: XCTestCase {
    private let ref = GalleryRef(site: .ex, gid: 81, token: "preview")
    private func form(_ group: Int?) throws -> GalleryFavoriteForm {
        try GalleryFavoriteForm.read(NativeFavoritesQA.html(reference: ref, group: group, note: ""), reference: ref)
    }
    func testReaderAndDetailShareConfirmedEditAndDoNotReadAgainOnRevision() async throws {
        let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID())
        let detail = GalleryFavoriteObservation(), reader = GalleryFavoriteObservation()
        var group: Int?, reads = 0
        let client = GalleryFavoriteClient(isCurrent: { true }, read: { reads += 1; return try self.form(group) }, submit: { _ in group = 2 })
        detail.bind(client, reference: ref, cache: cache, scope: scope)
        reader.bind(client, reference: ref, cache: cache, scope: scope); XCTAssertEqual(reads, 0)
        let p = reader.preparation(client, reference: ref)
        let edit = GalleryFavoriteEditorModel(client: p.client, initialForm: p.initialForm)
        await edit.reload(); edit.selection = 2
        let saved = await edit.save(); XCTAssertTrue(saved)
        reader.accept(edit.observedState, form: edit.form); detail.syncFromCache()
        XCTAssertEqual(reader.state, .favorited("已读")); XCTAssertEqual(detail.state, reader.state)
        detail.bind(client, reference: ref, cache: cache, scope: scope)
        XCTAssertEqual(reads, 2, "Only initial read and post-submit verification are needed")
        let remove = reader.preparation(client, reference: ref)
        let removal = GalleryFavoriteEditorModel(client: remove.client, initialForm: remove.initialForm)
        // Verify publication of a removal independently of the mock submit body.
        let none = try form(nil); reader.accept(.notFavorited, form: none); detail.syncFromCache()
        XCTAssertEqual(detail.state, .notFavorited); XCTAssertNotNil(removal.form)
    }
    func testOldReadCannotOverwriteNewerLocalConfirmationAndFailureRemainsUnknown() async throws {
        let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID())
        let o = GalleryFavoriteObservation(), value = try form(nil)
        o.bind(.init(isCurrent: { true }, read: { value }, submit: { _ in }), reference: ref, cache: cache, scope: scope)
        let initialVersion = cache.entry(scope)?.version
        cache.put(.favorited("已读"), form: try form(2), scope: scope, force: true)
        XCTAssertFalse(cache.put(value.state, scope: scope, expectedVersion: initialVersion, conditional: true))
        o.syncFromCache()
        XCTAssertEqual(o.state, .favorited("已读"))
        let version = cache.entry(scope)?.version
        cache.put(.unknown, scope: scope, force: true)
        XCTAssertFalse(cache.put(.favorited("stale"), scope: scope, expectedVersion: version, conditional: true))
        o.syncFromCache(); XCTAssertEqual(o.state, .unknown)
    }
    func testCacheIsBoundedAndCannotCarryStateOrFormsAcrossAccountsAndSessions() throws {
        let cache = SiteFavoriteCache(), generation = UUID()
        for id in 1...80 {
            cache.put(.notFavorited, scope: .init(reference: .init(site: .ex, gid: Int64(id), token: "preview"), owner: "aa", generation: generation))
        }
        XCTAssertNil(cache.entry(.init(reference: .init(site: .ex, gid: 1, token: "preview"), owner: "aa", generation: generation)))
        let old = GalleryFavoriteScope(reference: ref, owner: "aa", generation: generation)
        cache.put(.favorited("已读"), form: try form(2), scope: old)
        XCTAssertNotNil(cache.recent(old)); XCTAssertNil(cache.recent(old, now: Date().addingTimeInterval(16)))
        let other = GalleryFavoriteScope(reference: ref, owner: "bb", generation: UUID())
        XCTAssertNil(cache.entry(other)); cache.put(.notFavorited, scope: other)
        XCTAssertNil(cache.entry(old)); XCTAssertEqual(cache.entry(other)?.state, .notFavorited)
    }
}

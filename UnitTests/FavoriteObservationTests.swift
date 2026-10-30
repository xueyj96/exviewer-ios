import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class FavoriteObservationTests: XCTestCase {
    private let ref = GalleryRef(site: .ex, gid: 72, token: "preview")
    private func form(_ group: Int?) throws -> GalleryFavoriteForm {
        try GalleryFavoriteForm.read(NativeFavoritesQA.html(reference: ref, group: group, note: ""), reference: ref)
    }
    private final class Identity { var current = true }
    func testBindingRepeatedlyAndReceivingLocalChangesNeverReadsTheNetwork() throws {
        let o = GalleryFavoriteObservation(), cache = SiteFavoriteCache()
        let scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID()); var reads = 0
        let client = GalleryFavoriteClient(isCurrent: { true }, read: { reads += 1; return try self.form(nil) }, submit: { _ in })
        for _ in 0..<100 {
            o.bind(client, reference: ref, cache: cache, scope: scope)
            cache.put(.notFavorited, scope: scope); o.syncFromCache()
        }
        XCTAssertEqual(reads, 0); XCTAssertEqual(o.state, .notFavorited)
    }
    func testExpiredFormKeepsKnownDisplayStateWithoutRefreshing() throws {
        let o = GalleryFavoriteObservation(), cache = SiteFavoriteCache()
        let scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID()), value = try form(2); var reads = 0
        let client = GalleryFavoriteClient(isCurrent: { true }, read: { reads += 1; return value }, submit: { _ in })
        cache.put(value.state, form: value, scope: scope)
        o.bind(client, reference: ref, cache: cache, scope: scope, now: Date().addingTimeInterval(60))
        XCTAssertEqual(o.state, .favorited("已读")); XCTAssertNil(o.preparation(client, reference: ref).initialForm)
        XCTAssertEqual(reads, 0)
    }
    func testOnlyExplicitEditorReadsAndSubmissionStillUsesFreshReadback() async throws {
        let o = GalleryFavoriteObservation(); var group: Int?; var reads = 0, posts = 0
        let client = GalleryFavoriteClient(isCurrent: { true }, read: {
            reads += 1; return try self.form(group)
        }, submit: { _ in posts += 1; group = 1 })
        o.bind(client, reference: ref); XCTAssertEqual(reads, 0)
        let p = o.preparation(client, reference: ref), edit = GalleryFavoriteEditorModel(client: o.preparation(client, reference: ref).client)
        XCTAssertNil(p.initialForm); await edit.reload(); XCTAssertEqual(reads, 1)
        edit.selection = 1; let saved = await edit.save(); XCTAssertTrue(saved)
        o.accept(edit.observedState, form: edit.form)
        XCTAssertEqual(reads, 2); XCTAssertEqual(posts, 1); XCTAssertEqual(o.state, .favorited("待阅读"))
        let warm = o.preparation(client, reference: ref)
        XCTAssertNotNil(GalleryFavoriteEditorModel(client: warm.client, initialForm: warm.initialForm).form)
        XCTAssertEqual(reads, 2)
    }
    func testAccountSwitchRejectsOldPublicationAndAnotherGalleryCannotUseTheForm() throws {
        let o = GalleryFavoriteObservation(), cache = SiteFavoriteCache(), identity = Identity()
        let scope = GalleryFavoriteScope(reference: ref, owner: "aa", generation: UUID()), value = try form(2)
        let client = GalleryFavoriteClient(isCurrent: { identity.current }, read: { value }, submit: { _ in })
        o.bind(client, reference: ref, cache: cache, scope: scope); o.accept(value.state, form: value)
        XCTAssertNil(o.preparation(client, reference: .init(site: .eh, gid: 72, token: "preview")).initialForm)
        identity.current = false; o.accept(.notFavorited)
        XCTAssertEqual(cache.entry(scope)?.state, value.state)
        o.bind(client, reference: ref, cache: cache, scope: scope); XCTAssertEqual(o.state, .unknown)
        XCTAssertNil(o.preparation(client, reference: ref).initialForm)
    }
    func testUnknownOutcomeDoesNotStartBackgroundRetryOrClaimSuccess() async throws {
        let o = GalleryFavoriteObservation(); var reads = 0, posts = 0
        let initial = try form(nil)
        let client = GalleryFavoriteClient(isCurrent: { true }, read: {
            reads += 1; if reads > 1 { throw URLError(.timedOut) }; return initial
        }, submit: { _ in posts += 1 })
        o.bind(client, reference: ref)
        let p = o.preparation(client, reference: ref), model = GalleryFavoriteEditorModel(client: o.preparation(client, reference: ref).client)
        await model.reload(); model.selection = 2
        let saved = await model.save(); XCTAssertFalse(saved); o.accept(model.observedState)
        for _ in 0..<100 { o.syncFromCache(); _ = o.preparation(p.client, reference: ref) }
        XCTAssertEqual(reads, 2); XCTAssertEqual(posts, 1); XCTAssertEqual(o.state, .unknown)
        XCTAssertTrue(model.needsVerification)
    }
    func testManualEditorRefreshPreservesDraftAndDoesExactlyOneRead() async throws {
        let o = GalleryFavoriteObservation(), value = try form(2); var reads = 0
        let client = GalleryFavoriteClient(isCurrent: { true }, read: { reads += 1; return value }, submit: { _ in })
        o.bind(client, reference: ref); o.accept(value.state, form: value)
        let p = o.preparation(client, reference: ref), model = GalleryFavoriteEditorModel(client: o.preparation(client, reference: ref).client, initialForm: value)
        model.selection = 7; model.note = "Draft retained"; await model.reload(preserveDraft: true)
        XCTAssertEqual(reads, 1); XCTAssertEqual(model.selection, 7); XCTAssertEqual(model.note, "Draft retained")
        XCTAssertNotNil(p.initialForm)
    }
}

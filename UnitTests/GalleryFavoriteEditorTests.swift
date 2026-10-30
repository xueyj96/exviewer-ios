import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class GalleryFavoriteEditorTests: XCTestCase {
    @MainActor private final class Server {
        let ref = GalleryRef(site: .ex, gid: 42, token: "preview")
        var group: Int?
        var note = ""
        var reads = 0, posts = 0, invalidations = 0, notifications = 0
        var current = true, apply = true, lostPost = false
        var unreadable = 0
        var failNextReadback = false
        var postDelay: UInt64 = 0
        func form() throws -> GalleryFavoriteForm { try GalleryFavoriteForm.read(NativeFavoritesQA.html(reference: ref, group: group, note: note), reference: ref) }
        var client: GalleryFavoriteClient {
            .init(isCurrent: { self.current }, read: {
                self.reads += 1
                if self.unreadable > 0 { self.unreadable -= 1; throw ViewerError.layoutChanged }
                return try self.form()
            }, submit: { request in
                self.posts += 1
                if self.postDelay > 0 { try await Task.sleep(nanoseconds: self.postDelay) }
                if self.apply {
                    let body = String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
                    let fields = URLComponents(string: "https://example.invalid/?" + body)!.queryItems!
                    let group = fields.first { $0.name == "favcat" }!.value!
                    self.group = group == "favdel" ? nil : Int(group)
                    self.note = self.group == nil ? "" : fields.first { $0.name == "favnote" }!.value!
                }
                if self.failNextReadback { self.unreadable = 1 }
                if self.lostPost { throw URLError(.networkConnectionLost) }
            }, willSubmit: { self.invalidations += 1 }, didSubmit: { self.notifications += 1 })
        }
    }
    func testCancelOnlyLoadsStateAndDoesNotWriteOrInvalidate() async {
        let server = Server(); server.group = 2; server.note = "Existing neutral note"
        let model = GalleryFavoriteEditorModel(client: server.client)
        await model.reload(); XCTAssertEqual(model.selection, 2); XCTAssertEqual(model.note, server.note)
        XCTAssertFalse(model.canSave); model.selection = 7; model.note = "unsaved"; model.cancel()
        XCTAssertEqual(server.posts, 0); XCTAssertEqual(server.invalidations, 0)
        XCTAssertEqual(server.group, 2); XCTAssertEqual(server.note, "Existing neutral note")
    }
    func testAddMoveAndRemoveRequireFreshStateAndNotifyFavoritesList() async {
        let server = Server()
        let edit = GalleryFavoriteEditorModel(client: server.client)
        await edit.reload(); XCTAssertFalse(edit.canSave)
        edit.selection = 3; edit.note = "Neutral note"
        let added = await edit.save(); XCTAssertTrue(added); XCTAssertEqual(edit.observedState, .favorited("画集"))
        edit.selection = 7; let moved = await edit.save(); XCTAssertTrue(moved); XCTAssertEqual(server.note, "Neutral note")
        let removed = await edit.save(remove: true); XCTAssertTrue(removed); XCTAssertEqual(edit.observedState, .notFavorited)
        XCTAssertEqual(server.posts, 3); XCTAssertEqual(server.reads, 4)
        XCTAssertEqual(server.invalidations, 3); XCTAssertEqual(server.notifications, 3)
    }
    func testLostPostReplyCanBeConfirmedByReadbackWithoutResubmitting() async {
        let server = Server(); server.lostPost = true
        let model = GalleryFavoriteEditorModel(client: server.client); await model.reload(); model.selection = 1
        let confirmed = await model.save()
        XCTAssertTrue(confirmed); XCTAssertFalse(model.needsVerification)
        XCTAssertEqual(server.posts, 1); XCTAssertEqual(server.reads, 2)
    }
    func testUnknownOutcomeKeepsDraftBlocksPostsAndReadOnlyRefreshCanConfirm() async {
        let server = Server(); server.failNextReadback = true
        let model = GalleryFavoriteEditorModel(client: server.client); await model.reload()
        model.selection = 4; model.note = "Retained neutral draft"
        let initial = await model.save(); XCTAssertFalse(initial); XCTAssertTrue(model.needsVerification)
        XCTAssertEqual(model.observedState, .unknown); XCTAssertEqual(model.selection, 4); XCTAssertEqual(model.note, "Retained neutral draft")
        let duplicate = await model.save(); XCTAssertFalse(duplicate); XCTAssertEqual(server.posts, 1)
        let refreshed = await model.reload(preserveDraft: true)
        XCTAssertTrue(refreshed); XCTAssertFalse(model.needsVerification); XCTAssertEqual(server.posts, 1)
    }
    func testReadableReplyWithoutMatchingStateIsNotSavedAndRetainsEdits() async {
        let server = Server(); server.apply = false
        let model = GalleryFavoriteEditorModel(client: server.client); await model.reload(); model.selection = 6; model.note = "Keep this"
        let saved = await model.save(); XCTAssertFalse(saved)
        XCTAssertEqual(model.observedState, .notFavorited); XCTAssertEqual(model.selection, 6); XCTAssertEqual(model.note, "Keep this")
        XCTAssertNotNil(model.error); XCTAssertFalse(model.needsVerification); XCTAssertTrue(model.canSave)
    }
    func testDoubleSaveAndInvalidNotesDoNotCauseExtraPosts() async {
        let server = Server(); server.postDelay = 20_000_000
        let model = GalleryFavoriteEditorModel(client: server.client); await model.reload(); model.selection = 1
        model.note = String(repeating: "中", count: 67); let invalid = await model.save(); XCTAssertFalse(invalid); XCTAssertEqual(server.posts, 0)
        model.note = "Valid"
        let first = Task { await model.save() }
        for _ in 0..<100 { if server.posts == 1 { break }; try? await Task.sleep(nanoseconds: 1_000_000) }
        let second = await model.save(); XCTAssertFalse(second)
        let firstResult = await first.value; XCTAssertTrue(firstResult); XCTAssertEqual(server.posts, 1)
    }
    func testStaleContextDoesNotSubmitOrExposeLateState() async {
        let server = Server(); server.current = false
        let model = GalleryFavoriteEditorModel(client: server.client); await model.reload()
        XCTAssertNil(model.form); XCTAssertEqual(server.reads, 0)
        server.current = true; await model.reload(); model.selection = 2; server.current = false
        let saved = await model.save(); XCTAssertFalse(saved); XCTAssertEqual(server.posts, 0)
    }
    func testMovingPreservesAnExistingLongNoteWithoutRewritingIt() async {
        let server = Server(); server.group = 1; server.note = String(repeating: "x", count: 250)
        let model = GalleryFavoriteEditorModel(client: server.client); await model.reload(); model.selection = 4
        XCTAssertTrue(model.canSave)
        let saved = await model.save(); XCTAssertTrue(saved); XCTAssertEqual(server.note, String(repeating: "x", count: 250))
        model.note += "new"; XCTAssertFalse(model.canSave)
    }
}

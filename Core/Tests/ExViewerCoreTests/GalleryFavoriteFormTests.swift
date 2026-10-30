import XCTest
@testable import ExViewerCore

final class GalleryFavoriteFormTests: XCTestCase {
    private let ref = GalleryRef(site: .ex, gid: 42, token: "preview")
    private func html(group: Int? = nil, note: String = "", action: String = "", named: Bool = true) -> String {
        let rows = (0...9).map { index in
            let attributes = named ? "name='favcat' value='\(index)'" : ""
            let checked = group == index || (group == nil && index == 0) ? "checked" : ""
            return "<div onclick=\"favsel('\(index)')\"><input type='radio' \(attributes) \(checked)>Group \(index + 1)</div>"
        }.joined()
        let remove = group == nil ? "" : "<div onclick=\"favsel('favdel')\"><input type='radio' value='favdel'>Remove from Favorites</div>"
        return "<form method='post' action='\(action)'><div class='nosel'>\(rows)\(remove)</div><textarea name='favnote'>\(note)</textarea><input type='hidden' name='form_version' value='1'><input type='submit' name='submit' value='Apply Changes'></form>"
    }
    func testNewFormDefaultRadioDoesNotPretendGalleryIsAlreadyFavorited() throws {
        let form = try GalleryFavoriteForm.read(html(), reference: ref)
        XCTAssertEqual(form.groups.count, 10); XCTAssertNil(form.selectedGroup)
        XCTAssertEqual(form.state, .notFavorited); XCTAssertEqual(form.groups[3].name, "Group 4")
    }
    func testExistingGroupAndNoteAreReadForNamedAndJavaScriptRadioRows() throws {
        for named in [true, false] {
            let form = try GalleryFavoriteForm.read(html(group: 3, note: "A &amp; B\n第二行", named: named), reference: ref)
            XCTAssertEqual(form.selectedGroup, 3); XCTAssertEqual(form.state, .favorited("Group 4"))
            XCTAssertEqual(form.note, "A & B\n第二行")
        }
    }
    func testAddMoveAndRemovalUseSingleGalleryProtocolAndPreserveFormFields() throws {
        let form = try GalleryFavoriteForm.read(html(group: 3, note: "existing"), reference: ref)
        let request = try form.request(action: .move(7), note: "New note & +")
        XCTAssertEqual(request.url.host, "exhentai.org"); XCTAssertEqual(request.url.path, "/gallerypopups.php")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "form_version=1&favcat=7&favnote=New+note+%26+%2B&submit=Apply+Changes&update=1")
        XCTAssertTrue(String(decoding: try form.request(action: .remove, note: "ignored").body, as: UTF8.self).contains("favcat=favdel&favnote=&submit="))
        XCTAssertThrowsError(try form.request(action: .move(10), note: ""))
        let removed = try GalleryFavoriteForm.read(html(), reference: ref)
        XCTAssertTrue(removed.confirms(.remove, note: "")); XCTAssertFalse(removed.confirms(.move(0), note: ""))
    }
    func testNotesUseUTF8ByteLimitAndSafeEncodingWithoutSilentTruncation() throws {
        let form = try GalleryFavoriteForm.read(html(), reference: ref)
        let note = String(repeating: "中", count: 66) + "ok"
        let body = try form.request(action: .move(0), note: note).body
        XCTAssertTrue(body.allSatisfy { $0 < 128 }); XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("%E4%B8%AD"))
        XCTAssertThrowsError(try form.request(action: .move(0), note: note + "x"))
        XCTAssertThrowsError(try form.request(action: .move(0), note: "bad\0note"))
        let existing = try GalleryFavoriteForm.read(html(group: 1, note: String(repeating: "x", count: 250)), reference: ref)
        XCTAssertNoThrow(try existing.request(action: .remove, note: ""), "Removing must not be blocked by an old oversized note")
        XCTAssertNoThrow(try existing.request(action: .move(2), note: existing.note), "Moving preserves an existing note without truncation")
        XCTAssertThrowsError(try existing.request(action: .move(2), note: existing.note + "new"))
    }
    func testFormRejectsOtherOriginsGalleriesActionsAndAmbiguousLayouts() throws {
        for action in ["https://e-hentai.org/gallerypopups.php", "https://example.com/gallerypopups.php", "/favorites.php", "?gid=99&t=preview&act=addfav", "?gid=42&t=preview&act=addfav&gid=42"] {
            XCTAssertThrowsError(try GalleryFavoriteForm.read(html(action: action), reference: ref))
        }
        XCTAssertThrowsError(try GalleryFavoriteForm.read("<form method=post><textarea name=favnote></textarea></form>", reference: ref))
        XCTAssertThrowsError(try GalleryFavoriteForm.read("This page requires you to log on.", reference: ref))
        XCTAssertThrowsError(try GalleryFavoriteForm.read(html().replacingOccurrences(of: "value='9'", with: "value='4'"), reference: ref))
        XCTAssertThrowsError(try GalleryFavoriteForm.endpoint(for: .init(site: .ex, gid: 1, token: "bad/token")))
    }
    func testActualSubmitButtonNameAndEndpointRemainBoundToReference() throws {
        let valid = try GalleryFavoriteForm.endpoint(for: ref)
        let form = try GalleryFavoriteForm.read(html(action: valid.absoluteString).replacingOccurrences(of: "name='submit'", with: "name='apply'"), reference: ref)
        XCTAssertTrue(String(decoding: try form.request(action: .move(1), note: "").body, as: UTF8.self).contains("apply=Apply+Changes"))
        XCTAssertEqual(form.reference, ref)
    }
    func testDetailMissingFavoriteControlRemainsUnknown() throws {
        let body = "<div id='gn'>Neutral</div><div id='gdt'><a href='/s/page/42-1'>page</a></div>"
        XCTAssertEqual(try EHParser.detail(body, reference: ref).favoriteState, .unknown)
        XCTAssertEqual(try EHParser.detail(body + "<a id='fav'>Add to Favorites</a>", reference: ref).favoriteState, .notFavorited)
        XCTAssertEqual(try EHParser.detail(body + "<a id='fav'>Group One</a>", reference: ref).favoriteState, .favorited("Group One"))
    }
}

import XCTest
@testable import ExViewerCore

final class FavoritesTests: XCTestCase {
    private let url = URL(string: "https://exhentai.org/favorites.php?favcat=all")!
    private var fixture: String {
        "<form method='post' action='/favorites.php'><input name='modifygids[]' value='1'><input type='hidden' name='form_version' value='1'><select name='ddact'><option value='delete'>Remove</option>" + (0...9).map { "<option value='fav\($0)'>Group \($0)</option>" }.joined() + "</select></form>"
    }
    func testBatchUsesRepeatedIDsAndExpectedAction() throws {
        let form = try FavoritesForm.read(fixture, url: url, site: .ex)
        let body = String(data: try form.body(gids: [11, 22], action: .move(3)), encoding: .utf8)!
        XCTAssertEqual(body, "form_version=1&ddact=fav3&modifygids%5B%5D=11&modifygids%5B%5D=22&apply=Apply")
        XCTAssertTrue(String(data: try form.body(gids: [11], action: .remove), encoding: .utf8)!.contains("ddact=delete"))
    }
    func testInvalidBatchAndChangedFormAreRejected() throws {
        let form = try FavoritesForm.read(fixture, url: url, site: .ex)
        for ids: [Int64] in [[], [1, 1], [0], Array(1...26)] { XCTAssertThrowsError(try form.body(gids: ids, action: .remove)) }
        XCTAssertThrowsError(try form.body(gids: [1], action: .move(10)))
        XCTAssertThrowsError(try FavoritesForm.read(fixture.replacingOccurrences(of: "value='delete'", with: "value='other'"), url: url, site: .ex))
        XCTAssertThrowsError(try FavoritesForm.read("This page requires you to log on.", url: url, site: .ex)) { XCTAssertEqual($0 as? ViewerError, .authentication) }
    }
    func testFormCannotPostToAnotherOrigin() {
        XCTAssertThrowsError(try FavoritesForm.read(fixture.replacingOccurrences(of: "action='/favorites.php'", with: "action='https://e-hentai.org/favorites.php'"), url: url, site: .ex))
        XCTAssertThrowsError(try FavoritesForm.read(fixture, url: URL(string: "https://example.com/favorites.php")!, site: .ex))
    }

    func testFixedBatchRequestDoesNotNeedFormAndUsesRepeatedIDs() throws {
        let request = try FavoritesBatchRequest(url: url, site: .ex, gids: [11, 22], action: .move(3))
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "ddact=fav3&modifygids%5B%5D=11&modifygids%5B%5D=22&apply=Apply")
    }

    func testFixedBatchRequestRejectsInvalidInputBeforeSubmission() {
        for ids: [Int64] in [[], [1, 1], [0], Array(1...26)] {
            XCTAssertThrowsError(try FavoritesBatchRequest(url: url, site: .ex, gids: ids, action: .remove))
        }
        XCTAssertThrowsError(try FavoritesBatchRequest(url: url, site: .eh, gids: [1], action: .remove))
        XCTAssertThrowsError(try FavoritesBatchRequest(url: URL(string: "https://example.com/favorites.php")!, site: .ex, gids: [1], action: .remove))
        XCTAssertThrowsError(try FavoritesBatchRequest(url: url, site: .ex, gids: [1], action: .move(10)))
    }

    func testSubmissionParsesReadableNeutralListAsSubmittedOnly() async throws {
        var calls = 0
        let result = try await FavoritesSubmissionExecutor.run(isCurrent: { true }, submit: {
            calls += 1
            return "readable list"
        }, parse: { response in response })
        XCTAssertEqual(result, "readable list")
        XCTAssertEqual(calls, 1)
    }

    func testUnreadableReplyFailsWithMayHaveBeenSentAndNeverRetries() async {
        var calls = 0
        do {
            _ = try await FavoritesSubmissionExecutor.run(isCurrent: { true }, submit: {
                calls += 1
                return "unrecognized"
            }, parse: { _ in throw ViewerError.layoutChanged })
            XCTFail("expected parsing failure")
        } catch let failure as FavoritesSubmissionFailure {
            XCTAssertTrue(failure.requestMayHaveBeenSent)
            XCTAssertEqual(failure.underlying as? ViewerError, .layoutChanged)
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(calls, 1)
    }

    func testStaleGenerationDoesNotSubmitOrLateSuccess() async {
        var current = false
        var calls = 0
        do {
            _ = try await FavoritesSubmissionExecutor.run(isCurrent: { current }, submit: {
                calls += 1
                return "readable"
            }, parse: { $0 })
            XCTFail("expected stale generation")
        } catch let error as ViewerError { XCTAssertEqual(error, .stale) }
        catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(calls, 0)

        current = true
        do {
            _ = try await FavoritesSubmissionExecutor.run(isCurrent: { current }, submit: {
                calls += 1
                current = false
                return "readable"
            }, parse: { $0 })
            XCTFail("late response must not become success")
        } catch let failure as FavoritesSubmissionFailure {
            XCTAssertTrue(failure.requestMayHaveBeenSent)
            XCTAssertEqual(failure.underlying as? ViewerError, .stale)
        } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(calls, 1)
    }
}

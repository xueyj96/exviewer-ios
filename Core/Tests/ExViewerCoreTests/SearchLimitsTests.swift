import XCTest
@testable import ExViewerCore

final class SearchLimitsTests: XCTestCase {
    func testSameArtistInFilterAndTagCountsOnceAtFiveTermBoundary() throws {
        var query = SearchQuery()
        query.text = "one two three four"
        query.artist = "Preview Studio"
        query.rules = [.init(tag: .init(namespace: "artist", name: "PREVIEW STUDIO"))]
        XCTAssertEqual(try query.expression(), #""one" "two" "three" "four" artist:"preview studio"$"#)
    }

    func testInlineAndFilterArtistNormalizeWithoutChangingOtherFilters() throws {
        var query = SearchQuery()
        query.artist = "Preview Studio"; query.minRating = 3; query.maxPages = 100
        let parsed = try SearchInputParser.parse(#"one two three four A:"PREVIEW STUDIO""#, preserving: query)
        XCTAssertEqual(parsed.query.artist, "")
        XCTAssertEqual(parsed.query.rules, [.init(tag: .init(namespace: "artist", name: "PREVIEW STUDIO"))])
        XCTAssertEqual(parsed.query.minRating, 3); XCTAssertEqual(parsed.query.maxPages, 100)
        XCTAssertNoThrow(try parsed.query.url(site: .ex))
    }

    func testMultiwordArtistIsOneConditionThroughStructuredTagAndInlineInputs() throws {
        let name = "Sample Artist With Six Separate Name Words"
        let expected = #"artist:"sample artist with six separate name words"$"#
        var structured = SearchQuery(); structured.artist = name
        var tagged = SearchQuery(); tagged.rules = [.init(tag: .init(namespace: "artist", name: name))]
        let inline = try SearchInputParser.parse("ArTiSt:\"\(name)\"").query
        for query in [structured, tagged, inline] { XCTAssertEqual(try query.expression(), expected) }
    }

    func testWhitespaceArtistAndDuplicateTermsDoNotConsumeExtraSlots() throws {
        var query = SearchQuery(); query.text = "one two three four five"; query.artist = " \t "
        XCTAssertNoThrow(try query.expression())
        query.text = "one two three four five ONE"
        XCTAssertEqual(try query.expression(), #""one" "two" "three" "four" "five""#)
        query.text = ""; query.artist = ""
        query.rules = (0..<11).map { _ in .init(tag: .init(namespace: "other", name: "sample"), match: .exclude) }
        XCTAssertEqual(try query.expression(), #"-other:"sample"$"#)
    }

    func testRealLimitsReportTheExceededSideAndActualCount() throws {
        var query = SearchQuery(); query.text = "one two three four five"; query.artist = "sample"
        XCTAssertThrowsError(try query.expression()) { error in
            let message = (error as? ViewerError)?.localizedDescription ?? ""
            XCTAssertTrue(message.contains("6")); XCTAssertTrue(message.contains("包含")); XCTAssertFalse(message.contains("10"))
        }
        query.text = ""; query.artist = ""
        query.rules = (0..<11).map { .init(tag: .init(namespace: "other", name: "x\($0)"), match: .exclude) }
        XCTAssertThrowsError(try query.expression()) { error in
            let message = (error as? ViewerError)?.localizedDescription ?? ""
            XCTAssertTrue(message.contains("11")); XCTAssertTrue(message.contains("排除")); XCTAssertFalse(message.contains("包含"))
        }
        query.rules.removeLast(); XCTAssertNoThrow(try query.expression())
    }

    func testDistinctAuthorsAndMatchingModesAreNotSilentlyRemoved() throws {
        var query = SearchQuery(); query.artist = "First Artist"
        query.rules = [.init(tag: .init(namespace: "artist", name: "Second Artist")), .init(tag: .init(namespace: "artist", name: "First Artist"), match: .exclude)]
        let parsed = try SearchInputParser.parse("", preserving: query).query
        XCTAssertEqual(try parsed.expression(), #"artist:"first artist"$ artist:"second artist"$ -artist:"first artist"$"#)
        XCTAssertEqual(parsed.rules.count, 2)
    }

    func testChangingAuthorInTextOrFilterReplacesOnlyPositiveAuthors() throws {
        var previous = SearchQuery(); previous.artist = "Previous Author"; previous.minRating = 3
        previous.rules = [.init(tag: .init(namespace: "artist", name: "Old Tag Author")), .init(tag: .init(namespace: "artist", name: "Avoided Author"), match: .exclude), .init(tag: .init(namespace: "language", name: "english"))]
        let inline = try SearchInputParser.parse(#"one two three artist:"New Author""#, preserving: previous).query
        XCTAssertEqual(inline.artist, "")
        XCTAssertEqual(inline.rules.map(\.tag.name), ["Avoided Author", "english", "New Author"])
        XCTAssertNoThrow(try inline.expression()); XCTAssertEqual(inline.minRating, 3)
        previous.replaceArtist(" New Author ")
        XCTAssertEqual(try previous.expression(), #"artist:"new author"$ -artist:"avoided author"$ language:"english"$"#)
        XCTAssertEqual(previous.rules.map(\.tag.name), ["Avoided Author", "english"])
        XCTAssertEqual(previous.minRating, 3)
    }

    func testTypingArtistInSeparateWordsRetainsTheSpaceUntilSubmission() throws {
        var query = SearchQuery()
        query.replaceArtist("Sample ")
        query.replaceArtist(query.artist + "Studio")
        XCTAssertEqual(try query.expression(), #"artist:"sample studio"$"#)
    }
}

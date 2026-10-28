import XCTest
@testable import ExViewerCore

final class SearchInputTests: XCTestCase {
    func testNamespaceAliasesAreCanonicalAndDeduplicated() throws {
        var previous = SearchQuery(); previous.rules = [.init(tag: .init(namespace: "a", name: "sample"))]
        let parsed = try SearchInputParser.parse("artist:sample ~lang:english", preserving: previous)
        XCTAssertEqual(parsed.query.rules, [.init(tag: .init(namespace: "artist", name: "sample")), .init(tag: .init(namespace: "language", name: "english"), match: .any)])
    }
    func testQualifiersAreNotSilentlyConvertedToTags() {
        for value in ["-title:2007", "uploaduid:123", "comment:sample", "favnote:sample", "unknown:sample"] {
            XCTAssertThrowsError(try SearchInputParser.parse(value)) { error in
                guard let typed = error as? SearchInputError, case .unsupportedScope = typed else { return XCTFail("Expected explicit unsupported scope") }
            }
        }
    }
    func testTitleKeywordAndPositiveNegativeTagsBecomeSeparateConditions() throws {
        let parsed = try SearchInputParser.parse(
            #"title:"Autumn book" uploader:"archive team" language:chinese -other:city"#
        )

        XCTAssertEqual(parsed.query.text, "Autumn book")
        XCTAssertTrue(parsed.query.titleOnly)
        XCTAssertTrue(parsed.query.matchPhrase)
        XCTAssertEqual(parsed.query.uploader, "archive team")
        XCTAssertEqual(parsed.query.rules, [
            .init(tag: .init(namespace: "language", name: "chinese")),
            .init(tag: .init(namespace: "other", name: "city"), match: .exclude)
        ])
        XCTAssertEqual(try parsed.query.expression(), #"title:"Autumn book" uploader:"archive team" language:"chinese"$ -other:"city"$"#)
    }

    func testQuotedTagWithSpacesAndEitherMatch() throws {
        let parsed = try SearchInputParser.parse(#"~other:"full color"$"#)

        XCTAssertEqual(parsed.query.text, "")
        XCTAssertEqual(parsed.query.rules, [.init(tag: .init(namespace: "other", name: "full color"), match: .any)])
        XCTAssertEqual(try parsed.query.expression(), #"~other:"full color"$"#)
    }

    func testPreservesExistingFilterFieldsAndReplacesDuplicateTag() throws {
        var base = SearchQuery()
        base.artist = "Mori"
        base.uploader = "archive"
        base.excludedCategories = [1, 32]
        base.minRating = 4
        base.minPages = 24
        base.maxPages = 300
        base.requireTorrent = true
        base.rules = [
            .init(tag: .init(namespace: "other", name: "city")),
            .init(tag: .init(namespace: "language", name: "english"), match: .any)
        ]

        let parsed = try SearchInputParser.parse("-other:city artist:sample", preserving: base)

        XCTAssertEqual(parsed.query.artist, "Mori")
        XCTAssertEqual(parsed.query.uploader, "archive")
        XCTAssertEqual(parsed.query.excludedCategories, [1, 32])
        XCTAssertEqual(parsed.query.minRating, 4)
        XCTAssertEqual(parsed.query.minPages, 24)
        XCTAssertEqual(parsed.query.maxPages, 300)
        XCTAssertTrue(parsed.query.requireTorrent)
        XCTAssertEqual(parsed.query.rules.count, 3)
        XCTAssertEqual(parsed.query.rules.first(where: { $0.id == "other:city" })?.match, .exclude)
        XCTAssertEqual(parsed.query.rules.first(where: { $0.id == "language:english" })?.match, .any)
        XCTAssertEqual(parsed.query.rules.first(where: { $0.id == "artist:sample" })?.match, .all)
    }

    func testMalformedInputThrowsWithoutMutatingDraftQuery() {
        var draft = SearchQuery()
        draft.text = #"artist:"#
        draft.minPages = 12
        draft.rules = [.init(tag: .init(namespace: "other", name: "landscape"))]
        let original = draft

        XCTAssertThrowsError(try SearchInputParser.parse(draft.text, preserving: draft))
        XCTAssertEqual(draft, original)
        XCTAssertThrowsError(try SearchInputParser.parse("title:forest mountain"))
        XCTAssertThrowsError(try SearchInputParser.parse(#""phrase" mountain"#))
    }
}

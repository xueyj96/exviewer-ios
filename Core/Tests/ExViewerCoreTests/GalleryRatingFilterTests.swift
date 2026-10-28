import XCTest
@testable import ExViewerCore

final class GalleryRatingFilterTests: XCTestCase {
    private func gallery(_ rating: Double?) -> Gallery {
        Gallery(ref: .init(site: .ex, gid: 1, token: "abcdef"), title: "Neutral", rating: rating)
    }

    func testThresholdUsesUnroundedAverageAndRejectsUnknownOrInvalidValues() {
        for rating in [2.8, 2.9, 2.999, -.infinity, .infinity, .nan, -1, 6] {
            XCTAssertFalse(GalleryRatingFilter.includes(gallery(rating), minimum: 3))
        }
        XCTAssertFalse(GalleryRatingFilter.includes(gallery(nil), minimum: 3))
        for rating in [3.0, 3.001, 4.75, 5] {
            XCTAssertTrue(GalleryRatingFilter.includes(gallery(rating), minimum: 3))
        }
        XCTAssertTrue(GalleryRatingFilter.includes(gallery(nil), minimum: nil))
    }

    func testOnlyEnabledValidMinimumIsReadFromOriginalSearchURL() throws {
        var query = SearchQuery(); query.minRating = 3
        let url = try query.url(site: .ex)
        XCTAssertEqual(GalleryRatingFilter.minimum(in: url), 3)
        for raw in ["https://exhentai.org/?f_srdd=3", "https://exhentai.org/?f_sr=off&f_srdd=3",
                    "https://exhentai.org/?f_sr=on&f_srdd=1", "https://exhentai.org/?f_sr=on&f_srdd=6"] {
            XCTAssertNil(GalleryRatingFilter.minimum(in: try XCTUnwrap(URL(string: raw))))
        }
    }

    func testListStarSpritesNeverBecomeNumericAverage() throws {
        let html = """
        <div class='itg'><table><tr><td><a href='/g/1/abcdef/'><div class='glink'>Neutral</div></a>
        <div class='ir' style='background-position:0px -21px'></div></td></tr></table></div>
        """
        let list = try EHParser.list(html, base: GallerySite.ex.baseURL)
        XCTAssertEqual(list.items.count, 1)
        XCTAssertNil(list.items.first?.rating)
    }

    func testMetadataUsesDecimalAverageAndClearsMissingOrInvalidAverage() throws {
        let original = gallery(5)
        for value in ["2.8", "2.9", "3.0", "3.001"] {
            let data = Data("{\"gmetadata\":[{\"gid\":1,\"rating\":\"\(value)\"}]}".utf8)
            XCTAssertEqual(try GalleryMetadata.merge(data, into: [original]).first?.rating, Double(value))
        }
        for fields in ["", ",\"rating\":\"NaN\"", ",\"rating\":\"Infinity\"", ",\"rating\":\"6\""] {
            let data = Data("{\"gmetadata\":[{\"gid\":1\(fields)}]}".utf8)
            XCTAssertNil(try GalleryMetadata.merge(data, into: [original]).first?.rating)
        }
    }
}

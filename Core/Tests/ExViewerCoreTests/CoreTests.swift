import XCTest
@testable import ExViewerCore

final class CoreTests: XCTestCase {
    func testCombinedSearchMatchesOfficialSyntax() throws {
        var query = SearchQuery()
        query.text = "art book"
        query.matchPhrase = true
        query.artist = "sample artist"
        query.uploader = "example_user"
        query.rules = [.init(tag: .init(namespace: "language", name: "english")), .init(tag: .init(namespace: "other", name: "full color"), match: .any), .init(tag: .init(namespace: "other", name: "sample"), match: .exclude)]
        XCTAssertEqual(try query.expression(), #""art book" artist:"sample artist"$ uploader:"example_user" language:"english"$ ~other:"full color"$ -other:"sample"$"#)
        query.excludedCategories = [1, 32]
        query.minRating = 4; query.minPages = 20; query.maxPages = 100; query.requireTorrent = true
        let url = try query.url(site: .ex)
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "exhentai.org")
        XCTAssertEqual(fields["f_cats"], "33")
        XCTAssertEqual(fields["f_srdd"], "4")
        XCTAssertEqual(fields["f_spf"], "20")
        XCTAssertEqual(fields["f_storr"], "on")
    }
    func testQueryRejectsServerLimitsAndInjection() throws {
        var query = SearchQuery()
        query.rules = (0..<6).map { .init(tag: .init(namespace: "artist", name: "name\($0)")) }
        XCTAssertThrowsError(try query.expression())
        query.rules = []; query.text = "\" ~artist:test"
        XCTAssertThrowsError(try query.expression())
        query.text = String(repeating: "x", count: 201)
        XCTAssertThrowsError(try query.expression())
        query.text = ""; query.minPages = 100; query.maxPages = 20
        XCTAssertThrowsError(try query.url(site: .ex))
        query.minPages = nil; query.maxPages = nil
        query.excludedCategories = Set(GalleryCategory.all.map(\.id))
        XCTAssertThrowsError(try query.url(site: .eh))
    }
    func testSavedCombinationRoundTripIncludesEveryFilter() throws {
        var query = SearchQuery(); query.text = "Landscape"; query.artist = "Example"; query.uploader = "archive"
        query.titleOnly = true; query.minRating = 4; query.minPages = 30; query.maxPages = 500
        query.rules = [.init(tag: .init(namespace: "language", name: "japanese"), match: .exclude)]
        query.excludedCategories = [1, 32]; query.requireTorrent = true
        let saved = SavedSearch(name: "画集组合", site: .ex, query: query)
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(SavedSearch.self, from: data), saved)
    }
    func testExactTagBlockingAndUnknownCoverage() {
        let blocked: Set<String> = ["artist:sample"]
        XCTAssertEqual(TagFilter.decision(tags: [.init(namespace: "artist", name: "sample")], blocked: blocked, complete: false), .blocked)
        XCTAssertEqual(TagFilter.decision(tags: [.init(namespace: "artist", name: "sample two")], blocked: blocked, complete: true), .visible)
        XCTAssertEqual(TagFilter.decision(tags: [.init(namespace: "group", name: "sample")], blocked: blocked, complete: true), .visible)
        XCTAssertEqual(TagFilter.decision(tags: [], blocked: blocked, complete: false), .unknown)
    }
    func testListParserDeduplicatesAndUsesActualContinuation() throws {
        let html = """
        <div class="itg"><table><tr><td><img data-src="https://ehgt.org/test.webp"></td><td>
        <a href="/g/42/abcdef/"><div class="glink">Neutral art book</div></a><div class="cn">Non-H</div>
        <div class="gt" title="language:english">english</div><div>32 pages</div><a href="?f_search=uploader:example">example</a>
        </td></tr><tr><td><a href="/g/42/abcdef/"><div class="glink">Duplicate</div></a></td></tr></table></div>
        <a id="dnext" href="/?next=41&amp;f_search=test">Next &gt;</a>
        """
        let list = try EHParser.list(html, base: GallerySite.ex.baseURL)
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.items.first?.pages, 32)
        XCTAssertEqual(list.items.first?.tags.first?.id, "language:english")
        XCTAssertEqual(URLComponents(url: list.next!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "41")
    }
    func testThumbnailLayoutAndMalformedGalleryURL() throws {
        let html = """
        <div class="itg"><div class="gl1t"><a href="https://exhentai.org/g/45/aa123/"><span class="glink">A &amp; B</span></a></div>
        <div class="gl1t"><a href="https://exhentai.org.evil.invalid/g/46/aa123/"><span class="glink">Wrong host</span></a></div></div>
        """
        let list = try EHParser.list(html, base: GallerySite.ex.baseURL)
        XCTAssertEqual(list.items.map(\.title), ["A & B"])
    }
    func testErrorsAreNotEmptyResults() throws {
        XCTAssertTrue(try EHParser.list("<p>No hits found</p>", base: GallerySite.ex.baseURL).items.isEmpty)
        XCTAssertThrowsError(try EHParser.list("<h1>Unexpected response</h1>", base: GallerySite.ex.baseURL)) { XCTAssertEqual($0 as? ViewerError, .layoutChanged) }
        XCTAssertThrowsError(try EHParser.list("<title>Just a moment...</title>", base: GallerySite.ex.baseURL)) { XCTAssertEqual($0 as? ViewerError, .challenge) }
        XCTAssertThrowsError(try EHParser.image("<p>You have exceeded your image viewing limits.</p>", base: GallerySite.ex.baseURL)) { XCTAssertEqual($0 as? ViewerError, .imageLimit) }
    }
    func testImageSourceIsOneFilePerPageAndRejectsUntrustedMedia() throws {
        let base = URL(string: "https://exhentai.org/s/abc/42-1")!
        let image = try EHParser.image("<div id='i3'><img id='img' src='https://ehgt.org/animation.gif'></div>", base: base)
        XCTAssertEqual(image.url.pathExtension, "gif")
        XCTAssertThrowsError(try EHParser.image("<img id='img' src='https://example.invalid/track.gif'>", base: base))
    }
    func testHathMediaAllowsOnlyHTTPSApprovedPortRange() {
        for value in [
            "https://node.hath.network/image.jpg",
            "https://node.hath.network:443/image.jpg",
            "https://node.hath.network:1024/image.jpg",
            "https://edge.node.hath.network:65534/image.jpg"
        ] { XCTAssertTrue(URLPolicy.media(URL(string: value)!), value) }

        for value in [
            "http://node.hath.network:1024/image.jpg",
            "https://node.hath.network:1023/image.jpg",
            "https://node.hath.network:65535/image.jpg",
            "https://hath.network:1024/image.jpg",
            "https://node.hath.network.evil.invalid:1024/image.jpg",
            "https://nodehath.network:1024/image.jpg",
            "https://user@node.hath.network:1024/image.jpg",
            "https://127.0.0.1:1024/image.jpg",
            "https://localhost:1024/image.jpg",
            "https://ehgt.org:1024/image.jpg",
            "https://exhentai.org:1024/image.jpg"
        ] { XCTAssertFalse(URLPolicy.media(URL(string: value)!), value) }

        XCTAssertTrue(URLPolicy.account(URL(string: "https://exhentai.org/")!))
        XCTAssertFalse(URLPolicy.account(URL(string: "https://exhentai.org:1024/")!))
    }
    func testImageParserAcceptsHathMediaOnApprovedNon443Port() throws {
        let base = URL(string: "https://exhentai.org/s/neutral/42-1")!
        let html = "<div id='i3'><img id='img' src='https://node.hath.network:1024/neutral/page.jpg'></div>"
        let image = try EHParser.image(html, base: base)
        XCTAssertEqual(image.url.host, "node.hath.network")
        XCTAssertEqual(image.url.port, 1024)
        XCTAssertEqual(image.url.path, "/neutral/page.jpg")
    }
    func testGalleryPreviewPaginationAndPageIdentity() throws {
        let ref = GalleryRef(site: .ex, gid: 42, token: "abc123")
        let html = """
        <h1 id='gn'>Neutral test</h1><div id='taglist'><table><tr><td class='tc'>language:</td><td><div class='gt'><a>english</a></div></td></tr></table></div>
        <div id='gdt'><a href='/s/abcd/42-41'><div title='Page 41: frame.gif'></div></a><a href='/s/abcd/42-41'>duplicate</a></div>
        <table class='ptt'><tr><td><a href='?p=2'>&gt;</a></td></tr></table>
        """
        let detail = try EHParser.detail(html, reference: ref, pageURL: URL(string: ref.url.absoluteString + "?p=1"))
        XCTAssertEqual(detail.pages.map(\.index), [41])
        XCTAssertEqual(detail.gallery.tags.first?.id, "language:english")
        XCTAssertEqual(detail.next?.query, "p=2")
    }
    func testQuotaUnknownIsNotZero() throws {
        let quota = try EHParser.quota("<p>You are currently at 1,200 towards a limit of 10,000. Restores 4 points per minute.</p>")
        XCTAssertEqual(quota.remaining, 8800)
        XCTAssertEqual(quota.recoveryPerMinute, 4)
        XCTAssertNil(AccountQuota().remaining)
        XCTAssertThrowsError(try EHParser.quota("<h1>Account</h1>"))
    }
    func testCredentialAndContinuationBoundaries() {
        XCTAssertTrue(URLPolicy.account(URL(string: "https://forums.e-hentai.org/index.php")!))
        for value in ["http://e-hentai.org/", "https://e-hentai.org.evil.invalid/", "https://a:b@exhentai.org/", "https://exhentai.org:8443/"] { XCTAssertFalse(URLPolicy.account(URL(string: value)!)) }
        XCTAssertFalse(URLPolicy.media(URL(string: "https://127.0.0.1/image.gif")!))
        XCTAssertFalse(URLPolicy.continuation(URL(string: "https://exhentai.org/home.php?next=1")!, from: GallerySite.ex.baseURL))
        XCTAssertNil(GalleryRef(url: URL(string: "https://exhentai.org/g/1/abc/extra/")!))
    }
    func testKeywordIntersectionAndOptionalPhrase() throws {
        var query = SearchQuery(); query.text = "art book"
        XCTAssertEqual(try query.expression(), #""art" "book""#)
        query.matchPhrase = true
        XCTAssertEqual(try query.expression(), #""art book""#)
        query.matchPhrase = false; query.text = "one two three four five six"
        XCTAssertThrowsError(try query.expression())
    }
    func testMetadataOnlyMarksReturnedTagsComplete() throws {
        let a = Gallery(ref: .init(site: .ex, gid: 1, token: "aaaa"), title: "Old")
        let b = Gallery(ref: .init(site: .ex, gid: 2, token: "bbbb"), title: "Keep")
        let json = #"{"gmetadata":[{"gid":1,"title":"New","filecount":"10","tags":["language:english"],"thumb":"https://example.invalid/tracker.png"},{"gid":2,"error":"Unavailable"}]}"#
        let merged = try GalleryMetadata.merge(Data(json.utf8), into: [a, b])
        XCTAssertTrue(merged[0].tagsComplete); XCTAssertEqual(merged[0].title, "New"); XCTAssertEqual(merged[0].pages, 10); XCTAssertNil(merged[0].cover)
        XCTAssertFalse(merged[1].tagsComplete); XCTAssertEqual(merged[1].title, "Keep"); XCTAssertEqual(merged[1].ref, b.ref)
        XCTAssertThrowsError(try GalleryMetadata.request(Array(repeating: a, count: 26)))
    }
    func testReaderNeverMixesAnotherGalleryPages() throws {
        let ref = GalleryRef(site: .ex, gid: 42, token: "abc123")
        let html = "<h1 id='gn'>Neutral test</h1><div id='gdt'><a href='/s/abc/99-1'>Wrong gallery</a><a href='/s/abc/42-2'>Correct gallery</a></div>"
        XCTAssertEqual(try EHParser.detail(html, reference: ref).pages.map(\.index), [2])
        XCTAssertThrowsError(try EHParser.detail(html.replacingOccurrences(of: "/42-2", with: "/99-2"), reference: ref))
    }
    func testVerificationBootstrapFrameCompatibility() {
        XCTAssertTrue(SiteWebNavigation.allows(URL(string: "about:srcdoc")!, isMainFrame: false))
        XCTAssertTrue(SiteWebNavigation.allows(URL(string: "about:blank")!, isMainFrame: false))
        XCTAssertTrue(SiteWebNavigation.allows(URL(string: "https://challenges.cloudflare.com/test")!, isMainFrame: false))
        XCTAssertFalse(SiteWebNavigation.allows(URL(string: "about:srcdoc")!, isMainFrame: true))
        XCTAssertFalse(SiteWebNavigation.allows(URL(string: "https://challenges.cloudflare.com/test")!, isMainFrame: true))
    }
    func testVerificationFramesDoNotBroadenMainPageOrCredentialOrigins() {
        for string in ["https://challenges.cloudflare.com.evil.invalid/", "https://user:pass@challenges.cloudflare.com/", "http://challenges.cloudflare.com/", "https://challenges.cloudflare.com:8443/"] {
            XCTAssertFalse(SiteWebNavigation.allows(URL(string: string)!, isMainFrame: false))
        }
        XCTAssertTrue(SiteWebNavigation.allows(GallerySite.ex.baseURL, isMainFrame: true))
        XCTAssertFalse(URLPolicy.account(URL(string: "https://challenges.cloudflare.com/")!))
    }
    func testKeychainFailureIsDistinctFromFilesystemSpaceFailure() {
        let error = ViewerError.keychain(.update, -34018)
        XCTAssertTrue(error.localizedDescription.contains("-34018"))
        XCTAssertTrue(error.localizedDescription.contains("Keychain"))
        XCTAssertFalse(error.localizedDescription.contains("可用空间"))
        XCTAssertNotEqual(error, .storage)
    }
}

import XCTest
@testable import ExViewerCore

final class AccountPageTests: XCTestCase {
    func testQuotaParserReadsThousandsSeparatorsAndRecovery() throws {
        let html = """
        <html><body><div class="homebox"><h2>Image Limits</h2>
        <p>You are currently at <strong>1,234</strong>.</p><p>Account limit <strong>50,000</strong>.</p>
        <p>Reset cost <strong>2,500</strong>.</p></div><p>Image limits regenerate at 4.5 points per minute.</p></body></html>
        """
        let quota = try EHParser.quota(html)
        XCTAssertEqual(quota.used, 1234)
        XCTAssertEqual(quota.limit, 50000)
        XCTAssertEqual(quota.remaining, 48766)
        XCTAssertEqual(quota.recoveryPerMinute, 4.5)
        XCTAssertEqual(quota.tracking, .account)
        XCTAssertEqual(quota.resetCost, 2500)
    }

    func testQuotaParserSupportsExplicitLegacySentenceWithoutHomebox() throws {
        let quota = try EHParser.quota("<p>You are currently at 1,200 towards a limit of 10,000. Restores 4 points per minute.</p>")
        XCTAssertEqual(quota.used, 1200)
        XCTAssertEqual(quota.limit, 10000)
        XCTAssertEqual(quota.recoveryPerMinute, 4)
        XCTAssertEqual(quota.tracking, .account)
        XCTAssertNil(quota.resetCost)
        XCTAssertThrowsError(try EHParser.quota("<p>There are 1200 things and 10000 more things.</p>"))
    }

    func testQuotaParserKeepsIPQuotaUnknownAndReadsResetCost() throws {
        let html = "<div class='homebox'><h2>Image Limits</h2><p>Reset cost <strong>0</strong></p></div>"
        let quota = try EHParser.quota(html)
        XCTAssertNil(quota.used)
        XCTAssertNil(quota.limit)
        XCTAssertNil(quota.remaining)
        XCTAssertEqual(quota.tracking, .ip)
        XCTAssertEqual(quota.resetCost, 0)
    }

    func testQuotaParserRecognizesRestrictedIPText() throws {
        let html = """
        <div class="homebox"><h2>Image Limits</h2><p>Reset cost <strong>12</strong></p></div>
        <p>Due to a high request rate, your IP is currently restricted to lower-resolution images.</p>
        """
        let quota = try EHParser.quota(html)
        XCTAssertEqual(quota.tracking, .restrictedIP)
        XCTAssertNil(quota.used)
        XCTAssertNil(quota.limit)
        XCTAssertEqual(quota.resetCost, 12)
    }

    func testQuotaParserAllowsNeighboringImageLimitsHeading() throws {
        let html = """
        <section><h2>Image Limits</h2><div class="homebox">
        <p>Used <strong>12</strong></p><p>Limit <strong>300</strong></p><p>Reset <strong>0</strong></p>
        </div></section>
        """
        XCTAssertEqual(try EHParser.quota(html).used, 12)
    }

    func testQuotaParserRejectsLoginAndUnrecognizedPages() {
        let login = "<html><body><p>This page requires you to log on.</p></body></html>"
        XCTAssertThrowsError(try EHParser.quota(login)) { XCTAssertEqual($0 as? ViewerError, .authentication) }
        XCTAssertThrowsError(try EHParser.quota("<html><body><p>Account settings</p><p>Points 42</p></body></html>")) {
            XCTAssertEqual($0 as? ViewerError, .layoutChanged)
        }
        XCTAssertThrowsError(try EHParser.quota("<div class='homebox'><h2>Other settings</h2><p><strong>1</strong></p><p><strong>2</strong></p><p><strong>3</strong></p></div>")) {
            XCTAssertEqual($0 as? ViewerError, .layoutChanged)
        }
    }

    func testAccountPageReadingOnlyReturnsVisibleMatchingLines() throws {
        let home = """
        <html><body><div class="homebox"><h2>Image Limits</h2>
        <p>You are currently at <strong>10</strong></p><p>Limit <strong>900</strong></p><p>Cost <strong>2</strong></p>
        </div>
        <p>You are currently using account-based limits.</p></body></html>
        """
        let donation = """
        <html><body><h2>Donations</h2><p>Donation status: sample status only.</p>
        <p>Payment methods are listed on this page.</p><p>Unrelated profile text.</p></body></html>
        """
        let perks = "<html><body><h2>Hath Perks</h2><p>Sample perk description, cost shown by the site.</p></body></html>"
        let result = try AccountPages.read(home: home, donation: donation, perks: perks)
        XCTAssertEqual(result.quotaTrackingMode, "账号额度")
        XCTAssertTrue(result.donationStatus.contains { $0.contains("Donation status") })
        XCTAssertTrue(result.paymentInformation.contains { $0.contains("Payment methods") })
        XCTAssertTrue(result.perksInformation.contains { $0.contains("Sample perk") })
        XCTAssertFalse(result.paymentInformation.contains { $0.contains("Unrelated profile") })
    }
}

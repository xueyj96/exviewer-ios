import Foundation
import SwiftSoup

/// Read-only facts extracted from the public account pages. Empty fields mean
/// the page did not provide a recognizable value; callers must render that as unknown.
public struct AccountPageReading: Equatable, Sendable {
    public var quotaTrackingMode: String?
    public var quotaResetCost: Int?
    public var donationStatus: [String]
    public var paymentInformation: [String]
    public var perksInformation: [String]

    public init(quotaTrackingMode: String? = nil, quotaResetCost: Int? = nil, donationStatus: [String] = [], paymentInformation: [String] = [], perksInformation: [String] = []) {
        self.quotaTrackingMode = quotaTrackingMode; self.quotaResetCost = quotaResetCost
        self.donationStatus = donationStatus
        self.paymentInformation = paymentInformation
        self.perksInformation = perksInformation
    }
}

/// Conservative parsers for E-Hentai's visible account pages. Values are
/// included only when they appear in page text; no price, address, or benefit is synthesized.
public enum AccountPages {
    public static func read(home: String?, donation: String?, perks: String?) throws -> AccountPageReading {
        var result = AccountPageReading()
        if let home, let value = try? readHome(home) { result = result.merging(value) }
        if let donation, let value = try? readDonation(donation) { result = result.merging(value) }
        if let perks, let value = try? readPerks(perks) { result = result.merging(value) }
        guard home != nil || donation != nil || perks != nil else { throw ViewerError.layoutChanged }
        return result
    }

    public static func readHome(_ html: String) throws -> AccountPageReading {
        let quota = try EHParser.quota(html)
        let mode: String?
        switch quota.tracking {
        case .account: mode = "账号额度"
        case .ip: mode = "IP 额度"
        case .restrictedIP: mode = "IP 高分辨率受限"
        case nil: mode = nil
        }
        let lines = try selectedLines(html, keywords: ["donation", "donated", "donator", "adopt-a-server"], limit: 8)
        return AccountPageReading(quotaTrackingMode: mode, quotaResetCost: quota.resetCost, donationStatus: lines)
    }

    public static func readDonation(_ html: String) throws -> AccountPageReading {
        try validatePage(html)
        return AccountPageReading(
            donationStatus: try selectedLines(html, keywords: ["donation", "donated", "donator", "adopt-a-server"], limit: 12),
            paymentInformation: try selectedLines(html, keywords: ["bitcoin", "payment", "wallet", "address", "paypal", "donate", "donation"], limit: 16)
        )
    }

    public static func readPerks(_ html: String) throws -> AccountPageReading {
        try validatePage(html)
        return AccountPageReading(perksInformation: try selectedLines(html, keywords: ["hath", "perk", "cost", "price"], limit: 20))
    }

    private static func validatePage(_ html: String) throws {
        try EHParser.check(html)
        let doc = try SwiftSoup.parse(html)
        let text = try doc.text().lowercased()
        if (try doc.select("form[action*=login], #loginform, .sadbox").first() != nil)
            || text.contains("please log in") || text.contains("you must be logged in") {
            throw ViewerError.authentication
        }
        guard try doc.body()?.text().isEmpty == false else { throw ViewerError.layoutChanged }
    }

    private static func selectedLines(_ html: String, keywords: [String], limit: Int) throws -> [String] {
        let doc = try SwiftSoup.parse(html)
        let nodes = try doc.select("h1, h2, h3, h4, p, li, .homebox, .homebox div")
        var result: [String] = []
        for node in nodes {
            let line = try node.text().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.count <= 420,
                  keywords.contains(where: { line.localizedCaseInsensitiveContains($0) }),
                  !result.contains(line) else { continue }
            result.append(line)
            if result.count >= limit { break }
        }
        return result
    }

    private static func unique(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }
}

public extension AccountPageReading {
    func merging(_ other: AccountPageReading) -> AccountPageReading {
        AccountPageReading(
            quotaTrackingMode: other.quotaTrackingMode ?? quotaTrackingMode,
            quotaResetCost: other.quotaResetCost ?? quotaResetCost,
            donationStatus: Self.unique(donationStatus + other.donationStatus),
            paymentInformation: Self.unique(paymentInformation + other.paymentInformation),
            perksInformation: Self.unique(perksInformation + other.perksInformation)
        )
    }
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); return values.filter { seen.insert($0).inserted }
    }
}

import Foundation
import SwiftSoup

public enum EHParser {
    public static func check(_ html: String) throws {
        let value = html.lowercased()
        if value.contains("cf-chl-") || value.contains("just a moment...") || value.contains("checking your browser") { throw ViewerError.challenge }
        if value.contains("exceeded your image") || value.contains("image viewing limits") && value.contains("exceeded") || value.contains("509.gif") { throw ViewerError.imageLimit }
        if value.contains("your ip address has been temporarily banned") { throw ViewerError.restricted }
        if value.contains("sadpanda") || value.contains("sad panda") { throw ViewerError.authentication }
        if value.contains("this page requires you to log on") { throw ViewerError.authentication }
    }
    private static func text(_ element: Element?, _ selector: String) -> String { (try? element?.select(selector).first()?.text()) ?? "" }
    private static func url(_ raw: String?, base: URL) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }
    private static func attr(_ element: Element?, _ name: String) -> String { (try? element?.attr(name)) ?? "" }
    private static func ancestor(_ element: Element, anchor: Bool) -> Element? {
        var current: Element? = element
        while let node = current {
            if anchor, node.tagName() == "a", node.hasAttr("href") { return node }
            if !anchor, node.tagName() == "tr" || ((try? node.hasClass("gl1t")) ?? false) { return node }
            current = node.parent()
        }
        return nil
    }
    private static func match(_ string: String, _ pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)), group < m.numberOfRanges,
              let range = Range(m.range(at: group), in: string) else { return nil }
        return String(string[range])
    }
    private static func tags(_ node: Element) throws -> [GalleryTag] {
        var result: [GalleryTag] = []
        for element in try node.select(".gt[title], .gtl[title], .gtw[title]") {
            if let tag = GalleryTag(try element.attr("title")), !result.contains(tag) { result.append(tag) }
        }
        return result
    }
    private static func next(_ document: Document, base: URL, gallery: Bool = false) throws -> URL? {
        let links = try document.select(gallery ? ".ptt a, .ptb a" : "#dnext, a[rel=next], .searchnav a")
        for link in links {
            let label = try link.text()
            let id = try link.id()
            let rel = try link.attr("rel")
            if id == "dnext" || rel == "next" || label == ">" || label == "Next >" || label == "Next" {
                if let result = url(try link.attr("href"), base: base), URLPolicy.continuation(result, from: base), result != base { return result }
            }
        }
        return nil
    }
    public static func list(_ html: String, base: URL) throws -> GalleryList {
        try check(html)
        let document = try SwiftSoup.parse(html, base.absoluteString)
        var items: [Gallery] = []
        var seen = Set<String>()
        for title in try document.select(".itg .glink, .gl1t .glink") {
            guard let anchor = ancestor(title, anchor: true), let link = url(try anchor.attr("href"), base: base), let ref = GalleryRef(url: link), seen.insert(ref.id).inserted else { continue }
            let row = ancestor(title, anchor: false) ?? anchor
            let image = try row.select("img:not([alt=T])").first()
            let raw = attr(image, "data-src").isEmpty ? attr(image, "src") : attr(image, "data-src")
            let cover = url(raw, base: base).flatMap { URLPolicy.media($0) ? $0 : nil }
            let rowText = try row.text()
            let pages = match(rowText, #"(\d+)\s+pages?"#).flatMap(Int.init)
            let ratingStyle = attr(try row.select(".ir").first(), "style")
            let x = match(ratingStyle, #"(-?\d+)px\s+(-?\d+)px"#).flatMap(Double.init)
            let rating = x.map { max(0, min(5, 5 - abs($0) / 16)) }
            items.append(Gallery(ref: ref, title: try title.text(), category: text(row, ".cn, .cs, .ct"), uploader: text(row, "a[href*=uploader]"), pages: pages, rating: rating, tags: try tags(row), cover: cover))
        }
        if items.isEmpty {
            let body = try document.text().lowercased()
            let knownEmpty = body.contains("no hits found") || body.contains("no galleries found") || body.contains("you do not have any favorites") || body.contains("no favorites found")
            guard knownEmpty else { throw ViewerError.layoutChanged }
        }
        var categories: [String: String] = [:]
        for node in try document.select(".fp a[href], .nosel a[href], select[name=favcat] option") {
            let value = attr(node, "value")
            let href = attr(node, "href")
            if let cat = URLComponents(string: href)?.queryItems?.first(where: { $0.name == "favcat" })?.value ?? (value.isEmpty ? nil : value), cat == "all" || Int(cat).map({ (0...9).contains($0) }) == true { categories[cat] = try node.text() }
        }
        return GalleryList(items: items, next: try next(document, base: base), favoriteCategories: categories)
    }
    public static func detail(_ html: String, reference: GalleryRef, pageURL: URL? = nil) throws -> GalleryDetail {
        try check(html)
        let base = pageURL ?? reference.url
        let doc = try SwiftSoup.parse(html, base.absoluteString)
        let title = text(doc, "#gn")
        guard !title.isEmpty, try doc.select("#gdt").first() != nil else { throw ViewerError.layoutChanged }
        var gallery = Gallery(ref: reference, title: title, category: text(doc, "#gdc"), uploader: text(doc, "#gdn"))
        gallery.japaneseTitle = text(doc, "#gj")
        gallery.tagsComplete = true
        gallery.rating = match(text(doc, "#rating_label"), #"([\d.]+)"#).flatMap(Double.init)
        for row in try doc.select("#gdd tr") {
            if text(row, ".gdt1").contains("Length") { gallery.pages = match(text(row, ".gdt2"), #"(\d+)"#).flatMap(Int.init) }
        }
        for row in try doc.select("#taglist tr") {
            let namespace = text(row, ".tc").trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            guard !namespace.isEmpty else { continue }
            for node in try row.select(".gt a, .gtl a, .gtw a") {
                let name = try node.text().components(separatedBy: " | ")[0]
                let tag = GalleryTag(namespace: namespace, name: name)
                if !tag.name.isEmpty && !gallery.tags.contains(tag) { gallery.tags.append(tag) }
            }
        }
        if let node = try doc.select("#gd1 div[style]").first(), let raw = match(attr(node, "style"), #"url\(['"]?([^)'"\s]+)"#), let cover = url(raw, base: reference.url), URLPolicy.media(cover) { gallery.cover = cover }
        var pages: [GalleryPage] = []
        var indexes = Set<Int>()
        for link in try doc.select("#gdt a[href]") {
            guard let pageURL = url(try link.attr("href"), base: reference.url), URLPolicy.account(pageURL), pageURL.host == reference.site.host,
                  match(pageURL.path, #"/s/[^/]+/(\d+)-\d+"#).flatMap(Int64.init) == reference.gid,
                  let index = match(pageURL.path, #"/s/[^/]+/\d+-(\d+)"#).flatMap(Int.init), index > 0, indexes.insert(index).inserted else { continue }
            pages.append(GalleryPage(index: index, url: pageURL))
        }
        guard !pages.isEmpty else { throw ViewerError.layoutChanged }
        var archive: URL?
        for node in try doc.select("a[onclick]") where (try node.text()).contains("Archive Download") {
            if let raw = match(try node.attr("onclick"), #"popUp\('([^']+)'"#), let candidate = url(raw, base: reference.url), URLPolicy.account(candidate) { archive = candidate }
        }
        let favoriteName = text(doc, "#fav").trimmingCharacters(in: .whitespacesAndNewlines)
        return GalleryDetail(gallery: gallery, pages: pages.sorted { $0.index < $1.index }, next: try next(doc, base: base, gallery: true), archive: archive, favoriteName: favoriteName.isEmpty || favoriteName == "Add to Favorites" ? nil : favoriteName)
    }
    public static func image(_ html: String, base: URL) throws -> ImageSource {
        try check(html)
        let doc = try SwiftSoup.parse(html, base.absoluteString)
        guard let node = try doc.select("#img, #i3 img").first(), let source = url(try node.attr("src"), base: base), URLPolicy.media(source) else { throw ViewerError.layoutChanged }
        var original: URL?
        if let link = try doc.select("#i7 a[href]").first(), let candidate = url(try link.attr("href"), base: base), URLPolicy.account(candidate) { original = candidate }
        return ImageSource(url: source, originalPage: original)
    }
    public static func quota(_ html: String) throws -> AccountQuota {
        try check(html)
        let doc = try SwiftSoup.parse(html)
        let content = try doc.text().replacingOccurrences(of: "\u{00a0}", with: " ").replacingOccurrences(of: "\n", with: " ")
        let normalized = content.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let lower = normalized.lowercased()
        // home.php can return a login or account error page with HTTP 200. Do not
        // mistake those pages, or a generic page containing a number, for quota.
        if (try doc.select("form[action*=login], #loginform, .sadbox").first() != nil)
            || lower.contains("please log in") || lower.contains("you must be logged in")
            || lower.contains("this page requires you to log on") {
            throw ViewerError.authentication
        }
        let canonicalText = #"you are currently at\s+([\d,]+)\s+towards\s+(?:a\s+|an\s+|your\s+)?(?:account\s+)?limit\s+of\s+([\d,]+)(?:[.;]|$)"#
        if let usedText = match(normalized, canonicalText, group: 1),
           let limitText = match(normalized, canonicalText, group: 2),
           let used = Int(usedText.replacingOccurrences(of: ",", with: "")),
           let limit = Int(limitText.replacingOccurrences(of: ",", with: "")), limit > 0 {
            let recovery = match(normalized, #"([\d.]+)\s+(?:points?|images?|hits?)\s+per minute"#)
            return AccountQuota(used: used, limit: limit, recoveryPerMinute: recovery.flatMap(Double.init), tracking: .account)
        }
        guard let homebox = try doc.select("div.homebox").first() else { throw ViewerError.layoutChanged }
        let values = try homebox.select("p > strong").map { try $0.text().replacingOccurrences(of: ",", with: "") }
        let sectionText = try homebox.text().lowercased()
        let parent = homebox.parent()
        var adjacentText = [
            try homebox.previousElementSibling()?.text(),
            try homebox.nextElementSibling()?.text()
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        if let parent, parent.tagName() != "body", parent.tagName() != "html" {
            adjacentText += " " + (try parent.text()).lowercased()
        }
        let isImageLimitsSection = (sectionText + " " + adjacentText).contains("image limits")
        let isIPStatus = lower.contains("currently using ip-based limits")
            || lower.contains("due to a high request rate, your ip is currently restricted to lower-resolution images.")
        func number(_ index: Int) -> Int? { values.indices.contains(index) ? Int(values[index]) : nil }
        if isImageLimitsSection, values.count == 3, let used = number(0), let limit = number(1), let resetCost = number(2), used >= 0, limit > 0, resetCost >= 0 {
            let recovery = match(normalized, #"([\d.]+)\s+(?:points?|images?|hits?)\s+per minute"#)
                ?? match(normalized, #"regen(?:eration)?\s+rate\s*(?:is|:)?\s*([\d.]+)\s*(?:points?|images?|hits?)?\s*per minute"#)
            return AccountQuota(used: used, limit: limit, recoveryPerMinute: recovery.flatMap(Double.init), tracking: .account, resetCost: resetCost)
        }
        if (isImageLimitsSection || isIPStatus), values.count == 1, let resetCost = number(0), resetCost >= 0 {
            let tracking: AccountQuota.Tracking = lower.contains("due to a high request rate, your ip is currently restricted to lower-resolution images.") ? .restrictedIP : .ip
            return AccountQuota(tracking: tracking, resetCost: resetCost)
        }
        throw ViewerError.layoutChanged
    }
}

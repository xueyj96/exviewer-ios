import Foundation

public enum SiteWebNavigation {
    public static func allows(_ url: URL, isMainFrame: Bool?) -> Bool {
        if URLPolicy.account(url) { return true }
        if url.absoluteString == "about:blank" { return true }
        guard isMainFrame == false else { return false }
        if url.absoluteString == "about:srcdoc" { return true }
        return url.scheme == "https" && url.host?.lowercased() == "challenges.cloudflare.com"
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
}

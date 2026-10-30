import Foundation

public enum GallerySite: String, Codable, CaseIterable, Identifiable, Sendable {
    case eh, ex
    public var id: String { rawValue }
    public var name: String { self == .ex ? "ExHentai" : "E-Hentai" }
    public var host: String { self == .ex ? "exhentai.org" : "e-hentai.org" }
    public var baseURL: URL { URL(string: "https://" + host + "/")! }
}

public struct GalleryTag: Codable, Hashable, Identifiable, Sendable {
    public var namespace: String
    public var name: String
    public var id: String { (namespace + ":" + name).lowercased() }
    public var label: String { namespace + ":" + name }
    public init(namespace: String, name: String) {
        self.namespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public init?(_ text: String) {
        let pair = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
        self.init(namespace: pair[0], name: pair[1])
    }
}

public struct GalleryRef: Codable, Hashable, Identifiable, Sendable {
    public var site: GallerySite
    public var gid: Int64
    public var token: String
    public var id: String { "\(site.rawValue):\(gid)" }
    public var url: URL { site.baseURL.appendingPathComponent("g/\(gid)/\(token)/") }
    public init(site: GallerySite, gid: Int64, token: String) { self.site = site; self.gid = gid; self.token = token }
    public init?(url: URL) {
        guard let site = GallerySite.allCases.first(where: { $0.host == url.host?.lowercased() }),
              url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 3, parts[0] == "g", let gid = Int64(parts[1]), gid > 0,
              !parts[2].isEmpty, parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        self.init(site: site, gid: gid, token: parts[2])
    }
}

public struct Gallery: Codable, Hashable, Identifiable, Sendable {
    public var ref: GalleryRef
    public var title: String
    public var japaneseTitle: String = ""
    public var category: String = ""
    public var uploader: String = ""
    public var pages: Int? = nil
    public var rating: Double? = nil
    public var tags: [GalleryTag] = []
    public var tagsComplete: Bool = false
    public var cover: URL? = nil
    public var id: String { ref.id }
    public init(ref: GalleryRef, title: String, category: String = "", uploader: String = "", pages: Int? = nil, rating: Double? = nil, tags: [GalleryTag] = [], cover: URL? = nil) {
        self.ref = ref; self.title = title; self.category = category; self.uploader = uploader
        self.pages = pages; self.rating = rating; self.tags = tags; self.cover = cover
    }
    public var stored: Gallery { var value = self; value.cover = nil; return value }
}

public struct GalleryList: Sendable {
    public var items: [Gallery]
    public var next: URL?
    public var favoriteCategories: [String: String] = [:]
}

public struct GalleryPage: Codable, Hashable, Identifiable, Sendable {
    public var index: Int
    public var url: URL
    public var id: Int { index }
    public init(index: Int, url: URL) { self.index = index; self.url = url }
}

public struct GalleryDetail: Sendable {
    public var gallery: Gallery
    public var pages: [GalleryPage]
    public var next: URL?
    public var archive: URL?
    public var favoriteName: String?
    public var favoriteStateKnown: Bool
    public var favoriteState: GalleryFavoriteState {
        guard favoriteStateKnown else { return .unknown }
        return favoriteName.map { .favorited($0) } ?? .notFavorited
    }
    public init(gallery: Gallery, pages: [GalleryPage], next: URL?, archive: URL?, favoriteName: String?, favoriteStateKnown: Bool = true) {
        self.gallery = gallery; self.pages = pages; self.next = next; self.archive = archive; self.favoriteName = favoriteName
        self.favoriteStateKnown = favoriteStateKnown
    }
}

public struct ImageSource: Sendable {
    public var url: URL
    public var originalPage: URL?
}

public struct AccountQuota: Codable, Equatable, Sendable {
    public enum Tracking: String, Codable, Equatable, Sendable { case account, ip, restrictedIP }
    public var used: Int?
    public var limit: Int?
    public var recoveryPerMinute: Double?
    public var tracking: Tracking?
    public var resetCost: Int?
    public init(used: Int? = nil, limit: Int? = nil, recoveryPerMinute: Double? = nil, tracking: Tracking? = nil, resetCost: Int? = nil) {
        self.used = used; self.limit = limit; self.recoveryPerMinute = recoveryPerMinute
        self.tracking = tracking; self.resetCost = resetCost
    }
    public var remaining: Int? { guard let used, let limit else { return nil }; return max(0, limit - used) }
}

public enum KeychainOperation: String, Equatable, Sendable {
    case read, add, update, remove
    public var name: String { switch self { case .read: return "读取"; case .add: return "保存"; case .update: return "更新"; case .remove: return "移除" } }
}

public enum ViewerError: Error, LocalizedError, Equatable, Sendable {
    case invalidQuery(String), authentication, challenge, imageLimit, restricted, layoutChanged, network, tooLarge, unsupported, storage, stale
    case keychain(KeychainOperation, Int32), sessionRecord, ratingUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidQuery(let reason): return reason
        case .authentication: return "会话需要重新验证，请在官方网页完成登录。"
        case .challenge: return "站点要求网页验证，请打开官方网页完成验证后重试。"
        case .imageLimit: return "已达到站点看图额度。下载已暂停，可在账号页面查看额度。"
        case .restricted: return "站点暂时拒绝了访问，请检查账号权限或稍后重试。"
        case .layoutChanged: return "站点返回格式暂时无法识别，已有内容保留。可以打开原网页检查。"
        case .network: return "网络请求失败，已有内容保留，请重试。"
        case .ratingUnavailable: return "部分画廊的平均评分未能确认，已保留符合条件的结果，请重试。"
        case .tooLarge: return "文件超过本机单项大小或可用空间限制。"
        case .unsupported: return "当前文件无法解码，请检查站点原图。"
        case .storage: return "本机文件保存失败，请检查可用空间后重试。"
        case .keychain(let operation, let status):
            if status == -34018 { return "登录会话\(operation.name)失败：App 缺少 Keychain 签名权限（\(status)），请安装修正版后重试。" }
            return "本机登录会话\(operation.name)未完成（Keychain \(status)），请重试或检查设备解锁状态。"
        case .sessionRecord: return "本机登录记录格式异常，原记录已保留。请重新登录。"
        case .stale: return "账号或筛选条件已变化，请重新加载。"
        }
    }
}

public enum URLPolicy {
    public static let accountHosts = Set(["e-hentai.org", "exhentai.org", "forums.e-hentai.org", "api.e-hentai.org"])
    public static func account(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && accountHosts.contains(url.host?.lowercased() ?? "") && (url.port == nil || url.port == 443)
    }
    public static func media(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard url.scheme == "https" else { return false }
        let defaultPort = url.port == nil || url.port == 443
        if accountHosts.contains(host) || host == "ehgt.org" || host.hasSuffix(".ehgt.org") { return defaultPort }
        let hathSubdomain = host.hasSuffix(".hath.network")
        guard hathSubdomain else { return false }
        return defaultPort || (url.port.map { (1024...65534).contains($0) } ?? false)
    }
    public static func continuation(_ url: URL, from base: URL) -> Bool {
        account(url) && url.host == base.host && url.path == base.path
    }
}

import Foundation
import Security
import WebKit
import CryptoKit
import ExViewerCore

struct SessionCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var secure: Bool
    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain
        path = cookie.path; expires = cookie.expiresDate; secure = cookie.isSecure
    }
    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
}

enum SessionVault {
    static let service = "com.xueyj.exviewer.session.v1"
    static func read(service: String = SessionVault.service) throws -> [SessionCookie] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "site-session", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ViewerError.keychain(.read, status) }
        guard let data = result as? Data else { throw ViewerError.sessionRecord }
        do { return try JSONDecoder().decode([SessionCookie].self, from: data) }
        catch { throw ViewerError.sessionRecord }
    }
    static func save(_ cookies: [SessionCookie], service: String = SessionVault.service) throws {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "site-session"]
        let data = try JSONEncoder().encode(cookies)
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(key as CFDictionary, values as CFDictionary)
        if update == errSecItemNotFound {
            var record = key; values.forEach { record[$0.key] = $0.value }
            let status = SecItemAdd(record as CFDictionary, nil)
            guard status == errSecSuccess else { throw ViewerError.keychain(.add, status) }
        } else if update != errSecSuccess { throw ViewerError.keychain(.update, update) }
    }
    static func delete(service: String = SessionVault.service) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "site-session"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ViewerError.keychain(.remove, status) }
    }
}

final class SafeRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, URLPolicy.account(url) || URLPolicy.media(url) else { completionHandler(nil); return }
        if task.originalRequest?.httpMethod == "POST", task.originalRequest?.url?.path == "/favorites.php",
           task.originalRequest?.url?.host != url.host { completionHandler(nil); return }
        var safe = request
        // A redirect never carries a manually constructed authentication header to another origin.
        if response.url?.host != url.host { safe.setValue(nil, forHTTPHeaderField: "Cookie"); safe.setValue(nil, forHTTPHeaderField: "Referer") }
        completionHandler(safe)
    }
}

@MainActor final class SiteSession: ObservableObject {
    @Published private(set) var ehStatus = "未验证"
    @Published private(set) var exStatus = "未验证"
    @Published private(set) var generation = UUID()
    @Published private(set) var owner = "guest"
    @Published var quota = AccountQuota()
    @Published var error: String?
    let webStore = WKWebsiteDataStore.nonPersistent()
    private var cookies: [SessionCookie] = []
    private let delegate = SafeRedirect()
    private let transportConfiguration: URLSessionConfiguration?
    private let pageScheduler: SiteRequestScheduler
    private let pageConcurrencyLimit: () -> Int
    private lazy var transport = makeTransport()
    private func makeTransport() -> URLSession {
        let config = (transportConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    private var webOperation = UUID()
    private var loggingOut = false
    private let webGate = TransferGate(limit: 1)
    private let allowedNames = Set(["ipb_member_id", "ipb_pass_hash", "igneous", "cf_clearance", "yay", "uconfig"])
    var hasCredentials: Bool { cookies.contains { $0.name == "ipb_member_id" && !$0.value.isEmpty } && cookies.contains { $0.name == "ipb_pass_hash" && !$0.value.isEmpty } }

    init(qa: Bool = false, configuration: URLSessionConfiguration? = nil,
         searchInterval: TimeInterval = 3.1, pageConcurrencyLimit: (() -> Int)? = nil) {
        self.transportConfiguration = configuration
        self.pageScheduler = SiteRequestScheduler(searchInterval: searchInterval)
        self.pageConcurrencyLimit = pageConcurrencyLimit ?? {
            SiteRequestPolicy.configuredConcurrency(defaults: ReaderPreferenceDefaults.store)
        }
        guard !qa else { return }
        do { cookies = try SessionVault.read(); updateOwner() }
        catch { self.error = (error as? ViewerError)?.localizedDescription ?? "本机登录记录暂时无法读取，请重试。" }
    }
    private func updateOwner() {
        let member = cookies.first { $0.name == "ipb_member_id" && ($0.domain == ".e-hentai.org" || $0.domain == "e-hentai.org") }?.value
            ?? cookies.first { $0.name == "ipb_member_id" }?.value
        owner = member.map { SHA256.hash(data: Data($0.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() } ?? "guest"
    }
    private func accepted(_ cookie: HTTPCookie) -> Bool {
        let host = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return URLPolicy.accountHosts.contains(host) && allowedNames.contains(cookie.name) && !cookie.value.isEmpty && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
    }
    func beginWebOperation() throws -> UUID {
        guard !loggingOut else { throw ViewerError.stale }
        webOperation = UUID(); return webOperation
    }
    func endWebOperation(_ operation: UUID) { if webOperation == operation { webOperation = UUID() } }
    func prepareWebSession(operation: UUID) async throws {
        let revision = generation, snapshot = cookies
        try await webGate.acquire(); defer { Task { await webGate.release() } }
        guard !loggingOut, operation == webOperation, revision == generation else { throw ViewerError.stale }
        for cookie in snapshot.compactMap(\.cookie) where accepted(cookie) {
            guard !loggingOut, operation == webOperation, revision == generation else { throw ViewerError.stale }
            await webStore.httpCookieStore.setCookie(cookie)
            guard !loggingOut, operation == webOperation, revision == generation else { throw ViewerError.stale }
        }
    }
    func captureWebSession(operation: UUID) async throws {
        let revision = generation
        try await webGate.acquire(); defer { Task { await webGate.release() } }
        guard !loggingOut, operation == webOperation, revision == generation else { throw ViewerError.stale }
        let values = await webStore.httpCookieStore.allCookies().filter { accepted($0) }.map(SessionCookie.init)
        guard !loggingOut, operation == webOperation, revision == generation else { throw ViewerError.stale }
        guard values.contains(where: { $0.name == "ipb_member_id" }), values.contains(where: { $0.name == "ipb_pass_hash" }) else { throw ViewerError.authentication }
        guard Set(values.filter { $0.name == "ipb_member_id" }.map(\.value)).count == 1 else { throw ViewerError.stale }
        // Only the two site credentials are shared with the site's EX origin, never arbitrary browser cookies.
        var merged = values
        for name in ["ipb_member_id", "ipb_pass_hash"] {
            if !merged.contains(where: { $0.name == name && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "exhentai.org" }),
               var credential = values.first(where: { $0.name == name }) {
                credential.domain = ".exhentai.org"; credential.path = "/"; merged.append(credential)
            }
        }
        try SessionVault.save(merged)
        cookies = merged; generation = UUID(); updateOwner(); quota = AccountQuota(); ehStatus = "待验证"; exStatus = "待验证"
    }
    private func header(for url: URL) -> String? {
        guard URLPolicy.account(url), let host = url.host else { return nil }
        let applicable = cookies.filter { value in
            let domain = value.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || (value.domain.hasPrefix(".") && host.hasSuffix("." + domain))) && url.path.hasPrefix(value.path) && (value.expires == nil || value.expires! > Date())
        }
        return applicable.isEmpty ? nil : applicable.map { $0.name + "=" + $0.value }.joined(separator: "; ")
    }
    func updatePageConcurrency() { pageScheduler.setLimit(pageConcurrencyLimit()) }

    func html(_ url: URL, search: Bool = false, method: String = "GET", body: Data? = nil,
              contentType: String = "application/x-www-form-urlencoded",
              searchPriority: SearchRequestPriority = .foreground,
              recoverConnection: Bool = true,
              request demand: MediaRequestDemand? = nil) async throws -> String {
        guard URLPolicy.account(url) else { throw ViewerError.restricted }
        let revision = generation
        let demand = demand ?? MediaRequestDemand(priority: searchPriority == .prefetch ? .prefetch : .foreground)
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard revision == generation else { throw ViewerError.stale }
            let lease = try await pageScheduler.acquire(request: demand, search: search, limit: pageConcurrencyLimit())
            let client = attempt == 0 ? transport : makeTransport()
            do {
                let html = try await receiveHTML(url, method: method, body: body, contentType: contentType,
                                                 client: client, revision: revision)
                pageScheduler.release(lease)
                if attempt > 0 { client.finishTasksAndInvalidate() }
                return html
            } catch {
                pageScheduler.release(lease)
                if attempt > 0 { client.finishTasksAndInvalidate() }
                // Read-only GETs have one recovery attempt on a fresh connection.
                // PageMediaLoader disables this inner retry to keep its total budget at two.
                guard attempt == 0, recoverConnection, method == "GET", body == nil,
                      case RequestFailure.transport(.page, URLError.networkConnectionLost.rawValue) = error else { throw error }
                try Task.checkCancellation()
                guard revision == generation else { throw ViewerError.stale }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw ViewerError.network
    }

    private func receiveHTML(_ url: URL, method: String, body: Data?, contentType: String,
                             client: URLSession, revision: UUID) async throws -> String {
        try Task.checkCancellation()
        guard revision == generation else { throw ViewerError.stale }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        if method == "POST", url.path == "/favorites.php", let host = url.host, GallerySite.allCases.contains(where: { $0.host == host }) {
            request.setValue("https://" + host, forHTTPHeaderField: "Origin")
            request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        }
        request.setValue(header(for: url), forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        do {
            let (bytes, response) = try await client.bytes(for: request)
            guard let response = response as? HTTPURLResponse, let finalURL = response.url, URLPolicy.account(finalURL) else { throw ViewerError.network }
            if response.statusCode == 509 { throw ViewerError.imageLimit }
            if response.statusCode == 401 { throw ViewerError.authentication }
            if response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" { throw ViewerError.challenge }
            guard (200...299).contains(response.statusCode) || response.statusCode == 403 else { throw RequestFailure.http(.page, response.statusCode) }
            guard response.expectedContentLength <= 6_000_000 else { throw ViewerError.tooLarge }
            let data = try await Self.collectPageBytes(bytes)
            try Task.checkCancellation()
            guard revision == generation else { throw ViewerError.stale }
            guard let html = String(data: data, encoding: .utf8) else { throw ViewerError.layoutChanged }
            try EHParser.check(html)
            if response.statusCode == 403 { throw RequestFailure.http(.page, 403) }
            if let headers = response.allHeaderFields as? [String: String] {
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: finalURL) where accepted(cookie) {
                    cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }; cookies.append(SessionCookie(cookie))
                }
                if hasCredentials { try SessionVault.save(cookies) }
            }
            return html
        } catch let error as ViewerError { throw error }
        catch let error as RequestFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw RequestFailure.transport(.page, error.code.rawValue)
        }
        catch { throw ViewerError.network }
    }
    nonisolated private static func collectPageBytes(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        // URLSession's bounded stream is consumed off the main actor. A large
        // HTML/metadata response must not hold up selection and scrolling.
        var data = Data(); data.reserveCapacity(64_000)
        for try await byte in bytes { data.append(byte); if data.count > 6_000_000 { throw ViewerError.tooLarge } }
        return data
    }
    func verify() async {
        let revision = generation
        ehStatus = "连接中…"; exStatus = hasCredentials ? "连接中…" : "需要登录"
        for site in GallerySite.allCases {
            do {
                if site == .ex && !hasCredentials { exStatus = "需要登录"; continue }
                let url = try SearchQuery().url(site: site, favorites: site == .eh && hasCredentials)
                let list = try EHParser.list(await html(url, search: true), base: url)
                guard revision == generation else { return }
                let status = hasCredentials ? (site == .eh ? "站点收藏可读取" : "EX 画廊可访问") : "访客可访问"
                if site == .eh { ehStatus = status } else { exStatus = status }
                _ = list
            } catch {
                guard revision == generation else { return }
                let value = ErrorMessages.message(error, fallback: "验证未完成")
                if site == .eh { ehStatus = value } else { exStatus = value }
            }
        }
    }
    func changeFavorites(_ references: [GalleryRef], site: GallerySite, action: FavoriteAction) async throws {
        guard hasCredentials else { throw ViewerError.authentication }
        guard !references.isEmpty, references.count <= 25, references.allSatisfy({ $0.site == site }) else {
            throw ViewerError.invalidQuery("每批请选择 1 至 25 个有效收藏。")
        }
        let revision = generation, account = owner
        let endpoint = site.baseURL.appendingPathComponent("favorites.php")
        let request = try FavoritesBatchRequest(url: endpoint, site: site, gids: references.map(\.gid), action: action)
        do {
            _ = try await FavoritesSubmissionExecutor.run(isCurrent: { revision == self.generation && account == self.owner }, submit: {
                try await self.html(request.url, method: "POST", body: request.body)
            }, parse: { response in
                try EHParser.list(response, base: request.url)
            })
        } catch let failure as FavoritesSubmissionFailure {
            throw FavoriteMutationFailure(requestMayHaveBeenSent: failure.requestMayHaveBeenSent, underlying: failure.underlying)
        }
    }
    func refreshQuota() async {
        let revision = generation
        do {
            let result = try EHParser.quota(await html(URL(string: "https://e-hentai.org/home.php")!))
            guard revision == generation else { return }; quota = result
        } catch { guard revision == generation else { return }; self.error = ErrorMessages.message(error, fallback: "额度未能读取") }
    }
    func logout() async throws {
        loggingOut = true; webOperation = UUID(); generation = UUID()
        defer { loggingOut = false }
        transport.invalidateAndCancel()
        try SessionVault.delete(); cookies = []; generation = UUID(); owner = "guest"
        quota = AccountQuota(); ehStatus = "未验证"; exStatus = "未验证"
        try await webGate.acquire()
        await webStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await webGate.release()
        // Replace the invalidated ephemeral transport for a later account.
        transport = makeTransport()
    }
}

struct FavoriteMutationFailure: Error, LocalizedError {
    let requestMayHaveBeenSent: Bool
    let underlying: Error
    var errorDescription: String? {
        let status = requestMayHaveBeenSent ? "本次收藏操作可能已提交，结果未确认。" : "本次收藏操作尚未提交。"
        return status + ErrorMessages.message(underlying, fallback: "请刷新收藏检查后再操作。")
    }
}

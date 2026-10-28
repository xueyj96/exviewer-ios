import Foundation
import Combine
import ExViewerCore

struct TagSuggestion: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable { case site, cached, dictionary, saved, unsupported, qaFixture }
    let tag: GalleryTag
    let source: Source
    let chineseName: String?
    let relatedMaster: GalleryTag?
    var id: String { tag.id }
}

struct TagTranslationCatalog: Decodable, Sendable {
    let version: String
    let source: String
    let commit: String
    let license: String
    let updatedAt: String?
    let namespaces: [String: [String: String]]

    var count: Int { namespaces.values.reduce(0) { $0 + $1.count } }
    var information: String {
        let snapshot = updatedAt.map { "更新 \($0)" } ?? "快照 \(commit.prefix(8))"
        return "\(source) · \(version) · \(snapshot) · \(count) 个词条 · 仅覆盖词库条目，非全站标签目录 · \(license)"
    }

    static func load(bundle: Bundle = .main) -> TagTranslationCatalog? {
        guard let url = bundle.url(forResource: "tag-translations", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TagTranslationCatalog.self, from: data)
    }

    func matches(_ prefix: String, namespace: String, limit: Int = 20) -> [TagSuggestion] {
        let needle = TagSuggestionRequest.normalized(prefix)
        guard !needle.isEmpty else { return [] }
        guard !Self.currentTaskIsCancelled else { return [] }
        let scope = TagSuggestionRequest.normalized(namespace)
        let selectedNamespaces = namespaces.keys.filter { scope == "all" || TagSuggestionRequest.normalized($0) == scope }.sorted()
        var best: [(score: Int, suggestion: TagSuggestion)] = []
        var visited = 0
        for key in selectedNamespaces {
            guard let terms = namespaces[key] else { continue }
            for (raw, chinese) in terms {
                visited += 1
                if visited.isMultiple(of: 128), Self.currentTaskIsCancelled { return [] }
                guard let score = TagSuggestionRequest.matchRank(original: raw, chinese: chinese, normalizedPrefix: needle) else { continue }
                let suggestion = TagSuggestion(tag: GalleryTag(namespace: key, name: raw), source: .dictionary,
                                               chineseName: chinese.isEmpty ? nil : chinese, relatedMaster: nil)
                let insertion = best.firstIndex {
                    $0.score > score || ($0.score == score && $0.suggestion.tag.id.localizedStandardCompare(suggestion.tag.id) == .orderedDescending)
                } ?? best.endIndex
                best.insert((score, suggestion), at: insertion)
                if best.count > max(0, limit) { best.removeLast() }
            }
        }
        return Self.currentTaskIsCancelled ? [] : best.map(\.suggestion)
    }

    func translation(for tag: GalleryTag) -> String? {
        if let value = namespaces[tag.namespace]?[tag.name] { return value }
        guard let terms = namespaces.first(where: { $0.key.caseInsensitiveCompare(tag.namespace) == .orderedSame })?.value,
              let match = terms.first(where: { $0.key.caseInsensitiveCompare(tag.name) == .orderedSame }) else { return nil }
        return match.value
    }

    private static var currentTaskIsCancelled: Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }
}

struct EHTagSuggestionResponse: Decodable, Sendable {
    struct Candidate: Decodable, Sendable {
        let ns: String?
        let tn: String?
        let mns: String?
        let mtn: String?
    }
    let tags: [String: Candidate]

    private enum CodingKeys: String, CodingKey { case tags }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let map = try? container.decode([String: Candidate].self, forKey: .tags) {
            tags = map
        } else if (try? container.decode([String].self, forKey: .tags)) != nil {
            tags = [:]
        } else {
            throw DecodingError.dataCorruptedError(forKey: .tags, in: container, debugDescription: "Unexpected tagsuggest payload")
        }
    }

    static func parse(_ data: Data) throws -> [TagSuggestion] {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw TagSuggestionFailure.malformed }
        if let empty = object as? [Any], empty.isEmpty { return [] }
        if let response = object as? [String: Any], let error = response["error"] as? String, !error.isEmpty {
            throw TagSuggestionFailure.site
        }
        let decoded: Self
        do { decoded = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw TagSuggestionFailure.malformed }
        return decoded.tags.values.compactMap { value in
            guard let raw = value.tn?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            let namespace = (value.ns?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "other"
            guard namespace.utf8.count <= 32, namespace.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { return nil }
            let master: GalleryTag? = {
                guard let masterNamespace = value.mns, let masterName = value.mtn, !masterName.isEmpty else { return nil }
                return GalleryTag(namespace: masterNamespace, name: masterName)
            }()
            return TagSuggestion(tag: GalleryTag(namespace: namespace, name: raw), source: .site,
                                 chineseName: nil, relatedMaster: master)
        }
        .sorted { $0.tag.id.localizedStandardCompare($1.tag.id) == .orderedAscending }
    }
}

enum TagSuggestionRequest {
    static let selectableNamespaces: Set<String> = ["artist", "group", "parody", "character", "language", "cosplayer", "location", "female", "male", "mixed", "other", "reclass"]

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func text(prefix: String, namespace: String) -> String {
        let prefix = normalized(prefix), namespace = normalized(namespace)
        return namespace == "all" ? prefix : "\(namespace):\(prefix)"
    }

    static func exactText(for tag: GalleryTag) -> String {
        text(prefix: tag.name, namespace: tag.namespace) + "$"
    }

    static func matching(_ items: [TagSuggestion], namespace: String) -> [TagSuggestion] {
        let namespace = normalized(namespace)
        return namespace == "all" ? items : items.filter { normalized($0.tag.namespace) == namespace }
    }

    // Keep original names for display and selection. Only matching and wire
    // requests are folded, so stored tag identities and exact-match rules stay intact.
    static func matchRank(original: String, chinese: String?, normalizedPrefix needle: String) -> Int? {
        guard !needle.isEmpty else { return nil }
        let values = [normalized(original), normalized(chinese ?? "")]
        if values.contains(needle) { return 0 }
        if values.contains(where: { $0.hasPrefix(needle) }) { return 1 }
        return values.contains(where: { $0.contains(needle) }) ? 2 : nil
    }

    static func ranked(_ items: [TagSuggestion], prefix: String, limit: Int = 20) -> [TagSuggestion] {
        let needle = normalized(prefix)
        var scored: [(item: TagSuggestion, score: Int)] = items.map { item in
            let score = matchRank(original: item.tag.name, chinese: item.chineseName, normalizedPrefix: needle) ?? 3
            return (item: item, score: score)
        }
        scored.sort { left, right in
            if left.score != right.score { return left.score < right.score }
            return left.item.id.localizedStandardCompare(right.item.id) == .orderedAscending
        }
        return scored.prefix(max(0, limit)).map { $0.item }
    }

    static func isSelectable(_ tag: GalleryTag) -> Bool { selectableNamespaces.contains(tag.namespace) }
}

enum TagSuggestionFailure: Error, LocalizedError, Equatable {
    case site
    case malformed
    case dictionaryUnavailable

    var errorDescription: String? {
        switch self {
        case .site: return "站点 API 返回错误。"
        case .malformed: return "站点返回的标签建议格式无法识别。"
        case .dictionaryUnavailable: return "本地中文词库不可用。"
        }
    }
}

enum TagVerification: Equatable {
    case checking
    case verified
    case notFound
    case failed(String)
    case unverified
}

@MainActor final class TagSuggestionPacer {
    private let interval: TimeInterval
    private var lastStart = Date.distantPast
    init(interval: TimeInterval = 1) { self.interval = interval }

    func wait() async throws {
        // Multiple pending tags may verify at once. Every waiter rechecks after
        // waking so a delayed resume cannot release a burst of requests.
        while true {
            try Task.checkCancellation()
            let remaining = interval - Date().timeIntervalSince(lastStart)
            if remaining <= 0 { lastStart = Date(); return }
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }
}

@MainActor final class TagSuggestionModel: ObservableObject {
    enum State: Equatable {
        case idle, loading, ready, unavailable, failed(String)
        var message: String? {
            switch self {
            case .idle: return nil
            case .loading: return "正在查找真实标签建议…"
            case .ready: return nil
            case .unavailable: return "本地中文词库不可用；可请求站点英文前缀建议，或明确使用未验证输入。"
            case .failed(let value): return value
            }
        }
        var isFailure: Bool { if case .failed = self { return true }; return false }
    }
    private struct Cached {
        let date: Date
        let items: [TagSuggestion]
    }

    @Published private(set) var items: [TagSuggestion] = []
    @Published private(set) var state: State = .idle
    let catalog: TagTranslationCatalog?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var currentPrefix = ""
    private var cache: [String: Cached] = [:]
    private var lru: [String] = []
    private let cacheLimit = 128
    private let cacheTTL: TimeInterval = 15 * 60
    private let suggestionLimit = 20
    private let networkPacer = TagSuggestionPacer()

    init(catalog: TagTranslationCatalog? = .load()) { self.catalog = catalog }

    func update(prefix raw: String, namespace: String, session: SiteSession, qa: Bool, arguments: [String] = ProcessInfo.processInfo.arguments) {
        task?.cancel()
        generation = UUID()
        let current = generation
        let prefix = TagSuggestionRequest.normalized(raw)
        let namespace = TagSuggestionRequest.normalized(namespace)
        currentPrefix = prefix
        items = []
        state = prefix.isEmpty ? .idle : .loading
        guard !prefix.isEmpty else { return }

        task = Task {
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard !Task.isCancelled, current == generation else { return }
            let catalogSnapshot = catalog
            let localLimit = suggestionLimit
            let localTask = Task.detached(priority: .userInitiated) {
                catalogSnapshot?.matches(prefix, namespace: namespace, limit: localLimit) ?? []
            }
            let local = await withTaskCancellationHandler(operation: { await localTask.value }, onCancel: { localTask.cancel() })
            guard !Task.isCancelled, current == generation else { return }
            items = local
            state = catalog == nil ? .unavailable : .ready

            if qa {
                if arguments.contains("--qa-tags-offline") {
                    merge(Self.qaFixtures(matching: prefix, namespace: namespace), current: current)
                    return
                }
                guard arguments.contains("--qa-tags-delayed") else {
                    state = .failed("测试模式不访问站点标签建议；可用 --qa-tags-offline 或 --qa-tags-delayed 检查交互。")
                    return
                }
                do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
                guard !Task.isCancelled, current == generation else { return }
                merge(Self.qaFixtures(matching: prefix, namespace: namespace), current: current)
                return
            }

            guard prefix.unicodeScalars.allSatisfy({ $0.isASCII }), Self.safePrefix(prefix) else { return }
            let key = TagSuggestionRequest.text(prefix: prefix, namespace: namespace)
            if let cached = cache[key], Date().timeIntervalSince(cached.date) < cacheTTL {
                touch(key)
                merge(cached.items.map { Self.cached($0) }, current: current)
                return
            }
            let expired = cache[key]?.items.map { Self.cached($0) } ?? []
            state = .loading
            do {
                guard !Task.isCancelled, current == generation else { return }
                let url = URL(string: "https://api.e-hentai.org/api.php")!
                let body = try JSONSerialization.data(withJSONObject: ["method": "tagsuggest", "text": key])
                try await waitForNetworkSlot()
                guard current == generation else { return }
                let response = try await session.html(url, method: "POST", body: body, contentType: "application/json")
                let found = TagSuggestionRequest.matching(try EHTagSuggestionResponse.parse(Data(response.utf8)), namespace: namespace)
                    .map(classifySiteCandidate)
                guard !Task.isCancelled, current == generation else { return }
                store(found, for: key)
                merge(found, current: current)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, current == generation else { return }
                if !expired.isEmpty { merge(expired, current: current) }
                state = .failed(Self.failureLabel(error, usedExpiredCache: !expired.isEmpty, catalogAvailable: catalog != nil))
            }
        }
    }

    func verify(_ tag: GalleryTag, session: SiteSession, qa: Bool) async -> TagVerification {
        guard !qa else { return .unverified }
        guard Self.safePrefix(tag.name), tag.namespace.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) else { return .unverified }
        let revision = session.generation
        do {
            let url = URL(string: "https://api.e-hentai.org/api.php")!
            let body = try JSONSerialization.data(withJSONObject: ["method": "tagsuggest", "text": TagSuggestionRequest.exactText(for: tag)])
            try await waitForNetworkSlot()
            let response = try await session.html(url, method: "POST", body: body, contentType: "application/json")
            try Task.checkCancellation()
            guard revision == session.generation else { return .unverified }
            let found = try EHTagSuggestionResponse.parse(Data(response.utf8))
            return found.contains { $0.tag.id == tag.id } ? .verified : .notFound
        } catch is CancellationError { return .unverified }
        catch { return .failed(Self.failureLabel(error, usedExpiredCache: false, catalogAvailable: catalog != nil)) }
    }

    private func waitForNetworkSlot() async throws {
        try await networkPacer.wait()
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
    }

    func sessionChanged() {
        cancel(); cache.removeAll(); lru.removeAll()
    }

    static func cached(_ item: TagSuggestion) -> TagSuggestion {
        TagSuggestion(tag: item.tag, source: TagSuggestionRequest.isSelectable(item.tag) ? .cached : .unsupported,
                      chineseName: item.chineseName, relatedMaster: item.relatedMaster)
    }

    private static func safePrefix(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            $0.isASCII && !CharacterSet.controlCharacters.contains($0) && ![":", "$", "\"", "\\"].contains(String($0))
        }
    }

    private static func failureLabel(_ error: Error, usedExpiredCache: Bool, catalogAvailable: Bool) -> String {
        let detail: String
        if let value = error as? ViewerError {
            switch value {
            case .authentication: detail = "站点拒绝了访问或要求登录。"
            case .challenge: detail = "站点要求网页验证。"
            case .restricted: detail = "站点限制了标签建议请求。"
            case .imageLimit: detail = "站点返回了额度限制。"
            case .stale: detail = "账号会话已变化，请重新查找。"
            case .network: detail = "网络连接失败。"
            case .tooLarge: detail = "站点返回内容超过大小限制。"
            default: detail = "站点标签建议暂时不可用。"
            }
        } else if let failure = error as? RequestFailure {
            switch failure {
            case .http(_, let status): detail = "站点返回 HTTP \(status)。"
            case .transport: detail = "网络连接失败。"
            default: detail = "站点标签建议暂时不可用。"
            }
        } else if error as? TagSuggestionFailure == .site {
            detail = "站点 API 返回错误。"
        } else if error as? TagSuggestionFailure == .malformed {
            detail = "站点返回的建议数据格式无法识别。"
        } else { detail = "站点标签建议暂时不可用。" }
        if usedExpiredCache { return "\(detail) 显示过期站点缓存，候选未实时验证。" }
        return catalogAvailable ? "\(detail) 可查看本地词库匹配或明确使用未验证输入。" : "\(detail) 本地中文词库也不可用。"
    }

    static func qaFixtures(matching prefix: String, namespace: String) -> [TagSuggestion] {
        let fixtures = [
            TagSuggestion(tag: GalleryTag(namespace: "language", name: "english"), source: .qaFixture, chineseName: nil, relatedMaster: nil),
            TagSuggestion(tag: GalleryTag(namespace: "artist", name: "preview"), source: .qaFixture, chineseName: nil, relatedMaster: nil)
        ]
        return fixtures.filter { (namespace == "all" || $0.tag.namespace == namespace) && $0.tag.name.localizedCaseInsensitiveContains(prefix) }
    }

    private func classifySiteCandidate(_ item: TagSuggestion) -> TagSuggestion {
        let source: TagSuggestion.Source = TagSuggestionRequest.isSelectable(item.tag) ? .site : .unsupported
        return TagSuggestion(tag: item.tag, source: source, chineseName: catalog?.translation(for: item.tag), relatedMaster: item.relatedMaster)
    }

    private func merge(_ fresh: [TagSuggestion], current expected: UUID) {
        guard expected == generation else { return }
        var unique = Dictionary(items.map { ($0.tag.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in fresh { unique[item.tag.id] = item }
        items = TagSuggestionRequest.ranked(Array(unique.values), prefix: currentPrefix, limit: suggestionLimit)
        state = .ready
    }

    private func store(_ items: [TagSuggestion], for key: String) {
        cache[key] = Cached(date: Date(), items: items)
        touch(key)
        while lru.count > cacheLimit { cache.removeValue(forKey: lru.removeFirst()) }
    }

    private func touch(_ key: String) {
        lru.removeAll { $0 == key }; lru.append(key)
    }
}

import Foundation

/// A parsed search-field draft. Rules returned here came from the free-form
/// field; callers can track them separately from filter-sheet rules.
public struct ParsedSearchInput: Equatable, Sendable {
    public var query: SearchQuery
    public var inputRules: [TagRule]

    public init(query: SearchQuery, inputRules: [TagRule]) {
        self.query = query
        self.inputRules = inputRules
    }
}

public enum SearchInputError: Error, Equatable, LocalizedError, Sendable {
    case unclosedQuote
    case invalidQuotedValue(String)
    case invalidTag(String)
    case emptyValue(String)
    case unsupportedScope(String)
    case mixedTitleScope
    case mixedPhraseScope
    case repeatedUploader

    public var errorDescription: String? {
        switch self {
        case .unclosedQuote: return "搜索内容有未闭合的引号。"
        case .invalidQuotedValue(let token): return "引号后的内容无法解析：\(token)"
        case .invalidTag: return "标签请使用 namespace:tag、-namespace:tag 或 ~namespace:tag。"
        case .emptyValue(let scope): return "\(scope)条件不能为空。"
        case .unsupportedScope(let scope): return "当前组合输入暂不支持 \(scope): 范围，请使用已列出的关键词与标签条件。"
        case .mixedTitleScope: return "当前组合输入一次使用同一种关键词范围；请统一标题范围，或在筛选中设置。"
        case .mixedPhraseScope: return "当前组合输入暂不支持混合多个短语与普通词；请使用关键词模式或一个完整短语。"
        case .repeatedUploader: return "搜索栏只能指定一个 uploader 条件。"
        }
    }
}

/// Parses ordinary keywords and inline tag scopes without placing the raw
/// expression into SearchQuery.text, which is quoted by SearchQuery.expression.
public enum SearchInputParser {
    private static let namespaces: [String: String] = [
        "artist": "artist", "a": "artist", "character": "character", "c": "character", "char": "character",
        "cosplayer": "cosplayer", "cos": "cosplayer", "female": "female", "f": "female",
        "group": "group", "g": "group", "circle": "group", "language": "language", "l": "language", "lang": "language",
        "location": "location", "loc": "location", "male": "male", "m": "male", "mixed": "mixed", "x": "mixed",
        "other": "other", "o": "other", "parody": "parody", "p": "parody", "series": "parody", "reclass": "reclass", "r": "reclass"
    ]
    private struct Value {
        var text: String
        var quoted: Bool
    }

    public static func parse(_ input: String, preserving base: SearchQuery = SearchQuery()) throws -> ParsedSearchInput {
        let tokens = try tokenize(input)
        var query = base
        query.text = ""
        query.rules = []
        for rule in base.rules {
            let namespace = namespaces[rule.tag.namespace.lowercased()] ?? rule.tag.namespace
            let normalized = TagRule(tag: .init(namespace: namespace, name: rule.tag.name), match: rule.match)
            query.rules.removeAll { $0.id == normalized.id }; query.rules.append(normalized)
        }

        var keywords: [String] = []
        var titleKeywordCount = 0
        var unscopedKeywordCount = 0
        var quotedKeywordCount = 0
        var uploaderSeen = false
        var parsedRules: [TagRule] = []

        for token in tokens {
            if token.lowercased().hasPrefix("title:") {
                let raw = String(token.dropFirst("title:".count))
                let value = try parseValue(raw, scope: "标题", allowTerminator: false)
                keywords.append(value.text)
                titleKeywordCount += 1
                if value.quoted { quotedKeywordCount += 1 }
                query.titleOnly = true
                continue
            }
            if token.lowercased().hasPrefix("uploader:") {
                guard !uploaderSeen else { throw SearchInputError.repeatedUploader }
                let raw = String(token.dropFirst("uploader:".count))
                let value = try parseValue(raw, scope: "uploader", allowTerminator: false)
                query.uploader = value.text
                uploaderSeen = true
                continue
            }

            var rawTag = token
            var match = TagMatch.all
            if rawTag.first == "-" || rawTag.first == "~" {
                let prefix = rawTag.removeFirst()
                match = prefix == "-" ? .exclude : .any
                guard rawTag.contains(":") else { throw SearchInputError.invalidTag(token) }
            }
            if let colon = rawTag.firstIndex(of: ":") {
                let rawNamespace = String(rawTag[..<colon]).lowercased()
                let rawValue = String(rawTag[rawTag.index(after: colon)...])
                guard !rawNamespace.isEmpty, rawNamespace.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                    throw SearchInputError.invalidTag(token)
                }
                guard let namespace = namespaces[rawNamespace] else { throw SearchInputError.unsupportedScope(rawNamespace) }
                let value = try parseValue(rawValue, scope: "标签", allowTerminator: true)
                guard !value.text.isEmpty else { throw SearchInputError.emptyValue("标签") }
                let rule = TagRule(tag: .init(namespace: namespace, name: value.text), match: match)
                parsedRules.removeAll { $0.id == rule.id }; parsedRules.append(rule)
                continue
            }
            if token.first == "-" || token.first == "~" { throw SearchInputError.invalidTag(token) }
            if token.first == "\"" {
                let value = try parseValue(token, scope: "关键词", allowTerminator: false)
                keywords.append(value.text)
                unscopedKeywordCount += 1
                if value.quoted { quotedKeywordCount += 1 }
                continue
            }
            guard !token.contains("\"") else { throw SearchInputError.invalidQuotedValue(token) }
            guard !token.isEmpty else { continue }
            keywords.append(token)
            unscopedKeywordCount += 1
        }

        if titleKeywordCount > 0 && unscopedKeywordCount > 0 && !base.titleOnly {
            throw SearchInputError.mixedTitleScope
        }
        if quotedKeywordCount > 0 && keywords.count > 1 {
            throw SearchInputError.mixedPhraseScope
        }
        if quotedKeywordCount > 0 { query.matchPhrase = true }
        query.text = keywords.joined(separator: " ")

        // Existing rules from the filter sheet remain. An inline rule replaces
        // an existing rule for the same tag, including a different match mode.
        for rule in parsedRules {
            query.rules.removeAll { $0.id == rule.id }
            query.rules.append(rule)
        }
        return ParsedSearchInput(query: query, inputRules: parsedRules)
    }

    private static func tokenize(_ input: String) throws -> [String] {
        var result: [String] = []
        var token = ""
        var quoted = false
        for character in input {
            if character == "\"" {
                quoted.toggle()
                token.append(character)
            } else if character.isWhitespace && !quoted {
                if !token.isEmpty { result.append(token); token = "" }
            } else {
                token.append(character)
            }
        }
        guard !quoted else { throw SearchInputError.unclosedQuote }
        if !token.isEmpty { result.append(token) }
        return result
    }

    private static func parseValue(_ raw: String, scope: String, allowTerminator: Bool) throws -> Value {
        guard !raw.isEmpty else { throw SearchInputError.emptyValue(scope) }
        if raw.first == "\"" {
            guard let closing = raw.dropFirst().firstIndex(of: "\"") else { throw SearchInputError.unclosedQuote }
            let content = String(raw[raw.index(after: raw.startIndex)..<closing])
            let suffix = String(raw[raw.index(after: closing)...])
            let hasTerminator = suffix == "$"
            guard suffix.isEmpty || (allowTerminator && hasTerminator), !content.contains("\\") else {
                throw SearchInputError.invalidQuotedValue(raw)
            }
            guard !content.isEmpty else { throw SearchInputError.emptyValue(scope) }
            return Value(text: content, quoted: true)
        }
        guard !raw.contains("\"") else { throw SearchInputError.invalidQuotedValue(raw) }
        let hasTerminator = allowTerminator && raw.hasSuffix("$")
        let content = hasTerminator ? String(raw.dropLast()) : raw
        guard !content.isEmpty else { throw SearchInputError.emptyValue(scope) }
        return Value(text: content, quoted: false)
    }
}

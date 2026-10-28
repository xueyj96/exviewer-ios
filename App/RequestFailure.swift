import Foundation
import ExViewerCore

enum RequestStage: Equatable { case page, media
    var subject: String { self == .page ? "站点页面" : "图片源" }
}

/// Contains only a stage and a numeric status. URLs and authentication data never enter an error.
enum RequestFailure: Error, LocalizedError, Equatable {
    case http(RequestStage, Int)
    case transport(RequestStage, Int)
    case queueFull
    case pageQueueFull
    case redirectRejected
    case nonImage
    var errorDescription: String? {
        switch self {
        case let .http(stage, code):
            if code == 429 { return "\(stage.subject)请求过快（HTTP 429），请稍后重试。" }
            if code == 503 { return "\(stage.subject)暂时不可用（HTTP 503），请稍后重试。" }
            return "\(stage.subject)返回 HTTP \(code)，请重新载入。"
        case let .transport(stage, code):
            let reason: String
            switch code {
            case URLError.timedOut.rawValue: reason = "连接超时"
            case URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue: reason = "地址解析失败"
            case URLError.cannotConnectToHost.rawValue: reason = "无法连接"
            case URLError.networkConnectionLost.rawValue: reason = "连接中断"
            case URLError.notConnectedToInternet.rawValue: reason = "当前网络不可用"
            case URLError.secureConnectionFailed.rawValue, URLError.serverCertificateUntrusted.rawValue,
                 URLError.serverCertificateHasBadDate.rawValue, URLError.serverCertificateHasUnknownRoot.rawValue:
                reason = "安全连接未能建立"
            default: reason = "连接未完成"
            }
            return "\(stage.subject)\(reason)（\(code)），可重试。"
        case .queueFull: return "等待中的图片请求过多，请稍后重试。"
        case .pageQueueFull: return "等待中的站点页面请求过多，请稍后重试。"
        case .redirectRejected: return "图片源跳转到了未识别的地址，已停止加载。"
        case .nonImage: return "图片源返回了非图片内容，请重新载入此页。"
        }
    }
    var canRefreshImagePage: Bool {
        switch self {
        case .http(.media, let code): return [404, 410, 500, 502, 503, 504].contains(code)
        case .transport(.media, let code): return [URLError.timedOut.rawValue, URLError.networkConnectionLost.rawValue, URLError.cannotConnectToHost.rawValue].contains(code)
        default: return false
        }
    }
    var canRetryWhenVisible: Bool {
        if canRefreshImagePage { return true }
        switch self {
        case .http(.page, let code): return [500, 502, 503, 504].contains(code)
        case .transport(.page, let code):
            return [URLError.timedOut.rawValue, URLError.networkConnectionLost.rawValue, URLError.cannotConnectToHost.rawValue].contains(code)
        case .queueFull, .pageQueueFull: return true
        default: return false
        }
    }
}

enum ErrorMessages {
    static func message(_ error: Error, fallback: String = "请求未完成，请重试。") -> String {
        if let error = error as? ViewerError { return error.localizedDescription }
        if let error = error as? RequestFailure { return error.localizedDescription }
        return fallback
    }
}

enum PageMediaLoader {
    /// Retries the page/image pipeline once for a recoverable page or media
    /// transport failure. It never forces nl=1 or purchases a fallback.
    @MainActor static func file(resolvePage: () async throws -> ImageSource,
                                loadMedia: (URL) async throws -> URL,
                                isCurrent: () -> Bool) async throws -> URL {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard isCurrent() else { throw ViewerError.stale }
            do {
                let source = try await resolvePage()
                try Task.checkCancellation()
                guard isCurrent() else { throw ViewerError.stale }
                let file = try await loadMedia(source.url)
                try Task.checkCancellation()
                guard isCurrent() else { throw ViewerError.stale }
                return file
            } catch let failure as RequestFailure where attempt == 0 && failure.canRetryWhenVisible {
                try Task.checkCancellation()
                guard isCurrent() else { throw ViewerError.stale }
                try await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        throw ViewerError.network
    }
}

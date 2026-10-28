import Foundation

/// Owns one reusable, private media session. Individual transfers supply their
/// own task delegate so concurrent downloads keep independent response state.
final class MediaTransferClient: @unchecked Sendable {
    static let shared = MediaTransferClient()

    private let session: URLSession

    init(configuration suppliedConfiguration: URLSessionConfiguration? = nil) {
        let configuration = suppliedConfiguration?.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
    }

    func dataTask(with request: URLRequest, delegate: URLSessionDataDelegate) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        task.delegate = delegate
        return task
    }

    deinit {
        session.invalidateAndCancel()
    }
}

import Foundation
import Synchronization

public struct FeedHTTPResponse: Sendable {
    public let url: URL
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.url = url
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol FeedHTTPTransport: Sendable {
    /// Capture one logical call across redirects and origin-authentication retries.
    func requestScope() throws -> any FeedHTTPTransport
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse
    /// One request whose body may be at most `bodyLimit` bytes: a larger one fails with `FeedBodyLimitExceeded`
    /// (a server library's fetch, with the server's limit).
    func send(_ request: URLRequest, bodyLimit: Int) async throws -> FeedHTTPResponse
}

/// A response body over a request's limit (`FeedHTTPTransport.send(_:bodyLimit:)`).
public struct FeedBodyLimitExceeded: Error, Sendable {}

public extension FeedHTTPTransport {
    func requestScope() throws -> any FeedHTTPTransport { self }
    /// Checks the whole body afterwards; `URLSessionFeedTransport` stops reading at the limit.
    func send(_ request: URLRequest, bodyLimit: Int) async throws -> FeedHTTPResponse {
        let response = try await send(request)
        guard response.body.count <= bodyLimit else { throw FeedBodyLimitExceeded() }
        return response
    }
}

public final class URLSessionFeedTransport: FeedHTTPTransport {
    private let session: URLSession
    private let secureSession: URLSession
    private let proxy: PodcastProxy

    public convenience init() { self.init(configuration: nil) }

    public convenience init(proxy: PodcastProxy, cache: URLCache? = nil) throws {
        let configuration = URLSessionConfiguration.ephemeral
        try proxy.apply(to: configuration)
        let secure = URLSessionConfiguration.ephemeral
        try proxy.apply(to: secure, scheme: "https")
        self.init(configuration: configuration, secureConfiguration: secure, proxy: proxy, cache: cache)
    }

    private init(configuration supplied: URLSessionConfiguration?, secureConfiguration: URLSessionConfiguration? = nil, proxy: PodcastProxy = .init(), cache: URLCache? = nil) {
        self.proxy = proxy
        // HTTP and HTTPS sessions form one client; redirects between them must
        // retain that client's cookies without sharing them with another account.
        let primary = supplied ?? URLSessionConfiguration.ephemeral
        let cookies = primary.httpCookieStorage
        func make(_ configuration: URLSessionConfiguration) -> URLSession {
            configuration.urlCache = cache
            configuration.urlCredentialStorage = nil
            configuration.httpCookieStorage = cookies
            configuration.requestCachePolicy = cache == nil ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
            configuration.httpMaximumConnectionsPerHost = 8
            configuration.waitsForConnectivity = false
            return URLSession(configuration: configuration)
        }
        session = make(primary)
        secureSession = secureConfiguration.map(make) ?? session
    }

    deinit {
        session.invalidateAndCancel()
        if secureSession !== session { secureSession.invalidateAndCancel() }
    }

    public func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        try await send(request, limit: nil)
    }

    public func send(_ request: URLRequest, bodyLimit: Int) async throws -> FeedHTTPResponse {
        try await send(request, limit: bodyLimit)
    }

    private func send(_ request: URLRequest, limit: Int?) async throws -> FeedHTTPResponse {
        let response = try await sendOnce(request, limit: limit)
        // Foundation surfaces a forward-proxy 407 as a response, without a task
        // authentication challenge. Scope this retry to plain HTTP using our
        // immutable explicit proxy session; HTTPS credentials must stay outside
        // the encrypted origin request and are never added as request headers.
        guard response.status == 407, proxy.kind == .http, proxy.isConfigured,
              request.url?.scheme?.lowercased() == "http",
              let username = proxy.username, !username.isEmpty, let password = proxy.password else { return response }
        var authenticated = request
        authenticated.setValue(FeedCredentials(username: username, password: password).authorization(utf8: false), forHTTPHeaderField: "Proxy-Authorization")
        let retried = try await sendOnce(authenticated, limit: limit)
        guard retried.status != 407 else { throw URLError(.userAuthenticationRequired) }
        return retried
    }

    private func sendOnce(_ request: URLRequest, limit: Int?) async throws -> FeedHTTPResponse {
        let delegate = FeedSessionDelegate(proxy: proxy)
        let data: Data
        let response: URLResponse
        do {
            let selected = request.url?.scheme?.lowercased() == "https" ? secureSession : session
            if let limit { (data, response) = try await delegate.data(selected, for: request, limit: limit) }
            else { (data, response) = try await selected.data(for: request, delegate: delegate) }
        } catch let exceeded as FeedBodyLimitExceeded {
            throw exceeded
        } catch {
            try Task.checkCancellation()
            guard let rejected = delegate.authenticationFailure else { throw error }
            data = Data()
            response = rejected
        }
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        return FeedHTTPResponse(url: url, status: response.statusCode, headers: headers, body: data)
    }
}

private final class FeedSessionDelegate: NSObject, URLSessionDataDelegate {
    private let rejected = Mutex<HTTPURLResponse?>(nil)
    private let proxy: PodcastProxy
    init(proxy: PodcastProxy) { self.proxy = proxy }

    var authenticationFailure: HTTPURLResponse? { rejected.withLock { $0 } }

    /// A limited read (`data(_:for:limit:)`): the body so far, the limit, and who waits for the end.
    private struct Limited {
        var limit = Int.max
        var body = Data()
        var response: URLResponse?
        var exceeded = false
        var waiter: CheckedContinuation<(Data, URLResponse), any Error>?
    }
    private let limited = Mutex(Limited())

    /// The response with a body of at most `limit` bytes; reading stops, and the request fails with
    /// `FeedBodyLimitExceeded`, as soon as it is longer (a declared length over it fails before any body).
    func data(_ session: URLSession, for request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        task.delegate = self
        limited.withLock { $0.limit = limit }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                limited.withLock { $0.waiter = continuation }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let allowed: Bool = limited.withLock { state in
            state.response = response
            guard response.expectedContentLength <= Int64(state.limit) else { state.exceeded = true; return false }
            return true
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over: Bool = limited.withLock { state in
            guard !state.exceeded else { return false }
            if state.body.count + data.count > state.limit { state.exceeded = true; state.body = Data(); return true }
            state.body.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (waiter, result): (CheckedContinuation<(Data, URLResponse), any Error>?, Result<(Data, URLResponse), any Error>) = limited.withLock { state in
            let waiter = state.waiter
            state.waiter = nil
            if state.exceeded { return (waiter, .failure(FeedBodyLimitExceeded())) }
            if let error { return (waiter, .failure(error)) }
            guard let response = state.response else { return (waiter, .failure(URLError(.badServerResponse))) }
            return (waiter, .success((state.body, response)))
        }
        waiter?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.isProxy() {
            if let credential = proxy.credential(for: challenge) { completionHandler(.useCredential, credential) }
            else { completionHandler(.cancelAuthenticationChallenge, nil) }
        } else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else if let response = challenge.failureResponse as? HTTPURLResponse, response.statusCode == 401 {
            rejected.withLock { $0 = response }
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.useCredential, nil)
        }
    }
}

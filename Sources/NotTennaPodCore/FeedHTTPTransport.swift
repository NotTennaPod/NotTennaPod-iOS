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
    /// As `send(_:bodyLimit:)`, but a response whose status `completeAfter` maps to a byte count ends successfully
    /// once that many body bytes have arrived (the rest is not read; a count over `bodyLimit` fails at once). The body
    /// holds at least that many bytes: the delivered chunk that crosses the count is kept whole, as it was charged.
    /// Chapter pictures and chapter lists inside an episode need this; transports without it read as
    /// `send(_:bodyLimit:)`.
    func send(_ request: URLRequest, bodyLimit: Int, completeAfter: @escaping @Sendable (Int) -> Int?) async throws -> FeedHTTPResponse
    /// As `send(_:bodyLimit:completeAfter:)`, drawing on `budget`, which the caller shares with every other request
    /// of the same logical call (redirect hops, a proxy-login retry). The same object reaches the session delegate.
    func send(_ request: URLRequest, budget: FeedTransferBudget, completeAfter: (@Sendable (Int) -> Int?)?) async throws -> FeedHTTPResponse
}

/// A response body over a request's limit (`FeedHTTPTransport.send(_:bodyLimit:)`).
public struct FeedBodyLimitExceeded: Error, Sendable {}

/// The bytes one logical call may receive, shared by every redirect hop and every hidden proxy-login retry. Each body
/// chunk is charged as it arrives; the call fails with `FeedBodyLimitExceeded` once its bodies would pass `limit`.
public final class FeedTransferBudget: Sendable {
    public let limit: Int
    private let used = Mutex(0)

    public init(limit: Int) { self.limit = max(0, limit) }

    /// Body bytes delivered so far, across hops and retries (the delegate's count, not a packet capture).
    public var consumed: Int { used.withLock { $0 } }
    public var remaining: Int { max(0, limit - consumed) }

    /// Records `delivered` bytes, and fails when the `needed` part of them (all, by default) takes the total past
    /// `limit`. A response that ends early (`completeAfter`) needs only its prefix: the rest of the chunk crossing its
    /// end still counts, but doesn't fail the response it completes.
    public func charge(_ delivered: Int, needed: Int? = nil) throws {
        let fits: Bool = used.withLock { total in
            let fits = total <= limit && min(delivered, needed ?? delivered) <= limit - total
            total = Self.adding(delivered, to: total)
            return fits
        }
#if DEBUG
        trace.withLock { $0.append(.init(delivered: delivered, fits: fits, afterStop: false)) }
#endif
        guard fits else { throw FeedBodyLimitExceeded() }
    }

    /// Counts a chunk delivered after its response already stopped (ended at `completeAfter`, or over the budget).
    func record(_ delivered: Int) {
        used.withLock { $0 = Self.adding(delivered, to: $0) }
#if DEBUG
        trace.withLock { $0.append(.init(delivered: delivered, fits: true, afterStop: true)) }
#endif
    }

    private static func adding(_ count: Int, to total: Int) -> Int { total > Int.max - count ? Int.max : total + count }

#if DEBUG
    /// Test-only: every delivered chunk, in order, whether it fit, and whether it came after its response stopped.
    struct Charge: Equatable, Sendable { let delivered: Int; let fits: Bool; let afterStop: Bool }
    private let trace = Mutex<[Charge]>([])
    var charges: [Charge] { trace.withLock { $0 } }
#endif
}

public extension FeedHTTPTransport {
    func requestScope() throws -> any FeedHTTPTransport { self }
    /// Checks the whole body afterwards; `URLSessionFeedTransport` stops reading at the limit.
    func send(_ request: URLRequest, bodyLimit: Int) async throws -> FeedHTTPResponse {
        let response = try await send(request)
        guard response.body.count <= bodyLimit else { throw FeedBodyLimitExceeded() }
        return response
    }
    func send(_ request: URLRequest, bodyLimit: Int, completeAfter: @escaping @Sendable (Int) -> Int?) async throws -> FeedHTTPResponse {
        try await send(request, bodyLimit: bodyLimit)
    }
    /// For transports without a session delegate (test doubles): the remaining budget bounds the body, which is then
    /// charged whole.
    func send(_ request: URLRequest, budget: FeedTransferBudget, completeAfter: (@Sendable (Int) -> Int?)?) async throws -> FeedHTTPResponse {
        let response: FeedHTTPResponse
        if let completeAfter { response = try await send(request, bodyLimit: budget.remaining, completeAfter: completeAfter) }
        else { response = try await send(request, bodyLimit: budget.remaining) }
        try budget.charge(response.body.count)
        return response
    }
    func send(_ request: URLRequest, budget: FeedTransferBudget) async throws -> FeedHTTPResponse {
        try await send(request, budget: budget, completeAfter: nil)
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
        try await send(request, limit: FeedTransferBudget(limit: bodyLimit))
    }

    public func send(_ request: URLRequest, bodyLimit: Int, completeAfter: @escaping @Sendable (Int) -> Int?) async throws -> FeedHTTPResponse {
        try await send(request, limit: FeedTransferBudget(limit: bodyLimit), completeAfter: completeAfter)
    }

    public func send(_ request: URLRequest, budget: FeedTransferBudget, completeAfter: (@Sendable (Int) -> Int?)?) async throws -> FeedHTTPResponse {
        try await send(request, limit: budget, completeAfter: completeAfter)
    }

    /// The proxy-login retry draws on the same budget, which has already been charged for the login page.
    private func send(_ request: URLRequest, limit: FeedTransferBudget?, completeAfter: (@Sendable (Int) -> Int?)? = nil) async throws -> FeedHTTPResponse {
        let response = try await sendOnce(request, limit: limit, completeAfter: completeAfter)
        // Foundation surfaces a forward-proxy 407 as a response, without a task
        // authentication challenge. Scope this retry to plain HTTP using our
        // immutable explicit proxy session; HTTPS credentials must stay outside
        // the encrypted origin request and are never added as request headers.
        guard response.status == 407, proxy.kind == .http, proxy.isConfigured,
              request.url?.scheme?.lowercased() == "http",
              let username = proxy.username, !username.isEmpty, let password = proxy.password else { return response }
        var authenticated = request
        authenticated.setValue(FeedCredentials(username: username, password: password).authorization(utf8: false), forHTTPHeaderField: "Proxy-Authorization")
        let retried = try await sendOnce(authenticated, limit: limit, completeAfter: completeAfter)
        guard retried.status != 407 else { throw URLError(.userAuthenticationRequired) }
        return retried
    }

    private func sendOnce(_ request: URLRequest, limit: FeedTransferBudget?, completeAfter: (@Sendable (Int) -> Int?)? = nil) async throws -> FeedHTTPResponse {
        let delegate = FeedSessionDelegate(proxy: proxy)
        let data: Data
        let response: URLResponse
        do {
            let selected = request.url?.scheme?.lowercased() == "https" ? secureSession : session
            if let limit { (data, response) = try await delegate.data(selected, for: request, limit: limit, completeAfter: completeAfter) }
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

    /// A limited read (`data(_:for:limit:)`): the body so far, the call's budget, and who waits for the end.
    private struct Limited {
        var budget: FeedTransferBudget?
        var completeAfter: (@Sendable (Int) -> Int?)?
        /// Bytes after which this response ends successfully (`completeAfter`), and whether they have arrived.
        var completeAt: Int?
        var complete = false
        var body = Data()
        var response: URLResponse?
        var exceeded = false
        var waiter: CheckedContinuation<(Data, URLResponse), any Error>?
    }
    private let limited = Mutex(Limited())

    /// The response with a body that fits what is left of `budget`; every delivered chunk is charged to it as it
    /// arrives, and reading stops with `FeedBodyLimitExceeded` as soon as the body passes it (a declared length over
    /// it fails before any body).
    func data(_ session: URLSession, for request: URLRequest, limit budget: FeedTransferBudget,
              completeAfter: (@Sendable (Int) -> Int?)? = nil) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        task.delegate = self
        limited.withLock { $0.budget = budget; $0.completeAfter = completeAfter }
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
            let remaining = state.budget?.remaining ?? Int.max
            if let status = (response as? HTTPURLResponse)?.statusCode, let count = state.completeAfter?(status) {
                // Only `count` bytes are read, whatever the whole response's length.
                guard count <= remaining else { state.exceeded = true; return false }
                state.completeAt = count; state.complete = count == 0
                return true
            }
            guard response.expectedContentLength <= Int64(remaining) else { state.exceeded = true; return false }
            return true
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let stop: Bool = limited.withLock { state in
            // Every delivered chunk is charged whole, before anything is cut from it.
            guard !state.exceeded, !state.complete else { state.budget?.record(data.count); return false }
            if let count = state.completeAt {
                // Only the part up to `count` must fit; the chunk that crosses it was delivered and charged, and is kept
                // whole (a chapter list's prefix uses those bytes rather than paying for them again).
                let needed = min(data.count, count - state.body.count)
                do { try state.budget?.charge(data.count, needed: needed) }
                catch { state.exceeded = true; state.body = Data(); return true }
                state.body.append(data)
                state.complete = state.body.count >= count
                return state.complete
            }
            do { try state.budget?.charge(data.count) } catch { state.exceeded = true; state.body = Data(); return true }
            state.body.append(data)
            return false
        }
        if stop { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (waiter, result): (CheckedContinuation<(Data, URLResponse), any Error>?, Result<(Data, URLResponse), any Error>) = limited.withLock { state in
            let waiter = state.waiter
            state.waiter = nil
            if state.exceeded { return (waiter, .failure(FeedBodyLimitExceeded())) }
            if state.complete, let response = state.response { return (waiter, .success((state.body, response))) }
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

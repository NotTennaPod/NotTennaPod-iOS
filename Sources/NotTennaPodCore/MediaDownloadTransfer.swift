import Foundation
import Synchronization

/// Identity of bytes already accepted into a partial file. Weak tags and date-only
/// validators cannot establish byte-for-byte identity here.
public struct MediaDownloadRepresentation: Codable, Sendable, Equatable {
    public let resource: URL
    public let entityTag: String
    public let total: Int64?

    public init(resource: URL, entityTag: String, total: Int64? = nil) {
        self.resource = resource
        self.entityTag = entityTag
        self.total = total
    }

    var isValid: Bool {
        let bytes = Array(entityTag.utf8)
        return bytes.count >= 2 && bytes.first == 34 && bytes.last == 34
            && bytes.dropFirst().dropLast().allSatisfy { $0 == 33 || (35...126).contains($0) || $0 >= 128 }
            && (total.map { $0 >= 0 } ?? true)
            && ["http", "https"].contains(resource.scheme?.lowercased() ?? "")
            && resource.host != nil && resource.user == nil && resource.password == nil && resource.fragment == nil
    }
}

public struct MediaDownloadRequest: Sendable {
    public var source: String
    public var destination: URL
    public var credentials: FeedCredentials?
    public var networkConstraint: DownloadNetworkConstraint
    public var representation: MediaDownloadRepresentation?
    /// Called after any replacement truncation is synchronized, before body delivery.
    /// Failure prevents accepting bytes. Durable callers must fence obsolete attempts.
    public var acceptRepresentation: (@Sendable (MediaDownloadRepresentation?) async throws -> Void)?

    public init(source: String, destination: URL, credentials: FeedCredentials? = nil,
                networkConstraint: DownloadNetworkConstraint = .connected,
                representation: MediaDownloadRepresentation? = nil,
                acceptRepresentation: (@Sendable (MediaDownloadRepresentation?) async throws -> Void)? = nil) {
        self.source = source
        self.destination = destination
        self.credentials = credentials
        self.networkConstraint = networkConstraint
        self.representation = representation
        self.acceptRepresentation = acceptRepresentation
    }
}

public struct MediaDownloadProgress: Sendable, Equatable {
    public let received: Int64
    public let expected: Int64?
}

public struct MediaDownloadResult: Sendable, Equatable {
    public let destination: URL
    public let size: Int64
    public let validator: String?
    public var representation: MediaDownloadRepresentation? = nil
}

public enum MediaDownloadError: Error, Sendable, Equatable {
    case malformedURL
    case httpStatus(Int)
    case fileType
    case invalidRange
    case tooManyFollowUps
    case notEnoughSpace(required: Int64, available: Int64)
    case wrongSize(expected: Int64, received: Int64)
}

public final class MediaDownloadTransfer: Sendable {
    private let sessions = Mutex<MediaDownloadSessions?>(nil)
    private let proxyClient: @Sendable () -> ProxyNetworkEnvironment.Client
    private let userAgent: String
    private let availableCapacity: @Sendable (URL) throws -> Int64

    public init(userAgent: String = HTTPUserAgent.unversioned,
                proxyClient: (@Sendable () -> ProxyNetworkEnvironment.Client)? = nil,
                availableCapacity: @escaping @Sendable (URL) throws -> Int64 = { destination in
                    let attributes = try FileManager.default.attributesOfFileSystem(forPath: destination.deletingLastPathComponent().path)
                    return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                }) {
        let direct = ProxyNetworkEnvironment.Client(configuration: .init())
        self.proxyClient = proxyClient ?? { direct }
        self.userAgent = userAgent
        self.availableCapacity = availableCapacity
    }

    private func currentSessions() throws -> MediaDownloadSessions {
        let client = proxyClient()
        return try sessions.withLock { current in
            if let current, current.client == client { return current }
            let created = try MediaDownloadSessions(client: client)
            current = created
            return created
        }
    }

    public func download(_ input: MediaDownloadRequest,
                         progress: @escaping @Sendable (MediaDownloadProgress) -> Void = { _ in }) async throws -> MediaDownloadResult {
        do { return try await transfer(input, progress: progress) }
        catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func transfer(_ input: MediaDownloadRequest,
                          progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
        try Task.checkCancellation()
        guard input.destination.isFileURL, let original = try? FeedAddress.requestURL(input.source),
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            throw MediaDownloadError.malformedURL
        }
        var credentials = input.credentials
        if let user = components.user, !user.isEmpty || components.password != nil {
            credentials = components.password.map { FeedCredentials(username: user, password: $0) }
        } else if credentials?.username?.isEmpty != false && credentials?.password?.isEmpty != false {
            credentials = nil
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        guard let url = components.url else { throw MediaDownloadError.malformedURL }
        var exists = FileManager.default.fileExists(atPath: input.destination.path)
        var offset: Int64 = exists ? (try FileManager.default.attributesOfItem(atPath: input.destination.path)[.size] as? NSNumber)?.int64Value ?? 0 : 0
        var representation = input.representation.flatMap { $0.isValid ? $0 : nil }
        if representation == nil || representation?.total.map({ offset > $0 }) == true { offset = 0; representation = nil }
        var expectedTotal = offset > 0 ? representation?.total : nil
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.allowsExpensiveNetworkAccess = input.networkConstraint == .connected
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if url.scheme == "http" { request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests") }
        func applyRangeHeaders() {
            // Only the resource which issued this identity may interpret its tag.
            let resume = offset > 0 && request.url == representation?.resource
            request.setValue(resume ? "bytes=\(offset)-" : nil, forHTTPHeaderField: "Range")
            request.setValue(resume ? representation?.entityTag : nil, forHTTPHeaderField: "If-Range")
        }
        applyRangeHeaders()
        var authenticationAttempts = 0
        var previousStatus: Int?
        var followUps = 0
        // Source newCall captures one client for its entire redirect/auth chain.
        let selected = try currentSessions()
        defer { withExtendedLifetime(selected) {} }
        while followUps < 21 {
            followUps += 1
            try Task.checkCancellation()
            applyRangeHeaders()
            let requestedOffset = request.value(forHTTPHeaderField: "Range") == nil ? 0 : offset
            if request.url?.scheme?.lowercased() != "http" { request.setValue(nil, forHTTPHeaderField: "Proxy-Authorization") }
            let task = selected.session(for: request.url).dataTask(with: request)
            task.prefersIncrementalDelivery = true
            let response: HTTPURLResponse
            let result: MediaDownloadResult?
            do {
                (response, result) = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        task.delegate = MediaTransferDelegate(proxy: selected.proxy, input: input, exists: exists, offset: requestedOffset, expectedTotal: requestedOffset > 0 ? expectedTotal : nil, representation: requestedOffset > 0 ? representation : nil,
                                                              capacity: availableCapacity, progress: progress, continuation: continuation)
                        task.resume()
                    }
                } onCancel: { task.cancel() }
            } catch MediaTransferFollowUp.fullResponseRequired {
                try Task.checkCancellation()
                guard request.value(forHTTPHeaderField: "Range") != nil else { throw MediaDownloadError.invalidRange }
                // Keep the prefix untouched until a complete response is accepted.
                // Cache validators cannot validate an incomplete file as a full one.
                for field in ["Range", "If-Range", "If-None-Match", "If-Modified-Since"] {
                    request.setValue(nil, forHTTPHeaderField: field)
                }
                offset = 0
                expectedTotal = nil
                representation = nil
                continue
            }
            try Task.checkCancellation()
            let status = response.statusCode
            let lastStatus = previousStatus
            previousStatus = status
            if status == 407, request.value(forHTTPHeaderField: "Proxy-Authorization") == nil,
               selected.proxy.kind == .http, selected.proxy.isConfigured, request.url?.scheme?.lowercased() == "http",
               let username = selected.proxy.username, !username.isEmpty, let password = selected.proxy.password {
                request.setValue(FeedCredentials(username: username, password: password).authorization(utf8: false),
                                 forHTTPHeaderField: "Proxy-Authorization")
                continue
            }
            if status == 401, let credentials, authenticationAttempts < 2,
               let challengedURL = response.url, HTTPOrigin.matches(url, challengedURL) {
                request.url = response.url
                request.setValue(credentials.authorization(utf8: authenticationAttempts == 1), forHTTPHeaderField: "Authorization")
                authenticationAttempts += 1
                continue
            }
            if [408, 503].contains(status), lastStatus != status {
                let retry = response.value(forHTTPHeaderField: "Retry-After")
                if retry.map({ !$0.isEmpty && $0.allSatisfy { $0 == "0" } }) ?? (status == 408) { continue }
            }
            if [300, 301, 302, 303, 307, 308].contains(status), let responseURL = response.url,
               let location = response.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: responseURL)?.absoluteURL,
               ["http", "https"].contains(next.scheme?.lowercased() ?? "") {
                if !HTTPOrigin.matches(responseURL, next) { request.setValue(nil, forHTTPHeaderField: "Authorization") }
                guard var parts = URLComponents(url: next, resolvingAgainstBaseURL: false) else { throw MediaDownloadError.malformedURL }
                parts.user = nil
                parts.password = nil
                parts.fragment = nil
                request.url = parts.url
                continue
            }
            guard let result else { throw MediaDownloadError.httpStatus(status) }
            if status == 206 {
                let partial = try HTTPMediaPartialResponse(contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                    requestedOffset: requestedOffset, expectedTotal: expectedTotal, contentLength: response.expectedContentLength)
                if let total = partial.total, result.size < total {
                    // A valid response may contain only part of an open-ended range.
                    // Keep advancing instead of publishing an incomplete download.
                    representation = result.representation
                    expectedTotal = total
                    offset = result.size
                    exists = true
                    request.url = response.url
                    followUps = 0 // Only verified byte progress resets the follow-up bound.
                    continue
                }
            }
            return result
        }
        throw MediaDownloadError.tooManyFollowUps
    }
}

private enum MediaTransferFollowUp: Error { case fullResponseRequired }

private final class MediaTransferDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var response: HTTPURLResponse?
        var file: FileHandle?
        var received: Int64 = 0
        var expected: Int64?
        var responseEnd: Int64?
        var failure: (any Error)?
        var representation: MediaDownloadRepresentation?
        var acceptance: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let proxy: PodcastProxy
    private let input: MediaDownloadRequest
    private let exists: Bool
    private let offset: Int64
    private let expectedTotal: Int64?
    private let representation: MediaDownloadRepresentation?
    private let capacity: @Sendable (URL) throws -> Int64
    private let progress: @Sendable (MediaDownloadProgress) -> Void
    private let continuation: CheckedContinuation<(HTTPURLResponse, MediaDownloadResult?), any Error>

    init(proxy: PodcastProxy, input: MediaDownloadRequest, exists: Bool, offset: Int64, expectedTotal: Int64?, representation: MediaDownloadRepresentation?, capacity: @escaping @Sendable (URL) throws -> Int64,
         progress: @escaping @Sendable (MediaDownloadProgress) -> Void,
         continuation: CheckedContinuation<(HTTPURLResponse, MediaDownloadResult?), any Error>) {
        self.proxy = proxy; self.input = input
        self.exists = exists
        self.offset = offset
        self.expectedTotal = expectedTotal
        self.representation = representation
        self.capacity = capacity
        self.progress = progress
        self.continuation = continuation
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
            state.withLock { $0.response = response }
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else { completionHandler(.useCredential, nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let disposition: URLSession.ResponseDisposition = state.withLock { state in
            do {
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                state.response = response
                guard (200..<300).contains(response.statusCode) else { return .cancel }
                let length = response.value(forHTTPHeaderField: "Content-Length")
                if response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/") == true,
                   (length.flatMap(Int64.init) ?? -1) < 100 * 1024 { throw MediaDownloadError.fileType }
                let resume = response.statusCode == 206
                if resume {
                    guard offset > 0, let representation else { throw MediaDownloadError.invalidRange }
                    let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
                    guard encoding == nil || encoding == "identity" else { throw MediaTransferFollowUp.fullResponseRequired }
                    let partial = try HTTPMediaPartialResponse(contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                        requestedOffset: offset, expectedTotal: expectedTotal, contentLength: response.expectedContentLength)
                    // Without a total, this range cannot prove that the complete file was received.
                    guard let total = partial.total else { throw MediaTransferFollowUp.fullResponseRequired }
                    guard response.url == representation.resource,
                          response.value(forHTTPHeaderField: "ETag") == representation.entityTag else {
                        throw MediaTransferFollowUp.fullResponseRequired
                    }
                    state.representation = .init(resource: representation.resource, entityTag: representation.entityTag, total: total)
                    state.received = offset
                    state.expected = total
                    state.responseEnd = partial.bytes.upperBound
                } else {
                    state.received = 0
                    let decodedGzip = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() == "gzip"
                    state.expected = response.expectedContentLength >= 0 && !decodedGzip ? response.expectedContentLength : nil
                    state.responseEnd = state.expected
                    let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
                    if (encoding == nil || encoding == "identity"), let resource = response.url,
                       let tag = response.value(forHTTPHeaderField: "ETag") {
                        let identity = MediaDownloadRepresentation(resource: resource, entityTag: tag, total: state.expected)
                        state.representation = identity.isValid ? identity : nil
                    }
                }
                if !exists { try Data().write(to: input.destination, options: .withoutOverwriting) }
                let file = try FileHandle(forWritingTo: input.destination)
                state.file = file
                if resume { try file.seek(toOffset: UInt64(state.received)) }
                else {
                    // An interrupted metadata write must never label old bytes with a new identity.
                    try file.truncate(atOffset: 0)
                    try file.synchronize()
                }
                let available = try capacity(input.destination)
                if let expected = state.expected, expected - state.received > available {
                    throw MediaDownloadError.notEnoughSpace(required: expected - state.received, available: available)
                }
                return .allow
            } catch {
                state.failure = error
                return .cancel
            }
        }
        guard disposition == .allow else { completionHandler(disposition); return }
        state.withLock { state in
            let identity = state.representation
            let initial = MediaDownloadProgress(received: state.received, expected: state.expected)
            // Install under the same lock used by completion, so cancellation cannot
            // finish the transfer while its durable acceptance callback is still running.
            state.acceptance = Task {
                do {
                    try Task.checkCancellation()
                    guard dataTask.state != .canceling else { throw CancellationError() }
                    try await input.acceptRepresentation?(identity)
                    try Task.checkCancellation()
                    guard dataTask.state != .canceling else { throw CancellationError() }
                    progress(initial)
                    completionHandler(.allow)
                } catch {
                    self.state.withLock { $0.failure = error }
                    completionHandler(.cancel)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock { state in
            guard state.failure == nil, let file = state.file else { return }
            do {
                for start in stride(from: 0, to: data.count, by: 8192) {
                    if dataTask.state == .canceling { throw CancellationError() }
                    let chunk = data[start..<min(start + 8192, data.count)]
                    let (received, overflow) = state.received.addingReportingOverflow(Int64(chunk.count))
                    guard !overflow else { throw MediaDownloadError.invalidRange }
                    if let end = state.responseEnd, received > end {
                        throw MediaDownloadError.wrongSize(expected: end, received: received)
                    }
                    try file.write(contentsOf: chunk)
                    state.received = received
                    progress(.init(received: state.received, expected: state.expected))
                }
            } catch {
                state.failure = error
                dataTask.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let acceptance = state.withLock { $0.acceptance }
        if let acceptance {
            if error != nil { acceptance.cancel() }
            Task {
                await acceptance.value
                finish(error: error)
            }
        } else { finish(error: error) }
    }

    private func finish(error: (any Error)?) {
        let result: Result<(HTTPURLResponse, MediaDownloadResult?), any Error> = state.withLock { state in
            defer { try? state.file?.close(); state.file = nil; state.acceptance = nil }
            do {
                if let failure = state.failure { throw failure }
                guard let response = state.response else { throw error ?? URLError(.badServerResponse) }
                guard let file = state.file else { return .success((response, nil)) }
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if let expected = state.responseEnd, expected != state.received {
                    throw MediaDownloadError.wrongSize(expected: expected, received: state.received)
                }
                if let error { throw error }
                try file.synchronize()
                let size = (try FileManager.default.attributesOfItem(atPath: input.destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size == state.received else { throw MediaDownloadError.wrongSize(expected: state.received, received: size) }
                return .success((response, MediaDownloadResult(destination: input.destination, size: size,
                                                               validator: response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "Last-Modified"),
                                                               representation: state.representation)))
            } catch { return .failure(error) }
        }
        continuation.resume(with: result)
    }
}

/// Immutable paired sessions keep HTTP forward authentication out of HTTPS
/// origin headers. An in-flight task retains its pair across preference changes.
private final class MediaDownloadSessions: Sendable {
    let client: ProxyNetworkEnvironment.Client
    var proxy: PodcastProxy { client.configuration }
    private let plain: URLSession
    private let secure: URLSession
    init(client: ProxyNetworkEnvironment.Client) throws {
        self.client = client
        let proxy = client.configuration
        func make(_ scheme: String) throws -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
            configuration.httpMaximumConnectionsPerHost = 8; configuration.waitsForConnectivity = false
            try proxy.apply(to: configuration, scheme: scheme)
            return URLSession(configuration: configuration)
        }
        plain = try make("http")
        secure = proxy.isConfigured ? try make("https") : plain
    }
    func session(for url: URL?) -> URLSession { url?.scheme?.lowercased() == "https" ? secure : plain }
    deinit { plain.invalidateAndCancel(); if secure !== plain { secure.invalidateAndCancel() } }
}

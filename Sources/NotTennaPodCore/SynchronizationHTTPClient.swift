import Foundation
import CoreFoundation
import Synchronization

public struct SynchronizationHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol SynchronizationHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse
}

/// Each account has a private, in-memory cookie session. Gpodder authenticates
/// once with Basic and sends the resulting session cookie on subsequent calls.
public final class URLSessionSynchronizationTransport: SynchronizationHTTPTransport, Sendable {
    private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
        private struct Authentication { let value: String? }
        private let authentication = Mutex<Authentication?>(nil)
        private let rejected = Mutex<HTTPURLResponse?>(nil)
        var authenticationFailure: HTTPURLResponse? { rejected.withLock { $0 } }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            var next = request
            if let url = next.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                parts.user = nil; parts.password = nil
                next.url = parts.url
            }
            let sameOrigin = response.url.flatMap { source in next.url.map { HTTPOrigin.matches(source, $0) } } ?? false
            let value = authentication.withLock { state in
                let previous = state?.value ?? (state == nil ? task.originalRequest?.value(forHTTPHeaderField: "Authorization") : nil)
                let value = sameOrigin ? previous : nil
                state = Authentication(value: value)
                return value
            }
            // URLSession may remove this even for a same-origin redirect. Keep
            // source behavior, without restoring it after crossing an origin.
            next.setValue(value, forHTTPHeaderField: "Authorization")
            return next
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else if let response = challenge.failureResponse as? HTTPURLResponse, response.statusCode == 401 {
                rejected.withLock { $0 = response }
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else { completionHandler(.useCredential, nil) }
        }
    }
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
        let delegate = Redirects()
        let body: Data, response: URLResponse
        do { (body, response) = try await session.data(for: request, delegate: delegate) }
        catch {
            try Task.checkCancellation()
            guard let rejected = delegate.authenticationFailure else { throw error }
            body = Data(); response = rejected
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw SynchronizationError.invalidResponse }
        return .init(status: response.statusCode, body: body)
    }
}

/// Provider-specific wire behavior from release3.12.1. Credentials are ephemeral
/// inputs, deliberately not Codable or part of a library/preferences record.
public actor SynchronizationHTTPClient: SynchronizationProvider {
    public enum Backend: String, Codable, Sendable { case gpodder, nextcloud }
    private let backend: Backend
    private let base: URL
    private let username: String
    private let password: String
    private let device: String
    private let userAgent: String
    private let transport: any SynchronizationHTTPTransport
    private let clock: @Sendable () -> Date
    private var loggedIn = false

    public init(backend: Backend, host: String, username: String, password: String, device: String = "",
                userAgent: String = HTTPUserAgent.unversioned,
                transport: any SynchronizationHTTPTransport = URLSessionSynchronizationTransport(),
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        let explicitScheme = host.contains("://")
        guard var components = URLComponents(string: explicitScheme ? host : "https://" + host),
              let hostName = components.host, !hostName.isEmpty, ["http", "https"].contains(components.scheme),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else { throw SynchronizationError.invalidHost }
        // URLComponents reports nil for a numeric port larger than Int.max;
        // distinguish that malformed explicit port from an omitted port.
        guard components.rangeOfPort == nil || components.port != nil else { throw SynchronizationError.invalidHost }
        if !explicitScheme, components.port == 80 { components.scheme = "http" }
        guard let url = components.url else { throw SynchronizationError.invalidHost }
        base = url; self.backend = backend; self.username = username; self.password = password
        self.device = device; self.userAgent = userAgent; self.transport = transport; self.clock = clock
    }

    public func login() async throws {
        guard backend == .gpodder else { return }
        _ = try await request(["api", "2", "auth", username, "login.json"], method: "POST", body: Data(), authenticating: true)
        loggedIn = true
    }
    public func logout() async throws {
        // Both selected source implementations leave the session intact.
    }

    public func subscriptionChanges(since: Int64) async throws -> SynchronizationSubscriptionChanges {
        let data = try await request(subscriptionPath, since: since)
        let object = try jsonObject(data)
        guard let added = object["add"] as? [String], let removed = object["remove"] as? [String] else {
            throw SynchronizationError.invalidResponse
        }
        return try .init(added: added.map { $0.replacingOccurrences(of: "%3A", with: ":") },
            removed: removed.map { $0.replacingOccurrences(of: "%3A", with: ":") }, timestamp: timestamp(object))
    }

    public func uploadSubscriptions(added: [String], removed: [String]) async throws -> SynchronizationUploadResult {
        let path = backend == .gpodder ? subscriptionPath : nextcloudPath("subscription_change", "create")
        let body = try JSONSerialization.data(withJSONObject: ["add": added, "remove": removed])
        let data = try await request(path, method: "POST", body: body)
        return try uploadResult(data)
    }

    public func episodeChanges(since: Int64) async throws -> SynchronizationEpisodeChanges {
        let data = try await request(episodePath, since: since)
        let object = try jsonObject(data)
        guard let actions = object["actions"] as? [[String: Any]] else { throw SynchronizationError.invalidResponse }
        return try .init(actions: actions.compactMap(SynchronizationEpisodeAction.read), timestamp: timestamp(object))
    }

    /// Source uploads ordered batches of thirty, returning the last server cursor
    /// (gpodder) or local completion time (Nextcloud). Callers retain the queue if
    /// any batch fails; partial success is not reported as complete acceptance.
    public func uploadEpisodeActions(_ actions: [SynchronizationEpisodeAction]) async throws -> SynchronizationUploadResult? {
        try requireLogin()
        let objects = try actions.map { try $0.wireObject(device: backend == .gpodder ? device : nil) }
        var last: SynchronizationUploadResult?
        for start in stride(from: 0, to: objects.count, by: 30) {
            try Task.checkCancellation()
            let body = try JSONSerialization.data(withJSONObject: Array(objects[start..<min(start + 30, objects.count)]))
            let path = backend == .gpodder ? episodePath : nextcloudPath("episode_action", "create")
            let data = try await request(path, method: "POST", body: body)
            if backend == .gpodder { last = try uploadResult(data) }
        }
        return backend == .nextcloud ? .init(timestamp: Int64(clock().timeIntervalSince1970)) : last
    }

    public func devices() async throws -> [SynchronizationDevice] {
        guard backend == .gpodder else { throw SynchronizationError.unsupportedOperation }
        let data = try await request(["api", "2", "devices", username + ".json"])
        do { return try JSONDecoder().decode([SynchronizationDevice].self, from: data) }
        catch { throw SynchronizationError.invalidResponse }
    }

    public func configureDevice(id: String, caption: String?, type: String?) async throws {
        guard backend == .gpodder else { throw SynchronizationError.unsupportedOperation }
        var object: [String: String] = [:]
        if let caption { object["caption"] = caption }
        if let type { object["type"] = type }
        let body = object.isEmpty ? Data() : try JSONSerialization.data(withJSONObject: object)
        _ = try await request(["api", "2", "devices", username, id + ".json"], method: "POST", body: body)
    }

    private var subscriptionPath: [String] {
        backend == .gpodder ? ["api", "2", "subscriptions", username, device + ".json"] : nextcloudPath("subscriptions")
    }
    private var episodePath: [String] {
        backend == .gpodder ? ["api", "2", "episodes", username + ".json"] : nextcloudPath("episode_action")
    }
    private func nextcloudPath(_ parts: String...) -> [String] { ["index.php", "apps", "gpoddersync"] + parts }
    private func requireLogin() throws {
        if backend == .gpodder, !loggedIn { throw SynchronizationError.notLoggedIn }
    }

    private func request(_ path: [String], method: String = "GET", body: Data? = nil,
                         since: Int64? = nil, authenticating: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        if !authenticating { try requireLogin() }
        var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        var prefix = url.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        url.percentEncodedPath = prefix + "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        if let since { url.queryItems = [.init(name: "since", value: String(since))] }
        guard let destination = url.url else { throw SynchronizationError.invalidHost }
        var request = URLRequest(url: destination)
        request.httpMethod = method; request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue(authenticating ? "plain/text; charset=utf-8" : "application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if backend == .nextcloud { request.setValue("application/json", forHTTPHeaderField: "Accept") }
        if authenticating || backend == .nextcloud {
            let credentials = username + ":" + password
            let bytes = backend == .gpodder ? Data(credentials.utf8)
                : Data(credentials.unicodeScalars.map { $0.value <= 255 ? UInt8($0.value) : 63 })
            request.setValue("Basic " + bytes.base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.status == 200 else {
            if backend == .gpodder, response.status == 401 { throw SynchronizationError.authentication }
            throw SynchronizationError.httpStatus(response.status)
        }
        return response.body
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SynchronizationError.invalidResponse
        }
        return value
    }
    private func timestamp(_ object: [String: Any]) throws -> Int64 {
        if let number = object["timestamp"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.int64Value }
        if let value = object["timestamp"] as? String, let number = Int64(value) { return number }
        throw SynchronizationError.invalidResponse
    }
    private func uploadResult(_ data: Data) throws -> SynchronizationUploadResult {
        if backend == .nextcloud { return .init(timestamp: Int64(clock().timeIntervalSince1970)) }
        let object = try jsonObject(data)
        guard let pairs = object["update_urls"] as? [[String]], pairs.allSatisfy({ $0.count >= 2 }) else {
            throw SynchronizationError.invalidResponse
        }
        var urls: [String: String] = [:]
        for pair in pairs { urls[pair[0]] = pair[1] }
        return try .init(timestamp: timestamp(object), updatedURLs: urls)
    }
}

import Foundation

/// Transient Login Flow v2 state. The token grants access to an app password:
/// persist this only in a credential store, never preferences or activity data.
public struct NextcloudAuthenticationSession: Codable, Equatable, Sendable, CustomStringConvertible {
    public let rawHost: String
    public let token: String
    public let endpoint: URL
    public let expectedEpoch: UUID

    public init(rawHost: String, token: String, endpoint: URL, expectedEpoch: UUID) {
        self.rawHost = rawHost; self.token = token; self.endpoint = endpoint; self.expectedEpoch = expectedEpoch
    }
    public var description: String { "NextcloudAuthenticationSession(redacted)" }
}

public struct NextcloudAuthenticationChallenge: Sendable {
    public let login: URL
    public let token: String
    public let endpoint: URL
}

public struct NextcloudAuthenticationCredentials: Equatable, Sendable, CustomStringConvertible {
    public let server: String
    public let username: String
    public let password: String
    public var description: String { "NextcloudAuthenticationCredentials(redacted)" }
}

public enum NextcloudAuthenticationError: Error, Equatable, Sendable {
    case timedOut, browserUnavailable
}

/// The release's Nextcloud Login Flow v2 protocol. Login is an external browser
/// handoff; credentials are obtained by polling, without an app callback URL.
public struct NextcloudAuthenticationClient: Sendable {
    private let startURL: URL
    private let userAgent: String
    private let transport: any SynchronizationHTTPTransport

    public init(host: String, userAgent: String = HTTPUserAgent.unversioned,
                transport: any SynchronizationHTTPTransport = URLSessionSynchronizationTransport()) throws {
        // Use the same host policy as the provider that will consume the result.
        let explicitScheme = host.contains("://")
        guard var parts = URLComponents(string: explicitScheme ? host : "https://" + host),
              let name = parts.host, !name.isEmpty, ["http", "https"].contains(parts.scheme),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true,
              parts.rangeOfPort == nil || parts.port != nil else { throw SynchronizationError.invalidHost }
        if !explicitScheme, parts.port == 80 { parts.scheme = "http" }
        var prefix = parts.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        parts.percentEncodedPath = prefix + "/index.php/login/v2"
        guard let url = parts.url else { throw SynchronizationError.invalidHost }
        startURL = url; self.userAgent = userAgent; self.transport = transport
    }

    public func start() async throws -> NextcloudAuthenticationChallenge {
        let object = try await request(startURL, body: "")
        guard let login = object["login"] as? String, let loginURL = Self.webURL(login),
              let poll = object["poll"] as? [String: Any], let token = poll["token"] as? String,
              let endpoint = poll["endpoint"] as? String, let endpointURL = Self.webURL(endpoint) else {
            throw SynchronizationError.invalidResponse
        }
        return .init(login: loginURL, token: token, endpoint: endpointURL)
    }

    public func poll(_ session: NextcloudAuthenticationSession) async throws -> NextcloudAuthenticationCredentials {
        guard Self.webURL(session.endpoint.absoluteString) != nil else { throw SynchronizationError.invalidResponse }
        // The source sends its opaque provider token verbatim after "token=".
        let object = try await request(session.endpoint, body: "token=" + session.token)
        guard let server = object["server"] as? String, let username = object["loginName"] as? String,
              let password = object["appPassword"] as? String else { throw SynchronizationError.invalidResponse }
        return .init(server: server, username: username, password: password)
    }

    /// A failed request, non-200 status or malformed response retries after one
    /// second. Timeout covers the entire polling interval, including a request
    /// that never returns. Restored source flows begin a new five-minute window.
    public func authorize(_ session: NextcloudAuthenticationSession,
                          sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws -> NextcloudAuthenticationCredentials {
        try await withThrowingTaskGroup(of: NextcloudAuthenticationCredentials.self) { group in
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    do { return try await poll(session) }
                    catch {
                        try Task.checkCancellation()
                        try await sleep(.seconds(1))
                    }
                }
            }
            group.addTask {
                try await sleep(.seconds(300))
                try Task.checkCancellation()
                throw NextcloudAuthenticationError.timedOut
            }
            defer { group.cancelAll() }
            guard let credentials = try await group.next() else { throw CancellationError() }
            return credentials
        }
    }

    private static func webURL(_ string: String) -> URL? {
        guard let parts = URLComponents(string: string), ["http", "https"].contains(parts.scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    private func request(_ url: URL, body: String) async throws -> [String: Any] {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.status == 200 else { throw SynchronizationError.httpStatus(response.status) }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw SynchronizationError.invalidResponse
        }
        return object
    }
}

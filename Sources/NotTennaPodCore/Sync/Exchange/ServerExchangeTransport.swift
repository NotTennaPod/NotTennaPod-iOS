import Foundation

/// What a sync request can answer besides success (PROTOCOL §10, §6.4).
public enum ServerExchangeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No answer: no network, the host is unknown, refused or timed out.
    case unreachable
    /// An answer that is not a NotTennaPod server's (not protocol JSON).
    case notAServer
    /// An error body `{error, message, retry_after?, missing?}` with its HTTP status.
    case server(status: Int, code: String, retryAfter: Int?)
    /// No usable token: sync waits for the person to sign in again (PROTOCOL §15.4).
    case noToken
    /// The network may not be used for sync now: mobile data while the "Synchronization" mobile-data preference does
    /// not allow it. Nothing was sent; sync waits for a permitted network.
    case networkNotPermitted

    public var description: String {
        switch self {
        case .unreachable: "the server is unreachable"
        case .notAServer: "not a NotTennaPod server's answer"
        case .server(let status, let code, _): "HTTP \(status) \(code)"
        case .noToken: "no token"
        case .networkNotPermitted: "the network may not be used for sync now"
        }
    }

    public var code: String? { if case .server(_, let code, _) = self { code } else { nil } }
    public var status: Int? { if case .server(let status, _, _) = self { status } else { nil } }
    public var retryAfter: Int? { if case .server(_, _, let wait) = self { wait } else { nil } }
}

/// The exchange's requests (PROTOCOL §6.8): `POST /v1/push`, `POST /v1/pull`, `POST /v1/snapshot` and
/// `GET /v1/secrets/{id}`, each with the current installation's token. The account client and token
/// store are adapted to it; tests give it a server process directly.
public protocol ServerExchangeTransport: Sendable {
    /// Sends a protocol request (`body` canonical JSON, or no body for GET) and returns the decoded answer. Throws
    /// `ServerExchangeError` for anything else.
    func send(_ method: String, _ path: String, body: ContractJSON?) async throws -> ContractJSON
}

extension ServerExchangeTransport {
    func push(_ body: ContractJSON) async throws -> ContractJSON { try await send("POST", "v1/push", body: body) }
    func pull(_ body: ContractJSON) async throws -> ContractJSON { try await send("POST", "v1/pull", body: body) }
    func snapshot(_ body: ContractJSON) async throws -> ContractJSON { try await send("POST", "v1/snapshot", body: body) }
    func secret(_ id: String) async throws -> ContractJSON { try await send("GET", "v1/secrets/\(id)", body: nil) }
}

/// The app's transport: HTTP through the synchronization transport (so proxy settings apply as for gpodder.net),
/// with `NotTennaPod-Protocol: 1` and the token the provider gives at each request. Bodies are never logged.
public struct HTTPServerExchangeTransport: ServerExchangeTransport {
    public let base: URL
    private let transport: any SynchronizationHTTPTransport
    private let token: @Sendable () async throws -> String?
    private let userAgent: String
    private let network: (any ServerSyncNetworkGate)?

    /// `network`: every request first checks that sync may use the network now, and asks the system not to use an
    /// expensive (mobile) network unless the "Synchronization" mobile-data preference allows it.
    public init(base: URL, transport: any SynchronizationHTTPTransport = URLSessionSynchronizationTransport(),
                userAgent: String = HTTPUserAgent.unversioned, network: (any ServerSyncNetworkGate)? = nil,
                token: @escaping @Sendable () async throws -> String?) {
        self.base = base; self.transport = transport; self.token = token; self.userAgent = userAgent; self.network = network
    }

    public func send(_ method: String, _ path: String, body: ContractJSON?) async throws -> ContractJSON {
        if let network, await !network.permitted() { throw ServerExchangeError.networkNotPermitted }
        guard let token = try await token() else { throw ServerExchangeError.noToken }
        var request = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 60)
        if let network { request.allowsExpensiveNetworkAccess = await network.allowsMobile() }
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "NotTennaPod-Protocol")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if method == "GET" { request.setValue("no-store", forHTTPHeaderField: "Cache-Control") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.canonicalData()
        }
        let response: SynchronizationHTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw ServerExchangeError.unreachable
        }
        // The logout cut-off (PROTOCOL §15.4): a response that arrives after the exchange was stopped
        // is discarded without anything being written, so a change whose answer is lost stays unconfirmed.
        try Task.checkCancellation()
        return try Self.decode(status: response.status, body: response.body)
    }

    /// A 2xx protocol JSON object, or the error its body names.
    static func decode(status: Int, body: Data) throws -> ContractJSON {
        let decoded = try? ContractJSON.decode(body)
        guard (200..<300).contains(status) else {
            guard let code = decoded?["error"]?.stringValue else { throw ServerExchangeError.notAServer }
            throw ServerExchangeError.server(status: status, code: code,
                                             retryAfter: decoded?["retry_after"]?.integerValue.map { Int(clamping: $0) })
        }
        guard let decoded, decoded.objectValue != nil else { throw ServerExchangeError.notAServer }
        return decoded
    }
}

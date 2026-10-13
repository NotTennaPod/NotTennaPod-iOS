import Foundation

/// What the phone tells the server about itself at sign-in and after an app update (PROTOCOL §15.4).
public struct ServerDevice: Codable, Equatable, Sendable {
    public var name: String
    public var platform: String
    public var appVersion: String
    public var capabilities: [String]

    /// Every capability ships at once (PROTOCOL §15.4).
    public static let capabilities = ["favorites", "history", "inbox", "queue", "statistics"]

    public init(name: String, platform: String = "ios", appVersion: String, capabilities: [String] = ServerDevice.capabilities) {
        self.name = name; self.platform = platform; self.appVersion = appVersion; self.capabilities = capabilities
    }

    /// "NotTennaPod on iPhone" or "NotTennaPod on iPad", with the bundle's version.
    public static func current(model: String, bundle: Bundle = .main) -> ServerDevice {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return ServerDevice(name: "NotTennaPod on " + model, appVersion: build.map { "\(short) (\($0))" } ?? short)
    }

    var json: ContractJSON {
        ["name": .string(name), "platform": .string(platform), "app_version": .string(appVersion),
         "capabilities": .array(capabilities.map(ContractJSON.string))]
    }

    private enum CodingKeys: String, CodingKey { case name, platform, capabilities, appVersion = "app_version" }
}

/// `GET /v1/info`: the server's identity, the protocol version both sides speak and the advertised bounds.
public struct ServerInfo: Equatable, Sendable {
    public var serverID: String
    public var protocolVersion: Int
    public var bounds: ContractJSON?
}

/// `POST /v1/auth/device`'s answer.
public struct ServerSignIn: Equatable, Sendable {
    public var token: String
    public var installID: String
    public var accountID: String
    public var namespace: String
    public var username: String
}

/// Every outcome a person can be told about in plain words (PROTOCOL §15.5), plus the protocol answers the flows act on.
public enum ServerClientError: Error, Equatable, Sendable {
    case invalidAddress
    /// No answer: no network, the host is unknown, refused, timed out, or TLS failed.
    case unreachable
    /// An answer that is not a NotTennaPod server's (not JSON, or not its shape).
    case notAServer
    case serverNeedsUpdate
    case appNeedsUpdate
    /// 401 on sign-in: the username or password is wrong.
    case wrongCredentials
    /// 401 on an authenticated request: the token is no longer accepted (revoked, expired, the server restored).
    case unauthorized
    /// 403: the account is disabled or may not do this.
    case forbidden
    /// 429 `rate_limited`; the server's wait in seconds.
    case rateLimited(retryAfter: Int?)
    /// 503 `server_busy`; the server's wait in seconds.
    case busy(retryAfter: Int?)
    /// 409 `installation_conflict`: the installation ID is held by another physical install (PROTOCOL §6.10).
    case installationConflict
    /// 409 `installation_superseded`.
    case installationSuperseded
    /// 410 `view_expired`: a snapshot page of a view that no longer exists.
    case viewExpired
    /// Any other answer, with the server's error code.
    case server(status: Int, code: String?)

    /// The token is no longer usable: sync pauses and the page asks to sign in again (PROTOCOL §5, §15.4).
    public var rejectsCredentials: Bool { self == .unauthorized || self == .forbidden }
}

/// The phone's HTTP client for the account endpoints (PROTOCOL §15.4): `/v1/info`, `/v1/auth/device`,
/// sign-out, `/v1/installations` and the attach snapshot. Requests are JSON with `NotTennaPod-Protocol: 1`; it uses
/// the synchronization transport, so proxy settings apply as for gpodder.net. Never logs bodies: they hold passwords
/// and tokens.
public struct ServerClient: Sendable {
    public static let protocolVersions = 1...1
    public let address: ServerAddress
    private let transport: any SynchronizationHTTPTransport
    private let userAgent: String

    public init(address: ServerAddress, transport: any SynchronizationHTTPTransport = URLSessionSynchronizationTransport(),
                userAgent: String = HTTPUserAgent.unversioned) {
        self.address = address; self.transport = transport; self.userAgent = userAgent
    }

    // MARK: - Endpoints

    public func info() async throws -> ServerInfo {
        let answer = try await send("GET", "v1/info")
        guard let id = answer["server_id"]?.stringValue, !id.isEmpty,
              let low = answer["protocol"]?["min"]?.integerValue, let high = answer["protocol"]?["max"]?.integerValue,
              low <= high else { throw ServerClientError.notAServer }
        // The highest version both speak; none: whichever side is older needs updating (PROTOCOL §10).
        let common = min(Int(high), Self.protocolVersions.upperBound)
        guard common >= max(Int(low), Self.protocolVersions.lowerBound) else {
            throw Int(high) < Self.protocolVersions.lowerBound ? ServerClientError.serverNeedsUpdate : ServerClientError.appNeedsUpdate
        }
        return ServerInfo(serverID: id, protocolVersion: common, bounds: answer["bounds"])
    }

    public func signIn(username: String, password: String, installID: String, transportNonce: String,
                       device: ServerDevice) async throws -> ServerSignIn {
        let body: ContractJSON = ["username": .string(username), "password": .string(password),
                                  "install_id": .string(installID), "instance_nonce": .string(transportNonce),
                                  "device": device.json]
        let answer = try await send("POST", "v1/auth/device", body: body, signingIn: true)
        guard let token = answer["token"]?.stringValue, !token.isEmpty,
              let install = answer["install_id"]?.stringValue, install == installID,
              let account = answer["account"]?["account_id"]?.stringValue, ContractIdentity.isUUID(account),
              let namespace = answer["account"]?["namespace"]?.stringValue, ContractIdentity.isUUID(namespace) else {
            throw ServerClientError.notAServer
        }
        return ServerSignIn(token: token, installID: install, accountID: account, namespace: namespace,
                            username: answer["account"]?["username"]?.stringValue ?? username)
    }

    /// Best effort: the caller forgets the token whatever happens.
    public func signOut(token: String) async throws {
        _ = try await send("POST", "v1/auth/device/sign-out", body: .object(ContractObject()), token: token)
    }

    /// The installations of the account: a read that also checks that the token is still accepted.
    public func installations(token: String) async throws -> [ContractJSON] {
        try await send("GET", "v1/installations", token: token)["installations"]?.arrayValue ?? []
    }

    /// `PUT /v1/installations/self` after the app version or capabilities changed (PROTOCOL §15.4).
    public func updateInstallation(token: String, device: ServerDevice) async throws {
        _ = try await send("PUT", "v1/installations/self", body: [
            "app_version": .string(device.appVersion), "capabilities": .array(device.capabilities.map(ContractJSON.string))],
            token: token)
    }

    /// One page of a snapshot (PROTOCOL §6.4): the request's first page, or the page a token names.
    public func snapshotPage(token: String, installID: String, page: String?) async throws -> ContractJSON {
        var body: ContractObject = ["mode": "attach", "install_id": .string(installID), "acked_install_seq": 0]
        if let page { body["page"] = .string(page) }
        return try await send("POST", "v1/snapshot", body: .object(body), token: token)
    }

    // MARK: - Transport

    func send(_ method: String, _ path: String, body: ContractJSON? = nil, token: String? = nil,
              signingIn: Bool = false) async throws -> ContractJSON {
        var request = URLRequest(url: address.endpoint(path), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "NotTennaPod-Protocol")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.canonicalData()
        }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let response: SynchronizationHTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw ServerClientError.unreachable
        }
        let decoded = try? ContractJSON.decode(response.body)
        guard (200..<300).contains(response.status) else {
            throw Self.failure(status: response.status, body: decoded, signingIn: signingIn)
        }
        guard let decoded, decoded.objectValue != nil else { throw ServerClientError.notAServer }
        return decoded
    }

    static func failure(status: Int, body: ContractJSON?, signingIn: Bool) -> ServerClientError {
        // A NotTennaPod server answers every error as `{error, message}`; anything else is another server.
        guard let code = body?["error"]?.stringValue else { return .notAServer }
        let wait = body?["retry_after"]?.integerValue.map { Int(clamping: $0) }
        switch (status, code) {
        case (401, _): return signingIn ? .wrongCredentials : .unauthorized
        case (403, _): return .forbidden
        case (429, _): return .rateLimited(retryAfter: wait)
        case (503, _): return .busy(retryAfter: wait)
        case (409, "installation_conflict"): return .installationConflict
        case (409, "installation_superseded"): return .installationSuperseded
        case (410, "view_expired"): return .viewExpired
        case (_, "version_unsupported"): return .appNeedsUpdate
        default: return .server(status: status, code: code)
        }
    }
}

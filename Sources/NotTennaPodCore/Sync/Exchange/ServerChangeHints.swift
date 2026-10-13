import Foundation

/// Why the change-hint stream ended.
public enum ServerChangeHintError: Error, Equatable, Sendable {
    /// The server has no event stream for devices (an older server): the phone polls instead.
    case unsupported
    /// The server refused the token, or closed the stream because the token stopped being valid: the next exchange
    /// finds out why (a pause for "Sign in again").
    case rejected
    /// Any other answer.
    case failed(status: Int)
}

/// The server's change hints: each `changed` event names the account's head; the phone pulls when it is not its own.
public protocol ServerChangeHintSource: Sendable {
    /// Opens the stream. It yields heads until the connection ends (finishing or throwing).
    func hints() -> AsyncThrowingStream<ServerHead, any Error>
}

/// `GET /v1/events` (PROTOCOL §12) with the installation's device token: server-sent events, a `changed` event
/// with the head at once and after every commit, heartbeats every 25 s, `closed` when the token stops being valid.
/// Proxy settings apply as for every synchronization request.
public struct ServerEventStream: ServerChangeHintSource {
    let url: URL
    let proxy: PodcastProxy?
    let userAgent: String
    let token: @Sendable () async throws -> String?
    /// The longest silence before the connection counts as lost (heartbeats come every 25 s).
    let idleTimeout: TimeInterval

    /// Whether the stream may use an expensive (mobile) network (the "Synchronization" mobile-data preference).
    let allowsMobile: @Sendable () async -> Bool

    public init(base: URL, proxy: PodcastProxy? = nil, userAgent: String = HTTPUserAgent.unversioned, idleTimeout: TimeInterval = 75,
                allowsMobile: @escaping @Sendable () async -> Bool = { true }, token: @escaping @Sendable () async throws -> String?) {
        url = base.appendingPathComponent("v1/events")
        self.proxy = proxy; self.userAgent = userAgent; self.idleTimeout = idleTimeout; self.token = token
        self.allowsMobile = allowsMobile
    }

    public func hints() -> AsyncThrowingStream<ServerHead, any Error> {
        let url = url, proxy = proxy, userAgent = userAgent, token = token, idle = idleTimeout, allowsMobile = allowsMobile
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let token = try await token() else { throw ServerChangeHintError.rejected }
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = idle
                    configuration.urlCache = nil
                    configuration.urlCredentialStorage = nil
                    configuration.waitsForConnectivity = false
                    // The system refuses (and ends) the stream on an expensive network sync may not use.
                    configuration.allowsExpensiveNetworkAccess = await allowsMobile()
                    if let proxy, proxy.isConfigured { try proxy.apply(to: configuration, scheme: url.scheme ?? "https") }
                    let session = URLSession(configuration: configuration)
                    defer { session.invalidateAndCancel() }
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: idle)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                    request.setValue("1", forHTTPHeaderField: "NotTennaPod-Protocol")
                    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    switch status {
                    case 200..<300: break
                    case 404, 405, 501: throw ServerChangeHintError.unsupported
                    case 401, 403: throw ServerChangeHintError.rejected
                    default: throw ServerChangeHintError.failed(status: status)
                    }
                    var parser = ServerSentEventParser()
                    for try await byte in bytes {
                        guard let event = parser.feed(byte) else { continue }
                        switch event.name {
                        case "changed":
                            if let head = Self.head(event.data) { continuation.yield(head) }
                        case "closed":
                            throw ServerChangeHintError.rejected
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `{"log_id", "epoch", "seq"}`.
    static func head(_ data: String) -> ServerHead? {
        guard let json = try? ContractJSON.decode(Array(data.utf8)), let log = json["log_id"]?.stringValue,
              let epoch = json["epoch"]?.integerValue, let seq = json["seq"]?.integerValue else { return nil }
        return ServerHead(logID: log, epoch: epoch, seq: seq)
    }
}

/// Server-sent events (WHATWG HTML §9.2) fed byte by byte: lines end with LF, CRLF or CR; `event` and `data` fields
/// (several data lines joined by LF), comments ignored, a blank line dispatches.
struct ServerSentEventParser {
    struct Event: Equatable { var name: String; var data: String }
    private var line: [UInt8] = []
    private var name = ""
    private var data: [String] = []
    private var afterCR = false

    mutating func feed(_ byte: UInt8) -> Event? {
        if afterCR {
            afterCR = false
            if byte == 0x0A { return nil }
        }
        switch byte {
        case 0x0A: return endLine()
        case 0x0D: afterCR = true; return endLine()
        default: line.append(byte); return nil
        }
    }

    private mutating func endLine() -> Event? {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else {
            defer { name = ""; data = [] }
            guard !data.isEmpty || !name.isEmpty else { return nil }
            return Event(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))
        }
        let text = String(decoding: line, as: UTF8.self)
        guard !text.hasPrefix(":") else { return nil }
        var field = text, value = ""
        if let colon = text.firstIndex(of: ":") {
            field = String(text[..<colon])
            value = String(text[text.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        }
        switch field {
        case "event": name = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}

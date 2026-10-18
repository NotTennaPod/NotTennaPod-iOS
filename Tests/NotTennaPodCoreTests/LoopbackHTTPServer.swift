import Foundation
import Network
import Synchronization

final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body = Data("<rss><channel><title>Network podcast</title><item><title>Episode</title></item></channel></rss>".utf8)
        var keepConnectionOpen = false
        var includeAutomaticContentLength = true
        /// Paced delivery: the body is written `pace` bytes at a time, each write after the previous one was taken and
        /// a millisecond's pause, so the client receives it in small pieces rather than in socket-buffer-sized ones.
        var pace: Int? = nil
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "AntennaPodTests.Loopback")
    private let recorded = Mutex<[Request]>([])
    private let sentResponses = Mutex(0)
    private let held = Mutex<[String: [NWConnection]]>([:])
    var heldRequestPaths: Set<String> { held.withLock { Set($0.keys) } }

    func respond(toPath path: String, with response: Response) throws {
        // Drain after any handler already returning nil has registered its owner.
        let connections = queue.sync { held.withLock { $0.removeValue(forKey: path) ?? [] } }
        guard !connections.isEmpty else { throw URLError(.cannotConnectToHost) }
        for connection in connections { send(response, to: connection) }
    }
    private let connections = Mutex<[NWConnection]>([])
    private let byPath = Mutex<[String: NWConnection]>([:])

    /// Continue the response on the connection that carried the latest request for `path`
    /// (a response sent with `keepConnectionOpen`).
    func appendResponseBody(_ data: Data, toLatestRequestFor path: String, isFinal: Bool) async throws {
        guard let connection = byPath.withLock({ $0[path] }) else { throw URLError(.cannotConnectToHost) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: isFinal ? .finalMessage : .defaultMessage, isComplete: true,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }
    private let handler: @Sendable (Request) -> Response?
    private let onClientDisconnect: (@Sendable () -> Void)?

    var requests: [Request] { recorded.withLock { $0 } }
    /// Fixture synchronization: request receipt precedes sending its response.
    var sentResponseCount: Int { sentResponses.withLock { $0 } }

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/feed")! }

    private init(onClientDisconnect: (@Sendable () -> Void)?, handler: @escaping @Sendable (Request) -> Response?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
        self.onClientDisconnect = onClientDisconnect
    }

    static func start(onClientDisconnect: (@Sendable () -> Void)? = nil, handler: @escaping @Sendable (Request) -> Response?) async throws -> LoopbackHTTPServer {
        let server = try LoopbackHTTPServer(onClientDisconnect: onClientDisconnect, handler: handler)
        server.listener.newConnectionHandler = { [weak server] connection in
            guard let server else { connection.cancel(); return }
            server.connections.withLock { $0.append(connection) }
            connection.start(queue: server.queue)
            server.read(connection, accumulated: Data())
        }
        let resumed = Mutex(false)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                server.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if !resumed.withLock({ let previous = $0; $0 = true; return previous }) { continuation.resume() }
                    case .failed(let error):
                        if !resumed.withLock({ let previous = $0; $0 = true; return previous }) { continuation.resume(throwing: error) }
                    default: break
                    }
                }
                server.listener.start(queue: server.queue)
            }
        } catch {
            server.stop()
            throw error
        }
        return server
    }

    func stop() {
        listener.cancel()
        held.withLock { $0.removeAll() }
        let active = connections.withLock { let active = $0; $0 = []; return active }
        for connection in active { connection.cancel() }
    }

    /// Continue a held response. Select its connection explicitly when a test also
    /// opens range requests; existing single-connection tests retain their assertion.
    func appendResponseBody(_ data: Data, toConnectionAt index: Int? = nil, isFinal: Bool = false) async throws {
        let active = connections.withLock { $0 }
        let connection: NWConnection
        if let index {
            guard active.indices.contains(index) else { throw URLError(.cannotConnectToHost) }
            connection = active[index]
        } else {
            guard active.count == 1, let only = active.first else { throw URLError(.cannotConnectToHost) }
            connection = only
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: isFinal ? .finalMessage : .defaultMessage, isComplete: true,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let buffer = accumulated + (data ?? Data())
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete, error == nil, buffer.count < 1_048_576 { self.read(connection, accumulated: buffer) }
                else { connection.cancel() }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
            guard first.count == 3 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard length >= 0, length <= 8_388_608 else { connection.cancel(); return }
            guard buffer.count - end.upperBound >= length else {
                if !complete, error == nil { self.read(connection, accumulated: buffer) }
                else { connection.cancel() }
                return
            }
            let request = Request(method: first[0], path: first[1], headers: headers,
                                  body: Data(buffer[end.upperBound..<(end.upperBound + length)]))
            recorded.withLock { $0.append(request) }
            byPath.withLock { $0[request.path] = connection }
            if onClientDisconnect != nil { observeDisconnect(connection) }
            guard let response = handler(request) else {
                held.withLock { $0[request.path, default: []].append(connection) }; return
            }
            send(response, to: connection)
        }
    }
    private func send(_ response: Response, to connection: NWConnection) {
        var output = "HTTP/1.1 \(response.status) Test\r\nConnection: \(response.keepConnectionOpen ? "keep-alive" : "close")\r\n"
        if response.includeAutomaticContentLength,
           !response.headers.keys.contains(where: { $0.lowercased() == "content-length" || $0.lowercased() == "transfer-encoding" }) {
            output += "Content-Length: \(response.body.count)\r\n"
        }
        for (key, value) in response.headers { output += "\(key): \(value)\r\n" }
        output += "\r\n"
        if let pace = response.pace, pace > 0 {
            sendPaced(Data(output.utf8), body: response.body, pace: pace, keepOpen: response.keepConnectionOpen, to: connection)
            return
        }
        let declared = response.headers.first { $0.key.lowercased() == "content-length" }.flatMap { Int($0.value) }
        if !response.keepConnectionOpen, let declared, declared > response.body.count {
            // A truncated body: on a real network the bytes arrive and the connection drops afterwards.
            // When the close reaches URLSession in the same read as the bytes (loopback), URLSession reports
            // "connection lost" and drops those bytes before any delegate call (seen: a response,
            // then -1005 with no didReceive data), which is not what the code under test handles in practice.
            connection.send(content: Data(output.utf8) + response.body, contentContext: .defaultMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] error in
                if error != nil { connection.cancel(); return }
                self?.sentResponses.withLock { $0 += 1 }
                self?.queue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                    connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                }
            })
            return
        }
        connection.send(content: Data(output.utf8) + response.body, contentContext: response.keepConnectionOpen ? .defaultMessage : .finalMessage,
                        isComplete: true, completion: .contentProcessed { [weak self] error in
            if error != nil { connection.cancel() }
            else { self?.sentResponses.withLock { $0 += 1 } }
        })
    }
    private func sendPaced(_ head: Data, body: Data, pace: Int, keepOpen: Bool, to connection: NWConnection) {
        connection.send(content: head, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            if error != nil { connection.cancel(); return }
            self?.sendPiece(body, from: body.startIndex, pace: pace, keepOpen: keepOpen, to: connection)
        })
    }
    private func sendPiece(_ body: Data, from index: Data.Index, pace: Int, keepOpen: Bool, to connection: NWConnection) {
        guard index < body.endIndex else {
            sentResponses.withLock { $0 += 1 }
            if !keepOpen { connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent) }
            return
        }
        let end = min(body.endIndex, index + pace)
        connection.send(content: body[index..<end], contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            // A client that left ends the response.
            guard error == nil, let self else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(1)) { self.sendPiece(body, from: end, pace: pace, keepOpen: keepOpen, to: connection) }
        })
    }
    private func observeDisconnect(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil { onClientDisconnect?() }
            else { observeDisconnect(connection) }
        }
    }
}

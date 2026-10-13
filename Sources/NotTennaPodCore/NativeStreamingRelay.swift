import Foundation
import Network
import Synchronization

/// A playback-owned HTTP endpoint. Upstream bytes use the captured application proxy;
/// AVFoundation retains native playlist/open-ended parsing and playback.
///
/// iOS may defunct a suspended app's sockets, including this listener, which then still
/// reports ready. The relay can therefore be retired (listener and every connection
/// closed) and reopened on a new listener and port; its route (upstream URL, proxy,
/// credentials, user agent) stays. Each listener generation is a separate worker whose
/// callbacks end when it is retired, so a retired one can never affect its replacement.
public final class NativeStreamingRelay: Sendable {
    private struct Route: Sendable {
        let url: URL
        let playlist: Bool
        let proxy: PodcastProxy
        let authentication: PlaybackHTTPAuthentication?
        let endpoint: NativeRelayEndpoint
        let userAgent: String
        let onInterruption: (@Sendable (Error) -> Void)?
        let onFailure: @Sendable (Error) -> Void
    }
    private struct State {
        var worker: Worker?
        var url: URL
        var generation: UInt64 = 1
        /// The listener being started; `token` is unique, so a superseded start never installs.
        var opening: (token: UInt64, task: Task<(url: URL, generation: UInt64), any Error>)?
        var openings: UInt64 = 0
        var cancelled = false
#if DEBUG
        var reclaimsReplacements = false
#endif
    }
    private let route: Route
    private let state: Mutex<State>
    /// The current listener's address; a reopened relay advertises a new one.
    public var url: URL { state.withLock { $0.url } }
    /// The listener generation `url` belongs to.
    var generation: UInt64 { state.withLock { $0.generation } }
    /// Retired: no listener until the next `reopen`.
    var isRetired: Bool { state.withLock { $0.worker == nil && !$0.cancelled } }
    private init(route: Route, worker: Worker, url: URL) {
        self.route = route
        state = Mutex(State(worker: worker, url: url))
    }
    public static func start(url: URL, playlist: Bool, proxy: PodcastProxy, credentials: FeedCredentials? = nil,
                      endpoint: NativeRelayEndpoint = .loopback,
                      userAgent: String = HTTPUserAgent.unversioned,
                      onInterruption: (@Sendable (Error) -> Void)? = nil,
                      onFailure: @escaping @Sendable (Error) -> Void = { _ in }) async throws -> NativeStreamingRelay {
        let route = Route(url: url, playlist: playlist, proxy: proxy,
            authentication: PlaybackHTTPAuthentication(url: url, credentials: credentials), endpoint: endpoint,
            userAgent: userAgent, onInterruption: onInterruption, onFailure: onFailure)
        let (worker, local) = try await open(route)
        return NativeStreamingRelay(route: route, worker: worker, url: local)
    }
    private static func open(_ route: Route) async throws -> (Worker, URL) {
        let worker = try Worker(endpoint: route.endpoint, proxy: route.proxy, authentication: route.authentication,
                                userAgent: route.userAgent, onInterruption: route.onInterruption, onFailure: route.onFailure)
        do {
            try await worker.start()
            return (worker, try worker.register(route.url, playlist: route.playlist, variables: [:]))
        } catch { worker.cancel(); throw error }
    }
    public func cancel() {
        let (worker, opening) = state.withLock { state in
            state.cancelled = true
            defer { state.worker = nil; state.opening = nil }
            return (state.worker, state.opening?.task)
        }
        opening?.cancel(); worker?.cancel()
    }
    /// Closes the listener and every connection, including a transfer held by back
    /// pressure, but keeps the route for `reopen`. A late callback of the closed
    /// listener is dropped.
    func retire() {
        let (worker, opening) = state.withLock { state in
            defer { state.worker = nil; state.opening = nil }
            return (state.worker, state.opening?.task)
        }
        opening?.cancel(); worker?.cancel()
    }
    /// A listener on a new port (`.any`), started at most once for concurrent callers. A
    /// retired relay always gets a new one, never trusting the old listener's readiness;
    /// `stale` also replaces the current one while it is still that generation (a local
    /// connection failure). Throws if the caller or the relay was cancelled, or it was retired meanwhile.
    func reopen(replacing stale: UInt64? = nil) async throws -> (url: URL, generation: UInt64) {
        enum Next { case current(URL, UInt64), join(Task<(url: URL, generation: UInt64), any Error>) }
        let (next, replaced) = try state.withLock { state throws -> (Next, Worker?) in
            // Checked under the lock: a caller cancelled before a `retire()` never starts a listener after it.
            guard !state.cancelled, !Task.isCancelled else { throw CancellationError() }
            if let opening = state.opening { return (.join(opening.task), nil) }
            var replaced: Worker?
            if let worker = state.worker {
                guard let stale, stale == state.generation else { return (.current(state.url, state.generation), nil) }
                replaced = worker; state.worker = nil
            }
            state.openings &+= 1
            let token = state.openings, route = route
            let task = Task<(url: URL, generation: UInt64), any Error> {
                let (worker, local) = try await Self.open(route)
#if DEBUG
                if self.state.withLock({ $0.reclaimsReplacements }) { worker.defunct() }
#endif
                let generation = self.state.withLock { state -> UInt64? in
                    guard !state.cancelled, state.opening?.token == token else { return nil }
                    state.generation &+= 1
                    state.worker = worker; state.url = local; state.opening = nil
                    return state.generation
                }
                guard let generation else { worker.cancel(); throw CancellationError() }
                return (local, generation)
            }
            state.opening = (token, task)
            return (.join(task), replaced)
        }
        replaced?.cancel()
        switch next {
        case let .current(url, generation): return (url, generation)
        case let .join(task): return try await task.value
        }
    }
    /// Only an active lease for this exact advertised media URL authorizes adoption.
    public func owns(_ candidate: URL) -> Bool {
        state.withLock { candidate == $0.url && !$0.cancelled && $0.worker != nil }
    }
    var snapshot: (cancelled: Bool, activeRequests: Int, deferredRequests: Int) {
        let (worker, cancelled) = state.withLock { ($0.worker, $0.cancelled) }
        guard let worker else { return (cancelled, 0, 0) }
        let value = worker.snapshot
        return (cancelled || value.cancelled, value.activeRequests, value.deferredRequests)
    }
#if DEBUG
    /// Test hook: what iOS does to a suspended app's sockets. Closes only the current
    /// listener and its connections; the relay still believes it is listening. With
    /// `includingReplacements`, every listener opened later is closed the same way.
    func simulateSocketReclaim(includingReplacements: Bool = false) {
        state.withLock { state in
            if includingReplacements { state.reclaimsReplacements = true }
            return state.worker
        }?.defunct()
    }
#endif
    deinit {
        let (worker, opening) = state.withLock { ($0.worker, $0.opening?.task) }
        opening?.cancel(); worker?.cancel()
    }

    private final class Worker: @unchecked Sendable {
        /// AVFoundation may retire a probe/range request without retiring playback.
        private struct ClientDisconnected: Error {}
        private struct State {
            var cancelled = false
            var transfers: [UUID: (NWConnection, Task<Void, Never>)] = [:]
            var deferred: [UUID: CheckedContinuation<Void, Error>] = [:]
        }
        private let state = Mutex(State())
        private let listener: NWListener
        private let queue = DispatchQueue(label: "AntennaPod.NativeStreamingRelay")
        private let token = UUID().uuidString
        private let routes = NativeRelayRoute()
        private let endpoint: NativeRelayEndpoint
        private let proxy: PodcastProxy
        private let authentication: PlaybackHTTPAuthentication?
        private let userAgent: String
        private let onFailure: @Sendable (Error) -> Void
        private let onInterruption: (@Sendable (Error) -> Void)?
        private let plain: URLSessionConfiguration
        private let secure: URLSessionConfiguration
        private let delegate: RelaySessionDelegate
        init(endpoint: NativeRelayEndpoint, proxy: PodcastProxy, authentication: PlaybackHTTPAuthentication?, userAgent: String,
             onInterruption: (@Sendable (Error) -> Void)?, onFailure: @escaping @Sendable (Error) -> Void) throws {
            self.endpoint = endpoint
            self.proxy = proxy; self.authentication = authentication; self.userAgent = userAgent; self.onFailure = onFailure
            self.onInterruption = onInterruption
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(endpoint.address), port: .any)
            listener = try NWListener(using: parameters)
            delegate = RelaySessionDelegate(proxy: proxy)
            func make(_ scheme: String) throws -> URLSessionConfiguration {
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
                // Match media-read inactivity, without limiting total streaming duration.
                config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = .greatestFiniteMagnitude
                config.waitsForConnectivity = false
                try proxy.apply(to: config, scheme: scheme)
                return config
            }
            plain = try make("http"); secure = proxy.isConfigured ? try make("https") : plain
        }
        func start() async throws {
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                state.withLock { state in
                    guard !state.cancelled else { connection.cancel(); return }
                    let id = UUID()
                    connection.start(queue: queue)
                    state.transfers[id] = (connection, Task { [self] in
                        defer { connection.cancel(); _ = self.state.withLock { $0.transfers.removeValue(forKey: id) } }
                        do { try await serve(connection, id: id) }
                        catch is ClientDisconnected { }
                        catch { if !Task.isCancelled { deliver { self.onFailure(error) } } }
                    })
                }
            }
            let resumed = Mutex(false)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    listener.stateUpdateHandler = { state in
                        let result: Result<Void, Error>?
                        switch state {
                        case .ready: result = .success(())
                        case .failed(let error): result = .failure(error)
                        case .cancelled: result = .failure(CancellationError())
                        default: result = nil
                        }
                        if let result, !resumed.withLock({ let old = $0; $0 = true; return old }) { continuation.resume(with: result) }
                    }
                    listener.start(queue: queue)
                }
                try Task.checkCancellation()
            } onCancel: { self.cancel() }
        }
        private func watchForDisconnect(_ connection: NWConnection, id: UUID) {
            // Each local connection serves one GET/HEAD and advertises Connection: close.
            // Keep receiving while upstream is suspended so a retired native request
            // also cancels its upstream task, even before any response bytes arrive.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak connection] _, _, ended, error in
                guard let self, let connection else { return }
                if ended || error != nil {
                    let task = state.withLock { $0.transfers[id]?.1 }
                    task?.cancel(); connection.cancel()
                } else { watchForDisconnect(connection, id: id) }
            }
        }
        func cancel() {
            let transfers = state.withLock { value in
                value.cancelled = true
                let active = value.transfers; value.transfers.removeAll(); return active
            }
            listener.cancel()
            for (connection, task) in transfers.values { task.cancel(); connection.cancel() }
        }
        /// Owner callbacks run under the state lock, so none can follow `cancel()`.
        private func deliver(_ callback: () -> Void) {
            state.withLock { if !$0.cancelled { callback() } }
        }
#if DEBUG
        /// The listener and connections close as a reclaim closes them; nothing is marked cancelled.
        func defunct() {
            let transfers = state.withLock { value in
                let active = value.transfers; value.transfers.removeAll(); return active
            }
            listener.cancel()
            for (connection, task) in transfers.values { task.cancel(); connection.cancel() }
        }
#endif
        var snapshot: (cancelled: Bool, activeRequests: Int, deferredRequests: Int) {
            state.withLock { ($0.cancelled, $0.transfers.count, $0.deferred.count) }
        }
        private func waitForRetirement(id: UUID) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    state.withLock {
                        if $0.cancelled || Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { $0.deferred[id] = continuation }
                    }
                }
            } onCancel: {
                let continuation = self.state.withLock { $0.deferred.removeValue(forKey: id) }
                continuation?.resume(throwing: CancellationError())
            }
        }
        func register(_ url: URL, playlist: Bool, variables: [String: String]) throws -> URL {
            guard let port = listener.port else { throw URLError(.cannotConnectToHost) }
            guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
            let route = try routes.encode(.init(url: url, playlist: playlist, variables: variables))
            return try endpoint.url(port: port.rawValue, path: "\(token)/\(route)")
        }
        private func read(_ connection: NWConnection) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, ended, error in
                    if error != nil { continuation.resume(throwing: ClientDisconnected()) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: ClientDisconnected()) }
                }
            }
        }
        private func send(_ data: Data, to connection: NWConnection) async throws {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: ClientDisconnected()) } else { continuation.resume() }
                })
            }
        }
        private func serve(_ connection: NWConnection, id: UUID) async throws {
            var requestData = Data()
            while requestData.range(of: Data("\r\n\r\n".utf8)) == nil {
                requestData.append(try await read(connection))
                guard requestData.count <= 65536 else { throw ClientDisconnected() }
            }
            let lines = String(decoding: requestData, as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, ["GET", "HEAD", "OPTIONS"].contains(String(first[0])),
                  let local = URLComponents(string: String(first[1])) else { throw ClientDisconnected() }
            let parts = local.path.split(separator: "/")
            guard parts.count == 2, parts[0] == token,
                  let resource = try? routes.decode(String(parts[1])) else { throw ClientDisconnected() }
            if first[0] == "OPTIONS" {
                guard endpoint.receiver else { throw ClientDisconnected() }
                try await send(Data((["HTTP/1.1 204 No Content", "Connection: close"] + corsHeaders
                    + ["Access-Control-Allow-Methods: GET, HEAD, OPTIONS",
                       "Access-Control-Allow-Headers: Range, If-Range, If-None-Match, If-Modified-Since, Content-Type",
                       "Content-Length: 0"]).joined(separator: "\r\n").appending("\r\n\r\n").utf8), to: connection)
                return
            }
            // A receiver may add HLS blocking-reload parameters, but cannot use
            // a signed route to replace the publisher's query or credentials.
            if endpoint.receiver, let added = local.queryItems, !added.isEmpty {
                guard resource.playlist, added.allSatisfy({ ["_HLS_msn", "_HLS_part", "_HLS_skip"].contains($0.name) })
                else { throw ClientDisconnected() }
            }
            watchForDisconnect(connection, id: id)
            var address = URLComponents(url: resource.url, resolvingAgainstBaseURL: false)!
            if let added = local.queryItems {
                address.queryItems = (address.queryItems ?? []).filter { old in !added.contains { $0.name == old.name } } + added
            }
            var upstream = URLRequest(url: address.url!)
            upstream.httpMethod = String(first[0]); upstream.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for line in lines.dropFirst() {
                guard let separator = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<separator]).lowercased()
                if ["range", "if-range", "if-none-match", "if-modified-since"].contains(key) {
                    upstream.setValue(String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: key)
                }
            }
            if onInterruption != nil, !resource.playlist {
                // A selected unknown-duration source reconnects to the current live
                // stream, never to a previous byte offset (including native probes).
                upstream.setValue(nil, forHTTPHeaderField: "Range")
                upstream.setValue(nil, forHTTPHeaderField: "If-Range")
            }
            if let authentication, HTTPOrigin.matches(authentication.origin, upstream.url!) {
                upstream.setValue(authentication.authorization, forHTTPHeaderField: "Authorization")
            }
            let bytes = try await fetch(upstream)
            defer { bytes.cancel() }
            let response = bytes.response
            let mime = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let playlist = resource.playlist || mime.contains("mpegurl")
            if playlist, response.statusCode == 200, upstream.httpMethod != "HEAD" {
                var body = Data()
                while let chunk = try await bytes.next() {
                    body.append(chunk)
                    guard body.count <= 16 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                }
                let rewritten = try HLSRelayPlaylist.rewrite(body, base: response.url!, inherited: resource.variables) { url, playlist, variables in
                    try self.register(url, playlist: playlist, variables: variables)
                }
                try await send(headers(response, length: rewritten.count, playlist: true), to: connection)
                try await send(rewritten, to: connection)
                return
            }
            let length = response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil
            try await send(headers(response, length: length, playlist: false), to: connection)
            guard upstream.httpMethod != "HEAD" else { return }
            func emit(_ data: Data) async throws {
                if length == nil { try await send(Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8), to: connection) }
                else { try await send(data, to: connection) }
            }
            // Preserve the selected AVPlayer interruption path's existing 4 KiB
            // delivery contract until its replacement owns buffered recovery. Native
            // failed-to-end can invalidate a paused buffer even while its status and
            // loaded ranges still claim readiness. Prompt delivery is used by the
            // independent MP3 source and playlist/raw consumers instead.
            let retainsNativeDelivery = onInterruption != nil && length == nil && !playlist
            var pending = Data()
            do {
                while let chunk = try await bytes.next() {
                    if retainsNativeDelivery {
                        pending.append(chunk)
                        while pending.count >= 4096 {
                            try await emit(Data(pending.prefix(4096)))
                            pending.removeFirst(4096)
                        }
                    } else { try await emit(chunk) }
                }
                if !pending.isEmpty { try await emit(pending); pending.removeAll() }
            } catch {
                if !pending.isEmpty, !Task.isCancelled {
                    try await emit(pending); pending.removeAll()
                }
                guard !Task.isCancelled, !state.withLock({ $0.cancelled }),
                      length == nil, !playlist, response.statusCode == 200,
                      let interruption = onInterruption, let network = error as? URLError,
                      [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                       .cannotFindHost, .dnsLookupFailed].contains(network.code) else { throw error }
                // Deliver every received byte, then keep the local response open so
                // AVPlayer can consume its buffer without treating a network break as EOF.
                deliver { interruption(error) }
                try await waitForRetirement(id: id)
                return
            }
            if length == nil { try await send(Data("0\r\n\r\n".utf8), to: connection) }
        }
        private var corsHeaders: [String] {
            // The lease URL is the capability. Receiver requests need no cookies
            // or publisher credentials; those stay with the upstream owner.
            endpoint.receiver ? ["Access-Control-Allow-Origin: *",
                "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges, Content-Type, ETag, Last-Modified"] : []
        }
        private func headers(_ response: HTTPURLResponse, length: Int?, playlist: Bool) -> Data {
            var lines = ["HTTP/1.1 \(response.statusCode) Response", "Connection: close"] + corsHeaders
            if let length { lines.append("Content-Length: \(length)") } else { lines.append("Transfer-Encoding: chunked") }
            for field in ["Content-Type", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified", "Cache-Control", "Expires", "Retry-After"] {
                if playlist && ["Content-Type", "ETag", "Last-Modified"].contains(field) { continue }
                if let value = response.value(forHTTPHeaderField: field), !value.contains("\r"), !value.contains("\n") { lines.append("\(field): \(value)") }
            }
            if playlist { lines.append("Content-Type: application/vnd.apple.mpegurl") }
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        }
        private func fetch(_ original: URLRequest) async throws -> NativeRelayBody {
            var request = original, proxyAttempted = false
            for _ in 0...20 {
                try Task.checkCancellation()
                guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
                let configuration = url.scheme?.lowercased() == "https" ? secure : plain
                if url.scheme?.lowercased() != "http" { request.setValue(nil, forHTTPHeaderField: "Proxy-Authorization") }
                else if proxyAttempted, let username = proxy.username, let password = proxy.password {
                    request.setValue(FeedCredentials(username: username, password: password).authorization(utf8: false), forHTTPHeaderField: "Proxy-Authorization")
                }
                let bytes = try await NativeRelayBody.open(request: request, configuration: configuration, delegate: delegate)
                let http = bytes.response
                if http.statusCode == 407, !proxyAttempted, proxy.isConfigured, proxy.kind == .http, url.scheme?.lowercased() == "http",
                   let username = proxy.username, !username.isEmpty, proxy.password != nil {
                    proxyAttempted = true; bytes.cancel(); continue
                }
                if [301,302,303,307,308].contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
                   let next = URL(string: location, relativeTo: url)?.absoluteURL,
                   var components = URLComponents(url: next, resolvingAgainstBaseURL: false) {
                    bytes.cancel(); components.user = nil; components.password = nil; components.fragment = nil
                    if !HTTPOrigin.matches(url, next) { request.setValue(nil, forHTTPHeaderField: "Authorization") }
                    request.url = components.url; continue
                }
                if http.statusCode == 401 || http.statusCode == 407 {
                    bytes.cancel(); throw MediaDownloadError.httpStatus(http.statusCode)
                }
                return bytes
            }
            throw URLError(.httpTooManyRedirects)
        }
    }
}
final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let proxy: PodcastProxy
    init(proxy: PodcastProxy) { self.proxy = proxy }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.isProxy(), let credential = proxy.credential(for: challenge) { completionHandler(.useCredential, credential) }
        else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.rejectProtectionSpace, nil) }
    }
}

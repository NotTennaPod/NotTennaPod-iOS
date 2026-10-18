import Foundation

/// A transcript load: what can be shown now, whether an asked-for refresh is still owed, and what the network fetch
/// waits for when it could not run (`AuxiliaryNetworkAdmission`). A denial is never a result: nothing is cached for it.
public struct TranscriptLoad: Equatable, Sendable {
    public let transcript: EpisodeTranscript?
    /// A forced refresh that could not run yet; the retry must be forced too.
    public let refreshPending: Bool
    public let deferred: AuxiliaryNetworkAdmission.Wake?
    public init(transcript: EpisodeTranscript?, refreshPending: Bool = false, deferred: AuxiliaryNetworkAdmission.Wake? = nil) {
        self.transcript = transcript; self.refreshPending = refreshPending; self.deferred = deferred
    }
}

/// TranscriptUtils' local sidecar / cached response / forced-network precedence.
/// The shared transport retains configured proxy ownership and redirect behavior. A remote miss needs the admission
/// for small metadata ("Cover images", or an unrestricted network) and is bounded by its byte budget.
public actor TranscriptLoader {
    private let transport: RedirectingProxyTransport
    private let cache: URLCache
    private let userAgent: String
    public nonisolated let admission: AuxiliaryNetworkAdmission
    /// Over the restricted budget: these wait for an unrestricted network (no permission releases them).
    private var awaitingUnrestricted: Set<String> = []
    /// Over the unrestricted budget: not fetched again this session.
    private var refused: Set<String> = []

    public init(transport: any FeedHTTPTransport, cache: URLCache, userAgent: String, admission: AuxiliaryNetworkAdmission) {
        self.transport = RedirectingProxyTransport(transport: transport); self.cache = cache; self.userAgent = userAgent
        self.admission = admission
    }

    /// Tests: every fetch admitted, on the unrestricted budget.
    init(transport: any FeedHTTPTransport, cache: URLCache, userAgent: String) {
        self.init(transport: transport, cache: cache, userAgent: userAgent, admission: .unrestricted)
    }

    /// The transcript, or `AuxiliaryNetworkDenied` when its fetch must wait (`loadTranscript` keeps what can be shown).
    public func load(_ descriptor: FeedTranscript, localMediaPath: String? = nil, forceRefresh: Bool = false) async throws -> EpisodeTranscript {
        let load = try await loadTranscript(descriptor, localMediaPath: localMediaPath, forceRefresh: forceRefresh)
        if let deferred = load.deferred, load.transcript == nil || load.refreshPending { throw AuxiliaryNetworkDenied(wake: deferred) }
        guard let transcript = load.transcript else { throw URLError(.resourceUnavailable) }
        return transcript
    }

    /// The sidecar or cached transcript without a request; otherwise the network, when admitted. A denied forced
    /// refresh keeps showing what was there, with `refreshPending`, and makes no request.
    public func loadTranscript(_ descriptor: FeedTranscript, localMediaPath: String? = nil, forceRefresh: Bool = false) async throws -> TranscriptLoad {
        try Task.checkCancellation()
        let request = try request(descriptor)
        let local = try localText(descriptor, localMediaPath: localMediaPath, request: request)
        if !forceRefresh, let local { return .init(transcript: try TranscriptParser.parse(local, format: descriptor.format)) }
        // What a refresh that cannot run yet keeps showing.
        func held(_ wake: AuxiliaryNetworkAdmission.Wake) throws -> TranscriptLoad {
            .init(transcript: local.flatMap { try? TranscriptParser.parse($0, format: descriptor.format) },
                  refreshPending: forceRefresh, deferred: wake)
        }
        let key = descriptor.url
        if refused.contains(key) { throw FeedBodyLimitExceeded() }
        if awaitingUnrestricted.contains(key) {
            guard let state = try await admission.allowance(.smallMetadata), !state.restricted else { return try held(.unrestricted) }
            awaitingUnrestricted.remove(key)
        }
        guard let allowance = try await admission.allowance(.smallMetadata) else { return try held(.permitted(.smallMetadata)) }
        let text: String
        do {
            var constrained = request
            allowance.constrain(&constrained)
            text = try await admission.perform(allowance) { [constrained] in try await self.remoteText(constrained, bytes: allowance.bytes) }
        }
        catch is DownloadNetworkInterruption { return try held(.permitted(.smallMetadata)) }
        catch is FeedBodyLimitExceeded {
            overBudget(key, restricted: allowance.restricted)
            if allowance.restricted { return try held(.unrestricted) }
            throw FeedBodyLimitExceeded()
        }
        return .init(transcript: try TranscriptParser.parse(text, format: descriptor.format))
    }

    /// Download completion stores the original text even when its parser rejects it, under the download's own network
    /// constraint (a Wi-Fi-only download never fetches its transcript over mobile data) and the budget of the network
    /// it runs on. The URL's earlier budget outcomes hold here too, and its own are kept for the transcript screen: a
    /// transcript over the restricted budget waits for an unrestricted network, one over the unrestricted budget is
    /// not fetched again this session. The media worker owns this write and waits for cancellation before deletion.
    public func storeSidecar(_ descriptor: FeedTranscript, media: URL, constraint: DownloadNetworkConstraint,
                             network: DownloadNetworkMonitor) async throws {
        guard media.isFileURL else { throw FeedLibraryError.invalidLocation }
        let request = try request(descriptor)
        let restricted = network.current.map { !$0.connected || $0.restricted } ?? true
        let bytes = restricted ? AuxiliaryNetworkAdmission.restrictedByteLimit : AuxiliaryNetworkAdmission.smallMetadataByteLimit
        let key = descriptor.url
        if refused.contains(key) { throw FeedBodyLimitExceeded() }
        if awaitingUnrestricted.contains(key) {
            if restricted { throw FeedBodyLimitExceeded() }
            awaitingUnrestricted.remove(key)
        }
        var constrained = request
        AuxiliaryNetworkAdmission.Allowance(bytes: bytes, restricted: restricted, pathLocked: constraint == .unmetered).constrain(&constrained)
        let text: String
        do { text = try await network.perform(under: constraint) { [constrained] in try await self.remoteText(constrained, bytes: bytes) } }
        catch is FeedBodyLimitExceeded { overBudget(key, restricted: restricted); throw FeedBodyLimitExceeded() }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: media.path) else { throw CocoaError(.fileNoSuchFile) }
        try Data(text.utf8).write(to: URL(fileURLWithPath: media.path + ".transcript"), options: .atomic)
    }

    /// Over the restricted budget: wait for an unrestricted network. Over the unrestricted one: refused this session.
    private func overBudget(_ key: String, restricted: Bool) {
        if restricted { awaitingUnrestricted.insert(key) } else { refused.insert(key) }
    }

    private func request(_ descriptor: FeedTranscript) throws -> URLRequest {
        guard let url = URL(string: descriptor.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// The sidecar beside downloaded media, else a usable cached response.
    private func localText(_ descriptor: FeedTranscript, localMediaPath: String?, request: URLRequest) throws -> String? {
        if let localMediaPath {
            let file = localMediaPath.hasPrefix("file:") ? URL(string: localMediaPath) : URL(fileURLWithPath: localMediaPath)
            if let file, file.isFileURL,
               let text = try? String(contentsOf: URL(fileURLWithPath: file.path + ".transcript"), encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        if let cached = cache.cachedResponse(for: request), let response = cached.response as? HTTPURLResponse,
           (200..<300).contains(response.statusCode), let text = Self.text(cached.data, contentType: response.value(forHTTPHeaderField: "Content-Type")), text.utf16.count > 1 {
            return text
        }
        return nil
    }

    /// One bounded network read (one `FeedTransferBudget` across redirects and proxy-login retries); nothing over
    /// the budget is cached.
    private func remoteText(_ base: URLRequest, bytes: Int) async throws -> String {
        try Task.checkCancellation()
        var request = base
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let response = try await transport.send(request, bodyLimit: bytes)
        try Task.checkCancellation()
        guard (200..<300).contains(response.status) else { throw URLError(.badServerResponse) }
        guard let text = Self.text(response.body, contentType: response.header("Content-Type")), !text.isEmpty else { throw TranscriptParseError.invalidDocument }
        // FORCE_CACHE may reuse a stale cacheable response. no-store remains binding.
        if !(response.header("Cache-Control") ?? "").lowercased().contains("no-store"),
           let http = HTTPURLResponse(url: response.url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) {
            var key = base
            key.setValue(nil, forHTTPHeaderField: "Cache-Control")
            key.allowsExpensiveNetworkAccess = true; key.allowsConstrainedNetworkAccess = true
            cache.storeCachedResponse(CachedURLResponse(response: http, data: response.body), for: key)
        }
        return text
    }

    private static func text(_ data: Data, contentType: String?) -> String? {
        if data.starts(with: [0xFF,0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE,0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        let charset = contentType?.split(separator: ";").dropFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.first { $0.hasPrefix("charset=") }?.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let encoding: String.Encoding = ["iso-8859-1", "latin1"].contains(charset ?? "") ? .isoLatin1 : .utf8
        guard var text = String(data: data, encoding: encoding) else { return nil }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        return text
    }
}

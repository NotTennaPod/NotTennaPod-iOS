import Foundation

/// A chapter load: the chapters available now, and what each part that could not be fetched waits for
/// (`AuxiliaryNetworkAdmission`). A deferred part is never cached as "no chapters".
public struct EpisodeChapterLoad: Equatable, Sendable {
    public let chapters: [ParsedChapter]
    public let deferred: Set<AuxiliaryNetworkAdmission.Wake>
    public init(chapters: [ParsedChapter], deferred: Set<AuxiliaryNetworkAdmission.Wake> = []) {
        self.chapters = chapters; self.deferred = deferred
    }
}

/// Loads source-owned chapter lists in the release's order. Callers retain the
/// returned list on the playable, and leave it nil after interruption so a later
/// presentation can retry. Network/media lifetime stays outside the view.
public actor EpisodeChapterLoader {
    private let transport: RedirectingProxyTransport
    private let cache: URLCache
    private let userAgent: String
    /// External chapter JSON is small metadata: "Cover images", or an unrestricted network.
    public nonisolated let admission: AuxiliaryNetworkAdmission
    /// Over the restricted budget: these wait for an unrestricted network (no permission releases them).
    private var awaitingUnrestricted: Set<String> = []
    /// Over the unrestricted budget: not fetched again this session.
    private var refused: Set<String> = []

    public init(transport: any FeedHTTPTransport, cache: URLCache, userAgent: String, admission: AuxiliaryNetworkAdmission) {
        self.transport = RedirectingProxyTransport(transport: transport)
        self.cache = cache; self.userAgent = userAgent; self.admission = admission
    }

    /// Tests: every fetch admitted, on the unrestricted budget.
    init(transport: any FeedHTTPTransport, cache: URLCache, userAgent: String) {
        self.init(transport: transport, cache: cache, userAgent: userAgent, admission: .unrestricted)
    }

    /// Chapters read from episode media, by what decides them: the cover and the seek bar each
    /// reloaded on every play, pause and buffering change, which for a stream meant two ranged downloads
    /// each time. One read serves both, and later reloads of the same media; a refresh reads again.
    /// Interrupted reads are not kept, so a later reload retries.
    private var mediaResults: [(identity: EpisodeChapterIdentity, chapters: [ParsedChapter]?)] = []
    /// A read in flight lives as long as it has a consumer. A same-episode reload that joins within `retireDelay`
    /// keeps it; when the last consumer has left (the surface closed, or moved to another episode) it is cancelled,
    /// and its request with it. A read for other media retires orphaned reads at once.
    private struct MediaRead {
        let identity: EpisodeChapterIdentity
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<[ParsedChapter]?, any Error>] = [:]
        var retire: Task<Void, Never>?
    }
    private var mediaReads: [UUID: MediaRead] = [:]
    private(set) var mediaReadCount = 0
    var retireDelay: Duration = .milliseconds(500)
    func setRetireDelay(_ delay: Duration) { retireDelay = delay }
    /// Tests: the consumers awaiting reads in flight.
    var mediaConsumerCount: Int { mediaReads.values.reduce(0) { $0 + $1.waiters.count } }
    /// Media whose chapter list is known not to fit the restricted budget: no read until the network is
    /// unrestricted (never kept as a result).
    private var mediaAwaitingUnrestricted: [EpisodeChapterIdentity] = []

    func mediaChapters(_ identity: EpisodeChapterIdentity, forceRefresh: Bool,
                       read: @escaping @Sendable () async throws -> [ParsedChapter]?) async throws -> [ParsedChapter]? {
        if !forceRefresh, let hit = mediaResults.last(where: { $0.identity == identity }) { return hit.chapters }
        if mediaAwaitingUnrestricted.contains(identity) {
            guard try await admission.isUnrestricted() else { throw AuxiliaryNetworkDenied(wake: .unrestricted) }
            mediaAwaitingUnrestricted.removeAll { $0 == identity }
        }
        try Task.checkCancellation()
        let key: UUID
        if !forceRefresh, let running = mediaReads.first(where: { $0.value.identity == identity })?.key {
            key = running
            mediaReads[key]?.retire?.cancel(); mediaReads[key]?.retire = nil
        } else {
            // Reads orphaned by a move to other media stop now.
            for (other, entry) in mediaReads where entry.identity != identity && entry.waiters.isEmpty { retire(other) }
            key = UUID()
            mediaReadCount += 1
            mediaReads[key] = MediaRead(identity: identity)
            mediaReads[key]?.task = Task { [weak self] in
                let result: Result<[ParsedChapter]?, any Error>
                do { result = .success(try await read()) } catch { result = .failure(error) }
                await self?.finish(key, result)
            }
        }
        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || mediaReads[key] == nil { continuation.resume(throwing: CancellationError()); return }
                mediaReads[key]?.waiters[consumer] = continuation
            }
        } onCancel: {
            Task { await self.leave(key, consumer) }
        }
    }

    private func finish(_ key: UUID, _ result: Result<[ParsedChapter]?, any Error>) {
        guard let entry = mediaReads.removeValue(forKey: key) else { return }
        entry.retire?.cancel()
        switch result {
        case .success(let chapters):
            mediaResults.removeAll { $0.identity == entry.identity }
            mediaResults.append((entry.identity, chapters))
            if mediaResults.count > 8 { mediaResults.removeFirst(mediaResults.count - 8) }
        case .failure(let error):
            if (error as? AuxiliaryNetworkDenied)?.wake == .unrestricted, !mediaAwaitingUnrestricted.contains(entry.identity) {
                mediaAwaitingUnrestricted.append(entry.identity)
            }
        }
        for waiter in entry.waiters.values { waiter.resume(with: result) }
    }

    private func leave(_ key: UUID, _ consumer: UUID) {
        mediaReads[key]?.waiters.removeValue(forKey: consumer)?.resume(throwing: CancellationError())
        guard let entry = mediaReads[key], entry.waiters.isEmpty, entry.retire == nil else { return }
        let delay = retireDelay
        if delay <= .zero { retire(key); return }
        mediaReads[key]?.retire = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            await self?.retireIfOrphaned(key)
        }
    }

    private func retireIfOrphaned(_ key: UUID) {
        guard let entry = mediaReads[key], entry.waiters.isEmpty else { return }
        retire(key)
    }

    /// Cancels the read; a later consumer starts a new one.
    private func retire(_ key: UUID) {
        guard let entry = mediaReads.removeValue(forKey: key) else { return }
        entry.retire?.cancel(); entry.task?.cancel()
        for waiter in entry.waiters.values { waiter.resume(throwing: CancellationError()) }
    }

    public func load(stored: [ParsedChapter]?, loaded: [ParsedChapter]? = nil,
                     externalURL: String?, forceRefresh: Bool = false,
                     mediaChapters: @Sendable () async throws -> [ParsedChapter]?) async throws -> [ParsedChapter] {
        try await loadDeferring(stored: stored, loaded: loaded, externalURL: externalURL, forceRefresh: forceRefresh,
                                mediaChapters: mediaChapters).chapters
    }

    /// The merged chapters that are available, with the conditions of the parts that must wait.
    public func loadDeferring(stored: [ParsedChapter]?, loaded: [ParsedChapter]? = nil,
                              externalURL: String?, forceRefresh: Bool = false,
                              mediaChapters: @Sendable () async throws -> [ParsedChapter]?) async throws -> EpisodeChapterLoad {
        try Task.checkCancellation()
        if let loaded, !forceRefresh { return .init(chapters: loaded) }
        let (external, externalDeferred) = try await remote(externalURL, forceRefresh: forceRefresh)
        var deferred: Set<AuxiliaryNetworkAdmission.Wake> = externalDeferred.map { [$0] } ?? []
        try Task.checkCancellation()
        let media: [ParsedChapter]?
        do { media = try await mediaChapters() }
        // A streamed list that must wait is not a result: it is not kept (`mediaChapters`) and is read again later.
        catch let denied as AuxiliaryNetworkDenied { deferred.insert(denied.wake); media = nil }
        catch { try Self.rethrowInterruption(error); media = nil }
        try Task.checkCancellation()
        return .init(chapters: ChapterMerger.merge(ChapterMerger.merge(stored, media), external) ?? [], deferred: deferred)
    }

    private func remote(_ address: String?, forceRefresh: Bool) async throws -> ([ParsedChapter]?, AuxiliaryNetworkAdmission.Wake?) {
        guard let address, !address.isEmpty, let url = URL(string: address),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return (nil, nil) }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !forceRefresh, let response = cache.cachedResponse(for: request),
           let http = response.response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let chapters = Self.parse(response.data, contentType: http.value(forHTTPHeaderField: "Content-Type")), chapters.count > 1 {
            return (chapters, nil)
        }
        if refused.contains(address) { return (nil, nil) }
        if awaitingUnrestricted.contains(address) {
            guard let state = try await admission.allowance(.smallMetadata), !state.restricted else { return (nil, .unrestricted) }
            awaitingUnrestricted.remove(address)
        }
        guard let allowance = try await admission.allowance(.smallMetadata) else { return (nil, .permitted(.smallMetadata)) }
        let key = request
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        allowance.constrain(&request)
        do {
            let response = try await admission.perform(allowance) { [transport, request] in
                try await transport.send(request, bodyLimit: allowance.bytes)
            }
            try Task.checkCancellation()
            guard (200..<300).contains(response.status) else { return (nil, nil) }
            if !(response.header("Cache-Control") ?? "").lowercased().contains("no-store"),
               let http = HTTPURLResponse(url: response.url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) {
                cache.storeCachedResponse(CachedURLResponse(response: http, data: response.body), for: key)
            }
            return (Self.parse(response.body, contentType: response.header("Content-Type")), nil)
        } catch is DownloadNetworkInterruption {
            return (nil, .permitted(.smallMetadata))
        } catch is FeedBodyLimitExceeded {
            if allowance.restricted { awaitingUnrestricted.insert(address); return (nil, .unrestricted) }
            refused.insert(address)
            return (nil, nil)
        } catch { try Self.rethrowInterruption(error); return (nil, nil) }
    }

    private static func rethrowInterruption(_ error: any Error) throws {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        // SocketTimeoutException is an InterruptedIOException in the source.
        // Preserve retryable unloaded state for native cancellation/timeouts.
        if let error = error as? URLError, [.cancelled, .timedOut].contains(error.code) { throw error }
    }

    private static func parse(_ data: Data, contentType: String?) -> [ParsedChapter]? {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else {
            let charset = contentType?.split(separator: ";").dropFirst().map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }.first { $0.hasPrefix("charset=") }?.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let encoding: String.Encoding = ["iso-8859-1", "latin1"].contains(charset ?? "") ? .isoLatin1 : .utf8
            text = String(data: data, encoding: encoding)
        }
        return text.flatMap(PodcastIndexChapterParser.parse)
    }
}

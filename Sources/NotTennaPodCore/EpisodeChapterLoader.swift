import Foundation

/// Loads source-owned chapter lists in the release's order. Callers retain the
/// returned list on the playable, and leave it nil after interruption so a later
/// presentation can retry. Network/media lifetime stays outside the view.
public actor EpisodeChapterLoader {
    private let transport: RedirectingProxyTransport
    private let cache: URLCache
    private let userAgent: String

    public init(transport: any FeedHTTPTransport, cache: URLCache, userAgent: String) {
        self.transport = RedirectingProxyTransport(transport: transport)
        self.cache = cache; self.userAgent = userAgent
    }

    /// Chapters read from episode media, by what decides them: the cover and the seek bar each
    /// reloaded on every play, pause and buffering change, which for a stream meant two ranged downloads
    /// each time. One read serves both, and later reloads of the same media; a refresh reads again.
    /// Interrupted reads are not kept, so a later reload retries.
    private var mediaResults: [(identity: EpisodeChapterIdentity, chapters: [ParsedChapter]?)] = []
    private var mediaReads: [(identity: EpisodeChapterIdentity, task: Task<[ParsedChapter]?, any Error>)] = []
    private(set) var mediaReadCount = 0

    func mediaChapters(_ identity: EpisodeChapterIdentity, forceRefresh: Bool,
                       read: @escaping @Sendable () async throws -> [ParsedChapter]?) async throws -> [ParsedChapter]? {
        if !forceRefresh {
            if let hit = mediaResults.last(where: { $0.identity == identity }) { return hit.chapters }
            if let running = mediaReads.last(where: { $0.identity == identity })?.task {
                let result = try await running.value
                try Task.checkCancellation()
                return result
            }
        }
        mediaReadCount += 1
        let task = Task { try await read() }
        mediaReads.append((identity, task))
        defer { mediaReads.removeAll { $0.task == task } }
        // A reload superseded mid-read (play then pause) leaves the read running for the next one to share.
        let result = try await task.value
        mediaResults.removeAll { $0.identity == identity }
        mediaResults.append((identity, result))
        if mediaResults.count > 8 { mediaResults.removeFirst(mediaResults.count - 8) }
        try Task.checkCancellation()
        return result
    }

    public func load(stored: [ParsedChapter]?, loaded: [ParsedChapter]? = nil,
                     externalURL: String?, forceRefresh: Bool = false,
                     mediaChapters: @Sendable () async throws -> [ParsedChapter]?) async throws -> [ParsedChapter] {
        try Task.checkCancellation()
        if let loaded, !forceRefresh { return loaded }
        let external = try await remote(externalURL, forceRefresh: forceRefresh)
        try Task.checkCancellation()
        let media: [ParsedChapter]?
        do { media = try await mediaChapters() }
        catch { try Self.rethrowInterruption(error); media = nil }
        try Task.checkCancellation()
        return ChapterMerger.merge(ChapterMerger.merge(stored, media), external) ?? []
    }

    private func remote(_ address: String?, forceRefresh: Bool) async throws -> [ParsedChapter]? {
        guard let address, !address.isEmpty, let url = URL(string: address),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !forceRefresh, let response = cache.cachedResponse(for: request),
           let http = response.response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let chapters = Self.parse(response.data, contentType: http.value(forHTTPHeaderField: "Content-Type")), chapters.count > 1 {
            return chapters
        }
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let response = try await transport.send(request)
            try Task.checkCancellation()
            guard (200..<300).contains(response.status) else { return nil }
            if !(response.header("Cache-Control") ?? "").lowercased().contains("no-store"),
               let http = HTTPURLResponse(url: response.url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) {
                var key = request; key.setValue(nil, forHTTPHeaderField: "Cache-Control")
                cache.storeCachedResponse(CachedURLResponse(response: http, data: response.body), for: key)
            }
            return Self.parse(response.body, contentType: response.header("Content-Type"))
        } catch { try Self.rethrowInterruption(error); return nil }
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

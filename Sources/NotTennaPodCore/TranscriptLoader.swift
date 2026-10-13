import Foundation

/// TranscriptUtils' local sidecar / cached response / forced-network precedence.
/// The shared transport retains configured proxy ownership and redirect behavior.
public actor TranscriptLoader {
    private let transport: RedirectingProxyTransport
    private let cache: URLCache
    private let userAgent: String
    public init(transport: any FeedHTTPTransport, cache: URLCache, userAgent: String) {
        self.transport = RedirectingProxyTransport(transport: transport); self.cache = cache; self.userAgent = userAgent
    }

    public func load(_ descriptor: FeedTranscript, localMediaPath: String? = nil, forceRefresh: Bool = false) async throws -> EpisodeTranscript {
        try Task.checkCancellation()
        if !forceRefresh, let localMediaPath {
            let file = localMediaPath.hasPrefix("file:") ? URL(string: localMediaPath) : URL(fileURLWithPath: localMediaPath)
            if let file, file.isFileURL,
               let text = try? String(contentsOf: URL(fileURLWithPath: file.path + ".transcript"), encoding: .utf8), !text.isEmpty {
                return try TranscriptParser.parse(text, format: descriptor.format)
            }
        }
        return try TranscriptParser.parse(try await remoteText(descriptor, forceRefresh: forceRefresh), format: descriptor.format)
    }

    /// Download completion stores the original text even when its parser rejects it.
    /// The media worker owns this write and waits for cancellation before deletion.
    public func storeSidecar(_ descriptor: FeedTranscript, media: URL) async throws {
        guard media.isFileURL else { throw FeedLibraryError.invalidLocation }
        let text = try await remoteText(descriptor, forceRefresh: true)
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: media.path) else { throw CocoaError(.fileNoSuchFile) }
        try Data(text.utf8).write(to: URL(fileURLWithPath: media.path + ".transcript"), options: .atomic)
    }

    private func remoteText(_ descriptor: FeedTranscript, forceRefresh: Bool) async throws -> String {
        try Task.checkCancellation()
        guard let url = URL(string: descriptor.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !forceRefresh, let cached = cache.cachedResponse(for: request), let response = cached.response as? HTTPURLResponse,
           (200..<300).contains(response.statusCode), let text = Self.text(cached.data, contentType: response.value(forHTTPHeaderField: "Content-Type")), text.utf16.count > 1 {
            return text
        }
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.status) else { throw URLError(.badServerResponse) }
        guard let text = Self.text(response.body, contentType: response.header("Content-Type")), !text.isEmpty else { throw TranscriptParseError.invalidDocument }
        // FORCE_CACHE may reuse a stale cacheable response. no-store remains binding.
        if !(response.header("Cache-Control") ?? "").lowercased().contains("no-store"),
           let http = HTTPURLResponse(url: response.url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) {
            var key = request; key.setValue(nil, forHTTPHeaderField: "Cache-Control")
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

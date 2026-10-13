import Foundation
import CryptoKit

public struct PodcastSearchResult: Equatable, Sendable {
    public var title: String
    public var imageURL: String?
    public var feedURL: String
    public var author: String?
    public init(title: String, imageURL: String? = nil, feedURL: String, author: String? = nil) {
        self.title = title; self.imageURL = imageURL; self.feedURL = feedURL; self.author = author
    }
    public var subtitle: String? {
        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return author }
        return feedURL.contains("itunes.apple.com") ? nil : feedURL
    }
}

public enum PodcastSearchProvider: Sendable {
    case combined, apple, podcastIndex, fyyd
    public var name: String {
        switch self { case .combined: "Apple, Podcast Index"; case .apple: "Apple"; case .podcastIndex: "Podcast Index"; case .fyyd: "fyyd" }
    }
}

public enum PodcastSearchError: Error, LocalizedError, Equatable {
    case invalidResponse, http(Int), feedURLNotFound(artist: String, track: String)
    /// fyyd without a `data` array: the source's IOException("Null response").
    case nullResponse
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid podcast directory response"
        case .nullResponse: "Null response"
        case .http(let status): "HTTP \(status)"
        case .feedURLNotFound(let artist, let track): "No feed URL found for \(track) by \(artist)"
        }
    }
}

/// Public directory wire formats and provider order from net/discovery in 3.12.1.
/// The injected transport keeps HTTP scenarios deterministic without changing production routing.
public struct PodcastSearchClient: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)
    private let send: Send
    private let now: @Sendable () -> Date
    private let indexKey: String, indexSecret: String
    public init(indexKey: String = PodcastIndexApplicationCredentials.key,
                indexSecret: String = PodcastIndexApplicationCredentials.secret,
                now: @escaping @Sendable () -> Date = { Date() }, send: @escaping Send = { request in
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let response = response as? HTTPURLResponse else { throw PodcastSearchError.invalidResponse }
                    return (data, response.statusCode)
                }) {
        self.indexKey = indexKey; self.indexSecret = indexSecret; self.now = now; self.send = send
    }
    public func search(_ query: String, provider: PodcastSearchProvider = .combined) async throws -> [PodcastSearchResult] {
        try Task.checkCancellation()
        if provider == .combined {
            // Original CombinedSearcher tolerates even all-provider failure as an empty result.
            // Cancellation must still propagate rather than publish a spurious empty result.
            async let apple = tolerantSearch(query, provider: .apple)
            async let index = tolerantSearch(query, provider: .podcastIndex)
            let results = await [apple, index]
            try Task.checkCancellation()
            return Self.combine(results)
        }
        var components: URLComponents
        switch provider {
        case .apple:
            components = URLComponents(string: "https://itunes.apple.com/search")!
            components.queryItems = [.init(name: "media", value: "podcast"), .init(name: "term", value: query)]
        case .podcastIndex:
            components = URLComponents(string: "https://api.podcastindex.org/api/1.0/search/byterm")!
            components.queryItems = [.init(name: "q", value: query)]
        case .fyyd:
            components = URLComponents(string: "https://api.fyyd.de/0.2/search/podcast")!
            components.queryItems = [.init(name: "title", value: query), .init(name: "count", value: "10")]
        case .combined: preconditionFailure()
        }
        // Encode '+' literally: directory form decoders otherwise treat it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue(HTTPUserAgent.search, forHTTPHeaderField: "User-Agent")
        if provider == .podcastIndex {
            let timestamp = String(Int64(now().timeIntervalSince1970))
            let digest = Insecure.SHA1.hash(data: Data((indexKey + indexSecret + timestamp).utf8))
            request.setValue(timestamp, forHTTPHeaderField: "X-Auth-Date")
            request.setValue(indexKey, forHTTPHeaderField: "X-Auth-Key")
            request.setValue(digest.map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "Authorization")
        }
        let object = try await json(request)
        let arrayKey: String, titleKey: String, imageKey: String, urlKey: String, authorKey: String
        switch provider {
        case .apple: (arrayKey, titleKey, imageKey, urlKey, authorKey) = ("results", "collectionName", "artworkUrl100", "feedUrl", "artistName")
        case .podcastIndex: (arrayKey, titleKey, imageKey, urlKey, authorKey) = ("feeds", "title", "image", "url", "author")
        case .fyyd: (arrayKey, titleKey, imageKey, urlKey, authorKey) = ("data", "title", "thumbImageURL", "xmlURL", "author")
        case .combined: preconditionFailure()
        }
        guard let items = object[arrayKey] as? [[String: Any]] else {
            throw provider == .fyyd ? PodcastSearchError.nullResponse : PodcastSearchError.invalidResponse
        }
        return items.compactMap { item in
            if provider != .fyyd && item[urlKey] == nil { return nil }
            return PodcastSearchResult(title: item[titleKey] as? String ?? "Unknown", imageURL: item[imageKey] as? String ?? "",
                                       feedURL: item[urlKey] as? String ?? "", author: item[authorKey] as? String ?? "Unknown")
        }
    }
    private func tolerantSearch(_ query: String, provider: PodcastSearchProvider) async -> [PodcastSearchResult] {
        (try? await search(query, provider: provider)) ?? []
    }
    /// CombinedSearcher.weightSearchResults: both enabled providers have weight 1; a URL scores the
    /// float sum of 1/(position+1) and keeps the last provider's metadata. Equal scores keep the
    /// iteration order of the source's HashMap<String, Float> (a stable sort over it), which is
    /// deterministic and differs from first encounter.
    public static func combine(_ providers: [[PodcastSearchResult]]) -> [PodcastSearchResult] {
        var scores: [String: Float] = [:], results: [String: PodcastSearchResult] = [:]
        var map = JavaHashMapOrder()
        for provider in providers {
            for (position, result) in provider.enumerated() {
                results[result.feedURL] = result
                scores[result.feedURL] = (scores[result.feedURL] ?? 0) + 1 / (Float(position) + 1)
                map.put(result.feedURL)
            }
        }
        return map.keys.enumerated().sorted {
            let lhs = scores[$0.element]!, rhs = scores[$1.element]!
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.compactMap { results[$0.element] }
    }
    public struct FeedResolution: Equatable, Sendable {
        public var url: String
        public var recoveredBySearch: Bool
    }
    public func resolveFeed(_ address: String) async throws -> FeedResolution {
        do { return .init(url: try await resolveFeedURL(address), recoveredBySearch: false) }
        catch PodcastSearchError.feedURLNotFound(let artist, let track) {
            let candidates = try await search(track + " " + artist)
            guard let match = candidates.first(where: {
                Self.sameDirectoryName($0.title, track) && $0.author.map { Self.sameDirectoryName($0, artist) } == true
            }) else { throw PodcastSearchError.feedURLNotFound(artist: artist, track: track) }
            return .init(url: match.feedURL, recoveredBySearch: true)
        }
    }
    // Java equalsIgnoreCase compares simple scalar case mappings, without full
    // string expansions (ß != ss) or canonical normalization. Keep matching exact.
    static func sameDirectoryName(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf16.count == rhs.utf16.count else { return false }
        let left = Array(lhs.unicodeScalars), right = Array(rhs.unicodeScalars)
        guard left.count == right.count else { return false }
        func upper(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
            let mapped = Array(scalar.properties.uppercaseMapping.unicodeScalars)
            return mapped.count == 1 ? mapped[0] : scalar
        }
        func lower(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
            if scalar.value == 0x130 { return "i" }
            let mapped = Array(scalar.properties.lowercaseMapping.unicodeScalars)
            return mapped.count == 1 ? mapped[0] : scalar
        }
        return zip(left, right).allSatisfy { a, b in
            a == b || upper(a) == upper(b) || lower(upper(a)) == lower(upper(b))
        }
    }
    public func resolveFeedURL(_ address: String) async throws -> String {
        guard let url = URL(string: address), let host = url.host?.lowercased() else { return address }
        var lookup = url
        if host == "podcasts.apple.com" {
            guard let id = url.pathComponents.last(where: { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy(\.isNumber) && $0.count > 2 }) else { return address }
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [.init(name: "id", value: String(id.dropFirst(2)))]; lookup = components.url!
        } else if host != "itunes.apple.com" { return address }
        let object = try await json(URLRequest(url: lookup, timeoutInterval: 30))
        guard let results = object["results"] as? [[String: Any]], let first = results.first else { throw PodcastSearchError.invalidResponse }
        guard let feed = first["feedUrl"] as? String else {
            guard let artist = first["artistName"] as? String, let track = first["trackName"] as? String else { throw PodcastSearchError.invalidResponse }
            throw PodcastSearchError.feedURLNotFound(artist: artist, track: track)
        }
        return feed
    }
    public func sendRequest(_ request: URLRequest) async throws -> (Data, Int) { try await send(request) }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, status) = try await send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(status) else { throw PodcastSearchError.http(status) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PodcastSearchError.invalidResponse }
        return object
    }
}

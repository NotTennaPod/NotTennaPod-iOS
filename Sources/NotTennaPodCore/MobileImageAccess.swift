import Foundation

/// A picture larger than the limit for the network it was asked for on (`MobileImageAccess`).
public struct ArtworkTooLarge: Error, Sendable {
    /// Over the restricted-network limit: it may load on an unrestricted network, so it waits for one.
    public let restricted: Bool
    public init(restricted: Bool) { self.restricted = restricted }
}

/// Restricted connections may use an already cached cover without starting a request.
@MainActor public final class MobileImageAccess {
    /// On a restricted network (cellular, a hotspot, Low Data Mode) a picture larger than this waits for Wi-Fi: Android
    /// downloads it, but a few podcasts publish 7–40 MB pictures, a surprise mobile-data cost for one cover.
    public nonisolated static let restrictedByteLimit = 5 * 1024 * 1024
    /// No picture larger than this is held in memory on any network.
    public nonisolated static let byteLimit = 50 * 1024 * 1024

    private let preferences: MobileNetworkPreferenceStore
    private let network: DownloadNetworkMonitor
    private let proxyConfiguration: (@Sendable () -> PodcastProxy)?
    private let cache: URLCache
    private var proxyTransport: RedirectingProxyTransport?
    /// Without `proxyConfiguration` pictures use a direct connection, through the same bounded client.
    public init(preferences: MobileNetworkPreferenceStore, network: DownloadNetworkMonitor = .shared,
                proxyConfiguration: (@Sendable () -> PodcastProxy)? = nil, cache: URLCache = .shared) {
        self.preferences = preferences; self.network = network
        self.proxyConfiguration = proxyConfiguration; self.cache = cache
    }

    /// The most bytes a picture may have on the current network, and whether that network is restricted.
    public func byteLimit() async throws -> (bytes: Int, restricted: Bool) {
        let restricted = try await network.observedState().restricted
        return (restricted ? Self.restrictedByteLimit : Self.byteLimit, restricted)
    }

    /// The byte limit for a picture fetched now, or nil when none may be fetched: "Cover images" is off for mobile
    /// updates and the network is restricted (pictures already on the phone still show).
    public func fetchAllowance() async throws -> (bytes: Int, restricted: Bool)? {
        let limit = try await byteLimit()
        return !preferences.allows(.images) && limit.restricted ? nil : limit
    }

    /// Returns once the network is unrestricted (Wi-Fi or Ethernet without Low Data Mode).
    public func waitUntilUnrestricted() async throws {
        let changes = network.changes()
        if network.current.map({ !$0.restricted }) == true { return }
        for await state in changes where !state.restricted { return }
        throw CancellationError()
    }

    /// The picture at `url`; `ArtworkTooLarge` once more bytes than the network's limit arrive, counted on the body
    /// as received (a declared length over the limit stops before the body).
    public func load(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        let limit = try await byteLimit()
        if !preferences.allows(.images), limit.restricted {
            request.cachePolicy = .returnCacheDataDontLoad
        }
        do {
            // The source artwork factory owns a separate retained newBuilder
            // client. Shared-client reinit must not replace it or its cache.
            if proxyTransport == nil {
                proxyTransport = RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: proxyConfiguration?() ?? .init(), cache: cache))
            }
            let response = try await proxyTransport!.send(request, bodyLimit: limit.bytes)
            guard let native = HTTPURLResponse(url: response.url, statusCode: response.status, httpVersion: nil, headerFields: response.headers) else {
                throw URLError(.badServerResponse)
            }
            return (response.body, native)
        } catch is FeedBodyLimitExceeded {
            throw ArtworkTooLarge(restricted: limit.restricted)
        }
    }
}

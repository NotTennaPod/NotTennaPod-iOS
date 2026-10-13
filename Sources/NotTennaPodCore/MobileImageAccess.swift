import Foundation

/// Restricted connections may use an already cached cover without starting a request.
@MainActor public final class MobileImageAccess {
    private let preferences: MobileNetworkPreferenceStore
    private let network: DownloadNetworkMonitor
    private let session: URLSession
    private let proxyConfiguration: (@Sendable () -> PodcastProxy)?
    private let cache: URLCache
    private var proxyTransport: RedirectingProxyTransport?
    public init(preferences: MobileNetworkPreferenceStore, network: DownloadNetworkMonitor = .shared,
                session: URLSession = .shared, proxyConfiguration: (@Sendable () -> PodcastProxy)? = nil,
                cache: URLCache = .shared) {
        self.preferences = preferences; self.network = network; self.session = session
        self.proxyConfiguration = proxyConfiguration; self.cache = cache
    }
    public func load(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        if !preferences.allows(.images), try await network.observedState().restricted {
            request.cachePolicy = .returnCacheDataDontLoad
        }
        if let proxyConfiguration {
            // The source artwork factory owns a separate retained newBuilder
            // client. Shared-client reinit must not replace it or its cache.
            if proxyTransport == nil {
                proxyTransport = RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: proxyConfiguration(), cache: cache))
            }
            let response = try await proxyTransport!.send(request)
            guard let native = HTTPURLResponse(url: response.url, statusCode: response.status, httpVersion: nil, headerFields: response.headers) else {
                throw URLError(.badServerResponse)
            }
            return (response.body, native)
        }
        return try await session.data(for: request)
    }
}

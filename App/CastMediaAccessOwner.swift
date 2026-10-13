import Foundation
import NotTennaPodCore

struct CastReceiverAddress: Equatable, Sendable {
    let address: String
    let port: UInt16
}

/// Application library/network ownership for receiver fetches. Every prepared
/// item uses its own captured relay; there is no direct enclosure fallback.
@MainActor final class CastMediaAccessOwner {
    private struct Source: Equatable {
        let episodeID: Int64
        let url: URL
        let proxy: ProxyNetworkEnvironment.Client
        let credentials: FeedCredentials?
        let endpoint: NativeRelayEndpoint
    }
    private final class Entry {
        let source: Source
        weak var media: CastPlaybackMedia?
        weak var relay: NativeStreamingRelay?
        init(source: Source, media: CastPlaybackMedia, relay: NativeStreamingRelay) {
            self.source = source; self.media = media; self.relay = relay
        }
    }
    private let store: FeedLibraryStore
    private let authentication: FeedAuthentication
    private let network: ProxyNetworkEnvironment
    private let userAgent: String
    private let resolveEndpoint: @Sendable (CastReceiverAddress) async throws -> NativeRelayEndpoint
    private var receiver: CastReceiverAddress?
    private var revision = UUID()
    private var leases: [UUID: Entry] = [:]
    private var disconnected: [String: CastPlaybackMedia] = [:]

    /// Disconnect leaves the receiver playing its authorized URL. Retain that
    /// URL until re-adoption, an explicit receiver stop/replacement, or process
    /// teardown. A guessed timeout would interrupt paused/live receivers.
    func retainDisconnected(_ media: CastPlaybackMedia, identity: CastSessionIdentity) {
        if let old = disconnected.updateValue(media, forKey: identity.deviceID), old !== media { old.close() }
    }
    func receiverStopped(deviceID: String) { disconnected.removeValue(forKey: deviceID)?.close() }


    /// The library whose episodes this owner loads; a server library tags its loads (`CastMediaItemCodec.libraryIDKey`).
    let library: LibraryReference

    init(store: FeedLibraryStore, authentication: FeedAuthentication, network: ProxyNetworkEnvironment,
         userAgent: String, library: LibraryReference = .standalone,
         resolveEndpoint: @escaping @Sendable (CastReceiverAddress) async throws -> NativeRelayEndpoint = {
             try await ReceiverNetworkRoute.endpoint(address: $0.address, port: $0.port)
         }) {
        self.store = store; self.authentication = authentication; self.network = network
        self.userAgent = userAgent; self.library = library; self.resolveEndpoint = resolveEndpoint
    }
    isolated deinit { for entry in Array(leases.values) { entry.media?.close() } }

    func setReceiver(_ receiver: CastReceiverAddress?) {
        guard self.receiver != receiver else { return }
        self.receiver = receiver; revision = UUID()
    }

    private func source(episodeID: Int64) async throws -> (Source, LibraryEpisode, LibraryFeed) {
        let revision = revision
        guard let receiver else { throw URLError(.notConnectedToInternet) }
        let client = network.sharedClient()
        guard let episode = try await store.episode(id: episodeID),
              let feed = try await store.playbackFeed(id: store.feedID(forEpisode: episodeID)) else { throw FeedLibraryError.missingEpisode(episodeID) }
        guard let raw = episode.details.media?.url, var url = URLComponents(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { throw URLError(.unsupportedURL) }
        // Source authentication is supplied by the library owner, never embedded
        // into receiver metadata or the readable portion of a signed route.
        url.user = nil; url.password = nil; url.fragment = nil
        guard let address = url.url else { throw URLError(.badURL) }
        let credentials = try await authentication.credentials(feedID: feed.id)
        let endpoint = try await resolveEndpoint(receiver)
        try Task.checkCancellation()
        guard self.revision == revision else { throw CancellationError() }
        return (Source(episodeID: episodeID, url: address, proxy: client, credentials: credentials, endpoint: endpoint), episode, feed)
    }

    func prepare(_ episode: LibraryEpisode) async throws -> CastPlaybackMedia { try await prepare(episodeID: episode.id) }

    func prepare(episodeID: Int64) async throws -> CastPlaybackMedia {
        let revision = revision
        let (source, episode, feed) = try await source(episodeID: episodeID)
        let mime = episode.details.media?.mimeType?.lowercased() ?? ""
        let relay = try await NativeStreamingRelay.start(url: source.url,
            playlist: source.url.pathExtension.lowercased() == "m3u8" || mime.contains("mpegurl"),
            proxy: source.proxy.configuration, credentials: source.credentials, endpoint: source.endpoint,
            userAgent: userAgent)
        guard !Task.isCancelled, self.revision == revision else { relay.cancel(); throw CancellationError() }
        let id = UUID()
        let media = CastPlaybackMedia(item: .init(contentURL: relay.url.absoluteString, mediaID: String(episode.id),
            localPlaybackURL: episode.userState.isDownloaded ? episode.userState.localFileURL : source.url.absoluteString,
            title: episode.details.title, subtitle: feed.title,
            artworkURL: (episode.details.imageURL ?? feed.metadata.imageURL).flatMap(URL.init(string:)),
            libraryID: library.castLibraryID), release: { [weak self] in
                relay.cancel(); self?.leases[id] = nil
            })
        leases[id] = Entry(source: source, media: media, relay: relay)
        return media
    }

    /// Reuse requires a currently owned live URL and the current library,
    /// credentials, proxy-client identity and selected interface. Foreign metadata
    /// and an old process's expired relay URL cannot authorize an adoption.
    func authorizedMedia(episodeID: Int64, contentURL: String?) async throws -> CastPlaybackMedia? {
        guard let contentURL, let url = URL(string: contentURL) else { return nil }
        let candidates = leases.values.filter { $0.source.episodeID == episodeID && $0.relay?.owns(url) == true }
        guard !candidates.isEmpty else { return nil }
        let (source, _, _) = try await source(episodeID: episodeID)
        guard let media = candidates.first(where: { $0.source == source && $0.relay?.owns(url) == true })?.media else { return nil }
        for key in Array(disconnected.keys) where disconnected[key] === media { disconnected[key] = nil }
        return media
    }
}

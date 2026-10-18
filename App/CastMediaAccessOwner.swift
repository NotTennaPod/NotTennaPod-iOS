import Foundation
import NotTennaPodCore

struct CastReceiverAddress: Equatable, Sendable {
    let address: String
    let port: UInt16
}

/// A relayed cast needs "Streaming", an unrestricted network or Once consent for its episode, and none of them holds.
struct CastRelayStreamingDenied: Error, Equatable {
    let episodeID: Int64
}

/// Application library/network ownership for receiver fetches. A public enclosure (no stored credentials, no app
/// proxy, no userinfo) is cast by its own URL and fetched by the receiver, as on Android. Anything else is relayed
/// through the phone, each prepared item by its own captured relay, after the streaming admission.
@MainActor final class CastMediaAccessOwner {
    /// The library facts a route is decided on: the raw enclosure (userinfo not yet removed), credentials and proxy.
    private struct RawSource: Equatable {
        let episodeID: Int64
        let raw: String
        let proxy: ProxyNetworkEnvironment.Client
        let credentials: FeedCredentials?
    }
    private enum Route: Equatable { case direct(URL), relay(URL) }
    private struct Source: Equatable {
        let raw: RawSource
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
    private let admission: AuxiliaryNetworkAdmission
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

    /// `admission` decides each new relay ("Streaming", an unrestricted network or Once consent); without one, every
    /// relay is admitted (tests, and screens built without the app).
    init(store: FeedLibraryStore, authentication: FeedAuthentication, network: ProxyNetworkEnvironment,
         userAgent: String, library: LibraryReference = .standalone, admission: AuxiliaryNetworkAdmission = .unrestricted,
         resolveEndpoint: @escaping @Sendable (CastReceiverAddress) async throws -> NativeRelayEndpoint = {
             try await ReceiverNetworkRoute.endpoint(address: $0.address, port: $0.port)
         }) {
        self.store = store; self.authentication = authentication; self.network = network
        self.userAgent = userAgent; self.library = library; self.admission = admission; self.resolveEndpoint = resolveEndpoint
    }
    isolated deinit { for entry in Array(leases.values) { entry.media?.close() } }

    func setReceiver(_ receiver: CastReceiverAddress?) {
        guard self.receiver != receiver else { return }
        self.receiver = receiver; revision = UUID()
    }

    /// The episode's library facts, with no endpoint resolution and no request. The proxy client is read after the
    /// awaited reads, so a proxy configured meanwhile is seen.
    private func rawSource(episodeID: Int64) async throws -> (RawSource, LibraryEpisode, LibraryFeed) {
        guard let episode = try await store.episode(id: episodeID),
              let feed = try await store.playbackFeedHeader(id: store.feedID(forEpisode: episodeID)) else { throw FeedLibraryError.missingEpisode(episodeID) }
        guard let raw = episode.details.media?.url else { throw URLError(.unsupportedURL) }
        let credentials = try await authentication.credentials(feedID: feed.id)
        return (RawSource(episodeID: episodeID, raw: raw, proxy: network.sharedClient(), credentials: credentials), episode, feed)
    }

    /// Direct when nothing the phone holds is needed: no stored credentials, no app proxy, and no userinfo in the raw
    /// enclosure (judged before it is removed). Downloaded episodes and HLS follow the same rule. A proxy is a privacy
    /// choice: the proxy is checked as it is now, when a direct item is about to be returned (every caller returns
    /// synchronously after this), in the source's client, the current shared client and the one new clients get.
    private func route(_ source: RawSource) throws -> Route {
        guard var components = URLComponents(string: source.raw),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host?.isEmpty == false else {
            throw URLError(.unsupportedURL)
        }
        let userinfo = components.user != nil || components.password != nil
        // Source authentication is supplied by the library owner, never embedded into receiver metadata or the
        // readable portion of a signed route.
        components.user = nil; components.password = nil; components.fragment = nil
        guard let url = components.url else { throw URLError(.badURL) }
        let credentials = source.credentials.map { !($0.username ?? "").isEmpty || !($0.password ?? "").isEmpty } ?? false
        let proxied = source.proxy.configuration.isConfigured || network.sharedClient() != source.proxy
            || network.sharedClient().configuration.isConfigured || network.newClientConfiguration().isConfigured
        return !credentials && !proxied && !userinfo ? .direct(url) : .relay(url)
    }

    /// Only the relay path resolves the receiver's network route.
    private func relayEndpoint() async throws -> NativeRelayEndpoint {
        guard let receiver else { throw URLError(.notConnectedToInternet) }
        return try await resolveEndpoint(receiver)
    }

    func prepare(_ episode: LibraryEpisode) async throws -> CastPlaybackMedia { try await prepare(episodeID: episode.id) }

    /// The single place a relay is created, for every caller (connecting with an episode selected, selection, resume
    /// and reload, restoration). A relay needs the streaming admission for this episode, checked after the first network
    /// observation and before the relay. The source (proxy client, credentials, enclosure) is read again after every
    /// await: after the admission, after resolving the receiver's route and after starting the relay, which is handed
    /// out with no further await. A proxy configured, or credentials or the enclosure changed, meanwhile is decided
    /// again, once (a relay already started is cancelled before it fetches anything); a second change cancels.
    func prepare(episodeID: Int64) async throws -> CastPlaybackMedia {
        let revision = revision
        var (raw, episode, feed) = try await rawSource(episodeID: episodeID)
        guard self.revision == revision else { throw CancellationError() }
        var revalidated = false
        func redecide(unless holds: Bool) async throws -> Bool {
            guard !holds else { return false }
            guard !revalidated else { throw CancellationError() }
            revalidated = true; (raw, episode, feed) = try await rawSource(episodeID: episodeID)
            guard self.revision == revision else { throw CancellationError() }
            return true
        }
        while true {
            let url: URL
            switch try route(raw) {
            case .direct(let address): return media(episode: episode, feed: feed, contentURL: address, streamURL: address)
            case .relay(let address): url = address
            }
            guard try await admission.streamingRelay(episodeID) else { throw CastRelayStreamingDenied(episodeID: episodeID) }
            try Task.checkCancellation()
            guard self.revision == revision else { throw CancellationError() }
            if try await redecide(unless: sourceHolds(raw, episodeID: episodeID, revision: revision)) { continue }
            let endpoint = try await relayEndpoint()
            try Task.checkCancellation()
            guard self.revision == revision else { throw CancellationError() }
            if try await redecide(unless: sourceHolds(raw, episodeID: episodeID, revision: revision)) { continue }
            let source = Source(raw: raw, endpoint: endpoint)
            let mime = episode.details.media?.mimeType?.lowercased() ?? ""
            let relay = try await NativeStreamingRelay.start(url: url,
                playlist: url.pathExtension.lowercased() == "m3u8" || mime.contains("mpegurl"),
                proxy: raw.proxy.configuration, credentials: raw.credentials, endpoint: endpoint,
                userAgent: userAgent)
            let holds: Bool
            do {
                guard !Task.isCancelled, self.revision == revision else { throw CancellationError() }
                holds = try await sourceHolds(raw, episodeID: episodeID, revision: revision)
            } catch { relay.cancel(); throw error }
            if !holds { relay.cancel() }
            if try await redecide(unless: holds) { continue }
            // No await from here until the relay is handed out.
            let id = UUID()
            let media = media(episode: episode, feed: feed, contentURL: relay.url, streamURL: url) { [weak self] in
                relay.cancel(); self?.leases[id] = nil
            }
            leases[id] = Entry(source: source, media: media, relay: relay)
            return media
        }
    }

    /// Whether `raw` is still the episode's source: read again (the proxy client after the awaited reads), and still
    /// relayed. The caller hands out its relay with no further await.
    private func sourceHolds(_ raw: RawSource, episodeID: Int64, revision: UUID) async throws -> Bool {
        let current = try await rawSource(episodeID: episodeID).0
        try Task.checkCancellation()
        guard self.revision == revision else { throw CancellationError() }
        guard case .relay = try route(current) else { return false }
        return current == raw && network.sharedClient() == raw.proxy
    }

    /// The receiver's item. `local_file_url` is the downloaded file, as Android sends it, or the enclosure without
    /// userinfo; a picture whose address carries userinfo is left out.
    private func media(episode: LibraryEpisode, feed: LibraryFeed, contentURL: URL, streamURL: URL,
                       release: @escaping @MainActor () -> Void = {}) -> CastPlaybackMedia {
        let artwork = (episode.details.imageURL ?? feed.metadata.imageURL).flatMap { address in
            URLComponents(string: address).map { $0.user == nil && $0.password == nil } == true ? URL(string: address) : nil
        }
        return CastPlaybackMedia(item: .init(contentURL: contentURL.absoluteString, mediaID: String(episode.id),
            localPlaybackURL: episode.userState.isDownloaded ? episode.userState.localFileURL : streamURL.absoluteString,
            title: episode.details.title, subtitle: feed.title, artworkURL: artwork,
            libraryID: library.castLibraryID), release: release)
    }

    /// Reuse requires a currently owned live URL and the current library, credentials, proxy-client identity and
    /// selected interface; a direct item, the current public enclosure. Foreign metadata and an old process's expired
    /// relay URL cannot authorize an adoption. A direct item never resolves the receiver's route.
    func authorizedMedia(episodeID: Int64, contentURL: String?) async throws -> CastPlaybackMedia? {
        guard let contentURL, let url = URL(string: contentURL) else { return nil }
        let revision = revision
        let (raw, episode, feed) = try await rawSource(episodeID: episodeID)
        guard self.revision == revision else { throw CancellationError() }
        switch try route(raw) {
        case .direct(let address):
            guard address.absoluteString == contentURL else { return nil }
            return media(episode: episode, feed: feed, contentURL: address, streamURL: address)
        case .relay:
            let candidates = leases.values.filter { $0.source.raw == raw && $0.relay?.owns(url) == true }
            guard !candidates.isEmpty else { return nil }
            let endpoint = try await relayEndpoint()
            try Task.checkCancellation()
            guard self.revision == revision else { throw CancellationError() }
            guard let media = candidates.first(where: { $0.source.endpoint == endpoint && $0.relay?.owns(url) == true })?.media else { return nil }
            for key in Array(disconnected.keys) where disconnected[key] === media { disconnected[key] = nil }
            return media
        }
    }
}

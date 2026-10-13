import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum PlaybackSourceError: Error, Equatable, Sendable { case missingMedia, invalidURL }

@MainActor
public final class AVPlayerPlaybackEngine: PlaybackVolumeControlling {
    public var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    public var reading: PlaybackEngineReading? {
        if let reclaimedRelay, let generation, let commandID { return reclaimedReading(reclaimedRelay, generation: generation, commandID: commandID) }
        guard prepared, let generation, let commandID, let player = nativePlayer, let item = player.currentItem else { return nil }
        let position = pendingPosition ?? Self.milliseconds(player.currentTime(), fallback: 0)
        let duration = Self.milliseconds(item.duration, fallback: -1)
        return .init(generation: generation, commandID: commandID,
                     sample: .init(positionMilliseconds: Int32(truncatingIfNeeded: position),
                                   durationMilliseconds: Int32(truncatingIfNeeded: duration),
                                   seekable: !item.seekableTimeRanges.isEmpty,
                                   status: wantsPlayback ? .playing : .paused),
                     buffering: seekID != nil || (wantsPlayback && player.timeControlStatus == .waitingToPlayAtSpecifiedRate),
                     speed: player.defaultRate)
    }

    private(set) var nativePlayer: AVPlayer?
    private(set) var httpSource: ProgressiveHTTPMediaSource?
    private(set) var localSource: LocalPlaybackAssetLoader?
    private let localDocument: LocalPlaybackDocument?
    // Internal construction boundary supports deterministic source-error/lifecycle tests.
    var makeHTTPSource: (URL, @escaping @Sendable (Error) -> Void) throws -> ProgressiveHTTPMediaSource
    private let muted: Bool
    private let source: @MainActor (LibraryEpisode) throws -> URL
    private let credentials: (@Sendable (LibraryEpisode) async throws -> FeedCredentials?)?
    private let urlResolver: PlaybackURLResolver?
    private let proxyClient: (@Sendable () -> ProxyNetworkEnvironment.Client)?
    private let userAgent: String
    private var activeProxy = PodcastProxy()
    private var credentialTask: Task<Void, Never>?
    private var authentication: PlaybackHTTPAuthentication?
    private var nativeAuthentication: NativePlaybackAuthentication?
    private var relayTask: Task<Void, Never>?
    private(set) var nativeRelay: NativeStreamingRelay?
    // The relay route's item is retired when the app may be suspended (extension below).
    var relayReclaim: StreamingRelayReclaim = .shared
    private var relayParticipant: RelayRouteParticipant?
    private var relayTrust: UInt64?
    private var relayPlaylist = false
    private var reclaimedRelay: ReclaimedRelayRoute?
    private var rebuildingRelayRoute = false
    private var relayLifecycleEpoch: UInt64 = 0
    /// The epoch of the last repair after a local relay failure, the position it had to reach,
    /// and whether the replacement then delivered it (a seek landed with its media, or playback
    /// advanced past it). Item readiness alone is not progress.
    private var relayRepair: (epoch: UInt64, position: Int64, progressed: Bool)?
    /// A relay route is being rebuilt: no player exists that the system could pause.
    private var relayRebuildInProgress = false
#if DEBUG
    /// Test hook: every relay this engine starts loses its sockets at once, as iOS would close them.
    var reclaimsNewRelaysForTesting = false
#endif
    private var requestedSpeed: Float = 1
    private var requestedVolume: FeedVolumeAdaptation = .off
    private var sleepTimerVolume: Float = 1
    private(set) var volumeTap: PlaybackVolumeTap?
    var measureVolumeForTesting = false
    private let configureAudioSession: @MainActor () throws -> Void
    /// This engine's claim on the app's audio session: the player starts once the owner has activated
    /// it, and the session is released when this item stops for good (unload, failure), not on pause.
    private let session: AudioSessionActivationController
    private var activationRequest: UUID?
    private var generation: UUID?
    private var commandID: UUID?
    private var seekID: UUID?
    private var pendingPosition: Int64?
    private var prepared = false
    private var wantsPlayback = false
    private var failed = false
    private var ended = false
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var endNotification: NSObjectProtocol?
    private var timer: Timer?
    private var lastState: PlaybackEngineReading?
    private var audioConfigured = false
    private var nativeLoadID: UUID?
    private var remoteURL: URL?
    private var inspectingNativeFailure = false
    private var deferredHTTPFailure: String?
    private var deferredNativeInterruption: Error?

    public convenience init(muted: Bool = false,
                source: @escaping @MainActor (LibraryEpisode) throws -> URL = AVPlayerPlaybackEngine.mediaURL,
                localDocument: LocalPlaybackDocument? = nil,
                credentials: (@Sendable (LibraryEpisode) async throws -> FeedCredentials?)? = nil,
                urlResolver: PlaybackURLResolver? = nil,
                proxyClient: (@Sendable () -> ProxyNetworkEnvironment.Client)? = nil,
                userAgent: String = HTTPUserAgent.unversioned,
                configureAudioSession: (@MainActor () throws -> Void)? = nil) {
        self.init(muted: muted, source: source, localDocument: localDocument, credentials: credentials, urlResolver: urlResolver,
            proxyClient: proxyClient, userAgent: userAgent, configureAudioSession: configureAudioSession, sessionOwner: .shared)
    }

    init(muted: Bool = false,
         source: @escaping @MainActor (LibraryEpisode) throws -> URL = AVPlayerPlaybackEngine.mediaURL,
         localDocument: LocalPlaybackDocument? = nil,
         credentials: (@Sendable (LibraryEpisode) async throws -> FeedCredentials?)? = nil,
         urlResolver: PlaybackURLResolver? = nil,
         proxyClient: (@Sendable () -> ProxyNetworkEnvironment.Client)? = nil,
         userAgent: String = HTTPUserAgent.unversioned,
         configureAudioSession: (@MainActor () throws -> Void)? = nil,
         sessionOwner: AudioSessionOwner) {
        session = AudioSessionActivationController(owner: sessionOwner)
        self.muted = muted
        self.localDocument = localDocument
        self.source = source
        self.credentials = credentials
        self.urlResolver = urlResolver
        self.proxyClient = proxyClient; self.userAgent = userAgent
        self.makeHTTPSource = {
            try ProgressiveHTTPMediaSource(url: $0, unknownLengthHandling: .nativePlayback,
                userAgent: userAgent, onFailure: $1)
        }
        self.configureAudioSession = configureAudioSession ?? {
#if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
#endif
        }
        session.onResult = { [weak self] result in self?.activationFinished(result) }
        session.onSystemEvent = { [weak self] event in self?.receiveSystemEvent(event) }
    }

    isolated deinit { unload() }

    public static func mediaURL(_ episode: LibraryEpisode) throws -> URL {
        guard let media = episode.details.media else { throw PlaybackSourceError.missingMedia }
        if episode.userState.isDownloaded, let path = episode.userState.localFileURL {
            guard !path.contains("\0") else { throw PlaybackSourceError.invalidURL }
            return URL(fileURLWithPath: path)
        }
        guard let text = media.url, let url = URL(string: text),
              ["https", "http", "file"].contains(url.scheme?.lowercased() ?? ""),
              url.isFileURL || url.host?.isEmpty == false else { throw PlaybackSourceError.invalidURL }
        return url
    }

    static func assetOptions(for episode: LibraryEpisode, url: URL) -> [String: Any] {
        guard url.isFileURL, url.pathExtension.isEmpty || url.pathExtension.lowercased() == "media" else { return [:] }
        let originalExtension = episode.details.media?.url.flatMap { URL(string: $0)?.pathExtension }
        let inferredType = originalExtension.flatMap { UTType(filenameExtension: $0)?.preferredMIMEType }
        for type in [episode.details.media?.mimeType, inferredType].compactMap({ $0 }) {
            if AVURLAsset.isPlayableExtendedMIMEType(type) { return [AVURLAssetOverrideMIMETypeKey: type] }
        }
        return [:]
    }

    public func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        unload()
        activeProxy = proxyClient?().configuration ?? .init()
        self.generation = generation
        commandID = generation
        pendingPosition = max(0, positionMilliseconds)
        do {
            if let localDocument {
                let loadID = UUID(); nativeLoadID = loadID
                let source = LocalPlaybackAssetLoader(document: localDocument) { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == generation, self.nativeLoadID == loadID else { return }
                        self.fail(error.localizedDescription)
                    }
                }
                localSource = source
                install(asset: source.asset, generation: generation, loadID: loadID, speed: requestedSpeed)
                return
            }
            let url = try source(episode)
            // Downloaded files may have disappeared since the database was saved. Report
            // the native file error directly instead of waiting for opaque-media inspection.
            if url.isFileURL, try !url.checkResourceIsReachable() { throw CocoaError(.fileReadNoSuchFile) }
            let loadID = UUID()
            nativeLoadID = loadID
            if !url.isFileURL, credentials != nil || urlResolver != nil {
                let credentials = credentials, resolver = urlResolver
                credentialTask = Task { [weak self] in
                    do {
                        let login = try await credentials?(episode)
                        try Task.checkCancellation()
                        let resolved = try await resolver?.resolve(url) ?? url
                        try Task.checkCancellation()
                        guard let self, self.generation == generation, self.nativeLoadID == loadID else { return }
                        credentialTask = nil
                        // Resolving a redirect cannot grant a new origin the saved media login.
                        let scopedLogin = HTTPOrigin.matches(url, resolved) ? login : nil
                        try installSource(resolved, episode: episode, credentials: scopedLogin, generation: generation, loadID: loadID)
                    } catch {
                        guard !Task.isCancelled, let self, self.generation == generation, self.nativeLoadID == loadID else { return }
                        credentialTask = nil; fail(error.localizedDescription)
                    }
                }
                return
            }
            try installSource(url, episode: episode, credentials: nil, generation: generation, loadID: loadID)
        } catch { fail(error.localizedDescription) }
    }

    private func installSource(_ url: URL, episode: LibraryEpisode, credentials: FeedCredentials?, generation: UUID, loadID: UUID) throws {
        let asset: AVURLAsset
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            remoteURL = url
            authentication = PlaybackHTTPAuthentication(url: url, credentials: credentials)
            let failed: @Sendable (Error) -> Void = { [weak self] error in
                Task { @MainActor in self?.httpFailed(error, generation: generation, loadID: loadID) }
            }
            let source: ProgressiveHTTPMediaSource
            if authentication != nil || proxyClient != nil {
                source = try ProgressiveHTTPMediaSource(url: url, unknownLengthHandling: .nativePlayback,
                    credentials: authentication?.credentials, proxy: activeProxy, userAgent: userAgent, onFailure: failed)
            } else { source = try makeHTTPSource(url, failed) }
            source.observeRetryState { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == generation, self.nativeLoadID == loadID, !self.failed else { return }
                    self.deferredHTTPFailure = error?.localizedDescription
                    self.failIfRetryBufferIsUnavailable()
                }
            }
            httpSource = source; asset = source.asset
        } else { asset = AVURLAsset(url: url, options: Self.assetOptions(for: episode, url: url)) }
        install(asset: asset, generation: generation, loadID: loadID, speed: requestedSpeed)
    }

    private func install(asset: AVURLAsset, generation: UUID, loadID: UUID, speed: Float) {
        let item = AVPlayerItem(asset: asset)
        do {
            let tap = try PlaybackVolumeTap(setting: tapVolume,
                baseVolume: usesNativeSleepVolume ? 1 : sleepTimerVolume, measure: measureVolumeForTesting)
            volumeTap = tap
        } catch { fail(error.localizedDescription); return }
        let player = AVPlayer(playerItem: item)
        // Post-effects taps receive silence when AVPlayer is muted. Measurement tests
        // silence each processed buffer after inspecting it instead.
        player.isMuted = muted && !measureVolumeForTesting
        player.defaultRate = speed
        player.volume = nativeVolume
        nativePlayer = player
        observations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh(generation: generation, loadID: loadID) }
            },
            item.observe(\.tracks, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh(generation: generation, loadID: loadID) }
            },
            item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh(generation: generation, loadID: loadID) }
            },
            item.observe(\.duration, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh(generation: generation, loadID: loadID) }
            },
            player.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh(generation: generation, loadID: loadID) }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh(generation: generation, loadID: loadID) }
            }
        ]
        notifications = [NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? "Playback failed", local = Self.isLocalRelayFailure(error)
            let reset = Self.isServicesReset(error)
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.nativeLoadID == loadID else { return }
                if reset { self.closeAfterServicesReset() }
                else if local, self.nativeRelay != nil { self.relayRouteLost() } else { self.fail(message) }
            }
        }]
        if nativeRelay != nil { notifications.append(observeRelayErrors(item: item, generation: generation, loadID: loadID)) }
    }

    public func play(commandID: UUID) {
        guard generation != nil, !failed else { return }
        self.commandID = commandID
        wantsPlayback = true
        ended = false
        if rebuildRelayRouteOnDemand(seeking: false) { return }
        if prepared { startPlayback(); publishState(force: true) }
    }

    public func pause(commandID: UUID) {
        self.commandID = commandID
        wantsPlayback = false
        nativePlayer?.pause()
        stopTimer()
        if prepared, !failed, !ended { publishState(force: true) }
    }

    public func seek(to positionMilliseconds: Int64, commandID: UUID) {
        guard generation != nil, !failed else { return }
        self.commandID = commandID
        pendingPosition = max(0, positionMilliseconds)
        ended = false
        if rebuildRelayRouteOnDemand(seeking: true) { return }
        if nativePlayer?.currentItem?.status == .readyToPlay { beginSeek() }
    }

    public func setSpeed(_ speed: Float, commandID: UUID) throws {
        guard speed.isFinite, speed > 0 else { throw PlaybackSpeedError.invalidSpeed }
        guard generation != nil, !failed else { return }
        self.commandID = commandID
        requestedSpeed = speed
        nativePlayer?.defaultRate = speed
        // defaultRate alone never starts paused playback. Reapply play only for an active intent.
        if prepared, wantsPlayback { startPlayback() }
        if prepared { publishState(force: true) }
    }

    public func setVolumeAdaptation(_ setting: FeedVolumeAdaptation) throws {
        guard generation != nil, !failed else { return }
        requestedVolume = setting
        volumeTap?.set(tapVolume)
        nativePlayer?.volume = nativeVolume
    }

    // On the native URL route (HLS, open-ended relay) the processing tap receives no samples
    // on iOS 27 (0 frames with either the mixed or the concrete audio track; Duo 27.1). There,
    // attenuation — the feed volume reductions and the sleep-timer fade — uses AVPlayer's own
    // output volume, as Android applies attenuation through its player volume. Boosts need
    // sample access and stay with the tap, which still processes them wherever the platform
    // delivers samples; HLS boosts on iOS remain a recorded gap.
    private var usesNativeSleepVolume: Bool { httpSource == nil && remoteURL != nil }
    private var tapVolume: FeedVolumeAdaptation {
        usesNativeSleepVolume && requestedVolume.factor < 1 ? .off : requestedVolume
    }
    private var nativeVolume: Float {
        guard usesNativeSleepVolume else { return 1 }
        return max(0, min(1, sleepTimerVolume)) * min(1, requestedVolume.factor)
    }
    public func setSleepTimerVolume(_ volume: Float) throws {
        sleepTimerVolume = volume
        volumeTap?.setBaseVolume(usesNativeSleepVolume ? 1 : volume)
        nativePlayer?.volume = nativeVolume
    }

    public func unload() {
        releaseSession()
        credentialTask?.cancel(); credentialTask = nil
        relayTask?.cancel(); relayTask = nil
        nativeRelay?.cancel(); nativeRelay = nil
        relayTrust = nil; reclaimedRelay = nil; rebuildingRelayRoute = false; relayRepair = nil; relayRebuildInProgress = false
        nativeAuthentication?.cancel(); nativeAuthentication = nil
        deferredHTTPFailure = nil
        deferredNativeInterruption = nil
        authentication = nil; requestedSpeed = 1; requestedVolume = .off; sleepTimerVolume = 1
        generation = nil
        nativeLoadID = nil
        remoteURL = nil
        httpSource?.cancel()
        httpSource = nil
        localSource?.cancel(); localSource = nil
        commandID = nil
        seekID = nil
        retireNativePlayer()
        pendingPosition = nil
        prepared = false
        wantsPlayback = false
        failed = false
        ended = false
        lastState = nil
        audioConfigured = false
    }

    private func retireNativePlayer() {
        stopTimer()
        inspectingNativeFailure = false
        observations.removeAll()
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        notifications.removeAll()
        if let endNotification { NotificationCenter.default.removeObserver(endNotification) }
        endNotification = nil
        endSeekID = nil
        nativePlayer?.pause()
        nativePlayer?.currentItem?.cancelPendingSeeks()
        nativePlayer?.replaceCurrentItem(with: nil)
        nativePlayer = nil
        volumeTap = nil
    }

    private func refresh(generation: UUID, loadID: UUID) {
        guard generation == self.generation, nativeLoadID == loadID, !failed, !ended,
              let player = nativePlayer, let item = player.currentItem else { return }
        if item.status == .failed || player.status == .failed {
            if Self.isServicesReset(item.error ?? player.error) { closeAfterServicesReset(); return }
            let message = (item.error ?? player.error)?.localizedDescription ?? "Playback failed"
            if nativeRelay != nil, Self.isLocalRelayFailure(item.error ?? player.error) { relayRouteLost(); return }
            if let source = httpSource {
                guard !inspectingNativeFailure else { return }
                inspectingNativeFailure = true
                // Loader failure may reach AVPlayer before the source callback reaches MainActor.
                // Inspect the serial source state before publishing a misleading source-selection error.
                Task { @MainActor [weak self] in
                    let snapshot = await source.snapshot()
                    guard let self, self.generation == generation, self.nativeLoadID == loadID, !self.failed else { return }
                    self.inspectingNativeFailure = false
                    if snapshot.requiresNativePlayback { self.useNativeURL(generation: generation, loadID: loadID, playlist: snapshot.requiresNativePlaylist) }
                    else { self.fail(snapshot.failure ?? message) }
                }
            } else { fail(message) }
            return
        }
        if resumeDeferredNativeStreamIfNeeded() { return }
        failIfRetryBufferIsUnavailable()
        guard !failed, item.status == .readyToPlay else { return }
        // Native URL fallback includes HLS, whose documented processing contract
        // requires a combined-track tap. Custom progressive/local assets expose tracks.
        volumeTap?.bind(to: item, preferConcreteTrack: httpSource != nil || remoteURL == nil)
        if !prepared {
            if seekID == nil { beginSeek() }
        } else if seekID == nil {
            // A player paused by the system (not while it waits for the session to be activated).
            if wantsPlayback, activationRequest == nil, player.timeControlStatus == .paused {
                wantsPlayback = false
                stopTimer()
            }
            publishState()
        }
    }

    private func failIfRetryBufferIsUnavailable() {
        guard let message = deferredHTTPFailure, !failed else { return }
        guard let player = nativePlayer, let item = player.currentItem, item.status == .readyToPlay else {
            fail(message); return
        }
        let position = pendingPosition.map { Double($0) / 1000 } ?? player.currentTime().seconds
        // AVPlayer's playable buffered ranges determine whether it can still serve audio;
        // cached network bytes alone do not establish a playable buffer.
        let buffered = item.loadedTimeRanges.contains { value in
            let range = value.timeRangeValue
            return range.start.seconds <= position + 0.001 && range.end.seconds > position + 0.001
        }
        if item.isPlaybackBufferEmpty || !buffered { fail(message) }
    }

    private func httpFailed(_ error: Error, generation: UUID, loadID: UUID) {
        guard self.generation == generation, nativeLoadID == loadID, !failed, !ended else { return }
        if (error as? StreamingAudioTypeError) == .requiresNativePlaylist
            || error is ProgressiveHTTPMediaSource.NativeRoutingReason {
            useNativeURL(generation: generation, loadID: loadID, playlist: (error as? StreamingAudioTypeError) == .requiresNativePlaylist)
        } else { fail(error.localizedDescription) }
    }

    private func useNativeURL(generation: UUID, loadID: UUID, playlist: Bool) {
        guard self.generation == generation, nativeLoadID == loadID, !prepared,
              let url = remoteURL, let source = httpSource else { return }
        let speed = nativePlayer?.defaultRate ?? 1
        let replacement = UUID()
        nativeLoadID = replacement
        httpSource = nil
        source.cancel()
        seekID = nil
        retireNativePlayer()
        installNativeURL(url, playlist: playlist, generation: generation, loadID: replacement, speed: speed)
    }

    private func installNativeURL(_ url: URL, playlist: Bool, generation: UUID, loadID: UUID, speed: Float) {
        // Unknown-duration media needs app-owned interruption timing for direct and
        // configured-proxy playback. Native playlist loading retains its existing path.
        if activeProxy.isConfigured || !playlist {
            let proxy = activeProxy, credentials = authentication?.credentials, userAgent = userAgent
            relayTask = Task { [weak self] in
                do {
                    var interrupted: (@Sendable (Error) -> Void)?
                    if !playlist {
                        interrupted = { [weak self] error in
                            Task { @MainActor in
                                guard let self, self.generation == generation, self.nativeLoadID == loadID, !self.failed else { return }
                                self.deferredNativeInterruption = error
                                _ = self.resumeDeferredNativeStreamIfNeeded()
                            }
                        }
                    }
                    let relay = try await NativeStreamingRelay.start(url: url, playlist: playlist, proxy: proxy,
                        credentials: credentials, userAgent: userAgent, onInterruption: interrupted, onFailure: { [weak self] error in
                            Task { @MainActor in self?.httpFailed(error, generation: generation, loadID: loadID) }
                        })
                    try Task.checkCancellation()
                    guard let self, self.generation == generation, nativeLoadID == loadID else { relay.cancel(); return }
                    relayTask = nil; nativeRelay = relay
                    trustRelay(playlist: playlist)
#if DEBUG
                    if reclaimsNewRelaysForTesting { relay.simulateSocketReclaim() }
#endif
                    let asset = AVURLAsset(url: relay.url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidCrossSiteReference.rawValue])
                    install(asset: asset, generation: generation, loadID: loadID, speed: requestedSpeed)
                } catch {
                    guard !Task.isCancelled, let self, self.generation == generation, nativeLoadID == loadID else { return }
                    relayTask = nil; fail(error.localizedDescription)
                }
            }
            return
        }
        // Native URL loading preserves playlist resolution and open-ended streaming. Keep the caller's
        // pending seek, current command and play/pause intent through source selection.
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: userAgent])
        if let authentication {
            let delegate = NativePlaybackAuthentication(authentication) { [weak self] error in
                Task { @MainActor in self?.httpFailed(error, generation: generation, loadID: loadID) }
            }
            nativeAuthentication = delegate
            asset.resourceLoader.setDelegate(delegate, queue: delegate.queue)
        }
        install(asset: asset, generation: generation, loadID: loadID, speed: speed)
    }

    @discardableResult private func resumeDeferredNativeStreamIfNeeded() -> Bool {
        guard let interruption = deferredNativeInterruption, !failed, !ended,
              let player = nativePlayer, let item = player.currentItem,
              let generation, let url = remoteURL else { return false }
        guard prepared, item.status == .readyToPlay, !item.duration.seconds.isFinite else {
            fail(interruption.localizedDescription); return true
        }
        // Open-ended native ranges need not describe all buffered audio. Use the
        // player's actual starvation signal, not a synthetic duration or byte estimate.
        guard item.isPlaybackBufferEmpty else { return false }
        if var reading {
            reading.buffering = wantsPlayback
            onEvent?(.stateChanged(reading))
        }
        if let reading { onEvent?(.timelineReset(reading)) }
        deferredNativeInterruption = nil
        let replacement = UUID()
        nativeLoadID = replacement
        retireNativePlayer()
        nativeRelay?.cancel(); nativeRelay = nil
        prepared = false; seekID = nil; pendingPosition = 0; lastState = nil
        installNativeURL(url, playlist: false, generation: generation, loadID: replacement, speed: requestedSpeed)
        return true
    }

    private func beginSeek() {
        guard let player = nativePlayer, let item = player.currentItem,
              let generation, let target = pendingPosition else { return }
        failIfRetryBufferIsUnavailable()
        guard !failed else { return }
        let id = UUID()
        seekID = id
        publishState(force: true)
        observeEnd(item: item, generation: generation, seekID: id)
        player.seek(to: CMTime(value: target, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == generation, self.seekID == id, !self.failed else { return }
                self.seekID = nil
                // A newer target that was not issued yet is sought now; this completion settles only its own.
                if let newer = self.pendingPosition, newer != target { self.beginSeek(); return }
                self.pendingPosition = nil
                if !finished && !self.prepared { self.fail("Initial seek did not complete"); return }
                // A rebuilt relay route continues the prepared item; it is not ready again.
                let firstReady = !self.prepared && !self.rebuildingRelayRoute
                self.prepared = true; self.reclaimedRelay = nil; self.rebuildingRelayRoute = false; self.relayRebuildInProgress = false
                if finished { self.noteRelayProgress(reaching: target) }
                if firstReady, let reading = self.reading { self.onEvent?(.ready(reading)) }
                if self.wantsPlayback { self.startPlayback() }
                self.publishState(force: true)
            }
        }
    }

    private func observeEnd(item: AVPlayerItem, generation: UUID, seekID: UUID) {
        if let endNotification { NotificationCenter.default.removeObserver(endNotification) }
        endNotification = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.endSeekID == seekID,
                      self.prepared, !self.failed, !self.ended, self.seekID == nil, var reading = self.reading else { return }
                self.ended = true
                self.wantsPlayback = false
                self.stopTimer()
                reading.sample.status = .other
                self.onEvent?(.ended(reading))
            }
        }
        endSeekID = seekID
    }

    private var endSeekID: UUID?

    /// Asks the session owner for the session; the player starts when it is active (this engine
    /// configures the category itself, so the owner does not).
    private func startPlayback() {
        do {
            if !audioConfigured { try configureAudioSession(); audioConfigured = true }
            activationRequest = try session.request(active: true, prepare: false)
        } catch { fail(error.localizedDescription) }
    }

    private func activationFinished(_ result: AudioSessionActivationController.Result) {
        guard result.requestID == activationRequest else { return }
        activationRequest = nil
        guard result.active, prepared, wantsPlayback, !failed, !ended, generation != nil else { return }
        switch result.outcome {
        case .applied:
            nativePlayer?.play()
            startTimer()
        case .declined:
            // Another audio session holds the device (a call): stay paused, as the processed engine does.
            wantsPlayback = false
            publishState(force: true)
        case .failed:
            fail(result.error?.localizedDescription ?? "Audio session activation failed")
        }
    }

    /// Playback of this item stopped for good: the owner deactivates the session unless a newer engine holds it.
    private func releaseSession() {
        activationRequest = nil
        _ = try? session.request(active: false, prepare: false)
    }

    private func publishState(force: Bool = false) {
        guard let reading else { return }
        if force || lastState?.commandID != reading.commandID || lastState?.sample.status != reading.sample.status
            || lastState?.buffering != reading.buffering || lastState?.sample.durationMilliseconds != reading.sample.durationMilliseconds {
            lastState = reading
            onEvent?(.stateChanged(reading))
        }
    }

    private func fail(_ message: String) {
        guard !failed, let generation else { return }
        failed = true
        credentialTask?.cancel(); credentialTask = nil
        relayTask?.cancel(); relayTask = nil
        nativeRelay?.cancel(); nativeRelay = nil
        reclaimedRelay = nil; rebuildingRelayRoute = false; relayRebuildInProgress = false
        nativeAuthentication?.cancel()
        wantsPlayback = false
        httpSource?.cancel()
        httpSource = nil
        localSource?.cancel(); localSource = nil
        nativePlayer?.pause()
        stopTimer()
        releaseSession()
        onEvent?(.failed(generation: generation, message: message))
    }

    // A media-services reset is not a playback failure. After it every AVFoundation object of the item is
    // invalid (Apple QA1749): the player and its sources are retired at once and the coordinator keeps the item
    // selected and paused at its position, with no dialog; only an explicit Play loads it again. The reset may be
    // observed first as the session event or as the item's error; `failed` then fences every later callback of the
    // item. Other session events go to the relay route's handling (an interruption during its rebuild).

    private func receiveSystemEvent(_ event: AudioSessionEvent) {
        switch event {
        case .mediaServicesLost, .mediaServicesReset: closeAfterServicesReset()
        default: interruptedDuringRelayRebuild(event)
        }
    }

    nonisolated private static func isServicesReset(_ error: (any Error)?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == AVFoundationErrorDomain && error.code == mediaServicesWereResetCode
    }
#if os(iOS)
    nonisolated private static let mediaServicesWereResetCode = AVError.Code.mediaServicesWereReset.rawValue
#else
    /// `AVError.mediaServicesWereReset`, which host builds do not declare.
    nonisolated private static let mediaServicesWereResetCode = -11819
#endif

    /// Retires every audio object of this item and reports its final reading, paused; later callbacks are fenced as
    /// after a failure, without reporting one.
    private func closeAfterServicesReset() {
        guard let generation, let commandID, !failed, !ended else { return }
        var final = reading ?? PlaybackEngineReading(generation: generation, commandID: commandID,
            sample: .init(positionMilliseconds: Int32(truncatingIfNeeded: pendingPosition ?? 0), durationMilliseconds: -1,
                          status: .paused), speed: requestedSpeed, isPrepared: false)
        final.sample.status = .paused
        final.buffering = false
        failed = true
        wantsPlayback = false
        credentialTask?.cancel(); credentialTask = nil
        relayTask?.cancel(); relayTask = nil
        nativeRelay?.cancel(); nativeRelay = nil
        // The relay route's rebuild ends with the item, as on a failure; its tasks are fenced by `failed`.
        reclaimedRelay = nil; rebuildingRelayRoute = false; relayRebuildInProgress = false
        nativeAuthentication?.cancel()
        httpSource?.cancel(); httpSource = nil
        localSource?.cancel(); localSource = nil
        retireNativePlayer()
        releaseSession()
        onEvent?(.mediaServicesReset(final))
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsPlayback, !self.failed, !self.ended, let reading = self.reading else { return }
                if let status = self.volumeTap?.failure, status != noErr {
                    self.fail("Audio volume processing failed (\(status))")
                    return
                }
                if self.resumeDeferredNativeStreamIfNeeded() { return }
                self.failIfRetryBufferIsUnavailable()
                guard !self.failed else { return }
                self.noteRelayProgress(reaching: nil)
                self.onEvent?(.position(reading))
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    static func milliseconds(_ time: CMTime, fallback: Int64) -> Int64 {
        guard time.isNumeric else { return fallback }
        return CMTimeConvertScale(time, timescale: 1_000, method: .roundTowardZero).value
    }
}

// MARK: - The relay route lets iOS reclaim its sockets
//
// A new URL cannot repair an AVURLAsset or the relay addresses in its rewritten playlist.
// When the app becomes eligible for suspension, a paused relay route (proxied playlist or
// open-ended stream) retires its item and relay; Play or a seek then installs a new relay
// generation and item. A relay that dies without notice is found from the item's own
// signals (a refused connection to the loopback relay) and rebuilt the same way, once per
// epoch until the replacement loads; a repeated loss ends as the relay being unavailable.
// A finite item keeps its position, the latest seek and the play intent; an open-ended
// stream keeps today's reconnection: a new live period at zero.

/// What a retired relay route keeps to continue.
private struct ReclaimedRelayRoute {
    let positionMilliseconds: Int64
    let durationMilliseconds: Int32
    let seekable: Bool
    let live: Bool
}

/// The registry calls on any thread; the engine reconciles on the main actor.
private final class RelayRouteParticipant: StreamingRelayReclaimParticipant, @unchecked Sendable {
    private weak var engine: AVPlayerPlaybackEngine?
    init(engine: AVPlayerPlaybackEngine) { self.engine = engine }
    func reclaimLifecycleChanged() { Task { @MainActor [weak engine] in engine?.reconcileRelayLifecycle() } }
}

extension AVPlayerPlaybackEngine {
    fileprivate func trustRelay(playlist: Bool) {
        relayPlaylist = playlist
        // A relay started while the app may be suspended is never trusted.
        relayTrust = relayReclaim.isSuspended ? nil : relayReclaim.suspensions
        if relayParticipant == nil {
            let participant = RelayRouteParticipant(engine: self)
            relayParticipant = participant
            relayReclaim.register(participant)
        }
    }

    fileprivate func reclaimedReading(_ route: ReclaimedRelayRoute, generation: UUID, commandID: UUID) -> PlaybackEngineReading {
        .init(generation: generation, commandID: commandID,
              sample: .init(positionMilliseconds: Int32(truncatingIfNeeded: pendingPosition ?? route.positionMilliseconds),
                            durationMilliseconds: route.durationMilliseconds, seekable: route.seekable,
                            status: wantsPlayback ? .playing : .paused),
              buffering: rebuildingRelayRoute && (wantsPlayback || pendingPosition != nil), speed: requestedSpeed)
    }

    /// Applies each registry epoch once, reading the current lifecycle: a delayed notification
    /// cannot retire a route after a newer demand. Becoming eligible retires a paused route.
    fileprivate func reconcileRelayLifecycle() {
        let lifecycle = relayReclaim.lifecycle
        guard lifecycle.epoch > relayLifecycleEpoch else { return }
        relayLifecycleEpoch = lifecycle.epoch
        guard lifecycle.suspended, reclaimedRelay == nil, nativeRelay != nil, prepared, !wantsPlayback, seekID == nil,
              let route = captureRelayRoute() else { return }
        reclaimedRelay = route
        releaseRelayRoute()
    }

    /// Play or a seek: a retired route, or one whose relay outlived a suspension it was not
    /// retired for (iOS may have closed it without notice), continues on a new relay. A seek
    /// while a replacement prepares is issued on it, superseding the older native seek.
    fileprivate func rebuildRelayRouteOnDemand(seeking: Bool) -> Bool {
        guard !failed, generation != nil, remoteURL != nil else { return false }
        if let reclaimedRelay {
            if rebuildingRelayRoute {
                if seeking, nativePlayer?.currentItem?.status == .readyToPlay { beginSeek() } else { publishState(force: true) }
                return true
            }
            rebuildRelayRoute(reclaimedRelay)
            return true
        }
        guard nativeRelay != nil, relayTrust != relayReclaim.suspensions, prepared, seekID == nil,
              nativePlayer?.timeControlStatus == .paused, let captured = captureRelayRoute() else { return false }
        releaseRelayRoute()
        rebuildRelayRoute(captured)
        return true
    }

    /// The item reported a refused connection to the loopback relay: the relay died without
    /// notice. The first loss in an epoch (or after the last replacement loaded) rebuilds the
    /// route; another one ends playback as the relay being unavailable, never as a media problem.
    fileprivate func relayRouteLost() {
        guard !failed, let generation, let url = remoteURL else { return }
        let epoch = relayReclaim.epoch
        if let relayRepair, relayRepair.epoch == epoch, !relayRepair.progressed {
            fail(StreamingRelayUnavailable.message); return
        }
        let route = reclaimedRelay ?? captureRelayRoute()
        relayRepair = (epoch, route?.positionMilliseconds ?? pendingPosition ?? 0, false)
        guard let route else {
            // Never prepared: load again on a new relay, as the first time (its pending seek kept).
            releaseRelayRoute()
            seekID = nil; lastState = nil; relayRebuildInProgress = true
            let loadID = UUID()
            nativeLoadID = loadID
            installNativeURL(url, playlist: relayPlaylist, generation: generation, loadID: loadID, speed: requestedSpeed)
            return
        }
        releaseRelayRoute()
        rebuildRelayRoute(route)
    }

    private func rebuildRelayRoute(_ route: ReclaimedRelayRoute) {
        guard let generation, let commandID, let url = remoteURL else { return }
        lastState = nil; seekID = nil; prepared = false; relayRebuildInProgress = true
        if route.live {
            // As when an open-ended stream's connection drops: the heard period ends here.
            var final = reclaimedReading(route, generation: generation, commandID: commandID)
            final.sample.positionMilliseconds = Int32(truncatingIfNeeded: route.positionMilliseconds)
            final.buffering = wantsPlayback
            onEvent?(.stateChanged(final))
            onEvent?(.timelineReset(final))
            reclaimedRelay = nil; rebuildingRelayRoute = false; pendingPosition = 0
        } else {
            reclaimedRelay = route; rebuildingRelayRoute = true
            pendingPosition = pendingPosition ?? route.positionMilliseconds
        }
        let loadID = UUID()
        nativeLoadID = loadID
        installNativeURL(url, playlist: relayPlaylist, generation: generation, loadID: loadID, speed: requestedSpeed)
        if !route.live { publishState(force: true) }
    }

    private func captureRelayRoute() -> ReclaimedRelayRoute? {
        guard prepared, let player = nativePlayer, let item = player.currentItem else { return nil }
        return .init(positionMilliseconds: pendingPosition ?? Self.milliseconds(player.currentTime(), fallback: 0),
                     durationMilliseconds: Int32(truncatingIfNeeded: Self.milliseconds(item.duration, fallback: -1)),
                     seekable: !item.seekableTimeRanges.isEmpty, live: !item.duration.seconds.isFinite)
    }

    /// The item, its observations and the relay's listener and connections all close.
    private func releaseRelayRoute() {
        nativeLoadID = UUID()
        deferredNativeInterruption = nil
        retireNativePlayer()
        relayTask?.cancel(); relayTask = nil
        nativeRelay?.cancel(); nativeRelay = nil
        relayTrust = nil
    }

    /// Every request of a relay route goes to the loopback relay, so a refused connection in
    /// the item's error log means its listener is gone. Upstream outcomes arrive from the relay
    /// itself (`httpFailed`), never as a refused loopback connection.
    fileprivate func observeRelayErrors(item: AVPlayerItem, generation: UUID, loadID: UUID) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.nativeLoadID == loadID,
                      let entry = self.nativePlayer?.currentItem?.errorLog()?.events.last,
                      entry.errorDomain == NSURLErrorDomain, entry.errorStatusCode == URLError.cannotConnectToHost.rawValue else { return }
                self.relayRouteLost()
            }
        }
    }

    /// A refused connection, the one failure only a gone loopback listener produces.
    nonisolated static func isLocalRelayFailure(_ error: (any Error)?) -> Bool {
        var current = error.map { $0 as NSError }
        while let error = current {
            if error.domain == NSURLErrorDomain, error.code == URLError.cannotConnectToHost.rawValue { return true }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ECONNREFUSED) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// The replacement delivered what the repair was for: a seek landed with its media loaded, or
    /// playback advanced past the position where the relay was lost. Only then may a later loss in
    /// the same epoch rebuild again.
    fileprivate func noteRelayProgress(reaching target: Int64?) {
        guard let repair = relayRepair, !repair.progressed, let player = nativePlayer, let item = player.currentItem else { return }
        let seconds: Double
        if let target { seconds = Double(target) / 1000 } else {
            let position = Self.milliseconds(player.currentTime(), fallback: 0)
            guard position > repair.position + 500 else { return }
            seconds = Double(position) / 1000
        }
        let loaded = item.loadedTimeRanges.contains { value in
            let range = value.timeRangeValue
            return range.start.seconds <= seconds + 0.001 && range.end.seconds > seconds + 0.001
        }
        if loaded { relayRepair?.progressed = true }
    }

    /// While a relay route is rebuilt there is no player for the system to pause, so an
    /// interruption that begins then ends the play intent as that pause would (no automatic
    /// resumption, as on every AVPlayer route): the replacement settles paused and asks for no
    /// session. Nothing else is handled here; other AVPlayer playback is unchanged.
    fileprivate func interruptedDuringRelayRebuild(_ event: AudioSessionEvent) {
        guard case .interrupted = event, relayRebuildInProgress, !prepared, wantsPlayback, !failed,
              let generation, let commandID else { return }
        wantsPlayback = false
        stopTimer()
        if reading != nil { publishState(force: true); return }
        // A live or never-prepared replacement has no reading yet. The pause still reaches the
        // coordinator, for this item and command, so a later explicit Play reaches this engine.
        onEvent?(.stateChanged(.init(generation: generation, commandID: commandID,
            sample: .init(positionMilliseconds: Int32(truncatingIfNeeded: pendingPosition ?? 0), durationMilliseconds: -1,
                          seekable: false, status: .paused),
            buffering: false, speed: requestedSpeed, isPrepared: false)))
    }
}

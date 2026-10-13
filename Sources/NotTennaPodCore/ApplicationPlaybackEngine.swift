import AVFoundation
import Foundation

/// Application-owned dispatch across prepared media engines. Commands received
/// while identifying a source belong to that selection, never to a retired item.
/// Media that only AVPlayer can play (HLS, unknown formats) plays without
/// skipping silence and keeps the saved preference for the next item (owner
/// decision; Android 3.12.1 cannot play HLS at all).
@MainActor public final class ApplicationPlaybackEngine: PlaybackSilenceControlling, PlaybackSilencePreferenceRetaining, PlaybackVolumeControlling, PlaybackStatisticsConsumer, PlaybackVideoPresenting, PlaybackInterruptionReporting, PlaybackSessionReserving {
    typealias Resolution = @MainActor () async throws -> any PlaybackEngine
    typealias Resolver = @MainActor (LibraryEpisode) throws -> Resolution
    public var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    public var reading: PlaybackEngineReading? { selected?.reading.map(translated) }
    public var resumesAfterInterruption: Bool {
        (selected as? any PlaybackInterruptionReporting)?.resumesAfterInterruption == true
    }
    private var presentation: (any PlaybackVideoPresenting)? { selected as? any PlaybackVideoPresenting }
    public var videoDisplayLayer: AVSampleBufferDisplayLayer? { presentation?.videoDisplayLayer }
    public var videoPictureInPicture: PlaybackVideoPictureInPicture? { presentation?.videoPictureInPicture }
    public var mediaPresentationID: UUID? { presentation?.mediaPresentationID }
    public var mediaTracks: [PlaybackMediaTrack] { presentation?.mediaTracks ?? [] }
    public var selectedAudioTrackID: Int32? { presentation?.selectedAudioTrackID }
    public var selectedVideoTrackID: Int32? { presentation?.selectedVideoTrackID }
    public func selectAudioTrack(id: Int32, commandID: UUID) throws {
        guard let presentation else { throw PlaybackTrackSelectionError.unsupported }
        relayReclaim.demand()
        try presentation.selectAudioTrack(id: id, commandID: commandID)
        self.commandID = commandID; deliveredCommandID = commandID
    }
    public var supportsSkipSilence: Bool {
        selected.map { ($0 as? any PlaybackSilenceControlling)?.supportsSkipSilence == true } ?? true
    }
    public var retainsSkipSilencePreference: Bool { !supportsSkipSilence }
    struct Prepared {
        let engine: any PlaybackEngine
        var document: LocalPlaybackDocument? = nil
    }
    typealias PreparedResolution = @MainActor () async throws -> Prepared
    private let resolve: @MainActor (LibraryEpisode) throws -> PreparedResolution
    private var document: LocalPlaybackDocument?
    private var selected: (any PlaybackEngine)?
    private var task: Task<Void, Never>?
    private var selection: UUID?
    private var generation: UUID?
    private var commandID: UUID?
    /// The last command delivered to `selected`. A silence command that an
    /// AVPlayer-only item cannot apply is not delivered; that item's readings
    /// for the delivered command answer the newer one, as on a remote route.
    private var deliveredCommandID: UUID?
    private var position: Int64 = 0
    private var speed: Float = 1
    private var silence = false
    private var volume: FeedVolumeAdaptation = .off
    private var sleepTimerVolume: Float = 1
    private var wantsPlayback = false
    private var statistics: (@MainActor (UUID) -> Int64, @MainActor (UUID) async throws -> Void)?
    /// Play, a seek and a track change are demands: streaming relays retired while the
    /// app could be suspended reopen, including for a Lock Screen or remote command.
    var relayReclaim: StreamingRelayReclaim = .shared
    /// The playback session above the media engines: it keeps the audio session while one item replaces
    /// another (the old engine is still closed), through source resolution, until the item's own engine
    /// takes it or playback stops for good.
    private let sessionKeeper: AudioSessionActivationController
    private var keepingSession = false
    private var sessionReserved = false

    init(resolve: @escaping Resolver, sessionOwner: AudioSessionOwner = .shared) {
        self.resolve = { episode in
            let resolution = try resolve(episode)
            return { Prepared(engine: try await resolution()) }
        }
        sessionKeeper = AudioSessionActivationController(owner: sessionOwner)
        sessionKeeper.onSystemEvent = { [weak self] event in self?.receiveSystemEvent(event) }
    }
    init(resolvePrepared: @escaping @MainActor (LibraryEpisode) throws -> PreparedResolution, sessionOwner: AudioSessionOwner = .shared) {
        resolve = resolvePrepared
        sessionKeeper = AudioSessionActivationController(owner: sessionOwner)
        sessionKeeper.onSystemEvent = { [weak self] event in self?.receiveSystemEvent(event) }
    }
    isolated deinit { unload() }

    /// A media-services reset while the item's source is still being resolved (credentials, a local document, the
    /// format): no engine of it exists yet to report the reset, so this one does. The pending resolution is
    /// invalidated: its late result is closed and never receives the Play it was asked for. The item stays selected
    /// and paused, and an explicit Play resolves it again (QA1749). An engine that exists reports its own reset.
    private func receiveSystemEvent(_ event: AudioSessionEvent) {
        guard event == .mediaServicesReset || event == .mediaServicesLost,
              selected == nil, task != nil, selection != nil, let generation else { return }
        let final = PlaybackEngineReading(generation: generation, commandID: commandID,
            sample: .init(positionMilliseconds: Int32(truncatingIfNeeded: position), durationMilliseconds: 0, status: .paused),
            speed: speed, skipSilence: silence, isPrepared: false)
        selection = nil
        task?.cancel(); task = nil
        wantsPlayback = false
        releaseSession()
        onEvent?(.mediaServicesReset(final))
    }

#if os(iOS)
    public convenience init(muted: Bool = false,
        source: @escaping @MainActor (LibraryEpisode) throws -> URL = AVPlayerPlaybackEngine.mediaURL,
        localAccess: LocalPlaybackAccess? = nil,
        credentials: (@Sendable (LibraryEpisode) async throws -> FeedCredentials?)? = nil,
        urlResolver: PlaybackURLResolver? = nil,
        proxyClient: (@Sendable () -> ProxyNetworkEnvironment.Client)? = nil,
        userAgent: String = HTTPUserAgent.unversioned,
        cacheDirectory: URL = URL.cachesDirectory.appendingPathComponent("streaming", isDirectory: true),
        pauseOnDisconnect: @escaping @MainActor () -> Bool = { true }) {
        let factories = PCMPlaybackFactory(cacheDirectory: cacheDirectory,
            minimumQueuedSeconds: PCMRecoveryFactory.productionQueuedSeconds,
            makeTransport: { NativeSampleBufferTransport(muted: muted) })
        self.init(muted: muted, source: source, localAccess: localAccess, credentials: credentials,
            urlResolver: urlResolver, proxyClient: proxyClient, userAgent: userAgent, factories: factories,
            makePCMEngine: { factory, url in
                // Every engine claims the one app-wide session owner, which observes the system events.
                PCMPlaybackEngine(sessionOwner: .shared, resolveFactory: { _, _ in factory }, source: { _ in url },
                    pauseOnDisconnectProvider: pauseOnDisconnect)
            })
    }
#endif

    /// Shared application routing boundary. Host tests inject only the PCM
    /// transport/session driver; document resolution and both format routes are real.
    convenience init(muted: Bool, source: @escaping @MainActor (LibraryEpisode) throws -> URL,
        localAccess: LocalPlaybackAccess?,
        credentials: (@Sendable (LibraryEpisode) async throws -> FeedCredentials?)? = nil,
        urlResolver: PlaybackURLResolver? = nil,
        proxyClient: (@Sendable () -> ProxyNetworkEnvironment.Client)? = nil,
        userAgent: String = HTTPUserAgent.unversioned, factories: PCMPlaybackFactory,
        makePCMEngine: @escaping @MainActor (PCMRecoveryFactory, URL) -> any PlaybackEngine) {
        self.init(resolvePrepared: { episode in
            // Preserve synchronous route/proxy capture. Registered files resolve
            // from their bookmark before consulting a possibly obsolete saved URL.
            let original = Result { try source(episode) }
            let client = proxyClient?() ?? ProxyNetworkEnvironment.Client(configuration: PodcastProxy())
            return {
                if let localAccess, let document = try await localAccess.open(episode: episode) {
                    do {
                        let engine: any PlaybackEngine
                        if let factory = try await factories.processedIfSupported(document: document) {
                            engine = makePCMEngine(factory, URL(string: "antennapod-local://\(UUID().uuidString)/media")!)
                        } else {
                            engine = AVPlayerPlaybackEngine(muted: muted, localDocument: document)
                        }
                        do {
                            guard try await localAccess.confirm(document) else { throw CancellationError() }
                            try Task.checkCancellation()
                            return Prepared(engine: engine, document: document)
                        } catch { engine.unload(); throw error }
                    } catch { document.close(); throw error }
                }
                let original = try original.get()
                if original.isFileURL, try !original.checkResourceIsReachable() { throw CocoaError(.fileReadNoSuchFile) }
                let login = original.isFileURL ? nil : try await credentials?(episode)
                let resolved = try await urlResolver?.resolve(original) ?? original
                try Task.checkCancellation()
                let scopedLogin = HTTPOrigin.matches(original, resolved) ? login : nil
                if let factory = try await factories.processedIfSupported(url: resolved, proxy: client.configuration,
                    credentials: scopedLogin, userAgent: userAgent) {
                    return Prepared(engine: makePCMEngine(factory, resolved))
                }
                return Prepared(engine: AVPlayerPlaybackEngine(muted: muted, source: { _ in resolved },
                    credentials: { _ in scopedLogin }, proxyClient: { client }, userAgent: userAgent))
            }
        })
    }

    public func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        unload()
        sessionReserved = false // This item inherits a reserved session.
        let id = UUID(); selection = id
        self.generation = generation; commandID = generation; position = max(0, positionMilliseconds)
        let resolution: PreparedResolution
        do { resolution = try resolve(episode) }
        catch { releaseSession(); onEvent?(.failed(generation: generation, message: error.localizedDescription)); return }
        task = Task { [weak self] in
            do {
                let prepared = try await resolution(), engine = prepared.engine
                guard !Task.isCancelled, let self, self.selection == id else {
                    engine.unload(); prepared.document?.close(); return
                }
                self.task = nil; self.selected = engine; self.document = prepared.document
                engine.onEvent = { [weak self] event in
                    guard let self, self.selection == id else { return }
                    let translated = self.translated(event)
                    switch event {
                    case .failed, .mediaServicesReset:
                        // A reset item's audio objects are invalid: retired at once, like a failed one. The
                        // coordinator keeps the item selected and paused; an explicit Play loads it again.
                        self.selection = nil
                        self.retireSelected()
                        self.releaseSession()
                    default: break
                    }
                    self.onEvent?(translated)
                }
                if let statistics { (engine as? any PlaybackStatisticsConsumer)?.bindStatistics(lastPlayed: statistics.0, synchronize: statistics.1) }
                engine.load(episode: episode, generation: generation, positionMilliseconds: position)
                guard self.selection == id, let commandID else { return }
                self.deliveredCommandID = commandID
                try engine.setSpeed(speed, commandID: commandID)
                try (engine as? any PlaybackVolumeControlling)?.setVolumeAdaptation(volume)
                try (engine as? any PlaybackVolumeControlling)?.setSleepTimerVolume(sleepTimerVolume)
                (engine as? any PlaybackSilenceControlling)?.setSkipSilence(silence, commandID: commandID)
                if wantsPlayback { engine.play(commandID: commandID) }
                else { engine.pause(commandID: commandID) }
            } catch {
                guard !Task.isCancelled, let self, self.selection == id else { return }
                self.task = nil; self.retireSelected(); self.releaseSession()
                self.onEvent?(.failed(generation: generation, message: error.localizedDescription))
            }
        }
    }
    public func play(commandID: UUID) {
        self.commandID = commandID; wantsPlayback = true
        relayReclaim.demand()
        deliver(commandID); selected?.play(commandID: commandID)
    }
    public func pause(commandID: UUID) {
        self.commandID = commandID; wantsPlayback = false
        deliver(commandID); selected?.pause(commandID: commandID)
    }
    public func seek(to positionMilliseconds: Int64, commandID: UUID) {
        self.commandID = commandID; position = max(0, positionMilliseconds)
        relayReclaim.demand()
        deliver(commandID); selected?.seek(to: position, commandID: commandID)
    }
    public func setSpeed(_ speed: Float, commandID: UUID) throws {
        guard speed.isFinite, speed > 0 else { throw PlaybackSpeedError.invalidSpeed }
        try selected?.setSpeed(speed, commandID: commandID)
        self.speed = speed; self.commandID = commandID; deliver(commandID)
    }
    public func setSkipSilence(_ enabled: Bool, commandID: UUID) {
        self.commandID = commandID; silence = enabled
        guard let selected else { return }
        guard let processor = selected as? any PlaybackSilenceControlling, processor.supportsSkipSilence else {
            // Kept for the next item; this one keeps playing unchanged.
            if let reading { onEvent?(.stateChanged(reading)) }
            return
        }
        deliver(commandID); processor.setSkipSilence(enabled, commandID: commandID)
    }
    public func setVolumeAdaptation(_ setting: FeedVolumeAdaptation) throws {
        guard setting == .off || selected == nil || selected is any PlaybackVolumeControlling else { throw PlaybackVolumeError.unsupportedEngine }
        try (selected as? any PlaybackVolumeControlling)?.setVolumeAdaptation(setting)
        volume = setting
    }
    func bindStatistics(lastPlayed: @escaping @MainActor (UUID) -> Int64,
                        synchronize: @escaping @MainActor (UUID) async throws -> Void) {
        statistics = (lastPlayed, synchronize)
        (selected as? any PlaybackStatisticsConsumer)?.bindStatistics(lastPlayed: lastPlayed, synchronize: synchronize)
    }
    public func setSleepTimerVolume(_ volume: Float) throws {
        guard volume == 1 || selected == nil || selected is any PlaybackVolumeControlling else { throw PlaybackVolumeError.unsupportedEngine }
        try (selected as? any PlaybackVolumeControlling)?.setSleepTimerVolume(volume)
        sleepTimerVolume = volume
    }
    private func deliver(_ commandID: UUID) { if selected != nil { deliveredCommandID = commandID } }
    private func translated(_ value: PlaybackEngineReading) -> PlaybackEngineReading {
        guard !supportsSkipSilence else { return value }
        var value = value
        if value.commandID == deliveredCommandID, let commandID { value.commandID = commandID }
        value.skipSilence = silence
        return value
    }
    private func translated(_ event: PlaybackEngineEvent) -> PlaybackEngineEvent {
        switch event {
        case .ready(let value): .ready(translated(value))
        case .stateChanged(let value): .stateChanged(translated(value))
        case .position(let value): .position(translated(value))
        case .timelineReset(let value): .timelineReset(translated(value))
        case .ended(let value): .ended(translated(value))
        case .mediaServicesReset(let value): .mediaServicesReset(translated(value))
        case .failed: event
        }
    }
    private func retireSelected() {
        selected?.onEvent = nil; selected?.unload(); selected = nil
        document?.close(); document = nil
    }
    /// Stops for good unless a session was reserved for the next item.
    public func unload() {
        selection = nil; generation = nil; commandID = nil; deliveredCommandID = nil
        task?.cancel(); task = nil
        retireSelected()
        if !sessionReserved { releaseSession() }
        wantsPlayback = false; position = 0; speed = 1; silence = false; volume = .off; sleepTimerVolume = 1
    }
    public func reserveSessionForNextItem() {
        sessionReserved = true
        guard !keepingSession else { return }
        keepingSession = true
        _ = try? sessionKeeper.hold()
    }
    public func cancelSessionReservation() {
        guard sessionReserved else { return }
        sessionReserved = false
        if selection == nil { releaseSession() }
    }
    private func releaseSession() {
        sessionReserved = false
        guard keepingSession else { return }
        keepingSession = false
        _ = try? sessionKeeper.request(active: false, prepare: false)
    }
}

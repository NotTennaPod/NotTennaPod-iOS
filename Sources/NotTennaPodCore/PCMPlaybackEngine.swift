import AVFoundation
import Foundation

/// Application processing engine. Source preparation and recovery preserve the
/// existing coordinator's commands, statistics and media-generation identity.
@MainActor final class PCMPlaybackEngine: PlaybackSilenceControlling, PlaybackVolumeControlling, PlaybackStatisticsConsumer, PlaybackVideoPresenting, PlaybackInterruptionReporting {
    enum Failure: Error { case unboundStatistics, invalidDuration }
    typealias FactoryBuilder = @MainActor (URL) throws -> PCMRecoveryFactory
    typealias FactoryResolver = @MainActor (LibraryEpisode, URL) async throws -> PCMRecoveryFactory
    typealias EventSourceFactory = @MainActor (@escaping @MainActor (AudioSessionEvent) -> Void) -> AudioSessionEventSource
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    var videoDisplayLayer: AVSampleBufferDisplayLayer? { port?.videoDisplayLayer }
    var videoPictureInPicture: PlaybackVideoPictureInPicture? { port?.videoPictureInPicture }
    /// Read-only view of the focus policy: an interruption holds playback that its end resumes.
    var resumesAfterInterruption: Bool { recovery?.wantsPlayback == true && recovery?.isSuppressed == true }
    var mediaPresentationID: UUID? { recovery?.state == .seeking || trackSelectionID != nil ? nil : port?.mediaPresentationID }
    private(set) var mediaTracks: [PlaybackMediaTrack] = []
    private(set) var selectedAudioTrackID: Int32?
    private(set) var selectedVideoTrackID: Int32?
    private var mediaSource: FFmpegPlaybackSource?
    private var trackSelectionID: UUID?
    private var trackSelectionTask: Task<Void, Never>?
    var reading: PlaybackEngineReading? {
        guard !failed, !servicesReset, let generation, let commandID, let port else { return nil }
        let position = pendingPosition ?? ((try? port.positionMilliseconds) ?? 0)
        let playing = !ended && (recovery?.wantsPlayback ?? wantsPlayback) && recovery?.isSuppressed != true
        return .init(generation: generation, commandID: commandID,
            sample: .init(positionMilliseconds: Int32(truncatingIfNeeded: position),
                durationMilliseconds: Int32(truncatingIfNeeded: duration), seekable: sourceSeekable ?? true,
                status: ended ? .other : (playing ? .playing : .paused)),
            buffering: !ended && (!prepared || port.isSeeking || recovery?.state == .seeking || trackSelectionID != nil || (playing && port.outputState != .playing)), speed: parameters.speed,
            skipSilence: parameters.skipSilence, isPrepared: prepared)
    }
    private let source: @MainActor (LibraryEpisode) throws -> URL
    private let resolveFactory: FactoryResolver
    private var factoryTask: Task<PCMRecoveryFactory, any Error>?
    private let durationResolver: (@Sendable (URL) async throws -> Int64)?
    private let now: @MainActor () -> Int64
    private let activation: AudioSessionActivationController
    private let pauseOnDisconnect: Bool
    private let pauseOnDisconnectProvider: (@MainActor () -> Bool)?
    private var eventSource: AudioSessionEventSource?
    private var lastPlayed: (@MainActor (UUID) -> Int64)?
    private var synchronize: (@MainActor (UUID) async throws -> Void)?
    private var generation: UUID?
    private var commandID: UUID?
    private var mediaURL: URL?
    private var mediaContentType: String?
    private var parameterTask: Task<Void, Never>?
    private var port: PCMRecoverySession?
    private var recovery: PlaybackRecoveryController?
    private var parameters = PCMRecoverySession.Parameters(speed: 1, skipSilence: false)
    private var pendingPosition: Int64?
    private var duration: Int64 = -1
    private var sourceSeekable: Bool?
    private var sourceProvidesDuration = false
    private var prepared = false
    private var failed = false
    /// A media-services reset closed this item's audio objects; nothing of it plays again (QA1749).
    private var servicesReset = false
    private var ended = false
    private var wantsPlayback = false
    private var lastState: PlaybackEngineReading?
    private var lastResumesAfterInterruption = false
    private var lastPresentationID: UUID?
    private var handlingOutputRecovery = false
    private let positionTicker: any PlaybackPositionTicking
    private var positionTimerID: UUID?

    convenience init(driver: any AudioSessionActivationDriver, makeFactory: @escaping FactoryBuilder,
         source: @escaping @MainActor (LibraryEpisode) throws -> URL = AVPlayerPlaybackEngine.mediaURL,
         duration: (@Sendable (URL) async throws -> Int64)? = nil,
         events: EventSourceFactory? = nil,
         pauseOnDisconnect: Bool = true,
         pauseOnDisconnectProvider: (@MainActor () -> Bool)? = nil,
         positionTicker: any PlaybackPositionTicking = PlaybackPositionTicker(),
         now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.init(driver: driver, resolveFactory: { _, url in try makeFactory(url) },
            source: source, duration: duration, events: events, pauseOnDisconnect: pauseOnDisconnect,
            pauseOnDisconnectProvider: pauseOnDisconnectProvider,
            positionTicker: positionTicker, now: now)
    }

    /// An engine with an audio session of its own (`driver`), observing `events` itself.
    convenience init(driver: any AudioSessionActivationDriver, resolveFactory: @escaping FactoryResolver,
         source: @escaping @MainActor (LibraryEpisode) throws -> URL = AVPlayerPlaybackEngine.mediaURL,
         duration: (@Sendable (URL) async throws -> Int64)? = nil,
         events: EventSourceFactory? = nil,
         pauseOnDisconnect: Bool = true,
         pauseOnDisconnectProvider: (@MainActor () -> Bool)? = nil,
         positionTicker: any PlaybackPositionTicking = PlaybackPositionTicker(),
         now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.init(sessionOwner: AudioSessionOwner(driver: driver), resolveFactory: resolveFactory, source: source,
            duration: duration, events: events, pauseOnDisconnect: pauseOnDisconnect,
            pauseOnDisconnectProvider: pauseOnDisconnectProvider, positionTicker: positionTicker, now: now)
    }

    /// An engine claiming the app's shared audio session (`AudioSessionOwner.shared` in the app), whose
    /// owner observes system events and forwards them; pass `events` only for an owner without a source.
    init(sessionOwner: AudioSessionOwner, resolveFactory: @escaping FactoryResolver,
         source: @escaping @MainActor (LibraryEpisode) throws -> URL = AVPlayerPlaybackEngine.mediaURL,
         duration: (@Sendable (URL) async throws -> Int64)? = nil,
         events: EventSourceFactory? = nil,
         pauseOnDisconnect: Bool = true,
         pauseOnDisconnectProvider: (@MainActor () -> Bool)? = nil,
         positionTicker: any PlaybackPositionTicking = PlaybackPositionTicker(),
         now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        activation = AudioSessionActivationController(owner: sessionOwner)
        self.pauseOnDisconnect = pauseOnDisconnect
        self.pauseOnDisconnectProvider = pauseOnDisconnectProvider
        self.resolveFactory = resolveFactory
        self.source = source
        durationResolver = duration
        self.positionTicker = positionTicker
        self.now = now
        activation.onSystemEvent = { [weak self] event in self?.recovery?.receiveObserved(event) }
        eventSource = events? { [weak self] event in self?.receive(event) }
    }

    isolated deinit { eventSource?.close(); unload(); activation.close() }

    func bindStatistics(lastPlayed: @escaping @MainActor (UUID) -> Int64,
                        synchronize: @escaping @MainActor (UUID) async throws -> Void) {
        self.lastPlayed = lastPlayed
        self.synchronize = synchronize
    }

    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        unload()
        self.generation = generation
        commandID = generation
        do {
            guard lastPlayed != nil && synchronize != nil else { throw Failure.unboundStatistics }
            let url = try source(episode)
            // The selected factory validates supported sources. Captured remote factories
            // retain their source across recovery; local factories require file URLs.
            mediaURL = url
            mediaContentType = AVPlayerPlaybackEngine.assetOptions(for: episode, url: url)[AVURLAssetOverrideMIMETypeKey] as? String
            let resolveFactory = resolveFactory
            let factoryTask = Task { @MainActor in
                try Task.checkCancellation()
                let factory = try await resolveFactory(episode, url)
                try Task.checkCancellation()
                return factory
            }
            self.factoryTask = factoryTask
            try prepare(at: max(0, positionMilliseconds), factoryTask: factoryTask)
        } catch { fail(error) }
    }

    func play(commandID: UUID) {
        guard generation != nil, !failed, !servicesReset else { return }
        self.commandID = commandID
        wantsPlayback = true
        do { try recovery?.play(); publish() } catch { fail(error) }
    }

    func pause(commandID: UUID) {
        guard generation != nil, !failed, !servicesReset else { return }
        self.commandID = commandID
        wantsPlayback = false
        do { try recovery?.pause(); publish() } catch { fail(error) }
    }

    func seek(to positionMilliseconds: Int64, commandID: UUID) {
        guard generation != nil, !failed, !servicesReset else { return }
        trackSelectionTask?.cancel(); trackSelectionTask = nil; trackSelectionID = nil
        self.commandID = commandID
        let target = sourceSeekable == false ? 0 : max(0, positionMilliseconds)
        pendingPosition = target
        ended = false
        do { try recovery?.seek(to: target); publish() } catch { fail(error) }
    }

    func selectAudioTrack(id: Int32, commandID: UUID) throws {
        guard let generation, let mediaSource,
              mediaTracks.contains(where: { $0.kind == .audio && $0.id == id }) else { throw PlaybackTrackSelectionError.invalidTrack }
        if selectedAudioTrackID == id && trackSelectionID == nil {
            self.commandID = commandID; publish(); return
        }
        self.commandID = commandID
        let token = UUID(), position = max(0, (try? port?.positionMilliseconds) ?? 0)
        trackSelectionTask?.cancel(); trackSelectionID = token
        trackSelectionTask = Task { [weak self] in
            do {
                try await mediaSource.selectAudioTrack(id)
                try Task.checkCancellation()
                guard let self, self.generation == generation, self.trackSelectionID == token else { return }
                self.selectedAudioTrackID = id
                self.trackSelectionID = nil; self.trackSelectionTask = nil
                self.pendingPosition = position; self.ended = false
                try self.recovery?.seek(to: position)
                self.publish()
            } catch {
                guard let self, self.generation == generation, self.trackSelectionID == token else { return }
                self.trackSelectionID = nil; self.trackSelectionTask = nil
                self.fail(error)
            }
        }
        publish()
    }

    func setSpeed(_ speed: Float, commandID: UUID) throws {
        guard speed.isFinite, (0.5...4).contains(speed) else { throw PlaybackSpeedError.invalidSpeed }
        self.commandID = commandID
        parameters = .init(speed: speed, skipSilence: parameters.skipSilence, volume: parameters.volume, baseVolume: parameters.baseVolume)
        applyParameters()
        publish()
    }

    func receive(_ event: AudioSessionEvent) {
        if activation.receive(event) { recovery?.receiveObserved(event) }
    }

    func setSkipSilence(_ enabled: Bool, commandID: UUID) {
        self.commandID = commandID
        parameters = .init(speed: parameters.speed, skipSilence: enabled, volume: parameters.volume, baseVolume: parameters.baseVolume)
        applyParameters()
        publish()
    }

    func setVolumeAdaptation(_ setting: FeedVolumeAdaptation) throws {
        applyVolume(setting, baseVolume: parameters.baseVolume)
    }

    func setSleepTimerVolume(_ volume: Float) throws {
        applyVolume(parameters.volume, baseVolume: volume)
    }

    /// Applied when commanded, like Android's `player.setVolume`: no task, no flush.
    private func applyVolume(_ setting: FeedVolumeAdaptation, baseVolume: Float) {
        parameters = .init(speed: parameters.speed, skipSilence: parameters.skipSilence, volume: setting, baseVolume: baseVolume)
        do { try port?.setVolumeAdaptation(setting, baseVolume: baseVolume) } catch { fail(error) }
    }

    func unload() {
        trackSelectionTask?.cancel(); trackSelectionTask = nil; trackSelectionID = nil
        mediaSource = nil; mediaTracks = []; selectedAudioTrackID = nil; selectedVideoTrackID = nil
        factoryTask?.cancel(); factoryTask = nil
        generation = nil
        parameterTask?.cancel(); parameterTask = nil
        recovery?.onChange = nil
        port?.onChange = nil
        recovery?.close(); recovery = nil
        port?.close(); port = nil
        stopTimer()
        commandID = nil; mediaURL = nil; mediaContentType = nil; pendingPosition = nil
        prepared = false; failed = false; servicesReset = false; ended = false; wantsPlayback = false
        lastState = nil; lastResumesAfterInterruption = false; lastPresentationID = nil; duration = -1; sourceSeekable = nil; sourceProvidesDuration = false
        parameters = .init(speed: 1, skipSilence: false)
    }

    private func prepare(at position: Int64, factoryTask: Task<PCMRecoveryFactory, any Error>) throws {
        guard let generation, let url = mediaURL, let lastPlayed, let synchronize else { return }
        let durationResolver = durationResolver; let contentType = mediaContentType
        pendingPosition = position
        let port = PCMRecoverySession(positionMilliseconds: position, parameters: parameters,
            lastPlayedMilliseconds: { lastPlayed(generation) },
            synchronizeStatistics: { try await synchronize(generation) }, factory: { [weak self] position, parameters in
                let lease = PreparationCandidate()
                return try await withTaskCancellationHandler {
                    // Resolve credentials/source once per item. Seeks and renderer recovery
                    // await the same result instead of recapturing settings or replacing loading.
                    let factory = try await factoryTask.value
                    try Task.checkCancellation()
                    guard self?.generation == generation else { throw CancellationError() }
                    let providesDuration = factory.providesSourceDuration
                    self?.sourceProvidesDuration = providesDuration
                    let knownDuration = self?.duration ?? 0
                    async let measuredDuration: Int64 = {
                        if providesDuration { return -1 }
                        if knownDuration > 0 { return knownDuration }
                        if let durationResolver { return try await durationResolver(url) }
                        return try await Self.mediaDuration(url, contentType: contentType)
                    }()
                    let candidate = try await factory.make(positionMilliseconds: position, parameters: parameters)
                    do {
                        try lease.hold(candidate)
                        let metadata = try await factory.mediaSource?.prepareMediaMetadata()
                        let selectedAudio = await factory.mediaSource?.selectedAudioTrackID()
                        let measured = try await measuredDuration
                        try Task.checkCancellation()
                        if !providesDuration, measured <= 0 { throw Failure.invalidDuration }
                        guard self?.generation == generation else { throw CancellationError() }
                        self?.duration = providesDuration ? (candidate.sourceDurationMilliseconds ?? -1) : measured
                        self?.sourceSeekable = candidate.sourceSeekable
                        self?.mediaSource = factory.mediaSource
                        self?.mediaTracks = metadata?.tracks.compactMap { track in
                            guard track.decodable, track.kind == .audio || track.kind == .video else { return nil }
                            return PlaybackMediaTrack(id: track.id, kind: track.kind == .audio ? .audio : .video,
                                title: track.title, language: track.language, codec: track.codec,
                                videoGeometry: track.kind == .video ? PlaybackVideoGeometry(width: track.width, height: track.height,
                                    pixelAspectRatio: track.pixelAspectRatio, rotationDegrees: track.rotationDegrees) : nil)
                        } ?? []
                        self?.selectedAudioTrackID = selectedAudio
                        self?.selectedVideoTrackID = metadata?.selectedVideoTrackID
                        lease.release()
                        return candidate
                    } catch { lease.close(); throw error }
                } onCancel: { Task { @MainActor in lease.close() } }
            })
        let recovery = PlaybackRecoveryController(session: port, activation: activation,
            pauseOnDisconnect: pauseOnDisconnect, pauseOnDisconnectProvider: pauseOnDisconnectProvider,
            ownsActivation: false, now: now)
        self.port = port; self.recovery = recovery
        port.onChange = { [weak self] in self?.publish() }
        recovery.onChange = { [weak self] in self?.publish() }
        // Establish the seeking gate before the coordinator sends initial playback intent.
        // Focus can change while this asynchronous operation is still preparing media.
        try recovery.seek(to: position)
    }

    /// Covers native allocation while a structured metadata child is still outstanding.
    /// A cancellation delivered before allocation also closes any later candidate.
    @MainActor private final class PreparationCandidate {
        private var current: SampleBufferPlaybackSession?
        private var closed = false
        func hold(_ session: SampleBufferPlaybackSession) throws {
            guard !closed else { session.close(); throw CancellationError() }
            current = session
        }
        func release() { current = nil }
        func close() { closed = true; current?.close(); current = nil }
        isolated deinit { current?.close() }
    }

    private func applyParameters() {
        let parameters = parameters; let generation = generation
        let port = port
        // Calls are made in actor order; do not cancel an older valid parameter command.
        parameterTask = Task { @MainActor [weak self] in
            do {
                if let port { try await port.setParameters(speed: parameters.speed, skipSilence: parameters.skipSilence) }
            } catch { if self?.generation == generation { self?.fail(error) } }
        }
    }

    private func publish() {
        guard !failed, !servicesReset, !handlingOutputRecovery, let generation else { return }
        if let seekable = port?.sourceSeekable { sourceSeekable = seekable }
        if sourceProvidesDuration, let duration = port?.sourceDurationMilliseconds {
            self.duration = duration
        }
        // Before any output recovery: an output the reset left failed is not rebuilt without the person.
        if recovery?.state == .requiresRebuild { closeAfterServicesReset(); return }
        if port?.sourceRestartRequired == true, port?.isSeeking == false, recovery?.state != .seeking {
            // This is a source timeline discontinuity, not an episode ending or
            // renderer failure. The existing owner retains commands/focus/intent.
            handlingOutputRecovery = true
            defer { handlingOutputRecovery = false }
            if let reading { onEvent?(.timelineReset(reading)) }
            pendingPosition = 0
            do { try recovery?.seek(to: 0) } catch { fail(error) }
            return
        }
        if let error = recovery?.failure ?? port?.failure {
            if prepared, recovery?.failure == nil, port?.isSeeking == false,
               recovery?.state != .seeking, let position = port?.recoveryPositionMilliseconds {
                handlingOutputRecovery = true
                defer { handlingOutputRecovery = false }
                pendingPosition = position
                port?.discardFailedOutput(at: position)
                do { try recovery?.recoverOutput(at: position) } catch { fail(error) }
            } else { fail(error) }
            return
        }
        if !prepared {
            guard port?.outputState != nil, port?.isSeeking == false,
                  recovery?.state != .seeking else {
                if let reading { publishState(reading) }
                return
            }
            prepared = true
            pendingPosition = nil
            if let reading { onEvent?(.ready(reading)) }
            guard self.generation == generation, !failed else { return }
        }
        if port?.isSeeking == false && recovery?.state != .seeking { pendingPosition = nil }
        // The recovery owner announces a seek before its asynchronous port
        // replacement starts. The old ended output must not finish it again.
        if port?.outputState == .ended && port?.isSeeking == false && recovery?.state != .seeking && !ended {
            ended = true; wantsPlayback = false
            stopTimer()
            if let reading { onEvent?(.ended(reading)) }
            return
        }
        guard let reading else { return }
        if reading.sample.status == .playing { startTimer() } else { stopTimer() }
        publishState(reading)
    }

    private func publishState(_ reading: PlaybackEngineReading) {
        // A resumption the interruption held, kept or given up, is a state change too: a library switch waiting
        // for it checks again even when the reading itself is unchanged (an interruption that ends without resuming).
        let resumes = resumesAfterInterruption
        if lastPresentationID != mediaPresentationID || lastResumesAfterInterruption != resumes
            || lastState?.commandID != reading.commandID || lastState?.sample.status != reading.sample.status
            || lastState?.buffering != reading.buffering || lastState?.speed != reading.speed
            || lastState?.sample.durationMilliseconds != reading.sample.durationMilliseconds
            || lastState?.sample.seekable != reading.sample.seekable
            || lastState?.skipSilence != reading.skipSilence {
            lastState = reading
            lastResumesAfterInterruption = resumes
            lastPresentationID = mediaPresentationID
            onEvent?(.stateChanged(reading))
        }
    }

    /// A media-services reset invalidated every audio object of this item: they are closed at once (late callbacks
    /// find them closed), and the final reading goes to the coordinator, which keeps the item selected and paused
    /// at that position. Only an explicit Play loads it again (Apple QA1749); no failure is reported.
    private func closeAfterServicesReset() {
        guard !failed, !servicesReset, let generation else { return }
        // The output's clock may be unusable already: then the position the coordinator last had stays (the
        // reading is not offered as prepared), never a made-up zero.
        let measured = pendingPosition ?? port.flatMap { try? $0.positionMilliseconds }
        var final = reading ?? PlaybackEngineReading(generation: generation, commandID: commandID,
            sample: .init(positionMilliseconds: Int32(truncatingIfNeeded: pendingPosition ?? 0),
                durationMilliseconds: Int32(truncatingIfNeeded: duration), status: .paused),
            speed: parameters.speed, skipSilence: parameters.skipSilence, isPrepared: false)
        if measured == nil { final.isPrepared = false }
        final.sample.status = .paused
        final.buffering = false
        servicesReset = true; wantsPlayback = false
        stopTimer()
        trackSelectionTask?.cancel(); trackSelectionTask = nil; trackSelectionID = nil
        factoryTask?.cancel()
        recovery?.onChange = nil; port?.onChange = nil
        recovery?.close(); port?.close()
        onEvent?(.mediaServicesReset(final))
    }

    private func fail(_ error: any Error) {
        guard !failed, !servicesReset, let generation else { return }
        failed = true; wantsPlayback = false
        stopTimer()
        recovery?.close(); port?.close()
        onEvent?(.failed(generation: generation, message: error.localizedDescription))
    }

    private func startTimer() {
        guard positionTimerID == nil, let generation, reading?.sample.status == .playing else { return }
        let id = UUID()
        positionTimerID = id
        positionTicker.start { [weak self] in
            guard let self, self.positionTimerID == id, self.generation == generation,
                  !self.ended, let reading = self.reading, reading.sample.status == .playing else { return }
            self.onEvent?(.position(reading))
        }
    }

    private func stopTimer() { positionTimerID = nil; positionTicker.stop() }

    @concurrent static func mediaDuration(_ url: URL, contentType: String? = nil) async throws -> Int64 {
        try Task.checkCancellation()
        guard url.isFileURL else { throw NativePCMDecoder.Failure.notLocal }
        guard try url.checkResourceIsReachable() else { throw CocoaError(.fileReadNoSuchFile) }
        try Task.checkCancellation()
        let detectedType = try PCMFileContainer.nativeContentType(url: url)
        return try await PreparedMediaDuration.read(url, contentType: detectedType ?? contentType)
    }
}

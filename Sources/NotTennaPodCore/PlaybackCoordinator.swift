import Foundation

@MainActor
public final class PlaybackCoordinator {
    public enum Phase: Equatable, Sendable { case idle, stopped, preparing, playing, buffering, paused, awaitingStreamingConfirmation, failed }
    public enum Event: Sendable {
        case stateChanged, libraryChanged, positionSaved, noFollowingEpisode
        case positionChanged(PlaybackPositionUpdate)
        case introSkipped(seconds: Int32), endingSkipped(seconds: Int32)
        case engineFailed(String), storageFailed
        case streamingConfirmationRequired(episodeID: Int64)
    }

    public private(set) var episode: LibraryEpisode? {
        didSet { if oldValue?.id != episode?.id { systemSelectionID = UUID() } }
    }
    private var systemSelectionID = UUID()
    public private(set) var phase: Phase = .idle
    /// Loading can continue after Pause, including a seek awaiting network data.
    public var isBuffering: Bool {
        switch phase {
        case .preparing: return true
        case .playing, .buffering, .paused: return currentReading()?.buffering == true
        default: return false
        }
    }
    /// Capture when binding a newly accepted data model. Buffered older events
    /// must not update that model even when playback identity remains unchanged.
    public private(set) var positionRevision: UInt64 = 0
    public private(set) var sample: PlaybackSample?
    public private(set) var wantsPlayback = false
    /// An audio-session interruption (a phone call) holds playback that resumes by itself when it ends.
    public var awaitsInterruptionResumption: Bool {
        (engine as? any PlaybackInterruptionReporting)?.resumesAfterInterruption == true
    }
    /// A command is queued or running; its effect on playback is not visible yet.
    public var hasPendingCommands: Bool { tail != nil }
    /// A command that may start playback (Play, a selection that plays, Play/Pause), or playback the engine resumed by
    /// itself, is queued or running.
    public var startsPlayback: Bool { playRequests > 0 }
    private var playRequests = 0
    /// Playback the engine started by itself, counted the moment its event arrives (before it is handled), readable
    /// from the store's transaction: an adoption is committed and moves the engine only if none began (PROTOCOL §8.6).
    private let resumptions = PlaybackResumptionFence()
    /// The library is a server library (read at each load and restore): only there does an episode's device-local play
    /// time measure the rewind after a pause (`lastPlayedHere`).
    private var serverLibrary = false
    /// Called in the same main-actor step as a command that may start playback is admitted, before it runs, so what
    /// must not start against playback (a large sync publication) is refused from then on (admission fencing).
    public var onPlaybackRequested: (@MainActor () -> Void)?
    /// Playing, as the server exchange's budgets mean it (PROTOCOL §6.8): playback is wanted, preparing, playing or
    /// buffering, or a command that may start it is on its way. An item paused by the person, or held silent by an
    /// interruption that may still resume it, is not playing; its resumption is a state change like any start.
    public var playsForSynchronization: Bool {
        if wantsPlayback || startsPlayback { return true }
        switch phase {
        case .preparing, .playing, .buffering: return true
        case .idle, .stopped, .paused, .failed, .awaitingStreamingConfirmation: return false
        }
    }
    /// The library graph that owns this player is being torn down (`retire()`): no command is admitted any more.
    public private(set) var isRetired = false
    private var retirement: Task<Void, Never>?
    public private(set) var speed: Float = 1
    public private(set) var skipSilence = false
    public private(set) var volumeAdaptation: FeedVolumeAdaptation = .off
    public private(set) var sleepTimer: SleepTimer?
    public private(set) var sleepTimerValue: SleepTimerValue?
    public var onSleepTimerFeedback: (@MainActor (SleepTimerEvent) -> Void)?
    /// Each position tick of playing or buffering media of unknown duration (a live stream). `events()` has no
    /// position event for those (nothing to show or save), so this tells the widget the player is still alive.
    public var onUnknownDurationTick: (@MainActor () -> Void)?
    private let store: FeedLibraryStore
    private let engine: any PlaybackEngine
    private let preferences: @MainActor (LibraryEpisode) -> PlaybackPreferences
    private let speedPreferences: PlaybackSpeedPreferenceStore?
    private let sleepTimerPreferences: SleepTimerPreferenceStore?
    private let skipPreferences: (@MainActor (LibraryEpisode) async throws -> FeedSkipPreferences)?
    private var loadedSkipPreferences: FeedSkipPreferences?
    private var loadedDeletionPolicy = PlaybackDeletionPolicy()
    private let completionEffects: (@MainActor () async throws -> Void)?
    private var completionWork: Task<Void, Never>?
    /// Wall time: every saved timestamp and the history, the resume rewind measured against them, auto-enable hours.
    private let clock: @MainActor () -> Date
    /// Monotonic milliseconds: the checkpoint cadence and the clock sleep timer. A wall-clock correction
    /// moves neither, so saves continue every five seconds of playback and the timer counts listening time.
    private let monotonicClock: @MainActor () -> Int64
    private let streamingAccess: (@MainActor (LibraryEpisode) async throws -> PlaybackStreamingAccess)?
    private var streamingPolicy = StreamingAdmissionPolicy()
    public var pendingStreamingEpisodeID: Int64? { streamingPolicy.pendingMediaID }
    private var externalPreparation = false
    private var generation: UUID?
    private var commandID: UUID?
    private var session: LibraryPlaybackSession?
    private var baselineUsesPreparedPosition = true
    /// Monotonic time of the last periodic checkpoint (or its new baseline).
    private var lastSaveMilliseconds: Int64 = 0
    private var tail: Task<Void, any Error>?
    private var sequence: UInt64 = 0
    private var listeners: [UUID: AsyncStream<Event>.Continuation] = [:]

    /// The app passes neither clock. `clock` is the wall time saved with positions and history; `monotonicClock`
    /// paces the five-second checkpoints and the clock sleep timer. Injecting only `clock` makes it drive both
    /// (one test timeline), so rolling that clock back also moves the pacing; inject both to keep them apart.
    public init(store: FeedLibraryStore, engine: any PlaybackEngine,
                preferences: @escaping @MainActor (LibraryEpisode) -> PlaybackPreferences = { _ in .init() },
                speedPreferences: PlaybackSpeedPreferenceStore? = nil,
                sleepTimerPreferences: SleepTimerPreferenceStore? = nil,
                skipPreferences: (@MainActor (LibraryEpisode) async throws -> FeedSkipPreferences)? = nil,
                streamingAccess: (@MainActor (LibraryEpisode) async throws -> PlaybackStreamingAccess)? = nil,
                completionEffects: (@MainActor () async throws -> Void)? = nil,
                clock: (@MainActor () -> Date)? = nil,
                monotonicClock: (@MainActor () -> Int64)? = nil) {
        self.completionEffects = completionEffects
        self.store = store
        self.engine = engine
        self.preferences = preferences
        self.speedPreferences = speedPreferences
        self.sleepTimerPreferences = sleepTimerPreferences
        self.skipPreferences = skipPreferences
        self.clock = clock ?? { Date() }
        if let monotonicClock { self.monotonicClock = monotonicClock }
        // A test that injects only a wall clock has one timeline: its time passing drives both.
        else if let clock { self.monotonicClock = { Int64(clock().timeIntervalSince1970 * 1_000) } }
        else { let origin = ContinuousClock.now; self.monotonicClock = { Self.continuousMilliseconds(since: origin) } }
        self.streamingAccess = streamingAccess
        (engine as? any PlaybackStatisticsConsumer)?.bindStatistics(lastPlayed: { [weak self] generation in
            guard let self, self.generation == generation, let episode = self.episode else { return 0 }
            return self.lastPlayedHere(episode)
        }, synchronize: { [weak self] generation in
            guard let self else { throw FeedLibraryError.invalidMutation }
            try await self.synchronizePlaybackStatistics(generation: generation)
        })
        engine.onEvent = { [weak self] event in
            guard let self else { return }
            let receivedAt = self.clock(), monotonic = self.monotonicClock()
            // Playback the engine starts by itself (an interruption ending with shouldResume) is fenced like a Play,
            // in this step: its handling waits in the queue, and until it ran it counts as starting playback.
            let resumes = !self.isRetired && !self.wantsPlayback && event.engineReading?.sample.status == .playing
            if resumes { self.resumptions.advance(); self.playRequests += 1; self.onPlaybackRequested?() }
            _ = self.enqueue {
                defer { if resumes { self.playRequests -= 1 } }
                do { try await self.handle(event, receivedAt: receivedAt, monotonic: monotonic) }
                catch { self.storageFailure() }
            }
        }
    }

    public func events() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.yield(.stateChanged)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[id] = nil }
            }
        }
    }

    /// File-provider work is independent of player commands. Tests and orderly
    /// shutdown can observe completion without holding up the next episode.
    public func awaitPendingCompletionEffects() async { await completionWork?.value }

    private func scheduleCompletionEffects() {
        guard let completionEffects else { return }
        let previous = completionWork
        completionWork = Task { [completionEffects, weak self] in
            await previous?.value
            do { try await completionEffects() }
            catch { self?.publish(.storageFailed) }
            self?.publish(.libraryChanged)
        }
    }

    public func restore() async throws {
        try await enqueue {
            guard self.episode == nil, self.generation == nil else { return }
            guard let selected = try await self.store.playbackSelectionEpisodeID(),
                  let episode = try await self.store.episode(id: selected) else { return }
            self.session = try await self.store.playbackSession()
            self.serverLibrary = await self.store.isServerLibrary
            self.episode = episode
            self.sample = .init(positionMilliseconds: episode.userState.positionMilliseconds,
                                durationMilliseconds: episode.details.media?.durationMilliseconds ?? 0, status: .paused)
            self.phase = .stopped
            self.wantsPlayback = false
            self.loadedDeletionPolicy = try await self.store.playbackDeletionPolicy(forEpisode: episode.id)
            self.volumeAdaptation = try await self.store.volumeAdaptation(forEpisode: episode.id)
            self.speed = try await self.resolvedSpeed(for: episode)
            self.skipSilence = try await self.resolvedSkipSilence(for: episode)
            self.publish(.stateChanged)
        }.value
    }

    public private(set) var interactionRevision: UInt64 = 0

    public var systemSnapshot: PlaybackSystemSnapshot? {
        guard let episode else { return nil }
        let reading = currentReading()
        let current = reading?.sample ?? sample
        let duration = Int64(current?.durationMilliseconds ?? 0)
        let effectiveSpeed = reading?.speed ?? speed
        let prepared = generation != nil && phase != .preparing && phase != .failed
        let actionable = pendingStreamingEpisodeID == nil
        return .init(identity: .init(episodeID: episode.id, selectionID: systemSelectionID),
            title: episode.details.title ?? "", positionMilliseconds: max(0, Int64(current?.positionMilliseconds ?? 0)),
            durationMilliseconds: duration > 0 ? duration : nil,
            rate: phase == .playing && wantsPlayback && reading?.buffering != true ? effectiveSpeed : 0,
            defaultRate: effectiveSpeed, wantsPlayback: wantsPlayback,
            canSeek: actionable && prepared && current?.seekable == true && duration > 0,
            canSkip: actionable && prepared, canChangeRate: actionable && generation != nil,
            canPlay: actionable, isVideo: episode.details.media?.mimeType?.hasPrefix("video/") == true)
    }

    /// The actual local media session, shared by the app, inline video and PiP.
    /// Remote playback and an uncommitted replacement have no local surface.
    public var videoPresentation: (any PlaybackVideoPresenting)? {
        guard generation != nil, phase != .failed, phase != .stopped,
              let presentation = engine as? any PlaybackVideoPresenting,
              presentation.mediaPresentationID != nil else { return nil }
        return presentation
    }

    struct VideoCommandIdentity: Equatable {
        let selection: PlaybackSystemIdentity
        let generation: UUID
        let mediaSession: UUID
        let route: UUID?
        let layer: ObjectIdentifier?
        let pictureInPicture: ObjectIdentifier?
    }

    var videoCommandIdentity: VideoCommandIdentity? {
        guard let presentation = videoPresentation, let mediaSession = presentation.mediaPresentationID,
              let generation, let selection = systemSnapshot?.identity else { return nil }
        return .init(selection: selection, generation: generation, mediaSession: mediaSession,
            route: (engine as? RoutedPlaybackEngine)?.routeID,
            layer: presentation.videoDisplayLayer.map(ObjectIdentifier.init),
            pictureInPicture: presentation.videoPictureInPicture.map(ObjectIdentifier.init))
    }

    /// Track IDs belong to one committed source session, even when the selected
    /// episode or the outer route adapter is unchanged during a rebuild.
    public func selectAudioTrack(id: Int32) async throws {
        guard let identity = videoCommandIdentity else { throw PlaybackTrackSelectionError.unsupported }
        let queued = enqueue {
            try Task.checkCancellation()
            guard self.videoCommandIdentity == identity, let presentation = self.videoPresentation else {
                throw CancellationError()
            }
            guard presentation.mediaTracks.contains(where: { $0.id == id && $0.kind == .audio }) else {
                throw PlaybackTrackSelectionError.invalidTrack
            }
            guard presentation.selectedAudioTrackID != id else { return }
            let command = UUID()
            try presentation.selectAudioTrack(id: id, commandID: command)
            self.commandID = command
            self.interactionRevision &+= 1
            self.publish(.stateChanged)
        }
        try await withTaskCancellationHandler(operation: { try await queued.value }, onCancel: { queued.cancel() })
    }

    /// PiP's completion describes a settled timebase, not command admission or
    /// the optimistic UI position. Observe outside the queue so engine events
    /// and a later user command can settle or cancel this request.
    func seekFromPictureInPicture(to milliseconds: Int64, identity: VideoCommandIdentity,
        isCurrent: @escaping @MainActor () -> Bool) async throws {
        let events = events()
        var seekCommand: UUID?
        let queued = enqueue {
            try Task.checkCancellation()
            guard isCurrent(), self.videoCommandIdentity == identity,
                  let state = self.systemSnapshot, state.canSeek else { throw CancellationError() }
            self.interactionRevision &+= 1
            await self.seekCurrent(to: min(max(0, milliseconds), state.durationMilliseconds ?? 0))
            seekCommand = self.commandID
        }
        try await withTaskCancellationHandler(operation: { try await queued.value }, onCancel: { queued.cancel() })
        for await _ in events {
            try Task.checkCancellation()
            guard isCurrent(), self.systemSnapshot?.identity == identity.selection,
                  (self.engine as? RoutedPlaybackEngine)?.routeID == identity.route,
                  let seekCommand, self.commandID == seekCommand,
                  self.generation == identity.generation else { throw CancellationError() }
            if let reading = currentReading(), reading.commandID == seekCommand,
               reading.isPrepared, !reading.buffering {
                guard self.videoPresentation != nil else { throw CancellationError() }
                return
            }
        }
        throw CancellationError()
    }

    /// A remote callback may wait behind a library operation. Revalidate media
    /// identity and adapter lifetime at execution, not just when the OS sends it.
    @discardableResult public func performSystemCommand(_ command: PlaybackSystemCommand,
        for identity: PlaybackSystemIdentity,
        isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> Bool {
        var accepted = false
        let starts: Bool = switch command { case .play, .toggle: true; default: false }
        try await (starts ? requestPlayback : enqueue)({
            guard isCurrent(), let state = self.systemSnapshot, state.identity == identity else { return }
            switch command {
            case .play, .toggle: guard state.canPlay else { return }
            case .seek: guard state.canSeek else { return }
            case .skip, .next, .restart: guard state.canSkip else { return }
            case .rate(let value):
                guard state.canChangeRate, value.isFinite, (0.5...4).contains(value) else { return }
            case .pause, .stop: break
            }
            self.interactionRevision &+= 1
            switch command {
            case .play: try await self.playCurrent()
            // During an interruption the player shows paused, but its resumption is pending: Pause gives it up.
            case .pause: if self.wantsPlayback || self.awaitsInterruptionResumption { try await self.pauseCurrent() }
            case .toggle:
                if self.wantsPlayback { try await self.pauseCurrent() }
                else { try await self.playCurrent() }
            case .stop: try await self.stopCurrent()
            case .next: try await self.finish(.skipped)
            case .restart: await self.seekCurrent(to: 0)
            case .seek(let milliseconds):
                await self.seekCurrent(to: min(max(0, milliseconds), state.durationMilliseconds ?? 0))
            case .skip(let seconds, let direction): try await self.skipCurrentInterval(seconds: seconds, direction: direction)
            case .rate(let value): try self.setCurrentSpeed(value, alsoGlobal: false)
            }
            accepted = true
        }).value
        return accepted
    }

    public func select(episodeID: Int64, play: Bool = true) async throws {
        interactionRevision &+= 1
        try await (play ? requestPlayback : enqueue) {
            if self.episode?.id == episodeID, self.generation != nil {
                if play { try await self.resume() } else { try await self.pauseCurrent() }
                return
            }
            try await self.load(episodeID, play: play, fromQueue: false)
        }.value
    }

    /// The application validates receiver identity again after asynchronous
    /// library reads. Activation installs its route only after the old owner has
    /// settled playback and unloaded, so no intermediate local episode is cast.
    public func adoptExternalPlayback(episodeID: Int64,
        state: @escaping @MainActor () throws -> PlaybackExternalState,
        activateEngine: @escaping @MainActor () throws -> Void,
        isCurrent: @escaping @MainActor () -> Bool) async throws {
        let interaction = interactionRevision
        let current: @MainActor () -> Bool = { [weak self] in isCurrent() && self?.interactionRevision == interaction }
        try await enqueue {
            guard current() else { throw CancellationError() }
            var retired = false
            let adoption = ExternalAdoption(state: state, activate: activateEngine, isCurrent: current,
                didRetire: { retired = true })
            do { try await self.load(episodeID, play: false, fromQueue: false, adoption: adoption) }
            catch {
                if retired {
                    self.generation = nil; self.commandID = nil; self.engine.unload()
                    self.wantsPlayback = false; self.sample?.status = .paused
                    self.phase = self.episode == nil ? .idle : .stopped
                    self.publish(.stateChanged)
                }
                throw error
            }
        }.value
    }

    private struct ExternalAdoption {
        var state: @MainActor () throws -> PlaybackExternalState
        var activate: @MainActor () throws -> Void
        var isCurrent: @MainActor () -> Bool
        var didRetire: @MainActor () -> Void
    }

    /// Direct service Play, including Once/Always dialog callbacks. Row/mini-player
    /// actions use select/toggle to reselect an episode over a confirmation item.
    public func play() async throws {
        interactionRevision &+= 1
        try await requestPlayback { try await self.playCurrent() }.value
    }

    private func playCurrent() async throws {
        if pendingStreamingEpisodeID != nil {
            let decision = streamingPolicy.play(isConfirmationItem: true, currentMedia: nil,
                state: .ready, streamingAllowed: false, isCasting: false)
            if case .reload(let id) = decision { try await load(id, play: true, fromQueue: false) }
            return
        }
        guard let episode else { return }
        if generation == nil { try await load(episode.id, play: true, fromQueue: false) }
        else { try await resume() }
    }

    public func pause() async throws { interactionRevision &+= 1; try await enqueue { try await self.pauseCurrent() }.value }

    public enum SleepTimerError: Error, Equatable { case noMediaPlaying, invalidValue }

    public func startSleepTimer(mode: SleepTimerMode, value: Int64) async throws {
        try await enqueue {
            guard self.wantsPlayback, self.generation != nil else { throw SleepTimerError.noMediaPlaying }
            guard value > 0 else { throw SleepTimerError.invalidValue }
            try await self.startTimer(mode: mode, value: value)
            self.publish(.stateChanged)
        }.value
    }

    public func disableSleepTimer() async throws {
        try await enqueue {
            let events = self.sleepTimer?.stop() ?? [.cancelled]
            self.sleepTimer = nil
            try await self.deliverSleepTimerEvents(events)
            self.publish(.stateChanged)
        }.value
    }

    public func extendSleepTimer(by value: Int64) async throws {
        try await enqueue { self.sleepTimer?.extend(by: value) }.value
    }

    /// Called by the application-owned accelerometer observer only after the
    /// timer has requested shake listening. Reset feedback is independent of the
    /// optional expiry vibration, as in the source ShakeListener.
    public func resetSleepTimerAfterShake() async throws {
        try await enqueue {
            guard self.sleepTimer?.isListeningForShake == true else { return }
            let events = self.sleepTimer?.reset() ?? []
            try await self.deliverSleepTimerEvents(events)
            self.onSleepTimerFeedback?(.resetVibration)
            self.publish(.stateChanged)
        }.value
    }

    private func startTimer(mode: SleepTimerMode, value: Int64) async throws {
        guard engine is any PlaybackVolumeControlling else { throw PlaybackVolumeError.unsupportedEngine }
        var timer = sleepTimer ?? SleepTimer()
        let events = timer.start(mode: mode, value: value, nowMilliseconds: monotonicClock())
        sleepTimer = timer
        try await deliverSleepTimerEvents(events)
    }

    private func autoEnableSleepTimer() async throws {
        guard sleepTimer == nil, let settings = sleepTimerPreferences?.value,
              settings.autoEnable, settings.includes(hour: Calendar.current.component(.hour, from: clock())),
              let value = settings.timerValue, value > 0 else { return }
        try await startTimer(mode: settings.mode, value: value)
    }

    private func deliverSleepTimerEvents(_ events: [SleepTimerEvent]) async throws {
        // At expiry the faded audio stops first and only then is the volume restored, on every
        // route: a restore before the pause could be heard at full level.
        let expired = events.contains { if case .updated(let value) = $0 { value.milliseconds == 0 } else { false } }
        for event in events {
            switch event {
            case .enabled(let value): sleepTimerValue = value
            case .updated(let value):
                sleepTimerValue = value
                if !expired { try (engine as? any PlaybackVolumeControlling)?.setSleepTimerVolume(value.volume) }
            case .cancelled:
                sleepTimerValue = nil
                if !expired { try (engine as? any PlaybackVolumeControlling)?.setSleepTimerVolume(1) }
            case .expiryVibration, .resetVibration, .shakeListening: onSleepTimerFeedback?(event)
            }
        }
        if expired {
            let cleanup = sleepTimer?.stop() ?? []
            sleepTimer = nil; sleepTimerValue = nil
            for effect in cleanup { if case .shakeListening = effect { onSleepTimerFeedback?(effect) } }
            // pauseCurrent pauses the engine before it saves; restore even if saving fails.
            var pauseFailure: (any Error)?
            do { try await pauseCurrent() } catch { pauseFailure = error }
            try (engine as? any PlaybackVolumeControlling)?.setSleepTimerVolume(1)
            if let pauseFailure { throw pauseFailure }
        }
    }

    /// Dialog selections update the global default too; remote preset cycling changes only the current override.
    public func setSpeed(_ speed: Float, alsoGlobal: Bool = false) async throws {
        guard speed.isFinite, speed > 0 else { throw PlaybackSpeedError.invalidSpeed }
        try await enqueue {
            try self.setCurrentSpeed(speed, alsoGlobal: alsoGlobal)
        }.value
    }

    private func setCurrentSpeed(_ speed: Float, alsoGlobal: Bool) throws {
        try speedPreferences?.setCurrent(speed, alsoGlobal: alsoGlobal)
        if generation != nil { try engine.setSpeed(speed, commandID: nextCommand()) }
        self.speed = speed
        publish(.stateChanged)
    }

    /// The player dialog also changes the global default; service commands change only the temporary choice.
    public func setSkipSilence(_ enabled: Bool, alsoGlobal: Bool = false) async throws {
        try await enqueue {
            try self.requireSilenceSupport(enabled)
            try self.speedPreferences?.setCurrentSkipSilence(enabled, alsoGlobal: alsoGlobal)
            if self.generation != nil, let engine = self.engine as? any PlaybackSilenceControlling {
                engine.setSkipSilence(enabled, commandID: self.nextCommand())
            }
            self.skipSilence = enabled
            self.publish(.stateChanged)
        }.value
    }

    private func requireSilenceSupport(_ enabled: Bool, loadingNewMedia: Bool = false) throws {
        guard enabled else { return }
        guard let processor = engine as? any PlaybackSilenceControlling,
              loadingNewMedia || processor.supportsSkipSilence
                || (engine as? any PlaybackSilencePreferenceRetaining)?.retainsSkipSilencePreference == true
        else { throw PlaybackSilenceError.unsupportedEngine }
    }

    private func resolvedSkipSilence(for episode: LibraryEpisode) async throws -> Bool {
        guard let settings = speedPreferences else { return preferences(episode).skipSilence }
        let feedID = try await store.feedID(forEpisode: episode.id)
        return settings.value.resolvedSkipSilence(episodeID: episode.id, feedID: feedID)
    }

    private func resolvedSpeed(for episode: LibraryEpisode) async throws -> Float {
        guard let settings = speedPreferences else { return preferences(episode).speed }
        let feedID = try await store.feedID(forEpisode: episode.id)
        return settings.value.resolved(episodeID: episode.id, feedID: feedID)
    }

    public func toggle(episodeID: Int64? = nil) async throws {
        interactionRevision &+= 1
        try await requestPlayback {
            guard let id = episodeID ?? self.episode?.id else { return }
            if self.episode?.id != id || self.generation == nil {
                try await self.load(id, play: true, fromQueue: false)
            } else if self.wantsPlayback {
                try await self.pauseCurrent()
            } else {
                try await self.resume()
            }
        }.value
    }

    /// Settings changes affect only the matching selected feed, including paused/preparing media.
    public func refreshVolumeAdaptation(feedID: Int64) async throws {
        try await enqueue {
            guard let episode = self.episode, try await self.store.feedID(forEpisode: episode.id) == feedID else { return }
            let setting = try await self.store.volumeAdaptation(forEpisode: episode.id)
            guard setting == .off || self.engine is any PlaybackVolumeControlling else { throw PlaybackVolumeError.unsupportedEngine }
            try (self.engine as? any PlaybackVolumeControlling)?.setVolumeAdaptation(setting)
            self.volumeAdaptation = setting
            self.publish(.stateChanged)
        }.value
    }

    public func seek(to positionMilliseconds: Int64) async throws {
        interactionRevision &+= 1
        try await enqueue {
            await self.seekCurrent(to: positionMilliseconds)
        }.value
    }

    /// Cover arrows preserve playback intent; a dialog row starts playback.
    /// Keep the identity check, optional Play and Seek in one queued operation
    /// so a suspended resume cannot seek an episode selected by another action.
    public func seekChapter(episodeID: Int64, to positionMilliseconds: Int64, startPlayback: Bool) async throws {
        interactionRevision &+= 1
        try await (startPlayback ? requestPlayback : enqueue) {
            guard self.episode?.id == episodeID,
                  self.pendingStreamingEpisodeID == nil || self.pendingStreamingEpisodeID == episodeID else { return }
            if startPlayback, !self.wantsPlayback { try await self.playCurrent() }
            // Admission can replace the engine with a confirmation item.
            guard self.episode?.id == episodeID, self.pendingStreamingEpisodeID == nil else { return }
            await self.seekCurrent(to: positionMilliseconds)
        }.value
    }

    /// Recheck when consuming buffered events, including A→B→A selection and
    /// newer commands within the same playback generation.
    public func isCurrent(_ update: PlaybackPositionUpdate, after bindingRevision: UInt64 = 0) -> Bool {
        update.revision > bindingRevision && update.episodeID == episode?.id
            && update.generation == generation && update.commandID == commandID
    }

    private func publishPosition(generation expectedGeneration: UUID, commandID expectedCommand: UUID) {
        guard generation == expectedGeneration, commandID == expectedCommand,
              let episode, let sample else { return }
        positionRevision &+= 1
        publish(.positionChanged(.init(episodeID: episode.id, revision: positionRevision, generation: expectedGeneration,
            commandID: expectedCommand, positionMilliseconds: sample.positionMilliseconds,
            durationMilliseconds: sample.durationMilliseconds)))
    }

    /// An intentional seek (the slider, chapters, rewind and fast-forward, system and Picture-in-Picture commands):
    /// the audio moves first, then, in the same command, a server library records a takeover from a known
    /// superseding claim (PROTOCOL §8.6). A recording failure never undoes the seek; automatic seeks (ending skip,
    /// rewind after pause) call the engine directly.
    private func seekCurrent(to positionMilliseconds: Int64) async {
        let before = currentReading()?.sample.positionMilliseconds ?? sample?.positionMilliseconds
        guard moveEngine(to: positionMilliseconds), let session, let before else { return }
        if let rebased = try? await store.recordSeekIntent(sessionID: session.id, from: before,
                                                           to: Int32(truncatingIfNeeded: positionMilliseconds),
                                                           wantsPlayback: wantsPlayback, now: clock()),
           self.session?.id == rebased.id { self.session = rebased }
    }

    /// The paused seek a person's slider drag makes, without recording anything: the engine moves and the shown
    /// position follows. False without a loaded engine.
    @discardableResult private func moveEngine(to positionMilliseconds: Int64) -> Bool {
        guard let generation else { return false }
        let command = nextCommand()
        engine.seek(to: positionMilliseconds, commandID: command)
        sample?.positionMilliseconds = Int32(truncatingIfNeeded: positionMilliseconds)
        publishPosition(generation: generation, commandID: command)
        publish(.stateChanged)
        return true
    }

    /// Sync only (PROTOCOL §8.6): in the command queue, if `episodeID` is the current episode and playback is not wanted
    /// (paused, stopped or restored; not preparing, playing or held by an interruption that will resume it), runs
    /// `adopt` (a store transaction) and moves the player to the position it returns, with the same paused seek a
    /// person's slider drag uses; a player without a loaded engine only shows it, and its next Play loads from the row.
    /// Never acts otherwise, and never seeks, pauses or replaces playing audio.
    ///
    /// Playback the engine starts by itself (a Cast receiver resumed by another sender, an interruption's end) does not
    /// wait for this command: its event waits behind it. So the live engine is checked before and after the awaits, and
    /// `adopt` gets `stillPaused`, which its transaction checks last: the adoption commits only if no such playback began
    /// since it was decided, and the engine moves only if none has begun since. Playback that began after the commit is
    /// left playing where it is: listening this phone did not start (a Cast receiver resumed by another sender, or by
    /// itself after a seal) is not recorded until a Play here.
    public func adoptRemotePosition(episodeID: Int64,
                                    adopt: @escaping @Sendable (_ stillPaused: @escaping @Sendable () -> Bool) async throws -> Int32?) async throws {
        try await enqueue {
            guard self.episode?.id == episodeID, !self.wantsPlayback, !self.awaitsInterruptionResumption,
                  self.pendingStreamingEpisodeID == nil, !self.engineResumedByItself else { return }
            switch self.phase {
            case .paused, .stopped, .failed: break
            case .idle, .preparing, .playing, .buffering, .awaitingStreamingConfirmation: return
            }
            let resumptions = self.resumptions, decided = resumptions.count
            guard let position = try await adopt({ resumptions.count == decided }) else { return }
            if let session = try await self.store.playbackSession(), session.episodeID == episodeID { self.session = session }
            if let episode = try await self.store.episode(id: episodeID), self.episode?.id == episodeID { self.episode = episode }
            if self.generation != nil, self.phase == .paused {
                // Resumed meanwhile: the audio stays where it plays; its saves keep that position on the device.
                guard resumptions.count == decided, !self.engineResumedByItself else { self.publish(.positionSaved); return }
                self.moveEngine(to: Int64(position))
            } else {
                self.sample?.positionMilliseconds = position
                self.publish(.stateChanged)
            }
            self.publish(.positionSaved)
        }.value
    }

    public func skip() async throws {
        interactionRevision &+= 1
        try await enqueue {
            guard self.pendingStreamingEpisodeID == nil else { return }
            try await self.finish(.skipped)
        }.value
    }

    public func skipInterval(seconds: Int32, direction: PlaybackIntervalDirection? = nil) async throws {
        interactionRevision &+= 1
        try await enqueue {
            try await self.skipCurrentInterval(seconds: seconds, direction: direction)
        }.value
    }

    private func skipCurrentInterval(seconds: Int32, direction: PlaybackIntervalDirection?) async throws {
        guard generation != nil, let sample = currentReading()?.sample ?? self.sample else { return }
        switch PlaybackTiming.intervalSkip(positionMilliseconds: sample.positionMilliseconds,
            durationMilliseconds: sample.durationMilliseconds, seconds: seconds, direction: direction) {
        case .complete: try await finish(.ended)
        case .seek(let target): await seekCurrent(to: target)
        }
    }

    public func stop() async throws {
        interactionRevision &+= 1
        try await enqueue { try await self.stopCurrent() }.value
    }

    private func stopCurrent() async throws {
        try await pauseCurrent()
        if sleepTimer != nil {
            let events = sleepTimer?.stop() ?? []
            sleepTimer = nil
            try await deliverSleepTimerEvents(events)
        }
        generation = nil
        engine.unload()
        phase = episode == nil ? .idle : .stopped
        publish(.stateChanged)
    }

    public func resetPlaybackPosition(episodeID: Int64) async throws {
        interactionRevision &+= 1
        try await enqueue {
            try await self.store.resetPlaybackPosition(episodeID: episodeID)
            defer { self.publish(.libraryChanged); self.publish(.stateChanged) }
            guard self.episode?.id == episodeID || self.session?.episodeID == episodeID else { return }
            // Retire without pauseCurrent/save/finish: those paths could rewrite
            // the reset position or change history, queue and completion state.
            self.generation = nil
            self.commandID = nil
            self.session = nil
            self.episode = nil
            self.sample = nil
            self.wantsPlayback = false
            self.streamingPolicy = StreamingAdmissionPolicy()
            self.phase = .idle
            self.engine.unload()
            try self.speedPreferences?.clearCurrent()
        }.value
    }

    public func deleteDownloadedMedia(episodeID: Int64, deleteRemovesFromQueue: Bool = false) async throws {
        interactionRevision &+= 1
        try await enqueue {
            try await self.store.requestMediaDeletion(episodeID: episodeID, deleteRemovesFromQueue: deleteRemovesFromQueue)
            defer { self.publish(.libraryChanged); self.publish(.stateChanged) }
            guard self.episode?.id == episodeID || self.session?.episodeID == episodeID else { return }
            self.generation = nil
            self.commandID = nil
            self.session = nil
            self.episode = nil
            self.sample = nil
            self.wantsPlayback = false
            self.streamingPolicy = StreamingAdmissionPolicy()
            self.phase = .idle
            self.engine.unload()
            try self.speedPreferences?.clearCurrent()
        }.value
    }

    public func deleteDownloadedMedia(target: EpisodeMediaDeletionTarget,
        deleteRemovesFromQueue: Bool = false) async throws -> EpisodeMediaDeletionOutcome {
        var outcome = EpisodeMediaDeletionOutcome.stale
        try await enqueue {
            outcome = try await self.store.requestMediaDeletion(target: target,
                deleteRemovesFromQueue: deleteRemovesFromQueue)
            guard outcome == .deleted else { return }
            self.interactionRevision &+= 1
            try self.retireDeletedPlayback([target.episodeID])
            self.publish(.libraryChanged); self.publish(.stateChanged)
        }.value
        return outcome
    }

    /// Hold the existing playback command queue through provider admission and
    /// commit. A later selection cannot be retired by the old deletion callback.
    public func deleteLocalMedia(target: EpisodeMediaDeletionTarget,
        operation: @escaping @MainActor () async throws -> EpisodeMediaDeletionOutcome) async throws -> EpisodeMediaDeletionOutcome {
        var outcome = EpisodeMediaDeletionOutcome.stale
        try await enqueue {
            outcome = try await operation()
            guard outcome == .deleted else { return }
            self.interactionRevision &+= 1
            try self.retireDeletedPlayback([target.episodeID])
            self.publish(.libraryChanged); self.publish(.stateChanged)
        }.value
        return outcome
    }

    /// Feed removal already invalidated persistent selection/session. Retire
    /// matching live media without saving deleted state or completing playback.
    public func retireDeletedEpisodes(_ ids: Set<Int64>) async throws {
        interactionRevision &+= 1
        try await enqueue {
            try self.retireDeletedPlayback(ids)
        }.value
    }

    private func retireDeletedPlayback(_ ids: Set<Int64>) throws {
        guard episode.map({ ids.contains($0.id) }) == true
            || session.map({ ids.contains($0.episodeID) }) == true else { return }
        defer { publish(.libraryChanged); publish(.stateChanged) }
        generation = nil; commandID = nil; session = nil
        episode = nil; sample = nil; wantsPlayback = false
        streamingPolicy = StreamingAdmissionPolicy(); phase = .idle
        engine.unload()
        try speedPreferences?.clearCurrent()
    }

    func awaitPendingOperations() async throws { try await enqueue {}.value }

    /// Returns once every command queued before the call has finished (the library switch waits for them).
    public func settle() async { _ = try? await enqueue {}.value }

    /// Recovery must observe prior position saves and reject a replaced/failed media owner.
    func synchronizePlaybackStatistics(generation: UUID) async throws {
        try await enqueue {
            guard self.generation == generation, self.phase != .failed else {
                throw FeedLibraryError.invalidMutation
            }
        }.value
    }

    /// The library graph that owns this player is being torn down (a library switch, a database import). Closes command
    /// admission at once: every later command is refused with `CancellationError` and never runs, whoever sends it
    /// (screens, system controls, widgets, intents, Cast). Commands admitted earlier run, then playback stops.
    /// Returns that stop; calling it again returns the same one.
    @discardableResult public func retire() -> Task<Void, Never> {
        if let retirement { return retirement }
        interactionRevision &+= 1
        let stop = admit { try await self.stopCurrent() }
        isRetired = true
        let task = Task { _ = try? await stop.value }
        retirement = task
        return task
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        guard !isRetired else { return Task { throw CancellationError() } }
        return admit(operation)
    }

    /// `enqueue` for a command that may start playback: it counts as playing for the sync budgets from its
    /// admission until it has run, and `onPlaybackRequested` fences a publication admitted before it.
    private func requestPlayback(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        guard !isRetired else { return enqueue(operation) }
        playRequests += 1
        onPlaybackRequested?()
        return admit {
            defer { self.playRequests -= 1 }
            try await operation()
        }
    }

    private func admit(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let previous = tail
        sequence &+= 1
        let sequence = sequence
        let task = Task { @MainActor in
            _ = try? await previous?.value
            defer { if self.sequence == sequence { self.tail = nil } }
            try await operation()
        }
        tail = task
        return task
    }

    private func load(_ id: Int64, play: Bool, fromQueue: Bool, adoption: ExternalAdoption? = nil) async throws {
        guard let next = try await store.episode(id: id) else { throw FeedLibraryError.missingEpisode(id) }
        serverLibrary = await store.isServerLibrary
        guard next.details.media != nil else { throw FeedLibraryError.invalidMutation }
        let prefs = preferences(next)
        let feedSkip = try await skipPreferences?(next)
        let deletionPolicy = try await store.playbackDeletionPolicy(forEpisode: next.id)
        let volume = try await store.volumeAdaptation(forEpisode: next.id)
        guard volume == .off || engine is any PlaybackVolumeControlling else { throw PlaybackVolumeError.unsupportedEngine }
        let resolvedSpeed = try await resolvedSpeed(for: next)
        let resolvedSkipSilence = try await resolvedSkipSilence(for: next)
        try requireSilenceSupport(resolvedSkipSilence, loadingNewMedia: true)
        guard resolvedSpeed.isFinite, resolvedSpeed > 0 else { throw PlaybackSpeedError.invalidSpeed }
        if let adoption { guard adoption.isCurrent() else { throw CancellationError() }; _ = try adoption.state() }
        let retainedSession = adoption != nil && episode?.id == id && generation != nil ? session : nil
        // Replacing the item keeps the audio session for it (as Media3 keeps focus across items); a
        // replacement that does not reach the engine's load releases it.
        let reservation = adoption == nil ? engine as? any PlaybackSessionReserving : nil
        reservation?.reserveSessionForNextItem()
        var reservationTaken = false
        defer { if !reservationTaken { reservation?.cancelSessionReservation() } }
        if let episode, episode.id != id, session != nil {
            do { try await finish(.switched) }
            catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                // A committed refresh can remove the old row before its
                // durable teardown reaches this command queue. A switch to a
                // surviving episode must not try to finish that deleted row.
                // Check after failure so deletion during finish's awaits is
                // covered; preserve every failure for a still-existing row.
                guard try await store.episode(id: episode.id) == nil else { throw error }
                try Task.checkCancellation()
                try retireDeletedPlayback([episode.id])
            }
        }
        else if generation != nil { try await pauseCurrent() }
        adoption?.didRetire()
        generation = nil
        if let adoption {
            guard adoption.isCurrent() else { throw CancellationError() }
            try adoption.activate()
        } else { engine.unload() }
        streamingPolicy.willLoadEpisode()
        let access: PlaybackStreamingAccess?
        do { access = try await streamingAccess?(next) }
        catch {
            // Loading has already retired the old engine. A cancelled/failed
            // access observation must not leave a displayed preparing/playing state.
            commandID = nil
            wantsPlayback = false
            sample?.status = .paused
            phase = episode == nil ? .idle : .stopped
            publish(.stateChanged)
            throw error
        }
        if let access,
           case .confirm(let pendingID) = streamingPolicy.loadedMedia(.init(id: id, needsStreaming: access.needsStreaming),
                streamingAllowed: access.streamingAllowed, isCasting: access.isCasting) {
            showStreamingConfirmation(pendingID)
            return
        }
        let intro = PlaybackTiming.introSkip(positionMilliseconds: next.userState.positionMilliseconds,
                                             durationMilliseconds: next.details.media?.durationMilliseconds ?? 0,
                                             preferences: feedSkip ?? prefs.skip)
        let external = try adoption?.state()
        let position = external.map { Int64($0.sample.positionMilliseconds) } ?? (fromQueue ? intro.positionMilliseconds : Int64(PlaybackTiming.positionAfterPause(
            positionMilliseconds: Int32(truncatingIfNeeded: intro.positionMilliseconds),
            lastPlayedMilliseconds: lastPlayedHere(next), nowMilliseconds: milliseconds())))
        let baseline = fromQueue ? next.userState.positionMilliseconds : Int32(truncatingIfNeeded: position)
        do {
            if let retainedSession { session = retainedSession }
            else { session = try await store.beginPlayback(episodeID: id, positionMilliseconds: baseline,
                                                    enqueueLocation: prefs.enqueueLocation) }
        } catch { storageFailure(); throw error }
        baselineUsesPreparedPosition = !fromQueue && retainedSession == nil
        externalPreparation = adoption != nil
        episode = try await store.episode(id: id)
        loadedSkipPreferences = feedSkip
        loadedDeletionPolicy = deletionPolicy
        volumeAdaptation = volume
        let token = UUID()
        generation = token
        commandID = token
        wantsPlayback = external?.sample.status == .playing || (external == nil && play)
        phase = .preparing
        sample = .init(positionMilliseconds: Int32(truncatingIfNeeded: position),
                       durationMilliseconds: next.details.media?.durationMilliseconds ?? 0, status: .paused)
        if external == nil, let seconds = intro.notificationSeconds { publish(.introSkipped(seconds: seconds)) }
        speed = resolvedSpeed
        skipSilence = resolvedSkipSilence
        do { try speedPreferences?.activate(episodeID: id, resolvedSpeed: speed, resolvedSkipSilence: skipSilence) }
        catch { storageFailure(); throw error }
        if let adoption, let external {
            guard adoption.isCurrent(), let receiver = engine as? any PlaybackExternalStateAdopting else {
                throw CancellationError()
            }
            try receiver.adopt(episode: next, generation: token, state: external)
        } else {
            engine.load(episode: next, generation: token, positionMilliseconds: position)
            reservationTaken = true
        }
        try engine.setSpeed(speed, commandID: token)
        try (engine as? any PlaybackVolumeControlling)?.setVolumeAdaptation(volume)
        (engine as? any PlaybackSilenceControlling)?.setSkipSilence(skipSilence, commandID: token)
        if external == nil, play { engine.play(commandID: nextCommand()) }
        publish(.libraryChanged)
        publish(.stateChanged)
    }

    private func resume() async throws {
        guard let episode, generation != nil else { return }
        if let access = try await streamingAccess?(episode) {
            let state: StreamingAdmissionPolicy.PlayerState = phase == .preparing || phase == .buffering ? .buffering : .ready
            if case .confirm(let id) = streamingPolicy.play(isConfirmationItem: false,
                currentMedia: .init(id: episode.id, needsStreaming: access.needsStreaming), state: state,
                streamingAllowed: access.streamingAllowed, isCasting: access.isCasting) {
                showStreamingConfirmation(id)
                return
            }
        }
        guard !wantsPlayback || (engine as? any PlaybackExternalStateAdopting)?.requiresExplicitReload == true else { return }
        wantsPlayback = true
        var intent: (position: Int32, duration: Int32, time: Date)?
        if phase != .preparing {
            let position = currentReading()?.sample.positionMilliseconds ?? sample?.positionMilliseconds ?? 0
            let target = PlaybackTiming.positionAfterPause(positionMilliseconds: position,
                lastPlayedMilliseconds: lastPlayedHere(episode), nowMilliseconds: milliseconds())
            if target != position { engine.seek(to: Int64(target), commandID: nextCommand()) }
            engine.play(commandID: nextCommand())
            intent = (target, sample?.durationMilliseconds ?? 0, clock())
            if let reading = currentReading() { sample = reading.sample }
            sample?.status = .playing
            lastSaveMilliseconds = monotonicClock()
            phase = currentReading()?.buffering == true ? .buffering : .playing
        } else { engine.play(commandID: nextCommand()) }
        if phase != .preparing { try await autoEnableSleepTimer() }
        publish(.stateChanged)
        // Intentional play on a prepared engine (PROTOCOL §8): after the engine command, a server library starts the
        // load's sync session or records the resume's claim. Never fails playback; a preparing engine records at .ready.
        if let intent, let session, let generation {
            _ = try? await store.recordPlaybackIntent(sessionID: session.id, positionMilliseconds: intent.position,
                                                      durationMilliseconds: intent.duration, baseline: generation,
                                                      intentional: true, now: intent.time)
        }
    }

    private func showStreamingConfirmation(_ id: Int64) {
        // Keep saved/displayed episode metadata, but retire all callbacks and stop
        // remote playback. The pending ID owns direct Play until another selection.
        generation = nil
        commandID = nil
        engine.unload()
        wantsPlayback = false
        phase = .awaitingStreamingConfirmation
        if let episode {
            sample = .init(positionMilliseconds: episode.userState.positionMilliseconds,
                           durationMilliseconds: episode.details.media?.durationMilliseconds ?? 0, status: .paused)
        }
        publish(.streamingConfirmationRequired(episodeID: id))
        publish(.stateChanged)
    }

    private func pauseCurrent() async throws {
        wantsPlayback = false
        guard generation != nil else { return }
        let preparing = phase == .preparing
        engine.pause(commandID: nextCommand())
        if !preparing {
            if let reading = currentReading() { sample = reading.sample }
            sample?.status = .paused
            try await save(synchronize: episode.map { preferences($0).end.synchronize } ?? false)
            phase = .paused
        }
        publish(.stateChanged)
    }

    /// When this device last played `episode`, as the rewinds after a pause or an interruption measure it: Android's
    /// last-played time, which every save of a standalone library writes. A server library's synced date moves only with
    /// listening this phone started and with other devices' listening, so there the device-local time of its latest save
    /// here (receiver playback it observed included) is used: the rewind is the one a standalone library gives. A
    /// standalone library always uses its last-played date, whatever device-local time a record holds.
    private func lastPlayedHere(_ episode: LibraryEpisode) -> Int64 {
        if serverLibrary, let played = episode.userState.playedHereMilliseconds { return played }
        return episode.userState.lastPlayedTimeMilliseconds
    }

    /// The engine reports playing although playback is not wanted: it resumed by itself and its event is still queued.
    private var engineResumedByItself: Bool {
        guard !wantsPlayback, let generation, let reading = engine.reading, reading.generation == generation else { return false }
        return reading.sample.status == .playing
    }

    private func currentReading() -> PlaybackEngineReading? {
        guard let reading = engine.reading, reading.isPrepared,
              reading.generation == generation, reading.commandID == commandID else { return nil }
        return reading
    }

    private func nextCommand() -> UUID {
        let id = UUID()
        commandID = id
        return id
    }

    private func save(synchronize: Bool = false, at timestamp: Date? = nil) async throws {
        guard let session, let sample else { return }
        do {
            guard let saved = try await store.recordPlayback(sessionID: session.id, sample: sample,
                                                             now: timestamp ?? clock(), synchronize: synchronize) else {
                throw FeedLibraryError.invalidMutation
            }
            episode = saved
        } catch { storageFailure(); throw error }
        // DBWriter.setFeedMediaPlaybackInformation does not publish FeedItemEvent.
        // Distinguish periodic position writes from queue/item changes for screen refreshes.
        publish(.positionSaved)
    }

    private func storageFailure() {
        guard phase != .failed || generation != nil else { return }
        engine.pause(commandID: nextCommand())
        generation = nil
        engine.unload()
        wantsPlayback = false
        phase = .failed
        publish(.storageFailed)
        publish(.stateChanged)
    }

    private func finish(_ reason: PlaybackEndReason, finalSample: PlaybackSample? = nil, at timestamp: Date? = nil) async throws {
        guard let session, let episode else { return }
        // Stop the audio first: a completion entered with audio still playing (an interval skip past the
        // end) must not restore the sleep-timer volume while it can be heard.
        engine.pause(commandID: nextCommand())
        var continueQueue = true
        if reason == .ended, sleepTimer?.isActive == true {
            let completion = sleepTimer!.episodeFinished()
            continueQueue = completion.continuePlayback
            if !continueQueue { sleepTimer = nil }
            try await deliverSleepTimerEvents(completion.events)
        }
        var prefs = preferences(episode)
        // ensureCurrentMediaLoaded rereads the previous media for direct
        // switches; startNextInQueue uses its retained media for end/skip.
        let deletionPolicy = reason == .switched
            ? try await store.playbackDeletionPolicy(forEpisode: episode.id) : loadedDeletionPolicy
        prefs.end.autoDelete = deletionPolicy.choice.enabled(global: prefs.end.autoDelete,
            local: prefs.end.autoDeleteLocal, isLocalFeed: deletionPolicy.isLocalFeed)
        if let finalSample { sample = finalSample; try await save(at: timestamp) }
        else if phase != .preparing, let reading = currentReading() { sample = reading.sample; try await save() }
        let result: PlaybackEndResult
        do {
            guard let ended = try await store.endPlayback(sessionID: session.id, reason: reason,
                                                          preferences: prefs.end, now: timestamp ?? clock(), continueQueue: continueQueue) else {
                throw FeedLibraryError.invalidMutation
            }
            result = ended
        } catch { storageFailure(); throw error }
        generation = nil
        self.session = nil
        let retainsSelection = reason == .switched || result.nextEpisodeID != nil
        self.episode = retainsSelection ? result.episode : nil
        sample = retainsSelection ? .init(positionMilliseconds: result.episode.userState.positionMilliseconds,
            durationMilliseconds: result.episode.details.media?.durationMilliseconds ?? 0, status: .paused) : nil
        wantsPlayback = false
        phase = retainsSelection ? .stopped : .idle
        // The next queued item inherits the audio session; the end of the queue releases it.
        let reservation = reason != .switched && result.nextEpisodeID != nil ? engine as? any PlaybackSessionReserving : nil
        reservation?.reserveSessionForNextItem()
        engine.unload()
        // Retire the reader before unlinking media. File-provider latency and
        // failure must not hold up the next episode or player commands.
        scheduleCompletionEffects()
        if reason != .switched, result.nextEpisodeID == nil { try speedPreferences?.clearCurrent() }
        publish(.libraryChanged)
        publish(.stateChanged)
        if reason != .switched {
            if let next = result.nextEpisodeID {
                do { try await load(next, play: prefs.followQueue, fromQueue: true) }
                catch { reservation?.cancelSessionReservation(); throw error }
            } else if reason == .skipped { publish(.noFollowingEpisode) }
        }
    }

    /// `receivedAt` stamps what is saved; `monotonic` (the same moment) paces checkpoints and the clock timer.
    private func handle(_ event: PlaybackEngineEvent, receivedAt: Date, monotonic: Int64) async throws {
        if case .failed(let token, let message) = event {
            guard token == generation else { return }
            try await pauseCurrent()
            generation = nil
            engine.unload()
            phase = .failed
            publish(.engineFailed(message))
            publish(.stateChanged)
            return
        }
        if case .mediaServicesReset(let final) = event {
            // Not a failure (Apple QA1749): the item stays selected and paused at its position, with no dialog. The
            // engine closed its audio objects; this generation is cleared and unloaded as after a stop, and only an
            // explicit Play loads it again (a late event of the old generation finds it gone).
            guard final.generation == generation else { return }
            wantsPlayback = false
            if phase != .preparing {
                // A command queued after the reset decided what is shown (a seek): it is kept, as on a pause.
                if final.isPrepared, final.commandID == commandID { sample = final.sample }
                sample?.status = .paused
                try await save(synchronize: episode.map { preferences($0).end.synchronize } ?? false, at: receivedAt)
            }
            generation = nil
            engine.unload()
            phase = episode == nil ? .idle : .stopped
            publish(.stateChanged)
            return
        }
        if case .timelineReset(let final) = event {
            // A source discontinuity survives a queued Play/Pause command. A
            // retired episode generation must never alter its replacement.
            guard final.generation == generation, final.isPrepared, let session else { return }
            var settled = final.sample
            settled.status = sample?.status ?? settled.status
            guard let saved = try await store.recordPlaybackTimelineReset(sessionID: session.id,
                    finalSample: settled, now: receivedAt) else { throw FeedLibraryError.invalidMutation }
            episode = saved.episode
            self.session = saved.session
            settled.positionMilliseconds = 0
            sample = settled
            lastSaveMilliseconds = monotonic
            publish(.positionSaved)
            // A reset may survive an older command but cannot cross generations.
            if let commandID { publishPosition(generation: final.generation, commandID: commandID) }
            publish(.stateChanged)
            return
        }
        var reading: PlaybackEngineReading
        switch event {
        case .ready(let value), .stateChanged(let value), .position(let value), .ended(let value): reading = value
        case .failed, .timelineReset, .mediaServicesReset: return
        }
        guard reading.generation == generation else { return }
        if reading.commandID != commandID {
            guard case .ready = event, let current = currentReading() else { return }
            reading = current
        }
        speed = reading.speed
        skipSilence = reading.skipSilence
        switch event {
        case .ready:
            guard phase == .preparing else { return }
            if baselineUsesPreparedPosition, let episode, let session,
               session.startPositionMilliseconds != max(0, reading.sample.positionMilliseconds) {
                self.session = try await store.beginPlayback(episodeID: episode.id,
                    positionMilliseconds: reading.sample.positionMilliseconds,
                    enqueueLocation: preferences(episode).enqueueLocation)
            }
            sample = reading.sample
            wantsPlayback = reading.sample.status == .playing
            if wantsPlayback {
                phase = reading.buffering ? .buffering : .playing
                lastSaveMilliseconds = monotonic
                // Playback starts (PROTOCOL §8): a server library starts the load's sync session. A Cast receiver's
                // restored state is no press of play: listening this phone did not start is not recorded until a Play
                // here. Never fails playback.
                if let session, let generation {
                    _ = try? await store.recordPlaybackIntent(sessionID: session.id, positionMilliseconds: reading.sample.positionMilliseconds,
                                                              durationMilliseconds: reading.sample.durationMilliseconds, baseline: generation,
                                                              intentional: !externalPreparation, now: receivedAt)
                }
                try await save(at: receivedAt)
                try await autoEnableSleepTimer()
            } else {
                phase = .paused
                if externalPreparation { try await save(at: receivedAt) }
            }
            externalPreparation = false
        case .stateChanged:
            if phase == .preparing {
                wantsPlayback = reading.sample.status == .playing
                publish(.stateChanged)
                return
            }
            let wasBuffering = phase == .buffering
            let wasPlaying = phase == .playing || phase == .buffering
            sample = reading.sample
            wantsPlayback = reading.sample.status == .playing
            phase = wantsPlayback ? (reading.buffering ? .buffering : .playing) : .paused
            if wantsPlayback && !wasPlaying { lastSaveMilliseconds = monotonic }
            if !wantsPlayback && wasPlaying {
                try await save(synchronize: episode.map { preferences($0).end.synchronize } ?? false, at: receivedAt)
            }
            if wantsPlayback && wasBuffering && !reading.buffering { try await save(at: receivedAt) }
            if wantsPlayback && !wasPlaying { try await autoEnableSleepTimer() }
        case .position:
            guard phase == .playing || phase == .buffering else { return }
            let hasDuration = reading.sample.durationMilliseconds > 0
            if hasDuration {
                sample = reading.sample
                publishPosition(generation: reading.generation, commandID: reading.commandID)
            }
            // A clock timer measures listening time even for live media. Unknown
            // duration still cannot supply episode-mode fade/display/save facts.
            if var timer = sleepTimer, hasDuration || timer.mode == .minutes {
                let settings = sleepTimerPreferences?.value ?? .init()
                let events = timer.tick(nowMilliseconds: monotonic,
                    positionMilliseconds: Int64(reading.sample.positionMilliseconds),
                    durationMilliseconds: Int64(reading.sample.durationMilliseconds),
                    vibrate: settings.vibrate, shakeToReset: settings.shakeToReset)
                sleepTimer = timer
                try await deliverSleepTimerEvents(events)
                if !wantsPlayback { publish(.stateChanged); return }
            }
            guard hasDuration else { onUnknownDurationTick?(); return }
            if monotonic &- lastSaveMilliseconds >= 5_000 { try await save(at: receivedAt); lastSaveMilliseconds = monotonic }
            if let episode {
                let skip = loadedSkipPreferences ?? preferences(episode).skip
                if PlaybackTiming.shouldSkipEnding(positionMilliseconds: Int64(reading.sample.positionMilliseconds),
                                                    durationMilliseconds: Int64(reading.sample.durationMilliseconds),
                                                    speed: reading.speed, preferences: skip) {
                    engine.seek(to: Int64(reading.sample.durationMilliseconds), commandID: nextCommand())
                    publish(.endingSkipped(seconds: skip.endingSeconds))
                }
            }
        case .ended:
            guard phase != .preparing else { return }
            sample = reading.sample
            try await finish(.ended, finalSample: reading.sample, at: receivedAt)
        case .failed, .timelineReset, .mediaServicesReset: return
        }
        publish(.stateChanged)
    }

    /// Wall time, for comparisons with saved timestamps.
    private func milliseconds() -> Int64 { Int64(clock().timeIntervalSince1970 * 1_000) }
    /// Milliseconds on the continuous clock since `origin`. It is monotonic, so a wall-clock correction does not
    /// move it, and like wall time it keeps counting while the device sleeps, so a sleep reads as a long gap (a new
    /// baseline for the clock timer, as on Android) rather than as a few seconds of listening.
    nonisolated static func continuousMilliseconds(since origin: ContinuousClock.Instant) -> Int64 {
        let elapsed = (ContinuousClock.now - origin).components
        return elapsed.seconds &* 1_000 &+ elapsed.attoseconds / 1_000_000_000_000_000
    }
    private func publish(_ event: Event) { for listener in listeners.values { listener.yield(event) } }
}

private extension PlaybackEngineEvent {
    /// The reading an event carries, if any.
    var engineReading: PlaybackEngineReading? {
        switch self {
        case .ready(let value), .stateChanged(let value), .position(let value), .timelineReset(let value), .ended(let value),
             .mediaServicesReset(let value): value
        case .failed: nil
        }
    }
}

/// Counts playback an engine started by itself, from any thread (the store's adoption transaction reads it).
final class PlaybackResumptionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var count: UInt64 { lock.withLock { value } }
    func advance() { lock.withLock { value &+= 1 } }
}

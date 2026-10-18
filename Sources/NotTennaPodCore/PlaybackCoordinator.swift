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
    /// The episode whose current load proceeded on "Once" consent ("Allow this time"): its Cast relay and streamed
    /// chapter list may use a restricted network (`AuxiliaryNetworkAdmission`). Consent ends with that load: the next
    /// load, and every retirement or unload of it (stop, completion, skip, failure, a media-services reset), clear it.
    public private(set) var onceAdmittedEpisodeID: Int64?
    /// Where a confirmation the route asked for (`PlaybackEngineEvent.streamingConfirmationRequired`) resumes: the
    /// position that route was loading, such as the local position at a Cast transfer or a receiver's position.
    private var confirmationPosition: (episodeID: Int64, milliseconds: Int64)?
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
    /// Admitted commands and engine events, in admission order, until each has finished (`admit`).
    private var admitted: [Admission] = []
    /// The admission whose operation runs now.
    private var running: Admission?
    /// An engine stage runs now: a stage admitted meanwhile waits until it has finished.
    private var stagingEngine = false
    /// Tests turn this off for the serial reference: every engine stage then waits for its turn.
    var hoistsEngineStages = true
#if DEBUG
    /// Tests: called before each store write the coordinator makes, with the values it passes; awaiting holds the
    /// write, throwing fails it.
    var storeGate: (@MainActor (PlaybackStoreCall) async throws -> Void)?
#endif

    /// One admitted command or engine event. `residual`: all it still does is a store write whose inputs it captured,
    /// then applying that write's result and publishing.
    private final class Admission {
        var residual = false
        /// The engine stage of a pause, a seek or a position or state event, not run yet.
        var stage: (@MainActor () -> Stage)?
        /// What that stage left to write, when it ran before its turn.
        var persistence: (@MainActor () async throws -> Void)?
    }

    /// An engine stage's outcome: its store write (nil: none), or `opaque` when this time it needs more than the
    /// engine (a skip past the end, a sleep timer expiring), so the whole command waits for its turn.
    private enum Stage {
        case persist((@MainActor () async throws -> Void)?)
        case opaque
    }

    /// What a save writes, captured when it is decided: nothing that runs before it is written changes it.
    private struct SaveCapture {
        let sessionID: UUID, generation: UUID?, sample: PlaybackSample, now: Date, synchronize: Bool
    }

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
            // A route's refusal belongs to the route load that raised it: one replaced before the refusal is handled
            // (a session ending or handed back) must not stop its replacement.
            let route = (self.engine as? RoutedPlaybackEngine)?.routeID
            // Playback the engine starts by itself (an interruption ending with shouldResume) is fenced like a Play,
            // in this step: its handling waits in the queue, and until it ran it counts as starting playback.
            let resumes = !self.isRetired && !self.wantsPlayback && event.engineReading?.sample.status == .playing
            if resumes { self.resumptions.advance(); self.playRequests += 1; self.onPlaybackRequested?() }
            let handle: @MainActor () async throws -> Void = {
                do { try await self.handle(event, receivedAt: receivedAt, monotonic: monotonic, route: route) }
                catch { self.storageFailure() }
            }
            switch event {
            case .position, .stateChanged:
                // A position or state report moves no store write ahead of another: its save waits for its turn, but
                // what it shows does not wait for an earlier save, nor holds back a later pause or seek.
                _ = self.admitStaged(event: true, stage: {
                    self.eventStage(event, receivedAt: receivedAt, monotonic: monotonic)
                }, fallback: handle, finished: { if resumes { self.playRequests -= 1 } })
            default:
                _ = self.enqueue {
                    defer { if resumes { self.playRequests -= 1 } }
                    try await handle()
                }
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
        // Its engine stage may run at admission: a request already cancelled never reaches the engine.
        try Task.checkCancellation()
        let events = events()
        var seekCommand: UUID?, refused = false
        let cancelled = PictureSeekCancellation()
        // Like every seek, the engine moves as soon as everything admitted before it has only captured store writes
        // left; its recording keeps its place, and a later Pause does not wait for it.
        let queued = admitStaged(stage: {
            guard !cancelled.isSet, isCurrent(), self.videoCommandIdentity == identity,
                  let state = self.systemSnapshot, state.canSeek else { refused = true; return .persist(nil) }
            self.interactionRevision &+= 1
            let record = self.seekStage(to: min(max(0, milliseconds), state.durationMilliseconds ?? 0))
            seekCommand = self.commandID
            return .persist(record)
        }, fallback: {})
        try await withTaskCancellationHandler(operation: { try await queued.value },
                                              onCancel: { cancelled.set(); queued.cancel() })
        if refused || cancelled.isSet { throw CancellationError() }
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
        // Pause, seek and skip (the Lock Screen's, headphones') move the engine without waiting for earlier saves.
        let stage: @MainActor () -> Stage = {
            guard isCurrent(), let state = self.systemSnapshot, state.identity == identity else { return .persist(nil) }
            let staged: Stage
            switch command {
            case .pause:
                staged = .persist(self.wantsPlayback || self.awaitsInterruptionResumption ? self.pauseStage() : nil)
            case .toggle:
                guard state.canPlay else { return .persist(nil) }
                guard self.wantsPlayback else { return .opaque }
                staged = .persist(self.pauseStage())
            case .seek(let milliseconds):
                guard state.canSeek else { return .persist(nil) }
                staged = .persist(self.seekStage(to: min(max(0, milliseconds), state.durationMilliseconds ?? 0)))
            case .restart:
                guard state.canSkip else { return .persist(nil) }
                staged = .persist(self.seekStage(to: 0))
            case .skip(let seconds, let direction):
                guard state.canSkip else { return .persist(nil) }
                staged = self.skipIntervalStage(seconds: seconds, direction: direction)
            case .play, .next, .stop, .rate: return .opaque
            }
            guard case .persist = staged else { return .opaque }
            self.interactionRevision &+= 1
            accepted = true
            return staged
        }
        try await admitStaged(startsPlayback: starts, stage: stage, fallback: {
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
            case .play: try await self.playCurrent(residual: true)
            // During an interruption the player shows paused, but its resumption is pending: Pause gives it up.
            case .pause: if self.wantsPlayback || self.awaitsInterruptionResumption { try await self.pauseCurrent() }
            case .toggle:
                if self.wantsPlayback { try await self.pauseCurrent() }
                else { try await self.playCurrent(residual: true) }
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
                if play { try await self.resume(residual: true) } else { try await self.pauseCurrent() }
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
                    self.generation = nil; self.commandID = nil; self.engine.unload(); self.onceAdmittedEpisodeID = nil
                    self.wantsPlayback = false; self.sample?.status = .paused
                    self.phase = self.episode == nil ? .idle : .stopped
                    self.publish(.stateChanged)
                }
                throw error
            }
        }.value
    }

    /// A Cast receiver's item that this library loaded needs a new relay that the network does not admit (a restoration
    /// with no live lease): loads `episodeID` at the receiver's position on the route `activateRoute` installs, once the
    /// current item has settled and unloaded, so the route's refusal asks Once/Always there. It is not a person's
    /// command: it runs only while `isCurrent` holds and no person's command came after it was asked, checked again
    /// just before the route is installed, so a newer selection always wins and the receiver is left alone.
    public func selectOnRoute(episodeID: Int64, positionMilliseconds: Int64,
                              activateRoute: @escaping @MainActor () throws -> Void,
                              isCurrent: @escaping @MainActor () -> Bool) async throws {
        let interaction = interactionRevision
        let current: @MainActor () -> Bool = { [weak self] in isCurrent() && self?.interactionRevision == interaction }
        try await enqueue {
            guard current() else { throw CancellationError() }
            var retired = false
            let route = RouteActivation(activate: activateRoute, isCurrent: current, didRetire: { retired = true })
            do { try await self.load(episodeID, play: false, fromQueue: false, startPosition: positionMilliseconds, route: route) }
            catch {
                if retired {
                    self.generation = nil; self.commandID = nil; self.engine.unload(); self.onceAdmittedEpisodeID = nil
                    self.wantsPlayback = false; self.sample?.status = .paused
                    self.phase = self.episode == nil ? .idle : .stopped
                    self.publish(.stateChanged)
                }
                throw error
            }
        }.value
    }

    private struct RouteActivation {
        var activate: @MainActor () throws -> Void
        var isCurrent: @MainActor () -> Bool
        var didRetire: @MainActor () -> Void
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
        try await requestPlayback { try await self.playCurrent(residual: true) }.value
    }

    /// `residual`: the command does nothing after this (see `resume`).
    private func playCurrent(residual: Bool = false) async throws {
        if pendingStreamingEpisodeID != nil {
            let resumeAt = confirmationPosition
            let decision = streamingPolicy.play(isConfirmationItem: true, currentMedia: nil,
                state: .ready, streamingAllowed: false, isCasting: false)
            if case .reload(let id) = decision {
                try await load(id, play: true, fromQueue: false,
                               startPosition: resumeAt?.episodeID == id ? resumeAt?.milliseconds : nil)
            }
            return
        }
        guard let episode else { return }
        if generation == nil { try await load(episode.id, play: true, fromQueue: false) }
        else { try await resume(residual: residual) }
    }

    /// The engine pauses at once, even while an earlier save waits for the store; the pause's own save keeps its place.
    public func pause() async throws {
        interactionRevision &+= 1
        try await admitStaged(stage: { .persist(self.pauseStage()) }, fallback: { try await self.pauseCurrent() }).value
    }

    public enum SleepTimerError: Error, Equatable { case noMediaPlaying, invalidValue }

    public func startSleepTimer(mode: SleepTimerMode, value: Int64) async throws {
        try await enqueue {
            guard self.wantsPlayback, self.generation != nil else { throw SleepTimerError.noMediaPlaying }
            guard value > 0 else { throw SleepTimerError.invalidValue }
            try self.startTimer(mode: mode, value: value)
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

    /// A started timer has time left (`value` > 0), so nothing it reports expires: no pause, no save.
    private func startTimer(mode: SleepTimerMode, value: Int64) throws {
        guard engine is any PlaybackVolumeControlling else { throw PlaybackVolumeError.unsupportedEngine }
        var timer = sleepTimer ?? SleepTimer()
        let events = timer.start(mode: mode, value: value, nowMilliseconds: monotonicClock())
        sleepTimer = timer
        let expired = try applySleepTimerEvents(events)
        assert(!expired, "a started sleep timer has time left")
    }

    private func autoEnableSleepTimer() throws {
        guard sleepTimer == nil, let settings = sleepTimerPreferences?.value,
              settings.autoEnable, settings.includes(hour: Calendar.current.component(.hour, from: clock())),
              let value = settings.timerValue, value > 0 else { return }
        try startTimer(mode: settings.mode, value: value)
    }

    private static func expires(_ events: [SleepTimerEvent]) -> Bool {
        events.contains { if case .updated(let value) = $0 { value.milliseconds == 0 } else { false } }
    }

    private func deliverSleepTimerEvents(_ events: [SleepTimerEvent]) async throws {
        guard try applySleepTimerEvents(events) else { return }
        let cleanup = sleepTimer?.stop() ?? []
        sleepTimer = nil; sleepTimerValue = nil
        for effect in cleanup { if case .shakeListening = effect { onSleepTimerFeedback?(effect) } }
        // pauseCurrent pauses the engine before it saves; restore even if saving fails.
        var pauseFailure: (any Error)?
        do { try await pauseCurrent() } catch { pauseFailure = error }
        try (engine as? any PlaybackVolumeControlling)?.setSleepTimerVolume(1)
        if let pauseFailure { throw pauseFailure }
    }

    /// Applies what the timer reports; returns whether it expired (the caller then pauses before restoring the volume).
    private func applySleepTimerEvents(_ events: [SleepTimerEvent]) throws -> Bool {
        // At expiry the faded audio stops first and only then is the volume restored, on every
        // route: a restore before the pause could be heard at full level.
        let expired = Self.expires(events)
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
        return expired
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

    /// The player's Play/Pause button: pausing moves the engine at once, like `pause()`.
    public func toggle(episodeID: Int64? = nil) async throws {
        interactionRevision &+= 1
        try await admitStaged(startsPlayback: true, stage: {
            guard let id = episodeID ?? self.episode?.id else { return .persist(nil) }
            guard self.episode?.id == id, self.generation != nil, self.wantsPlayback else { return .opaque }
            return .persist(self.pauseStage())
        }, fallback: {
            guard let id = episodeID ?? self.episode?.id else { return }
            if self.episode?.id != id || self.generation == nil {
                try await self.load(id, play: true, fromQueue: false)
            } else if self.wantsPlayback {
                try await self.pauseCurrent()
            } else {
                try await self.resume(residual: true)
            }
        }).value
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

    /// The engine seeks at once, even while an earlier save waits for the store; the seek's own record keeps its place.
    public func seek(to positionMilliseconds: Int64) async throws {
        interactionRevision &+= 1
        try await admitStaged(stage: { .persist(self.seekStage(to: positionMilliseconds)) },
                              fallback: { await self.seekCurrent(to: positionMilliseconds) }).value
    }

    /// Cover arrows preserve playback intent; a dialog row starts playback.
    /// Keep the identity check, optional Play and Seek in one queued operation
    /// so a suspended resume cannot seek an episode selected by another action.
    public func seekChapter(episodeID: Int64, to positionMilliseconds: Int64, startPlayback: Bool) async throws {
        interactionRevision &+= 1
        guard startPlayback else {
            try await admitStaged(stage: {
                guard self.episode?.id == episodeID, self.pendingStreamingEpisodeID == nil else { return .persist(nil) }
                return .persist(self.seekStage(to: positionMilliseconds))
            }, fallback: {
                guard self.episode?.id == episodeID, self.pendingStreamingEpisodeID == nil else { return }
                await self.seekCurrent(to: positionMilliseconds)
            }).value
            return
        }
        try await requestPlayback {
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
        await seekStage(to: positionMilliseconds)?()
    }

    /// A seek's engine stage: the engine moves now; the returned record (nil: none) writes what was captured here.
    /// Its failure is ignored, as the seek's always was; its result applies only to the session that captured it.
    private func seekStage(to positionMilliseconds: Int64) -> (@MainActor () async -> Void)? {
        let before = currentReading()?.sample.positionMilliseconds ?? sample?.positionMilliseconds
        guard moveEngine(to: positionMilliseconds), let session, let before, let generation else { return nil }
        let sessionID = session.id, target = Int32(truncatingIfNeeded: positionMilliseconds)
        let wants = wantsPlayback, now = clock()
        return {
            // A failure before it retired this playback: as a seek arriving then, it records nothing.
            guard self.generation == generation else { return }
            if let rebased = try? await self.stored(.recordSeekIntent(sessionID: sessionID, from: before, to: target,
                                                                      wantsPlayback: wants, now: now), {
                try await self.store.recordSeekIntent(sessionID: sessionID, from: before, to: target, wantsPlayback: wants, now: now)
            }), self.generation == generation, self.session?.id == rebased.id { self.session = rebased }
        }
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

    /// A skip that seeks moves the engine at once (see `seek`); one past the end completes the episode in its turn.
    public func skipInterval(seconds: Int32, direction: PlaybackIntervalDirection? = nil) async throws {
        interactionRevision &+= 1
        try await admitStaged(stage: { self.skipIntervalStage(seconds: seconds, direction: direction) }, fallback: {
            try await self.skipCurrentInterval(seconds: seconds, direction: direction)
        }).value
    }

    private func skipIntervalStage(seconds: Int32, direction: PlaybackIntervalDirection?) -> Stage {
        guard generation != nil, let sample = currentReading()?.sample ?? self.sample else { return .persist(nil) }
        switch PlaybackTiming.intervalSkip(positionMilliseconds: sample.positionMilliseconds,
            durationMilliseconds: sample.durationMilliseconds, seconds: seconds, direction: direction) {
        case .complete: return .opaque
        case .seek(let target): return .persist(seekStage(to: target))
        }
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
        onceAdmittedEpisodeID = nil
        phase = episode == nil ? .idle : .stopped
        publish(.stateChanged)
    }

    public func resetPlaybackPosition(episodeID: Int64) async throws {
        interactionRevision &+= 1
        try await enqueue {
            try await self.stored(.resetPlaybackPosition(episodeID: episodeID)) {
                try await self.store.resetPlaybackPosition(episodeID: episodeID)
            }
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
            self.onceAdmittedEpisodeID = nil
            self.phase = .idle
            self.engine.unload()
            try self.speedPreferences?.clearCurrent()
        }.value
    }

    public func deleteDownloadedMedia(episodeID: Int64, deleteRemovesFromQueue: Bool = false) async throws {
        interactionRevision &+= 1
        try await enqueue {
            try await self.stored(.requestMediaDeletion(episodeID: episodeID)) {
                try await self.store.requestMediaDeletion(episodeID: episodeID, deleteRemovesFromQueue: deleteRemovesFromQueue)
            }
            defer { self.publish(.libraryChanged); self.publish(.stateChanged) }
            guard self.episode?.id == episodeID || self.session?.episodeID == episodeID else { return }
            self.generation = nil
            self.commandID = nil
            self.session = nil
            self.episode = nil
            self.sample = nil
            self.wantsPlayback = false
            self.streamingPolicy = StreamingAdmissionPolicy()
            self.onceAdmittedEpisodeID = nil
            self.phase = .idle
            self.engine.unload()
            try self.speedPreferences?.clearCurrent()
        }.value
    }

    public func deleteDownloadedMedia(target: EpisodeMediaDeletionTarget,
        deleteRemovesFromQueue: Bool = false) async throws -> EpisodeMediaDeletionOutcome {
        var outcome = EpisodeMediaDeletionOutcome.stale
        try await enqueue {
            outcome = try await self.stored(.requestMediaDeletion(episodeID: target.episodeID)) {
                try await self.store.requestMediaDeletion(target: target, deleteRemovesFromQueue: deleteRemovesFromQueue)
            }
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
        streamingPolicy = StreamingAdmissionPolicy(); onceAdmittedEpisodeID = nil; phase = .idle
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

    /// Every command and engine event runs in admission order, one after another, so every store call keeps that
    /// order. Only engine stages (`admitStaged`) may run before their turn.
    private func admit(entry: Admission = Admission(),
                       _ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let previous = tail
        sequence &+= 1
        let sequence = sequence
        admitted.append(entry)
        let task = Task { @MainActor in
            _ = try? await previous?.value
            self.running = entry
            defer {
                self.running = nil
                self.admitted.removeAll { $0 === entry }
                if self.sequence == sequence { self.tail = nil }
                self.advanceEngineStages()
            }
            try await operation()
        }
        tail = task
        return task
    }

    /// A pause, a seek or a position or state event: its engine stage runs as soon as everything admitted before it
    /// is residual (only captured store writes left), at admission or when an earlier admission becomes residual,
    /// never before an earlier engine stage or past an unfinished command. Its own store write waits for its turn, and
    /// `fallback` runs the whole command then when its stage is opaque. An engine event never runs a stage inside the
    /// engine's callback: its stage runs on the next main-actor turn at the earliest.
    private func admitStaged(startsPlayback: Bool = false, event: Bool = false,
                             stage: @escaping @MainActor () -> Stage,
                             fallback: @escaping @MainActor () async throws -> Void,
                             finished: (@MainActor () -> Void)? = nil) -> Task<Void, any Error> {
        guard !isRetired else { finished?(); return Task { throw CancellationError() } }
        if startsPlayback { playRequests += 1; onPlaybackRequested?() }
        let entry = Admission()
        entry.stage = stage
        let task = admit(entry: entry) {
            defer { if startsPlayback { self.playRequests -= 1 }; finished?() }
            guard let stage = entry.stage else { try await entry.persistence?(); return }
            entry.stage = nil
            let staging = self.stagingEngine
            self.stagingEngine = true
            let outcome = stage()
            self.stagingEngine = staging
            guard case .persist(let persistence) = outcome else { try await fallback(); return }
            self.becomeResidual()
            try await persistence?()
        }
        if event { Task { @MainActor [weak self] in self?.advanceEngineStages() } } else { advanceEngineStages() }
        return task
    }

    /// Tests: commands and engine events admitted and not finished, and how many engine stages among them wait.
    var admissionsForTesting: (admitted: Int, stagesWaiting: Int) {
        (admitted.count, admitted.filter { $0.stage != nil }.count)
    }

    /// The running command has only captured store writes left (then their results and publishing).
    private func becomeResidual() {
        running?.residual = true
        advanceEngineStages()
    }

    /// Runs, in admission order, the engine stages whose every earlier admission is residual.
    private func advanceEngineStages() {
        guard hoistsEngineStages, !stagingEngine else { return }
        stagingEngine = true
        defer { stagingEngine = false }
        var index = 0
        while index < admitted.count {
            let entry = admitted[index]
            if !entry.residual {
                guard let stage = entry.stage, case .persist(let persistence) = stage() else { return }
                entry.stage = nil
                entry.persistence = persistence
                entry.residual = true
            }
            index += 1
        }
    }

    /// A store write of the coordinator (`storeGate` sees it first in tests).
    private func stored<T>(_ call: @autoclosure () -> PlaybackStoreCall, _ write: () async throws -> T) async throws -> T {
#if DEBUG
        if let storeGate { try await storeGate(call()) }
#endif
        return try await write()
    }

    private func load(_ id: Int64, play: Bool, fromQueue: Bool, adoption: ExternalAdoption? = nil,
                      startPosition: Int64? = nil, route: RouteActivation? = nil) async throws {
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
        if let route { guard route.isCurrent() else { throw CancellationError() } }
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
        // A person's command that came while the current item settled wins before anything is retired: a seek or an
        // interval skip queued behind this load still finds its item loaded.
        if let route { guard route.isCurrent() else { throw CancellationError() } }
        adoption?.didRetire(); route?.didRetire()
        generation = nil
        if let adoption {
            guard adoption.isCurrent() else { throw CancellationError() }
            try adoption.activate()
        } else {
            engine.unload()
            if let route {
                guard route.isCurrent() else { throw CancellationError() }
                try route.activate()
            }
        }
        streamingPolicy.willLoadEpisode()
        onceAdmittedEpisodeID = nil
        confirmationPosition = nil
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
        if let access {
            let once = streamingPolicy.allowStreamingThisTime
            if case .confirm(let pendingID) = streamingPolicy.loadedMedia(.init(id: id, needsStreaming: access.needsStreaming),
                    streamingAllowed: access.streamingAllowed, isCasting: access.isCasting) {
                showStreamingConfirmation(pendingID)
                return
            }
            if once { onceAdmittedEpisodeID = id }
        }
        let intro = PlaybackTiming.introSkip(positionMilliseconds: next.userState.positionMilliseconds,
                                             durationMilliseconds: next.details.media?.durationMilliseconds ?? 0,
                                             preferences: feedSkip ?? prefs.skip)
        let external = try adoption?.state()
        let position = external.map { Int64($0.sample.positionMilliseconds) } ?? startPosition.map { max(0, $0) }
            ?? (fromQueue ? intro.positionMilliseconds : Int64(PlaybackTiming.positionAfterPause(
            positionMilliseconds: Int32(truncatingIfNeeded: intro.positionMilliseconds),
            lastPlayedMilliseconds: lastPlayedHere(next), nowMilliseconds: milliseconds())))
        let baseline = fromQueue ? next.userState.positionMilliseconds : Int32(truncatingIfNeeded: position)
        do {
            if let retainedSession { session = retainedSession }
            else {
                session = try await stored(.beginPlayback(episodeID: id, positionMilliseconds: baseline)) {
                    try await store.beginPlayback(episodeID: id, positionMilliseconds: baseline, enqueueLocation: prefs.enqueueLocation)
                }
            }
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

    /// `residual`: the command does nothing after this, so once the engine plays, a pause or seek admitted after it
    /// moves the engine without waiting for the recording below.
    private func resume(residual: Bool = false) async throws {
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
        if phase != .preparing { try autoEnableSleepTimer() }
        publish(.stateChanged)
        // Intentional play on a prepared engine (PROTOCOL §8): after the engine command, a server library starts the
        // load's sync session or records the resume's claim. Never fails playback; a preparing engine records at .ready.
        if let intent, let session, let generation {
            let sessionID = session.id
            if residual { becomeResidual() }
            _ = try? await stored(.recordPlaybackIntent(sessionID: sessionID, positionMilliseconds: intent.position,
                                                        durationMilliseconds: intent.duration, intentional: true, now: intent.time)) {
                try await store.recordPlaybackIntent(sessionID: sessionID, positionMilliseconds: intent.position,
                                                     durationMilliseconds: intent.duration, baseline: generation,
                                                     intentional: true, now: intent.time)
            }
        }
    }

    private func showStreamingConfirmation(_ id: Int64, positionMilliseconds: Int64? = nil) {
        // Keep saved/displayed episode metadata, but retire all callbacks and stop
        // remote playback. The pending ID owns direct Play until another selection.
        generation = nil
        commandID = nil
        engine.unload()
        onceAdmittedEpisodeID = nil
        wantsPlayback = false
        phase = .awaitingStreamingConfirmation
        confirmationPosition = positionMilliseconds.map { (id, $0) }
        if let episode {
            sample = .init(positionMilliseconds: positionMilliseconds.map { Int32(clamping: $0) } ?? episode.userState.positionMilliseconds,
                           durationMilliseconds: episode.details.media?.durationMilliseconds ?? 0, status: .paused)
        }
        publish(.streamingConfirmationRequired(episodeID: id))
        publish(.stateChanged)
    }

    private func pauseCurrent() async throws {
        try await pauseStage()?()
    }

    /// A pause's engine stage: the engine pauses and the player shows paused now; the returned save (nil: none)
    /// writes the paused sample captured here.
    private func pauseStage() -> (@MainActor () async throws -> Void)? {
        wantsPlayback = false
        guard generation != nil else { return nil }
        let preparing = phase == .preparing
        engine.pause(commandID: nextCommand())
        var save: SaveCapture?
        if !preparing {
            if let reading = currentReading() { sample = reading.sample }
            sample?.status = .paused
            save = captureSave(synchronize: episode.map { preferences($0).end.synchronize } ?? false)
            phase = .paused
        }
        publish(.stateChanged)
        return persistence(of: save)
    }

    private func persistence(of save: SaveCapture?) -> (@MainActor () async throws -> Void)? {
        guard let save else { return nil }
        return { try await self.persist(save) }
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
        guard let capture = captureSave(synchronize: synchronize, at: timestamp) else { return }
        try await persist(capture)
    }

    private func captureSave(synchronize: Bool = false, at timestamp: Date? = nil) -> SaveCapture? {
        guard let session, let sample else { return nil }
        return .init(sessionID: session.id, generation: generation, sample: sample, now: timestamp ?? clock(),
                     synchronize: synchronize)
    }

    /// Whether the playback that captured `save` is still the current one.
    private func owns(_ save: SaveCapture) -> Bool { generation == save.generation && session?.id == save.sessionID }

    /// Writes a captured save in its turn. After a failure before it retired that playback nothing is written, as a
    /// command arriving then would not have saved. Its result applies only to the playback that captured it; its
    /// failure fails that playback here, in its turn, showing the sample it failed to save (a later pause or seek
    /// already moved the engine, which the failure stops), and is dropped for any other.
    private func persist(_ save: SaveCapture) async throws {
        guard generation == save.generation else { return }
        let saved: LibraryEpisode
        do {
            guard let result = try await stored(.recordPlayback(sessionID: save.sessionID, sample: save.sample, now: save.now,
                                                                synchronize: save.synchronize), {
                try await store.recordPlayback(sessionID: save.sessionID, sample: save.sample, now: save.now,
                                               synchronize: save.synchronize)
            }) else { throw FeedLibraryError.invalidMutation }
            saved = result
        } catch {
            guard owns(save) else { return }
            sample = save.sample
            storageFailure()
            throw error
        }
        if owns(save) { episode = saved }
        // DBWriter.setFeedMediaPlaybackInformation does not publish FeedItemEvent.
        // Distinguish periodic position writes from queue/item changes for screen refreshes.
        publish(.positionSaved)
    }

    private func storageFailure() {
        guard phase != .failed || generation != nil else { return }
        engine.pause(commandID: nextCommand())
        generation = nil
        engine.unload()
        onceAdmittedEpisodeID = nil
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
            let now = timestamp ?? clock()
            guard let ended = try await stored(.endPlayback(sessionID: session.id, reason: reason, now: now), {
                try await store.endPlayback(sessionID: session.id, reason: reason, preferences: prefs.end, now: now,
                                            continueQueue: continueQueue)
            }) else {
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
        onceAdmittedEpisodeID = nil
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
    private func handle(_ event: PlaybackEngineEvent, receivedAt: Date, monotonic: Int64, route: UUID?) async throws {
        if case .failed(let token, let message) = event {
            guard token == generation else { return }
            try await pauseCurrent()
            generation = nil
            engine.unload()
            onceAdmittedEpisodeID = nil
            phase = .failed
            publish(.engineFailed(message))
            publish(.stateChanged)
            return
        }
        if case .streamingConfirmationRequired(let token) = event {
            // The route fetches through the phone (a Cast relay) and the network does not admit streaming for this
            // episode; nothing reached the route. Pause as a failure would, then ask Once/Always as a refused load
            // does, resuming where the route was asked to start.
            guard token == generation, (engine as? RoutedPlaybackEngine)?.routeID == route, let episode else { return }
            let resumeAt = engine.reading.flatMap { $0.generation == token ? Int64($0.sample.positionMilliseconds) : nil }
            try await pauseCurrent()
            guard token == generation, (engine as? RoutedPlaybackEngine)?.routeID == route,
                  case .confirm(let id) = streamingPolicy.requireConfirmation(mediaID: episode.id) else { return }
            showStreamingConfirmation(id, positionMilliseconds: resumeAt)
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
            onceAdmittedEpisodeID = nil
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
            guard let saved = try await stored(.timelineReset(sessionID: session.id, sample: settled, now: receivedAt), {
                try await store.recordPlaybackTimelineReset(sessionID: session.id, finalSample: settled, now: receivedAt)
            }) else { throw FeedLibraryError.invalidMutation }
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
        if case .position = event {
            try await handleInTurn(event, receivedAt: receivedAt, monotonic: monotonic); return
        }
        if case .stateChanged = event {
            try await handleInTurn(event, receivedAt: receivedAt, monotonic: monotonic); return
        }
        var reading: PlaybackEngineReading
        switch event {
        case .ready(let value), .ended(let value): reading = value
        case .stateChanged, .position, .failed, .timelineReset, .mediaServicesReset, .streamingConfirmationRequired: return
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
                let position = reading.sample.positionMilliseconds, location = preferences(episode).enqueueLocation
                self.session = try await stored(.beginPlayback(episodeID: episode.id, positionMilliseconds: position)) {
                    try await store.beginPlayback(episodeID: episode.id, positionMilliseconds: position, enqueueLocation: location)
                }
            }
            sample = reading.sample
            wantsPlayback = reading.sample.status == .playing
            if wantsPlayback {
                phase = reading.buffering ? .buffering : .playing
                lastSaveMilliseconds = monotonic
                // The sleep timer's automatic start writes nothing, so it comes before the writes below, which a pause
                // or seek admitted meanwhile does not wait for. Its failure still fails playback after them.
                var timerFailure: (any Error)?
                do { try autoEnableSleepTimer() } catch { timerFailure = error }
                let intentional = !externalPreparation
                externalPreparation = false
                let save = captureSave(at: receivedAt)
                let sessionID = session?.id, generation = generation, started = reading.sample
                publish(.stateChanged)
                becomeResidual()
                // Playback starts (PROTOCOL §8): a server library starts the load's sync session. A Cast receiver's
                // restored state is no press of play: listening this phone did not start is not recorded until a Play
                // here. Never fails playback.
                if let sessionID, let generation {
                    _ = try? await stored(.recordPlaybackIntent(sessionID: sessionID, positionMilliseconds: started.positionMilliseconds,
                                                                durationMilliseconds: started.durationMilliseconds,
                                                                intentional: intentional, now: receivedAt)) {
                        try await store.recordPlaybackIntent(sessionID: sessionID, positionMilliseconds: started.positionMilliseconds,
                                                             durationMilliseconds: started.durationMilliseconds, baseline: generation,
                                                             intentional: intentional, now: receivedAt)
                    }
                }
                if let save { try await persist(save) }
                if let timerFailure, self.generation == generation { sample = started; throw timerFailure }
                return
            } else {
                phase = .paused
                if externalPreparation { try await save(at: receivedAt) }
            }
            externalPreparation = false
        case .ended:
            guard phase != .preparing else { return }
            sample = reading.sample
            try await finish(.ended, finalSample: reading.sample, at: receivedAt)
        case .stateChanged, .position, .failed, .timelineReset, .mediaServicesReset, .streamingConfirmationRequired: return
        }
        publish(.stateChanged)
    }

    /// A position or state event in its turn: its engine stage, then its save.
    private func handleInTurn(_ event: PlaybackEngineEvent, receivedAt: Date, monotonic: Int64) async throws {
        switch eventStage(event, receivedAt: receivedAt, monotonic: monotonic) {
        case .persist(let persistence): try await persistence?()
        case .opaque: if case .position(let reading) = event { try await expiringTick(reading, monotonic: monotonic) }
        }
    }

    /// The engine stage of a position or state event: what it shows and commands, its save captured (written in its
    /// turn). `opaque` for a position whose sleep-timer tick expires the timer: that pause and save wait for its turn.
    private func eventStage(_ event: PlaybackEngineEvent, receivedAt: Date, monotonic: Int64) -> Stage {
        let reading: PlaybackEngineReading
        switch event {
        case .stateChanged(let value), .position(let value): reading = value
        case .ready, .ended, .failed, .timelineReset, .mediaServicesReset, .streamingConfirmationRequired: return .opaque
        }
        guard reading.generation == generation, reading.commandID == commandID else { return .persist(nil) }
        if case .position = event, phase == .playing || phase == .buffering, var timer = sleepTimer,
           reading.sample.durationMilliseconds > 0 || timer.mode == .minutes,
           Self.expires(tick(&timer, reading, monotonic: monotonic)) { return .opaque }
        speed = reading.speed
        skipSilence = reading.skipSilence
        var save: SaveCapture?
        if case .stateChanged = event {
            if phase == .preparing {
                wantsPlayback = reading.sample.status == .playing
                publish(.stateChanged)
                return .persist(nil)
            }
            let wasBuffering = phase == .buffering
            let wasPlaying = phase == .playing || phase == .buffering
            sample = reading.sample
            wantsPlayback = reading.sample.status == .playing
            phase = wantsPlayback ? (reading.buffering ? .buffering : .playing) : .paused
            if wantsPlayback && !wasPlaying { lastSaveMilliseconds = monotonic }
            if !wantsPlayback && wasPlaying {
                save = captureSave(synchronize: episode.map { preferences($0).end.synchronize } ?? false, at: receivedAt)
            }
            if wantsPlayback && wasBuffering && !reading.buffering { save = captureSave(at: receivedAt) }
            if wantsPlayback && !wasPlaying {
                do { try autoEnableSleepTimer() } catch { storageFailure(); return .persist(nil) }
            }
        } else {
            guard phase == .playing || phase == .buffering else { return .persist(nil) }
            let hasDuration = reading.sample.durationMilliseconds > 0
            if hasDuration {
                sample = reading.sample
                publishPosition(generation: reading.generation, commandID: reading.commandID)
            }
            // A clock timer measures listening time even for live media. Unknown
            // duration still cannot supply episode-mode fade/display/save facts.
            if var timer = sleepTimer, hasDuration || timer.mode == .minutes {
                let events = tick(&timer, reading, monotonic: monotonic)
                sleepTimer = timer
                do { _ = try applySleepTimerEvents(events) } catch { storageFailure(); return .persist(nil) }
                if !wantsPlayback { publish(.stateChanged); return .persist(nil) }
            }
            guard hasDuration else { onUnknownDurationTick?(); return .persist(nil) }
            if monotonic &- lastSaveMilliseconds >= 5_000 { save = captureSave(at: receivedAt); lastSaveMilliseconds = monotonic }
            // The ending skip moves the engine before the save is written; the save keeps the sample captured above.
            if let episode {
                let skip = loadedSkipPreferences ?? preferences(episode).skip
                if PlaybackTiming.shouldSkipEnding(positionMilliseconds: Int64(reading.sample.positionMilliseconds),
                                                    durationMilliseconds: Int64(reading.sample.durationMilliseconds),
                                                    speed: reading.speed, preferences: skip) {
                    engine.seek(to: Int64(reading.sample.durationMilliseconds), commandID: nextCommand())
                    publish(.endingSkipped(seconds: skip.endingSeconds))
                }
            }
            // Its state notice follows its save, as before (what it shows was published above).
            if let save { return .persist({ try await self.persist(save); self.publish(.stateChanged) }) }
        }
        publish(.stateChanged)
        return .persist(persistence(of: save))
    }

    private func tick(_ timer: inout SleepTimer, _ reading: PlaybackEngineReading, monotonic: Int64) -> [SleepTimerEvent] {
        let settings = sleepTimerPreferences?.value ?? .init()
        return timer.tick(nowMilliseconds: monotonic, positionMilliseconds: Int64(reading.sample.positionMilliseconds),
                          durationMilliseconds: Int64(reading.sample.durationMilliseconds),
                          vibrate: settings.vibrate, shakeToReset: settings.shakeToReset)
    }

    /// A position whose tick expires the sleep timer, in its turn: the faded audio pauses and saves.
    private func expiringTick(_ reading: PlaybackEngineReading, monotonic: Int64) async throws {
        speed = reading.speed
        skipSilence = reading.skipSilence
        guard phase == .playing || phase == .buffering, var timer = sleepTimer else { return }
        if reading.sample.durationMilliseconds > 0 {
            sample = reading.sample
            publishPosition(generation: reading.generation, commandID: reading.commandID)
        }
        let events = tick(&timer, reading, monotonic: monotonic)
        sleepTimer = timer
        try await deliverSleepTimerEvents(events)
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
        case .failed, .streamingConfirmationRequired: nil
        }
    }
}

/// A Picture in Picture seek's cancellation, set from any thread, read when its engine stage runs.
final class PictureSeekCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Counts playback an engine started by itself, from any thread (the store's adoption transaction reads it).
final class PlaybackResumptionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var count: UInt64 { lock.withLock { value } }
    func advance() { lock.withLock { value &+= 1 } }
}

/// A store write the coordinator makes, with the values it passes (tests trace and hold them, `storeGate`).
enum PlaybackStoreCall: Equatable, Sendable {
    case beginPlayback(episodeID: Int64, positionMilliseconds: Int32?)
    case recordPlayback(sessionID: UUID, sample: PlaybackSample, now: Date, synchronize: Bool)
    case recordPlaybackIntent(sessionID: UUID, positionMilliseconds: Int32, durationMilliseconds: Int32, intentional: Bool, now: Date)
    case recordSeekIntent(sessionID: UUID, from: Int32, to: Int32, wantsPlayback: Bool, now: Date)
    case timelineReset(sessionID: UUID, sample: PlaybackSample, now: Date)
    case endPlayback(sessionID: UUID, reason: PlaybackEndReason, now: Date)
    case resetPlaybackPosition(episodeID: Int64)
    case requestMediaDeletion(episodeID: Int64)
}

import Foundation
import AVFoundation

/// One coordinator-facing engine across local and Cast sessions. Route changes
/// keep the episode generation and statistics session; each backend load gets a
/// fresh identity so retired callbacks cannot mutate the replacement route.
@MainActor public final class RoutedPlaybackEngine: PlaybackSilenceControlling, PlaybackVolumeControlling,
    PlaybackSilencePreferenceRetaining, PlaybackStatisticsConsumer, PlaybackExternalStateAdopting, PlaybackVideoPresenting,
    PlaybackInterruptionReporting, PlaybackSessionReserving {
    public var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    public var isRemote: Bool { remote != nil }
    public var resumesAfterInterruption: Bool {
        !isRemote && (local as? any PlaybackInterruptionReporting)?.resumesAfterInterruption == true
    }
    /// Changes on each backend route/load, but not an ordinary seek on that route.
    public var routeID: UUID? { backendGeneration }
    private var localPresentation: (any PlaybackVideoPresenting)? {
        guard generation != nil, backendGeneration != nil, !isRemote else { return nil }
        return local as? any PlaybackVideoPresenting
    }
    public var videoDisplayLayer: AVSampleBufferDisplayLayer? { localPresentation?.videoDisplayLayer }
    public var videoPictureInPicture: PlaybackVideoPictureInPicture? { localPresentation?.videoPictureInPicture }
    public var mediaPresentationID: UUID? { localPresentation?.mediaPresentationID }
    public var mediaTracks: [PlaybackMediaTrack] { localPresentation?.mediaTracks ?? [] }
    public var selectedAudioTrackID: Int32? { localPresentation?.selectedAudioTrackID }
    public var selectedVideoTrackID: Int32? { localPresentation?.selectedVideoTrackID }
    public func selectAudioTrack(id: Int32, commandID: UUID) throws {
        guard generation != nil, let localPresentation else { throw PlaybackTrackSelectionError.unsupported }
        let previous = (self.commandID, backendCommandID)
        self.commandID = commandID; backendCommandID = commandID
        do { try localPresentation.selectAudioTrack(id: id, commandID: commandID) }
        catch { (self.commandID, backendCommandID) = previous; throw error }
    }
    public var requiresExplicitReload: Bool {
        (selected as? any PlaybackExternalStateAdopting)?.requiresExplicitReload == true
    }
    public var supportsSkipSilence: Bool {
        !isRemote && (local as? any PlaybackSilenceControlling)?.supportsSkipSilence == true
    }
    public var retainsSkipSilencePreference: Bool {
        isRemote || (local as? any PlaybackSilencePreferenceRetaining)?.retainsSkipSilencePreference == true
    }
    public var reading: PlaybackEngineReading? {
        guard let generation, let commandID else { return nil }
        if let value = selected.reading, value.generation == backendGeneration {
            let value = translated(value)
            if value.commandID == commandID { return value }
        }
        return .init(generation: generation, commandID: commandID,
                     sample: .init(positionMilliseconds: position, durationMilliseconds: duration,
                                   status: wantsPlayback ? .playing : .paused),
                     buffering: wantsPlayback && !backendPrepared, speed: speed,
                     skipSilence: silence, isPrepared: backendPrepared)
    }

    private let local: any PlaybackEngine
    private var remote: (any PlaybackEngine)?
    private var selected: any PlaybackEngine { remote ?? local }
    private var episode: LibraryEpisode?
    private var generation: UUID?
    private var backendGeneration: UUID?
    private var commandID: UUID?
    private var backendCommandID: UUID?
    private var position: Int32 = 0
    private var duration: Int32 = 0
    private var speed: Float = 1
    private var silence = false
    private var volume: FeedVolumeAdaptation = .off
    private var timerVolume: Float = 1
    private var wantsPlayback = false
    private var backendPrepared = false
    private var reportedReady = false
    private var configuring = false
    private var configurationFailure: String?
    private var statistics: (@MainActor (UUID) -> Int64, @MainActor (UUID) async throws -> Void)?
    /// The local route holds a session reserved for the next item. Only a local load consumes it; giving
    /// the route to a remote withdraws it.
    private var localReservation = false

    public init(local: any PlaybackEngine) { self.local = local }
    isolated deinit { unload() }

    /// Call synchronously at session ending, while the remote engine still has
    /// its last media/position reading. A nil destination returns to local.
    public func setRemote(_ destination: (any PlaybackEngine)?) {
        guard destination !== remote else { return }
        precondition(destination !== local, "The remote route must use a distinct engine")
        let outgoing = selected
        captureCurrentReading()
        retire(outgoing)
        remote = destination
        if destination != nil { withdrawLocalReservation() }
        guard episode != nil else { return }
        prepareSelected()
    }

    /// Accounting has already settled the outgoing selection. Install a receiver
    /// for adoption without loading that outgoing selection on the destination.
    public func setRemoteForAdoption(_ destination: any PlaybackExternalStateAdopting) {
        unload()
        remote = destination
        withdrawLocalReservation()
    }

    public func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        unload()
        self.episode = episode; self.generation = generation; commandID = generation
        position = Int32(clamping: max(0, positionMilliseconds))
        duration = episode.details.media?.durationMilliseconds ?? 0
        prepareSelected()
    }

    public func adopt(episode: LibraryEpisode, generation: UUID, state: PlaybackExternalState) throws {
        guard selected is any PlaybackExternalStateAdopting else { throw FeedLibraryError.invalidMutation }
        if self.generation != nil { unload() }
        self.episode = episode; self.generation = generation; commandID = generation
        position = state.sample.positionMilliseconds; duration = state.sample.durationMilliseconds
        wantsPlayback = state.sample.status == .playing; speed = state.speed
        prepareSelected(adopting: state)
    }

    private func prepareSelected(adopting external: PlaybackExternalState? = nil) {
        guard let episode, let generation, let commandID else { return }
        let backend = selected
        // A local load takes over a reserved local session; any other load leaves it to be released.
        if !isRemote && external == nil { localReservation = false } else { withdrawLocalReservation() }
        let token = UUID()
        backendGeneration = token; backendPrepared = false
        backendCommandID = commandID
        configuring = true; configurationFailure = nil
        backend.onEvent = { [weak self] event in
            guard let self, self.backendGeneration == token else { return }
            self.receive(event)
        }
        if let statistics {
            (backend as? any PlaybackStatisticsConsumer)?.bindStatistics(lastPlayed: { [weak self] id in
                guard self?.backendGeneration == id else { return 0 }
                return statistics.0(generation)
            }, synchronize: { [weak self] id in
                guard self?.backendGeneration == id else { throw FeedLibraryError.invalidMutation }
                try await statistics.1(generation)
            })
        }
        do {
            if let external, let adopting = backend as? any PlaybackExternalStateAdopting {
                try adopting.adopt(episode: episode, generation: token, state: external)
            } else {
                backend.load(episode: episode, generation: token, positionMilliseconds: Int64(position))
                try backend.setSpeed(speed, commandID: commandID)
                try setVolumeAdaptation(volume)
                try setSleepTimerVolume(timerVolume)
                if !isRemote { (backend as? any PlaybackSilenceControlling)?.setSkipSilence(silence, commandID: commandID) }
                if wantsPlayback { backend.play(commandID: commandID) }
                else { backend.pause(commandID: commandID) }
            }
        } catch { configurationFailure = error.localizedDescription }
        configuring = false
        if let failure = configurationFailure {
            onEvent?(.failed(generation: generation, message: failure))
        } else if let reading {
            if backendPrepared { publishReady(reading) }
            else { onEvent?(.stateChanged(reading)) }
        }
    }

    public func play(commandID: UUID) {
        self.commandID = commandID; backendCommandID = commandID; wantsPlayback = true
        guard generation != nil else { return }
        selected.play(commandID: commandID)
    }
    public func pause(commandID: UUID) {
        self.commandID = commandID; backendCommandID = commandID; wantsPlayback = false
        guard generation != nil else { return }
        selected.pause(commandID: commandID)
    }
    public func seek(to positionMilliseconds: Int64, commandID: UUID) {
        self.commandID = commandID; backendCommandID = commandID
        position = Int32(clamping: max(0, positionMilliseconds))
        guard generation != nil else { return }
        selected.seek(to: Int64(position), commandID: commandID)
    }
    public func setSpeed(_ speed: Float, commandID: UUID) throws {
        guard speed.isFinite, speed > 0 else { throw PlaybackSpeedError.invalidSpeed }
        let old = (self.speed, self.commandID, backendCommandID)
        self.speed = speed; self.commandID = commandID; backendCommandID = commandID
        do { if generation != nil { try selected.setSpeed(speed, commandID: commandID) } }
        catch { (self.speed, self.commandID, backendCommandID) = old; throw error }
    }
    public func setSkipSilence(_ enabled: Bool, commandID: UUID) {
        silence = enabled; self.commandID = commandID
        guard generation != nil else { return }
        if !isRemote {
            backendCommandID = commandID
            (selected as? any PlaybackSilenceControlling)?.setSkipSilence(enabled, commandID: commandID)
        }
        // No receiver command is sent for a local-only processing preference.
        // Future readings for its unchanged command map to the new owner token.
        else {
            if let reading { onEvent?(.stateChanged(reading)) }
        }
    }
    public func setVolumeAdaptation(_ setting: FeedVolumeAdaptation) throws {
        if generation != nil {
            guard let backend = selected as? any PlaybackVolumeControlling else {
                if setting != .off { throw PlaybackVolumeError.unsupportedEngine }; return
            }
            try backend.setVolumeAdaptation(setting)
        }
        volume = setting
    }
    public func setSleepTimerVolume(_ value: Float) throws {
        if generation != nil {
            guard let backend = selected as? any PlaybackVolumeControlling else {
                if value != 1 { throw PlaybackVolumeError.unsupportedEngine }; return
            }
            try backend.setSleepTimerVolume(value)
        }
        timerVolume = value
    }

    private func captureCurrentReading() {
        guard let reading else { return }
        position = reading.sample.positionMilliseconds; duration = reading.sample.durationMilliseconds
        wantsPlayback = reading.sample.status == .playing; speed = reading.speed
    }
    private func retire(_ backend: any PlaybackEngine) {
        backendGeneration = nil; backendPrepared = false
        backend.onEvent = nil; backend.unload()
    }
    /// The local route keeps its audio session across an item replacement; a remote route has none here.
    public func reserveSessionForNextItem() {
        guard !isRemote, let local = local as? any PlaybackSessionReserving else { return }
        localReservation = true
        local.reserveSessionForNextItem()
    }
    public func cancelSessionReservation() { withdrawLocalReservation() }
    private func withdrawLocalReservation() {
        guard localReservation else { return }
        localReservation = false
        (local as? any PlaybackSessionReserving)?.cancelSessionReservation()
    }
    public func unload() {
        retire(selected)
        episode = nil; generation = nil; commandID = nil; backendCommandID = nil
        position = 0; duration = 0; speed = 1; silence = false
        volume = .off; timerVolume = 1; wantsPlayback = false; reportedReady = false
    }
    func bindStatistics(lastPlayed: @escaping @MainActor (UUID) -> Int64,
                        synchronize: @escaping @MainActor (UUID) async throws -> Void) {
        statistics = (lastPlayed, synchronize)
    }
    private func translated(_ value: PlaybackEngineReading) -> PlaybackEngineReading {
        var value = value
        if value.commandID == backendCommandID, let commandID { value.commandID = commandID }
        else if value.commandID == backendGeneration, let generation { value.commandID = generation }
        value.generation = generation ?? value.generation
        if isRemote { value.skipSilence = silence }
        return value
    }
    private func publishReady(_ reading: PlaybackEngineReading) {
        if reportedReady { onEvent?(.stateChanged(reading)) }
        else { reportedReady = true; onEvent?(.ready(reading)) }
    }
    private func receive(_ event: PlaybackEngineEvent) {
        guard let generation else { return }
        if case .failed(let id, let message) = event {
            guard id == backendGeneration else { return }
            if configuring { configurationFailure = message }
            else { onEvent?(.failed(generation: generation, message: message)) }
            return
        }
        if case .streamingConfirmationRequired(let id) = event {
            guard id == backendGeneration else { return }
            onEvent?(.streamingConfirmationRequired(generation: generation))
            return
        }
        let raw: PlaybackEngineReading
        switch event {
        case .ready(let value), .stateChanged(let value), .position(let value), .timelineReset(let value), .ended(let value),
             .mediaServicesReset(let value): raw = value
        case .failed, .streamingConfirmationRequired: return
        }
        guard raw.generation == backendGeneration else { return }
        if case .ready = event { backendPrepared = raw.isPrepared }
        guard !configuring else { return }
        let value = translated(raw)
        if value.commandID == commandID {
            position = value.sample.positionMilliseconds; duration = value.sample.durationMilliseconds
            speed = value.speed; wantsPlayback = value.sample.status == .playing
        }
        switch event {
        case .ready: publishReady(value)
        case .stateChanged: onEvent?(.stateChanged(value))
        case .position: onEvent?(.position(value))
        case .timelineReset: onEvent?(.timelineReset(value))
        case .ended: onEvent?(.ended(value))
        case .mediaServicesReset: onEvent?(.mediaServicesReset(value))
        case .failed, .streamingConfirmationRequired: break
        }
    }
}

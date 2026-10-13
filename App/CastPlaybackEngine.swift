import Foundation
import NotTennaPodCore
import GoogleCast

/// The source owner must provide an authorized receiver URL and keep any relay
/// alive until close. There is deliberately no direct-origin fallback here.
@MainActor final class CastPlaybackMedia {
    let item: CastMediaItemCodec.Item
    private var release: (@MainActor () -> Void)?
    init(item: CastMediaItemCodec.Item, release: @escaping @MainActor () -> Void = {}) {
        self.item = item; self.release = release
    }
    func close() { let action = release; release = nil; action?() }
    isolated deinit { close() }
}

@MainActor final class CastPlaybackEngine: PlaybackEngine, PlaybackVolumeControlling, PlaybackExternalStateAdopting {
    typealias PrepareMedia = @MainActor (LibraryEpisode) async throws -> CastPlaybackMedia
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    private(set) var reading: PlaybackEngineReading?
    private var client: any CastMediaClient
    private let prepareMedia: PrepareMedia
    private let automaticallyPoll: Bool
    private var preparing: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var media: CastPlaybackMedia?
    private var adoptionMedia: CastPlaybackMedia?
    private var selectedEpisode: LibraryEpisode?
    private var foreignReceiver = false
    var requiresExplicitReload: Bool { foreignReceiver }
    private var adopted: (episode: LibraryEpisode, mediaID: String, loadID: String?, sessionID: Int)?
    private var generation: UUID?
    private var loadID: UUID?
    private var mediaSessionID: Int?
    private var receivedLoadResponse = false
    private var applyingLoadCommands = false
    private var ready = false, ended = false, failed = false, unloadedAtReceiver = false
    private var position: Int64 = 0
    private var playing = false
    private var speed: Float = 1
    private var adaptation: FeedVolumeAdaptation = .off
    private var timerVolume: Float = 1
    private enum Slot: Hashable { case load, playing, seek, speed, volume, status }
    private struct Pending {
        var id: UUID
        var request: (any CastRequestCancellation)?
    }
    private var pending: [Slot: Pending] = [:]
    private var suspended = false
    private var awaitingResumeStatus = false
    private var statusObserverID = UUID()
    private var deferred: Set<Slot> = []
    /// Session ownership must resolve a receiver item changed by another sender.
    /// Never reload the old episode over that item as a side effect of resuming.
    var onReceiverItemChanged: (@MainActor (any CastMediaClient, CastRemoteSnapshot) -> Void)?

    /// The tag this library's loads carry (`CastMediaItemCodec.libraryIDKey`): nil for the standalone library.
    /// Local IDs repeat across libraries, so a receiver item is this engine's only with the same tag.
    private let libraryTag: String?

    init(client: any CastMediaClient, automaticallyPoll: Bool = true, adoptionMedia: CastPlaybackMedia? = nil,
         library: LibraryReference = .standalone, prepareMedia: @escaping PrepareMedia) {
        self.client = client; self.automaticallyPoll = automaticallyPoll; self.prepareMedia = prepareMedia
        self.adoptionMedia = adoptionMedia; libraryTag = library.castLibraryID
    }
    isolated deinit { unload() }

    func adopt(episode: LibraryEpisode, generation: UUID, state: PlaybackExternalState) throws {
        guard let status = client.snapshot, Int64(status.mediaID ?? "") == episode.id, status.libraryID == libraryTag,
              status.mediaSessionID != 0,
              status.state != .idle, status.state != .unknown else { throw FeedLibraryError.invalidMutation }
        let lease = adoptionMedia; adoptionMedia = nil
        unload()
        media = lease
        selectedEpisode = episode
        self.generation = generation
        adopted = (episode, status.mediaID!, status.loadID, status.mediaSessionID); mediaSessionID = status.mediaSessionID
        receivedLoadResponse = true; ready = true
        position = Int64(status.positionMilliseconds); playing = status.state == .playing
            || ((status.state == .buffering || status.state == .loading) && state.sample.status == .playing)
        speed = status.speed > 0 && status.speed.isFinite ? status.speed : state.speed
        reading = .init(generation: generation, sample: .init(positionMilliseconds: status.positionMilliseconds,
            durationMilliseconds: status.durationMilliseconds, seekable: status.seekable,
            status: playing ? .playing : .paused), buffering: status.state == .buffering || status.state == .loading, speed: speed)
        observeStatus(generation)
        if let lease, lease.item.contentURL != status.contentURL {
            // Known database media from another sender or an expired/proxy-stale
            // lease must use the application's newly authorized fetch URL. Keep
            // receiver position/intent and the coordinator's adoption baseline.
            adopted = nil
            sendLoad()
        } else if let reading { onEvent?(.ready(reading)) }
        startProgress(generation)
    }

    func takeMediaForAdoption(_ status: CastRemoteSnapshot) -> CastPlaybackMedia? {
        guard let media, media.item.contentURL == status.contentURL,
              let id = media.item.mediaID, Int64(id) == status.mediaID.flatMap(Int64.init) else { return nil }
        self.media = nil
        return media
    }

    private var currentMediaID: String? { adopted?.mediaID ?? media?.item.mediaID }
    private func matchesCurrentItem(_ status: CastRemoteSnapshot) -> Bool {
        guard status.mediaID == currentMediaID, status.libraryID == libraryTag else { return false }
        if let adopted { return status.loadID == adopted.loadID && status.mediaSessionID == adopted.sessionID }
        return loadID != nil && status.loadID == loadID?.uuidString
    }

    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        if foreignReceiver {
            // An explicit selection can replace an unowned receiver item. Do
            // not send STOP for the old episode while retiring its observation.
            loadID = nil; adopted = nil; suspended = false
        }
        unload()
        selectedEpisode = episode
        self.generation = generation; position = max(0, positionMilliseconds)
        reading = .init(generation: generation,
            sample: .init(positionMilliseconds: Int32(clamping: position),
                          durationMilliseconds: episode.details.media?.durationMilliseconds ?? 0, status: .paused),
            isPrepared: false)
        observeStatus(generation)
        preparing = Task { [weak self, prepareMedia] in
            do {
                let media = try await prepareMedia(episode)
                guard !Task.isCancelled, let self, self.generation == generation else { media.close(); return }
                self.preparing = nil; self.media = media
                self.sendLoad()
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.preparing = nil; self.reportFailure(error.localizedDescription)
            }
        }
    }

    private func observeStatus(_ generation: UUID) {
        let observerID = UUID(); statusObserverID = observerID
        client.onStatus = { [weak self] in
            guard self?.generation == generation, self?.statusObserverID == observerID else { return }
            if self?.awaitingResumeStatus == true { self?.reconcileResume() }
            else { self?.receiveStatus() }
        }
    }

    /// iOS can suspend the sender connection while the receiver keeps playing.
    /// Keep the episode/relay lease and owner generation; only retire SDK work.
    func suspendConnection() {
        guard !suspended else { return }
        receiveStatus()
        suspended = true; awaitingResumeStatus = false
        deferred.formUnion(pending.keys)
        cancelPendingRequests(); polling?.cancel(); polling = nil
    }

    /// The SDK session ends independently of media playback. Match Media3's
    /// client detachment before local handback: do not send a media STOP, and
    /// transfer any HTTP lease that a disconnected receiver may still fetch.
    func detachReceiverMedia() -> CastPlaybackMedia? {
        suspendConnection()
        let lease = media
        media = nil
        return lease
    }

    func resumeConnection(client: any CastMediaClient) {
        self.client.onStatus = nil; self.client = client
        suspended = false
        guard let generation else { return }
        observeStatus(generation)
        guard media != nil || adopted != nil else { return } // An explicit new selection is still preparing.
        awaitingResumeStatus = true
        // The SDK may retain its pre-suspension snapshot at session-resumed.
        // Wait for receiver status/GET_STATUS completion before consuming it.
        send(.status, slot: .status) { [weak self] in self?.reconcileResume() }
    }

    private func reconcileResume() {
        guard !suspended, awaitingResumeStatus, let status = client.snapshot else { return }
        awaitingResumeStatus = false
        let matches = matchesCurrentItem(status)
        if deferred.contains(.load), !matches {
            // The explicit selection was never acknowledged. If the receiver did
            // accept it, the matching identity above avoids another LOAD.
            deferred.removeAll(); sendLoad(); return
        }
        guard matches || (ready && status.state == .idle && status.mediaID == nil
            && (status.mediaSessionID == mediaSessionID || status.mediaSessionID == 0)) else {
            deferred.removeAll(); suspended = true; foreignReceiver = true
            onReceiverItemChanged?(client, status); return
        }
        receivedLoadResponse = true
        let commands = deferred; deferred.removeAll()
        if status.state == .idle {
            let explicitlyPlay = commands.contains(.playing) && playing
            receiveStatus()
            if !ended, !failed, explicitlyPlay { playing = true; sendLoad() }
            return
        }
        applyingLoadCommands = true
        if commands.contains(.seek) { send(.seek(position), slot: .seek) }
        if commands.contains(.playing) { send(playing ? .play : .pause, slot: .playing) }
        if commands.contains(.speed) { send(.speed(speed), slot: .speed) }
        if commands.contains(.volume) || commands.contains(.load) { send(.volume(streamVolume), slot: .volume) }
        applyingLoadCommands = false
        receiveStatus(progress: true)
        if let generation, ready, !ended, !failed, !unloadedAtReceiver { startProgress(generation) }
    }

    private func sendLoad() {
        guard let media else {
            if let adopted, let generation {
                // A receiver-owned URL may belong to another sender. An explicit
                // reload must acquire this app's authorized source/relay lease.
                let savedPosition = position, savedPlaying = playing, savedSpeed = speed
                let savedVolume = adaptation, savedTimer = timerVolume, command = reading?.commandID ?? generation
                load(episode: adopted.episode, generation: generation, positionMilliseconds: savedPosition)
                speed = savedSpeed; adaptation = savedVolume; timerVolume = savedTimer
                reading?.speed = savedSpeed; playing = savedPlaying; setIntent(command)
            }
            return
        }
        if suspended || awaitingResumeStatus { deferred.insert(.load); return }
        let id = UUID(); loadID = id; mediaSessionID = nil
        receivedLoadResponse = false; ready = false; ended = false; unloadedAtReceiver = false
        reading?.isPrepared = false
        let queue = GCKMediaQueueDataBuilder(queueType: .generic)
        queue.items = [CastMediaItemCodec.encode(media.item, loadID: id)]
        queue.repeatMode = .off; queue.startIndex = 0; queue.startTime = Double(position) / 1000
        let data = GCKMediaLoadRequestDataBuilder()
        data.queueData = queue.build(); data.autoplay = NSNumber(value: playing)
        data.startTime = Double(position) / 1000; data.playbackRate = speed
        let submittedPosition = position, submittedPlaying = playing, submittedSpeed = speed
        send(.load(data.build()), slot: .load) { [weak self] in
            guard let self, self.loadID == id else { return }
            self.receivedLoadResponse = true
            self.deferred.removeAll()
            self.applyingLoadCommands = true
            // Commands issued while the load was in flight belong to this item.
            // Mask their old status fields before consuming the load response.
            if self.position != submittedPosition { self.send(.seek(self.position), slot: .seek) }
            if self.playing != submittedPlaying { self.send(self.playing ? .play : .pause, slot: .playing) }
            if self.speed != submittedSpeed { self.send(.speed(self.speed), slot: .speed) }
            self.send(.volume(self.streamVolume), slot: .volume)
            self.applyingLoadCommands = false
            self.receiveStatus()
        }
    }

    func play(commandID: UUID) {
        if foreignReceiver, let episode = selectedEpisode, let generation {
            let savedPosition = position, savedSpeed = speed, savedVolume = adaptation, savedTimer = timerVolume
            load(episode: episode, generation: generation, positionMilliseconds: savedPosition)
            speed = savedSpeed; adaptation = savedVolume; timerVolume = savedTimer; reading?.speed = savedSpeed
        }
        playing = true; setIntent(commandID)
        if suspended || awaitingResumeStatus || (!receivedLoadResponse && loadID != nil) { deferred.insert(.playing) }
        if unloadedAtReceiver { sendLoad() }
        else if receivedLoadResponse { send(.play, slot: .playing) }
    }
    func pause(commandID: UUID) {
        playing = false; setIntent(commandID)
        if suspended || awaitingResumeStatus || (!receivedLoadResponse && loadID != nil) { deferred.insert(.playing) }
        if receivedLoadResponse, !unloadedAtReceiver { send(.pause, slot: .playing) }
    }
    func seek(to value: Int64, commandID: UUID) {
        position = max(0, value); reading?.sample.positionMilliseconds = Int32(clamping: position)
        setIntent(commandID)
        if suspended || awaitingResumeStatus || (!receivedLoadResponse && loadID != nil) { deferred.insert(.seek) }
        if receivedLoadResponse, !unloadedAtReceiver { send(.seek(position), slot: .seek) }
    }
    func setSpeed(_ value: Float, commandID: UUID) throws {
        guard value.isFinite, value > 0 else { throw PlaybackSpeedError.invalidSpeed }
        // Media3 RemoteCastPlayer clamps to the receiver's supported0.5–2 range.
        speed = min(2, max(0.5, value)); reading?.speed = speed; setIntent(commandID)
        if suspended || awaitingResumeStatus || (!receivedLoadResponse && loadID != nil) { deferred.insert(.speed) }
        if receivedLoadResponse, !unloadedAtReceiver { send(.speed(speed), slot: .speed) }
    }
    private func setIntent(_ commandID: UUID) {
        reading?.commandID = commandID
        reading?.sample.status = playing ? .playing : .paused
        // Receiver readiness survives intent changes until a matching status updates it.
        if let reading { onEvent?(.stateChanged(reading)) }
    }
    private var streamVolume: Float { adaptation.effect(baseVolume: timerVolume).attenuation }
    func setVolumeAdaptation(_ value: FeedVolumeAdaptation) throws {
        adaptation = value
        if suspended || awaitingResumeStatus { deferred.insert(.volume) }
        if receivedLoadResponse, !unloadedAtReceiver { send(.volume(streamVolume), slot: .volume) }
    }
    func setSleepTimerVolume(_ value: Float) throws {
        timerVolume = max(0, min(1, value))
        if suspended || awaitingResumeStatus { deferred.insert(.volume) }
        if receivedLoadResponse, !unloadedAtReceiver { send(.volume(streamVolume), slot: .volume) }
    }

    private func send(_ command: CastMediaCommand, slot: Slot, then: (@MainActor () -> Void)? = nil) {
        guard let generation, !failed else { return }
        if suspended || (awaitingResumeStatus && slot != .status) { deferred.insert(slot); return }
        pending.removeValue(forKey: slot)?.request?.cancel()
        let id = UUID(); pending[slot] = Pending(id: id)
        let token = client.send(command) { [weak self] outcome in
            guard let self, self.generation == generation, self.pending[slot]?.id == id else { return }
            self.pending[slot] = nil
            switch outcome {
            case .failed(let message): self.reportFailure(message)
            case .completed, .superseded:
                if let then { then() } else { self.receiveStatus() }
            }
        }
        if pending[slot]?.id == id { pending[slot]?.request = token }
        else { token.cancel() }
    }

    /// The SDK status callback and the one-second progress observer share this
    /// path. Tests drive it explicitly without clocks or a physical receiver.
    func receiveStatus(progress: Bool = false) {
        guard let generation, receivedLoadResponse, !suspended, !awaitingResumeStatus,
              !applyingLoadCommands, !failed, !ended,
              let status = client.snapshot, var value = reading else { return }
        let matches = matchesCurrentItem(status)
        // The final unload can omit metadata; only the already accepted media
        // session may finish this item. Unrelated receiver items are never adopted here.
        let finalUnload = ready && status.state == .idle && status.mediaID == nil
            && (status.mediaSessionID == mediaSessionID || status.mediaSessionID == 0)
        guard matches || finalUnload else {
            // Another item (another media ID, library or load, in any state, idle or finished included) takes this
            // item's ownership away, so no later status, end or unload without media identity reaches the local
            // episode. Stop observing it.
            if ready, status.mediaID != nil {
                suspended = true; foreignReceiver = true; cancelPendingRequests(); polling?.cancel(); polling = nil
                onReceiverItemChanged?(client, status)
            }
            return
        }
        if matches, status.mediaSessionID != 0 { mediaSessionID = status.mediaSessionID }
        if CastMediaItemCodec.hasPlaybackJustFinished(state: status.state, idleReason: status.idleReason) {
            ended = true; polling?.cancel(); polling = nil
            cancelPendingRequests()
            if status.positionMilliseconds > 0 { value.sample.positionMilliseconds = status.positionMilliseconds }
            if status.durationMilliseconds > 0 { value.sample.durationMilliseconds = status.durationMilliseconds }
            if value.sample.durationMilliseconds > 0 { value.sample.positionMilliseconds = value.sample.durationMilliseconds }
            value.isPrepared = true
            reading = value
            if !ready { ready = true; onEvent?(.ready(value)) }
            onEvent?(.ended(value)); return
        }
        if status.state == .idle {
            if status.idleReason == .error { reportFailure(Appearance.text("cast_error_playback_failed")); return }
            cancelPendingRequests(); polling?.cancel(); polling = nil
            playing = false; unloadedAtReceiver = true
            value.sample.status = .paused; value.buffering = false; value.isPrepared = false
            // Do not replace the saved position with the unloaded session's zero.
            reading = value
            if !ready { ready = true; onEvent?(.ready(value)) }
            else { onEvent?(.stateChanged(value)) }
            return
        }
        guard status.state != .unknown else { return }
        let previous = reading
        if pending[.seek] == nil { position = Int64(status.positionMilliseconds) }
        if pending[.playing] == nil {
            if status.state == .playing { playing = true }
            else if status.state == .paused { playing = false }
        }
        if pending[.speed] == nil, status.speed.isFinite, status.speed > 0 { speed = status.speed }
        value.sample.positionMilliseconds = Int32(clamping: position)
        value.sample.durationMilliseconds = status.durationMilliseconds
        value.sample.seekable = status.seekable
        value.sample.status = playing ? .playing : .paused
        value.buffering = status.state == .buffering || status.state == .loading
        value.isPrepared = true; value.speed = speed
        reading = value
        if !ready {
            ready = true; onEvent?(.ready(value)); startProgress(generation)
        } else if progress, previous?.sample.status == value.sample.status, previous?.buffering == value.buffering {
            onEvent?(.position(value))
        } else { onEvent?(.stateChanged(value)) }
    }
    private func startProgress(_ generation: UUID) {
        guard automaticallyPoll, polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == generation else { return }
                self.receiveStatus(progress: true)
            }
        }
    }
    private func reportFailure(_ message: String) {
        guard let generation, !failed else { return }
        failed = true; polling?.cancel(); polling = nil
        cancelPendingRequests()
        reading?.sample.status = .paused; reading?.buffering = false
        onEvent?(.failed(generation: generation, message: message))
    }
    private func cancelPendingRequests() {
        let requests = pending.values; pending.removeAll()
        requests.forEach { $0.request?.cancel() }
    }
    func unload() {
        let ownedMedia = loadID != nil || adopted != nil
        generation = nil; client.onStatus = nil
        preparing?.cancel(); preparing = nil; polling?.cancel(); polling = nil
        cancelPendingRequests()
        if ownedMedia, !suspended { client.send(.stop) { _ in }.cancel() }
        media?.close(); media = nil; reading = nil; loadID = nil; mediaSessionID = nil
        adoptionMedia?.close(); adoptionMedia = nil
        adopted = nil
        selectedEpisode = nil; foreignReceiver = false
        position = 0; playing = false; speed = 1; adaptation = .off; timerVolume = 1
        receivedLoadResponse = false; applyingLoadCommands = false
        ready = false; ended = false; failed = false; unloadedAtReceiver = false
        awaitingResumeStatus = false; deferred.removeAll()
    }
}

import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// Through the app's own composition (Cast route switch, application engine, processed or AVPlayer
/// engine, one session owner observing the system's events) and the real coordinator and store:
/// - a media-services reset keeps the episode selected at its position as after a relaunch (phase stopped: shown
///   paused; Play rebuilds it, and seeking and skipping wait for that Play), with no failed phase and no dialog; its
///   audio objects go at once (a source still being resolved too), a failure of their cleanup is no failure, late
///   events start nothing, and only an explicit Play builds new ones;
/// - an interruption's pending resumption is kept until its end or a command of the person, never ended by the app
///   coming to the foreground; Pause and Stop give it up, so a late end plays nothing; an explicit Play supersedes it;
/// - a library switch or "Keep using this library" requested while playing or during the interruption waits, is
///   never stuck ("Stop playback and continue"), and a late end after that action is fenced;
/// - sync counts only actual playback; a Play, and playback an interruption's end resumes, fence a large
///   publication from the step they are admitted or reported.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct AudioResetAndInterruptionTests {
    typealias Rig = AudioSessionOwnerTests.Rig

    private func rig(avPlayer: Bool = false) async throws -> (Rig, PlaybackCoordinator) {
        let rig = try Rig(fallback: avPlayer ? [1] : [], events: true, routed: true)
        rig.driver.autoComplete = true
        return (rig, try await rig.coordinator())
    }

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    /// Every OS activation so far (an activation without the person is the thing to rule out).
    private func activations(_ rig: Rig) -> Int { rig.driver.calls.filter { $0 }.count }

    /// Late events have reached the owner, the engines and the coordinator.
    private func settle(_ rig: Rig, _ player: PlaybackCoordinator) async throws {
        await player.settle()
        try await wait { rig.owner.isIdle }
        await player.settle()
    }

    private func interrupt(_ rig: Rig, _ player: PlaybackCoordinator) async throws {
        rig.events.post(.interrupted(reason: 0))
        try await wait { player.awaitsInterruptionResumption && rig.transports.allSatisfy { !$0.playing } }
        await player.settle()
        #expect(player.phase == .paused && !player.wantsPlayback, "the player shows paused")
    }

    // MARK: Media-services reset

    @Test(arguments: [false, true])
    func resetKeepsTheEpisodeAsAfterARelaunchWithoutADialogAndOnlyPlayRebuilds(avPlayer: Bool) async throws {
        let (rig, player) = try await rig(avPlayer: avPlayer)
        defer { rig.close() }
        let reports = PCMSystemSessionTests.EngineReports(try #require(rig.routes))
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle && player.phase == .playing }
        if avPlayer {
            try await wait { (rig.app.reading?.sample.positionMilliseconds ?? 0) > 100 }
        } else {
            rig.transports[0].advance(24_000)
        }
        let made = try #require(rig.engines.last)
        let output = rig.transports.last
        rig.events.post(.mediaServicesReset)
        // Its audio objects go in the step the system reported the reset, before the coordinator hears of it.
        if avPlayer { #expect((made.engine as? AVPlayerPlaybackEngine)?.nativePlayer == nil) }
        else { #expect(output?.closed == true && output?.playing == false) }
        try await wait { player.phase == .stopped }
        try await settle(rig, player)
        #expect(reports.failures.isEmpty && reports.resets.count == 1, "a reset is no playback failure: no dialog")
        #expect(player.episode?.id == 1 && !player.wantsPlayback && player.sample?.status == .paused)
        let position = try #require(player.sample?.positionMilliseconds)
        #expect(position > 0 && position == reports.resets.first?.sample.positionMilliseconds)
        #expect(try await rig.store.episode(id: 1)?.userState.positionMilliseconds == position, "saved where it stopped")
        #expect(made.engine == nil, "the application engine retired the reset engine")
        // As after a relaunch: shown paused with Play available; seeking and skipping wait for Play.
        #expect(player.systemSnapshot?.canPlay == true && player.systemSnapshot?.rate == 0)
        #expect(player.systemSnapshot?.canSeek == false && player.systemSnapshot?.canSkip == false)
        // The session's recovery events and the old engine's callbacks start nothing (QA1749).
        rig.events.post(.becameActive)
        rig.events.post(.resumptionRecommended(true))
        try await settle(rig, player)
        #expect(activations(rig) == 1 && rig.engines.count == 1 && rig.playingEpisode == nil && player.phase == .stopped)
        // An explicit Play builds a new engine at the saved position.
        try await player.play()
        try await wait { rig.playingEpisode == 1 && rig.engines.count == 2 && player.phase == .playing }
        #expect(reports.failures.isEmpty && player.episode?.id == 1)
        try await player.stop()
    }

    enum Resolution: String, CaseIterable, Sendable { case initial, replacement }

    /// A reset while the item's source is still being resolved (held at the gate, as credentials, a local
    /// document or the format would hold it), for a first selection or replacing a playing episode. The resolution's
    /// late result is closed and never receives the Play asked for before the reset: nothing plays, nothing activates,
    /// the episode stays selected at its position with one reset and no failure; an explicit Play plays it.
    @Test(arguments: Resolution.allCases)
    func resetDuringSourceResolutionNeverDeliversTheEarlierPlay(resolution: Resolution) async throws {
        let (rig, player) = try await rig()
        defer { rig.close() }
        let reports = PCMSystemSessionTests.EngineReports(try #require(rig.routes))
        let episode: Int64 = resolution == .initial ? 1 : 2
        if resolution == .replacement {
            try await player.select(episodeID: 1)
            try await wait { rig.playingEpisode == 1 && rig.owner.isIdle }
        }
        let saved = try await rig.store.episode(id: episode)?.userState.positionMilliseconds
        rig.gate.hold(episode)
        try await player.select(episodeID: episode)
        try await wait { rig.gate.isWaiting(episode) && rig.owner.isIdle }
        let before = activations(rig)
        rig.events.post(.mediaServicesReset)
        try await wait { player.phase == .stopped }
        rig.gate.release(episode)
        try await wait { rig.resolved.contains(episode) }
        try await settle(rig, player)
        #expect(reports.failures.isEmpty && reports.resets.count == 1, "one reset, no failure")
        #expect(player.episode?.id == episode && !player.wantsPlayback && player.phase == .stopped)
        #expect(rig.playingEpisode == nil && activations(rig) == before, "the late resolution plays and activates nothing")
        #expect(rig.engines.filter { $0.id == episode }.allSatisfy { $0.engine == nil }, "its late engine was closed")
        #expect(try await rig.store.episode(id: episode)?.userState.positionMilliseconds == saved)
        try await player.play()
        try await wait { rig.playingEpisode == episode && player.phase == .playing }
        try await player.stop()
    }

    /// The reset's own cleanup pauses an orphaned output whose clock already fails; the output reports
    /// that failure synchronously, inside the reset. It is no failure of the item: no failed phase, no dialog, one
    /// reset, the output closed, the position the player had kept; Play plays.
    @Test func anOutputFailingInTheResetCleanupIsNoFailure() async throws {
        let (rig, player) = try await rig()
        defer { rig.close() }
        let reports = PCMSystemSessionTests.EngineReports(try #require(rig.routes))
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle && player.phase == .playing }
        let output = try #require(rig.transports.last)
        #expect(output.playing)
        output.currentTime = .invalid
        rig.events.post(.mediaServicesReset)
        #expect(output.closed && !output.playing)
        try await wait { player.phase == .stopped || player.phase == .failed }
        try await settle(rig, player)
        #expect(player.phase == .stopped && reports.failures.isEmpty && reports.resets.count == 1, "\(reports.failures)")
        #expect(player.episode?.id == 1 && player.sample?.status == .paused)
        let position = try #require(player.sample?.positionMilliseconds)
        #expect(try await rig.store.episode(id: 1)?.userState.positionMilliseconds == position)
        try await player.play()
        try await wait { rig.playingEpisode == 1 && player.phase == .playing }
        try await player.stop()
    }

    // MARK: Pending resumption

    enum GiveUp: String, CaseIterable, Sendable { case pause, systemPause, stop }

    /// Pause (the player's, or the Lock Screen's, which the player shows as paused) and Stop during an interruption
    /// give up its resumption: no switch waits for it, and its late end, resuming or not, plays nothing and
    /// activates nothing. A later explicit Play plays.
    @Test(arguments: GiveUp.allCases, [true, false])
    func aCommandDuringTheInterruptionGivesUpItsResumption(command: GiveUp, lateEndResumes: Bool) async throws {
        let (rig, player) = try await rig()
        defer { rig.close() }
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle }
        let identity = try #require(player.systemSnapshot?.identity)
        try await interrupt(rig, player)
        switch command {
        case .pause: try await player.pause()
        case .systemPause: #expect(try await player.performSystemCommand(.pause, for: identity))
        case .stop: try await player.stop()
        }
        try await settle(rig, player)
        #expect(!player.awaitsInterruptionResumption && !player.wantsPlayback)
        #expect(LibraryActivationState(player, castBlocks: false).permitsSwitch)
        let before = activations(rig)
        rig.events.post(.resumptionRecommended(lateEndResumes))
        try await settle(rig, player)
        #expect(rig.transports.allSatisfy { !$0.playing } && !player.wantsPlayback && activations(rig) == before,
                "the late end is fenced")
        #expect(player.phase == (command == .stop ? .stopped : .paused))
        try await player.play()
        try await wait { rig.playingEpisode == 1 && player.phase == .playing }
        try await player.stop()
    }

    /// An explicit Play during the interruption supersedes it: playback starts (the session is granted here), and
    /// the interruption's late end changes nothing.
    @Test func anExplicitPlaySupersedesThePendingResumption() async throws {
        let (rig, player) = try await rig()
        defer { rig.close() }
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle }
        try await interrupt(rig, player)
        try await player.play()
        try await wait { rig.playingEpisode == 1 && player.phase == .playing && rig.owner.isIdle }
        #expect(!player.awaitsInterruptionResumption)
        let outputs = rig.transports.count, before = activations(rig)
        rig.events.post(.resumptionRecommended(true))
        try await settle(rig, player)
        #expect(rig.transports.count == outputs && activations(rig) == before && rig.playingEpisode == 1)
        try await player.stop()
    }

    // MARK: A waiting switch or Keep

    /// A library graph's switch or Keep, as the app runs them: the switcher with its activation rule, re-checked after
    /// each player state change and at every scene activation; the Keep through `LibraryKeepRuntime`.
    @MainActor final class WaitingOperation {
        enum Kind: String, CaseIterable, Sendable { case librarySwitch, keep }
        nonisolated static let serverID = "5e0f4b1a-2c3d-4e5f-8a9b-0c1d2e3f4a5b"
        let kind: Kind
        let root: URL
        let registry: LibraryRegistryFile
        let player: PlaybackCoordinator
        var switcher: LibrarySwitcher!
        private var observation: Task<Void, Never>?
        private var keepPending = false
        /// The switch's restart, or the Keep's phases, ran (and finished).
        private(set) var ran = 0
        /// Keep attempts; one that does not succeed (not enough storage) leaves the Keep pending.
        private(set) var attempts = 0
        var keepSucceeds = true
        /// The Keep still waits (it never ran, or it stalled).
        var isKeepPending: Bool { keepPending }
        /// After a Keep attempt the app restarts the library graph, so this graph (its player and its switch checks)
        /// never runs the Keep again; a retry belongs to the next graph, as in the app.
        private var graphRestarted = false
        private(set) var holdChanges = 0

        init(_ kind: Kind, player: PlaybackCoordinator) throws {
            self.kind = kind; self.player = player
            root = FileManager.default.temporaryDirectory.appendingPathComponent("WaitingOperation-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            registry = LibraryRegistryFile(root: root)
            var saved = LibraryRegistry()
            saved.libraries = [.init(id: Self.serverID, serverURL: "https://sync.example.test", serverID: "server-1",
                                     accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f", username: "alice", state: .ready, createdAt: 1)]
            try registry.write(saved)
            try LibraryLocation(root: root, reference: .server(Self.serverID)).prepare()
            switcher = LibrarySwitcher(registry: registry, activation: { [weak self] in
                LibraryActivationState(self?.player, castBlocks: false)
            }, settle: { [weak self] in await self?.player.settle() }, retire: { [weak self] in self?.player.retire() },
               restart: { [weak self] in await self?.restart() })
            switcher.opened(try registry.openingLibrary())
            if kind == .keep {
                switcher.keepPending = { [weak self] in self.map { $0.keepPending && !$0.graphRestarted } ?? false }
                switcher.runKeep = { [weak self] in await self?.runKeep() }
            }
            switcher.onPlaybackHoldChange = { [weak self] in self?.holdChanges += 1 }
            observation = switcher.observe(player)
        }

        func request() async throws {
            switch kind {
            case .librarySwitch: try await switcher.request(.server(Self.serverID), reason: .logout)
            case .keep: keepPending = true; await switcher.attempt()
            }
        }

        /// What the page shows and its action ends.
        var hold: LibraryPlaybackHold? { LibraryActivationState(player, castBlocks: false).playbackHold }

        /// "Stop playback and continue", as the app's account service runs it.
        func stopPlaybackAndContinue() async {
            try? await player.stop()
            await switcher.attempt()
        }

        private func restart() async {
            observation?.cancel()
            await player.retire().value
            ran += 1
            switcher.opened((try? registry.openingLibrary()) ?? .standalone)
        }

        private func runKeep() async {
            await LibraryKeepRuntime(gate: LibraryGate(), mayRun: { [weak self] in
                guard let self else { return false }
                return LibraryActivationState(player, castBlocks: false).permitsSwitch && keepPending && !graphRestarted
            }, retire: { [weak self] in _ = self?.player.retire() },
               stop: { [weak self] in await self?.player.retire().value },
               keep: { [weak self] in
                   guard let self else { return }
                   attempts += 1
                   if keepSucceeds { ran += 1; keepPending = false }
               },
               restart: { [weak self] in self?.graphRestarted = true; self?.observation?.cancel() }).run()
        }

        func close() {
            observation?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
    }

    enum Requested: String, CaseIterable, Sendable { case whilePlaying, duringInterruption }
    enum End: String, CaseIterable, Sendable { case resumes, doesNotResume, never }

    /// Every ordering of the plan's expected results: a switch or Keep requested while playing or during the
    /// interruption waits through it, the app coming to the foreground in one scene and another ending nothing;
    /// its page offers "Stop playback and continue", after which the operation runs and the late end plays nothing.
    /// Without the action: ended(shouldResume) resumes playback and the operation waits for a pause; ended without
    /// resuming lets it run by itself; no end keeps it waiting, with the action still offered.
    @Test(arguments: WaitingOperation.Kind.allCases, Requested.allCases)
    func aWaitingOperationThroughAnInterruption(kind: WaitingOperation.Kind, requested: Requested) async throws {
        for end in End.allCases {
            for action in [false, true] {
                try await scenario(kind, requested, end, action)
            }
        }
    }

    private func scenario(_ kind: WaitingOperation.Kind, _ requested: Requested, _ end: End, _ action: Bool) async throws {
        let label = "\(kind) \(requested) \(end) action=\(action)"
        let (rig, player) = try await rig()
        defer { rig.close() }
        let operation = try WaitingOperation(kind, player: player)
        defer { operation.close() }
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle && player.phase == .playing }
        if requested == .whilePlaying {
            try await operation.request()
            #expect(operation.ran == 0 && operation.hold == .playing, "\(label): waits while playing")
        }
        try await interrupt(rig, player)
        if requested == .duringInterruption { try await operation.request() }
        // The app comes to the foreground, in one scene and then in another: no evidence the interruption ended.
        #expect(await operation.switcher.attempt() == false, "\(label)")
        #expect(await operation.switcher.attempt() == false, "\(label)")
        try await settle(rig, player)
        #expect(operation.ran == 0 && player.awaitsInterruptionResumption, "\(label): still waiting for the call")
        #expect(operation.hold == .resumingAfterInterruption, "\(label): the page says playback resumes after it")
        let activationsBefore = activations(rig)
        if action {
            await operation.stopPlaybackAndContinue()
            try await wait { operation.ran == 1 }
            #expect(player.isRetired && !player.wantsPlayback, "\(label)")
        }
        switch end {
        case .resumes: rig.events.post(.resumptionRecommended(true))
        case .doesNotResume: rig.events.post(.resumptionRecommended(false))
        case .never: break
        }
        try await settle(rig, player)
        if action {
            #expect(operation.ran == 1 && rig.transports.allSatisfy { !$0.playing } && activations(rig) == activationsBefore,
                    "\(label): the late end is fenced")
            return
        }
        switch end {
        case .resumes:
            try await wait { rig.playingEpisode == 1 && player.phase == .playing }
            #expect(operation.ran == 0 && operation.hold == .playing, "\(label): resumed; the operation waits for a pause")
            try await player.pause()
            try await wait { operation.ran == 1 }
        case .doesNotResume:
            // Giving up the resumption is a state change of its own: the operation runs without another trigger.
            try await wait { operation.ran == 1 }
            #expect(rig.transports.allSatisfy { !$0.playing } && activations(rig) == activationsBefore, "\(label)")
        case .never:
            #expect(await operation.switcher.attempt() == false, "\(label)")
            #expect(operation.ran == 0 && operation.hold == .resumingAfterInterruption, "\(label): offers the action")
            // The action ends it at any time.
            await operation.stopPlaybackAndContinue()
            try await wait { operation.ran == 1 }
        }
        #expect(operation.holdChanges >= 2, "\(label): the page heard of the hold changing")
    }

    /// A Play admitted after "Stop playback and continue" wins: the operation is checked against it in one step, waits
    /// again for playback, and runs at the next pause.
    @Test(arguments: WaitingOperation.Kind.allCases)
    func aPlayAdmittedAfterTheActionHoldsTheOperation(kind: WaitingOperation.Kind) async throws {
        let (rig, player) = try await rig()
        defer { rig.close() }
        let operation = try WaitingOperation(kind, player: player)
        defer { operation.close() }
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle }
        try await operation.request()
        try await interrupt(rig, player)
        try await player.stop()
        let play = Task { try await player.play() }
        try await wait { player.startsPlayback || player.phase != .stopped }
        #expect(await operation.switcher.attempt() == false)
        try await play.value
        try await wait { rig.playingEpisode == 1 && player.phase == .playing }
        #expect(operation.ran == 0 && operation.hold == .playing && !player.isRetired)
        try await player.pause()
        try await wait { operation.ran == 1 }
    }

    /// A Keep that stalled (not enough storage) and is then held by playback, here an interruption with
    /// no end, still offers "Stop playback and continue" with its explanation; the action stops playback and the
    /// Keep's retry decides: with storage freed it finishes, otherwise it stalls again and nothing plays.
    @Test(arguments: [true, false])
    func aStalledKeepHeldByAnInterruptionStillOffersTheAction(storageFreed: Bool) async throws {
        let (rig, player) = try await rig()
        defer { rig.close() }
        let operation = try WaitingOperation(.keep, player: player)
        defer { operation.close() }
        // An earlier attempt (before the graph restarted) stalled for lack of storage; the Keep is still pending
        // and the person keeps listening.
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle && player.phase == .playing }
        operation.keepSucceeds = storageFreed
        try await operation.request()
        try await interrupt(rig, player)
        #expect(await operation.switcher.attempt() == false && operation.attempts == 0, "the interruption holds the retry")
        var registry = LibraryRegistry()
        let id = ContractIdentity.randomUUID()
        registry.libraries = [.init(id: id, serverURL: "https://sync.example.test", serverID: "s", accountID: ContractIdentity.randomUUID(),
                                    username: "alice", state: .keeping, operation: ContractIdentity.randomUUID(), createdAt: 0)]
        registry.active = .server(id)
        func page() -> ServerSynchronizationPage {
            .make(registry: registry, open: .server(id), otherProvider: false, summaries: [:], keepFailure: .storage, playbackHold: operation.hold)
        }
        #expect(page().condition == .keepStalled(.storage) && page().rows == [.status, .stopPlayback])
        await operation.stopPlaybackAndContinue()
        try await wait { operation.attempts == 1 }
        // Other triggers of this graph (its last state changes, another check) start no second attempt.
        #expect(await operation.switcher.attempt() == false)
        await player.settle()
        #expect(operation.attempts == 1 && player.isRetired && !player.wantsPlayback && rig.transports.allSatisfy { !$0.playing })
        #expect(operation.hold == nil && !page().rows.contains(.stopPlayback), "the action stopped audio and cleared the hold")
        if storageFreed { #expect(operation.ran == 1 && !operation.isKeepPending, "with storage the Keep completes") }
        else { #expect(operation.ran == 0 && operation.isKeepPending, "without it the Keep stays stalled for the next graph") }
    }

    // MARK: Sync pacing and publication (PROTOCOL §6.8)

    /// Only actual playback counts for sync: preparing and playing do, and a Play from the step it is admitted, before
    /// it runs (a publication ticket taken earlier is refused); an item held silent by an interruption, or paused by the
    /// person, does not; its resumption counts again.
    @Test func syncCountsOnlyActualPlaybackAndAPlayFencesPublicationAtAdmission() async throws {
        let (rig, player) = try await rig()
        defer { rig.close() }
        let eligibility = ServerPublicationEligibility()
        var atAdmission: [(PlaybackCoordinator.Phase, Bool, Bool)] = []
        player.onPlaybackRequested = { [weak player] in
            eligibility.changed()
            if let player { atAdmission.append((player.phase, player.startsPlayback, player.playsForSynchronization)) }
        }
        #expect(!player.playsForSynchronization)
        let ticket = ServerPublicationTicket(eligibility: eligibility, generation: eligibility.current)
        try await player.select(episodeID: 1)
        #expect(!ticket.isCurrent, "a publication admitted before the Play is refused")
        #expect(atAdmission.count == 1 && atAdmission[0].0 == .idle && atAdmission[0].1 && atAdmission[0].2,
                "counted as playing from its admission, before it ran")
        #expect(player.phase == .preparing && player.playsForSynchronization && !player.startsPlayback)
        try await wait { rig.playingEpisode == 1 && player.phase == .playing }
        #expect(player.playsForSynchronization)
        try await interrupt(rig, player)
        #expect(!player.playsForSynchronization, "interrupted and silent")
        rig.events.post(.resumptionRecommended(true))
        try await wait { rig.playingEpisode == 1 && player.phase == .playing }
        #expect(player.playsForSynchronization, "resumed")
        try await player.pause()
        #expect(!player.playsForSynchronization, "paused by the person")
        try await interruptAfterPlay(rig, player)
        // A paused item and an interrupted one are no wait for a sync pause; a Pause or a seek are no play request.
        let count = atAdmission.count
        try await player.seek(to: 100)
        #expect(atAdmission.count == count)
        try await player.stop()
    }

    /// Playback an interruption's end resumes by itself is fenced like a Play, in the step the engine
    /// reports it: a publication admitted while the item was silent is refused, and the item counts as playing for
    /// sync, before the coordinator has handled the resumption (it still shows paused then); afterwards it plays.
    @Test func anInterruptionsResumptionFencesPublicationBeforeItIsHandled() async throws {
        let (rig, player) = try await rig()
        defer { rig.close() }
        let eligibility = ServerPublicationEligibility()
        player.onPlaybackRequested = { eligibility.changed() }
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && player.phase == .playing && !player.startsPlayback }
        try await interrupt(rig, player)
        #expect(!player.playsForSynchronization, "silent")
        let ticket = ServerPublicationTicket(eligibility: eligibility, generation: eligibility.current)
        rig.events.post(.resumptionRecommended(true))
        // Same step: the coordinator's handling of the resumed state is still queued.
        #expect(player.phase == .paused && !player.wantsPlayback, "not handled yet")
        #expect(!ticket.isCurrent, "a publication admitted while silent is refused")
        #expect(player.playsForSynchronization && player.startsPlayback, "counted as playing until handled")
        try await wait { rig.playingEpisode == 1 && player.phase == .playing }
        await player.settle()
        #expect(player.playsForSynchronization && !player.startsPlayback)
        try await player.stop()
    }

    private func interruptAfterPlay(_ rig: Rig, _ player: PlaybackCoordinator) async throws {
        try await player.play()
        try await wait { rig.playingEpisode == 1 && player.phase == .playing }
        try await interrupt(rig, player)
        #expect(!player.playsForSynchronization)
    }

    // MARK: The account service's action

    /// "Stop playback and continue" stops playback, then runs whichever operation waits; one that runs at once
    /// follows the tap, so the page reopens in that scene, without announcing the earlier logout again. The page
    /// names the hold.
    @Test func stopPlaybackAndContinueStopsThenRunsTheWaitingOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StopAndContinue-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = ContractIdentity.randomUUID()
        var registry = LibraryRegistry()
        registry.libraries = [.init(id: id, serverURL: "https://sync.example.test", serverID: "s", accountID: ContractIdentity.randomUUID(),
                                    username: "alice", state: .inactive, createdAt: 0)]
        registry.active = .server(id)
        try registry.recordSwitch(to: .standalone, reason: .logout, at: 1)
        try LibraryRegistryFile(root: root).write(registry)
        var steps: [String] = []
        var hold: LibraryPlaybackHold? = .resumingAfterInterruption
        var accounts: ServerAccounts!
        var dependencies = ServerAccounts.Dependencies(root: root, openLibrary: { .server(id) }, requestSwitch: { _, _, _ in },
            secrets: MemoryServerSecrets(), makeClient: { ServerClient(address: $0) }, device: ServerDevice(name: "n", appVersion: "t"))
        dependencies.playbackHold = { hold }
        dependencies.stopPlayback = {
            steps.append("stop in \(accounts.interactiveSwitch?.scene ?? "-") \(accounts.interactiveSwitch?.reason.rawValue ?? "-")")
            hold = nil
        }
        dependencies.attemptKeep = {
            steps.append("attempt in \(accounts.interactiveSwitch?.scene ?? "-") continues \(accounts.interactiveSwitchContinues)")
        }
        accounts = ServerAccounts(dependencies)
        let waiting = accounts.page(otherProvider: false)
        #expect(waiting.condition == .loggedOut && waiting.playbackHold == .resumingAfterInterruption)
        #expect(waiting.rows == [.status, .stopPlayback, .keptLibraries])
        var changes = 0
        let observation = accounts.observe { changes += 1 }
        await accounts.stopPlaybackAndContinue(scene: "scene-1")
        // It only continues the logout made earlier: the reopened page does not announce it again.
        #expect(steps == ["stop in scene-1 logout", "attempt in scene-1 continues true"])
        #expect(accounts.interactiveSwitch == nil && !accounts.interactiveSwitchContinues && changes >= 1)
        let after = accounts.page(otherProvider: false)
        #expect(after.playbackHold == nil && after.rows == [.status, .keptLibraries])
        _ = observation
    }
}

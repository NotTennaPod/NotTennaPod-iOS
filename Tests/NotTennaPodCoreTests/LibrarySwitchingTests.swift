import Foundation
import Testing
@testable import NotTennaPodCore

/// PROTOCOL §15.4: a library switch runs only when nothing plays, nothing is about to play and nothing will resume by
/// itself. Checked with the real store and coordinator and a scripted engine that reports interruptions as the
/// processed-audio engine does (`PlaybackRecoveryController`: a call holds playback; its end may resume it).
@Suite @MainActor
struct LibrarySwitchingTests {
    nonisolated private static let serverID = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"

    private final class Engine: PlaybackEngine, PlaybackInterruptionReporting {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        private(set) var resumesAfterInterruption = false
        private(set) var loads = 0, plays = 0
        private var generation: UUID?, commandID: UUID?, start: Int64 = 0, wanted = false
        let duration: Int32 = 20_000

        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            self.generation = generation; commandID = generation; loads += 1
            start = positionMilliseconds; reading = nil; wanted = false; resumesAfterInterruption = false
        }
        func play(commandID: UUID) { command(commandID); plays += 1; wanted = true; reading?.sample.status = .playing }
        func pause(commandID: UUID) {
            command(commandID); wanted = false; resumesAfterInterruption = false; reading?.sample.status = .paused
        }
        func seek(to positionMilliseconds: Int64, commandID: UUID) {
            command(commandID); reading?.sample.positionMilliseconds = Int32(positionMilliseconds)
        }
        func setSpeed(_ speed: Float, commandID: UUID) throws { command(commandID) }
        func unload() { reading = nil; generation = nil; commandID = nil; wanted = false; resumesAfterInterruption = false }
        private func command(_ id: UUID) { commandID = id; reading?.commandID = id }

        func ready() {
            guard let generation, let commandID else { return }
            let value = PlaybackEngineReading(generation: generation, commandID: commandID, sample: .init(
                positionMilliseconds: Int32(start), durationMilliseconds: duration, status: wanted ? .playing : .paused))
            reading = value
            onEvent?(.ready(value))
        }
        /// A phone call: output pauses and playback is held for the call's end.
        func interrupt() {
            guard wanted, var value = reading else { return }
            resumesAfterInterruption = true
            value.sample.status = .paused
            reading = value
            onEvent?(.stateChanged(value))
        }
        /// The call ends. Resumed: playing again. Not resumed: the policy drops play intent; the reading is unchanged,
        /// so (like the real engine) no event is sent.
        func endInterruption(resume: Bool) {
            guard resumesAfterInterruption, var value = reading else { return }
            resumesAfterInterruption = false
            guard resume else { wanted = false; return }
            value.sample.status = .playing
            reading = value
            onEvent?(.stateChanged(value))
        }
        /// Reports the current reading again (the engine's periodic and state reports).
        func report() { if let reading { onEvent?(.stateChanged(reading)) } }
        func end() {
            guard var value = reading else { return }
            value.sample.positionMilliseconds = duration; value.sample.status = .other
            reading = value
            onEvent?(.ended(value))
        }
    }

    /// A library graph in a temporary root: the registry with one ready server library, the standalone library's
    /// store and player, and a switcher whose restart stops the player and reopens through the registry.
    @MainActor private final class Graph {
        let root: URL
        let registry: LibraryRegistryFile
        let store: FeedLibraryStore
        let engine = Engine()
        let player: PlaybackCoordinator
        var castBlocks = false
        var foreground = true
        private(set) var restarts: [String] = []
        let opened: AsyncStream<LibraryReference>
        private let openedContinuation: AsyncStream<LibraryReference>.Continuation
        var switcher: LibrarySwitcher!
        var observation: Task<Void, Never>?
        var episodes: [Int64] = []
        /// Runs inside the teardown after the player stopped, where the app awaits the downloads' shutdown.
        var duringTeardown: (@MainActor () async -> Void)?
        /// Whether the player's commands were already closed when the teardown began (the switcher's retire step).
        private(set) var retiredAtTeardown: [Bool] = []

        /// `streaming`: every episode needs streaming over a network where it is not allowed (the Stream dialog).
        /// `observes`: the switch is re-checked after each player state change, as in the app.
        init(streaming: Bool = false, observes: Bool = true) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySwitching-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            registry = LibraryRegistryFile(root: root)
            var saved = LibraryRegistry()
            saved.libraries = [.init(id: LibrarySwitchingTests.serverID, serverURL: "https://sync.example.test", serverID: "server-1",
                                     accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f", username: "alice", state: .ready, createdAt: 1)]
            try registry.write(saved)
            try LibraryLocation(root: root, reference: .server(LibrarySwitchingTests.serverID)).prepare()
            store = try FeedLibraryStore(url: LibraryLocation(root: root, reference: .standalone).database)
            let parsed = ["A", "B"].map { letter in
                ParsedEpisode(identifier: letter, title: "Episode " + letter,
                              media: ParsedMedia(url: "https://example.test/\(letter).mp3", size: 0, durationMilliseconds: 20_000))
            }
            _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Switch lab", episodes: parsed),
                source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                validator: nil, permanentRedirectURL: nil))
            episodes = try await store.snapshot().feeds.flatMap(\.episodes).sorted { ($0.details.title ?? "") < ($1.details.title ?? "") }.map(\.id)
            if streaming {
                player = PlaybackCoordinator(store: store, engine: engine, streamingAccess: { _ in
                    PlaybackStreamingAccess(needsStreaming: true, streamingAllowed: false)
                })
            } else { player = PlaybackCoordinator(store: store, engine: engine) }
            (opened, openedContinuation) = AsyncStream<LibraryReference>.makeStream()
            switcher = LibrarySwitcher(registry: registry, activation: { [weak self] in
                LibraryActivationState(self?.player, castBlocks: self?.castBlocks ?? true)
            }, allowed: { [weak self] in self?.foreground ?? false }, settle: { [weak self] in await self?.player.settle() },
               retire: { [weak self] in self?.player.retire() }, restart: { [weak self] in await self?.restart() })
            switcher.opened(try registry.openingLibrary())
            if observes { observation = switcher.observe(player) }
        }

        /// What `stopLibraryGraph` and `startLibraryGraph` do for a switch: the player stops before anything else
        /// changes, and the start applies the recorded switch before a library opens.
        private func restart() async {
            restarts.append("stop while \(String(describing: (try? registry.read())?.active))")
            retiredAtTeardown.append(player.isRetired)
            observation?.cancel()
            await player.retire().value
            await duringTeardown?()
            let library = (try? registry.openingLibrary()) ?? .standalone
            restarts.append("open \(library)")
            switcher.opened(library)
            openedContinuation.yield(library)
        }

        func settle() async throws { try await player.awaitPendingOperations() }
        var pending: LibraryRegistry.PendingSwitch? { (try? registry.read())?.pendingSwitch }

        func close() async {
            observation?.cancel()
            try? await store.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func waitForSwitch(_ graph: Graph) async -> LibraryReference? {
        var iterator = graph.opened.makeAsyncIterator()
        return await iterator.next()
    }

    /// The rule itself: every condition that blocks a switch.
    @Test func activationRuleBlocksPlaybackPreparationInterruptionsPendingCommandsAndCast() {
        #expect(LibraryActivationState().permitsSwitch, "nothing loaded")
        for phase in [PlaybackCoordinator.Phase.idle, .stopped, .paused, .failed, .awaitingStreamingConfirmation] {
            #expect(LibraryActivationState(phase: phase).permitsSwitch, "\(phase)")
        }
        for phase in [PlaybackCoordinator.Phase.preparing, .playing, .buffering] {
            #expect(!LibraryActivationState(phase: phase).permitsSwitch, "\(phase)")
        }
        #expect(!LibraryActivationState(wantsPlayback: true, phase: .paused).permitsSwitch, "playback wanted")
        #expect(!LibraryActivationState(phase: .paused, awaitsInterruptionResumption: true).permitsSwitch, "a call will resume it")
        #expect(!LibraryActivationState(phase: .paused, hasPendingCommands: true).permitsSwitch, "a Play just tapped")
        #expect(!LibraryActivationState(phase: .paused, castBlocks: true).permitsSwitch, "a Cast receiver holds this library's media")
        // What of playback holds it, as the waiting page names it; Cast and a queued command name their own wait.
        for phase in [PlaybackCoordinator.Phase.preparing, .playing, .buffering] {
            #expect(LibraryActivationState(phase: phase).playbackHold == .playing, "\(phase)")
        }
        #expect(LibraryActivationState(wantsPlayback: true, phase: .paused).playbackHold == .playing)
        #expect(LibraryActivationState(phase: .paused, awaitsInterruptionResumption: true).playbackHold == .resumingAfterInterruption)
        for phase in [PlaybackCoordinator.Phase.idle, .stopped, .paused, .failed, .awaitingStreamingConfirmation] {
            #expect(LibraryActivationState(phase: phase).playbackHold == nil, "\(phase)")
        }
        #expect(LibraryActivationState(phase: .paused, hasPendingCommands: true, castBlocks: true).playbackHold == nil)
    }

    /// Nothing plays: the switch runs when it is requested; the player was stopped before the registry changed.
    @Test func switchRunsAtOnceWhenNothingPlays() async throws {
        let graph = try await Graph()
        try await graph.switcher.request(.server(Self.serverID), reason: .attach)
        #expect(graph.restarts == ["stop while Optional(standalone)", "open \(Self.serverID)"])
        #expect(graph.pending == nil)
        #expect(try graph.registry.read().active == .server(Self.serverID))
        await graph.close()
    }

    /// Playing: the recorded switch waits; the person's pause runs it, after the player stopped.
    @Test func switchWaitsWhilePlayingAndRunsAtThePause() async throws {
        let graph = try await Graph()
        try await graph.player.select(episodeID: graph.episodes[0], play: true)
        #expect(graph.player.phase == .preparing)
        try await graph.switcher.request(.server(Self.serverID), reason: .attach)
        #expect(graph.restarts.isEmpty && graph.pending?.to == .server(Self.serverID), "preparing to play")
        graph.engine.ready(); try await graph.settle()
        #expect(graph.player.phase == .playing)
        #expect(await graph.switcher.attempt() == false)
        #expect(graph.restarts.isEmpty)
        try await graph.player.toggle()
        #expect(await waitForSwitch(graph) == .server(Self.serverID))
        #expect(graph.restarts.first == "stop while Optional(standalone)")
        #expect(graph.pending == nil && graph.switcher.openLibrary == .server(Self.serverID))
        await graph.close()
    }

    /// A phone call pauses the output, but playback resumes when it ends: no switch during the call. After the call
    /// resumes playback, the person's pause runs it.
    @Test func interruptionThatWillResumeHoldsTheSwitch() async throws {
        let graph = try await Graph()
        try await graph.player.select(episodeID: graph.episodes[0], play: true)
        graph.engine.ready(); try await graph.settle()
        try await graph.switcher.request(.server(Self.serverID), reason: .logout)
        graph.engine.interrupt(); try await graph.settle()
        #expect(graph.player.phase == .paused && !graph.player.wantsPlayback, "the coordinator alone sees a pause")
        #expect(graph.player.awaitsInterruptionResumption)
        #expect(await graph.switcher.attempt() == false)
        graph.engine.endInterruption(resume: true); try await graph.settle()
        #expect(graph.player.phase == .playing && !graph.player.awaitsInterruptionResumption)
        #expect(await graph.switcher.attempt() == false)
        #expect(graph.restarts.isEmpty)
        try await graph.player.pause()
        #expect(await waitForSwitch(graph) == .server(Self.serverID))
        await graph.close()
    }

    /// A call that ends without resuming (the system says not to) leaves playback paused: the next check, at the
    /// latest the scene's activation, runs the switch.
    @Test func interruptionThatEndsWithoutResumingAllowsTheSwitch() async throws {
        let graph = try await Graph()
        try await graph.player.select(episodeID: graph.episodes[0], play: true)
        graph.engine.ready(); try await graph.settle()
        try await graph.switcher.request(.server(Self.serverID), reason: .attach)
        graph.engine.interrupt(); try await graph.settle()
        #expect(await graph.switcher.attempt() == false)
        graph.engine.endInterruption(resume: false)
        #expect(!graph.player.awaitsInterruptionResumption)
        #expect(await graph.switcher.attempt())
        #expect(graph.switcher.openLibrary == .server(Self.serverID))
        await graph.close()
    }

    /// The end of the last episode, or a stop, satisfies the rule.
    @Test func endOfTheLastEpisodeRunsTheSwitch() async throws {
        let graph = try await Graph()
        try await graph.player.select(episodeID: graph.episodes[1], play: true)
        graph.engine.ready(); try await graph.settle()
        try await graph.switcher.request(.server(Self.serverID), reason: .attach)
        #expect(graph.restarts.isEmpty)
        graph.engine.end()
        #expect(await waitForSwitch(graph) == .server(Self.serverID))
        await graph.close()
    }

    /// The app's own conditions: a Cast receiver holding this library's media, or the app in the background, hold the
    /// switch until they clear.
    @Test func castAndBackgroundHoldTheSwitch() async throws {
        let graph = try await Graph()
        graph.castBlocks = true
        try await graph.switcher.request(.server(Self.serverID), reason: .attach)
        #expect(graph.restarts.isEmpty)
        graph.castBlocks = false; graph.foreground = false
        #expect(await graph.switcher.attempt() == false)
        graph.foreground = true
        #expect(await graph.switcher.attempt())
        #expect(graph.switcher.openLibrary == .server(Self.serverID))
        await graph.close()
    }

    /// The Stream dialog: Play on a network where streaming is not allowed leaves the player unloaded, asking; Cancel
    /// keeps it so. Nothing plays there without a tap, so a switch runs, and nothing plays afterwards.
    @Test func switchRunsWhileTheStreamDialogIsUpAndNothingPlaysAfterwards() async throws {
        let graph = try await Graph(streaming: true)
        try await graph.player.select(episodeID: graph.episodes[0], play: true)
        #expect(graph.player.phase == .awaitingStreamingConfirmation && !graph.player.wantsPlayback)
        #expect(graph.player.pendingStreamingEpisodeID == graph.episodes[0])
        // Cancel in the dialog sends nothing to the player: the phase stays.
        try await graph.switcher.request(.server(Self.serverID), reason: .logout)
        #expect(graph.restarts == ["stop while Optional(standalone)", "open \(Self.serverID)"])
        #expect(graph.switcher.openLibrary == .server(Self.serverID))
        #expect(graph.player.isRetired && !graph.player.hasPendingCommands)
        #expect(graph.engine.loads == 0 && graph.engine.plays == 0 && graph.engine.reading == nil)
        #expect(!graph.player.wantsPlayback && graph.player.phase != .playing && graph.player.phase != .preparing)
        await graph.close()
    }

    /// A player command still queued (here an engine report being handled) holds the switch; the switch waits for it
    /// to finish, then runs, even if that command publishes no further state change.
    @Test func queuedPlayerCommandIsWaitedFor() async throws {
        // Only the checks this test makes run, so nothing else can trigger the switch.
        let graph = try await Graph(observes: false)
        try await graph.player.select(episodeID: graph.episodes[0], play: true)
        graph.engine.ready(); try await graph.settle()
        try await graph.player.pause()
        graph.foreground = false
        try await graph.switcher.request(.server(Self.serverID), reason: .attach)
        graph.foreground = true
        graph.engine.report()
        #expect(graph.player.hasPendingCommands)
        #expect(!LibraryActivationState(graph.player, castBlocks: false).permitsSwitch)
        #expect(await graph.switcher.attempt())
        #expect(graph.switcher.openLibrary == .server(Self.serverID))
        await graph.close()
    }

    /// Checks that overlap at their waits (the page's "Stop playback and continue" and the check after each player
    /// state change) must not take each other's wait for the player's queue as a pending command and all give up: one
    /// of them runs the switch. The player's queue is modelled: a command is queued, and each wait queues an empty one.
    @Test func overlappingChecksDoNotGiveUpOnEachOther() async throws {
        @MainActor final class Queue { var command = true; var waits = 0; var restarts = 0; var switcher: LibrarySwitcher? }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OverlappingChecks-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = LibraryRegistryFile(root: root)
        var saved = LibraryRegistry()
        saved.libraries = [.init(id: Self.serverID, serverURL: "https://sync.example.test", serverID: "server-1",
                                 accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f", username: "alice", state: .ready, createdAt: 1)]
        try saved.recordSwitch(to: .server(Self.serverID), reason: .attach, at: 1)
        try registry.write(saved)
        let queue = Queue()
        let switcher = LibrarySwitcher(registry: registry, activation: {
            LibraryActivationState(phase: .paused, hasPendingCommands: queue.command || queue.waits > 0)
        }, settle: {
            queue.waits += 1
            await Task.yield(); queue.command = false; await Task.yield()
            queue.waits -= 1
        }, restart: {
            // As the graph start does: the recorded switch is applied and the new library opens.
            queue.restarts += 1
            queue.switcher?.opened((try? registry.openingLibrary()) ?? .standalone)
        })
        queue.switcher = switcher
        switcher.opened(.standalone)
        #expect(switcher.isPending)
        let first = Task { await switcher.attempt() }, second = Task { await switcher.attempt() }
        let results = [await first.value, await second.value]
        #expect(results.contains(true) && queue.restarts == 1, "\(results), restarts \(queue.restarts)")
    }

    /// Command admission closes in the same main-actor step as the final activation check, before any
    /// asynchronous teardown. A Play from the old screen while the teardown awaits (the app awaits the downloads'
    /// shutdown there) is refused: it never runs, nothing plays, and the switch completes.
    @Test func playDuringTheTeardownIsRefused() async throws {
        let graph = try await Graph(observes: false)
        try await graph.player.select(episodeID: graph.episodes[0], play: false)
        graph.engine.ready(); try await graph.settle()
        var refused: [String] = []
        graph.duringTeardown = {
            do { try await graph.player.play() } catch is CancellationError { refused.append("play") } catch { }
            do { try await graph.player.toggle() } catch is CancellationError { refused.append("toggle") } catch { }
            do { try await graph.player.select(episodeID: graph.episodes[1], play: true) }
            catch is CancellationError { refused.append("select") } catch { }
            graph.engine.ready()
        }
        try await graph.switcher.request(.server(Self.serverID), reason: .attach)
        #expect(graph.switcher.openLibrary == .server(Self.serverID))
        #expect(graph.retiredAtTeardown == [true], "admission closed by the switcher before its teardown began")
        #expect(refused == ["play", "toggle", "select"], "every command after the check is refused")
        #expect(graph.engine.plays == 0 && graph.engine.loads == 1, "nothing was started or loaded")
        #expect(!graph.player.wantsPlayback && graph.player.phase != .playing && graph.player.phase != .preparing)
        await graph.close()
    }

    /// The retired player refuses every later command; commands admitted before it still run, then playback stops.
    @Test func retiredPlayerRefusesLaterCommands() async throws {
        let graph = try await Graph(observes: false)
        try await graph.player.select(episodeID: graph.episodes[0], play: true)
        graph.engine.ready(); try await graph.settle()
        graph.engine.report() // An engine report, admitted (queued) before the retirement.
        #expect(graph.player.hasPendingCommands)
        let stopped = graph.player.retire()
        #expect(graph.player.retire() == stopped, "idempotent")
        await #expect(throws: CancellationError.self) { try await graph.player.play() }
        await #expect(throws: CancellationError.self) { try await graph.player.seek(to: 1_000) }
        await #expect(throws: CancellationError.self) { try await graph.player.setSpeed(1.5) }
        await stopped.value
        #expect(!graph.player.wantsPlayback && graph.player.phase == .stopped && graph.engine.reading == nil)
        #expect(graph.engine.plays == 1)
        await graph.close()
    }

    /// A registry that cannot be read for a moment leaves a recorded switch pending; the next trigger
    /// runs it. (Only this test's registry file changes permissions, and they are restored.)
    @Test func registryReadFailureKeepsTheSwitchPending() async throws {
        let graph = try await Graph(observes: false)
        graph.foreground = false
        try await graph.switcher.request(.server(Self.serverID), reason: .attach)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: graph.registry.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: graph.registry.url.path) }
        #expect(throws: (any Error).self) { _ = try graph.registry.read() }
        graph.foreground = true
        #expect(await graph.switcher.attempt() == false)
        #expect(graph.switcher.isPending, "still waiting")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: graph.registry.url.path)
        #expect(graph.pending?.to == .server(Self.serverID), "the recorded request is still on disk")
        #expect(await graph.switcher.attempt(), "the next trigger runs it")
        #expect(graph.switcher.openLibrary == .server(Self.serverID))
        await graph.close()
    }

    /// Requesting the library that is already open needs no restart.
    @Test func switchToTheOpenLibraryDoesNotRestart() async throws {
        let graph = try await Graph()
        try await graph.player.select(episodeID: graph.episodes[0], play: true)
        graph.engine.ready(); try await graph.settle()
        try await graph.switcher.request(.server(Self.serverID), reason: .attach)
        try await graph.switcher.request(.standalone, reason: .logout)
        #expect(graph.pending == nil && !graph.switcher.isPending)
        try await graph.player.pause()
        #expect(await graph.switcher.attempt() == false)
        #expect(graph.restarts.isEmpty && graph.player.phase == .paused)
        await graph.close()
    }
}

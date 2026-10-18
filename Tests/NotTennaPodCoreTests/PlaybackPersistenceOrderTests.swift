import Foundation
import Testing
@testable import NotTennaPodCore

// The store is held through `PlaybackCoordinator.storeGate`, a debug-only test boundary.
#if DEBUG
/// Pause and seek never wait for persistence-only work: while an earlier save waits for the store, the engine pauses
/// and seeks at once, yet every store write keeps its admission order, captures its own values, and fails at its own
/// position for the playback that made it. Each scenario runs twice, with engine stages hoisted and with the serial
/// reference (`hoistsEngineStages = false`, every engine stage in its turn), and compares the ordered store writes with
/// their values, the engine's commands, the player's state and the reopened library. The store is held at the
/// coordinator's boundary (`storeGate`), on conditions, never by sleeping.
@MainActor @Suite(.serialized)
struct PlaybackPersistenceOrderTests {
    final class Engine: PlaybackEngine {
        enum Command: Equatable, CustomStringConvertible {
            case load(Int64, Int64), play, pause, seek(Int64), unload
            var description: String {
                switch self {
                case .load(let id, let position): "load \(id)@\(position)"
                case .play: "play"
                case .pause: "pause"
                case .seek(let position): "seek \(position)"
                case .unload: "unload"
                }
            }
        }
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        var commands: [Command] = []
        var generation: UUID?
        var commandID: UUID?
        var initialPosition: Int64 = 0
        var wantsPlayback = false

        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            self.generation = generation; commandID = generation
            initialPosition = positionMilliseconds; reading = nil; wantsPlayback = false
            commands.append(.load(episode.id, positionMilliseconds))
        }
        func play(commandID: UUID) {
            wantsPlayback = true; self.commandID = commandID
            reading?.commandID = commandID; reading?.sample.status = .playing
            commands.append(.play)
        }
        func pause(commandID: UUID) {
            wantsPlayback = false; self.commandID = commandID
            reading?.commandID = commandID; reading?.sample.status = .paused
            commands.append(.pause)
        }
        func seek(to positionMilliseconds: Int64, commandID: UUID) {
            self.commandID = commandID
            reading?.commandID = commandID
            reading?.sample.positionMilliseconds = Int32(truncatingIfNeeded: positionMilliseconds)
            commands.append(.seek(positionMilliseconds))
        }
        func setSpeed(_ speed: Float, commandID: UUID) throws {
            self.commandID = commandID; reading?.speed = speed; reading?.commandID = commandID
        }
        func unload() {
            commands.append(.unload)
            reading = nil; generation = nil; commandID = nil; wantsPlayback = false
        }
        func ready(duration: Int32 = 100_000) {
            guard let generation, let commandID else { return }
            let value = PlaybackEngineReading(generation: generation, commandID: commandID,
                sample: .init(positionMilliseconds: Int32(truncatingIfNeeded: initialPosition), durationMilliseconds: duration,
                              status: wantsPlayback ? .playing : .paused))
            reading = value
            onEvent?(.ready(value))
        }
        func position(_ position: Int32) {
            guard var value = reading else { return }
            value.sample.positionMilliseconds = position
            reading = value
            onEvent?(.position(value))
        }
        func state(_ status: LibraryPlaybackSession.Status, buffering: Bool = false) {
            guard var value = reading else { return }
            value.sample.status = status; value.buffering = buffering
            reading = value
            onEvent?(.stateChanged(value))
        }
        func reset(after position: Int32) {
            guard var value = reading else { return }
            value.sample.positionMilliseconds = position
            let final = value
            value.sample.positionMilliseconds = 0
            reading = value
            onEvent?(.timelineReset(final))
        }
    }

    struct InjectedFailure: Error {}

    /// The coordinator's store writes, in order, with the ones a scenario selects held until released.
    @MainActor final class Gate {
        private(set) var trace: [PlaybackStoreCall] = []
        private var holds: [(PlaybackStoreCall) -> Bool] = []
        private var held: [CheckedContinuation<Void, any Error>] = []
        var isHolding: Bool { !held.isEmpty }

        /// The next write `matching` selects waits for `release`.
        func hold(_ matching: @escaping (PlaybackStoreCall) -> Bool) { holds.append(matching) }

        func pass(_ call: PlaybackStoreCall) async throws {
            trace.append(call)
            guard let index = holds.firstIndex(where: { $0(call) }) else { return }
            holds.remove(at: index)
            try await withCheckedThrowingContinuation { held.append($0) }
        }

        /// Lets the oldest held write go on, or fails it as the store would.
        func release(failing: Bool = false) {
            let continuation = held.removeFirst()
            if failing { continuation.resume(throwing: InjectedFailure()) } else { continuation.resume() }
        }
    }

    final class Clock {
        var milliseconds: Int64 = 1_700_000_000_000
        var date: Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
    }

    /// A test's view of one run.
    @MainActor final class Run {
        let store: FeedLibraryStore, player: PlaybackCoordinator, engine: Engine, gate: Gate, clock: Clock
        let hoisting: Bool
        /// The library's episodes, oldest first (1, 2, 3 in a standalone library).
        var ids: [Int64] = [1, 2, 3]
        var events: [String] = []
        /// Streaming checks while `holdsAccess`: each waits for `releaseAccess`.
        var holdsAccess = false
        var access: [CheckedContinuation<Void, Never>] = []

        init(store: FeedLibraryStore, player: PlaybackCoordinator, engine: Engine, gate: Gate, clock: Clock, hoisting: Bool) {
            self.store = store; self.player = player; self.engine = engine; self.gate = gate; self.clock = clock
            self.hoisting = hoisting
        }

        func releaseAccess() { access.removeFirst().resume() }

        /// Waits (by condition, yielding the main actor) until `condition` holds.
        func until(_ what: String, _ condition: () -> Bool) async throws {
            for _ in 0..<200_000 {
                if condition() { return }
                await Task.yield()
            }
            Issue.record("never: \(what)")
            throw CancellationError()
        }

        /// Until the coordinator has done all it can now: `admitted` commands and events wait, and when hoisting no
        /// engine stage that could run still waits (its earlier admissions residual).
        func quiet(admitted: Int) async throws {
            try await until("\(admitted) admitted") { player.admissionsForTesting.admitted == admitted }
            for _ in 0..<50 { await Task.yield() }
        }

        /// A playing episode whose first five-second save is due on the next position.
        func playing(_ id: Int64? = nil) async throws {
            try await player.select(episodeID: id ?? ids[0])
            engine.ready()
            try await player.awaitPendingOperations()
            clock.milliseconds += 5_000
        }
    }

    struct Outcome: Equatable, CustomStringConvertible {
        var writes: [String], commands: [String], player: String, events: [String], stored: [String]
        /// A server library's: its sync sessions (journal, bases, exports and contributions) and its exported facts in order.
        var sessions: [String] = [], facts: [String] = []
        var description: String {
            "writes \(writes)\ncommands \(commands)\nplayer \(player)\nevents \(events)\nstored \(stored)\nsessions \(sessions)\nfacts \(facts)"
        }
    }

    /// A server library both runs start from: copies of one registered library, so the account, podcast, generation
    /// and episode identities and everything recorded before the run are the same literal values in both.
    struct ServerBase {
        let fixture: ServerLibraryFixture
        let ids: [Int64]
        /// The UUIDs the base already holds: stable, never renamed.
        let stable: Set<String>
        @MainActor static func make() async throws -> ServerBase {
            let fixture = try await ServerLibraryFixture()
            let ids = try await fixture.subscribeRegistered().feed.episodes.map(\.id).sorted()
            let text = try RefreshSharedReadsDifferentialTests.dump(fixture.url).map(\.text).joined(separator: "\n")
            let stable = Set(uuid.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!]).uppercased()
            })
            return ServerBase(fixture: fixture, ids: ids, stable: stable)
        }
    }

    static let clientTime = try! NSRegularExpression(pattern: "\\\\?\"client_time\\\\?\":([0-9]+)")
    static let uuid = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    static let queueMember = try! NSRegularExpression(pattern: "\"key\":\"(q1:[0-9]+:[0-9a-f]+)\",\"position_id\":\"([0-9A-Fa-f-]{36})\"")

    /// A queue member's key checked against its position write (PROTOCOL §3.6): a valid key whose numerator carries the
    /// position ID's residue 2U + 1 (mod 2^129) is written with its exponent and the numerator's part above the residue,
    /// which the interval decides; any other key stays visible as invalid. Keys in one text must ascend.
    static func checkedQueueKeys(_ text: String) -> String {
        var result = text, keys: [QueueKey] = []
        for match in queueMember.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let wire = String(text[Range(match.range(at: 1), in: text)!])
            let position = String(text[Range(match.range(at: 2), in: text)!])
            var checked = "q1:INVALID(\(wire))"
            if let key = try? QueueKey(wire: wire), let id = UUID(uuidString: position) {
                let u = id.uuid
                let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
                let residue = (ContractBigUInt(bytes: bytes) << 1) + ContractBigUInt(1)
                if key.numerator.lowBits(129) == residue {
                    checked = "q1:\(key.exponent):\((key.numerator >> 129).hex)+residue"
                    keys.insert(key, at: 0)
                } else {
                    checked = "q1:WRONG-RESIDUE(\(wire))"
                }
            }
            result.replaceSubrange(Range(match.range(at: 1), in: result)!, with: checked)
        }
        if zip(keys, keys.dropFirst()).contains(where: { !($0 < $1) }) { result += " <queue keys out of order>" }
        return result
    }

    /// Renames, by order of appearance, only the UUIDs a run created (session, generation, op and position-write IDs),
    /// and writes a fact's wall-clock `client_time` as T: UUIDs in `stable` and every other value stay literal. Queue keys
    /// are checked first (`checkedQueueKeys`).
    static func normalized(_ texts: [[String]], stable: Set<String> = []) -> [[String]] {
        var names: [String: String] = [:]
        return texts.map { list in
            list.map { original in
                let text = checkedQueueKeys(original)
                var result = text
                for match in uuid.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                    let value = String(text[Range(match.range, in: text)!]).uppercased()
                    guard !stable.contains(value) else { continue }
                    let name = names[value] ?? "id\(names.count)"
                    names[value] = name
                    result.replaceSubrange(Range(match.range, in: result)!, with: name)
                }
                // A fact's `client_time` taken from the wall clock (a load's queue add), not the test's clock: T.
                let timed = result, now = Date().timeIntervalSince1970 * 1_000
                for match in clientTime.matches(in: timed, range: NSRange(timed.startIndex..., in: timed)).reversed() {
                    if let value = Double(timed[Range(match.range(at: 1), in: timed)!]), abs(value - now) < 2 * 86_400_000 {
                        result.replaceSubrange(Range(match.range(at: 1), in: result)!, with: "T")
                    }
                }
                // A fact's dependencies are sorted by their random values: their names, sorted.
                let lists = try! NSRegularExpression(pattern: "\\[(\"id[0-9]+\"(,\"id[0-9]+\")*)\\]")
                let named = result
                for match in lists.matches(in: named, range: NSRange(named.startIndex..., in: named)).reversed() {
                    let inner = String(named[Range(match.range(at: 1), in: named)!])
                    result.replaceSubrange(Range(match.range, in: result)!, with: "[\(inner.split(separator: ",").sorted().joined(separator: ","))]")
                }
                return result
            }
        }
    }

    /// Runs `scenario` on a fresh library with hoisting on or off; returns what it did, after the reopened library.
    /// `server`: a server library (PROTOCOL §8) with a registered podcast, whose pauses and stops save synchronized as
    /// the app's do; its sync sessions and exported facts are compared too.
    /// `alter`: a change made to the server library after the scenario, before it is read (the oracle's own tests).
    static func run(hoisting: Bool, server base: ServerBase? = nil, alter: ((ServerLibraryFixture) async throws -> Void)? = nil,
                    _ scenario: (Run) async throws -> Void) async throws -> Outcome {
        let directory: URL, url: URL, store: FeedLibraryStore, ids: [Int64]
        var fixture: ServerLibraryFixture?
        let server = base != nil
        if let base {
            let library = try await base.fixture.copy()
            fixture = library
            directory = library.directory; url = library.url; store = library.store
            ids = base.ids
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("PersistenceOrder-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("library.sqlite")
            store = try FeedLibraryStore(url: url)
            let episodes = (1...3).map {
                ParsedEpisode(identifier: "\($0)", title: "Episode \($0)",
                              media: ParsedMedia(url: "https://example.test/\($0).mp3", size: 0, durationMilliseconds: 100_000))
            }
            _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Order", episodes: episodes),
                                                  source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                                                  validator: nil, permanentRedirectURL: nil))
            ids = [1, 2, 3]
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = Engine(), gate = Gate(), clock = Clock()
        var runReference: Run?
        let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
            var preferences = PlaybackPreferences(); preferences.end.synchronize = server; return preferences
        }, streamingAccess: { _ in
            if let run = runReference, run.holdsAccess { await withCheckedContinuation { run.access.append($0) } }
            return .init(needsStreaming: false, streamingAllowed: true)
        }, clock: { clock.date }, monotonicClock: { clock.milliseconds })
        player.hoistsEngineStages = hoisting
        player.storeGate = { call in try await gate.pass(call) }
        let run = Run(store: store, player: player, engine: engine, gate: gate, clock: clock, hoisting: hoisting)
        run.ids = ids
        runReference = run
        let listener = Task { @MainActor in
            for await event in player.events() {
                switch event {
                case .storageFailed: run.events.append("storageFailed")
                case .engineFailed: run.events.append("engineFailed")
                default: break
                }
            }
        }
        defer { listener.cancel() }
        do { try await scenario(run) } catch { await player.settle(); try? await store.close(); throw error }
        await player.settle()
        if let fixture, let alter { try await alter(fixture) }
        let writes = gate.trace.map { String(describing: $0) }
        let state = "\(player.episode?.id ?? 0) \(player.phase) wants \(player.wantsPlayback) sample \(String(describing: player.sample))"
        player.storeGate = nil
        try await store.close()
        let reopened = try FeedLibraryStore(url: url)
        var stored: [String] = []
        for id in ids {
            let user = try #require(try await reopened.episode(id: id)).userState
            stored.append("\(id): position \(user.positionMilliseconds) played \(user.playedDurationMilliseconds) "
                          + "last \(user.lastPlayedTimeMilliseconds) state \(user.playState)")
        }
        if let session = try await reopened.playbackSession() {
            stored.append("session \(session.id) \(session.episodeID) start \(session.startPositionMilliseconds) "
                          + "base \(session.playedDurationWhenStarted) \(session.status)")
        }
        try await reopened.close()
        var sessions: [String] = [], facts: [String] = []
        if let fixture {
            // Records as JSON with sorted keys (their encoding's member order is not part of them).
            func sorted(_ text: String?) -> String {
                guard let text, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return text ?? "NULL" }
                return String(decoding: data, as: UTF8.self)
            }
            sessions = try fixture.rows("SELECT state, incarnation, CAST(record AS TEXT) FROM ntp_sessions ORDER BY rowid").map {
                "\($0[0] ?? "NULL") | \($0[1] ?? "NULL") | \(sorted($0[2]))"
            }
            facts = try fixture.rows("SELECT type, CAST(fact AS TEXT) FROM ntp_outbox ORDER BY install_seq").map { $0.map { $0 ?? "NULL" }.joined(separator: " | ") }
        }
        let lists = normalized([writes, engine.commands.map(\.description), [state], run.events, stored, sessions, facts],
                               stable: base?.stable ?? [])
        return Outcome(writes: lists[0], commands: lists[1], player: lists[2][0], events: lists[3], stored: lists[4],
                       sessions: lists[5], facts: lists[6])
    }

    /// Both runs, compared (`engineCommands`: the engine's commands may differ, as the test then checks).
    @discardableResult
    static func compare(engineCommands: Bool = true, server: Bool = false,
                        _ scenario: (Run) async throws -> Void) async throws -> (Outcome, Outcome) {
        let base = server ? try await ServerBase.make() : nil
        defer { if let base { Task { await base.fixture.close() } } }
        let hoisted = try await run(hoisting: true, server: base, scenario)
        let serial = try await run(hoisting: false, server: base, scenario)
        var compared = hoisted
        if !engineCommands { compared.commands = serial.commands }
        #expect(compared == serial, "hoisted:\n\(hoisted)\nserial:\n\(serial)")
        return (hoisted, serial)
    }

    static func isSave(_ call: PlaybackStoreCall) -> Bool { if case .recordPlayback = call { true } else { false } }

    /// A five-second save waits for the store; pause and then seek are pressed. The engine pauses and seeks before the
    /// save is written; the pause's save still writes the paused position, after the earlier save, and the seek's
    /// record follows it.
    @Test func pauseThenSeekMoveTheEngineWhileAnEarlierSaveWaits() async throws {
        let (outcome, _) = try await Self.compare { run in
            try await run.playing()
            run.gate.hold(Self.isSave)
            run.engine.position(12_000)
            try await run.until("the five-second save waits") { run.gate.isHolding }
            run.clock.milliseconds += 300
            let pausing = Task { try await run.player.pause() }
            let seeking = Task { try await run.player.seek(to: 50_000) }
            try await run.quiet(admitted: 3)
            if run.hoisting {
                #expect(run.engine.commands.suffix(2) == [.pause, .seek(50_000)], "both reach the engine while the save waits")
                #expect(run.player.phase == .paused && !run.player.wantsPlayback, "the button shows paused at once")
                #expect(run.player.sample?.positionMilliseconds == 50_000)
            } else {
                #expect(run.engine.commands.last == .play, "the serial reference waits")
            }
            #expect(run.gate.trace.count(where: Self.isSave) == 2, "the save of the start and the held one only")
            run.gate.release()
            try await pausing.value; try await seeking.value
        }
        #expect(outcome.writes.suffix(3).map { $0.prefix(16) } == ["recordPlayback(s", "recordPlayback(s", "recordSeekIntent"])
        #expect(outcome.writes.dropLast().last?.contains("positionMilliseconds: 12000") == true, "the pause saved where it paused")
        #expect(outcome.stored[0].hasPrefix("1: position 12000"))
    }

    /// Two seeks while a save waits: both reach the engine at once, and their records keep their order and values.
    @Test func seekThenSeek() async throws {
        let (outcome, _) = try await Self.compare { run in
            try await run.playing()
            run.gate.hold(Self.isSave)
            run.engine.position(12_000)
            try await run.until("the five-second save waits") { run.gate.isHolding }
            let first = Task { try await run.player.seek(to: 30_000) }
            let second = Task { try await run.player.seek(to: 60_000) }
            try await run.quiet(admitted: 3)
            if run.hoisting { #expect(run.engine.commands.suffix(2) == [.seek(30_000), .seek(60_000)]) }
            run.gate.release()
            try await first.value; try await second.value
        }
        #expect(outcome.writes.suffix(2).allSatisfy { $0.hasPrefix("recordSeekIntent") })
        #expect(outcome.writes.last?.contains("from: 30000, to: 60000") == true)
    }

    /// Play waits for its streaming check, Pause is pressed meanwhile, then Play's recording waits for the store.
    /// Pause reaches the engine before that recording is written, though it was admitted before Play became residual.
    @Test func resumeThenPausePausesWhilePlaysRecordingWaits() async throws {
        let (outcome, _) = try await Self.compare { run in
            try await run.player.select(episodeID: 1, play: false)
            run.engine.ready()
            try await run.player.awaitPendingOperations()
            run.holdsAccess = true
            run.gate.hold { if case .recordPlaybackIntent = $0 { true } else { false } }
            let playing = Task { try await run.player.play() }
            try await run.until("Play waits for its streaming check") { !run.access.isEmpty }
            let pausing = Task { try await run.player.pause() }
            try await run.quiet(admitted: 2)
            #expect(run.engine.commands.last != .play, "Play has not reached the engine yet")
            run.releaseAccess()
            try await run.until("Play's recording waits") { run.gate.isHolding }
            try await run.quiet(admitted: 2)
            if run.hoisting {
                #expect(run.engine.commands.suffix(2) == [.play, .pause], "Pause reached the engine while Play's recording waits")
                #expect(run.player.phase == .paused)
            } else {
                #expect(run.engine.commands.last == .play, "the serial reference waits")
            }
            run.gate.release()
            try await playing.value; try await pausing.value
        }
        #expect(outcome.writes.suffix(2).map { $0.prefix(20) } == ["recordPlaybackIntent", "recordPlayback(sessi"])
    }

    /// A five-second save P, a buffering end's save B and a timeline reset R: P waits for the store, B's engine stage
    /// runs at once, R waits for both: the store sees P, B, R, and the reset's accounting is today's.
    @Test func periodicSaveBufferingEndAndTimelineResetKeepTheirOrder() async throws {
        let (outcome, _) = try await Self.compare { run in
            try await run.playing()
            run.gate.hold(Self.isSave)
            run.engine.position(12_000)
            try await run.until("the five-second save waits") { run.gate.isHolding }
            run.engine.state(.playing, buffering: true)
            run.clock.milliseconds += 1_000
            run.engine.state(.playing, buffering: false)
            run.clock.milliseconds += 1_000
            run.engine.reset(after: 15_000)
            try await run.quiet(admitted: 4)
            // Both state reports ran their engine stages at once; the serial reference still has them waiting.
            #expect(run.player.admissionsForTesting.stagesWaiting == (run.hoisting ? 0 : 2))
            #expect(!run.gate.trace.contains { if case .timelineReset = $0 { true } else { false } }, "the reset waits")
            run.gate.release()
        }
        let tail = outcome.writes.suffix(3)
        #expect(tail.map { $0.prefix(14) } == ["recordPlayback", "recordPlayback", "timelineReset("])
        #expect(outcome.stored[0].hasPrefix("1: position 0"), "\(outcome.stored)")
    }

    /// A five-second save fails after the person chose another episode: playback of the first fails in its turn, then
    /// the second loads and plays, as in the serial reference (the failure is not appended after the switch).
    @Test func anOldSavesFailureFailsItsOwnPlaybackBeforeASwitch() async throws {
        let (outcome, _) = try await Self.compare { run in
            try await run.playing()
            run.gate.hold(Self.isSave)
            run.engine.position(12_000)
            try await run.until("the five-second save waits") { run.gate.isHolding }
            let switching = Task { try await run.player.select(episodeID: 2) }
            try await run.quiet(admitted: 2)
            run.gate.release(failing: true)
            try await switching.value
            run.engine.ready()
            try await run.player.awaitPendingOperations()
            #expect(run.player.episode?.id == 2 && run.player.phase == .playing, "the second plays")
        }
        #expect(outcome.events == ["storageFailed"])
    }

    /// A save fails while a pause admitted after it already moved the engine: playback fails in the failed save's turn
    /// showing what it failed to save, and the pause's own save, for that retired playback, is not written.
    @Test func aFailureBeforeAHoistedPauseRetiresItsSave() async throws {
        let (outcome, serial) = try await Self.compare(engineCommands: false) { run in
            try await run.playing()
            run.gate.hold(Self.isSave)
            run.engine.position(12_000)
            try await run.until("the five-second save waits") { run.gate.isHolding }
            run.engine.position(13_000)
            let pausing = Task { try await run.player.pause() }
            try await run.quiet(admitted: 3)
            run.gate.release(failing: true)
            try await pausing.value
            #expect(run.player.phase == .failed)
        }
        #expect(outcome.writes.count(where: { $0.hasPrefix("recordPlayback(") }) == 2, "the start's and the failed one")
        // The hoisted pause reached the engine before the failure, which then paused and unloaded it as in the serial run.
        #expect(outcome.commands.suffix(3) == ["pause", "pause", "unload"] && serial.commands.suffix(2) == ["pause", "unload"])
        #expect(outcome.player.contains("positionMilliseconds: 12000"), "it shows the sample it failed to save: \(outcome.player)")
    }

    /// A position reset and a media deletion wait behind a pending five-second save: the reset position stays 0, no
    /// storage failure, and the player is idle.
    @Test(arguments: [false, true]) func resetOrDeletionWaitsBehindAPendingSave(deletion: Bool) async throws {
        let (outcome, _) = try await Self.compare { run in
            try await run.playing()
            run.gate.hold(Self.isSave)
            run.engine.position(12_000)
            try await run.until("the five-second save waits") { run.gate.isHolding }
            let resetting = Task {
                if deletion { try await run.player.deleteDownloadedMedia(episodeID: 1) }
                else { try await run.player.resetPlaybackPosition(episodeID: 1) }
            }
            try await run.quiet(admitted: 2)
            #expect(run.gate.trace.count == 4, "the load's, the start's two, then the held save; the reset waits")
            run.gate.release()
            try await resetting.value
            #expect(run.player.phase == .idle)
        }
        #expect(outcome.events.isEmpty)
        if !deletion { #expect(outcome.stored[0].hasPrefix("1: position 0")) }
    }

    /// A load still running (its store write held) is never overtaken: a pause admitted meanwhile reaches the engine
    /// only after the new episode is loaded, and applies to it.
    @Test func aPauseNeverOvertakesALoad() async throws {
        let (outcome, _) = try await Self.compare { run in
            try await run.playing()
            run.gate.hold { if case .beginPlayback = $0 { true } else { false } }
            let switching = Task { try await run.player.select(episodeID: 2) }
            try await run.until("the load's write waits") { run.gate.isHolding }
            let pausing = Task { try await run.player.pause() }
            try await run.quiet(admitted: 2)
            #expect(!run.engine.commands.contains(.load(2, 0)))
            #expect(run.engine.commands.last == .unload, "nothing reached the engine after the old episode's unload")
            run.gate.release()
            try await switching.value; try await pausing.value
            #expect(run.player.episode?.id == 2 && !run.player.wantsPlayback)
        }
        #expect(outcome.commands.suffix(3) == ["load 2@0", "play", "pause"])
    }

    /// A Cast restoration's selection on a new route (`selectOnRoute`) is opaque: a seek pressed while its pause's save
    /// waits never reaches the engine before it. The restoration then gives up for that newer command, before
    /// retiring anything or installing its route, and the seek lands on the item still loaded.
    @Test func aSeekNeverOvertakesARouteSelection() async throws {
        let (outcome, _) = try await Self.compare { run in
            try await run.playing()
            run.engine.position(10_000)
            try await run.player.awaitPendingOperations()
            run.gate.hold(Self.isSave)
            final class Activations { var count = 0 }
            let activated = Activations()
            let restoring = Task {
                try await run.player.selectOnRoute(episodeID: run.ids[0], positionMilliseconds: 60_000,
                                                   activateRoute: { activated.count += 1 }, isCurrent: { true })
            }
            try await run.until("the restoration's pause saves") { run.gate.isHolding }
            let seeking = Task { try await run.player.seek(to: 70_000) }
            try await run.quiet(admitted: 2)
            #expect(run.engine.commands.last == .pause, "the seek waits for the restoration")
            run.gate.release()
            await #expect(throws: CancellationError.self) { try await restoring.value }
            try await seeking.value
            #expect(activated.count == 0 && run.engine.commands.last == .seek(70_000) && run.engine.generation != nil)
            #expect(run.player.episode?.id == run.ids[0] && run.player.sample?.positionMilliseconds == 70_000)
        }
        #expect(outcome.commands.suffix(2) == ["pause", "seek 70000"], "nothing retired or reloaded: \(outcome.commands)")
    }

    /// A route's streaming refusal is opaque: a seek pressed while its pause's save waits never reaches the engine
    /// before it, and then finds the item retired for the confirmation.
    @Test func aSeekNeverOvertakesAStreamingRefusal() async throws {
        let (outcome, _) = try await Self.compare { run in
            try await run.playing()
            run.gate.hold(Self.isSave)
            run.engine.onEvent?(.streamingConfirmationRequired(generation: try #require(run.engine.generation)))
            try await run.until("the refusal's pause saves") { run.gate.isHolding }
            let seeking = Task { try await run.player.seek(to: 70_000) }
            try await run.quiet(admitted: 2)
            #expect(run.engine.commands.last == .pause, "the seek waits for the refusal")
            run.gate.release()
            try await seeking.value
            #expect(run.player.phase == .awaitingStreamingConfirmation && run.player.pendingStreamingEpisodeID == run.ids[0])
        }
        #expect(outcome.commands.suffix(2) == ["pause", "unload"])
    }

    /// A pending save, then a switch: the first episode's save result applies before the switch runs, never to the
    /// second episode.
    @Test func aSavesResultAppliesOnlyToItsPlayback() async throws {
        try await Self.compare { run in
            try await run.playing()
            run.gate.hold(Self.isSave)
            run.engine.position(12_000)
            try await run.until("the five-second save waits") { run.gate.isHolding }
            run.engine.position(13_000)
            let switching = Task { try await run.player.select(episodeID: 2) }
            try await run.quiet(admitted: 3)
            run.gate.release()
            try await switching.value
            #expect(run.player.episode?.id == 2)
            #expect(run.player.episode?.userState.positionMilliseconds == 0)
        }
    }

    /// Retirement (a library switch) with a save pending: the save is written, then the stop's, then retirement ends.
    @Test func retirementDrainsAPendingSave() async throws {
        let (outcome, _) = try await Self.compare { run in
            try await run.playing()
            run.gate.hold(Self.isSave)
            run.engine.position(12_000)
            try await run.until("the five-second save waits") { run.gate.isHolding }
            run.engine.position(13_000)
            let retirement = run.player.retire()
            try await run.quiet(admitted: 3)
            run.gate.release()
            await retirement.value
            #expect(run.player.phase == .stopped && run.player.isRetired)
        }
        #expect(outcome.writes.suffix(2).allSatisfy { $0.hasPrefix("recordPlayback") })
        #expect(outcome.stored[0].hasPrefix("1: position 13000"))
    }

    // MARK: - A server library with a minute export due (PROTOCOL §8.2)

    /// Playing a server library's episode for a minute: the next position's save exports the minute's checkpoint
    /// (durable), and it waits for the store.
    static func minuteExportHeld(_ run: Run) async throws {
        try await run.playing()
        run.clock.milliseconds += 55_000
        run.gate.hold(Self.isSave)
        run.engine.position(60_000)
        try await run.until("the minute's save waits") { run.gate.isHolding }
    }

    /// Retirement (a library switch) while the minute export waits: the export is written, then the stop's synchronized
    /// save, then retirement ends; the reopened library's sessions, exported facts and played time are the serial run's.
    @Test func serverRetirementDrainsAPendingMinuteExport() async throws {
        let (outcome, _) = try await Self.compare(server: true) { run in
            try await Self.minuteExportHeld(run)
            run.engine.position(61_000)
            let retirement = run.player.retire()
            try await run.quiet(admitted: 3)
            run.gate.release()
            await retirement.value
            #expect(run.player.phase == .stopped && run.player.isRetired)
        }
        #expect(outcome.facts.filter { $0.hasPrefix("session.checkpoint") }.count >= 2, "the minute's export and the stop's: \(outcome.facts)")
        #expect(outcome.stored[0].contains("position 61000 played 61000"), "\(outcome.stored)")
    }

    /// The comparison's own checks: a queue export whose key no longer carries its position write's residue (here
    /// `q1:1:1` beside the real `position_id`, the fact's content hash recomputed) does not compare equal to the same run.
    @Test func corruptServerQueueExportFailsTheComparison() async throws {
        let base = try await ServerBase.make()
        defer { Task { await base.fixture.close() } }
        let scenario: (Run) async throws -> Void = { run in
            try await Self.minuteExportHeld(run)
            run.engine.position(61_000)
            let retirement = run.player.retire()
            try await run.quiet(admitted: 3)
            run.gate.release()
            await retirement.value
        }
        let intact = try await Self.run(hoisting: true, server: base, scenario)
        var replaced: String?
        let corrupt = try await Self.run(hoisting: true, server: base, alter: { fixture in
            let row = try #require(try fixture.rows("SELECT install_seq, CAST(fact AS TEXT) FROM ntp_outbox WHERE type = 'queue.add' ORDER BY install_seq DESC LIMIT 1").first)
            let text = try #require(row[1])
            let match = try #require(Self.queueMember.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
            let key = String(text[Range(match.range(at: 1), in: text)!])
            let fact = text.replacingOccurrences(of: "\"key\":\"\(key)\"", with: "\"key\":\"q1:1:1\"")
            let hash = try ContractHash.contentHash(try ContractJSON.decode(Data(fact.utf8)))
            try await fixture.store.executeForTesting("UPDATE ntp_outbox SET fact = CAST(? AS BLOB), content_hash = ? WHERE install_seq = ?",
                                                      [.text(fact), .text(hash), .integer(Int64(row[0] ?? "0")!)])
            replaced = key
        }, scenario)
        #expect(replaced != nil, "the key was replaced")
        #expect(intact.facts != corrupt.facts, "a key without its position write's residue is visible")
        #expect(corrupt.facts.contains { $0.contains("q1:WRONG-RESIDUE(q1:1:1)") })
    }

    /// The comparison keeps what queue keys and derived identities say: different positions and different kinds of
    /// identity stay different.
    @Test func theServerNormalizerKeepsPositionsAndIdentityKinds() {
        #expect(Self.normalized([["q1:1:1"]]) != Self.normalized([["q1:2:1"]]))
        let hash = String(repeating: "ab", count: 32)
        #expect(Self.normalized([["p1:\(hash)"]]) != Self.normalized([["e1:\(hash)"]]))
    }

    /// Pause then seek while the minute export waits, in a server library: the engine moves at once, and the journal,
    /// exports and played time are the serial run's.
    @Test func serverPauseThenSeekWhileAMinuteExportWaits() async throws {
        let (outcome, _) = try await Self.compare(server: true) { run in
            try await Self.minuteExportHeld(run)
            let pausing = Task { try await run.player.pause() }
            let seeking = Task { try await run.player.seek(to: 120_000) }
            try await run.quiet(admitted: 3)
            if run.hoisting { #expect(run.engine.commands.suffix(2) == [.pause, .seek(120_000)]) }
            run.gate.release()
            try await pausing.value; try await seeking.value
        }
        #expect(outcome.stored[0].contains("position 60000"), "the pause saved where it paused: \(outcome.stored)")
    }

    /// Resume then pause in a server library: Play waits for its streaming check, Pause is pressed, Play's
    /// recording (the session's start or claim) waits for the store; Pause reaches the engine meanwhile, and the
    /// sessions and facts are the serial run's.
    @Test func serverResumeThenPause() async throws {
        let (outcome, _) = try await Self.compare(server: true) { run in
            try await run.playing()
            try await run.player.pause()
            run.clock.milliseconds += 30_000
            run.holdsAccess = true
            run.gate.hold { if case .recordPlaybackIntent = $0 { true } else { false } }
            let playing = Task { try await run.player.play() }
            try await run.until("Play waits for its streaming check") { !run.access.isEmpty }
            let pausing = Task { try await run.player.pause() }
            try await run.quiet(admitted: 2)
            run.releaseAccess()
            try await run.until("Play's recording waits") { run.gate.isHolding }
            try await run.quiet(admitted: 2)
            if run.hoisting { #expect(run.engine.commands.suffix(2) == [.play, .pause]) }
            run.gate.release()
            try await playing.value; try await pausing.value
        }
        #expect(!outcome.sessions.isEmpty && !outcome.facts.isEmpty)
    }

    /// Mutation guard: the serial reference really is the old coordinator (nothing reaches the engine while a save
    /// waits), so the comparisons above compare against today's behaviour.
    @Test func theSerialReferenceWaits() async throws {
        _ = try await Self.run(hoisting: false) { run in
            try await run.playing()
            run.gate.hold(Self.isSave)
            run.engine.position(12_000)
            try await run.until("the five-second save waits") { run.gate.isHolding }
            let pausing = Task { try await run.player.pause() }
            try await run.quiet(admitted: 2)
            #expect(run.engine.commands.last == .play)
            run.gate.release()
            try await pausing.value
            #expect(run.engine.commands.last == .pause)
        }
    }
}
#endif

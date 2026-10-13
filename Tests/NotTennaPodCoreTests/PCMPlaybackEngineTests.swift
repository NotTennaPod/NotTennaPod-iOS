import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct PCMPlaybackEngineTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    @MainActor final class Driver: AudioSessionActivationDriver {
        var requests: [Bool] = []
        var preparations = 0
        var configurationError: (any Error)?
        var activationGranted = true
        func prepareForActivation() throws {
            preparations += 1
            if let configurationError { throw configurationError }
        }
        func setActive(_ active: Bool) async throws -> Bool { requests.append(active); return !active || activationGranted }
    }
    @MainActor final class Clock { var now: Int64 = 5000; var date: Date { Date(timeIntervalSince1970: Double(now) / 1000) } }
    @MainActor final class Ticker: PlaybackPositionTicking {
        var tick: (@MainActor () -> Void)?
        var starts = 0
        func start(_ tick: @escaping @MainActor () -> Void) { if self.tick == nil { starts += 1; self.tick = tick } }
        func stop() { tick = nil }
        func fire() { tick?() }
    }
    @MainActor final class Outputs {
        var values: [Transport] = []
        var nativeValues: [NativeSampleBufferTransport] = []
        var configure: ((Transport) -> Void)?
        let ticker = Ticker()
    }
    actor DurationGate {
        private var pending: [CheckedContinuation<Int64, Never>?] = []
        private var closed = false
        func duration() async -> Int64 {
            if closed { return 600 }
            return await withCheckedContinuation { pending.append($0) }
        }
        func requestCount() -> Int { pending.count }
        func releaseAll() {
            closed = true
            for index in pending.indices { release(index) }
        }
        func waitForCount(_ count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while pending.count < count && ContinuousClock.now < deadline { await Task.yield() }
            try #require(pending.count >= count)
        }
        func release(_ index: Int) { let c = pending[index]; pending[index] = nil; c?.resume(returning: 600) }
    }

    func withPlayer(nativeOutput: Bool = false,
                            speed: Float = 1, skipSilence: Bool = false,
                            maximumOutputFrames: Int = 4096, maximumQueuedBuffers: Int = 4,
                            events: PCMPlaybackEngine.EventSourceFactory? = nil,
                            pauseOnDisconnect: Bool = true,
                            duration: (@Sendable (URL) async throws -> Int64)? = nil,
                            minimumQueuedSeconds: Double = 0, fixtureFrames: Int = 28_800,
                            _ body: (FeedLibraryStore, PlaybackCoordinator, PCMPlaybackEngine, Outputs, Clock, Driver) async throws -> Void) async throws {
        let (url, _) = try PCMTestFixture.waveFixture(frames: fixtureFrames)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try FeedLibraryStore(url: url.deletingLastPathComponent().appendingPathComponent("library.sqlite"))
        let episodes = (1...3).map { ParsedEpisode(identifier: "\($0)", title: "Episode \($0)",
            media: ParsedMedia(url: "https://example.test/\($0).wav", size: 0, durationMilliseconds: 600)) }
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "PCM", episodes: episodes),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
            validator: nil, permanentRedirectURL: nil))
        let outputs = Outputs(); let clock = Clock(); let driver = Driver()
        let engine = PCMPlaybackEngine(driver: driver, makeFactory: { url in
            var factory = try PCMRecoveryFactory(url: url, maximumOutputFrames: maximumOutputFrames,
                                       maximumQueuedBuffers: maximumQueuedBuffers, makeTransport: {
                if nativeOutput {
                    let t = NativeSampleBufferTransport(muted: true)
                    outputs.nativeValues.append(t)
                    return t
                }
                let t = Transport(); outputs.configure?(t); outputs.values.append(t); return t
            })
            factory.minimumQueuedSeconds = minimumQueuedSeconds
            return factory
        }, source: { _ in url }, duration: duration, events: events, pauseOnDisconnect: pauseOnDisconnect,
            positionTicker: nativeOutput ? PlaybackPositionTicker() : outputs.ticker, now: { clock.now })
        let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
            var preferences = PlaybackPreferences(); preferences.end.smartMarkAsPlayedSeconds = 0
            preferences.speed = speed; preferences.skipSilence = skipSilence; return preferences
        }, clock: { clock.date })
        do { try await body(store, player, engine, outputs, clock, driver) }
        catch { engine.unload(); try? await store.close(); throw error }
        engine.unload(); try await store.close()
    }

    @Test func pausedLoadSeekAndCompletionDriveRealCoordinatorAndDatabase() async throws {
        try await withPlayer { store, player, engine, outputs, clock, _ in
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused }
            #expect(engine.reading?.sample.durationMilliseconds == 600)
            #expect(outputs.values.count == 1 && !outputs.values[0].playing)
            try await player.play(); try await wait { outputs.values[0].playing }
            outputs.values[0].advance(4800)
            clock.now += 1000
            try await player.pause()
            #expect(player.sample?.positionMilliseconds == 100)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
            try await player.seek(to: 300)
            #expect(engine.reading?.sample.positionMilliseconds == 300)
            #expect(engine.reading?.buffering == true && player.isBuffering)
            #expect(player.phase == .paused && !player.wantsPlayback)
            try await wait { outputs.values.count == 2 && engine.reading?.sample.positionMilliseconds == 300 && !engine.reading!.buffering }
            #expect(outputs.values[0].closed && !outputs.values[1].playing)
            #expect(!player.isBuffering)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
            try await player.play(); try await wait { outputs.values[1].playing }
            try await drain(outputs.values[1]) { player.phase == .idle }
            let completed = try #require(try await store.episode(id: 1))
            #expect(completed.userState.playState == .played && completed.userState.positionMilliseconds == 0)
            #expect(try await store.queue().isEmpty)
            #expect(try await store.playbackSession() == nil)
        }
    }

    @Test(arguments: ["media", ""])
    func opaqueMP3DurationRetainsOriginalMeasuredPadding(fileExtension: String) async throws {
#if SWIFT_PACKAGE
        let source = try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
#else
        let source = try #require(Bundle(for: PCMEngineFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3"))
#endif
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(fileExtension.isEmpty ? "download" : "download.\(fileExtension)")
        try FileManager.default.copyItem(at: source, to: url)
        #expect(abs(try await PCMPlaybackEngine.mediaDuration(url, contentType: "audio/mpeg") - 30040) <= 100)
    }

    @Test func completionAdvancesQueueAndOldOutputCannotAffectSuccessor() async throws {
        try await withPlayer { store, player, engine, outputs, _, driver in
            _ = try await store.enqueue([1, 2])
            try await player.select(episodeID: 1)
            try await wait { outputs.values.first?.playing == true }
            let old = outputs.values[0]; let late = old.onTimeChanged
            try await drain(old) { player.episode?.id == 2 && outputs.values.count == 2 && outputs.values[1].playing }
            #expect(old.closed && player.wantsPlayback)
            #expect(try await store.queue().map(\.id) == [2])
            let nextReading = engine.reading
            late?(); old.advance(999999)
            try await player.awaitPendingOperations()
            #expect(engine.reading == nextReading && player.episode?.id == 2)
            #expect(driver.requests.last == true)
            try await player.stop()
        }
    }

    /// Production queue (one second) and rebuffer threshold (0.5 s): the renderer runs dry, then only
    /// 2400 frames remain. The final piece plays by itself, the episode completes once and the queue advances.
    @Test func finalPieceAfterStallCompletesOnceAndTheQueueAdvances() async throws {
        try await withPlayer(minimumQueuedSeconds: 1, fixtureFrames: 49_152 + 2400) { store, player, engine, outputs, _, _ in
            var endings = 0
            let deliver = engine.onEvent
            engine.onEvent = { event in
                if case .ended = event { endings += 1 }
                deliver?(event)
            }
            _ = try await store.enqueue([1, 2])
            try await player.select(episodeID: 1)
            try await wait { outputs.values.first?.playing == true && outputs.values[0].end == CMTime(value: 49_152, timescale: 48_000) }
            let first = outputs.values[0]
            first.advance(49_152)
            #expect(!first.playing && player.wantsPlayback)
            try await wait { first.end == CMTime(value: 51_552, timescale: 48_000) && first.monitoring }
            #expect(first.playing)
            try await drain(first) { player.episode?.id == 2 && outputs.values.count == 2 && outputs.values[1].playing }
            try await player.awaitPendingOperations()
            #expect(endings == 1 && first.closed && player.wantsPlayback)
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            #expect(try await store.episode(id: 2)?.userState.playState != .played)
            #expect(try await store.queue().map(\.id) == [2])
            try await player.stop()
        }
    }

    @Test func interruptionPublishesPauseBeforeRecoveryReadsSavedStatistics() async throws {
        try await withPlayer { store, player, engine, outputs, clock, _ in
            try await player.select(episodeID: 1)
            try await wait { outputs.values.first?.playing == true }
            outputs.values[0].advance(9600)
            clock.now += 1000
            engine.receive(.interrupted(reason: 0))
            clock.now += 60001
            engine.receive(.resumptionRecommended(true))
            try await wait { outputs.values.count == 2 && outputs.values[1].playing }
            try await player.awaitPendingOperations()
            #expect(outputs.values[0].closed && player.wantsPlayback)
            #expect(engine.reading?.sample.positionMilliseconds == 0)
            #expect(try await store.episode(id: 1)?.userState.lastPlayedTimeMilliseconds == clock.now)
            try await player.pause()
        }
    }

    @Test func replacedPreparationCannotPublishOrDeactivateNewEpisode() async throws {
        let gate = DurationGate()
        try await withPlayer(duration: { _ in await gate.duration() }) { _, player, engine, outputs, _, driver in
            try await player.select(episodeID: 1)
            try await gate.waitForCount(1)
            try await wait { outputs.values.count == 1 }
            try await player.select(episodeID: 2)
            try await gate.waitForCount(2)
            await gate.release(1)
            try await wait { outputs.values.count == 2 && outputs.values[1].playing }
            #expect(outputs.values[0].closed && player.episode?.id == 2)
            let token = engine.reading?.generation
            let requestsBeforeObsoleteCompletion = driver.requests
            #expect(requestsBeforeObsoleteCompletion.last == true)
            await gate.release(0)
            try await Task.sleep(for: .milliseconds(20))
            try await player.awaitPendingOperations()
            #expect(engine.reading?.generation == token && outputs.values[1].playing)
            #expect(player.episode?.id == 2 && driver.requests == requestsBeforeObsoleteCompletion)
        }
    }

    @Test func pauseAndSpeedDuringPreparationRemainPausedAndImmediateSeekReportsTarget() async throws {
        let gate = DurationGate()
        try await withPlayer(duration: { _ in await gate.duration() }) { _, player, engine, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await gate.waitForCount(1)
            try await player.setSpeed(2)
            try await player.pause()
            await gate.release(0)
            try await wait { player.phase == .paused }
            #expect(engine.reading?.speed == 2 && !outputs.values[0].playing)
            engine.seek(to: 350, commandID: UUID())
            #expect(engine.reading?.sample.positionMilliseconds == 350)
            try await wait { outputs.values.count == 2 && outputs.values[1].buffers.count > 0 }
            #expect(engine.reading?.speed == 2 && !outputs.values[1].playing)
        }
    }

    @Test func shownPositionFollowsHeardAudioAndIsSavedEveryFiveSeconds() async throws {
        try await withPlayer { store, player, engine, outputs, clock, _ in
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused }
            try await player.play(); try await wait { outputs.values[0].playing }
            try await player.awaitPendingOperations()
            outputs.values[0].advance(4800)
            clock.now += 4999
            outputs.ticker.fire(); try await player.awaitPendingOperations()
            // The shown position is what was heard; the database is written every 5 s (as on Android).
            #expect(player.sample?.positionMilliseconds == 100)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 0)
            clock.now += 1
            outputs.ticker.fire(); try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
            try await player.pause()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
            _ = engine
            try await player.stop()
        }
    }

    @Test(arguments: [Float(0.5), 1, 4], [false, true])
    func silenceCommandsReachDecodedOutputAndCompletion(speed: Float, skipSilence: Bool) async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await withPlayer(speed: speed, skipSilence: skipSilence) { _, player, engine, outputs, _, _ in
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused }
            #expect(player.skipSilence == skipSilence && engine.reading?.skipSilence == skipSilence)
            #expect(player.speed == speed && !outputs.values[0].playing)
            try await player.play(); try await wait { outputs.values[0].playing }
            try await drain(outputs.values[0]) { player.phase == .idle }
            #expect(try payload(outputs.values[0]) == expected(input[...], speed: speed, skipSilence: skipSilence))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func liveSilenceCommandProcessesFutureAudioWithoutDiscardingQueuedSamples(initial: Bool, playing: Bool) async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await withPlayer(skipSilence: initial, maximumOutputFrames: 127, maximumQueuedBuffers: 2) {
            _, player, engine, outputs, _, _ in
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused }
            if playing { try await player.play(); try await wait { outputs.values[0].playing } }
            let queued = try payload(outputs.values[0])
            try await player.setSkipSilence(!initial)
            try await player.setSpeed(2)
            #expect(engine.reading?.skipSilence == !initial && engine.reading?.speed == 2)
            #expect(try payload(outputs.values[0]) == queued && outputs.values[0].playing == playing)
            #expect(player.wantsPlayback == playing)
            #expect(engine.reading?.sample.positionMilliseconds == 0)
            if !playing { try await player.play(); try await wait { outputs.values[0].playing } }
            try await drain(outputs.values[0]) { player.phase == .idle }
            var bytes = try expected(input[..<8192], speed: 1, skipSilence: initial)
            bytes.append(try expected(input[8192...], speed: 2, skipSilence: !initial))
            #expect(try payload(outputs.values[0]) == bytes)
            #expect(outputs.values.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func silenceChangesDuringPreparationAndSeekKeepLatestChoiceAndPausedIntent(initial: Bool) async throws {
        let gate = DurationGate()
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await withPlayer(skipSilence: initial, duration: { _ in await gate.duration() }) { _, player, engine, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await gate.waitForCount(1)
            try await player.setSkipSilence(!initial)
            try await player.setSpeed(2)
            try await player.pause()
            await gate.release(0)
            try await wait { player.phase == .paused }
            #expect(player.skipSilence == !initial && engine.reading?.skipSilence == !initial)
            #expect(player.speed == 2 && !outputs.values[0].playing)
            try await player.seek(to: 300)
            try await player.setSkipSilence(initial)
            try await player.setSpeed(1.5)
            try await wait { outputs.values.count == 2 && !outputs.values[1].buffers.isEmpty }
            #expect(engine.reading?.skipSilence == initial && engine.reading?.speed == 1.5)
            #expect(!outputs.values[1].playing && !player.wantsPlayback)
            // A second seek makes a fresh decoder after the preceding commands have settled.
            // Its complete payload must use the selected pair, including quiet input.
            try await player.seek(to: 300)
            try await wait { outputs.values.count == 3 && !outputs.values[2].buffers.isEmpty }
            #expect(outputs.values[0].closed && outputs.values[1].closed)
            try await player.play(); try await wait { outputs.values[2].playing }
            try await drain(outputs.values[2]) { player.phase == .idle }
            #expect(try payload(outputs.values[2]) == expected(input[28800...], speed: 1.5, skipSilence: initial))
        }
    }

    private func payload(_ transport: Transport) throws -> Data {
        try transport.buffers.reduce(into: Data()) {
            $0.append(try #require($1.content.withContiguousStorageIfAvailable { Data($0) }))
        }
    }

    private func expected(_ input: ArraySlice<Int16>, speed: Float, skipSilence: Bool) throws -> Data {
        var silence = skipSilence ? try SilenceSkippingProcessor(sampleRate: 48000, channels: 2) : nil
        var rate = speed == 1 ? nil : try PCMSpeedProcessor(sampleRate: 48000, channels: 2, speed: speed)
        var samples: [Int16] = []
        for offset in stride(from: input.startIndex, to: input.endIndex, by: 8192) {
            let packet = Array(input[offset..<min(input.endIndex, offset + 8192)])
            let quiet = try silence?.process(packet) ?? packet
            samples += try rate?.process(quiet) ?? quiet
        }
        let tail = silence?.finish() ?? []
        samples += try rate?.process(tail) ?? tail
        samples += rate?.finish() ?? []
        return samples.withUnsafeBytes { Data($0) }
    }

    @Test func missingDownloadedFileFailsPreparationInsteadOfHanging() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID()).media")
        await #expect(throws: (any Error).self) {
            try await PCMPlaybackEngine.mediaDuration(missing, contentType: "audio/mpeg")
        }
    }

    @Test func corruptOpaqueFileFailsPreparationDespiteDeclaredAudioType() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).media")
        try Data("This file is not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) {
            try await PCMPlaybackEngine.mediaDuration(url, contentType: "audio/mpeg")
        }
    }

    func drain(_ output: Transport, until condition: () -> Bool) async throws {
        var progressDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var previous = (output.end, output.currentTime)
        while !condition() {
            try Task.checkCancellation()
            if output.playing && !output.closed { output.advance(output.end.value) }
            let current = (output.end, output.currentTime)
            if current != previous {
                progressDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                previous = current
            }
            try #require(ContinuousClock.now <= progressDeadline, "PCM playback drain stalled")
            await Task.yield()
        }
        try #require(condition())
    }

    func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), sourceLocation: sourceLocation)
    }
}

private final class PCMEngineFixtures: NSObject {}

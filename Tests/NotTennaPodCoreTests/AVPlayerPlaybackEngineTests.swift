import AVFoundation
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor
struct AVPlayerPlaybackEngineTests {
    private enum Failure: Error { case timedOut }
    @MainActor private final class AudioConfiguration {
        var count = 0
        var shouldFail = true
    }
    private final class Events {
        var values: [PlaybackEngineEvent] = []
        var ready: [PlaybackEngineReading] { values.compactMap { if case .ready(let v) = $0 { v } else { nil } } }
        var positions: [PlaybackEngineReading] { values.compactMap { if case .position(let v) = $0 { v } else { nil } } }
        var ended: [PlaybackEngineReading] { values.compactMap { if case .ended(let v) = $0 { v } else { nil } } }
        var failures: [UUID] { values.compactMap { if case .failed(let id, _) = $0 { id } else { nil } } }
    }

    private var fixture: URL { Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")! }

    private func episode(id: Int64 = 1, file: URL? = nil) -> LibraryEpisode {
        var state = EpisodeUserState()
        state.isDownloaded = true
        state.localFileURL = (file ?? fixture).path
        return LibraryEpisode(id: id, details: ParsedEpisode(identifier: "\(id)", title: "Native playback",
            media: ParsedMedia(url: "https://example.invalid/\(id).mp3", size: 0, durationMilliseconds: 30_000)), userState: state)
    }

    private func wait(until condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            if ContinuousClock.now >= deadline { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func withEngine(_ operation: (AVPlayerPlaybackEngine, Events) async throws -> Void) async throws {
        let engine = AVPlayerPlaybackEngine(muted: true)
        let events = Events()
        engine.onEvent = { events.values.append($0) }
        defer { engine.unload() }
        try await operation(engine, events)
    }

    private func prepare(_ engine: AVPlayerPlaybackEngine, _ events: Events, position: Int64 = 3_883) async throws {
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: position)
        try await wait { !events.ready.isEmpty || !events.failures.isEmpty }
        #expect(events.failures.isEmpty)
        _ = try #require(events.ready.first)
    }

    @Test func rateSetDuringPreparationAndPausedSeekingDoesNotStartPlayback() async throws {
        try await withEngine { engine, events in
            let generation = UUID()
            engine.load(episode: episode(), generation: generation, positionMilliseconds: 3_883)
            let rateCommand = UUID()
            try engine.setSpeed(2, commandID: rateCommand)
            try await wait { !events.ready.isEmpty || !events.failures.isEmpty }
            let ready = try #require(events.ready.first)
            #expect(ready.commandID == rateCommand && ready.speed == 2)
            #expect(ready.sample.status == .paused && engine.nativePlayer?.rate == 0)
            #expect(engine.nativePlayer?.currentItem?.audioTimePitchAlgorithm == .timeDomain)
            engine.seek(to: 10_000, commandID: UUID())
            try engine.setSpeed(0.5, commandID: UUID())
            try await wait { engine.nativePlayer?.currentItem?.currentTime().seconds ?? 0 >= 10 }
            #expect(engine.reading?.speed == 0.5 && engine.nativePlayer?.rate == 0)
            #expect(engine.reading?.sample.status == .paused)
        }
    }

    @Test func changingActiveRateAndResumingUseTheConfiguredNativeRate() async throws {
        try await withEngine { engine, events in
            try await prepare(engine, events, position: 0)
            try engine.setSpeed(1.5, commandID: UUID())
            engine.play(commandID: UUID())
            try await wait { engine.nativePlayer?.rate == 1.5 }
            try await wait { engine.nativePlayer?.timeControlStatus == .playing }
            // The native clock holds still for the first audio output (about 0.2 s after
            // `.playing` on the host), which is start-up latency, not speed. Measure the
            // rate once audio is actually being heard.
            try await wait { engine.nativePlayer?.currentTime().seconds ?? 0 > 0.1 }
            // 1.5x really plays 1.5 s of media per wall-clock second (10%).
            let wallStart = ContinuousClock.now
            let mediaStart = try #require(engine.nativePlayer?.currentTime().seconds)
            try await Task.sleep(for: .seconds(1))
            let mediaEnd = try #require(engine.nativePlayer?.currentTime().seconds)
            let wall = ContinuousClock.now - wallStart
            let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
            let ratio = (mediaEnd - mediaStart) / wallSeconds
            #expect(abs(ratio - 1.5) <= 0.15, "measured playback speed \(ratio)")
            try engine.setSpeed(4, commandID: UUID())
            try await wait { engine.nativePlayer?.rate == 4 }
            let before = try #require(engine.nativePlayer?.currentTime().seconds)
            try await Task.sleep(for: .milliseconds(250))
            let after = try #require(engine.nativePlayer?.currentTime().seconds)
            #expect(after - before > 0.5) // Distinguishes 4x advancement from 1x; allows scheduling variance.
            engine.pause(commandID: UUID())
            #expect(engine.nativePlayer?.rate == 0 && engine.reading?.speed == 4)
            try engine.setSpeed(0.5, commandID: UUID())
            #expect(engine.nativePlayer?.rate == 0)
            engine.play(commandID: UUID())
            try await wait { engine.nativePlayer?.rate == 0.5 }
            #expect(engine.reading?.sample.status == .playing)
        }
    }

    @Test func invalidRateIsRejectedAndNewMediaStartsWithFreshRateConfiguration() async throws {
        try await withEngine { engine, events in
            try await prepare(engine, events)
            try engine.setSpeed(1.5, commandID: UUID())
            let commandID = engine.reading?.commandID
            for rate: Float in [0, -1, .infinity, -.infinity, .nan] {
                #expect(throws: PlaybackSpeedError.invalidSpeed) { try engine.setSpeed(rate, commandID: UUID()) }
            }
            #expect(engine.reading?.speed == 1.5 && engine.reading?.commandID == commandID)
            engine.load(episode: episode(id: 2), generation: UUID(), positionMilliseconds: 0)
            try await wait { events.ready.count == 2 }
            #expect(engine.reading?.speed == 1 && engine.nativePlayer?.rate == 0)
        }
    }

    @Test func sourceResolutionPreservesDownloadedChoiceWithoutSilentNetworkFallback() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/podcast with spaces.mp3")
        var item = episode(file: missing)
        #expect(try AVPlayerPlaybackEngine.mediaURL(item) == missing)
        item.userState.isDownloaded = false
        #expect(try AVPlayerPlaybackEngine.mediaURL(item).absoluteString == "https://example.invalid/1.mp3")
        item.details.media?.url = "content://android-only/media"
        #expect(throws: PlaybackSourceError.invalidURL) { try AVPlayerPlaybackEngine.mediaURL(item) }
        item.details.media = nil
        #expect(throws: PlaybackSourceError.missingMedia) { try AVPlayerPlaybackEngine.mediaURL(item) }
    }

    @Test func timeConversionUsesTruncationAndKeepsUnknownDistinct() {
        // Known times convert to the displayed millisecond value; unknown
        // times stay distinct from zero so the UI does not show a bogus 0:00.
        #expect(abs(AVPlayerPlaybackEngine.milliseconds(CMTime(value: 1_324_800, timescale: 44_100), fallback: -1) - 30_040) <= 1)
        #expect(AVPlayerPlaybackEngine.milliseconds(CMTime(value: -3, timescale: 2_000), fallback: -1) == -1)
        #expect(AVPlayerPlaybackEngine.milliseconds(.indefinite, fallback: -1) == -1)
        #expect(AVPlayerPlaybackEngine.milliseconds(.invalid, fallback: 0) == 0)
        #expect(AVPlayerPlaybackEngine.milliseconds(.positiveInfinity, fallback: -1) == -1)
    }

    @Test func readyUsesPlayerItemDurationAndExactSeekWithoutAutoplay() async throws {
        try await withEngine { engine, events in
            try await prepare(engine, events)
            let value = try #require(events.ready.first)
            // Opens at the saved position with the real duration, paused.
            #expect(abs(value.sample.positionMilliseconds - 3_883) <= 250)
            #expect(abs(value.sample.durationMilliseconds - 30_040) <= 100)
            #expect(value.sample.seekable)
            #expect(value.sample.status == .paused)
            #expect(engine.nativePlayer?.rate == 0)
            try await Task.sleep(for: .milliseconds(120))
            #expect(engine.nativePlayer?.rate == 0 && engine.reading?.sample.status == .paused)
            #expect(abs((engine.reading?.sample.positionMilliseconds ?? 0) - 3_883) <= 250)
        }
    }

    @Test func realPlaybackAdvancesAndPauseStopsTimerAndPosition() async throws {
        try await withEngine { engine, events in
            try await prepare(engine, events)
            engine.play(commandID: UUID())
            try await wait { !events.positions.isEmpty }
            #expect(try #require(engine.reading).sample.positionMilliseconds > 3_883)
            #expect(engine.nativePlayer?.rate == 1)
            engine.pause(commandID: UUID())
            let position = try #require(engine.nativePlayer?.currentTime().seconds)
            let shown = engine.reading?.sample.positionMilliseconds
            try await Task.sleep(for: .milliseconds(1_100))
            // AVPlayer may settle a few samples after pausing; what matters is that the audio stopped.
            #expect(abs(try #require(engine.nativePlayer?.currentTime().seconds) - position) < 0.05)
            #expect(engine.nativePlayer?.rate == 0 && engine.reading?.sample.status == .paused)
            #expect(engine.reading?.sample.positionMilliseconds == shown)
        }
    }

    @Test func downloadedGenericExtensionPreparesAndPlaysUsingMediaType() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Native-download-\(UUID()).media")
        try FileManager.default.copyItem(at: fixture, to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await withEngine { engine, events in
            var media = episode(file: file)
            media.details.media?.mimeType = "audio/mpeg"
            engine.load(episode: media, generation: UUID(), positionMilliseconds: 3_883)
            try await wait { !events.ready.isEmpty || !events.failures.isEmpty }
            #expect(events.failures.isEmpty)
            let reading = try #require(events.ready.first)
            #expect(reading.sample.positionMilliseconds == 3_883)
            engine.play(commandID: UUID())
            try await wait { !events.positions.isEmpty || !events.failures.isEmpty }
            #expect(events.failures.isEmpty)
            #expect(try #require(engine.reading).sample.positionMilliseconds > 3_883)
        }
    }

    @Test func formatHintDoesNotOverrideRemoteOrRecognizedLocalTypes() {
        var item = episode()
        item.details.media?.mimeType = "video/mp4"
        #expect(AVPlayerPlaybackEngine.assetOptions(for: item, url: fixture).isEmpty)
        #expect(AVPlayerPlaybackEngine.assetOptions(for: item, url: URL(string: "https://example.test/audio.media")!).isEmpty)
        let generic = URL(fileURLWithPath: "/tmp/episode.media")
        item.details.media?.mimeType = "audio/mpeg"
        #expect(AVPlayerPlaybackEngine.assetOptions(for: item, url: generic)[AVURLAssetOverrideMIMETypeKey] as? String == "audio/mpeg")
        item.details.media?.mimeType = "application/octet-stream"
        #expect(AVPlayerPlaybackEngine.assetOptions(for: item, url: generic)[AVURLAssetOverrideMIMETypeKey] as? String == "audio/mpeg")
        item.details.media?.mimeType = nil
        item.details.media?.url = "https://example.test/unknown"
        #expect(AVPlayerPlaybackEngine.assetOptions(for: item, url: generic).isEmpty)
    }

    @Test func pendingInitialSeekAndPauseUseLatestCommand() async throws {
        try await withEngine { engine, events in
            engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 3_883)
            engine.seek(to: 12_345, commandID: UUID())
            let paused = UUID()
            engine.pause(commandID: paused)
            try await wait { !events.ready.isEmpty || !events.failures.isEmpty }
            let value = try #require(events.ready.first)
            #expect(events.failures.isEmpty)
            #expect(value.sample.positionMilliseconds == 12_345 && value.commandID == paused)
            #expect(engine.nativePlayer?.rate == 0)
        }
    }

    @Test func rapidSeeksSettleOnLatestPositionWithoutOldCompletionOverwritingIt() async throws {
        try await withEngine { engine, events in
            try await prepare(engine, events)
            for position: Int64 in [4_000, 22_000, 1_000] { engine.seek(to: position, commandID: UUID()) }
            engine.seek(to: 18_123, commandID: UUID())
            // The last requested position wins (within 0.25 s); earlier seeks'
            // completions (4 s, 22 s, 1 s) never move it afterwards.
            func near(_ value: Int64?) -> Bool { value.map { abs($0 - 18_123) <= 250 } ?? false }
            #expect(near(engine.reading.map { Int64($0.sample.positionMilliseconds) }))
            try await wait {
                near(engine.nativePlayer.map { AVPlayerPlaybackEngine.milliseconds($0.currentTime(), fallback: -1) })
                    && engine.reading?.buffering == false
            }
            #expect(events.failures.isEmpty)
            try await Task.sleep(for: .milliseconds(100))
            #expect(near(engine.reading.map { Int64($0.sample.positionMilliseconds) }) && events.ended.isEmpty)
            #expect(near(engine.nativePlayer.map { AVPlayerPlaybackEngine.milliseconds($0.currentTime(), fallback: -1) }))
        }
    }

    @Test func missingAndCorruptFilesFailAndNewItemRecovers() async throws {
        try await withEngine { engine, events in
            let missing = UUID()
            engine.load(episode: episode(file: URL(fileURLWithPath: "/nonexistent/\(missing).mp3")),
                        generation: missing, positionMilliseconds: 0)
            try await wait { events.failures.contains(missing) }
            #expect(events.ready.isEmpty)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp3")
            try Data("This is not audio".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let corrupt = UUID()
            engine.load(episode: episode(file: file), generation: corrupt, positionMilliseconds: 0)
            try await wait { events.failures.contains(corrupt) }
            let good = UUID()
            engine.load(episode: episode(), generation: good, positionMilliseconds: 0)
            try await wait { events.ready.contains { $0.generation == good } }
            #expect(events.failures == [missing, corrupt])
            #expect(engine.reading?.generation == good)
        }
    }

    @Test(arguments: ["mp3", "media", ""])
    func missingLocalFileReportsFailureBeforePlayerPreparation(fileExtension: String) async throws {
        try await withEngine { engine, events in
            let generation = UUID()
            var url = FileManager.default.temporaryDirectory.appendingPathComponent(generation.uuidString)
            if !fileExtension.isEmpty { url.appendPathExtension(fileExtension) }
            engine.load(episode: episode(file: url), generation: generation, positionMilliseconds: 123)
            #expect(events.failures == [generation] && events.ready.isEmpty && events.ended.isEmpty)
            #expect(engine.reading == nil)
            engine.play(commandID: UUID())
            #expect(events.failures == [generation] && events.ready.isEmpty)
            let next = UUID()
            engine.load(episode: episode(), generation: next, positionMilliseconds: 123)
            try await wait { events.ready.contains { $0.generation == next } }
            #expect(engine.reading?.generation == next && events.failures == [generation])
        }
    }

    @Test func HTTPMediaPreparesWithNativePlayer() async throws {
        let data = try Data(contentsOf: fixture)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg"], body: data)
        }
        defer { server.stop() }
        try await withEngine { engine, events in
            var item = episode()
            item.userState.isDownloaded = false
            item.details.media?.url = server.url.absoluteString
            engine.load(episode: item, generation: UUID(), positionMilliseconds: 3_883)
            try await wait { !events.ready.isEmpty || !events.failures.isEmpty }
            #expect(events.failures.isEmpty && !server.requests.isEmpty)
            #expect(try #require(events.ready.first).sample.positionMilliseconds == 3_883)
        }
    }

    @Test func HTTPMediaPlayBeforeReadyAdvancesAndCanPauseResume() async throws {
        let data = try Data(contentsOf: fixture)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg"], body: data)
        }
        defer { server.stop() }
        try await withEngine { engine, events in
            var item = episode()
            item.userState.isDownloaded = false
            item.details.media?.url = server.url.absoluteString
            engine.load(episode: item, generation: UUID(), positionMilliseconds: 0)
            engine.play(commandID: UUID())
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= 1_000 || !events.failures.isEmpty }
            #expect(events.failures.isEmpty)
            #expect(!events.ready.isEmpty && !server.requests.isEmpty)
            #expect(engine.reading?.sample.status == .playing)
            #expect((engine.reading?.sample.durationMilliseconds ?? 0) > 0)
            engine.pause(commandID: UUID())
            let stopped = try #require(engine.reading?.sample.positionMilliseconds)
            try await Task.sleep(for: .milliseconds(200))
            #expect(abs((engine.reading?.sample.positionMilliseconds ?? 0) - stopped) <= 100)
            engine.play(commandID: UUID())
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= stopped + 1_000 }
        }
    }

    @Test func nativeHTTPOnceAdmissionPublishesProgressThroughCoordinator() async throws {
        let data = try Data(contentsOf: fixture)
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: data) }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeStream-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        var details = episode().details
        details.media?.url = server.url.absoluteString
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Native stream", episodes: [details]),
            source: server.url.absoluteString, responseURL: server.url, validator: nil, permanentRedirectURL: nil))
        let engine = AVPlayerPlaybackEngine(muted: true)
        let player = PlaybackCoordinator(store: store, engine: engine,
            streamingAccess: { _ in .init(needsStreaming: true, streamingAllowed: false) })
        do {
            try await player.select(episodeID: 1)
            #expect(player.phase == .awaitingStreamingConfirmation)
            try await player.play()
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= 1_000 }
            #expect((engine.reading?.sample.durationMilliseconds ?? 0) > 0)
            try await wait { (player.sample?.positionMilliseconds ?? 0) >= 1_000 }
            #expect(player.phase == .playing)
            try await player.pause()
            #expect((try await store.episode(id: 1)?.userState.positionMilliseconds ?? 0) >= 1_000)
            try await player.stop(); try await store.close()
        } catch {
            print("HTTP progress diagnostic: phase=\(player.phase), sample=\(String(describing: player.sample)), native=\(String(describing: engine.reading))")
            engine.unload(); try? await store.close(); throw error
        }
    }

    @Test func replacingStalledPreparationCannotPublishIntoNewItem() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        try await withEngine { engine, events in
            var item = episode()
            item.userState.isDownloaded = false
            item.details.media?.url = server.url.absoluteString
            let old = UUID()
            engine.load(episode: item, generation: old, positionMilliseconds: 0)
            try await wait { !server.requests.isEmpty }
            let next = UUID()
            engine.load(episode: episode(id: 2), generation: next, positionMilliseconds: 3_883)
            try await wait { !events.ready.isEmpty }
            server.stop()
            try await Task.sleep(for: .milliseconds(100))
            #expect(events.ready.allSatisfy { $0.generation == next })
            #expect(events.failures.isEmpty && engine.reading?.generation == next)
        }
    }

    @Test func naturalEndUsesNativePositionAndEmitsOnce() async throws {
        try await withEngine { engine, events in
            try await prepare(engine, events, position: 29_900)
            engine.play(commandID: UUID())
            try await wait { !events.ended.isEmpty }
            let end = try #require(events.ended.first)
            // The episode ends once, at its end.
            #expect(end.sample.status == .other)
            #expect(abs(end.sample.positionMilliseconds - end.sample.durationMilliseconds) <= 250)
            #expect(abs(end.sample.durationMilliseconds - 30_040) <= 100)
            #expect(engine.nativePlayer?.rate == 0)
            try await Task.sleep(for: .milliseconds(100))
            #expect(events.ended.count == 1)
        }
    }

    @Test func seekToEndWhilePlayingCompletesInsteadOfLosingEndCallback() async throws {
        try await withEngine { engine, events in
            try await prepare(engine, events)
            engine.play(commandID: UUID())
            try await wait { engine.nativePlayer?.timeControlStatus == .playing }
            engine.seek(to: 30_040, commandID: UUID())
            try await wait { !events.ended.isEmpty || !events.failures.isEmpty }
            #expect(events.ended.count == 1 && events.failures.isEmpty)
        }
    }

    @Test func unloadAndDeinitializationStopNativePlayerAndRemoveCallbacks() async throws {
        let events = Events()
        var engine: AVPlayerPlaybackEngine? = AVPlayerPlaybackEngine(muted: true)
        engine?.onEvent = { events.values.append($0) }
        engine?.load(episode: episode(), generation: UUID(), positionMilliseconds: 3_883)
        try await wait { !events.ready.isEmpty }
        engine?.play(commandID: UUID())
        let native = try #require(engine?.nativePlayer)
        // Releasing the engine silences audio and stops further updates.
        engine = nil
        #expect(native.rate == 0 && native.currentItem == nil)
        let count = events.values.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.values.count == count)
    }

    @Test(arguments: [Float(1), 1.5])
    func nativeEngineAndCoordinatorPersistPauseAndCompleteQueue(speed: Float) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativePlayback-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let source = "https://example.test/feed"
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Native", episodes: [episode().details]),
            source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
        let file = fixture.path
        try await store.updateEpisode(id: 1) {
            $0.userState.localFileURL = file
            $0.userState.isDownloaded = true
            $0.userState.positionMilliseconds = 3_883
        }
        let engine = AVPlayerPlaybackEngine(muted: true)
        let settingsFile = directory.appendingPathComponent("speed-preferences.json")
        let settings = try PlaybackSpeedPreferenceStore(file: settingsFile)
        try settings.setGlobal(speed)
        let player = PlaybackCoordinator(store: store, engine: engine, speedPreferences: settings)
        do {
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused || player.phase == .failed }
            #expect(player.phase == .paused && engine.nativePlayer?.rate == 0)
            #expect(player.speed == speed && engine.reading?.speed == speed)
            #expect(try PlaybackSpeedPreferenceStore(file: settingsFile).value.temporary == speed)
            try await player.play()
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 4_000 }
            try await player.pause()
            let saved = try #require(try await store.episode(id: 1))
            #expect(saved.userState.positionMilliseconds == engine.reading?.sample.positionMilliseconds)
            #expect(saved.details.media?.durationMilliseconds == 30_040)
            #expect(try await store.playbackSession()?.status == .paused)
            try await player.seek(to: 29_900)
            try await wait { engine.nativePlayer.map { AVPlayerPlaybackEngine.milliseconds($0.currentTime(), fallback: 0) } == 29_900 }
            try await player.play()
            try await wait { player.phase == .idle || player.phase == .failed }
            #expect(player.phase == .idle)
            #expect(try await store.queue().isEmpty)
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 0)
            #expect(try await store.playbackSession() == nil)
            let restoredSettings = try PlaybackSpeedPreferenceStore(file: settingsFile)
            #expect(restoredSettings.value.currentEpisodeID == nil)
            #expect(restoredSettings.value.global == speed && restoredSettings.value.temporary == speed)
            #expect(FileManager.default.fileExists(atPath: file))
            try await player.stop()
            try await store.close()
        } catch {
            engine.unload()
            try? await store.close()
            throw error
        }
    }

    @Test func audioConfigurationWaitsForExplicitPlayAndFailureDoesNotStartAudio() async throws {
        let configuration = AudioConfiguration()
        let engine = AVPlayerPlaybackEngine(muted: true, configureAudioSession: {
            configuration.count += 1
            if configuration.shouldFail { throw PlaybackSourceError.invalidURL }
        })
        let events = Events()
        engine.onEvent = { events.values.append($0) }
        defer { engine.unload() }
        try await prepare(engine, events)
        #expect(configuration.count == 0)
        engine.play(commandID: UUID())
        #expect(configuration.count == 1 && events.failures.count == 1)
        #expect(engine.nativePlayer?.rate == 0)
        configuration.shouldFail = false
        let replacement = UUID()
        engine.load(episode: episode(), generation: replacement, positionMilliseconds: 3_883)
        try await wait { events.ready.contains { $0.generation == replacement } }
        engine.play(commandID: UUID())
        try await wait { engine.nativePlayer?.timeControlStatus == .playing }
        engine.pause(commandID: UUID())
        engine.play(commandID: UUID())
        #expect(configuration.count == 2)
    }

    @Test func nativeExternalPauseUpdatesIntentWithoutPretendingEpisodeEnded() async throws {
        try await withEngine { engine, events in
            try await prepare(engine, events)
            engine.play(commandID: UUID())
            try await wait { engine.nativePlayer?.timeControlStatus == .playing }
            engine.nativePlayer?.pause()
            try await wait { engine.reading?.sample.status == .paused }
            #expect(events.ended.isEmpty && events.failures.isEmpty)
            #expect(events.values.contains { if case .stateChanged(let reading) = $0 { reading.sample.status == .paused } else { false } })
        }
    }

    @Test func unloadingDuringSeekDiscardsCompletionAndStopsNativeItem() async throws {
        try await withEngine { engine, events in
            try await prepare(engine, events)
            engine.seek(to: 20_000, commandID: UUID())
            let native = try #require(engine.nativePlayer)
            engine.unload()
            let count = events.values.count
            try await Task.sleep(for: .milliseconds(100))
            #expect(engine.reading == nil && native.currentItem == nil && native.rate == 0)
            #expect(events.values.count == count)
        }
    }
}

extension AVPlayerPlaybackEngineTests {
    private final class SourceCapture {
        var sources: [ProgressiveHTTPMediaSource] = []
        var callbacks: [@Sendable (Error) -> Void] = []
    }

    private func captureSources(_ engine: AVPlayerPlaybackEngine) -> SourceCapture {
        let capture = SourceCapture()
        engine.makeHTTPSource = { url, callback in
            let source = try ProgressiveHTTPMediaSource(url: url, unknownLengthHandling: .nativePlayback, onFailure: callback)
            capture.sources.append(source)
            capture.callbacks.append(callback)
            return source
        }
        return capture
    }

    @Test func unloadAndReplacementRetireHTTPSourceAndFenceItsLateFailure() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        try await withEngine { engine, events in
            let captured = captureSources(engine)
            var remote = episode(); remote.userState.isDownloaded = false
            remote.details.media?.url = server.url.absoluteString
            engine.load(episode: remote, generation: UUID(), positionMilliseconds: 0)
            try await wait { !server.requests.isEmpty }
            let source = try #require(captured.sources.first)
            let nextGeneration = UUID()
            engine.load(episode: episode(id: 2), generation: nextGeneration, positionMilliseconds: 3883)
            try await wait { events.ready.contains { $0.generation == nextGeneration } }
            // A late network failure of the replaced stream shows no error on
            // the new episode, and its temporary cache file is removed.
            captured.callbacks[0](URLError(.networkConnectionLost))
            #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
            try await Task.sleep(for: .milliseconds(100))
            #expect(events.failures.isEmpty && engine.reading?.generation == nextGeneration)
            #expect(engine.reading?.sample.positionMilliseconds == 3883)
            engine.unload()
            let count = events.values.count
            captured.callbacks[0](URLError(.cannotConnectToHost))
            try await Task.sleep(for: .milliseconds(100))
            #expect(events.values.count == count && engine.reading == nil)
        }
    }

    @Test func sourceFailureWhileNativeItemRemainsReadyIsReportedOnceAndStopsPlayback() async throws {
        let bytes = try Data(contentsOf: fixture)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(bytes.count)"],
                  body: bytes.prefix(bytes.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        try await withEngine { engine, events in
            let captured = captureSources(engine)
            var remote = episode(); remote.userState.isDownloaded = false
            remote.details.media?.url = server.url.absoluteString
            let generation = UUID()
            engine.load(episode: remote, generation: generation, positionMilliseconds: 0)
            engine.play(commandID: UUID())
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= 1000 }
            #expect(engine.nativePlayer?.currentItem?.status == .readyToPlay)
            #expect((engine.reading?.sample.durationMilliseconds ?? 0) > 0)
            let source = try #require(captured.sources.first)
            // A network failure mid-stream is reported once, stops playback
            // and removes the temporary cache file.
            captured.callbacks[0](URLError(.badServerResponse))
            try await wait { !events.failures.isEmpty }
            captured.callbacks[0](URLError(.networkConnectionLost))
            // The engine cancels the source, whose worker queue then cleans up; the snapshot runs behind that work.
            let retired = await source.snapshot()
            #expect(retired.cancelled && retired.activeTransfers == 0 && retired.pendingRequests == 0 && retired.cleanupFailure == nil)
            #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
            try await Task.sleep(for: .milliseconds(100))
            #expect(events.failures == [generation])
            #expect(engine.nativePlayer?.rate == 0)
        }
    }

    @Test func releasingEngineCancelsStalledNetworkAndCacheOwner() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        var engine: AVPlayerPlaybackEngine? = AVPlayerPlaybackEngine(muted: true)
        let captured = captureSources(try #require(engine))
        var remote = episode(); remote.userState.isDownloaded = false
        remote.details.media?.url = server.url.absoluteString
        engine?.load(episode: remote, generation: UUID(), positionMilliseconds: 0)
        try await wait { !server.requests.isEmpty }
        let source = try #require(captured.sources.first)
        engine = nil
        // Releasing the player stops the stalled download and removes its
        // temporary file instead of leaking network use and storage.
        #expect(await source.snapshot().cancelled)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    @Test(arguments: [false, true], ["index.m3u8", "opaque.mp3"])
    func nativePlaylistRoutingPreservesPositionRateAndLatestIntent(paused: Bool, name: String) async throws {
        let index = try #require(Bundle.module.url(forResource: "index", withExtension: "m3u8", subdirectory: "Fixtures/StreamingHLS"))
        let folder = index.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let contents = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let playlist = try #require(contents["index.m3u8"])
        let server = try await LoopbackHTTPServer.start { request in
            let key = String(request.path.split(separator: "?")[0].split(separator: "/").last ?? "")
            if key == "index.m3u8" || key == "opaque.mp3" {
                return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: playlist)
            }
            if let data = contents[key], key.hasSuffix(".ts") { return .init(headers: ["Content-Type": "video/mp2t"], body: data) }
            return .init(status: 404)
        }
        defer { server.stop() }
        let url = server.url.deletingLastPathComponent().appendingPathComponent(name)
        try await withEngine { engine, events in
            let captured = captureSources(engine)
            var remote = episode(); remote.userState.isDownloaded = false
            remote.details.media?.url = url.absoluteString
            let command = UUID()
            engine.load(episode: remote, generation: UUID(), positionMilliseconds: 3883)
            try engine.setSpeed(1.5, commandID: command)
            engine.play(commandID: command)
            if paused { engine.pause(commandID: command) }
            try await wait { !events.ready.isEmpty || !events.failures.isEmpty }
            #expect(events.failures.isEmpty && events.ready.count == 1)
            let ready = try #require(events.ready.first)
            // An HLS playlist (even behind an .mp3 URL) plays from the saved
            // position at the chosen speed, honouring the latest play/pause.
            #expect(abs(ready.sample.positionMilliseconds - 3883) <= 250 && ready.speed == 1.5)
            #expect(ready.sample.status == (paused ? .paused : .playing))
            let source = try #require(captured.sources.first)
            #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
            captured.callbacks[0](URLError(.badServerResponse))
            try await Task.sleep(for: .milliseconds(100))
            #expect(events.failures.isEmpty)
            if paused { #expect(engine.nativePlayer?.rate == 0) }
            else { try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= 4500 } }
        }
    }
}


extension AVPlayerPlaybackEngineTests {
    // 1× only: AVPlayer refuses every rate above 1× for an item of indefinite duration
    // (SetRateFailed), so the app plays identified open-ended streams through its processed engine.
    // The same stream at 1.5×, with pause and resume, is verified on that route by AuthenticatedPlaybackTests
    // .privateOpenEndedStreamPlaysAtOneAndAHalfSpeedThroughApplicationRoute.
    @Test(arguments: [Float(1)])
    func unknownLengthStreamStartsBeforeEOFAndPreservesPauseResume(speed: Float) async throws {
        let bytes = try Data(contentsOf: fixture)
        let prefix = bytes.prefix(bytes.count * 3 / 4)
        // A valid chunk, but deliberately no terminating zero chunk or connection EOF.
        let body = Data("\(String(prefix.count, radix: 16))\r\n".utf8) + prefix + Data("\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                  body: body, keepConnectionOpen: true)
        }
        defer { server.stop() }
        try await withEngine { engine, events in
            let captured = captureSources(engine)
            var remote = episode(); remote.userState.isDownloaded = false
            remote.details.media?.url = server.url.absoluteString
            let command = UUID()
            engine.load(episode: remote, generation: UUID(), positionMilliseconds: 0)
            try engine.setSpeed(speed, commandID: command)
            engine.play(commandID: command)
            do { try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= 1000 } }
            catch {
                print("Unknown-length diagnostic: reading=\(String(describing: engine.reading)), native=\(String(describing: engine.nativePlayer?.currentItem?.status)), time=\(String(describing: engine.nativePlayer?.currentTime())), rate=\(String(describing: engine.nativePlayer?.rate)), ranges=\(String(describing: engine.nativePlayer?.currentItem?.seekableTimeRanges)), failures=\(events.failures)")
                if let source = captured.sources.first { print("Source: \(await source.snapshot())") }
                throw error
            }
            // A stream without a known length starts before the download ends,
            // keeps the chosen speed and pauses/resumes where it stopped.
            #expect(events.failures.isEmpty && events.ready.count == 1)
            let source = try #require(captured.sources.first)
            #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
            captured.callbacks[0](URLError(.networkConnectionLost))
            #expect(engine.reading?.commandID == command && engine.reading?.speed == speed)
            engine.pause(commandID: UUID())
            let stopped = try #require(engine.reading?.sample.positionMilliseconds)
            try await Task.sleep(for: .milliseconds(200))
            #expect(abs((engine.reading?.sample.positionMilliseconds ?? 0) - stopped) <= 100)
            engine.play(commandID: UUID())
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= stopped + 1000 }
            #expect(events.failures.isEmpty)
        }
    }
}

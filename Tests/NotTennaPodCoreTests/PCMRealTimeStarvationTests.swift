import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Real-time sufficiency of the production processed-PCM path (a device report: constant skipping at
/// 1.75× on a downloaded MP3). A long MP3 plays through the application's factory settings and Apple's renderer
/// while the main thread is blocked 400 ms of every second, like a busy screen, and every core is loaded. Any
/// moment the renderer runs out of written audio is a gap a listener hears (`PCMStarvationDiagnostics`); the
/// heard position must also advance at the selected speed. The former 0.37 s queue failed this from ~250 ms.
@Suite(.serialized) @MainActor struct PCMRealTimeStarvationTests {
    @MainActor final class Driver: AudioSessionActivationDriver {
        func setActive(_ active: Bool) async throws -> Bool { true }
    }

    private func withProductionPlayer(speed: Float, _ body: (PlaybackCoordinator, PCMPlaybackEngine) async throws -> Void) async throws {
        let fixture = try #require(Bundle.module.url(forResource: "half-hour.mp3", withExtension: nil, subdirectory: "Fixtures/LongMP3"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FeedLibraryStore(url: dir.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Real time", episodes: [
            ParsedEpisode(identifier: "1", title: "Episode", media: ParsedMedia(url: "https://example.test/1.mp3", size: 0, durationMilliseconds: 1_800_000))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let factories = PCMPlaybackFactory(cacheDirectory: dir.appendingPathComponent("cache"),
            minimumQueuedSeconds: PCMRecoveryFactory.productionQueuedSeconds,
            makeTransport: { NativeSampleBufferTransport(muted: true) })
        let engine = PCMPlaybackEngine(driver: Driver(), resolveFactory: { _, url in
            try #require(try await factories.processedIfSupported(url: url, proxy: PodcastProxy(), credentials: nil, userAgent: "t"))
        }, source: { _ in fixture })
        let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
            var preferences = PlaybackPreferences(); preferences.speed = speed; return preferences
        }, clock: { Date() })
        let episodeID = try #require(try await store.feeds().first?.episodes.first?.id)
        do {
            try await player.select(episodeID: episodeID)
            let deadline = ContinuousClock.now + .seconds(10)
            while player.phase != .playing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(player.phase == .playing)
            try await body(player, engine)
            try await player.pause()
        } catch { engine.unload(); try? await store.close(); throw error }
        engine.unload(); try await store.close()
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    @Test(arguments: [Float(1), 1.75, 3])
    func busyMainThreadAndLoadedCoresNeverStarveTheRenderer(speed: Float) async throws {
        try await withProductionPlayer(speed: speed) { _, engine in
            try await Task.sleep(for: .milliseconds(500))
            let spinning = Atomic<Bool>(true)
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                Thread.detachNewThread { var x = 0.0; while spinning.load(ordering: .relaxed) { x += sin(x) } }
            }
            defer { spinning.store(false, ordering: .relaxed) }
            PCMStarvationDiagnostics.reset()
            let startMedia = Double(engine.reading?.sample.positionMilliseconds ?? 0) / 1000
            let start = ContinuousClock.now
            while start.duration(to: .now) < .seconds(8) {
                usleep(400_000) // the main thread is busy, as with heavy synchronous screen work
                try await Task.sleep(for: .milliseconds(600))
            }
            let elapsed = Self.seconds(start.duration(to: .now))
            let advanced = Double(engine.reading?.sample.positionMilliseconds ?? 0) / 1000 - startMedia
            let starvation = PCMStarvationDiagnostics.current
            #expect(starvation.events == 0, "renderer ran dry \(starvation.events)× for \(starvation.overrunSeconds) s at \(speed)×")
            #expect(abs(advanced / elapsed - Double(speed)) / Double(speed) < 0.03, "heard \(advanced / elapsed)× at \(speed)×")
        }
    }

    /// The deeper queue keeps a speed change within about a second, comparable to Android's AudioTrack buffer.
    @Test func speedChangeIsHeardWithinASecondAndAHalf() async throws {
        try await withProductionPlayer(speed: 1) { player, engine in
            try await Task.sleep(for: .seconds(2))
            let command = ContinuousClock.now
            try await player.setSpeed(2)
            var samples: [(Double, Double)] = []
            while command.duration(to: .now) < .seconds(3) {
                samples.append((Self.seconds(command.duration(to: .now)), Double(engine.reading?.sample.positionMilliseconds ?? 0) / 1000))
                try await Task.sleep(for: .milliseconds(50))
            }
            let heard = samples.indices.first { i in
                guard let j = samples.indices.first(where: { samples[$0].0 >= samples[i].0 + 0.3 }) else { return false }
                return (samples[j].1 - samples[i].1) / (samples[j].0 - samples[i].0) >= 1.9
            }.map { samples[$0].0 }
            let delay = try #require(heard, "2× was never heard")
            #expect(delay < 1.5, "2× heard after \(delay) s")
        }
    }

    @Test func productionQueueHoldsAboutASecondAtEverySampleRate() throws {
        var factory = try PCMRecoveryFactory(url: URL(fileURLWithPath: "/dev/null"), makeTransport: { NativeSampleBufferTransport(muted: true) })
        factory.minimumQueuedSeconds = PCMRecoveryFactory.productionQueuedSeconds
        for rate in [8_000, 22_050, 44_100, 48_000, 96_000] {
            let seconds = Double(factory.queuedBuffers(sampleRate: rate) * 4096) / Double(rate)
            #expect(seconds >= 1 && seconds < 2.1, "\(rate) Hz queues \(seconds) s")
        }
        factory.minimumQueuedSeconds = 0
        #expect(factory.queuedBuffers(sampleRate: 48_000) == 4) // tests keep their explicit queue
    }
}

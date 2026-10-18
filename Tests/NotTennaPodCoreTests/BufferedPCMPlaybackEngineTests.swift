import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor
struct BufferedPCMPlaybackEngineTests {
    private let helper = PCMPlaybackEngineTests()

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"])
    func HTTPPlaybackPausePersistenceAndSeekUseSharedRecovery(name: String) async throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
        let data = try Data(contentsOf: url)
        let server = try await LoopbackHTTPServer.start { _ in .init(body: data) }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episode = ParsedEpisode(identifier: "audio", title: "Audio",
            media: ParsedMedia(url: server.url.absoluteString, size: Int64(data.count), durationMilliseconds: 8000))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Codec", episodes: [episode]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
            validator: nil, permanentRedirectURL: nil))
        let outputs = PCMPlaybackEngineTests.Outputs(), clock = PCMPlaybackEngineTests.Clock()
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), makeFactory: { url in
            try PCMRecoveryFactory(bufferedURL: url, makeTransport: {
                let transport = SampleBufferPCMOutputTests.Transport()
                outputs.values.append(transport); return transport
            })
        }, positionTicker: outputs.ticker, now: { clock.now })
        let player = PlaybackCoordinator(store: store, engine: engine, clock: { clock.date })
        do {
            try await player.select(episodeID: 1, play: false)
            try await helper.wait { player.phase == .paused || player.phase == .failed }
            try #require(player.phase == .paused && outputs.values.count == 1)
            // The 8-second file shows its real duration (within 50 ms).
            #expect(abs((engine.reading?.sample.durationMilliseconds ?? 0) - 8000) <= 50)
            try await player.play()
            try await helper.wait { outputs.values[0].playing }
            outputs.values[0].advance(4800)
            clock.now += 1000
            try await player.pause()
            #expect(player.sample?.positionMilliseconds == 100)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
            try await player.setSpeed(2)
            try await player.setSkipSilence(true)
            let late = outputs.values[0].onTimeChanged
            try await player.seek(to: 4000)
            // The paused seek lands within 0.25 s of 4 s with the new speed and
            // skip-silence settings; the old output is stopped (no double audio).
            func landed() -> Bool { abs(Int(engine.reading?.sample.positionMilliseconds ?? -1_000) - 4000) <= 250 }
            do {
                try await helper.wait { outputs.values.count == 2 && landed() && engine.reading?.buffering == false }
            } catch {
                print("Buffered engine seek: reading=\(String(describing: engine.reading)), phase=\(player.phase), outputs=\(outputs.values.count)")
                throw error
            }
            #expect(outputs.values[0].closed && !outputs.values[1].playing)
            #expect(engine.reading?.speed == 2 && engine.reading?.skipSilence == true)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
            // A late tick from the replaced output cannot move the position.
            late?(); outputs.values[0].advance(999999)
            #expect(landed())
            try await player.play()
            try await helper.wait { outputs.values[1].playing }
            try await player.stop()
            #expect(outputs.values.allSatisfy { $0.closed })
            #expect(try await store.playbackSession()?.status == .paused)
            #expect(player.phase == .stopped)
        } catch { engine.unload(); try? await store.close(); throw error }
        engine.unload(); try await store.close()
    }
}

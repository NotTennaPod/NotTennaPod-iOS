import Foundation
import Testing
@testable import NotTennaPodCore

/// With skip silence saved on, media that only AVPlayer can play (HLS) plays without skipping silence
/// and the saved preference stays on for the next item; a large-art MP3 takes the processed route and
/// skips silence (without a notice).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct PlaybackSilenceFallbackTests {
    private func wait(_ check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !check(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(check())
    }

    @Test func savedSkipSilencePlaysHLSWithoutFailingAndKeepsThePreference() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("silence-fallback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
#if SWIFT_PACKAGE
        let folder = try #require(Bundle.module.url(forResource: "index", withExtension: "m3u8",
            subdirectory: "Fixtures/StreamingHLS")).deletingLastPathComponent()
#else
        let folder = try #require(Bundle(for: SilenceFallbackFixtures.self).url(forResource: "index", withExtension: "m3u8",
            subdirectory: "StreamingHLS")).deletingLastPathComponent()
#endif
        let hls = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let server = try await LoopbackHTTPServer.start { request in
            let name = String(request.path.split(separator: "/").last ?? "")
            guard let bytes = hls[name] else { return .init(status: 404) }
            return .init(headers: ["Content-Type": name.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t"], body: bytes)
        }
        defer { server.stop() }
        let audio = try Data(contentsOf: LargeID3TagRoutingTests.fixture("playback-30sec"))
        let plain = root.appendingPathComponent("plain.mp3"), art = root.appendingPathComponent("art.mp3")
        try audio.write(to: plain)
        try (LargeID3TagRoutingTests.tag(length: 3 * LargeID3TagRoutingTests.mebibyte) + audio).write(to: art)
        let playlist = server.url.deletingLastPathComponent().appendingPathComponent("index.m3u8")
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Silence", episodes: [
            ("plain", plain), ("hls", playlist), ("art", art)].map {
                ParsedEpisode(identifier: $0.0, title: $0.0, media: ParsedMedia(url: $0.1.absoluteString, size: 0, durationMilliseconds: 30_000))
            }), source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
            validator: nil, permanentRedirectURL: nil))
        var ids: [String: Int64] = [:]
        for candidate in Int64(1)...3 { if let title = try await store.episode(id: candidate)?.details.title { ids[title] = candidate } }
        func id(_ title: String) throws -> Int64 { try #require(ids[title]) }
        let preferences = root.appendingPathComponent("speed.json")
        let settings = try PlaybackSpeedPreferenceStore(file: preferences)
        try settings.setGlobalSkipSilence(true)
        let local = ApplicationStreamRoute.engine(cacheDirectory: root.appendingPathComponent("cache"), credentials: nil)
        let routes = RoutedPlaybackEngine(local: local)
        let player = PlaybackCoordinator(store: store, engine: routes, speedPreferences: settings)
        func play(_ title: String) async throws {
            try await player.select(episodeID: id(title), play: true)
            try await wait { player.phase == .failed || player.phase == .playing && (player.sample?.positionMilliseconds ?? 0) >= 300 }
            try #require(player.phase == .playing, "\(title) did not play")
        }
        try await play("plain")
        #expect(routes.supportsSkipSilence && player.skipSilence && local.reading?.skipSilence == true)
        // The playlist only AVPlayer can play starts and keeps the saved setting shown and stored.
        try await play("hls")
        #expect(!routes.supportsSkipSilence && player.skipSilence && local.reading?.skipSilence == true)
        #expect(settings.value.silence.global)
        // Changing skip silence during it keeps the item playing; positions keep arriving.
        try await player.setSkipSilence(false, alsoGlobal: true)
        #expect(!player.skipSilence && !settings.value.silence.global)
        try await player.setSkipSilence(true, alsoGlobal: true)
        #expect(player.skipSilence && settings.value.silence.global)
        let position = player.sample?.positionMilliseconds ?? 0
        try await wait { player.phase != .playing || (player.sample?.positionMilliseconds ?? 0) > position + 300 }
        #expect(player.phase == .playing && player.skipSilence && local.reading?.skipSilence == true)
        // The large-art MP3 is processed, with silence skipping applied.
        try await play("art")
        #expect(routes.supportsSkipSilence && player.skipSilence && local.reading?.skipSilence == true)
        try await player.stop()
        // A relaunch reads the same saved preference.
        let relaunched = try PlaybackSpeedPreferenceStore(file: preferences)
        #expect(relaunched.value.silence.global)
        let restored = PlaybackCoordinator(store: store, engine: RoutedPlaybackEngine(local: ApplicationStreamRoute.engine(
            cacheDirectory: root.appendingPathComponent("cache"), credentials: nil)), speedPreferences: relaunched)
        try await restored.restore()
        #expect(restored.skipSilence)
        try await store.close()
    }
}
#if !SWIFT_PACKAGE
private final class SilenceFallbackFixtures: NSObject {}
#endif

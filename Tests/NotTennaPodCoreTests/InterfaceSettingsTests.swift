import Foundation
import Testing
@testable import NotTennaPodCore

/// Theme, Full black, Use episode cover and the global playback speed against the Android oracle.
/// Expected values come from the oracle, not the Swift code.
@Suite(.serialized) @MainActor
struct InterfaceSettingsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let oracle: [String: Any] = {
        let url = root.appendingPathComponent("TestSupport/Data/interface-settings/expected/interface-settings.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()
    private static func cases(_ key: String) -> [[String: Any]] { oracle[key] as! [[String: Any]] }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M31Interface-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    @Test func themeResolutionAndActiveCardMatchTheOracle() {
        let cases = Self.cases("theme_cases")
        #expect(cases.count == 20)
        for item in cases {
            let stored = item["stored"] as? String
            let preferences = InterfacePreferences(theme: ThemePreference(stored: stored), blackTheme: item["black"] as! Bool)
            let resolved = preferences.resolvedTheme(systemIsDark: item["systemDark"] as! Bool)
            #expect(resolved.rawValue == item["resolved"] as! String, "\(item)")
            let card = switch preferences.theme { case .system: "SYSTEM"; case .light: "LIGHT"; case .dark: "DARK" }
            #expect(card == item["activeCard"] as! String, "\(item)")
        }
    }

    @Test func storeUsesAndroidDefaultsKeysAndValuesAndSurvivesReopening() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("interface-preferences.json")
            let store = try InterfacePreferenceStore(file: file)
            #expect(store.value == InterfacePreferences(theme: .system, blackTheme: false, useEpisodeCover: true))
            #expect(!FileManager.default.fileExists(atPath: file.path), "Reading defaults writes nothing")
            try store.update(.init(theme: .dark, blackTheme: true, useEpisodeCover: false))
            // Independent check of the saved file: Android's keys and stored theme strings.
            let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(saved["prefTheme"] as? String == "1" && saved["prefThemeBlack"] as? Bool == true
                    && saved["prefEpisodeCover"] as? Bool == false && saved.count == 3)
            #expect(try InterfacePreferenceStore(file: file).value == .init(theme: .dark, blackTheme: true, useEpisodeCover: false))
            try store.update(.init(theme: .light))
            #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["prefTheme"] as? String == "0")
            try store.update(.init(theme: .system))
            #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["prefTheme"] as? String == "system")
        }
    }

    @Test func unknownOrMissingValuesReadAsAndroidDefaultsAndCorruptFilesAreKept() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("interface-preferences.json")
            try Data(#"{"prefTheme":"2"}"#.utf8).write(to: file)
            #expect(try InterfacePreferenceStore(file: file).value == InterfacePreferences())
            try Data("{}".utf8).write(to: file)
            #expect(try InterfacePreferenceStore(file: file).value == InterfacePreferences())
            try Data("not json".utf8).write(to: file)
            #expect(throws: (any Error).self) { try InterfacePreferenceStore(file: file) }
            #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
        }
    }

    @Test func coverSelectionMatchesTheOracleForEverySurface() {
        let cases = Self.cases("cover_cases")
        #expect(cases.count == 72)
        #expect(Set(cases.map { $0["surface"] as! String }) == Set(EpisodeCoverSurface.allCases.map(\.rawValue)))
        for item in cases {
            let surface = try! #require(EpisodeCoverSurface(rawValue: item["surface"] as! String))
            let feedImage = item["feedImage"] as? String
            let own = EpisodeArtworkSelection.source(episodeImage: item["episodeImage"] as? String,
                hasEmbeddedPicture: item["embedded"] as! Bool, localMedia: item["localFile"] as? String, feedImage: feedImage)
            let cover = EpisodeArtworkSelection.cover(for: surface, own: own, feedImage: feedImage,
                                                      useEpisodeCover: item["useEpisodeCover"] as! Bool)
            #expect(cover.primary == item["primary"] as? String && cover.fallback == item["fallback"] as? String, "\(item)")
        }
    }

    @Test func coverSelectionUsesStoredEpisodeAndFeedImages() async throws {
        try await withDirectory { directory in
            let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            var withImage = ParsedEpisode(identifier: "a", title: "A", media: .init(url: "https://example.test/a.mp3", size: 1, durationMilliseconds: 1000))
            withImage.imageURL = "https://example.test/a.png"
            let plain = ParsedEpisode(identifier: "b", title: "B", media: .init(url: "https://example.test/b.mp3", size: 1, durationMilliseconds: 1000))
            var parsed = ParsedFeed(format: .rss, title: "Covers", episodes: [withImage, plain])
            parsed.imageURL = "https://example.test/feed.png"
            let feed = try await store.insert(.init(feed: parsed, source: "https://example.test/feed",
                responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
            let a = try #require(feed.episodes.first { $0.details.title == "A" }), b = try #require(feed.episodes.first { $0.details.title == "B" })
            for surface in EpisodeCoverSurface.allCases {
                #expect(EpisodeArtworkSelection.cover(for: surface, episode: a, feed: feed, useEpisodeCover: true)
                    == ("https://example.test/a.png", "https://example.test/feed.png"))
                #expect(EpisodeArtworkSelection.cover(for: surface, episode: a, feed: feed, useEpisodeCover: false).primary
                    == (surface.followsEpisodeCoverSetting ? "https://example.test/feed.png" : "https://example.test/a.png"))
                #expect(EpisodeArtworkSelection.cover(for: surface, episode: b, feed: feed, useEpisodeCover: true).primary == "https://example.test/feed.png")
            }
            try await store.close()
        }
    }

    @Test func speedResolutionMatchesTheOracle() {
        let cases = Self.cases("speed_cases")
        #expect(cases.count == 16)
        let feedID: Int64 = 1
        for item in cases {
            var preferences = PlaybackSpeedPreferences()
            preferences.global = Float(item["global"] as! Double)
            let feed = Float(item["feed"] as! Double)
            if feed != PlaybackSpeed.useGlobal { preferences.feeds[feedID] = feed }
            preferences.currentEpisodeID = (item["currentMedia"] as? Int).map(Int64.init)
            preferences.temporary = Float(item["temporary"] as! Double)
            let expected = Float(item["resolved"] as! Double)
            if let media = item["media"] as? Int {
                #expect(preferences.resolved(episodeID: Int64(media), feedID: feedID) == expected, "\(item)")
            } else {
                // Nothing selected: the dialog shows the global speed (PSU:31–33).
                #expect(preferences.global == expected, "\(item)")
            }
        }
    }

    /// The Settings speed dialog with nothing selected saves the global speed; a newly started episode uses it,
    /// and a podcast's own speed wins for that podcast's episodes.
    @Test func globalSpeedFromSettingsAppliesToNewPlaybackWhileAPodcastSpeedWins() async throws {
        try await withDirectory { directory in
            let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            let settings = try PlaybackSpeedPreferenceStore(file: directory.appendingPathComponent("speed.json"))
            func insert(_ title: String) async throws -> LibraryFeed {
                try await store.insert(.init(feed: .init(format: .rss, title: title, episodes: (1...2).map {
                    ParsedEpisode(identifier: "\(title)-\($0)", title: "\(title) \($0)",
                                  media: .init(url: "https://example.test/\(title)/\($0).mp3", size: 1, durationMilliseconds: 60_000))
                }), source: "https://example.test/\(title)", responseURL: URL(string: "https://example.test/\(title)")!,
                    validator: nil, permanentRedirectURL: nil))
            }
            let plain = try await insert("plain"), own = try await insert("own")
            let engine = SpeedEngine()
            let player = PlaybackCoordinator(store: store, engine: engine, speedPreferences: settings)
            try await player.setSpeed(1.5, alsoGlobal: true)
            #expect(settings.value.global == 1.5 && settings.value.currentEpisodeID == nil)
            try await player.select(episodeID: plain.episodes[0].id, play: false)
            #expect(player.speed == 1.5 && engine.speeds.last == 1.5)
            try settings.setFeed(own.id, speed: 1.25)
            try await player.select(episodeID: own.episodes[0].id, play: false)
            #expect(player.speed == 1.25 && engine.speeds.last == 1.25, "The podcast's own speed wins")
            // Changing the speed in the dialog now also changes the current episode, and the global default.
            try await player.setSpeed(2, alsoGlobal: true)
            #expect(player.speed == 2 && settings.value.global == 2 && settings.value.feeds[own.id] == 1.25)
            try await player.select(episodeID: own.episodes[1].id, play: false)
            #expect(player.speed == 1.25, "The old temporary speed does not carry over to a new episode")
            try await player.select(episodeID: plain.episodes[1].id, play: false)
            #expect(player.speed == 2)
            // Independent check of the saved file.
            let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("speed.json"))) as? [String: Any])
            #expect((saved["global"] as? Double) == 2)
            try await player.stop()
            try await store.close()
        }
    }
}

@MainActor private final class SpeedEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    var speeds: [Float] = []
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {}
    func play(commandID: UUID) {}
    func pause(commandID: UUID) {}
    func seek(to positionMilliseconds: Int64, commandID: UUID) {}
    func setSpeed(_ speed: Float, commandID: UUID) throws { speeds.append(speed) }
    func unload() {}
}

import Foundation
import Testing
@testable import NotTennaPodCore

/// "Set notification buttons" choices, defaults, persistence and the Now Playing
/// commands they offer. Expectations come from the Android oracle.
@Suite @MainActor struct NowPlayingButtonPreferenceTests {
    private struct Oracle: Decodable {
        struct Option: Decodable { let id: Int; let labelKey: String; let label: String }
        let preferenceKey: String
        let defaultIDs: [Int]
        let androidDialog: [Option]
        let iosDialog: [Option]
        let iosCommands: [String: String?]
    }
    private func oracle() throws -> Oracle {
        let url = try #require(Bundle.module.url(forResource: "now-playing-oracle", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NowPlayingButtons-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func choicesLabelsAndDefaultFollowTheAndroidSource() throws {
        let source = try oracle()
        #expect(NotificationButton.allCases.map(\.rawValue) == source.androidDialog.map(\.id))
        #expect(NotificationButton.allCases.map(\.titleKey) == source.androidDialog.map(\.labelKey))
        #expect(NotificationButton.offered.map(\.rawValue) == source.iosDialog.map(\.id))
        #expect(NotificationButtonPreferences().buttons.map(\.rawValue) == source.defaultIDs)
        // Only the offered buttons have an iOS command.
        for button in NotificationButton.allCases {
            let command = source.iosCommands[String(button.rawValue)] ?? nil
            #expect((command != nil) == NotificationButton.offered.contains(button))
        }
    }

    @Test func choicePersistsAcrossReopenAndIsPublishedAtOnce() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notification-buttons.json")
        let store = try NotificationButtonPreferenceStore(file: file)
        #expect(store.value.shows(.skipEpisode) && store.value.shows(.playbackSpeed))
        var events = store.events().makeAsyncIterator()
        #expect(await events.next() == store.value)
        try store.select([0])
        #expect(await events.next()?.buttons == [.skipEpisode])
        #expect(try NotificationButtonPreferenceStore(file: file).value.buttons == [.skipEpisode])
        try store.select([1])
        #expect(try NotificationButtonPreferenceStore(file: file).value.buttons == [.playbackSpeed])
        try store.select([])
        let reopened = try NotificationButtonPreferenceStore(file: file).value
        #expect(!reopened.shows(.skipEpisode) && !reopened.shows(.playbackSpeed))
        // Saved data is Android's id list, readable without the app's types.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(json?["buttons"] as? [Int] == [])
        try store.select([1, 0])
        #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["buttons"] as? [Int] == [2, 4])
        // A failed save keeps the previous choice.
        try FileManager.default.removeItem(at: root)
        #expect(throws: (any Error).self) { try store.select([0]) }
        #expect(store.value.buttons == [.skipEpisode, .playbackSpeed])
    }

    @Test func storedIDsFromAndroidShapesDecodeWithoutUnknownOrDuplicateButtons() throws {
        for (json, expected) in [("{}", [NotificationButton.skipEpisode, .playbackSpeed]),
                                 ("{\"buttons\":[4,3,99,4]}", [.playbackSpeed, .nextChapter]),
                                 ("{\"buttons\":[]}", [])] {
            #expect(try JSONDecoder().decode(NotificationButtonPreferences.self, from: Data(json.utf8)).buttons == expected)
        }
    }

    private func snapshot(canPlay: Bool = true, wantsPlayback: Bool = true, canSeek: Bool = true, canSkip: Bool = true,
                          canChangeRate: Bool = true) -> PlaybackSystemSnapshot {
        PlaybackSystemSnapshot(identity: .init(episodeID: 1, selectionID: UUID()), title: "Episode", positionMilliseconds: 0,
            durationMilliseconds: 100_000, rate: 1, defaultRate: 1, wantsPlayback: wantsPlayback, canSeek: canSeek,
            canSkip: canSkip, canChangeRate: canChangeRate, canPlay: canPlay, isVideo: false)
    }

    /// Each offered button × chosen/not chosen, with the other commands unaffected.
    @Test func eachButtonControlsOnlyItsOwnCommand() {
        let hardware = PlaybackHardwarePreferences(), intervals = PlaybackIntervalPreferences(), presets: [Float] = [1, 1.25, 1.5]
        for skip in [false, true] {
            for speed in [false, true] {
                let buttons = NotificationButtonPreferences(buttons: (skip ? [.skipEpisode] : []) + (speed ? [.playbackSpeed] : []))
                let offered = NowPlayingCommandAvailability.make(state: snapshot(), buttons: buttons, hardware: hardware,
                    intervals: intervals, presets: presets, remote: false)
                #expect(offered.nextTrack == skip)
                #expect(offered.changeRate == speed)
                #expect(offered.pause && offered.toggle && offered.stop && !offered.play)
                #expect(offered.skipForward && offered.skipBackward && offered.previousTrack && offered.changePosition)
                #expect(offered.supportedRates == presets)
            }
        }
        let paused = NowPlayingCommandAvailability.make(state: snapshot(wantsPlayback: false), buttons: .init(),
            hardware: hardware, intervals: intervals, presets: presets, remote: false)
        #expect(paused.play && !paused.pause)
    }

    @Test func chosenCommandsStillNeedAPlayableEpisode() {
        let buttons = NotificationButtonPreferences(), hardware = PlaybackHardwarePreferences(), intervals = PlaybackIntervalPreferences()
        let none = NowPlayingCommandAvailability.make(state: nil, buttons: buttons, hardware: hardware, intervals: intervals,
            presets: [1, 1.5], remote: false)
        #expect(!none.nextTrack && !none.changeRate && !none.pause && !none.stop)
        let loading = NowPlayingCommandAvailability.make(state: snapshot(canSeek: false, canSkip: false, canChangeRate: false),
            buttons: buttons, hardware: hardware, intervals: intervals, presets: [1, 1.5], remote: false)
        #expect(!loading.nextTrack && !loading.changeRate && !loading.skipForward)
    }

    /// Android's speed button steps through the chosen speeds (`Media3PlaybackService.setNextPlaybackSpeed`); a receiver takes at most 2×.
    @Test func speedPresetsAreTheOfferedRatesWithinTheRoute() {
        let offered = { (remote: Bool) in
            NowPlayingCommandAvailability.make(state: self.snapshot(), buttons: .init(), hardware: .init(), intervals: .init(),
                presets: [0.75, 1, 1.5, 2.5, 3], remote: remote).supportedRates
        }
        #expect(offered(false) == [0.75, 1, 1.5, 2.5, 3])
        #expect(offered(true) == [0.75, 1, 1.5])
    }
}

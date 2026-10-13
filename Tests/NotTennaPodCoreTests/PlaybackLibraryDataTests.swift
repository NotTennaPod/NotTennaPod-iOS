import Foundation
import Testing
@testable import NotTennaPodCore

/// PROTOCOL §15.4: speeds and the shownotes position keyed by local IDs are library data. The standalone library keeps
/// today's files and format; a server library keeps its own in `playback-library.json`, while the device-wide speed
/// values stay in the root file for every library.
@Suite @MainActor struct PlaybackLibraryDataTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackLibrary-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The pairs of an Int64-keyed map as `JSONEncoder` writes it: a flat `[key, value, key, value, …]` array.
    private func pairs(_ value: Any?) -> [Int64: Double]? {
        guard let array = value as? [NSNumber], array.count.isMultiple(of: 2) else { return nil }
        return Dictionary(uniqueKeysWithValues: stride(from: 0, to: array.count, by: 2).map { (array[$0].int64Value, array[$0 + 1].doubleValue) })
    }

    /// The standalone store writes what it wrote before: one file, the whole `PlaybackSpeedPreferences`, with the same
    /// keys and the per-feed maps as flat `[feedID, value, …]` arrays. (Content and structure are compared, not bytes:
    /// `JSONEncoder` does not keep key or dictionary order between encodings.)
    @Test func standaloneSpeedFileKeepsItsFormat() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("playback-speed-preferences.json")
        let store = try PlaybackSpeedPreferenceStore(file: file)
        try store.setFeed(7, speed: 1.5, skipSilence: .aggressive)
        try store.activate(episodeID: 70, resolvedSpeed: 1.5, resolvedSkipSilence: true)
        try store.setGlobal(1.25)
        let data = try Data(contentsOf: file)
        #expect(try JSONDecoder().decode(PlaybackSpeedPreferences.self, from: data) == store.value)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["global", "presets", "feeds", "currentEpisodeID", "temporary", "silence"])
        #expect(json["global"] as? Double == 1.25 && json["temporary"] as? Double == 1.5)
        #expect((json["presets"] as? [Double]) == [1, 1.25, 1.5])
        #expect(pairs(json["feeds"]) == [7: 1.5])
        #expect((json["currentEpisodeID"] as? NSNumber)?.int64Value == 70)
        let silence = try #require(json["silence"] as? [String: Any])
        #expect(Set(silence.keys) == ["global", "feeds", "temporary"])
        #expect(pairs(silence["feeds"]) == [7: Double(PlaybackSilencePreference.aggressive.rawValue)])
        #expect((silence["temporary"] as? NSNumber)?.intValue == PlaybackSilencePreference.aggressive.rawValue)
        #expect(silence["global"] as? Bool == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["playback-speed-preferences.json"])
        let reopened = try PlaybackSpeedPreferenceStore(file: file)
        #expect(reopened.value == store.value)
    }

    /// A server library reads and writes its feed speeds, feed silence and current episode with its speed and silence in
    /// its own file; global speed, presets and global skip silence are shared with the standalone library, whose
    /// library-keyed values in the root file are never touched.
    @Test func serverLibrarySpeedsAreLibraryDataAndDeviceSpeedsAreShared() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootFile = root.appendingPathComponent("playback-speed-preferences.json")
        let standalone = try PlaybackSpeedPreferenceStore(file: rootFile)
        try standalone.setFeed(1, speed: 2, skipSilence: .off)
        try standalone.activate(episodeID: 10, resolvedSpeed: 2, resolvedSkipSilence: false)
        try standalone.setCurrent(2.5, alsoGlobal: false)
        try standalone.setGlobal(1.1)
        let standaloneValue = standalone.value

        let libraryFile = try PlaybackLibraryFile(url: root.appendingPathComponent("playback-library.json"))
        let server = try PlaybackSpeedPreferenceStore(file: rootFile, library: libraryFile)
        #expect(server.value.global == 1.1, "device-wide")
        #expect(server.value.feeds.isEmpty && server.value.currentEpisodeID == nil && server.value.temporary == PlaybackSpeed.useGlobal,
                "the standalone library's feed 1 and episode 10 are not this library's")
        #expect(server.value.resolved(episodeID: 10, feedID: 1) == 1.1, "local IDs repeat across libraries")
        try server.setFeed(1, speed: 0.8, skipSilence: .aggressive)
        try server.activate(episodeID: 10, resolvedSpeed: 0.8, resolvedSkipSilence: true)
        try server.setCurrent(0.9, alsoGlobal: false)
        try server.setPresets([1, 1.75, 3])
        try server.setGlobalSkipSilence(true)

        let reopenedStandalone = try PlaybackSpeedPreferenceStore(file: rootFile)
        var expected = standaloneValue
        expected.presets = [1, 1.75, 3]; expected.silence.global = true
        #expect(reopenedStandalone.value == expected, "only the device-wide values changed in the root file")
        #expect(reopenedStandalone.value.resolved(episodeID: 10, feedID: 1) == 2.5)

        let reopened = try PlaybackSpeedPreferenceStore(file: rootFile, library: try PlaybackLibraryFile(url: libraryFile.url))
        #expect(reopened.value.feeds == [1: 0.8] && reopened.value.silence.feeds == [1: .aggressive])
        #expect(reopened.value.currentEpisodeID == 10 && reopened.value.temporary == 0.9 && reopened.value.silence.temporary == .aggressive)
        #expect(reopened.value.presets == [1, 1.75, 3] && reopened.value.silence.global && reopened.value.global == 1.1)
        #expect(reopened.value.resolved(episodeID: 10, feedID: 1) == 0.9)
    }

    /// Each file is validated within its own recovery boundary. A damaged server-library file (here a
    /// feed speed of 0) is set aside in that library only; the valid standalone root file stays where it is, intact,
    /// and both open, exactly as the app opens them (`UnreadableSettingsFile` around each file).
    @Test func damagedServerSpeedsAreRecoveredInTheServerLibraryOnly() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = root.appendingPathComponent("playback-speed-preferences.json")
        let standalone = try PlaybackSpeedPreferenceStore(file: device)
        try standalone.setFeed(1, speed: 2)
        let original = try Data(contentsOf: device)
        let serverFile = root.appendingPathComponent("playback-library.json")
        var corrupt = PlaybackLibraryData(); corrupt.speeds.feeds[1] = 0; corrupt.shownotes = .init(episodeID: 4, offset: 10)
        try JSONEncoder().encode(corrupt).write(to: serverFile)
        var setAside: [String] = []
        let library = try UnreadableSettingsFile.open(serverFile, { try PlaybackLibraryFile(url: $0) },
                                                      setAside: { _ in setAside.append(serverFile.lastPathComponent) })
        let speeds = try UnreadableSettingsFile.open(device, { try PlaybackSpeedPreferenceStore(file: $0, library: library) },
                                                     setAside: { _ in setAside.append(device.lastPathComponent) })
        #expect(setAside == ["playback-library.json"], "only the damaged server-library file is set aside")
        #expect(try Data(contentsOf: device) == original, "the standalone root file is intact")
        #expect(speeds.value.feeds.isEmpty && library.value == PlaybackLibraryData(), "the server library starts from the defaults")
        #expect(try PlaybackSpeedPreferenceStore(file: device).value.feeds == [1: 2])
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("playback-library.json.unreadable-") }
        #expect(kept.count == 1, "the damaged bytes are kept beside it")
        // A damaged temporary speed is caught the same way.
        var temporary = PlaybackLibraryData(); temporary.speeds.temporary = -2
        try JSONEncoder().encode(temporary).write(to: serverFile)
        #expect(throws: PlaybackSpeedError.invalidSpeed) { _ = try PlaybackLibraryFile(url: serverFile) }
    }

    /// The shownotes position: today's file for the standalone library, `playback-library.json` for a server library,
    /// which shares the file with its speeds without either losing the other's values.
    @Test func shownotesPositionIsLibraryData() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let standaloneFile = root.appendingPathComponent("shownotes-scroll.json")
        let standalone = try ShownotesScrollStore(file: standaloneFile)
        try standalone.save(episodeID: 3, offset: 120)
        #expect(try String(decoding: Data(contentsOf: standaloneFile), as: UTF8.self).contains("\"episodeID\":3"))

        let library = try PlaybackLibraryFile(url: root.appendingPathComponent("playback-library.json"))
        let speeds = try PlaybackSpeedPreferenceStore(file: root.appendingPathComponent("playback-speed-preferences.json"), library: library)
        let notes = ShownotesScrollStore(library: library)
        #expect(notes.offset(for: 3) == nil, "the standalone library's episode 3 is another episode")
        try notes.save(episodeID: 3, offset: 40)
        try speeds.setFeed(2, speed: 1.5)
        let reopened = try PlaybackLibraryFile(url: library.url)
        #expect(ShownotesScrollStore(library: reopened).offset(for: 3) == 40)
        #expect(reopened.value.speeds.feeds == [2: 1.5])
        #expect(try ShownotesScrollStore(file: standaloneFile).offset(for: 3) == 120)
        try notes.reset()
        #expect(try PlaybackLibraryFile(url: library.url).value.shownotes == nil)
        #expect(try PlaybackLibraryFile(url: library.url).value.speeds.feeds == [2: 1.5])
    }
}

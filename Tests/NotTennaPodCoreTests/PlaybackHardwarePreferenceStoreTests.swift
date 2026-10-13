import Foundation
import Testing
@testable import NotTennaPodCore

@Suite @MainActor struct PlaybackHardwarePreferenceStoreTests {
    @Test func sourceChoicesDefaultsPersistenceAndLiveIntervals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PC-Hardware-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hardware.json"), owner = try PlaybackHardwarePreferenceStore(file: file)
        #expect(PlaybackHardwareAction.allCases.map(\.rawValue) == ["90", "89", "87", "88"])
        #expect(owner.value.forward == .forward && owner.value.previous == .rewind && owner.value.pauseOnDisconnect)
        var iterator = owner.events().makeAsyncIterator()
        #expect(await iterator.next() == owner.value)
        var settings = owner.value; settings.forward = .next; settings.previous = .restart; settings.pauseOnDisconnect = false
        try owner.update(settings)
        #expect(await iterator.next() == settings)
        #expect(try PlaybackHardwarePreferenceStore(file: file).value == settings)
        var intervals = PlaybackIntervalPreferences(); intervals.forwardSeconds = 45; intervals.rewindSeconds = 20
        #expect(PlaybackHardwareAction.forward.command(intervals: intervals) == .skip(seconds: 45, direction: .forward))
        #expect(PlaybackHardwareAction.rewind.command(intervals: intervals) == .skip(seconds: 20, direction: .rewind))
        #expect(settings.forward.command(intervals: intervals) == .next && settings.previous.command(intervals: intervals) == .restart)
        // Atomic-save failure keeps both the in-memory setting and published value.
        try FileManager.default.removeItem(at: root)
        #expect(throws: (any Error).self) { try owner.update(.init()) }
        #expect(owner.value == settings)
    }
    @Test func missingAndUnknownStoredChoicesKeepSourceDefaults() throws {
        for json in ["{}", "{\"forward\":\"invalid\",\"previous\":\"999\"}"] {
            let result = try JSONDecoder().decode(PlaybackHardwarePreferences.self, from: Data(json.utf8))
            #expect(result.forward == .forward && result.previous == .rewind && result.pauseOnDisconnect)
        }
    }
}

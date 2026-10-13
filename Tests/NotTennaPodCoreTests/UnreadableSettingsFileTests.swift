import Foundation
import Testing
@testable import NotTennaPodCore

@Suite @MainActor struct UnreadableSettingsFileTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Unreadable-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func damagedFileIsKeptAsideAndTheGroupStartsFromDefaults() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sleep-timer.json"), damaged = Data("{broken".utf8)
        try damaged.write(to: file)
        var reported: [any Error] = []
        let store = try UnreadableSettingsFile.open(file, now: Date(timeIntervalSince1970: 1_000), { try SleepTimerPreferenceStore(file: $0) }) {
            reported.append($0)
        }
        #expect(store.value == SleepTimerPreferences())
        #expect(reported.count == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent("sleep-timer.json.unreadable-1000")) == damaged)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        var changed = store.value; changed.vibrate.toggle()
        try store.update(changed)
        #expect(try SleepTimerPreferenceStore(file: file).value == changed)
    }

    @Test func readableAndMissingFilesOpenWithoutReport() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        var reported = 0
        let missing = try UnreadableSettingsFile.open(file, { try PlaybackQueuePreferenceStore(file: $0) }) { _ in reported += 1 }
        var saved = missing.value; saved.followQueue.toggle(); try missing.update(saved)
        let readable = try UnreadableSettingsFile.open(file, { try PlaybackQueuePreferenceStore(file: $0) }) { _ in reported += 1 }
        #expect(readable.value == saved && reported == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["queue.json"])
    }

    @Test func failureWithNothingToSetAsideIsRethrown() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("missing/queue.json")
        struct Failed: Error {}
        var reported = 0
        #expect(throws: Failed.self) {
            _ = try UnreadableSettingsFile.open(file, { _ -> Int in throw Failed() }) { _ in reported += 1 }
        }
        #expect(reported == 0)
    }
}

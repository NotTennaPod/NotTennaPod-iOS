import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor
struct DownloadPreferenceStoreTests {
    @Test func defaultsAndAllChoicesSurviveReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preferences.json")
        let store = try DownloadPreferenceStore(file: file)
        #expect(!store.value.allowMobile)
        #expect(store.value.enqueue)
        #expect(!store.value.deleteRemovesFromQueue)
        #expect(store.value.enqueueLocation == .back)
        var preferences = store.value
        preferences.allowMobile = true
        preferences.enqueue = false
        preferences.deleteRemovesFromQueue = true
        preferences.enqueueLocation = .front
        try store.update(preferences)
        #expect(try DownloadPreferenceStore(file: file).value == preferences)
    }

    @Test func corruptPreferencesAreReportedAndRetained() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let invalid = Data("{broken".utf8)
        try invalid.write(to: file)
        #expect(throws: (any Error).self) { try DownloadPreferenceStore(file: file) }
        #expect(try Data(contentsOf: file) == invalid)
    }

    @Test func failedWriteDoesNotPublishUnsavedChoices() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing/preferences.json")
        let store = try DownloadPreferenceStore(file: file)
        let original = store.value
        var changed = original
        changed.allowMobile = true
        #expect(throws: (any Error).self) { try store.update(changed) }
        #expect(store.value == original)
    }
}

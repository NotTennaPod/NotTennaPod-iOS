import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite struct PlaybackIntervalPreferenceTests {
    @Test func defaultsAndEverySourceChoicePersistIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("intervals.json"), store = try PlaybackIntervalPreferenceStore(file: file)
        #expect(store.value.rewindSeconds == 10 && store.value.forwardSeconds == 30)
        #expect(PlaybackIntervalPreferences.choices == [5, 10, 15, 20, 30, 45, 60])
        for direction in PlaybackIntervalDirection.allCases {
            for index in PlaybackIntervalPreferences.choices.indices {
                let previous = store.value
                var value = previous; value.select(index, for: direction)
                try store.update(value)
                let reopened = try PlaybackIntervalPreferenceStore(file: file).value
                #expect(reopened == value && reopened.selectedIndex(for: direction) == index)
                #expect(reopened.seconds(for: direction == .forward ? .rewind : .forward) == previous.seconds(for: direction == .forward ? .rewind : .forward))
            }
        }
    }
    @Test func unknownStoredChoiceIsPreservedUntilSelectionAndMissingKeysKeepDefaults() throws {
        let value = try JSONDecoder().decode(PlaybackIntervalPreferences.self, from: Data("{\"rewindSeconds\":0}".utf8))
        #expect(value.forwardSeconds == 30 && value.rewindSeconds == 0 && value.selectedIndex(for: .rewind) == 0)
        var changed = value; changed.select(-1, for: .rewind); changed.select(99, for: .forward)
        #expect(changed == value)
        changed.select(0, for: .rewind)
        #expect(changed.rewindSeconds == 5)
        // A retained zero rewind cannot be mistaken for the forward-at-end completion command.
        #expect(PlaybackTiming.intervalSkip(positionMilliseconds: 30_000, durationMilliseconds: 30_000, seconds: 0, direction: .rewind) == .seek(30_000))
        #expect(PlaybackTiming.intervalSkip(positionMilliseconds: 30_000, durationMilliseconds: 30_000, seconds: 0, direction: .forward) == .complete)
        #expect(PlaybackTiming.intervalSkip(positionMilliseconds: 2_000, durationMilliseconds: -1, seconds: 5, direction: .rewind) == .seek(0))
    }
    @Test func failedWriteDoesNotPublishAnUnsavedValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("intervals.json"), store = try PlaybackIntervalPreferenceStore(file: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        var value = store.value; value.select(6, for: .forward)
        #expect(throws: (any Error).self) { try store.update(value) }
        #expect(store.value.forwardSeconds == 30)
    }
    @Test func everyPlayerObserverReceivesCommittedUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PlaybackIntervalPreferenceStore(file: directory.appendingPathComponent("intervals.json"))
        var first = store.events().makeAsyncIterator(), second = store.events().makeAsyncIterator()
        #expect(await first.next()?.forwardSeconds == 30)
        #expect(await second.next()?.rewindSeconds == 10)
        var value = store.value; value.select(6, for: .forward); try store.update(value)
        #expect(await first.next()?.forwardSeconds == 60)
        #expect(await second.next()?.forwardSeconds == 60)
    }
}

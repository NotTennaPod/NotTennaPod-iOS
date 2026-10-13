import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor
struct PlaybackSpeedPreferenceStoreTests {
    private func withStore(_ operation: (PlaybackSpeedPreferenceStore, URL) throws -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Speed-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try operation(PlaybackSpeedPreferenceStore(file: file), file)
    }

    @Test func defaultsAndEveryPreferenceSurviveReopening() throws {
        try withStore { store, file in
            #expect(store.value.global == 1 && store.value.presets == [1, 1.25, 1.5])
            #expect(store.value.feeds.isEmpty && store.value.currentEpisodeID == nil && store.value.temporary == -1)
            try store.setGlobal(1.25)
            try store.setFeed(10, speed: 0.75)
            try store.activate(episodeID: 1, resolvedSpeed: store.value.resolved(episodeID: 1, feedID: 10))
            try store.setCurrent(1.5, alsoGlobal: true)
            try store.setPresets([0.75, 1.5, 2])
            let restored = try PlaybackSpeedPreferenceStore(file: file)
            #expect(restored.value == store.value)
            #expect(restored.value.resolved(episodeID: 1, feedID: 10) == 1.5)
            #expect(restored.value.resolved(episodeID: 2, feedID: 10) == 0.75)
            #expect(restored.value.resolved(episodeID: 3, feedID: 20) == 1.5)
        }
    }

    @Test func globalFeedAndCurrentChangesRemainSeparateUntilNewSelection() throws {
        try withStore { store, _ in
            try store.setFeed(10, speed: 0.75)
            try store.activate(episodeID: 1, resolvedSpeed: 0.75)
            try store.setCurrent(2, alsoGlobal: false)
            #expect(store.value.global == 1 && store.value.feeds[10] == 0.75)
            try store.setGlobal(1.5)
            try store.setFeed(10, speed: 3)
            #expect(store.value.resolved(episodeID: 1, feedID: 10) == 2)
            #expect(store.value.resolved(episodeID: 2, feedID: 10) == 3)
            try store.setFeed(10, speed: PlaybackSpeed.useGlobal)
            #expect(store.value.feeds[10] == nil)
            #expect(store.value.resolved(episodeID: 1, feedID: 10) == 2)
            #expect(store.value.resolved(episodeID: 2, feedID: 10) == 1.5)
            try store.clearCurrent()
            #expect(store.value.temporary == 2 && store.value.currentEpisodeID == nil)
            #expect(store.value.resolved(episodeID: 1, feedID: 10) == 1.5)
        }
    }

    @Test func presetEditingSortsAddsDetectsDuplicatesAndPermitsRemovingEveryPreset() throws {
        try withStore { store, file in
            var selection = PlaybackSpeedPresetSelection(presets: store.value.presets)
            #expect(try !selection.add(1.25))
            #expect(try selection.add(0.75))
            try store.setPresets(selection.presets)
            #expect(store.value.presets == [0.75, 1, 1.25, 1.5])
            for rate in selection.presets { selection.remove(rate) }
            try store.setPresets(selection.presets)
            #expect(store.value.presets.isEmpty)
            #expect(try PlaybackSpeedPreferenceStore(file: file).value.presets.isEmpty)
            #expect(try selection.add(2.25))
            try store.setPresets(selection.presets)
            #expect(store.value.presets == [2.25] && store.value.global == 1)
        }
    }

    @Test func openDialogRetainsUnroundedSelectionsWhileReopenedDialogReadsStoredPrecision() throws {
        try withStore { store, file in
            var selection = PlaybackSpeedPresetSelection(presets: [])
            #expect(try selection.add(1.125))
            try store.setPresets(selection.presets)
            #expect(selection.presets == [1.125])
            #expect(store.value.presets == [1.12])
            #expect(try !selection.add(1.125))
            selection.remove(1.125)
            #expect(selection.presets.isEmpty)
            let reopened = PlaybackSpeedPresetSelection(presets: try PlaybackSpeedPreferenceStore(file: file).value.presets)
            #expect(reopened.presets == [1.12])
        }
    }

    @Test func persistedPresetFormattingUsesTwoDecimalsAndHalfEvenWithoutChangingGlobalRate() throws {
        try withStore { store, file in
            try store.setGlobal(1.125)
            try store.setPresets([1.125, 1.375, 1.5])
            #expect(store.value.presets == [1.12, 1.38, 1.5])
            #expect(store.value.global == 1.125)
            #expect(try PlaybackSpeedPreferenceStore(file: file).value.presets == [1.12, 1.38, 1.5])
        }
    }

    @Test func invalidChoicesLeaveSavedStateUnchanged() throws {
        try withStore { store, file in
            try store.setGlobal(1.25)
            let original = try Data(contentsOf: file)
            for invalid: Float in [0, -2, .nan, .infinity, -.infinity] {
                #expect(throws: PlaybackSpeedError.invalidSpeed) { try store.setGlobal(invalid) }
                #expect(throws: PlaybackSpeedError.invalidSpeed) { try store.setFeed(10, speed: invalid) }
                #expect(throws: PlaybackSpeedError.invalidSpeed) { try store.setPresets([invalid]) }
                #expect(throws: PlaybackSpeedError.invalidSpeed) { try store.setCurrent(invalid, alsoGlobal: true) }
            }
            #expect(store.value.global == 1.25)
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func corruptFilesArePreservedAndWriteFailureDoesNotPublishUnsavedState() throws {
        try withStore { store, file in
            let corrupt = Data("{broken".utf8)
            try corrupt.write(to: file)
            #expect(throws: (any Error).self) { try PlaybackSpeedPreferenceStore(file: file) }
            #expect(try Data(contentsOf: file) == corrupt)
            let blocked = try PlaybackSpeedPreferenceStore(file: file.appendingPathComponent("child.json"))
            #expect(throws: (any Error).self) { try blocked.setCurrent(2, alsoGlobal: true) }
            #expect(blocked.value == PlaybackSpeedPreferences())
            #expect(try Data(contentsOf: file) == corrupt)
            #expect(store.value == PlaybackSpeedPreferences())
        }
    }
}

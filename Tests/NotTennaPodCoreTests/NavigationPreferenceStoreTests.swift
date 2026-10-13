import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct NavigationPreferenceStoreTests {
    @Test func preferStreamingMigratesOffAndPersistsIndependentlyOfNavigationChoices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("navigation.json")
        try Data("{\"bottomNavigation\":false,\"defaultPage\":\"QueueFragment\"}".utf8).write(to: file)
        let store = try NavigationPreferenceStore(file: file)
        #expect(!store.value.streamOverDownload && !store.value.streamingSuggestionHidden)
        for preferStreaming in [true, false, true] {
            var changed = store.value
            changed.chooseStreamOverDownload(preferStreaming)
            try store.update(changed)
            let restored = try NavigationPreferenceStore(file: file).value
            #expect(restored.streamOverDownload == preferStreaming)
            #expect(restored.streamingSuggestionHidden)
            #expect(!restored.bottomNavigation && restored.defaultPage == "QueueFragment")
        }
        let last = store.value
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var changed = last; changed.streamOverDownload = false
        #expect(throws: (any Error).self) { try store.update(changed) }
        #expect(store.value == last)
    }
    @Test func releaseDefaultsAndBothModeChoicesSurviveReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("navigation.json")
        let owner = try NavigationPreferenceStore(file: file)
        #expect(owner.value.bottomNavigation && !owner.value.backButtonOpensDrawer)
        for bottom in [false, true] {
            var value = owner.value
            value.bottomNavigation = bottom; value.backButtonOpensDrawer = true
            value.configuration.hiddenTags = [NavigationDestination.downloads.rawValue]
            value.configuration.orderedTags = [NavigationDestination.queue.rawValue]
            try owner.update(value)
            #expect(try NavigationPreferenceStore(file: file).value == value)
        }
    }

    @Test func sharedSubscribersSeeChangesOnlyAfterSuccessfulPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try NavigationPreferenceStore(file: directory.appendingPathComponent("navigation.json"))
        var first = owner.events().makeAsyncIterator(), second = owner.events().makeAsyncIterator()
        #expect(await first.next() == owner.value)
        #expect(await second.next() == owner.value)
        var value = owner.value; value.bottomNavigation = false
        try owner.update(value)
        #expect(await first.next() == value)
        #expect(await second.next() == value)
        try FileManager.default.removeItem(at: directory)
        #expect(throws: (any Error).self) { try owner.update(NavigationPreferences()) }
        #expect(owner.value == value)
    }
}

import Foundation
import Testing
@testable import NotTennaPodCore

struct StreamDownloadUsageTests {
    private struct Oracle: Decodable {
        struct Case: Decodable {
            struct Expected: Decodable {
                let bits: UInt32
                let stream, download: Int32
                let streamBias, downloadBias: Bool
            }
            let actions: String
            let initialBits: UInt32
            let stream, download: Int32
            let hidden: Bool
            let expected: Expected
        }
        let referenceCommit: String
        let cases: [Case]
    }

    /// When the "prefer streaming/downloading?" suggestion appears matches the original class
    /// (the internal moving-average float bits are not compared).
    @Test func originalClassMatchesCountersAndStrictBiasBoundaries() throws {
        let url = try #require(Bundle.module.url(forResource: "stream-download-usage-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(oracle.cases.count == 2177)
        for (index, item) in oracle.cases.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: [
                "movingAverage": Float(bitPattern: item.initialBits),
                "streamExecutions": item.stream, "downloadExecutions": item.download
            ])
            var usage = try JSONDecoder().decode(StreamDownloadUsage.self, from: data)
            for action in item.actions { usage.log(action == "0" ? .stream : .download) }
            #expect(usage.streamExecutions == item.expected.stream, "case \(index)")
            #expect(usage.downloadExecutions == item.expected.download, "case \(index)")
            #expect(usage.hasSignificantBias(to: .stream, hidden: item.hidden) == item.expected.streamBias, "case \(index)")
            #expect(usage.hasSignificantBias(to: .download, hidden: item.hidden) == item.expected.downloadBias, "case \(index)")
        }
    }

    @Test(arguments: [StreamDownloadUsage.Action.stream, .download])
    func promptIsCheckedBeforeLoggingAndRequiresAnOppositePreference(action: StreamDownloadUsage.Action) {
        var usage = StreamDownloadUsage()
        var preferences = NavigationPreferences()
        preferences.streamOverDownload = action == .download
        let button: EpisodeDetailActions.Action = action == .stream ? .stream : .download
        for _ in 0..<8 {
            #expect(usage.suggestion(for: button, preferences: preferences) == nil)
            usage.log(action)
        }
        #expect(usage.suggestion(for: button, preferences: preferences) == action)
        #expect(usage.streamExecutions + usage.downloadExecutions == 8)
        let before = usage
        for _ in 0..<3 { #expect(usage.suggestion(for: button, preferences: preferences) == action) }
        #expect(usage == before) // Outside dismissal has no history/preference effect.
        preferences.streamingSuggestionHidden = true
        #expect(usage.suggestion(for: button, preferences: preferences) == nil)
        preferences.streamingSuggestionHidden = false
        preferences.streamOverDownload.toggle()
        #expect(usage.suggestion(for: button, preferences: preferences) == nil)
    }

    @Test func onlyTheTwoSourceActionsCanOfferConfiguration() {
        let actions: [EpisodeDetailActions.Action] = [.markRead, .visitWebsite, .pause, .playLocal, .play, .stream, .cancelDownload, .delete, .download]
        for history: StreamDownloadUsage.Action in [.stream, .download] {
            var usage = StreamDownloadUsage()
            for _ in 0..<20 { usage.log(history) }
            for prefer in [false, true] {
                for hidden in [false, true] {
                    var preferences = NavigationPreferences()
                    preferences.streamOverDownload = prefer
                    preferences.streamingSuggestionHidden = hidden
                    for action in actions {
                        let expected: StreamDownloadUsage.Action? = !hidden && history == .stream && action == .stream && !prefer ? .stream
                            : !hidden && history == .download && action == .download && prefer ? .download : nil
                        #expect(usage.suggestion(for: action, preferences: preferences) == expected)
                    }
                }
            }
        }
    }

    @MainActor @Test func historyPersistsWithoutChangingNavigationAndFailedWritesDoNotCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.json")
        let navigationFile = directory.appendingPathComponent("navigation.json")
        let navigation = try NavigationPreferenceStore(file: navigationFile)
        var preference = navigation.value
        preference.bottomNavigation = false
        try navigation.update(preference)
        let navigationBytes = try Data(contentsOf: navigationFile)
        let owner = try StreamDownloadUsageStore(file: file)
        #expect(owner.value == StreamDownloadUsage())
        for _ in 0..<8 { try owner.log(.stream) }
        let reopened = try StreamDownloadUsageStore(file: file)
        #expect(reopened.value == owner.value)
        #expect(try Data(contentsOf: navigationFile) == navigationBytes)
        #expect(reopened.value.suggestion(for: .stream, preferences: navigation.value) == .stream)
        preference.chooseStreamOverDownload(true)
        try navigation.update(preference)
        let suppressed = try NavigationPreferenceStore(file: navigationFile).value
        #expect(reopened.value.suggestion(for: .stream, preferences: suppressed) == nil)
        #expect(reopened.value == owner.value) // Choosing a preference logs no action.
        try navigation.update(NavigationPreferences())
        let before = reopened.value
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try reopened.log(.download) }
        #expect(reopened.value == before)
        #expect(throws: (any Error).self) { _ = try StreamDownloadUsageStore(file: file) }
        try FileManager.default.removeItem(at: file)
        try Data("broken".utf8).write(to: file)
        #expect(throws: (any Error).self) { _ = try StreamDownloadUsageStore(file: file) }
    }

    @MainActor @Test(arguments: [false, true])
    func acceptingMayAllowAnOppositeFutureSuggestionButDecliningSuppressesBoth(offerStreaming: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("navigation.json")
        let store = try NavigationPreferenceStore(file: file)
        var preferences = store.value
        preferences.streamOverDownload = !offerStreaming
        var usage = StreamDownloadUsage()
        let first: StreamDownloadUsage.Action = offerStreaming ? .stream : .download
        for _ in 0..<8 { usage.log(first) }
        let before = usage
        preferences.respondToStreamingSuggestion(offerStreaming: offerStreaming, accept: true)
        try store.update(preferences)
        preferences = try NavigationPreferenceStore(file: file).value
        #expect(preferences.streamOverDownload == offerStreaming)
        #expect(!preferences.streamingSuggestionHidden)
        #expect(usage == before)
        let other: StreamDownloadUsage.Action = offerStreaming ? .download : .stream
        for _ in 0..<20 { usage.log(other) }
        let button: EpisodeDetailActions.Action = offerStreaming ? .download : .stream
        #expect(usage.suggestion(for: button, preferences: preferences) == other)
        preferences.respondToStreamingSuggestion(offerStreaming: !offerStreaming, accept: false)
        try store.update(preferences)
        preferences = try NavigationPreferenceStore(file: file).value
        #expect(preferences.streamOverDownload == offerStreaming)
        #expect(preferences.streamingSuggestionHidden)
        for action: StreamDownloadUsage.Action in [.stream, .download] {
            for _ in 0..<20 { usage.log(action) }
            #expect(usage.suggestion(for: action == .stream ? .stream : .download, preferences: preferences) == nil)
        }
    }
}

import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct AllEpisodesFilterTests {
    private func withStore(_ body: (AllEpisodesFilterPreferenceStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AllEpisodesFilter-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("filter.json")
        try body(AllEpisodesFilterPreferenceStore(file: file), file)
    }
    private func episode(_ id: Int64 = 1, play: EpisodePlayState = .new, favorite: Bool = false, media: Bool = true) -> LibraryEpisode {
        var state = EpisodeUserState(); state.playState = play; state.isFavorite = favorite
        return .init(id: id, details: .init(title: "Episode", media: media ? .init(url: "https://example.invalid/media", size: 0) : nil), userState: state)
    }
    @Test func absentPreferenceDefaultAndRawTokensSurviveRecreation() throws {
        try withStore { store, file in
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(store.value.stored.values.isEmpty && !store.value.effective.isActive)
            try store.update(.init(values: ["new", "unknown", "include_archived", "", "unplayed"]))
            let raw = try JSONDecoder().decode(String.self, from: Data(contentsOf: file))
            #expect(raw == "new,unknown,include_archived,,unplayed")
            let reopened = try AllEpisodesFilterPreferenceStore(file: file)
            #expect(reopened.value == store.value)
            #expect(reopened.value.stored.values == ["new", "unknown", "include_archived", "", "unplayed"])
        }
    }
    @Test(arguments: 0..<8)
    func sourceSubscriptionQueryUsesExplicitSubsetOrSubscribedDefault(mask: Int) {
        let names = ["include_subscribed", "include_archived", "include_not_subscribed"]
        let states: [FeedSubscriptionState] = [.subscribed, .archived, .notSubscribed]
        let filter = AllEpisodesFilter(.init(values: names.indices.filter { mask & (1 << $0) != 0 }.map { names[$0] }))
        for index in states.indices {
            #expect(filter.includes(episode(), subscription: states[index], queued: false) == (mask == 0 ? index == 0 : mask & (1 << index) != 0))
        }
    }
    @Test(arguments: FeedSubscriptionState.allCases)
    func favoritesOverrideSubscriptionOnlyAndNeverRewriteStoredFilter(subscription: FeedSubscriptionState) {
        let filter = AllEpisodesFilter(.init(values: ["is_favorite", "include_archived", "new"]))
        #expect(filter.includes(episode(favorite: true), subscription: subscription, queued: false))
        #expect(!filter.includes(episode(favorite: false), subscription: subscription, queued: false))
        #expect(!filter.includes(episode(play: .played, favorite: true), subscription: subscription, queued: false))
        #expect(filter.stored.values == ["is_favorite", "include_archived", "new"])
        #expect(Set(filter.effective.values).isSuperset(of: ["include_subscribed", "include_archived", "include_not_subscribed"]))
    }
    @Test func sourceSQLPrecedenceNullableMediaQueueAndCountUseOnePredicate() {
        let rows = [episode(1), episode(2, play: .unplayed), episode(3, play: .played), episode(4, media: false)]
        let cases: [([String], [Int64])] = [([], [1,2,3,4]), (["new"], [1,4]),
            (["played", "unplayed", "new"], [3]), (["unplayed", "new"], [1,2,4]),
            (["queued"], [2,4]), (["not_queued"], [1,3]), (["not_downloaded"], [1,2,3]),
            (["downloaded"], []), (["no_media"], [4]), (["not_paused"], [1,2,3,4])]
        for (tokens, expected) in cases {
            let filter = AllEpisodesFilter(.init(values: tokens))
            let selected = rows.filter { filter.includes($0, subscription: .subscribed, queued: [2,4].contains($0.id)) }
            #expect(selected.map(\.id) == expected)
        }
    }
    @Test func legacyNewChangesMembershipAndSourceSwipeFeedbackWithoutOfferedNewOption() {
        let item = EpisodeListItem(episode: episode(), local: false, queued: false, downloading: false)
        let filtered = AllEpisodesFilter(.init(values: ["new"]))
        #expect(filtered.includes(item.episode, subscription: .subscribed, queued: false))
        #expect(!filtered.includes(episode(play: .unplayed), subscription: .subscribed, queued: false))
        #expect(SwipeAction.removeInbox.removesRow(item: item, filter: filtered.effective))
        #expect(!SwipeAction.removeInbox.removesRow(item: item, filter: .init()))
        #expect(!FeedFilterGroup.allCases.flatMap(\.values).contains("new"))
    }
    @Test func editorWritesImmediatelyAndClosingWithoutATapDoesNotChangeHiddenOnlyTokens() throws {
        try withStore { store, file in
            try store.update(.init(values: ["new", "unknown"]))
            do { let editor = AllEpisodesFilterEditor(store: store); editor.restoreVisibleOptions() }
            #expect(try AllEpisodesFilterPreferenceStore(file: file).value.stored.values == ["new", "unknown"])
            do {
                let editor = AllEpisodesFilterEditor(store: store)
                editor.toggle(group: .played, index: 1)
                #expect(try AllEpisodesFilterPreferenceStore(file: file).value.stored.values == ["unplayed"])
                editor.toggle(group: .queued, index: 0)
            }
            #expect(try AllEpisodesFilterPreferenceStore(file: file).value.stored.values == ["unplayed", "queued"])
            let editor = AllEpisodesFilterEditor(store: store); editor.reset()
            #expect(try AllEpisodesFilterPreferenceStore(file: file).value.stored.values.isEmpty)
        }
    }
    @Test func visibleRestorationNormalizesLastSelectionOnlyOnceAndFavoriteExpansionIsNotStored() throws {
        try withStore { store, file in
            try store.update(.init(values: ["played", "unplayed", "new", "is_favorite", "unknown"]))
            let editor = AllEpisodesFilterEditor(store: store)
            var saves = 0; editor.onEvent = { if case .saved = $0 { saves += 1 } }
            editor.restoreVisibleOptions(); editor.restoreVisibleOptions()
            #expect(saves == 1)
            #expect(try AllEpisodesFilterPreferenceStore(file: file).value.stored.values == ["unplayed", "is_favorite"])
            #expect(store.value.effective.values.contains("include_not_subscribed"))
        }
    }
    @Test func failedAtomicWriteKeepsMemoryDurableBytesAndVisibleSelection() throws {
        try withStore { store, file in
            try store.update(.init(values: ["played"]))
            let before = try Data(contentsOf: file), parent = file.deletingLastPathComponent()
            let moved = parent.appendingPathExtension("saved")
            try FileManager.default.moveItem(at: parent, to: moved)
            defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.moveItem(at: moved, to: parent) }
            try Data("blocked parent".utf8).write(to: parent)
            let editor = AllEpisodesFilterEditor(store: store); var failures = 0, saves = 0
            editor.onEvent = { switch $0 { case .failed: failures += 1; case .saved: saves += 1; case .changed: break } }
            editor.toggle(group: .queued, index: 0)
            #expect(failures == 1 && saves == 0)
            #expect(editor.selection.filter.values == ["played"] && store.value.stored.values == ["played"])
            #expect(try Data(contentsOf: moved.appendingPathComponent(file.lastPathComponent)) == before)
        }
    }
    @Test func corruptPreferenceIsReportedAndNeverOverwritten() throws {
        try withStore { _, file in
            let invalid = Data("{broken".utf8); try invalid.write(to: file)
            #expect(throws: (any Error).self) { try AllEpisodesFilterPreferenceStore(file: file) }
            #expect(try Data(contentsOf: file) == invalid)
        }
    }
}

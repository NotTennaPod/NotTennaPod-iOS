import Foundation
import Testing
@testable import NotTennaPodCore

/// Tag chips, Tags dialog, tag rename/delete and bulk edits against the independent oracle (written from the
/// pinned source and cross-checked by running the unchanged `FeedPreferences.java`). The library is the
/// oracle's Android-schema fixture `tags-library.db`, imported through the database restore. Bulk edits are
/// checked in the Android database the app exports afterwards, column by column.
@MainActor @Suite(.serialized) struct SubscriptionTagsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let fixtures = root.appendingPathComponent("TestSupport/Data/subscription-tags-bulk")

    private func oracle() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("expected/subscription-tags.json"))) as! [String: Any]
    }
    private func ids(_ value: Any?) -> [Int64] { (value as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value } }
    private func strings(_ value: Any?) -> [String] { value as? [String] ?? [] }

    /// A fresh store holding the fixture library, plus the imported per-feed speeds.
    private func withLibrary(_ body: (FeedLibraryStore, AndroidDatabaseRestore.Library, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SubscriptionTags-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent("tags-library.db"),
                                                      staging: directory.appendingPathComponent("staging"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
            try await body(store, restored, directory)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
    /// Tags as the app and Android read them back (stored "" → `#root`), in Java set order.
    private func reloaded(_ feed: LibraryFeed?) -> [String] { FeedTagOrder.preferences(feed?.tags ?? []).values }

    // MARK: Chips

    @Test func chipsFollowTheOracleOnBothScreens() async throws {
        let views = try oracle()["views"] as! [String: Any]
        try await withLibrary { store, _, _ in
            let feeds = try await store.snapshot().feeds
            for (name, state) in [("subscribed", FeedSubscriptionState.subscribed), ("archive", .archived)] {
                let expected = (views[name] as! [String: Any])["chips"] as! [[String: Any]]
                let chips = SubscriptionTagChips.chips(feeds, state: state)
                #expect(chips.map(\.tag) == expected.map { $0["tag"] as! String }, "\(name) chip order")
                #expect(chips.map(\.feedIDs) == expected.map { ids($0["unfiltered_feed_ids"]) }, "\(name) chip members")
                #expect(chips.map(\.isTag) == expected.map { $0["long_press_menu"] as! Bool }, "\(name) long-press menus")
                #expect(SubscriptionTagChips.rowVisible(chips) == (views[name] as! [String: Any])["chips_row_visible"] as! Bool)
            }
        }
    }

    /// 20-unit rule; a cut that would split an emoji moves before it (Android leaves half a pair).
    @Test func chipLabelsKeepTwentyUnitsWithoutSplittingAnEmoji() throws {
        let notes = (try oracle()["views"] as! [String: Any])["chip_label_notes"] as! [[String: Any]]
        for note in notes {
            let tag = note["tag"] as! String
            if note["splits_surrogate_pair"] as! Bool {
                #expect(SubscriptionTagChips.label(tag) == "123456789012345678…")
            } else {
                #expect(SubscriptionTagChips.label(tag) == note["label"] as! String, "\(tag)")
            }
        }
        #expect(SubscriptionTagChips.label("News") == "News")
        #expect(SubscriptionTagChips.rowVisible([.init(tag: FeedTags.root, feedIDs: [1]), .init(tag: FeedTags.untagged, feedIDs: [1])]) == false)
    }

    /// Each chip lists that tag's members in the Subscriptions order and filter; a chip with no visible
    /// feed falls back to All ("news" under the Kept updated filter).
    @Test(arguments: [("subscribed", ""), ("subscribed_filter_kept_updated", "enabled_updates")])
    func selectingAChipShowsItsMembers(view: String, filter: String) async throws {
        let expected = try oracle()
        let byChip = ((expected["views"] as! [String: Any])[view] as! [String: Any])["by_chip"] as! [String: [String: Any]]
        let prefs = expected["preferences"] as! [String: Any]
        var preferences = SubscriptionDisplayPreferences()
        preferences.feedOrder = prefs["prefDrawerFeedOrder"] as! String
        preferences.feedCounter = prefs["prefDrawerFeedIndicator"] as! String
        preferences.subscriptionsFilter = filter
        try await withLibrary { store, _, _ in
            let result = SubscriptionListQueries.load(try await store.snapshot().feeds, preferences: preferences, state: .subscribed,
                                                      globalAutoDownload: prefs["prefEnableAutoDl"] as! Bool)
            for (tag, outcome) in byChip {
                let shown = SubscriptionTagChips.shown(selected: tag, in: result)
                #expect(shown.tag == outcome["selected_chip_after_load"] as! String, "\(view) \(tag)")
                #expect(shown.feeds.map(\.id) == ids(outcome["feed_ids"]), "\(view) \(tag)")
            }
        }
    }

    // MARK: Tags dialog

    @Test func tagsDialogShowsOnlyCommonTagsInTheFirstFeedsOrder() async throws {
        let cases = (try oracle()["dialogs"] as! [String: Any])["cases"] as! [[String: Any]]
        try await withLibrary { store, _, _ in
            let feeds = Dictionary(uniqueKeysWithValues: try await store.snapshot().feeds.map { ($0.id, $0) })
            for item in cases {
                let selection = ids(item["selection_in_list_order"])
                let draft = FeedTags(selection: selection.map { feeds[$0]!.tags })
                #expect(draft.displayed == strings(item["displayed_tags"]), "\(selection)")
                #expect(draft.includeRoot == item["root_checked"] as! Bool, "\(selection)")
                #expect(draft.isMultiple == item["info_visible"] as! Bool, "\(selection)")
            }
        }
    }

    // MARK: Tag edits — stored effect per feed

    /// Oracle cases by name, with the iOS fixes applied where Android has a defect.
    private func run(_ name: String, on store: FeedLibraryStore, case item: [String: Any]) async throws {
        let subscribed = { try await SubscriptionTagsTests.members($0, store: store, state: .subscribed) }
        switch name {
        case _ where name.hasPrefix("dialog_"):
            let selection = ids(item["selection"])
            var tagsOf: [[String]] = []
            for id in selection { tagsOf.append(try await store.feed(id: id)?.tags ?? []) }
            var draft = FeedTags(selection: tagsOf)
            let rejected = strings(item["rejected_inputs"])
            for edit in item["edits"] as! [[String]] {
                switch edit[0] {
                case "remove": draft.remove(at: try #require(draft.displayed.firstIndex(of: edit[1])))
                case "add", "pending":
                    let accepted = draft.add(edit[1])
                    #expect(accepted == !rejected.contains(edit[1]), "\(name) add \(edit[1])")
                default: Issue.record("unknown edit \(edit)")
                }
            }
            if let root = item["root_checkbox_set_to"] as? Bool { draft.includeRoot = root }
            try await store.saveTags(draft, feedIDs: selection)
        case "chip_rename_news": try await store.renameTag("News", to: "Headlines", feedIDs: try await subscribed("News"))
        case "chip_rename_collision_merge": try await store.renameTag("News", to: "Tech", feedIDs: try await subscribed("News"))
        case "chip_rename_case_only": try await store.renameTag("news", to: "News", feedIDs: try await subscribed("news"))
        case "chip_delete_news": try await store.deleteTag("News", feedIDs: try await subscribed("News"))
        case "chip_delete_last_tag": try await store.deleteTag("Solo", feedIDs: try await subscribed("Solo"))
        case "archive_chip_delete_old":
            try await store.deleteTag("Old", feedIDs: try await Self.members("Old", store: store, state: .archived))
        case "drawer_delete_tech_unfiltered", "drawer_delete_tech_filtered":
            try await store.deleteTag("Tech", feedIDs: try await subscribed("Tech"))
        case "drawer_rename_tech_filtered":
            try await store.renameTag("Tech", to: "Technology", feedIDs: try await subscribed("Tech"))
        case "chip_rename_to_empty_single_tag": try await store.renameTag("Solo", to: "", feedIDs: try await subscribed("Solo"))
        case "chip_rename_to_empty_with_other_tags": try await store.renameTag("Tech", to: "", feedIDs: try await subscribed("Tech"))
        default: Issue.record("unmapped case \(name)")
        }
    }
    static func members(_ tag: String, store: FeedLibraryStore, state: FeedSubscriptionState) async throws -> [Int64] {
        FeedTagEdit.members(of: tag, in: try await store.snapshot().feeds, state: state)
    }

    @Test func tagEditsChangeExactlyTheExpectedFeeds() async throws {
        let cases = try oracle()["tag_edits"] as! [[String: Any]]
        #expect(cases.count == 18)
        for item in cases {
            let name = item["name"] as! String
            try await withLibrary { store, _, _ in
                let before = Dictionary(uniqueKeysWithValues: try await store.snapshot().feeds.map { ($0.id, $0) })
                try await run(name, on: store, case: item)
                let after = Dictionary(uniqueKeysWithValues: try await store.snapshot().feeds.map { ($0.id, $0) })
                #expect(after.count == before.count, "\(name): feeds are never deleted")
                var expected: [Int64: [String]] = [:]
                for change in item["changes"] as! [[String: Any]] {
                    expected[(change["feed"] as! NSNumber).int64Value] = strings(change["after_reload"])
                }
                switch name {
                case "chip_rename_to_empty_single_tag", "chip_rename_to_empty_with_other_tags":
                    expected = [:] // Empty text is rejected; nothing is written.
                case "drawer_delete_tech_filtered":
                    expected[5] = ["news"] // The filter-hidden Epsilon loses the deleted tag too.
                case "drawer_rename_tech_filtered":
                    expected[5] = FeedTagOrder.preferences(["news", "Technology"]).values
                default: break
                }
                for (id, feed) in after {
                    let want = expected[id] ?? reloaded(before[id])
                    #expect(reloaded(feed) == want, "\(name) feed \(id)")
                    var other = feed, original = before[id]!
                    other.tags = []; original.tags = []
                    #expect(other == original, "\(name) feed \(id): only tags change")
                }
            }
        }
    }

    /// Blank, `#root` and `#untagged` are not accepted as a new tag name; case-only and merge are.
    @Test func renameRejectsOnlyBlankAndReservedNames() {
        for text in ["", " ", "\t  ", FeedTags.root, FeedTags.untagged] { #expect(!FeedTagEdit.acceptsRename(text), "\(text)") }
        for text in ["News", " padded ", "#Root", "Untagged", "🎧"] { #expect(FeedTagEdit.acceptsRename(text), "\(text)") }
        #expect(FeedTagEdit.renamed(["News", "Tech"], from: "News", to: "Tech") == ["Tech"])
        #expect(FeedTagEdit.deleted(["Solo"], "Solo").isEmpty, "the last tag leaves an empty set (main list)")
    }

    // MARK: Multi-select

    @Test func floatingActionsFollowTheSelection() async throws {
        let menus = try oracle()["menus"] as! [String: Any]
        let titles: [String: FeedBulkAction] = ["Edit tags": .editTags, "Share": .share, "Remove all from inbox": .removeInbox,
            "Unsubscribe / archive": .removeArchive, "Unsubscribe / restore": .removeRestore, "Keep updated": .keepUpdated,
            "Episode notifications": .notifications, "Include in auto downloads": .autoDownload, "Delete after playing": .autoDelete,
            "Playback speed": .playbackSpeed]
        try await withLibrary { store, _, _ in
            let feeds = Dictionary(uniqueKeysWithValues: try await store.snapshot().feeds.map { ($0.id, $0) })
            for item in menus["floating"] as! [[String: Any]] {
                guard let expected = item["items"] as? [String] else { continue }
                let selection = ids(item["selection"]).map { feeds[$0]! }
                #expect(FeedBulkAction.visible(selection, archiveScreen: item["archive_screen"] as! Bool) == expected.map { titles[$0]! },
                        "\(selection.map(\.id))")
            }
            for item in menus["feed_context"] as! [[String: Any]] {
                let feed = feeds[(item["feed"] as! NSNumber).int64Value]!
                let expected: [String: SearchFeedMenu.Action] = ["Remove all from inbox": .removeInbox, "Edit tags": .editTags,
                    "Unsubscribe / archive": .removeArchive, "Unsubscribe / restore": .removeRestore, "Share": .share]
                #expect(SearchFeedMenu.actions(for: feed) == (item["items"] as! [String]).map { expected[$0]! }, "\(feed.id)")
            }
        }
    }

    @Test func selectAllAboveAndBelow() throws {
        for item in try oracle()["selection"] as! [[String: Any]] {
            let displayed = (0..<Int64((item["visible"] as! NSNumber).intValue)).map { $0 }
            let selected = ids(item["selected"])
            for (key, change) in [("select_toggle", { (s: inout EpisodeListSelection) in s.toggleAll(displayed: displayed) }),
                                  ("select_all_above", { $0.above(displayed: displayed) }),
                                  ("select_all_below", { $0.below(displayed: displayed) })] {
                var selection = EpisodeListSelection()
                selection.start(selected[0]); selected.dropFirst().forEach { selection.toggle($0) }
                change(&selection)
                #expect(selection.selected(displayed: displayed) == ids(item[key]), "\(key) from \(selected)")
                #expect(selection.active, "Deselect all keeps selection mode open")
            }
        }
    }

    // MARK: Bulk actions — checked in the exported Android database

    private func export(_ store: FeedLibraryStore, speeds: PlaybackSpeedPreferences, to url: URL) async throws {
        let snapshot = try await store.snapshot()
        let feedOf = Dictionary(uniqueKeysWithValues: snapshot.feeds.flatMap { feed in feed.episodes.map { ($0.id, feed.id) } })
        try AndroidDatabaseBackup.write(.init(feeds: snapshot.feeds, queue: snapshot.queue.map { .init(episodeID: $0.id, feedID: feedOf[$0.id]!) },
                                              speeds: speeds), to: url)
    }
    private static let bulkColumns = ["state", "tags", "auto_download", "keep_updated", "auto_delete_action", "feed_playback_speed",
                                      "feed_skip_silence", "feed_volume_adaption", "episode_notification", "new_episodes_action"]
    private func feedRows(_ url: URL) throws -> [Int64: [String: String]] {
        let db = try BackupSQLite(url: url, create: false); defer { try? db.close() }
        var result: [Int64: [String: String]] = [:]
        for row in try db.named("SELECT id, \(Self.bulkColumns.joined(separator: ", ")) FROM Feeds") {
            var values: [String: String] = [:]
            for column in Self.bulkColumns {
                values[column] = column == "feed_playback_speed" ? String(row.double(column))
                    : column == "tags" ? Set((row.string(column) ?? "").components(separatedBy: "\u{1E}")).sorted().joined(separator: "|")
                    : String(row.long(column))
            }
            result[row.long("id")] = values
        }
        return result
    }
    private func readStates(_ url: URL) throws -> [Int64: Int64] {
        let db = try BackupSQLite(url: url, create: false); defer { try? db.close() }
        return Dictionary(uniqueKeysWithValues: try db.named("SELECT id, read FROM FeedItems").map { ($0.long("id"), $0.long("read")) })
    }

    /// Every oracle bulk case through the app's store/preference owners, then an Android export: exactly
    /// the expected cells change. On iOS the speed dialog also saves "Skip silence in audio"
    /// like the per-feed dialog (Global → global, otherwise unchecked → off), which Android never writes.
    @Test func bulkActionsChangeExactlyTheSelectedFeedsColumn() async throws {
        let cases = try oracle()["bulk"] as! [[String: Any]]
        #expect(cases.count == 17)
        for item in cases {
            let name = item["name"] as! String, selection = ids(item["selection"])
            try await withLibrary { store, restored, directory in
                let speeds = try PlaybackSpeedPreferenceStore(file: directory.appendingPathComponent("speed.json"))
                try speeds.restore(feeds: restored.feedSpeeds, silence: restored.feedSilence)
                let before = directory.appendingPathComponent("before.db"), after = directory.appendingPathComponent("after.db")
                try await export(store, speeds: speeds.value, to: before)
                let choice = item["choice"] as? [String: Any]
                var expectedSilence: PlaybackSilencePreference?
                switch item["action"] as! String {
                case "keep_updated": try await store.applyBulk(.keepUpdated(choice!["switch_on"] as! Bool), feedIDs: selection)
                case "notify_new_episodes": try await store.applyBulk(.notifications(choice!["switch_on"] as! Bool), feedIDs: selection)
                case "autodownload":
                    try await store.applyBulk(.autoDownload(FeedBulkPreference.autoDownloadChoices[choice!["index"] as! Int]), feedIDs: selection)
                case "autoDeleteDownload":
                    try await store.applyBulk(.autoDelete(FeedBulkPreference.autoDeleteChoices[choice!["index"] as! Int]), feedIDs: selection)
                case "playback_speed":
                    var draft = FeedPlaybackSpeedDraft(speed: 1, skipSilence: .off)
                    if choice!["global"] as! Bool { draft.usesGlobal = true } else { draft.move(to: choice!["progress"] as! Int) }
                    try speeds.setFeeds(selection, speed: draft.savedSpeed, skipSilence: draft.savedSilence)
                    expectedSilence = draft.savedSilence
                case "remove_all_inbox_item": try await store.removeFeedsFromInbox(feedIDs: selection)
                case "remove_archive_feed", "remove_restore_feed":
                    let state: FeedSubscriptionState = item["action"] as! String == "remove_archive_feed" ? .archived : .subscribed
                    for id in selection { try await store.updatePreferences(feedID: id) { $0.subscriptionState = state } }
                default: Issue.record("unmapped \(name)")
                }
                try await export(store, speeds: speeds.value, to: after)
                let old = try feedRows(before), new = try feedRows(after)
                #expect(Set(old.keys) == Set(new.keys))
                var expected = old
                for change in item["feeds_changes"] as! [[String: Any]] {
                    let id = (change["feed"] as! NSNumber).int64Value, column = change["column"] as! String
                    expected[id]![column] = column == "feed_playback_speed" ? String((change["after"] as! NSNumber).doubleValue)
                        : String((change["after"] as! NSNumber).int64Value)
                }
                if let expectedSilence { for id in selection { expected[id]!["feed_skip_silence"] = String(expectedSilence.rawValue) } }
                #expect(new == expected, "\(name)")
                var reads = try readStates(before)
                for change in item["feed_items_changes"] as? [[String: Any]] ?? [] {
                    reads[(change["episode"] as! NSNumber).int64Value] = (change["after"] as! NSNumber).int64Value
                }
                #expect(try readStates(after) == reads, "\(name) episodes")
                if let keep = ProcessInfo.processInfo.environment["SUBSCRIPTION_TAGS_EXPORT_DIR"] {
                    let target = URL(fileURLWithPath: keep).appendingPathComponent(name, isDirectory: true)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: before, to: target.appendingPathComponent("BEFORE.db"))
                    try FileManager.default.copyItem(at: after, to: target.appendingPathComponent("AFTER.db"))
                }
            }
        }
    }

    /// A bulk edit is one transaction: a missing feed leaves every selected feed unchanged.
    @Test func bulkEditIsAllOrNothing() async throws {
        try await withLibrary { store, _, _ in
            let before = try await store.snapshot().feeds
            await #expect(throws: (any Error).self) { try await store.applyBulk(.keepUpdated(false), feedIDs: [1, 999, 3]) }
            #expect(try await store.snapshot().feeds == before)
        }
    }
}

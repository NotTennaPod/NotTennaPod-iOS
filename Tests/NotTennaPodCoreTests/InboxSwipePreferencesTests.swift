import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct InboxSwipePreferencesTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InboxSwipe-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func item(_ state: EpisodePlayState = .new, media: Bool = true, local: Bool = false,
                      downloaded: Bool = false, favorite: Bool = false, queued: Bool = false,
                      downloading: Bool = false) -> EpisodeListItem {
        var episode = LibraryEpisode(id: 17, details: .init(title: "Fixture", media: media ? .init(url: "https://example.test/media", size: 100) : nil))
        episode.userState.playState = state; episode.userState.positionMilliseconds = 12_000
        episode.userState.isDownloaded = downloaded; episode.userState.isFavorite = favorite
        return .init(episode: episode, local: local, queued: queued, downloading: downloading)
    }

    @Test(arguments: SwipeScreen.allCases)
    func absentConfigurationAndCancelledDraftRemainAbsent(screen: SwipeScreen) throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("swipe.json"), store = try SwipePreferenceStore(file: root.appendingPathComponent("swipe.json"))
        #expect(store.value.configuration(for: screen) == nil)
        #expect(store.gesture(on: screen, direction: .left) == .configure)
        #expect(store.gesture(on: screen, direction: .right) == .configure)
        var abandoned = store.draft(for: screen)
        #expect(abandoned.configuration == screen.defaultConfiguration)
        abandoned.configuration.enabled = false; abandoned.configuration.left = .removeInbox
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try SwipePreferenceStore(file: file).value.configuration(for: screen) == nil)
        try store.confirm(store.draft(for: screen))
        let reopened = try SwipePreferenceStore(file: file)
        #expect(reopened.value.configuration(for: screen) == screen.defaultConfiguration)
        #expect(reopened.gesture(on: screen, direction: .left) == .action(screen.defaultConfiguration.left))
        #expect(reopened.gesture(on: screen, direction: .right) == .action(screen.defaultConfiguration.right))
    }

    @Test func screenCommitsPreserveOtherScreensAndPhysicalSidesAcrossReopen() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("swipe.json"), store = try SwipePreferenceStore(file: root.appendingPathComponent("swipe.json"))
        let oldFeedDraft = store.draft(for: .feed)
        var inbox = store.draft(for: .inbox); inbox.configuration.left = .favorite; inbox.configuration.right = .removeInbox
        try store.confirm(inbox)
        try store.confirm(oldFeedDraft) // A different screen's older draft cannot reset Inbox.
        var favorites = store.draft(for: .favorites); favorites.configuration.enabled = false
        favorites.configuration.left = .removeInbox; favorites.configuration.right = .queue; try store.confirm(favorites)
        let saved = try Data(contentsOf: file)
        var cancelled = store.draft(for: .inbox); cancelled.configuration.right = .download
        #expect(try Data(contentsOf: file) == saved)
        let reopened = try SwipePreferenceStore(file: file)
        #expect(reopened.value.configuration(for: .inbox) == inbox.configuration)
        #expect(reopened.value.configuration(for: .feed) == oldFeedDraft.configuration)
        #expect(reopened.value.configuration(for: .episodes) == nil)
        #expect(reopened.gesture(on: .inbox, direction: .left) == .action(.favorite))
        #expect(reopened.gesture(on: .inbox, direction: .right) == .action(.removeInbox))
        for direction in [EpisodeSwipeDirection.left, .right] { #expect(reopened.gesture(on: .favorites, direction: direction) == .disabled) }
        // Physical direction has no locale input; the persisted names stay left/right.
        let json = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let screens = try #require(json["screens"] as? [String: [String: Any]])
        #expect(screens["NewEpisodesFragment"]?["left"] as? String == "MARK_FAV")
        #expect(screens["NewEpisodesFragment"]?["right"] as? String == "REMOVE_FROM_INBOX")
    }

    @Test func invalidDraftPreservesDiskAndMemory() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("swipe.json"), store = try SwipePreferenceStore(file: root.appendingPathComponent("swipe.json"))
        try store.confirm(store.draft(for: .inbox)); let bytes = try Data(contentsOf: file), value = store.value
        for direction in [EpisodeSwipeDirection.left, .right] {
            var invalid = store.draft(for: .inbox)
            if direction == .left { invalid.configuration.left = .delete } else { invalid.configuration.right = .played }
            #expect(throws: InboxSwipePreferenceError.self) { try store.confirm(invalid) }
            #expect(store.value == value)
            #expect(try Data(contentsOf: file) == bytes)
        }
        #expect(try SwipePreferenceStore(file: file).value == value)
    }

    @Test func failedAtomicWriteDoesNotPublishOrLoseExistingPreferences() throws {
        let root = try directory()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("swipe.json"), store = try SwipePreferenceStore(file: root.appendingPathComponent("swipe.json"))
        try store.confirm(store.draft(for: .inbox)); let bytes = try Data(contentsOf: file), value = store.value
        var updated = store.draft(for: .inbox); updated.configuration.enabled = false
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) { try store.confirm(updated) }
        #expect(store.value == value)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try SwipePreferenceStore(file: file).value == value)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try store.confirm(updated)
        #expect(try SwipePreferenceStore(file: file).value.configuration(for: .inbox) == updated.configuration)
    }

    @Test(arguments: [
        "not json", "{}", "{\"screens\":{\"UnknownFragment\":{\"left\":\"REMOVE_FROM_INBOX\",\"right\":\"ADD_TO_QUEUE\",\"enabled\":true}}}",
        "{\"screens\":{\"NewEpisodesFragment\":{\"left\":\"DELETE\",\"right\":\"ADD_TO_QUEUE\",\"enabled\":true}}}",
        "{\"screens\":{\"NewEpisodesFragment\":{\"left\":\"UNRECOGNIZED\",\"right\":\"ADD_TO_QUEUE\",\"enabled\":true}}}",
        "{\"screens\":{\"NewEpisodesFragment\":{\"left\":\"REMOVE_FROM_INBOX\",\"enabled\":true}}}",
        "{\"screens\":{\"NewEpisodesFragment\":{\"left\":\"REMOVE_FROM_INBOX\",\"right\":\"ADD_TO_QUEUE\",\"enabled\":1}}}"
    ])
    func malformedOrDisallowedStoredDataIsReportedWithoutRepair(raw: String) throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("swipe.json"), bytes = Data(raw.utf8); try bytes.write(to: file)
        #expect(throws: (any Error).self) { _ = try SwipePreferenceStore(file: file) }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func missingParentWriteAndDirectoryReadReportErrorsWithoutCreatingConfiguration() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("missing/swipe.json"), store = try SwipePreferenceStore(file: root.appendingPathComponent("missing/swipe.json"))
        #expect(throws: (any Error).self) { try store.confirm(store.draft(for: .inbox)) }
        #expect(store.value.configuration(for: .inbox) == nil && !FileManager.default.fileExists(atPath: file.path))
        #expect(throws: (any Error).self) { _ = try SwipePreferenceStore(file: root) }
    }

    @Test func queueToggleKeepsItsOwnFeedbackSeparateFromAddActionMotion() {
        let rows: [(EpisodeListItem, SwipeDecision.Recipient)] = [
            (item(), .list(.addQueue)), (item(media: false), .notice("no_media_label")),
            (item(queued: true), .list(.removeQueue)), (item(media: false, queued: true), .list(.removeQueue))
        ]
        for (current, recipient) in rows {
            for tokens in [[], ["new"], ["queued"], ["not_queued"]] {
                let result = SwipeAction.queue.decision(item: current, filter: .init(values: tokens))
                #expect(result.recipient == recipient)
                #expect(result.removesRow == (current.episode.details.media != nil && (tokens.contains("new") || tokens.contains("not_queued"))))
                #expect(result.undo == (current.queued && (tokens.contains("queued") || tokens.contains("not_queued")) ? .queuePosition : nil))
            }
        }
    }

    @Test func downloadAdmissionAndDeleteNeverCancelAnActiveRemoteTransfer() {
        let cases: [(EpisodeListItem, SwipeDecision.Recipient, SwipeDecision.Recipient)] = [
            (item(), .download, .none), (item(media: false), .notice("no_media_label"), .none),
            (item(local: true), .notice("already_downloaded"), .list(.delete)),
            (item(downloaded: true), .notice("already_downloaded"), .list(.delete)),
            (item(downloading: true), .none, .none),
            (item(downloaded: true, downloading: true), .notice("already_downloaded"), .list(.delete)),
            (item(media: false, local: true), .notice("no_media_label"), .list(.delete))
        ]
        for (current, download, delete) in cases {
            for filter in [FeedEpisodeFilter(), .init(values: ["downloaded"])] {
                let d = SwipeAction.download.decision(item: current, filter: filter)
                #expect(d.recipient == download && !d.removesRow && d.undo == nil)
                let deletion = SwipeAction.delete.decision(item: current, filter: filter)
                #expect(deletion.recipient == delete && deletion.undo == nil)
                #expect(deletion.removesRow == (filter.values.contains("downloaded") && (current.local || current.episode.userState.isDownloaded)))
            }
        }
    }
}

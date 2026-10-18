import Foundation
import Testing
@testable import NotTennaPodCore

@Suite
struct SynchronizationQueueTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func fixture(_ body: (FeedLibraryStore, URL, LibraryFeed) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncQueue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: file)
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Sync podcast", episodes: (1...3).map {
            .init(identifier: "guid-\($0)", title: "Episode \($0)", publicationDate: now.addingTimeInterval(Double($0)),
                media: .init(url: "https://example.test/\($0).mp3", size: 100, durationMilliseconds: 100_000))
        }), source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        do { try await body(store, file, feed); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func action(_ episode: LibraryEpisode, position: Int32 = 50, date: Date? = nil,
                        kind: SynchronizationEpisodeAction.Kind = .play) -> SynchronizationEpisodeAction {
        .init(podcast: "https://example.test/feed", episode: episode.details.media!.url!, guid: episode.details.identifier,
            action: kind, timestamp: date ?? now, started: 0, position: position, total: 100)
    }

    @Test func originalFilterCasesAndConfirmedMalformedStateDefects() throws {
        struct Fixture: Decodable {
            struct Row: Decodable { let localKind, localTime, remoteKind, remoteTime: Int; let selected: Bool }
            struct Position: Decodable { let seconds, stored: Int32 }
            let cases: [Row]; let nullAfterDated: String; let positions: [Position]
        }
        let url = try #require(Bundle.module.url(forResource: "synchronization-policy", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let kinds: [SynchronizationEpisodeAction.Kind] = [.new, .download, .play, .delete]
        func make(_ kind: Int, _ time: Int) -> SynchronizationEpisodeAction {
            .init(podcast: "p", episode: "e", action: kinds[kind], timestamp: time < 0 ? nil : Date(timeIntervalSince1970: Double(time)), started: 0, position: 1, total: 10)
        }
        #expect(fixture.cases.count == 400)
        for row in fixture.cases {
            #expect(!SynchronizationActionPolicy.remoteOverridingLocal([make(row.remoteKind, row.remoteTime)], local: [make(row.localKind, row.localTime)]).isEmpty == row.selected)
        }
        #expect(fixture.nullAfterDated == "NullPointerException")
        #expect(SynchronizationActionPolicy.remoteOverridingLocal([make(2, 0)], local: [make(2, 1), make(0, -1)]).isEmpty)
        #expect(SynchronizationActionPolicy.remoteOverridingLocal([make(2, 2)], local: [make(2, 1), make(0, -1)]) == [make(2, 2)])
        #expect(fixture.positions.first { $0.seconds == -1 }?.stored == -1_000)
        #expect(fixture.positions.first { $0.seconds == 2_147_484 }?.stored == -2_147_483_296)
    }

    @Test func connectionGatesNewEffectsAndDefaultsResolveFromPersistedAccount() async throws {
        try await fixture { store, file, feed in
            let episode = feed.episodes[0]
            try await store.markEpisodePlayed(episodeID: episode.id, played: true, now: now)
            #expect(try await store.synchronizationQueue().isEmpty)
            let account = UUID()
            try await store.selectSynchronizationAccount(account)
            // Historical feed/played effects must not be replayed on connection.
            #expect(try await store.synchronizationQueue().isEmpty)
            try await store.markEpisodePlayed(episodeID: episode.id, played: false, now: now)
            let queued = try await store.synchronizationQueue()
            #expect(queued.count == 1)
            guard case .episode(let action) = queued[0].value else { Issue.record("Expected NEW"); return }
            #expect(action.action == .new && action.position == -1 && action.timestamp == now)
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await reopened.synchronizationQueue() == queued)
            #expect(try await reopened.synchronizationState().accountID == account)
            try await reopened.close()
            try await store.selectSynchronizationAccount(nil)
            #expect(try await store.synchronizationQueue().isEmpty)
            try await store.markEpisodePlayed(episodeID: episode.id, played: true, now: now)
            #expect(try await store.synchronizationQueue().isEmpty)
        }
    }

    @Test func outboxFailureRollsBackActualEpisodeMutationAndItsPendingEffect() async throws {
        try await fixture { store, file, feed in
            try await store.selectSynchronizationAccount(UUID())
            let episode = feed.episodes[0], before = try await store.pendingEffects()
            let db = try LibrarySQLite(url: file)
            try db.execute("CREATE TRIGGER reject_sync BEFORE INSERT ON synchronization_outbox BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: FeedLibraryError.self) { try await store.markEpisodePlayed(episodeID: episode.id, played: true, now: now) }
            #expect(try await store.episode(id: episode.id) == episode)
            #expect(try await store.pendingEffects() == before)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try await store.synchronizationState().request == nil)
            try db.close()
        }
    }

    @Test func acknowledgedSnapshotPreservesNewerChangesAndAccountEpochRejectsStaleReply() async throws {
        try await fixture { store, _, feed in
            try await store.selectSynchronizationAccount(UUID())
            let epoch = try await store.synchronizationState().epoch
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true, now: now)
            let before = try await store.synchronizationQueue()
            try await store.markEpisodePlayed(episodeID: feed.episodes[1].id, played: true, now: now)
            try await store.acknowledgeSynchronization(epoch: epoch, phase: .episodes, ids: before.map(\.id), timestamp: 123)
            #expect(try await store.synchronizationQueue().count == 1)
            #expect(try await store.synchronizationState().episodeTimestamp == 123)
            try await store.selectSynchronizationAccount(UUID())
            await #expect(throws: CancellationError.self) {
                try await store.acknowledgeSynchronization(epoch: epoch, phase: .episodes, ids: [], timestamp: 999)
            }
            #expect(try await store.synchronizationState().episodeTimestamp == 0)
        }
    }

    @Test func requestReplacementDebounceRecentGateRetryAndFullSyncPreservePendingActions() async throws {
        try await fixture { store, _, feed in
            try await store.selectSynchronizationAccount(UUID())
            try await store.setSynchronizationMobileAllowed(true)
            let first = try #require(try await store.requestSynchronization(now: now))
            #expect(first.notBefore == now.addingTimeInterval(20) && first.network == .connected)
            let state = try await store.beginSynchronization(first, now: now)
            let delayed = try #require(try await store.requestSynchronization(now: now))
            #expect(delayed.notBefore == now.addingTimeInterval(120))
            try await store.finishSynchronization(first, epoch: state.epoch, successful: true)
            #expect(try await store.synchronizationState().request == delayed)
            #expect(try await store.requestSynchronization(ifNotRecent: true, now: now.addingTimeInterval(600)) == nil)
            #expect(try await store.requestSynchronization(ifNotRecent: true, now: now.addingTimeInterval(601)) != nil)
            let immediate = try #require(try await store.requestSynchronization(immediately: true, now: now))
            #expect(immediate.notBefore == now)
            _ = try await store.beginSynchronization(immediate, now: now)
            try await store.finishSynchronization(immediate, epoch: state.epoch, successful: false, retry: true, now: now)
            let retry = try #require(try await store.synchronizationState().request)
            #expect(retry.attempts == 1 && retry.notBefore == now.addingTimeInterval(600))
            _ = try await store.beginSynchronization(retry, now: now)
            try await store.finishSynchronization(retry, epoch: state.epoch, successful: false, retry: true, now: now)
            #expect(try await store.synchronizationState().request?.notBefore == now.addingTimeInterval(1_200))
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true, now: now)
            let queued = try await store.synchronizationQueue()
            _ = try await store.requestSynchronization(full: true, now: now)
            let full = try await store.synchronizationState()
            #expect(full.epoch != state.epoch && full.lastAttempt == nil && full.request?.notBefore == now)
            #expect(try await store.synchronizationQueue() == queued)
        }
    }

    @Test func remoteProgressCompletesAtLocalDurationThresholdWithoutDeletingMediaOrStatistics() async throws {
        try await fixture { store, file, feed in
            let episodes = feed.episodes.sorted { $0.id < $1.id }
            _ = try await store.enqueue(episodes.map(\.id))
            if let token = try await store.automaticDownloadRequest() { try await store.finishAutomaticDownloadRequest(token) }
            let path = file.deletingLastPathComponent().appendingPathComponent("download.mp3")
            try Data([1,2,3]).write(to: path)
            for episode in episodes {
                try await store.updateEpisode(id: episode.id) {
                    $0.userState.playState = .new; $0.userState.isFavorite = true
                    $0.userState.playedDurationMilliseconds = 321
                    $0.userState.localFileURL = path.path; $0.userState.isDownloaded = true
                }
            }
            try await store.selectSynchronizationAccount(UUID())
            let epoch = try await store.synchronizationState().epoch
            let pending = try await store.pendingEffects()
            var expectedPartial = try #require(try await store.episode(id: episodes[0].id))
            var expectedCompleted = try #require(try await store.episode(id: episodes[1].id))
            expectedPartial.userState.positionMilliseconds = 69_000; expectedPartial.userState.playState = .unplayed
            expectedCompleted.userState.positionMilliseconds = 0; expectedCompleted.userState.playState = .played
            let changed = try await store.applySynchronizationEpisodes([action(episodes[0], position: 69), action(episodes[1], position: 70)], epoch: epoch)
            #expect(changed == Array(episodes.prefix(2)).map(\.id))
            let partial = try #require(try await store.episode(id: episodes[0].id))
            let completed = try #require(try await store.episode(id: episodes[1].id))
            #expect(partial == expectedPartial && completed == expectedCompleted)
            #expect(partial.userState.positionMilliseconds == 69_000 && partial.userState.playState == .unplayed)
            #expect(completed.userState.positionMilliseconds == 0 && completed.userState.playState == .played)
            #expect(completed.userState.isFavorite && completed.userState.isDownloaded && completed.userState.playedDurationMilliseconds == 321)
            #expect(try Data(contentsOf: path) == Data([1,2,3]))
            #expect(try await store.queue().map(\.id) == [episodes[0].id, episodes[2].id])
            #expect(try await store.queueAutoDownloadRequested() == false)
            #expect(try await store.pendingEffects() == pending)
            #expect(try await store.synchronizationQueue().isEmpty)
        }
    }

    @Test func localNewerActionWinsRemoteTiesWinAndValidGuidNeverFallsBackToURL() async throws {
        try await fixture { store, _, feed in
            let episode = feed.episodes[0]
            try await store.selectSynchronizationAccount(UUID())
            let epoch = try await store.synchronizationState().epoch
            try await store.markEpisodePlayed(episodeID: episode.id, played: false, now: now.addingTimeInterval(1))
            #expect(try await store.applySynchronizationEpisodes([action(episode)], epoch: epoch).isEmpty)
            #expect(try await store.applySynchronizationEpisodes([action(episode, date: now.addingTimeInterval(1))], epoch: epoch) == [episode.id])
            var unknown = action(episode, position: 90, date: now.addingTimeInterval(2)); unknown.guid = "unknown"
            #expect(try await store.applySynchronizationEpisodes([unknown], epoch: epoch).isEmpty)
            unknown.guid = "null"
            #expect(try await store.applySynchronizationEpisodes([unknown], epoch: epoch) == [episode.id])
            #expect(try await store.episode(id: episode.id)?.userState.playState == .played)
        }
    }

    /// Remote actions match the lowest-ID episode with the exact GUID (or, without a valid GUID, the exact media
    /// URL), across feeds, as the per-action library scan did; the lookup is built once per application.
    @Test func remoteActionsMatchTheLowestIDEpisodeAcrossFeeds() async throws {
        try await fixture { store, _, feed in
            let copy = try await store.insert(.init(feed: .init(format: .rss, title: "Copy", episodes: (1...3).map {
                .init(identifier: "guid-\($0)", title: "Copy \($0)", publicationDate: now.addingTimeInterval(Double($0)),
                    media: .init(url: "https://example.test/\($0).mp3", size: 100, durationMilliseconds: 100_000))
            }), source: "https://example.test/copy", responseURL: URL(string: "https://example.test/copy")!, validator: nil, permanentRedirectURL: nil))
            try await store.selectSynchronizationAccount(UUID())
            let epoch = try await store.synchronizationState().epoch
            let original = feed.episodes.sorted { $0.id < $1.id }, copies = copy.episodes.sorted { $0.id < $1.id }
            var byURL = action(original[1], position: 30); byURL.guid = nil
            var unmatched = action(original[2], position: 40); unmatched.episode = "https://example.test/none.mp3"; unmatched.guid = nil
            let changed = try await store.applySynchronizationEpisodes(
                [action(original[0], position: 20), byURL, unmatched] + (0..<500).map { index in
                    var missing = action(original[2], position: 10)
                    missing.guid = "gone-\(index)"; missing.episode = "https://example.test/gone-\(index).mp3"; return missing
                }, epoch: epoch)
            #expect(changed == [original[0].id, original[1].id])
            #expect(try await store.episode(id: original[0].id)?.userState.positionMilliseconds == 20_000)
            #expect(try await store.episode(id: original[1].id)?.userState.positionMilliseconds == 30_000)
            #expect(try await store.episode(id: original[2].id)?.userState.positionMilliseconds == 0)
            for episode in copies { #expect(try await store.episode(id: episode.id)?.userState.positionMilliseconds == 0) }
        }
    }

    @Test func malformedRemotePositionsAndNonPlayActionsCannotMutateLibrary() async throws {
        try await fixture { store, _, feed in
            try await store.selectSynchronizationAccount(UUID())
            let epoch = try await store.synchronizationState().epoch
            let before = try await store.snapshot()
            for seconds: Int32 in [-1, 2_147_484, Int32.max] {
                #expect(try await store.applySynchronizationEpisodes([action(feed.episodes[0], position: seconds)], epoch: epoch).isEmpty)
            }
            for kind: SynchronizationEpisodeAction.Kind in [.new, .download, .delete] {
                #expect(try await store.applySynchronizationEpisodes([action(feed.episodes[0], kind: kind)], epoch: epoch).isEmpty)
            }
            #expect(try await store.snapshot() == before)
        }
    }

    @Test func initialPlayedUploadUsesLocalDurationAndCursorAckStopsFullHistoryReplay() async throws {
        try await fixture { store, _, feed in
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true)
            try await store.selectSynchronizationAccount(UUID())
            let epoch = try await store.synchronizationState().epoch
            let first = try await store.synchronizationEpisodeUpload(epoch: epoch, now: now)
            #expect(first.ids.isEmpty && first.actions.count == 1)
            #expect(first.actions[0].started == 100 && first.actions[0].position == 100 && first.actions[0].total == 100)
            try await store.acknowledgeSynchronization(epoch: epoch, phase: .episodes, ids: first.ids, timestamp: 50)
            #expect(try await store.synchronizationEpisodeUpload(epoch: epoch).actions.isEmpty)
        }
    }

    @Test func schemaNineMigrationPreservesQueuedAutomaticRequestAndCreatesDisconnectedSync() async throws {
        try await fixture { store, file, feed in
            _ = try await store.enqueue([feed.episodes[0].id])
            let snapshot = try await store.snapshot(), automatic = try await store.automaticDownloadRequest()
            try await store.close()
            let old = try LibrarySQLite(url: file)
            try restoreRefreshSchemaEleven(old)
            try old.execute("DROP TABLE synchronization_state"); try old.execute("DROP TABLE synchronization_outbox")
            try old.execute("DROP TABLE feed_credentials"); try old.execute("DROP TABLE feed_credential_cleanup"); try old.execute("PRAGMA user_version = 9"); try old.close()
            let migrated = try FeedLibraryStore(url: file)
            #expect(try await migrated.snapshot() == snapshot)
            #expect(try await migrated.automaticDownloadRequest() == automatic)
            #expect(try await migrated.synchronizationState().accountID == nil)
            #expect(try await migrated.synchronizationQueue().isEmpty)
            try await migrated.close()
        }
    }
    @Test func subscriptionAddThenRemoveCancelsOppositeEntryAndKeepsSourceRemoval() async throws {
        try await fixture { store, _, _ in
            try await store.selectSynchronizationAccount(UUID())
            let source = "https://second.test/feed"
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Second"), source: source,
                responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil), options: .init(now: now))
            #expect(try await store.synchronizationQueue().map(\.value) == [.added(source)])
            #expect(try await store.requestFeedDeletion(feedID: feed.id, now: now))
            let effect = try #require(try await store.pendingEffects().first {
                if case .deleteFeed(let deletion) = $0.effect.kind { deletion.feedID == feed.id } else { false }
            })
            try await store.completeFeedDeletion(effectID: effect.id)
            #expect(try await store.synchronizationQueue().map(\.value) == [.removed(source)])
            #expect(try await store.feed(id: feed.id) == nil)
            try await store.completeFeedDeletion(effectID: effect.id)
            #expect(try await store.synchronizationQueue().count == 1)
        }
    }

    @Test func downloadPlaybackAndCompletedFileDeletionQueueRealEffectsExactlyOnce() async throws {
        try await fixture { store, file, feed in
            try await store.selectSynchronizationAccount(UUID())
            let episode = feed.episodes[0]
            let job = try #require(try await store.requestDownload(episodeID: episode.id, directory: file.deletingLastPathComponent(), now: now))
            let active = try #require(try await store.beginDownloadAttempt(id: job.id, now: now))
            let media = try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: media, to: job.destination)
            #expect(try await store.attachDownloadFile(id: job.id, attempt: active.attempts))
            #expect(try await store.completeDownload(id: job.id, attempt: active.attempts, now: now))
            let session = try await store.beginPlayback(episodeID: episode.id)
            _ = try await store.recordPlayback(sessionID: session.id,
                sample: .init(positionMilliseconds: 5_000, durationMilliseconds: 100_000, status: .paused), now: now, synchronize: true)
            try await store.requestMediaDeletion(episodeID: episode.id, now: now)
            let pending = try #require(try await store.pendingEffects().first {
                if case .deleteDownloadFile = $0.effect.kind { true } else { false }
            })
            #expect(try await store.synchronizationQueue().count == 2)
            try FileManager.default.removeItem(at: job.destination)
            #expect(try await store.completeDownloadFileDeletion(effectID: pending.id))
            #expect(try await store.completeDownloadFileDeletion(effectID: pending.id) == false)
            let actions = try await store.synchronizationQueue().compactMap { entry -> SynchronizationEpisodeAction? in
                if case .episode(let action) = entry.value { action } else { nil }
            }
            #expect(actions.map(\.action) == [.download, .play, .delete])
            #expect(actions[1].started == 0 && actions[1].position == 5 && actions[1].total == 100)
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
        }
    }

    @Test func remoteWriteAndAcknowledgementFailuresKeepCompletePriorState() async throws {
        try await fixture { store, file, feed in
            try await store.selectSynchronizationAccount(UUID())
            _ = try await store.enqueue(feed.episodes.map(\.id))
            let epoch = try await store.synchronizationState().epoch
            let before = try await store.snapshot(), beforeState = try await store.synchronizationState()
            let db = try LibrarySQLite(url: file)
            try db.execute("CREATE TRIGGER reject_remote BEFORE UPDATE ON episodes WHEN NEW.id = \(feed.episodes[1].id) BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: FeedLibraryError.self) {
                try await store.applySynchronizationEpisodes([action(feed.episodes[0], position: 90), action(feed.episodes[1], position: 90)], epoch: epoch)
            }
            #expect(try await store.snapshot() == before)
            #expect(try await store.synchronizationState() == beforeState)
            try db.execute("DROP TRIGGER reject_remote")
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true, now: now)
            let queue = try await store.synchronizationQueue(), state = try await store.synchronizationState()
            try db.execute("CREATE TRIGGER reject_ack BEFORE DELETE ON synchronization_outbox BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: FeedLibraryError.self) {
                try await store.acknowledgeSynchronization(epoch: epoch, phase: .episodes, ids: queue.map(\.id), timestamp: 999)
            }
            #expect(try await store.synchronizationQueue() == queue)
            #expect(try await store.synchronizationState() == state)
            try db.close()
        }
    }

    @Test func disconnectedRequestFinishesWithoutInventingAnAttemptOrSuccess() async throws {
        try await fixture { store, _, _ in
            let request = try #require(try await store.requestSynchronization(immediately: true, now: now))
            let state = try await store.beginSynchronization(request, now: now)
            #expect(state.accountID == nil && state.lastAttempt == nil)
            try await store.finishSynchronization(request, epoch: state.epoch, successful: nil)
            let completed = try await store.synchronizationState()
            #expect(completed.request == nil && completed.lastAttempt == nil && !completed.lastAttemptSuccessful)
        }
    }

}

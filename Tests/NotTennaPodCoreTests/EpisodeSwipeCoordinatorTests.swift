import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

@MainActor @Suite struct EpisodeSwipeCoordinatorTests {
    @MainActor private final class Clock {
        var instant = ContinuousClock.now
        var deadlines: [ContinuousClock.Instant] = []
        var sleepers: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, any Error>)] = [:]
        var value: EpisodeSwipeCoordinator.Clock {
            .init(now: { self.instant }, sleep: { try await self.sleep(until: $0) })
        }
        func sleep(until deadline: ContinuousClock.Instant) async throws {
            try Task.checkCancellation()
            deadlines.append(deadline)
            guard instant < deadline else { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    sleepers[id] = (deadline, continuation)
                }
            } onCancel: { Task { @MainActor in self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) } }
        }
        func advance(_ duration: Duration) {
            instant = instant.advanced(by: duration)
            for (id, pending) in sleepers where pending.0 <= instant {
                sleepers.removeValue(forKey: id)?.1.resume()
            }
        }
    }
    private actor Gate {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(); continuation = nil }
    }
    @MainActor private final class Preferences { var value = DownloadPreferences() }
    @MainActor private final class Harness {
        let root: URL, url: URL, store: FeedLibraryStore, downloads: DownloadCoordinator, feedID: Int64
        let clock = Clock(), preferences = Preferences()
        let ids: [Int64]
        var owners: [EpisodeSwipeCoordinator] = []
        var events: [EpisodeSwipeCoordinator.Event] = []
        var deletions: [EpisodeMediaDeletionTarget] = []
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("SwipeRecipient-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            url = root.appendingPathComponent("library.sqlite"); store = try FeedLibraryStore(url: url)
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Swipe", episodes: (1...2).map {
                .init(identifier: "\($0)", title: "Episode \($0)",
                    media: .init(url: "https://example.test/\($0).mp3", size: 42, durationMilliseconds: 120_000))
            }), source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                validator: nil, permanentRedirectURL: nil))
            feedID = feed.id; ids = feed.episodes.map(\.id).sorted()
            for id in ids {
                let file = root.appendingPathComponent("\(id).media")
                try Data([1, 2, 3]).write(to: file)
                try await store.updateEpisode(id: id) {
                    $0.userState.playState = .new; $0.userState.positionMilliseconds = 90_000
                    $0.userState.localFileURL = file.path; $0.userState.isDownloaded = true
                }
            }
            preferences.value.autoDelete = true
            let preferences = preferences
            downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("downloads"),
                network: DownloadNetworkMonitor(startMonitoring: false), preferences: { preferences.value })
        }
        func model(_ index: Int = 0) async throws -> EpisodeActionModel {
            .init(item: .init(episode: try #require(try await store.episode(id: ids[index])), local: false))
        }
        func target(_ model: EpisodeActionModel) -> EpisodeMediaDeletionTarget? {
            let episode = model.snapshot().episode
            guard let media = episode.details.media else { return nil }
            return .init(episodeID: episode.id, feedID: feedID, source: "https://example.test/feed",
                media: .remote(mediaURL: media.url, originalFile: episode.userState.localFileURL))
        }
        func coordinator(persistence: EpisodeSwipeCoordinator.Persistence? = nil,
            delete: (@MainActor (EpisodeMediaDeletionTarget) async throws -> EpisodeMediaDeletionOutcome)? = nil) -> EpisodeSwipeCoordinator {
            let owner = EpisodeSwipeCoordinator(persistence: persistence ?? .init(store: store), downloads: downloads,
                clock: clock.value, delete: delete ?? { [weak self] target in self?.deletions.append(target); return .deleted })
            owner.onEvent = { [weak self] in self?.events.append($0) }
            owners.append(owner); return owner
        }
        func results(_ id: UUID) -> [EpisodeSwipeCoordinator.CleanupResult] {
            events.compactMap { if case .cleanupFinished(id, let result) = $0 { result } else { nil } }
        }
        func sql(_ query: String) throws -> [[String]] {
            var db: OpaquePointer?
            guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw FeedLibraryError.corruptRecord }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw FeedLibraryError.corruptRecord }
            defer { sqlite3_finalize(statement) }
            var rows: [[String]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return rows }
                guard status == SQLITE_ROW else { throw FeedLibraryError.sqlite(code: status, message: String(cString: sqlite3_errmsg(db))) }
                rows.append((0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_text(statement, $0)) })
            }
        }
        func diskState(_ id: Int64) throws -> EpisodePlayState {
            let text = try #require(sql("SELECT record FROM episodes WHERE id = \(id)").first?.first)
            return try JSONDecoder().decode(LibraryEpisode.self, from: Data(text.utf8)).userState.playState
        }
        func close() async throws {
            for owner in owners { owner.invalidateLibrary() }; owners.removeAll()
            clock.advance(.seconds(10))
            await downloads.stop(); try await store.close()
            try FileManager.default.removeItem(at: root)
        }
    }
    private func fixture(_ body: (Harness) async throws -> Void) async throws {
        let h = try await Harness()
        do { try await body(h); try await h.close() }
        catch { try? await h.close(); throw error }
    }
    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while await !predicate(), ContinuousClock.now < limit { await Task.yield() }
        try #require(await predicate())
    }
    private func commit(_ result: EpisodeSwipeCoordinator.PerformResult) throws -> EpisodeSwipeCoordinator.Commit {
        guard case .committed(let commit) = result else { Issue.record("Expected committed action, got \(result)"); throw FeedLibraryError.invalidMutation }
        return commit
    }

    private final class SilentEngine: PlaybackEngine {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {}
        func play(commandID: UUID) {}
        func pause(commandID: UUID) {}
        func seek(to positionMilliseconds: Int64, commandID: UUID) {}
        func setSpeed(_ speed: Float, commandID: UUID) throws {}
        func unload() {}
    }
    @Test(arguments: [false, true]) func integratedRemoteGuardDeletesOnlyCapturedArtifact(replaced: Bool) async throws {
        try await fixture { h in
            let model = try await h.model(), target = try #require(try await h.store.snapshot().deletionTargets[model.episodeID])
            let playback = PlaybackCoordinator(store: h.store, engine: SilentEngine())
            let owner = h.coordinator { target in try await h.downloads.deleteDownloadedMedia(target: target, playback: playback) }
            let operation = try commit(await owner.perform(model: model, action: .removeInbox, target: target, offersUndo: true))
            let oldFile = try #require(model.snapshot().episode.userState.localFileURL)
            let replacement = h.root.appendingPathComponent("replacement.media")
            if replaced {
                try Data([9, 8, 7]).write(to: replacement)
                try await h.store.updateEpisode(id: model.episodeID) { $0.userState.localFileURL = replacement.path }
            }
            h.clock.advance(.seconds(2))
            try await wait { !h.results(operation.operationID).isEmpty }
            #expect(h.results(operation.operationID) == [replaced ? .stale : .deleted])
            #expect(FileManager.default.fileExists(atPath: oldFile) == replaced)
            if replaced {
                #expect(try Data(contentsOf: replacement) == Data([9, 8, 7]))
                #expect(try await h.store.episode(id: model.episodeID)?.userState.localFileURL == replacement.path)
            } else {
                // Late Undo restores only state; already-deleted bytes stay deleted.
                #expect(await owner.undo(operationID: operation.operationID) == .restored)
                #expect(try h.diskState(model.episodeID) == .new)
                #expect(!FileManager.default.fileExists(atPath: oldFile))
                #expect(try await h.store.episode(id: model.episodeID)?.userState.isDownloaded == false)
            }
        }
    }
    @Test func integratedUndoBeforeDeadlinePreservesFileAndNoSync() async throws {
        try await fixture { h in
            let model = try await h.model(), playback = PlaybackCoordinator(store: h.store, engine: SilentEngine())
            let owner = h.coordinator { target in try await h.downloads.deleteDownloadedMedia(target: target, playback: playback) }
            let operation = try commit(await owner.perform(model: model, action: .removeInbox, target: h.target(model), offersUndo: true))
            let file = try #require(model.snapshot().episode.userState.localFileURL)
            #expect(await owner.beginUndo(operationID: operation.operationID).value == .restored)
            h.clock.advance(.seconds(3))
            #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data([1, 2, 3]))
            #expect(try h.diskState(model.episodeID) == .new)
            #expect(try await h.store.synchronizationQueue().isEmpty)
            #expect(h.results(operation.operationID) == [.cancelled])
        }
    }

    @Test func twoOffersOwnTheirCancellationAndExpiryDoesNotCancelTimer() async throws {
        try await fixture { h in
            let owner = h.coordinator(), first = try await h.model(), second = try await h.model(1)
            let start = h.clock.instant
            let a = try commit(await owner.perform(model: first, action: .removeInbox, target: h.target(first), offersUndo: true))
            let b = try commit(await owner.perform(model: second, action: .removeInbox, target: h.target(second), offersUndo: true))
            try await wait { h.clock.sleepers.count == 2 }
            #expect(h.clock.deadlines == [start.advanced(by: .seconds(2)), start.advanced(by: .seconds(2))])
            #expect(a.message == .removedFromInbox && a.actionTitleKey == "undo")
            h.clock.advance(.milliseconds(1_999)); #expect(h.deletions.isEmpty)
            #expect(await owner.undo(operationID: a.operationID) == .restored)
            await owner.endOffer(operationID: b.operationID)
            #expect(await owner.undo(operationID: b.operationID) == .notOffered)
            h.clock.advance(.milliseconds(1))
            try await wait { h.deletions.count == 1 }
            #expect(h.deletions[0].episodeID == second.episodeID)
            #expect(h.results(a.operationID) == [.cancelled]); #expect(h.results(b.operationID) == [.deleted])
            #expect(try h.diskState(first.episodeID) == .new); #expect(try h.diskState(second.episodeID) == .unplayed)
        }
    }

    @Test(arguments: EpisodePlayState.allCases) func messageAndDeltaUseAcceptedPriorState(previous: EpisodePlayState) async throws {
        try await fixture { h in
            let stale = try await h.model(), owner = h.coordinator()
            try await h.store.updateEpisode(id: stale.episodeID) { $0.userState.playState = previous }
            let value = try commit(await owner.perform(model: stale, action: .togglePlayed, target: h.target(stale), offersUndo: true))
            let message: EpisodeSwipeCoordinator.Message = previous == .new ? .removedFromInbox : previous == .unplayed ? .markedAsPlayed : .markedAsUnplayed
            #expect(value.message == message); #expect(value.message?.quantity == (previous == .new ? nil : 1))
            #expect(stale.snapshot().episode.userState.playState == (previous == .unplayed ? .played : .unplayed))
            #expect(stale.snapshot().episode.userState.positionMilliseconds == 90_000)
            #expect(await owner.undo(operationID: value.operationID) == .restored)
            #expect(stale.snapshot().episode.userState.playState == previous)
        }
    }

    @Test func silentAndMediaLessActionsHaveNoHiddenUndo() async throws {
        try await fixture { h in
            let owner = h.coordinator(), first = try await h.model()
            let a = try commit(await owner.perform(model: first, action: .removeInbox, target: h.target(first), offersUndo: false))
            #expect(a.message == nil && a.actionTitleKey == nil)
            #expect(await owner.undo(operationID: a.operationID) == .notOffered)
            try await h.store.updateEpisode(id: h.ids[1]) { $0.details.media = nil }
            let second = try await h.model(1)
            let b = try commit(await owner.perform(model: second, action: .removeInbox, target: nil, offersUndo: true))
            #expect(await owner.undo(operationID: b.operationID) == .restored)
            h.clock.advance(.seconds(2)); try await wait { h.deletions.count == 1 }
            #expect(h.deletions[0].episodeID == first.episodeID)
        }
    }

    @Test func failedInitialPersistenceHasNoDeltaOfferOrTimer() async throws {
        try await fixture { h in
            let owner = h.coordinator(), model = try await h.model(), before = model.snapshot()
            _ = try h.sql("CREATE TRIGGER reject_mark BEFORE INSERT ON episode_swipe_undo BEGIN SELECT RAISE(ABORT, 'mark failure'); END")
            #expect(await owner.perform(model: model, action: .removeInbox, target: h.target(model), offersUndo: true) == .failed)
            #expect(model.snapshot() == before); #expect(try h.diskState(model.episodeID) == .new)
            #expect(h.clock.deadlines.isEmpty && h.deletions.isEmpty)
            #expect(h.events.contains { if case .failed(nil, .mark, _) = $0 { true } else { false } })
        }
    }

    @Test func failedUndoCancelsBeforeTheBlockedWriteAndNeverClaimsRestoration() async throws {
        try await fixture { h in
            let gate = Gate(), model = try await h.model()
            var persistence = EpisodeSwipeCoordinator.Persistence(store: h.store)
            let actualUndo = persistence.undo
            persistence.undo = { receipt in await gate.wait(); return try await actualUndo(receipt) }
            let owner = h.coordinator(persistence: persistence)
            let value = try commit(await owner.perform(model: model, action: .removeInbox, target: h.target(model), offersUndo: true))
            try await wait { h.clock.sleepers.count == 1 }
            _ = try h.sql("CREATE TRIGGER reject_undo BEFORE UPDATE ON episodes BEGIN SELECT RAISE(ABORT, 'undo failure'); END")
            let attempt = Task { await owner.undo(operationID: value.operationID) }
            try await wait { await gate.entered }
            h.clock.advance(.seconds(2))
            #expect(h.deletions.isEmpty); #expect(h.results(value.operationID) == [.cancelled])
            await gate.release(); #expect(await attempt.value == .failed)
            #expect(try h.diskState(model.episodeID) == .unplayed)
            #expect(model.snapshot().episode.userState.playState == .unplayed)
            #expect(await owner.undo(operationID: value.operationID) == .notOffered)
            #expect(!h.events.contains { if case .undone(_, _, .restored, _, _) = $0 { true } else { false } })
            #expect(h.events.contains { if case .failed(_, .undo, _) = $0 { true } else { false } })
        }
    }

    @Test func undoAtDueButNotSubmittedBoundaryCancelsQueuedCallback() async throws {
        try await fixture { h in
            let owner = h.coordinator(), model = try await h.model()
            let value = try commit(await owner.perform(model: model, action: .removeInbox, target: h.target(model), offersUndo: true))
            try await wait { h.clock.sleepers.count == 1 }
            // Resume the wait without yielding this actor. The timer is due,
            // but its deletion callback has not entered its submitted phase.
            h.clock.advance(.seconds(2))
            #expect(await owner.undo(operationID: value.operationID) == .restored)
            try await wait { h.clock.sleepers.isEmpty }
            #expect(h.results(value.operationID) == [.cancelled])
            #expect(h.deletions.isEmpty)
            #expect(try h.diskState(model.episodeID) == .new)
        }
    }

    @Test func synchronousButtonRequestCancelsWithoutAwaitingItsPersistenceTask() async throws {
        try await fixture { h in
            let owner = h.coordinator(), model = try await h.model()
            let value = try commit(await owner.perform(model: model, action: .removeInbox, target: h.target(model), offersUndo: true))
            try await wait { h.clock.sleepers.count == 1 }
            let undo = owner.beginUndo(operationID: value.operationID)
            #expect(h.results(value.operationID) == [.cancelled])
            h.clock.advance(.seconds(2))
            #expect(await undo.value == .restored)
            #expect(h.deletions.isEmpty)
        }
    }

    @Test func lateUndoDoesNotCancelSubmittedDeletionOrRecreateBytes() async throws {
        try await fixture { h in
            let gate = Gate(), model = try await h.model(), target = try #require(h.target(model))
            let file = try #require(model.snapshot().episode.userState.localFileURL)
            let owner = h.coordinator { captured in
                #expect(captured == target)
                await gate.wait()
                #expect(!Task.isCancelled)
                try FileManager.default.removeItem(atPath: file)
                return .deleted
            }
            let value = try commit(await owner.perform(model: model, action: .removeInbox, target: target, offersUndo: true))
            h.clock.advance(.seconds(2)); try await wait { await gate.entered }
            #expect(await owner.undo(operationID: value.operationID) == .restored)
            #expect(FileManager.default.fileExists(atPath: file))
            await gate.release(); try await wait { h.results(value.operationID) == [.deleted] }
            #expect(!FileManager.default.fileExists(atPath: file)); #expect(try h.diskState(model.episodeID) == .new)
        }
    }

    @Test func offerReplacementAndStaleReceiptCancelOnlyTheirOwnPendingWork() async throws {
        try await fixture { h in
            let owner = h.coordinator(), model = try await h.model()
            let first = try commit(await owner.perform(model: model, action: .removeInbox, target: h.target(model), offersUndo: true))
            let second = try commit(await owner.perform(model: model, action: .togglePlayed, target: h.target(model), offersUndo: true))
            #expect(await owner.undo(operationID: first.operationID) == .superseded)
            #expect(model.snapshot().episode.userState.playState == .played)
            await owner.endOffer(operationID: first.operationID)
            h.clock.advance(.seconds(2)); try await wait { h.deletions.count == 1 }
            #expect(h.results(first.operationID) == [.cancelled]); #expect(h.results(second.operationID) == [.deleted])
            #expect(await owner.undo(operationID: second.operationID) == .restored)
            #expect(model.snapshot().episode.userState.playState == .unplayed)
        }
    }

    @Test func mutableThresholdAndFrozenTargetDoNotFollowSameIDReplacement() async throws {
        try await fixture { h in
            let owner = h.coordinator(), captured = try await h.model(), original = try #require(h.target(captured))
            captured.receivePlaybackPosition(positionMilliseconds: 0, durationMilliseconds: 120_000)
            let value = try commit(await owner.perform(model: captured, action: .removeInbox, target: original, offersUndo: true))
            captured.receivePlaybackPosition(positionMilliseconds: 90_000, durationMilliseconds: 120_000)
            try await h.store.updateEpisode(id: captured.episodeID) {
                $0.details.media?.url = "https://example.test/replacement.mp3"
                $0.userState.localFileURL = "/replacement/other.media"; $0.userState.positionMilliseconds = 0
            }
            let replacement = try await h.model()
            #expect(replacement.identity != captured.identity)
            h.clock.advance(.seconds(2)); try await wait { h.deletions.count == 1 }
            #expect(h.deletions[0] == original)
            #expect(replacement.snapshot().episode.userState.positionMilliseconds == 0)
            #expect(await owner.undo(operationID: value.operationID) == .superseded)
        }
    }

    @Test func currentSettingsAreReadAtFireAndNoEligibleCheckIsReportedAsDeletion() async throws {
        try await fixture { h in
            let owner = h.coordinator(), model = try await h.model()
            let value = try commit(await owner.perform(model: model, action: .removeInbox, target: h.target(model), offersUndo: true))
            h.preferences.value.autoDelete = false
            h.clock.advance(.seconds(2)); try await wait { h.results(value.operationID) == [.skipped] }
            #expect(h.deletions.isEmpty)
            #expect(await owner.undo(operationID: value.operationID) == .restored)
        }
    }

    @Test(arguments: [false, true]) func callbackStaleAndFailureAreNeverDeletionSuccess(fails: Bool) async throws {
        try await fixture { h in
            let model = try await h.model()
            let owner = h.coordinator { _ in if fails { throw FeedLibraryError.invalidMutation }; return .stale }
            let value = try commit(await owner.perform(model: model, action: .removeInbox, target: h.target(model), offersUndo: true))
            h.clock.advance(.seconds(2)); try await wait { !h.results(value.operationID).isEmpty }
            #expect(h.results(value.operationID) == [fails ? .failed : .stale])
            #expect(await owner.undo(operationID: value.operationID) == .restored)
            #expect(h.events.contains { if case .failed(_, .cleanup, _) = $0 { true } else { false } } == fails)
        }
    }

    @Test func replacementDuringCommitCannotPatchTheNewPresentationAndDoesNotRestartDeadline() async throws {
        try await fixture { h in
            let gate = Gate(), captured = try await h.model(), target = h.target(captured), start = h.clock.instant
            var persistence = EpisodeSwipeCoordinator.Persistence(store: h.store)
            let actualApply = persistence.apply
            persistence.apply = { id, action in await gate.wait(); return try await actualApply(id, action) }
            let owner = h.coordinator(persistence: persistence)
            let mutation = Task { await owner.perform(model: captured, action: .removeInbox, target: target, offersUndo: true) }
            try await wait { await gate.entered }
            let replacement = try await h.model()
            owner.onEvent = { event in
                h.events.append(event)
                if case .committed(let value) = event, value.modelIdentity == replacement.identity {
                    replacement.applyCommittedState(value.delta)
                }
            }
            h.clock.advance(.seconds(3)); #expect(h.deletions.isEmpty)
            await gate.release(); let value = try commit(await mutation.value)
            try await wait { h.deletions.count == 1 }
            #expect(h.clock.deadlines == [start.advanced(by: .seconds(2))])
            #expect(value.modelIdentity == captured.identity)
            #expect(captured.snapshot().episode.userState.playState == .unplayed)
            #expect(replacement.snapshot().episode.userState.playState == .new)
        }
    }

    @Test func teardownCancelsWaitingTasksAndSuppressesLateCommittedPresentation() async throws {
        try await fixture { h in
            let gate = Gate(), first = try await h.model(), second = try await h.model(1)
            var persistence = EpisodeSwipeCoordinator.Persistence(store: h.store)
            let actualApply = persistence.apply, secondID = second.episodeID
            persistence.apply = { id, action in
                if id == secondID { await gate.wait() }
                return try await actualApply(id, action)
            }
            let owner = h.coordinator(persistence: persistence)
            _ = try commit(await owner.perform(model: first, action: .removeInbox, target: h.target(first), offersUndo: true))
            let mutation = Task { await owner.perform(model: second, action: .removeInbox, target: h.target(second), offersUndo: true) }
            try await wait { await gate.entered }
            let before = h.events.count
            owner.invalidateLibrary(); h.clock.advance(.seconds(2)); await gate.release()
            #expect(await mutation.value == .invalidated)
            #expect(h.events.count == before && h.deletions.isEmpty)
            #expect(await owner.perform(model: first, action: .togglePlayed, target: h.target(first), offersUndo: true) == .invalidated)
        }
    }

    @Test func malformedTargetDoesNotMutateAndRawFileSpellingIsPreserved() async throws {
        try await fixture { h in
            let owner = h.coordinator(), model = try await h.model()
            #expect(await owner.perform(model: model, action: .removeInbox, target: nil, offersUndo: true) == .failed)
            #expect(try h.diskState(model.episodeID) == .new)
            let file = "/owned/é/../literal.media"
            try await h.store.updateEpisode(id: model.episodeID) { $0.userState.localFileURL = file }
            let exact = try await h.model(), target = try #require(h.target(exact))
            _ = try commit(await owner.perform(model: exact, action: .removeInbox, target: target, offersUndo: false))
            h.clock.advance(.seconds(2)); try await wait { h.deletions.count == 1 }
            if case .remote(_, let originalFile) = h.deletions[0].media { #expect(originalFile?.utf16.elementsEqual(file.utf16) == true) }
            else { Issue.record("Expected captured remote target") }
        }
    }

    @Test func localCallbackReceivesOriginalRegistrationAfterReconnect() async throws {
        try await fixture { h in
            let context = try await h.store.registerLocalFolder(title: "Local", directoryIdentity: "original", bookmark: Data([1]))
            let scanned = try await h.store.applyLocalFolderScan(.init(format: .rss, episodes: [
                .init(identifier: "local", link: "one.mp3", media: .init(url: "file:///original/one.mp3", size: 42, durationMilliseconds: 120_000))
            ]), context: context)
            let id = try #require(scanned.feed.episodes.first?.id)
            try await h.store.updateEpisode(id: id) { $0.userState.playState = .new; $0.userState.positionMilliseconds = 90_000 }
            let reference = try #require(try await h.store.localDocument(episodeID: id))
            let model = EpisodeActionModel(item: .init(episode: try #require(try await h.store.episode(id: id)), local: true))
            let target = EpisodeMediaDeletionTarget(episodeID: id, feedID: context.feed.id, source: "antennapod_local:original", media: .local(reference))
            let owner = h.coordinator { captured in
                h.deletions.append(captured)
                #expect(captured == target)
                return .stale // Explicit injected admission result, not a real provider test.
            }
            h.preferences.value.autoDeleteLocal = true
            let value = try commit(await owner.perform(model: model, action: .removeInbox, target: target, offersUndo: true))
            _ = try await h.store.reconnectLocalFolder(feedID: context.feed.id, directoryIdentity: "replacement", bookmark: Data([2]))
            h.clock.advance(.seconds(2)); try await wait { h.deletions.count == 1 }
            #expect(h.results(value.operationID) == [.stale])
            #expect(await owner.undo(operationID: value.operationID) == .superseded)
        }
    }
}

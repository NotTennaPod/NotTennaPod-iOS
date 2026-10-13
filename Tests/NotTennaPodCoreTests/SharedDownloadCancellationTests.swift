import Foundation
import Testing
@testable import NotTennaPodCore

struct SharedDownloadCancellationTests {
    private func fixture(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedCancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let url = URL(string: "https://example.invalid/feed")!
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Shared", episodes: (1...3).map {
            .init(identifier: "\($0)", title: "Episode \($0)", media: .init(url: "https://example.invalid/\($0 == 3 ? "other" : "shared").mp3", size: 100))
        }), source: url.absoluteString, responseURL: url, validator: nil, permanentRedirectURL: nil))
        do { try await body(store, root); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    @Test func callerEffectsPreserveTheOtherEpisodesPartialForResumptionAcrossReopen() async throws {
        for ownerPrequeued in [false, true] {
            for callerHasFile in [false, true] {
                for deleteRemoves in [false, true] {
                    try await fixture { store, root in
                        try await store.selectSynchronizationAccount(UUID())
                        _ = try await store.enqueue(ownerPrequeued ? [1, 2] : [2])
                        let job = try #require(try await store.requestDownload(episodeID: 1, directory: root))
                        let attempt = try #require(try await store.beginDownloadAttempt(id: job.id))
                        try Data("owner partial".utf8).write(to: job.destination)
                        #expect(try await store.attachDownloadFile(id: job.id, attempt: attempt.attempts))
                        let callerFile = root.appendingPathComponent("caller-partial.media")
                        if callerHasFile {
                            try Data("caller partial".utf8).write(to: callerFile)
                            try await store.updateEpisode(id: 2) {
                                $0.userState.localFileURL = callerFile.path
                                $0.details.media?.hasEmbeddedPicture = true
                            }
                        }
                        let originalOwner = try #require(try await store.episode(id: 1))
                        #expect(try await store.cancelDownload(id: job.id, callerEpisodeID: 2, deleteRemovesFromQueue: deleteRemoves))
                        let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
                        let owner = try #require(try await reopened.episode(id: 1))
                        let caller = try #require(try await reopened.episode(id: 2))
                        #expect(owner == originalOwner)
                        #expect(!caller.userState.autoDownloadEnabled && caller.userState.localFileURL == nil)
                        if callerHasFile { #expect(caller.details.media?.hasEmbeddedPicture == false) }
                        let queue = try await reopened.queue().map(\.id)
                        #expect(queue.contains(1))
                        #expect(queue.contains(2) == (ownerPrequeued && !(callerHasFile && deleteRemoves)))
                        let cleanup = try await reopened.pendingEffects()
                        #expect(cleanup.filter { if case .deleteDownloadFile(_, let episode, _, _) = $0.effect.kind { episode.id == 2 } else { false } }.count == (callerHasFile ? 1 : 0))
                        #expect(FileManager.default.fileExists(atPath: job.destination.path))
                        let worker = MediaDownloadWorker(store: reopened)
                        try await worker.cleanCancelledFiles()
                        #expect(try Data(contentsOf: job.destination) == Data("owner partial".utf8))
                        #expect(!FileManager.default.fileExists(atPath: callerFile.path))
                        // The caller's deleted partial is reported once (DELETE for its episode) and its work is done.
                        #expect(try await reopened.pendingEffects().allSatisfy {
                            if case .deleteDownloadFile = $0.effect.kind { false } else { true }
                        })
                        let deleted = try await reopened.synchronizationQueue().compactMap { change -> String? in
                            if case .episode(let action) = change.value, action.action == .delete { action.guid } else { nil }
                        }
                        #expect(deleted == (callerHasFile ? ["2"] : []))
                        let restarted = try #require(try await reopened.requestDownload(episodeID: 1, directory: root))
                        #expect(restarted.id != job.id)
                        #expect(try await reopened.completeDownload(id: job.id, attempt: attempt.attempts) == false)
                        #expect(try await reopened.cancelDownload(id: job.id) == false)
                        try await worker.cleanCancelledFiles()
                        #expect(try Data(contentsOf: restarted.destination) == Data("owner partial".utf8))
                        try await reopened.close()
                    }
                }
            }
        }
    }

    @Test func unrelatedAndMissingCallersCannotCancelOrMutateTheJob() async throws {
        try await fixture { store, root in
            let job = try #require(try await store.requestDownload(episodeID: 1, directory: root))
            let original = try await store.snapshot(), effects = try await store.pendingEffects()
            for caller: Int64 in [3, 404] {
                await #expect(throws: (any Error).self) { try await store.cancelDownload(id: job.id, callerEpisodeID: caller) }
                let worker = MediaDownloadWorker(store: store)
                await #expect(throws: (any Error).self) { try await worker.cancel(id: job.id, callerEpisodeID: caller) }
                #expect(try await store.downloadJob(id: job.id) == job)
                #expect(try await store.snapshot() == original)
                #expect(try await store.pendingEffects() == effects)
            }
        }
    }

    @Test func sharedCancellationFailureRollsBackBothEpisodesQueueAndCleanup() async throws {
        try await fixture { store, root in
            _ = try await store.enqueue([2])
            let job = try #require(try await store.requestDownload(episodeID: 1, directory: root))
            let attempt = try #require(try await store.beginDownloadAttempt(id: job.id))
            try Data("partial".utf8).write(to: job.destination)
            #expect(try await store.attachDownloadFile(id: job.id, attempt: attempt.attempts))
            let snapshot = try await store.snapshot(), effects = try await store.pendingEffects()
            let injector = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            try injector.execute("CREATE TRIGGER reject_shared_cancel BEFORE UPDATE ON download_jobs BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: (any Error).self) { try await store.cancelDownload(id: job.id, callerEpisodeID: 2) }
            #expect(try await store.snapshot() == snapshot)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.downloadJob(id: job.id)?.state == .transferring)
            #expect(try Data(contentsOf: job.destination) == Data("partial".utf8))
            try injector.close()
        }
    }

    @Test func sourceChangesAndPendingDeletionPreventReusingAnObsoletePartial() async throws {
        for changedSource in [false, true] {
            try await fixture { store, root in
                let job = try #require(try await store.requestDownload(episodeID: 1, directory: root))
                let attempt = try #require(try await store.beginDownloadAttempt(id: job.id))
                try Data("partial".utf8).write(to: job.destination)
                #expect(try await store.attachDownloadFile(id: job.id, attempt: attempt.attempts))
                #expect(try await store.cancelDownload(id: job.id, callerEpisodeID: 2))
                if changedSource {
                    try await store.updateEpisode(id: 1) { $0.details.media?.url = "https://example.invalid/replacement.mp3" }
                } else {
                    // A previously journaled deletion must never target the new job's file.
                    let episode = try #require(try await store.episode(id: 1))
                    let effect = FeedLibraryEffect(feedID: 1, date: Date(), kind: .deleteDownloadFile(
                        file: job.destination, episode: episode, source: "https://example.invalid/feed", synchronize: true))
                    let injector = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
                    try injector.execute("INSERT INTO pending_effects(record) VALUES (?)",
                        [.blob(try JSONEncoder().encode(effect))])
                    try injector.close()
                }
                let replacement = try #require(try await store.requestDownload(episodeID: 1, directory: root))
                #expect(replacement.destination != job.destination && replacement.representation == nil)
                try Data("replacement".utf8).write(to: replacement.destination)
                try await MediaDownloadWorker(store: store).cleanCancelledFiles()
                #expect(try Data(contentsOf: replacement.destination) == Data("replacement".utf8))
            }
        }
    }

    @Test func aRetainedPartialRequiringResetCannotResumeItsInvalidBytes() async throws {
        try await fixture { store, root in
            let job = try #require(try await store.requestDownload(episodeID: 1, directory: root))
            let attempt = try #require(try await store.beginDownloadAttempt(id: job.id))
            try Data("invalid partial".utf8).write(to: job.destination)
            #expect(try await store.attachDownloadFile(id: job.id, attempt: attempt.attempts))
            _ = try await store.acceptDownloadRepresentation(id: job.id, attempt: attempt.attempts,
                representation: .init(resource: URL(string: job.source)!, entityTag: "\"old\"", total: 100))
            _ = try await store.recordDownloadFailure(id: job.id, attempt: attempt.attempts, failure: .http(416))
            #expect(try await store.cancelDownload(id: job.id, callerEpisodeID: 2))
            let next = try #require(try await store.requestDownload(episodeID: 1, directory: root))
            #expect(next.fileResetRequired == true)
            #expect(try await store.beginDownloadAttempt(id: next.id) == nil)
            try await MediaDownloadWorker(store: store).recoverStoppedForegroundWork()
            #expect(!FileManager.default.fileExists(atPath: next.destination.path))
            let recovered = try #require(try await store.downloadJob(id: next.id))
            #expect(recovered.fileResetRequired == false && recovered.representation == nil)
            #expect(try await store.beginDownloadAttempt(id: next.id)?.attempts == 1)
        }
    }
}

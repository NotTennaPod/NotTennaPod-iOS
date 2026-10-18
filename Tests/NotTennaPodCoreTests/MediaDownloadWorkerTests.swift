import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite
struct MediaDownloadWorkerTests {
    private final class HeldTransfer: MediaTransferring {
        private struct State {
            var continuation: CheckedContinuation<MediaDownloadResult, any Error>?
            var cancelled = false
        }
        private let state = Mutex(State())
        var started: Bool { state.withLock { $0.continuation != nil } }
        var cancelled: Bool { state.withLock { $0.cancelled } }
        func download(_ input: MediaDownloadRequest,
                      progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in state.withLock { $0.continuation = continuation } }
            } onCancel: { self.state.withLock { $0.cancelled = true } }
        }
        func release() {
            let pending = state.withLock { let pending = $0.continuation; $0.continuation = nil; return pending }
            pending?.resume(throwing: CancellationError())
        }
    }

    private final class Clock: Sendable {
        private let state = Mutex((date: Date(timeIntervalSince1970: 1_700_000_000), waits: [TimeInterval]()))
        var now: Date { state.withLock { $0.date } }
        var waits: [TimeInterval] { state.withLock { $0.waits } }
        func advance(_ seconds: TimeInterval) { state.withLock { $0.date += seconds; $0.waits.append(seconds) } }
    }

    private func withJob(source: String, transcript: FeedTranscript? = nil, networkConstraint: DownloadNetworkConstraint = .unmetered, _ operation: (FeedLibraryStore, LibraryDownloadJob, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadWorker-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let episode = ParsedEpisode(identifier: "episode", title: "Episode", media: ParsedMedia(url: source, size: 120_017, durationMilliseconds: 30_000), transcript: transcript)
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Worker fixture", episodes: [episode]),
                                              source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                                              validator: nil, permanentRedirectURL: nil))
        let job = try #require(try await store.requestDownload(episodeID: 1, directory: directory, networkConstraint: networkConstraint, now: Clock().now))
        do { try await operation(store, job, url); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func worker(_ store: FeedLibraryStore, _ clock: Clock) -> MediaDownloadWorker {
        MediaDownloadWorker(store: store, clock: { clock.now }, wait: { clock.advance($0) },
                            network: allowedNetwork(), duration: { _ in 30_040 })
    }

    private func allowedNetwork() -> DownloadNetworkMonitor {
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: false, cellular: false))
        return network
    }

    private func awaitRequest(_ server: LoopbackHTTPServer) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while server.requests.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(!server.requests.isEmpty)
    }

    @Test func deletionWaitsForActiveWriterBeforeExternalFileCleanup() async throws {
        try await withJob(source: "https://example.org/held.mp3") { store, job, _ in
            let transfer = HeldTransfer()
            let worker = MediaDownloadWorker(store: store, transfer: transfer, network: allowedNetwork())
            let active = Task { try await worker.run(id: job.id) }
            let deadline = ContinuousClock.now + .seconds(5)
            while !transfer.started && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(transfer.started)
            let feed = try #require(try await store.feeds().first)
            _ = try await store.requestFeedDeletion(feedID: feed.id)
            let retired = Mutex(false)
            let retirement = Task { try await worker.retireDeletedJobs([job.id]); retired.withLock { $0 = true } }
            while !transfer.cancelled && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            #expect(transfer.cancelled && !retired.withLock { $0 })
            transfer.release()
            try await retirement.value
            #expect(try await active.value == .interrupted)
            #expect(try await store.downloadJob(id: job.id) == nil)
            #expect(try await store.feed(id: feed.id) == nil)
        }
    }

    @Test(arguments: ["valid", "malformed", "offline"])
    func transcriptSidecarCompletesWithMediaAndIsRemoved(kind: String) async throws {
        let media = Data(repeating: 93, count: 1024)
        let text = kind == "valid" ? "{\"segments\":[{\"startTime\":0,\"endTime\":5,\"body\":\"Offline text\"}]}" : "Malformed publisher transcript"
        let server = try await LoopbackHTTPServer.start { request in
            if request.path.contains("transcript") {
                return .init(status: kind == "offline" ? 503 : 200, body: Data(text.utf8))
            }
            return .init(body: media)
        }
        defer { server.stop() }
        let descriptor = FeedTranscript(format: .json, url: server.url.appendingPathComponent("transcript").absoluteString)
        try await withJob(source: server.url.absoluteString, transcript: descriptor) { store, job, _ in
            let loader = TranscriptLoader(transport: URLSessionFeedTransport(), cache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0), userAgent: "sidecar-test")
            let runner = MediaDownloadWorker(store: store, network: allowedNetwork(), transcriptLoader: loader,
                duration: { _ in 30_000 }, artwork: { _ in false })
            #expect(try await runner.run(id: job.id) == .completed)
            #expect(try await store.episode(id: job.episodeID)?.userState.isDownloaded == true)
            let sidecar = URL(fileURLWithPath: job.destination.path + ".transcript")
            if kind == "offline" { #expect(!FileManager.default.fileExists(atPath: sidecar.path)) }
            else { #expect(try String(contentsOf: sidecar, encoding: .utf8) == text) }
            if kind == "valid" {
                server.stop()
                #expect(try await loader.load(descriptor, localMediaPath: job.destination.path).segments.first?.words == "Offline text")
            }
            // The shared deletion operation is used by episode, cleanup and feed removal owners.
            try FeedDeletionCoordinator.unlinkDownload(job.destination)
            #expect(!FileManager.default.fileExists(atPath: sidecar.path))
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
        }
    }

    @Test func cancellingWhileTranscriptDownloadsRetiresWriterBeforeCleanup() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.path.contains("transcript") {
                return .init(body: Data("unfinished".utf8), keepConnectionOpen: true, includeAutomaticContentLength: false)
            }
            return .init(body: Data(repeating: 93, count: 1024))
        }
        defer { server.stop() }
        let descriptor = FeedTranscript(format: .json, url: server.url.appendingPathComponent("transcript").absoluteString)
        try await withJob(source: server.url.absoluteString, transcript: descriptor) { store, job, _ in
            let loader = TranscriptLoader(transport: URLSessionFeedTransport(), cache: URLCache(memoryCapacity: 1024, diskCapacity: 0), userAgent: "test")
            let runner = MediaDownloadWorker(store: store, network: allowedNetwork(), transcriptLoader: loader,
                duration: { _ in 30_000 }, artwork: { _ in false })
            let running = Task { try await runner.run(id: job.id) }
            let end = ContinuousClock.now + .seconds(5)
            while !server.requests.contains(where: { $0.path.contains("transcript") }), ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(server.requests.contains(where: { $0.path.contains("transcript") }))
            #expect(try await runner.cancel(id: job.id))
            #expect(try await running.value == .interrupted)
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(!FileManager.default.fileExists(atPath: job.destination.path + ".transcript"))
        }
    }

    @Test func realTransferPublishesCurrentStateAndOneSuccessLog() async throws {
        let body = Data(repeating: 93, count: 100_003)
        let server = try await LoopbackHTTPServer.start { _ in .init(body: body) }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, url in
            try await store.updateEpisode(id: 1) { $0.userState.positionMilliseconds = 3_883; $0.userState.isFavorite = true }
            let clock = Clock()
            let runner = worker(store, clock)
            #expect(try await runner.run(id: job.id) == .completed)
            #expect(try await runner.run(id: job.id) == .notStarted)
            let reopened = try FeedLibraryStore(url: url)
            let saved = try #require(try await reopened.downloadJob(id: job.id))
            #expect(saved.state == .completed && saved.attempts == 1)
            #expect(saved.logs == [.init(date: clock.now, attempt: 1, failure: nil, title: "Episode")])
            let episode = try #require(try await reopened.episode(id: 1))
            #expect(episode.userState.isDownloaded && !episode.userState.autoDownloadEnabled)
            #expect(episode.userState.positionMilliseconds == 3_883 && episode.userState.isFavorite)
            #expect(episode.details.media?.size == 100_003 && episode.details.media?.durationMilliseconds == 30_040)
            #expect(try Data(contentsOf: job.destination) == body)
            #expect(try await reopened.queue().map(\.id) == [1])
            #expect(server.requests.count == 1 && clock.waits.isEmpty)
            try await reopened.close()
        }
    }

    @Test func corruptResumeCannotPublishDownloadedStateOrSuccessAfterReopen() async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .init(status: 206, headers: ["Content-Range": "bytes 5-7/8"], body: Data("xyz".utf8))
        }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, url in
            try Data("abc".utf8).write(to: job.destination)
            try await store.updateEpisode(id: 1) {
                $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 3_883
            }
            let before = try #require(try await store.episode(id: 1))
            let clock = Clock()
            #expect(try await worker(store, clock).run(id: job.id) == .failed(.invalidRange))
            let reopened = try FeedLibraryStore(url: url)
            let saved = try #require(try await reopened.downloadJob(id: job.id))
            #expect(saved.state == .failed && saved.attempts == 3)
            #expect(saved.logs?.map(\.failure) == [.invalidRange, .invalidRange, .invalidRange])
            let episode = try #require(try await reopened.episode(id: 1))
            #expect(!episode.userState.isDownloaded && episode.userState.downloadDate == nil)
            #expect(episode.userState.isFavorite && episode.userState.positionMilliseconds == 3_883)
            #expect(episode.details == before.details)
            #expect(try await reopened.queue().map(\.id) == [1])
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(server.requests.map { $0.headers["range"] } == Array<String?>(repeating: nil, count: 3))
            try await reopened.close()
        }
    }

    @Test func retryableHTTPFailureStopsAtThreeAttemptsWithExponentialWaitsAndCleanup() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(status: 500, body: Data()) }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, _ in
            try Data("partial".utf8).write(to: job.destination)
            let clock = Clock()
            let started = clock.now
            #expect(try await worker(store, clock).run(id: job.id) == .failed(.http(500)))
            let saved = try #require(try await store.downloadJob(id: job.id))
            #expect(saved.state == .failed && saved.attempts == 3 && saved.fileResetRequired == false)
            #expect(saved.logs?.map(\.attempt) == [1, 2, 3])
            #expect(saved.logs?.map(\.failure) == [.http(500), .http(500), .http(500)])
            #expect(saved.logs?.map { $0.date.timeIntervalSince(started) } == [0, 30, 90])
            #expect(clock.waits == [30, 60] && server.requests.count == 3)
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.episode(id: 1)?.userState.isDownloaded == false)
        }
    }

    @Test(arguments: [401, 403, 404, 410])
    func fatalHTTPStatusDoesNotRetryOrRemoveQueue(_ status: Int) async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(status: status, body: Data()) }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { (store, job, _) async throws in
            let clock = Clock()
            #expect(try await worker(store, clock).run(id: job.id) == .failed(.http(status)))
            #expect(try await store.downloadJob(id: job.id)?.attempts == 1)
            #expect(server.requests.count == 1 && clock.waits.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.episode(id: 1)?.userState.autoDownloadEnabled == true)
        }
    }

    @Test func invalidRangeRestartsWithoutOrdinaryFailureLog() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            request.headers["range"] == nil ? .init(body: Data("complete".utf8)) : .init(status: 416, body: Data())
        }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, _ in
            try Data("partial".utf8).write(to: job.destination)
            let clock = Clock()
            _ = try await store.beginDownloadAttempt(id: job.id, now: clock.now)
            #expect(try await store.acceptDownloadRepresentation(id: job.id, attempt: 1,
                representation: .init(resource: server.url, entityTag: "\"v1\"")))
            #expect(try await store.interruptDownload(id: job.id, attempt: 1, now: clock.now))
            #expect(try await worker(store, clock).run(id: job.id) == .completed)
            let saved = try #require(try await store.downloadJob(id: job.id))
            #expect(saved.attempts == 3 && saved.logs == [.init(date: clock.now, attempt: 3, failure: nil, title: "Episode")])
            // The interrupted first attempt does not count, so the 416 is the first counted
            // attempt and waits 30 s (Android would count the stop and wait 60 s; not copied).
            #expect(saved.countedAttempts == 2 && clock.waits == [30])
            #expect(server.requests.map { $0.headers["range"] } == ["bytes=7-", nil])
            #expect(try Data(contentsOf: job.destination) == Data("complete".utf8))
        }
    }

    @Test func retryDeadlineSurvivesReopenAndCannotBeClaimedEarly() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("complete".utf8)) }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, url in
            let clock = Clock()
            _ = try await store.beginDownloadAttempt(id: job.id, now: clock.now)
            let failed = try #require(try await store.recordDownloadFailure(id: job.id, attempt: 1, failure: .connection, now: clock.now))
            #expect(failed.retryAt == clock.now + 30)
            #expect(try await store.beginDownloadAttempt(id: job.id, now: clock.now + 29.999) == nil)
            #expect(try await store.recordDownloadFailure(id: job.id, attempt: 1, failure: .http(404), now: clock.now) == nil)
            try await store.close()
            clock.advance(10)
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.downloadJob(id: job.id) == failed)
            #expect(try await worker(reopened, clock).run(id: job.id) == .completed)
            #expect(clock.waits == [10, 20])
            #expect(try await reopened.downloadJob(id: job.id)?.logs?.map(\.failure) == [.connection, nil])
            try await reopened.close()
        }
    }

    @Test func taskCancellationRetainsPartialFileAndReleasesAttempt() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, _ in
            try Data("partial".utf8).write(to: job.destination)
            let runner = worker(store, Clock())
            let task = Task { try await runner.run(id: job.id) }
            defer { task.cancel() }
            try await awaitRequest(server)
            task.cancel()
            #expect(try await task.value == .interrupted)
            #expect(try await store.downloadJob(id: job.id)?.state == .waiting)
            #expect(try Data(contentsOf: job.destination) == Data("partial".utf8))
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.episode(id: 1)?.userState.autoDownloadEnabled == true)
        }
    }

    @Test func explicitCancellationStopsTransferDeletesFileAndRetainsSyncWork() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, _ in
            try Data("partial".utf8).write(to: job.destination)
            try await store.selectSynchronizationAccount(UUID())
            let runner = worker(store, Clock())
            let task = Task { try await runner.run(id: job.id) }
            defer { task.cancel() }
            try await awaitRequest(server)
            await #expect(throws: FeedLibraryError.invalidMutation) { try await runner.recoverStoppedForegroundWork() }
            #expect(try await runner.cancel(id: job.id))
            #expect(try await task.value == .interrupted)
            #expect(try await store.downloadJob(id: job.id)?.state == .cancelled)
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(try await store.queue().isEmpty)
            #expect(try await store.episode(id: 1)?.userState.autoDownloadEnabled == false)
            // The deleted file's DELETE action is in the account's outbox; the deletion work is done.
            let effects = try await store.pendingEffects()
            #expect(!effects.contains { if case .deleteDownloadFile = $0.effect.kind { true } else { false } })
            let actions = try await store.synchronizationQueue().compactMap { if case .episode(let action) = $0.value { action } else { nil } }
            #expect(actions.map(\.action) == [.delete])
            #expect(actions.first?.podcast == "https://example.test/feed" && actions.first?.episode == server.url.absoluteString)
            try await runner.cleanCancelledFiles()
            #expect(try await store.pendingEffects() == effects)
        }
    }

    @Test func recoveryReclaimsStoppedAttemptAndFinishesPreviouslyRecordedDeletion() async throws {
        try await withJob(source: "https://example.test/audio") { store, job, url in
            _ = try await store.beginDownloadAttempt(id: job.id)
            try Data("partial".utf8).write(to: job.destination)
            _ = try await store.attachDownloadFile(id: job.id, attempt: 1)
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            let runner = worker(reopened, Clock())
            try await runner.recoverStoppedForegroundWork()
            #expect(try await reopened.downloadJob(id: job.id)?.state == .waiting)
            #expect(try Data(contentsOf: job.destination) == Data("partial".utf8))
            _ = try await reopened.cancelDownload(id: job.id)
            try FileManager.default.removeItem(at: job.destination)
            try await runner.recoverStoppedForegroundWork()
            // A file that is already gone still completes (acknowledges) the deletion work.
            #expect(!(try await reopened.pendingEffects()).contains { if case .deleteDownloadFile = $0.effect.kind { true } else { false } })
            try await reopened.close()
        }
    }

    @Test func failureBeforeResetAcknowledgmentIsRecoveredWithoutEarlyRetry() async throws {
        try await withJob(source: "https://example.test/audio") { store, job, _ in
            let clock = Clock()
            _ = try await store.beginDownloadAttempt(id: job.id, now: clock.now)
            try Data("partial".utf8).write(to: job.destination)
            _ = try await store.recordDownloadFailure(id: job.id, attempt: 1, failure: .http(416), now: clock.now)
            #expect(try await store.beginDownloadAttempt(id: job.id, now: clock.now + 30) == nil)
            #expect(try await store.acknowledgeDownloadFileReset(id: job.id, attempt: 2) == false)
            try await worker(store, clock).recoverStoppedForegroundWork()
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(try await store.beginDownloadAttempt(id: job.id, now: clock.now) == nil)
            #expect(try await store.beginDownloadAttempt(id: job.id, now: clock.now + 30)?.attempts == 2)
        }
    }

    @Test func metadataFailureRetainsFeedDurationWithoutRetryingValidDownload() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("complete".utf8)) }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { (store, job, _) async throws in
            let runner = MediaDownloadWorker(store: store, network: allowedNetwork(), duration: { _ in throw CocoaError(.fileReadCorruptFile) })
            #expect(try await runner.run(id: job.id) == .completed)
            #expect(try await store.episode(id: 1)?.details.media?.durationMilliseconds == 30_000)
            #expect(server.requests.count == 1)
        }
    }

    @Test func olderVersionThreeJobDecodesWithoutNewOptionalFields() async throws {
        try await withJob(source: "https://example.test/audio") { _, job, _ in
            var older = job
            older.networkConstraint = nil
            let data = try JSONEncoder().encode(older)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["retryAt"] == nil && object["fileResetRequired"] == nil && object["logs"] == nil && object["networkConstraint"] == nil)
            #expect(try JSONDecoder().decode(LibraryDownloadJob.self, from: data) == older)
        }
    }

    @Test func cancellationDuringBackoffPreservesDeadlineWithoutAnotherRequest() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(status: 500, body: Data()) }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, _ in
            let waiting = Mutex(false)
            let clock = Clock()
            let runner = MediaDownloadWorker(store: store, clock: { clock.now }, wait: { _ in
                waiting.withLock { $0 = true }
                try await Task.sleep(for: .seconds(30))
            }, network: allowedNetwork(), duration: { _ in nil })
            let task = Task { try await runner.run(id: job.id) }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !waiting.withLock({ $0 }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(waiting.withLock { $0 })
            task.cancel()
            #expect(try await task.value == .interrupted)
            let saved = try #require(try await store.downloadJob(id: job.id))
            #expect(saved.state == .waiting && saved.attempts == 1 && saved.retryAt == clock.now + 30)
            #expect(server.requests.count == 1)
            #expect(try await runner.cancel(id: job.id))
            #expect(try await store.queue().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
        }
    }

    @Test func anotherWorkerCannotClaimActiveTransfer() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, _ in
            let first = worker(store, Clock())
            let second = worker(store, Clock())
            let task = Task { try await first.run(id: job.id) }
            defer { task.cancel() }
            try await awaitRequest(server)
            #expect(try await second.run(id: job.id) == .notStarted)
            #expect(try await store.downloadJob(id: job.id)?.attempts == 1 && server.requests.count == 1)
            task.cancel()
            #expect(try await task.value == .interrupted)
        }
    }

    @Test func completionDatabaseFailureDoesNotPublishOrDeleteValidFile() async throws {
        let body = Data("complete".utf8)
        let server = try await LoopbackHTTPServer.start { _ in .init(body: body) }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, url in
            let effectsBefore = try await store.pendingEffects()
            let injector = try LibrarySQLite(url: url)
            try injector.execute("CREATE TRIGGER reject_worker_completion BEFORE UPDATE ON download_jobs WHEN NEW.active = 0 BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            let runner = worker(store, Clock())
            await #expect(throws: (any Error).self) { try await runner.run(id: job.id) }
            #expect(try await store.downloadJob(id: job.id)?.state == .transferring)
            #expect(try await store.downloadJob(id: job.id)?.logs == nil)
            #expect(try await store.episode(id: 1)?.userState.isDownloaded == false)
            #expect(try Data(contentsOf: job.destination) == body)
            #expect(try await store.pendingEffects() == effectsBefore)
            try injector.execute("DROP TRIGGER reject_worker_completion")
            try injector.close()
            try await runner.recoverStoppedForegroundWork()
            #expect(try await runner.run(id: job.id) == .completed)
            #expect(try await store.downloadJob(id: job.id)?.logs?.count == 1)
        }
    }

    @Test func cancellationPreventsNewRunUntilOldTransferHasStopped() async throws {
        try await withJob(source: "https://example.test/audio") { store, job, _ in
            let transfer = HeldTransfer()
            let runner = MediaDownloadWorker(store: store, transfer: transfer, network: allowedNetwork())
            let run = Task { try await runner.run(id: job.id) }
            defer { run.cancel(); transfer.release() }
            let startDeadline = ContinuousClock.now + .seconds(5)
            while !transfer.started && ContinuousClock.now < startDeadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(transfer.started)
            let cancel = Task { try await runner.cancel(id: job.id) }
            defer { cancel.cancel() }
            let cancelDeadline = ContinuousClock.now + .seconds(5)
            while !transfer.cancelled && ContinuousClock.now < cancelDeadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(transfer.cancelled)
            #expect(try await runner.run(id: job.id) == .notStarted)
            #expect(try await store.downloadJob(id: job.id)?.state == .transferring)
            #expect(FileManager.default.fileExists(atPath: job.destination.path))
            transfer.release()
            #expect(try await cancel.value)
            #expect(try await run.value == .interrupted)
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(try await store.downloadJob(id: job.id)?.state == .cancelled)
        }
    }

    @Test func nativeMeasuredDurationMatchesAndroidMetadataRetrieverFixture() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = root.appendingPathComponent("TestSupport/Media/listening/30sec.mp3")
        let duration = try await MediaDownloadWorker.mediaDuration(file)
        #expect(duration.map { abs(Int64($0) - 30_041) <= 50 } == true)
        try await withJob(source: "https://example.test/audio") { _, job, _ in
            try FileManager.default.copyItem(at: file, to: job.destination)
            let storedDuration = try await MediaDownloadWorker.mediaDuration(job.destination)
            #expect(storedDuration.map { abs(Int64($0) - 30_041) <= 50 } == true)
        }
    }

    @Test func restrictedRequestWaitsWithoutFileOrAttemptThenStartsWhenPermitted() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, url in
            let monitor = DownloadNetworkMonitor(startMonitoring: false)
            monitor.update(.init(connected: false, metered: true, cellular: true))
            let runner = MediaDownloadWorker(store: store, network: monitor, duration: { _ in nil })
            let task = Task { try await runner.run(id: job.id) }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.pendingWaitCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(monitor.pendingWaitCount == 1)
            #expect(try await store.downloadJob(id: job.id)?.attempts == 0)
            #expect(try await store.downloadJob(id: job.id)?.state == .waiting)
            #expect(server.requests.isEmpty && !FileManager.default.fileExists(atPath: job.destination.path))
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.downloadJob(id: job.id)?.networkConstraint == .unmetered)
            try await reopened.close()
            monitor.update(.init(connected: true, metered: false, cellular: false))
            #expect(try await task.value == .completed)
            #expect(server.requests.count == 1)
        }
    }

    @Test func cancellationWhileWaitingForNetworkDoesNotCreateFileOrFailureLog() async throws {
        try await withJob(source: "https://example.test/audio") { store, job, _ in
            let monitor = DownloadNetworkMonitor(startMonitoring: false)
            let runner = MediaDownloadWorker(store: store, network: monitor)
            let task = Task { try await runner.run(id: job.id) }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.pendingWaitCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(monitor.pendingWaitCount == 1)
            #expect(try await runner.cancel(id: job.id))
            #expect(try await task.value == .interrupted)
            let saved = try #require(try await store.downloadJob(id: job.id))
            #expect(saved.state == .cancelled && saved.attempts == 0 && saved.logs == nil)
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(try await store.queue().isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func meteredTransitionRetainsPartialDataUntilResumeOrExplicitCancellation(resume: Bool) async throws {
        let body = Data((0..<100_003).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { request in
            if let header = request.headers["range"], let offset = Int(header.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes \(offset)-\(body.count - 1)/\(body.count)"], body: body.dropFirst(offset))
            }
            return .init(headers: ["ETag": "\"v1\"", "Content-Length": "\(body.count)"], body: body.prefix(8192), keepConnectionOpen: true)
        }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, _ in
            let monitor = allowedNetwork()
            let changed = Mutex(false)
            let clock = Clock()
            let runner = MediaDownloadWorker(store: store, clock: { clock.now }, wait: { clock.advance($0) },
                                             network: monitor, duration: { _ in nil })
            let task = Task {
                try await runner.run(id: job.id) { value in
                    if value.received > 0 && !changed.withLock({ let old = $0; $0 = true; return old }) {
                        monitor.update(.init(connected: true, metered: true, cellular: true))
                    }
                }
            }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if changed.withLock({ $0 }), try await store.downloadJob(id: job.id)?.state == .waiting { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let paused = try #require(try await store.downloadJob(id: job.id))
            try #require(changed.withLock { $0 })
            #expect(paused.state == .waiting && paused.attempts == 1 && paused.logs == nil && paused.retryAt == nil)
            #expect(try Data(contentsOf: job.destination) == body.prefix(8192))
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.episode(id: 1)?.userState.autoDownloadEnabled == true)
            #expect(clock.waits.isEmpty && server.requests.count == 1)
            if !resume {
                #expect(try await runner.cancel(id: job.id))
                #expect(try await task.value == .interrupted)
                #expect(try await store.downloadJob(id: job.id)?.state == .cancelled)
                #expect(try await store.downloadJob(id: job.id)?.logs == nil)
                #expect(try await store.queue().isEmpty)
                #expect(!FileManager.default.fileExists(atPath: job.destination.path))
                return
            }
            monitor.update(.init(connected: true, metered: false, cellular: false))
            #expect(try await task.value == .completed)
            #expect(try Data(contentsOf: job.destination) == body)
            #expect(server.requests.map { $0.headers["range"] } == [nil, "bytes=8192-"])
            let completed = try #require(try await store.downloadJob(id: job.id))
            #expect(completed.attempts == 2 && completed.logs == [.init(date: clock.now, attempt: 2, failure: nil, title: "Episode")])
            #expect(clock.waits.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func interruptedRepresentationSurvivesReopenAndCannotMixServerVersions(changed: Bool) async throws {
        let old = Data(repeating: 65, count: 100_003)
        let new = Data(repeating: 66, count: 100_003)
        let responseVersion = Mutex(1)
        let server = try await LoopbackHTTPServer.start { request in
            if responseVersion.withLock({ $0 }) == 1 {
                return .init(headers: ["ETag": "\"v1\"", "Content-Length": "100003"],
                             body: old.prefix(8192), keepConnectionOpen: true)
            }
            if !changed, request.headers["range"] == "bytes=8192-", request.headers["if-range"] == "\"v1\"" {
                return .init(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes 8192-100002/100003"],
                             body: old.dropFirst(8192))
            }
            return .init(headers: ["ETag": "\"v2\""], body: new)
        }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, url in
            let runner = worker(store, Clock())
            let delivered = Mutex(false)
            let task = Task { try await runner.run(id: job.id) { value in
                if value.received >= 8192 { delivered.withLock { $0 = true } }
            } }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !delivered.withLock({ $0 }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(delivered.withLock { $0 })
            task.cancel()
            #expect(try await task.value == .interrupted)
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            let saved = try #require(try await reopened.downloadJob(id: job.id))
            #expect(saved.state == .waiting && saved.attempts == 1 && saved.logs == nil)
            #expect(saved.representation == .init(resource: server.url, entityTag: "\"v1\"", total: 100_003))
            #expect(try Data(contentsOf: job.destination) == old.prefix(8192))
            responseVersion.withLock { $0 = 2 }
            #expect(try await worker(reopened, Clock()).run(id: job.id) == .completed)
            #expect(try Data(contentsOf: job.destination) == (changed ? new : old))
            let complete = try #require(try await reopened.downloadJob(id: job.id))
            #expect(complete.representation?.entityTag == (changed ? "\"v2\"" : "\"v1\""))
            #expect(complete.attempts == 2 && complete.logs?.count == 1 && complete.logs?.first?.failure == nil)
            #expect(try await reopened.episode(id: 1)?.userState.isDownloaded == true)
            #expect(server.requests.map { $0.headers["range"] } == [nil, "bytes=8192-"])
            #expect(server.requests.last?.headers["if-none-match"] == nil)
            try await reopened.close()
        }
    }

    @Test func durableRepresentationRejectsStaleAttemptsAndDecodesLegacyJobs() async throws {
        try await withJob(source: "https://example.test/audio") { store, job, url in
            let first = MediaDownloadRepresentation(resource: URL(string: job.source)!, entityTag: "\"v1\"", total: 6)
            let second = MediaDownloadRepresentation(resource: URL(string: job.source)!, entityTag: "\"v2\"", total: 6)
            let encoded = try JSONEncoder().encode(job)
            var legacy = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            legacy.removeValue(forKey: "representation")
            let decoded = try JSONDecoder().decode(LibraryDownloadJob.self, from: JSONSerialization.data(withJSONObject: legacy))
            #expect(decoded == job && decoded.representation == nil)
            #expect(try await store.acceptDownloadRepresentation(id: job.id, attempt: 0, representation: first) == false)
            _ = try await store.beginDownloadAttempt(id: job.id, now: Clock().now)
            #expect(try await store.acceptDownloadRepresentation(id: job.id, attempt: 1, representation: first))
            #expect(try await store.interruptDownload(id: job.id, attempt: 1, now: Clock().now))
            #expect(try await store.acceptDownloadRepresentation(id: job.id, attempt: 1, representation: second) == false)
            _ = try await store.beginDownloadAttempt(id: job.id, now: Clock().now)
            #expect(try await store.acceptDownloadRepresentation(id: job.id, attempt: 1, representation: second) == false)
            #expect(try await store.acceptDownloadRepresentation(id: job.id, attempt: 2, representation: second))
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.downloadJob(id: job.id)?.representation == second)
            #expect(try await store.acceptDownloadRepresentation(id: job.id, attempt: 2, representation: nil))
            #expect(try await reopened.downloadJob(id: job.id)?.representation == nil)
            try await reopened.close()
        }
    }


    @Test func identityDatabaseFailureLeavesNoMislabeledBytesAndRecoversAfterReopen() async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["ETag": "\"v2\""], body: Data("UVWXYZ".utf8))
        }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, url in
            let clock = Clock()
            _ = try await store.beginDownloadAttempt(id: job.id, now: clock.now)
            #expect(try await store.acceptDownloadRepresentation(id: job.id, attempt: 1,
                representation: .init(resource: server.url, entityTag: "\"v1\"", total: 6)))
            try Data("abc".utf8).write(to: job.destination)
            #expect(try await store.interruptDownload(id: job.id, attempt: 1, now: clock.now))
            let injector = try LibrarySQLite(url: url)
            try injector.execute("""
                CREATE TRIGGER reject_identity BEFORE UPDATE ON download_jobs
                WHEN json_extract(NEW.record, '$.representation.entityTag') != json_extract(OLD.record, '$.representation.entityTag')
                BEGIN SELECT RAISE(ABORT, 'fixture identity failure'); END
                """)
            let progress = Mutex<[MediaDownloadProgress]>([])
            await #expect(throws: FeedLibraryError.self) {
                try await worker(store, clock).run(id: job.id) { value in progress.withLock { $0.append(value) } }
            }
            #expect(progress.withLock { $0.isEmpty })
            #expect(try Data(contentsOf: job.destination).isEmpty)
            let failed = try #require(try await store.downloadJob(id: job.id))
            #expect(failed.state == .transferring && failed.representation?.entityTag == "\"v1\"" && failed.logs == nil)
            #expect(try await store.episode(id: 1)?.userState.isDownloaded == false)
            try injector.execute("DROP TRIGGER reject_identity")
            try injector.close()
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            let resumed = worker(reopened, clock)
            try await resumed.recoverStoppedForegroundWork()
            #expect(try await resumed.run(id: job.id) == .completed)
            #expect(try Data(contentsOf: job.destination) == Data("UVWXYZ".utf8))
            #expect(server.requests.map { $0.headers["range"] } == ["bytes=3-", nil])
            #expect(try await reopened.downloadJob(id: job.id)?.representation?.entityTag == "\"v2\"")
            try await reopened.close()
        }
    }

    @Test func unsolicitedNotModifiedCannotStrandAnIncompleteJobAsInterrupted() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(status: 304, body: Data()) }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, _ in
            try Data("partial".utf8).write(to: job.destination)
            #expect(try await worker(store, Clock()).run(id: job.id) == .failed(.http(304)))
            let saved = try #require(try await store.downloadJob(id: job.id))
            #expect(saved.state == .failed && saved.attempts == 3)
            #expect(saved.logs?.map(\.failure) == [.http(304), .http(304), .http(304)])
            #expect(try await store.episode(id: 1)?.userState.isDownloaded == false)
        }
    }


    @Test(arguments: ["missing", "W/\"v2\"", "unquoted"])
    func unvalidatedReplacementClearsOldIdentityBeforeBytesAndRestartsSafely(tag: String) async throws {
        let body = Data(repeating: 66, count: 100_003)
        let finish = Mutex(false)
        let server = try await LoopbackHTTPServer.start { _ in
            if finish.withLock({ $0 }) { return .init(body: body) }
            var headers = ["Content-Length": "100003"]
            if tag != "missing" { headers["ETag"] = tag }
            return .init(headers: headers, body: body.prefix(8192), keepConnectionOpen: true)
        }
        defer { server.stop() }
        try await withJob(source: server.url.absoluteString) { store, job, url in
            let clock = Clock()
            _ = try await store.beginDownloadAttempt(id: job.id, now: clock.now)
            #expect(try await store.acceptDownloadRepresentation(id: job.id, attempt: 1,
                representation: .init(resource: server.url, entityTag: "\"v1\"", total: 100_003)))
            try Data("abc".utf8).write(to: job.destination)
            #expect(try await store.interruptDownload(id: job.id, attempt: 1, now: clock.now))
            let received = Mutex(false)
            let task = Task { try await worker(store, clock).run(id: job.id) { value in
                if value.received >= 8192 { received.withLock { $0 = true } }
            } }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !received.withLock({ $0 }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(received.withLock { $0 })
            #expect(try await store.downloadJob(id: job.id)?.representation == nil)
            task.cancel()
            #expect(try await task.value == .interrupted)
            #expect(try Data(contentsOf: job.destination) == body.prefix(8192))
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            finish.withLock { $0 = true }
            #expect(try await worker(reopened, clock).run(id: job.id) == .completed)
            #expect(try Data(contentsOf: job.destination) == body)
            #expect(server.requests.map { $0.headers["range"] } == ["bytes=3-", nil])
            #expect(try await reopened.downloadJob(id: job.id)?.representation == nil)
            try await reopened.close()
        }
    }


    /// The transcript sidecar runs under its download's own constraint, with the budget of its network; a refusal,
    /// an interruption or an oversized transcript never fails the download. Real requests at a loopback fixture.
    private func sidecarServer(transcript: Data, hold: Bool = false, onClientDisconnect: (@Sendable () -> Void)? = nil) async throws -> LoopbackHTTPServer {
        let media = Data(repeating: 93, count: 1024)
        return try await LoopbackHTTPServer.start(onClientDisconnect: onClientDisconnect) { request in
            if request.path.contains("transcript") { return hold ? nil : .init(body: transcript) }
            return .init(body: media)
        }
    }
    private static let sidecarText = Data("{\"segments\":[{\"startTime\":0,\"endTime\":5,\"body\":\"Offline text\"}]}".utf8)
    private func transcriptRequests(_ server: LoopbackHTTPServer) -> Int { server.requests.filter { $0.path.contains("transcript") }.count }

    /// A Wi-Fi-only download whose network turns to cellular after the media arrived: no transcript request, and the
    /// download completes without a sidecar. Unchanged network: one request and a sidecar (control).
    @Test(arguments: [true, false]) func wifiOnlyJobDoesNotFetchSidecarAfterMovingToCellular(moves: Bool) async throws {
        let server = try await sidecarServer(transcript: Self.sidecarText)
        defer { server.stop() }
        let descriptor = FeedTranscript(format: .json, url: server.url.appendingPathComponent("transcript").absoluteString)
        try await withJob(source: server.url.absoluteString, transcript: descriptor) { store, job, _ in
            let network = allowedNetwork()
            let loader = TranscriptLoader(transport: URLSessionFeedTransport(), cache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0), userAgent: "test")
            let runner = MediaDownloadWorker(store: store, network: network, transcriptLoader: loader, duration: { _ in 30_000 },
                artwork: { _ in false }, beforeSidecar: { if moves { network.update(.init(connected: true, metered: true, cellular: true)) } })
            let outcome = try await runner.run(id: job.id)
            #expect(outcome == .completed)
            #expect(transcriptRequests(server) == (moves ? 0 : 1))
            #expect(FileManager.default.fileExists(atPath: job.destination.path + ".transcript") == !moves)
        }
    }

    /// The network turns metered while the transcript is arriving: its request is cancelled (the server sees the
    /// client leave) and the download still completes, without a sidecar.
    @Test func meteredNetworkDuringTheSidecarCancelsItAndTheDownloadCompletes() async throws {
        let disconnected = Mutex(false)
        let server = try await sidecarServer(transcript: Self.sidecarText, hold: true, onClientDisconnect: { disconnected.withLock { $0 = true } })
        defer { server.stop() }
        let descriptor = FeedTranscript(format: .json, url: server.url.appendingPathComponent("transcript").absoluteString)
        try await withJob(source: server.url.absoluteString, transcript: descriptor) { store, job, _ in
            let network = allowedNetwork()
            let loader = TranscriptLoader(transport: URLSessionFeedTransport(), cache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0), userAgent: "test")
            let runner = MediaDownloadWorker(store: store, network: network, transcriptLoader: loader, duration: { _ in 30_000 }, artwork: { _ in false })
            let running = Task { try await runner.run(id: job.id) }
            let end = ContinuousClock.now + .seconds(5)
            while transcriptRequests(server) == 0, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
            try #require(transcriptRequests(server) == 1)
            network.update(.init(connected: true, metered: true, cellular: true))
            #expect(try await running.value == .completed)
            while !disconnected.withLock({ $0 }), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
            #expect(disconnected.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: job.destination.path + ".transcript"))
            #expect(try await store.episode(id: job.episodeID)?.userState.isDownloaded == true)
        }
    }

    /// A download allowed on mobile data fetches its transcript on cellular, on the restricted budget: a small one is
    /// stored; one over 5 MiB is not, and the download completes either way.
    @Test(arguments: [false, true]) func connectedJobOnCellularFetchesItsSidecarWithinTheRestrictedBudget(oversized: Bool) async throws {
        let text = oversized ? Data("{\"segments\":[{\"startTime\":0,\"endTime\":5,\"body\":\"\(String(repeating: " ", count: 6 * 1024 * 1024))\"}]}".utf8) : Self.sidecarText
        let server = try await sidecarServer(transcript: text)
        defer { server.stop() }
        let descriptor = FeedTranscript(format: .json, url: server.url.appendingPathComponent("transcript").absoluteString)
        try await withJob(source: server.url.absoluteString, transcript: descriptor, networkConstraint: .connected) { store, job, _ in
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: true, cellular: true))
            let loader = TranscriptLoader(transport: URLSessionFeedTransport(), cache: URLCache(memoryCapacity: 20_000_000, diskCapacity: 0), userAgent: "test")
            let runner = MediaDownloadWorker(store: store, network: network, transcriptLoader: loader, duration: { _ in 30_000 }, artwork: { _ in false })
            let outcome = try await runner.run(id: job.id)
            #expect(outcome == .completed)
            #expect(transcriptRequests(server) == 1)
            #expect(FileManager.default.fileExists(atPath: job.destination.path + ".transcript") == !oversized)
        }
    }
}

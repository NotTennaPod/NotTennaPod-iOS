import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SynchronizationCoordinatorTests {
    private func fixture(_ body: (FeedLibraryStore, URL, SyncOwnerClock) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncOwner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = SyncOwnerClock(), file = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: file, synchronizationClock: { clock.now })
        do { try await body(store, file, clock); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func until(_ body: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !body(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(try await body())
    }
    private func owner(_ store: FeedLibraryStore, _ clock: SyncOwnerClock,
                       announce: @escaping @MainActor @Sendable (SynchronizationRequest, UUID) async throws -> Void = { _, _ in },
                       execute: @escaping @Sendable (SynchronizationRequest) async throws -> SynchronizationWorker.Outcome) -> SynchronizationCoordinator {
        .init(store: store, clock: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) }, announceStarted: announce, execute: execute)
    }
    private nonisolated func finish(_ store: FeedLibraryStore, _ request: SynchronizationRequest, _ clock: SyncOwnerClock) async throws {
        let state = try await store.beginSynchronization(request, now: clock.now)
        try await store.finishSynchronization(request, epoch: state.epoch, successful: state.accountID == nil ? nil : true, now: clock.now)
    }

    @Test func manualAndAutomaticAdmissionPublishBeforeDelayAndWorkerWithoutRepeatingWakeHints() async throws {
        try await fixture { store, _, clock in
            try await store.selectSynchronizationAccount(UUID())
            let announced = Mutex<[UUID]>([]), executed = Mutex<[UUID]>([])
            let owner = owner(store, clock, announce: { request, epoch in
                let saved = try await store.synchronizationState()
                #expect(saved.epoch == epoch)
                announced.withLock { $0.append(request.id) }
            }) { request in
                #expect(announced.withLock { $0 }.contains(request.id))
                executed.withLock { $0.append(request.id) }
                try await finish(store, request, clock); return .success
            }
            defer { owner.suspend() }
            owner.resume()
            let manual = try #require(try await owner.request().value)
            try await until { announced.withLock { $0 } == [manual.id] }
            #expect(executed.withLock { $0 }.isEmpty && manual.announcesStart == true)
            try await store.setSynchronizationMobileAllowed(true)
            owner.resume()
            clock.advance(by: 20)
            try await until { owner.state == .idle }
            #expect(announced.withLock { $0 } == [manual.id])
            let source = "https://example.test/automatic"
            _ = try await store.insert(.init(feed: .init(format: .rss, title: "Automatic"), source: source,
                responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
            let automatic = try #require(try await store.synchronizationState().request)
            try await until { announced.withLock { $0 } == [manual.id, automatic.id] }
            #expect(automatic.announcesStart == true && executed.withLock { $0 } == [manual.id])
            clock.advance(by: 20)
            try await until { owner.state == .idle }
            #expect(executed.withLock { $0 } == [manual.id, automatic.id])
        }
    }

    @Test func admissionDuringActiveServiceStaysSilentAfterServiceRetiresIncludingFullSync() async throws {
        try await fixture { store, _, clock in
            try await store.selectSynchronizationAccount(UUID())
            let source = "https://example.test/active"
            let initial = try #require(try await store.requestSynchronization(immediately: true, now: clock.now))
            let running = try await store.beginSynchronization(initial, now: clock.now)
            _ = try await store.insert(.init(feed: .init(format: .rss, title: "During service"), source: source,
                responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
            let automatic = try #require(try await store.synchronizationState().request)
            #expect(automatic.announcesStart == false)
            try await store.finishSynchronization(initial, epoch: running.epoch, successful: true, now: clock.now)
            let notices = Mutex(0), calls = Mutex(0)
            let owner = owner(store, clock, announce: { _, _ in notices.withLock { $0 += 1 } }) { request in
                calls.withLock { $0 += 1 }; try await finish(store, request, clock); return .success
            }
            defer { owner.suspend() }
            owner.resume()
            try await until { owner.state == .waiting(automatic) }
            clock.advance(by: 120)
            try await until { owner.state == .idle && calls.withLock { $0 } == 1 }
            #expect(notices.withLock { $0 } == 0)
            owner.suspend()
            let active = try #require(try await store.requestSynchronization(immediately: true, now: clock.now))
            _ = try await store.beginSynchronization(active, now: clock.now)
            let full = try #require(try await owner.request(full: true).value)
            #expect(full.announcesStart == false)
            #expect(try await store.synchronizationState().lastAttempt == nil)
            await store.releaseSynchronizationExecution(active)
            owner.resume()
            try await until { owner.state == .idle && calls.withLock { $0 } == 2 }
            #expect(notices.withLock { $0 } == 0)
        }
    }

    @Test func schedulingDeliveryFailureRetainsWorkAndResumeRetriesBeforeExecution() async throws {
        try await fixture { store, _, clock in
            try await store.selectSynchronizationAccount(UUID())
            var deliveries = 0
            let executed = Mutex(0)
            let owner = owner(store, clock, announce: { _, _ in
                deliveries += 1
                if deliveries == 1 { throw FeedLibraryError.invalidMutation }
            }) { request in
                executed.withLock { $0 += 1 }; try await finish(store, request, clock); return .success
            }
            defer { owner.suspend() }
            owner.resume()
            let request = try #require(try await owner.request(immediately: true).value)
            try await until { if case .failed = owner.state { true } else { false } }
            #expect(try await store.synchronizationState().request == request)
            #expect(executed.withLock { $0 } == 0 && deliveries == 1)
            owner.resume()
            try await until { owner.state == .idle && executed.withLock { $0 } == 1 }
            #expect(deliveries == 2)
        }
    }

    @Test func networkWaitDoesNotSuppressNewSchedulingStatusAndReplacementStillRetiresOldWork() async throws {
        try await fixture { store, _, clock in
            try await store.selectSynchronizationAccount(UUID())
            let gate = SyncOwnerGate(), calls = Mutex<[UUID]>([])
            var announcements: [UUID] = []
            let owner = owner(store, clock, announce: { request, _ in announcements.append(request.id) }) { request in
                let count = calls.withLock { $0.append(request.id); return $0.count }
                // The real worker also waits for network before beginSynchronization.
                if count == 1 { try await gate.wait() }
                try await finish(store, request, clock); return .success
            }
            defer { owner.suspend(); gate.open() }
            owner.resume()
            let first = try #require(try await owner.request(immediately: true).value)
            try await until { gate.entries == 1 }
            let replacement = try #require(try await owner.request().value)
            #expect(replacement.announcesStart == true && replacement.notBefore == clock.now.addingTimeInterval(20))
            try await until { announcements == [first.id, replacement.id] }
            #expect(calls.withLock { $0 } == [first.id])
            clock.advance(by: 20)
            try await until { owner.state == .idle && calls.withLock { $0 } == [first.id, replacement.id] }
            #expect(gate.cancellations == 1)
            #expect(try await store.synchronizationState().request == nil)
        }
    }

    @Test func legacyRequestDecodesWithoutManufacturingAStartedEvent() async throws {
        try await fixture { store, _, clock in
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SynchronizationRequest(notBefore: clock.now, allowMobile: false))) as? [String: Any])
            object.removeValue(forKey: "announcesStart")
            let request = try JSONDecoder().decode(SynchronizationRequest.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(request.announcesStart == nil)
            try await store.selectSynchronizationAccount(UUID())
            var state = try await store.synchronizationState(); state.request = request
            try await store.saveSynchronizationState(state)
            let calls = Mutex(0)
            let owner = owner(store, clock, announce: { _, _ in Issue.record("Old saved work does not replay source admission") }) { request in
                calls.withLock { $0 += 1 }; try await finish(store, request, clock); return .success
            }
            defer { owner.suspend() }
            owner.resume()
            try await until { owner.state == .idle && calls.withLock { $0 } == 1 }
        }
    }

    @Test func acceptanceWhileSuspendedSurvivesReopenAndDoesNotRestoreExpiredDelay() async throws {
        try await fixture { store, file, clock in
            let calls = Mutex<[UUID]>([])
            let first = owner(store, clock) { _ in Issue.record("Suspended owner ran"); return .success }
            let request = try #require(try await first.request().value)
            #expect(first.state == .suspended)
            clock.advance(by: 100)
            let reopened = try FeedLibraryStore(url: file, synchronizationClock: { clock.now })
            let recovered = owner(reopened, clock) { request in
                calls.withLock { $0.append(request.id) }; try await finish(reopened, request, clock); return .noProvider
            }
            defer { first.suspend(); recovered.suspend() }
            recovered.resume()
            try await until { calls.withLock { $0 }.count == 1 && recovered.state == .idle }
            #expect(calls.withLock { $0 } == [request.id])
            #expect(try await reopened.synchronizationState().request == nil)
            try await reopened.close()
        }
    }

    @Test func activePassFinishesWhileNewDelayedRequestRemainsScheduled() async throws {
        try await fixture { store, _, clock in
            try await store.selectSynchronizationAccount(UUID())
            let gate = SyncOwnerGate(), calls = Mutex<[UUID]>([])
            let owner = owner(store, clock) { request in
                let index = calls.withLock { $0.append(request.id); return $0.count }
                let state = try await store.beginSynchronization(request, now: clock.now)
                do {
                    if index == 1 { try await gate.wait() }
                    try await store.finishSynchronization(request, epoch: state.epoch, successful: true, now: clock.now)
                    return .success
                } catch { await store.releaseSynchronizationExecution(request); throw error }
            }
            defer { owner.suspend(); gate.open() }
            owner.resume()
            let first = try #require(try await owner.request(immediately: true).value)
            try await until { gate.entries == 1 }
            let next = try #require(try await owner.request().value)
            #expect(next.notBefore == clock.now.addingTimeInterval(120))
            gate.open()
            try await until { owner.state == .waiting(next) }
            #expect(calls.withLock { $0 } == [first.id])
            clock.advance(by: 120)
            try await until { owner.state == .idle }
            #expect(calls.withLock { $0 } == [first.id, next.id])
        }
    }

    @Test func immediateReplacementWaitsForCancelledWorkerRetirementAndLatestWins() async throws {
        try await fixture { store, _, clock in
            let gate = SyncOwnerGate(ignoreCancellation: true), calls = Mutex<[UUID]>([])
            let owner = owner(store, clock) { request in
                let count = calls.withLock { $0.append(request.id); return $0.count }
                if count == 1 { try await gate.wait(); try Task.checkCancellation() }
                try await finish(store, request, clock); return .noProvider
            }
            defer { owner.suspend(); gate.open() }
            owner.resume()
            let first = try #require(try await owner.request(immediately: true).value)
            try await until { gate.entries == 1 }
            _ = try await owner.request(immediately: true).value
            try await until { gate.cancellations == 1 }
            let latest = try #require(try await owner.request(immediately: true).value)
            #expect(calls.withLock { $0 } == [first.id])
            gate.open()
            try await until { owner.state == .idle }
            #expect(calls.withLock { $0 } == [first.id, latest.id])
        }
    }

    @Test func retryBackoffAutomaticallyRunsSavedNextAttemptWithoutNewTrigger() async throws {
        try await fixture { store, _, clock in
            try await store.selectSynchronizationAccount(UUID())
            let attempts = Mutex<[Int]>([])
            var announcements = 0
            let owner = owner(store, clock, announce: { _, _ in announcements += 1 }) { request in
                attempts.withLock { $0.append(request.attempts) }
                let state = try await store.beginSynchronization(request, now: clock.now)
                try await store.finishSynchronization(request, epoch: state.epoch, successful: request.attempts == 1,
                    retry: request.attempts == 0, now: clock.now)
                return request.attempts == 0 ? .retry : .success
            }
            defer { owner.suspend() }
            owner.resume()
            let first = try #require(try await owner.request(immediately: true).value)
            try await until { if case .waiting(let next) = owner.state { next.attempts == 1 } else { false } }
            let next = try #require(try await store.synchronizationState().request)
            #expect(next.id == first.id && next.notBefore == clock.now.addingTimeInterval(600))
            #expect(next.announcesStart == true && announcements == 1)
            clock.advance(by: 599)
            #expect(attempts.withLock { $0 } == [0])
            clock.advance(by: 1)
            try await until { owner.state == .idle }
            #expect(attempts.withLock { $0 } == [0, 1])
            #expect(announcements == 1, "Backoff retry must retain its error/phase, not announce new scheduling")
        }
    }

    @Test func suspendRetainsWorkAndResumeWaitsForOldCleanup() async throws {
        try await fixture { store, _, clock in
            let gate = SyncOwnerGate(ignoreCancellation: true), calls = Mutex(0)
            let owner = owner(store, clock) { request in
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 1 { try await gate.wait(); try Task.checkCancellation() }
                try await finish(store, request, clock); return .noProvider
            }
            defer { owner.suspend(); gate.open() }
            owner.resume()
            let request = try #require(try await owner.request(immediately: true).value)
            try await until { gate.entries == 1 }
            owner.suspend()
            #expect(owner.state == .suspended)
            #expect(try await store.synchronizationState().request == request)
            owner.resume()
            try await until { gate.cancellations == 1 }
            #expect(calls.withLock { $0 } == 1)
            gate.open()
            try await until { owner.state == .idle }
            #expect(calls.withLock { $0 } == 2)
        }
    }

    @Test func accountChangeCancelsOldEpochEvenWithoutSuccessorAndFullSyncReplacesIt() async throws {
        try await fixture { store, _, clock in
            try await store.selectSynchronizationAccount(UUID())
            let gate = SyncOwnerGate(), calls = Mutex(0)
            let owner = owner(store, clock) { request in
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 1 { try await gate.wait() }
                try await finish(store, request, clock); return .success
            }
            defer { owner.suspend(); gate.open() }
            owner.resume()
            _ = try await owner.request(immediately: true).value
            try await until { gate.entries == 1 }
            try await store.selectSynchronizationAccount(nil)
            try await until { gate.cancellations == 1 && owner.state == .idle }
            #expect(try await store.synchronizationState().lastAttempt == nil)
            let full = try #require(try await owner.request(full: true).value)
            #expect(full.notBefore == clock.now)
            try await until { owner.state == .idle && calls.withLock { $0 } == 2 }
        }
    }

    @Test func localFailureDoesNotHotLoopAndExplicitResumeRetriesSavedWork() async throws {
        try await fixture { store, _, clock in
            let calls = Mutex(0)
            let owner = owner(store, clock) { request in
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 1 { throw FeedLibraryError.invalidMutation }
                try await finish(store, request, clock); return .success
            }
            defer { owner.suspend() }
            owner.resume()
            let request = try #require(try await owner.request(immediately: true).value)
            try await until { if case .failed = owner.state { true } else { false } }
            try await store.setSynchronizationMobileAllowed(true) // Wake hint, same request.
            #expect(try await store.synchronizationState().request == request)
            #expect(calls.withLock { $0 } == 1)
            owner.resume()
            try await until { owner.state == .idle }
            #expect(calls.withLock { $0 } == 2)
        }
    }

    @Test func libraryEffectsWakeOwnerAndFailedTransactionNeverExecutesRolledBackRequest() async throws {
        try await fixture { store, file, clock in
            try await store.selectSynchronizationAccount(UUID())
            let calls = Mutex(0)
            let owner = owner(store, clock) { request in
                calls.withLock { $0 += 1 }; try await finish(store, request, clock); return .success
            }
            defer { owner.suspend() }
            owner.resume()
            try await until { owner.state == .idle }
            let source = "https://example.test/feed"
            let feed = FetchedFeed(feed: .init(format: .rss, title: "Podcast"), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
            let db = try LibrarySQLite(url: file)
            defer { try? db.close() }
            try db.execute("CREATE TRIGGER reject_state BEFORE INSERT ON synchronization_state BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: FeedLibraryError.self) { try await store.insert(feed) }
            #expect(try await store.feeds().isEmpty)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try await store.synchronizationState().request == nil)
            try db.execute("DROP TRIGGER reject_state")
            _ = try await store.insert(feed)
            let request = try #require(try await store.synchronizationState().request)
            try await until { owner.state == .waiting(request) }
            #expect(request.notBefore == clock.now.addingTimeInterval(20))
            clock.advance(by: 20)
            try await until { owner.state == .idle }
            #expect(calls.withLock { $0 } == 1)
        }
    }

    @Test func realHTTPWorkerPreservesChangeQueuedDuringUploadAndRunsDelayedFollowup() async throws {
        try await fixture { store, _, clock in
            let source = "https://example.test/feed"
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Podcast", episodes: (1...2).map {
                .init(identifier: "guid-\($0)", title: "Episode \($0)", media: .init(url: "https://media.test/\($0).mp3", size: 100, durationMilliseconds: 100_000))
            }), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
            try await store.selectSynchronizationAccount(UUID())
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true, now: clock.now)
            let server = try await LoopbackHTTPServer.start { request in
                if request.method == "POST" { return .init(body: Data("{}".utf8)) }
                let json = request.path.contains("/subscriptions") ? #"{"add":[],"remove":[],"timestamp":10}"# : #"{"actions":[],"timestamp":20}"#
                return .init(body: Data(json.utf8))
            }
            defer { server.stop() }
            let client = try SynchronizationHTTPClient(backend: .nextcloud, host: server.url.deletingLastPathComponent().absoluteString,
                username: "fixture", password: "fixture", clock: { clock.now })
            let provider = OwnerHTTPProvider(client: client) {
                try await store.markEpisodePlayed(episodeID: feed.episodes[1].id, played: true, now: clock.now)
            }
            let deletion = FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: false, cellular: false))
            let effects = OwnerWorkerEffects()
            let worker = SynchronizationWorker(store: store, subscriptions: .init(store: store, deletion: deletion, redirect: { _ in nil }),
                provider: { _ in provider }, waitForRefresh: {}, requestRefresh: { Issue.record("Known feed must not request refresh") },
                effects: effects, network: network, clock: { clock.now })
            let owner = owner(store, clock) { try await worker.run($0) }
            defer { owner.suspend() }
            owner.resume()
            _ = try await owner.request(immediately: true).value
            try await until { effects.successes == 1 && { if case .waiting = owner.state { true } else { false } }() }
            let next = try #require(try await store.synchronizationState().request)
            #expect(next.notBefore == clock.now.addingTimeInterval(120))
            let queued = try await store.synchronizationQueue()
            #expect(queued.count == 1)
            clock.advance(by: 120)
            try await until { owner.state == .idle && effects.successes == 2 }
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try await store.synchronizationState().request == nil)
            let uploads = server.requests.filter { $0.method == "POST" && $0.path.contains("episode_action") }
            #expect(uploads.count == 2)
            let second = try #require(JSONSerialization.jsonObject(with: uploads[1].body) as? [[String: Any]])
            #expect(second.count == 1 && second[0]["guid"] as? String == feed.episodes[1].details.identifier)
        }
    }

    @Test func strictRecentGateAndSuspendedInvocationOrderArePreserved() async throws {
        try await fixture { store, _, clock in
            try await store.selectSynchronizationAccount(UUID())
            let initial = try #require(try await store.requestSynchronization(immediately: true, now: clock.now))
            try await finish(store, initial, clock)
            let owner = owner(store, clock) { request in try await finish(store, request, clock); return .success }
            defer { owner.suspend() }
            clock.advance(by: 600)
            #expect(try await owner.request(ifNotRecent: true).value == nil)
            clock.advance(by: 1)
            #expect(try await owner.request(ifNotRecent: true).value != nil)
            let accepted = (0..<20).map { _ in owner.request(immediately: true) }
            var final: SynchronizationRequest?
            for task in accepted { final = try await task.value }
            #expect(try await store.synchronizationState().request == final)
            owner.resume()
            try await until { owner.state == .idle }
            #expect(try await store.synchronizationState().request == nil)
        }
    }

    @Test func newerRequestRunsEvenIfPreviousExecutionFailsLocally() async throws {
        try await fixture { store, _, clock in
            let gate = SyncOwnerGate(), calls = Mutex(0)
            let owner = owner(store, clock) { request in
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 1 { try await gate.wait(); throw FeedLibraryError.invalidMutation }
                try await finish(store, request, clock); return .success
            }
            defer { owner.suspend(); gate.open() }
            owner.resume()
            _ = try await owner.request(immediately: true).value
            try await until { gate.entries == 1 }
            let newer = try #require(try await owner.request().value)
            gate.open()
            try await until { owner.state == .waiting(newer) }
            clock.advance(by: 20)
            try await until { owner.state == .idle }
            #expect(calls.withLock { $0 } == 2)
        }
    }

    /// A change queued before or while the app is in the background reaches the provider within the
    /// granted background time instead of after the 20 s debounce; back in the foreground the source
    /// delay applies again, and a provider retry keeps its backoff.
    @Test func backgroundStartsPendingFirstAttemptAtOnceAndForegroundRestoresDebounce() async throws {
        try await fixture { store, _, clock in
            try await store.selectSynchronizationAccount(UUID())
            let executed = Mutex<[UUID]>([])
            let owner = owner(store, clock) { request in
                executed.withLock { $0.append(request.id) }
                try await finish(store, request, clock); return .success
            }
            defer { owner.suspend() }
            owner.resume()
            let pending = try #require(try await owner.request().value)
            try await until { owner.state == .waiting(pending) }
            owner.setExpedited(true)
            try await until { executed.withLock { $0 } == [pending.id] }
            try await until { owner.state == .idle }
            let queuedInBackground = try #require(try await owner.request().value)
            try await until { executed.withLock { $0 } == [pending.id, queuedInBackground.id] }
            owner.setExpedited(false)
            try await until { owner.state == .idle }
            let foreground = try #require(try await owner.request().value)
            try await until { owner.state == .waiting(foreground) }
            #expect(executed.withLock { $0 }.count == 2, "the 20 s delay applies in the foreground")
            clock.advance(by: 20)
            try await until { executed.withLock { $0 }.count == 3 }
        }
    }

    @Test func backgroundKeepsProviderRetryBackoff() async throws {
        try await fixture { store, _, clock in
            try await store.selectSynchronizationAccount(UUID())
            let calls = Mutex(0)
            let owner = owner(store, clock) { request in
                calls.withLock { $0 += 1 }
                let state = try await store.beginSynchronization(request, now: clock.now)
                try await store.finishSynchronization(request, epoch: state.epoch, successful: false, retry: true, now: clock.now)
                return .retry
            }
            defer { owner.suspend() }
            owner.resume()
            _ = try await owner.request(immediately: true).value
            try await until { calls.withLock { $0 } == 1 }
            try await until { if case .waiting(let retry) = owner.state { retry.attempts == 1 } else { false } }
            owner.setExpedited(true)
            await Task.yield()
            #expect(calls.withLock { $0 } == 1, "a retry waits for its 10-minute backoff")
            clock.advance(by: 600)
            try await until { calls.withLock { $0 } == 2 }
        }
    }
}

private final class SyncOwnerClock: Sendable {
    private struct State {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var waiters: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
    }
    private let storage = Mutex(State())
    var now: Date { storage.withLock { $0.now } }
    func sleep(until date: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = storage.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.now >= date { return .success(()) }
                    state.waiters[id] = (date, continuation); return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            self.storage.withLock { $0.waiters.removeValue(forKey: id)?.1 }?.resume(throwing: CancellationError())
        }
    }
    func advance(by seconds: TimeInterval) {
        let ready = storage.withLock { state in
            state.now = state.now.addingTimeInterval(seconds)
            let ready = state.waiters.filter { $0.value.0 <= state.now }
            for id in ready.keys { state.waiters[id] = nil }
            return ready.map { $0.value.1 }
        }
        for continuation in ready { continuation.resume() }
    }
}

private final class SyncOwnerGate: Sendable {
    private struct State {
        var opened = false, entries = 0, cancellations = 0
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }
    private let storage = Mutex(State())
    private let ignoreCancellation: Bool
    init(ignoreCancellation: Bool = false) { self.ignoreCancellation = ignoreCancellation }
    var entries: Int { storage.withLock { $0.entries } }
    var cancellations: Int { storage.withLock { $0.cancellations } }
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = storage.withLock { state in
                    state.entries += 1
                    if Task.isCancelled && !ignoreCancellation { return .failure(CancellationError()) }
                    if state.opened { return .success(()) }
                    state.waiters[id] = continuation; return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = self.storage.withLock { state in
                state.cancellations += 1
                return self.ignoreCancellation ? nil : state.waiters.removeValue(forKey: id)
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
    func open() {
        let waiters = storage.withLock { state in
            state.opened = true
            let values = Array(state.waiters.values); state.waiters.removeAll(); return values
        }
        for waiter in waiters { waiter.resume() }
    }
}

private actor OwnerHTTPProvider: SynchronizationProvider {
    let client: SynchronizationHTTPClient
    let duringFirstUpload: @Sendable () async throws -> Void
    var uploaded = false
    init(client: SynchronizationHTTPClient, duringFirstUpload: @escaping @Sendable () async throws -> Void) {
        self.client = client; self.duringFirstUpload = duringFirstUpload
    }
    func login() async throws { try await client.login() }
    func logout() async throws { try await client.logout() }
    func subscriptionChanges(since: Int64) async throws -> SynchronizationSubscriptionChanges { try await client.subscriptionChanges(since: since) }
    func uploadSubscriptions(added: [String], removed: [String]) async throws -> SynchronizationUploadResult { try await client.uploadSubscriptions(added: added, removed: removed) }
    func episodeChanges(since: Int64) async throws -> SynchronizationEpisodeChanges { try await client.episodeChanges(since: since) }
    func uploadEpisodeActions(_ actions: [SynchronizationEpisodeAction]) async throws -> SynchronizationUploadResult? {
        let receipt = try await client.uploadEpisodeActions(actions)
        if !uploaded { uploaded = true; try await duringFirstUpload() }
        return receipt
    }
}

private final class OwnerWorkerEffects: SynchronizationWorkerEffects {
    private let events = Mutex<[SynchronizationWorker.Event]>([])
    var successes: Int { events.withLock { $0.filter { $0 == .status(.success) }.count } }
    func handle(_ event: SynchronizationWorker.Event, epoch: UUID) async throws { events.withLock { $0.append(event) } }
}

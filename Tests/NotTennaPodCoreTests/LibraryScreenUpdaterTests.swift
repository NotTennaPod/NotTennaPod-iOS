import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The screen updater with a fake reader whose snapshot sequence and timing the test controls: out-of-order and racing
/// reads, sets delivered during a read, the open's baseline, `settle(receipt:)`, sync pacing against local sets, the
/// background union and the catch-up cap, another library's sets, read failures and teardown.
@MainActor @Suite(.serialized) struct LibraryScreenUpdaterTests {
    /// The fake library: the sequence its next read sees, a gate that holds reads, and what was read and applied.
    final class Fake: @unchecked Sendable {
        struct State {
            var sequence: Int64 = 0
            var held = false
            var waiting: [CheckedContinuation<Void, Never>] = []
            var requests: [LibraryMirrorRequest] = []
            var failures = 0
            /// Sequences the next reads see, before the current one (a snapshot taken before a later commit).
            var scripted: [Int64] = []
            var starts: [ContinuousClock.Instant] = []
        }
        let state = Mutex(State())
        var applied: [Int64] = []
        var reopened = 0
        var errors = 0

        func read(_ request: LibraryMirrorRequest) async throws -> LibraryMirrorRead {
            let hold = state.withLock { state -> Bool in state.requests.append(request); state.starts.append(.now); return state.held }
            if hold { await withCheckedContinuation { continuation in state.withLock { $0.waiting.append(continuation) } } }
            if state.withLock({ state in
                guard state.failures > 0 else { return false }
                state.failures -= 1; return true
            }) { throw FeedLibraryError.closed }
            var result = LibraryMirrorRead()
            result.sequence = state.withLock { $0.scripted.isEmpty ? $0.sequence : $0.scripted.removeFirst() }
            return result
        }
        func release() {
            let waiting = state.withLock { state in defer { state.waiting = []; state.held = false }; return state.waiting }
            for continuation in waiting { continuation.resume() }
        }
        var reads: Int { state.withLock { $0.requests.count } }
        var requests: [LibraryMirrorRequest] { state.withLock { $0.requests } }
        func commit(_ sequence: Int64) { state.withLock { $0.sequence = sequence } }
    }

    let identity = LibraryChangeHub.Identity(library: "library", incarnation: UUID())
#if DEBUG
    /// The updater's mutations (`LibraryScreenMutationTests`).
    var faults: Set<LibraryScreenUpdater.Fault> = []
#endif

    func make(_ fake: Fake, active: @escaping () -> Bool = { true }, pacing: Duration = .milliseconds(300)) -> (LibraryChangeHub, LibraryScreenUpdater) {
        let hub = LibraryChangeHub(identity: identity, baseline: 0)
        var configuration = LibraryScreenUpdater.Configuration()
        configuration.syncPacing = pacing
        configuration.errorRetry = .milliseconds(20)
        configuration.raceRetry = .milliseconds(5)
        let updater = LibraryScreenUpdater(subscription: hub.subscribe(), configuration: configuration)
        updater.request = { sets in
            var request = LibraryMirrorRequest()
            for set in sets { request.episodes.formUnion(set.episodes.keys) }
            return request.episodes.count > 100 ? nil : request
        }
        updater.read = { try await fake.read($0) }
        updater.apply = { [weak updater] read in fake.applied.append(read.sequence); _ = updater }
        updater.reopen = { fake.reopened += 1 }
        updater.failed = { _ in fake.errors += 1 }
        updater.isActive = active
#if DEBUG
        updater.faults = faults
#endif
        return (hub, updater)
    }

    func set(_ sequence: Int64, origin: LibraryChangeOrigin = .local, episodes: [Int64] = [1], identity: LibraryChangeHub.Identity? = nil) -> LibraryChangeSet {
        var set = LibraryChangeSet(identity: identity ?? self.identity, sequence: sequence, origin: origin)
        for id in episodes { set.episodes[id] = .init(change: .changed, feed: 1) }
        return set
    }

    /// Commits and delivers a set (the store emits after COMMIT, so the database is ahead of delivery first).
    func commit(_ hub: LibraryChangeHub, _ fake: Fake, _ set: LibraryChangeSet) {
        fake.commit(set.sequence)
        hub.emit(set)
    }

    func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { await Task.yield(); try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition(), "\(label)")
    }

    @Test func nothingDeliveredReadsNothing() async throws {
        let fake = Fake(); let (_, updater) = make(fake)
        #expect(await updater.settle(receipt: 0) == .settled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.reads == 0 && fake.applied.isEmpty)
        updater.stop()
    }

    /// Settle returns only once the screen covers the receipt, never early.
    @Test func settleWaitsForTheReceipt() async throws {
        let fake = Fake(); let (hub, updater) = make(fake)
        fake.state.withLock { $0.held = true }
        commit(hub, fake, set(1))
        var settled: LibraryScreenUpdater.Settled?
        let waiter = Task { settled = await updater.settle(receipt: 1) }
        try await wait("read started") { fake.reads == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(settled == nil && updater.covered == 0, "not before the patch")
        fake.release()
        await waiter.value
        #expect(settled == .settled && updater.covered == 1 && fake.applied == [1])
        updater.stop()
    }

    /// A read whose snapshot already holds a commit not yet delivered is never applied; it is read again once that
    /// commit is delivered, and one patch covers both.
    @Test func aReadAheadOfDeliveryIsReadAgain() async throws {
        let fake = Fake(); let (hub, updater) = make(fake)
        fake.state.withLock { $0.held = true }
        commit(hub, fake, set(1, episodes: [1]))
        try await wait("first read") { fake.reads == 1 }
        // Commit 2 lands in the database before its set is delivered: the held read will see it.
        fake.commit(2)
        fake.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fake.applied.isEmpty, "mixed inputs never applied")
        hub.emit(set(2, episodes: [2]))
        try await wait("patched") { updater.covered == 2 }
        #expect(fake.applied == [2])
        #expect(fake.requests.last?.episodes == [1, 2], "the patch reads what both sets named")
        #expect(updater.metrics.races >= 1)
        updater.stop()
    }

    /// A set delivered while a read runs (whose snapshot predates it) is applied by the next patch, after the first one.
    /// A read of library L1 still running when the screen switches to library L2 (the same IDs and
    /// sequences, another library) is discarded when it returns: L1's updater applies nothing, L2's covers only its own
    /// sets, and L1's sets never reach L2.
    @Test func aDelayedResultOfTheLibraryLeftIsDiscarded() async throws {
        let first = Fake(); let (firstHub, firstUpdater) = make(first)
        first.state.withLock { $0.held = true }
        commit(firstHub, first, set(1, episodes: [1]))
        try await wait("L1's read started") { first.reads == 1 }
        // The switch: L1's screen stops; L2 (reused IDs and sequences) opens at sequence 0.
        firstUpdater.stop()
        let second = Fake()
        let otherIdentity = LibraryChangeHub.Identity(library: "library", incarnation: UUID())
        let secondHub = LibraryChangeHub(identity: otherIdentity, baseline: 0)
        let secondUpdater = LibraryScreenUpdater(subscription: secondHub.subscribe(), configuration: .init())
        secondUpdater.request = { sets in var request = LibraryMirrorRequest(); for set in sets { request.episodes.formUnion(set.episodes.keys) }; return request }
        secondUpdater.read = { try await second.read($0) }
        secondUpdater.apply = { read in second.applied.append(read.sequence) }
        secondUpdater.isActive = { true }
        // L1's commit 1 (its identity) delivered to L2 is not L2's.
        secondUpdater.receive(set(1, episodes: [1]))
        first.commit(1)
        first.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(first.applied.isEmpty, "L1's delayed result is discarded")
        #expect(secondUpdater.covered == 0 && second.reads == 0 && second.applied.isEmpty, "L2 is untouched")
        // L2's own commit 1 is patched.
        second.commit(1)
        secondHub.emit(set(1, episodes: [1], identity: otherIdentity))
        try await wait("L2's own set applied") { secondUpdater.covered == 1 }
        #expect(second.applied == [1] && first.applied.isEmpty)
        secondUpdater.stop()
    }

    @Test func aSetDeliveredDuringAReadIsPatchedNext() async throws {
        let fake = Fake(); let (hub, updater) = make(fake)
        fake.state.withLock { $0.held = true; $0.scripted = [1] }
        commit(hub, fake, set(1, episodes: [1]))
        try await wait("first read") { fake.reads == 1 }
        commit(hub, fake, set(2, episodes: [7]))
        fake.release()
        try await wait("both applied") { updater.covered == 2 }
        #expect(fake.applied == [1, 2])
        #expect(fake.requests.map(\.episodes) == [[1], [7]])
        updater.stop()
    }

    /// A sync set delivered during a sync patch's read is patched next only after the pacing, like any sync patch; a
    /// local set delivered during the read is patched at once.
    @Test func syncSetsDeliveredDuringAReadWaitForThePacing() async throws {
        let fake = Fake(); let (hub, updater) = make(fake, pacing: .seconds(1))
        fake.state.withLock { $0.held = true; $0.scripted = [1] }
        commit(hub, fake, set(1, origin: .sync, episodes: [1]))
        try await wait("first read") { fake.reads == 1 }
        commit(hub, fake, set(2, origin: .sync, episodes: [2]))
        fake.release()
        try await wait("both applied") { updater.covered == 2 }
        let starts = fake.state.withLock { $0.starts }
        #expect(fake.applied == [1, 2])
        #expect(starts[0].duration(to: starts[1]) >= .milliseconds(950), "the second sync patch waited for the pacing")
        updater.stop()

        let localFake = Fake(); let (localHub, localUpdater) = make(localFake, pacing: .seconds(1))
        localFake.state.withLock { $0.held = true; $0.scripted = [1] }
        commit(localHub, localFake, set(1, origin: .sync, episodes: [1]))
        try await wait("first read") { localFake.reads == 1 }
        commit(localHub, localFake, set(2, origin: .local, episodes: [2]))
        localFake.release()
        try await wait("both applied") { localUpdater.covered == 2 }
        let localStarts = localFake.state.withLock { $0.starts }
        #expect(localStarts[0].duration(to: localStarts[1]) < .milliseconds(500), "a local set is patched at once")
        localUpdater.stop()
    }

    /// After the configured attempts the updater parks: no read until a trigger (a new delivery), then it recovers.
    @Test func persistentFailuresParkUntilATrigger() async throws {
        let fake = Fake(); let (hub, updater) = make(fake)
        fake.state.withLock { $0.failures = 12 }
        commit(hub, fake, set(1))
        try await wait("attempts spent") { fake.reads >= 3 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.reads == 3, "no hot retry: \(fake.reads) reads")
        #expect(fake.errors == 1, "shown once")
        fake.state.withLock { $0.failures = 0 }
        commit(hub, fake, set(2))
        try await wait("recovered") { updater.covered == 2 }
        updater.stop()
    }

    /// Sets up to the open's sequence are covered by it; later ones are patched, also those delivered during the open.
    @Test func setsBeforeTheOpenAreCoveredAndLaterOnesPatched() async throws {
        let fake = Fake(); let (hub, updater) = make(fake)
        updater.beginOpen()
        for sequence in Int64(1)...3 { commit(hub, fake, set(sequence, episodes: [sequence])) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(fake.reads == 0, "no patch while the screen reads in full")
        updater.opened(at: 2)
        try await wait("patched") { updater.covered == 3 }
        #expect(fake.requests.map(\.episodes) == [[3]])
        updater.stop()
    }

    /// Sync sets are paced (a patch at most every `syncPacing`); a local set is applied at once, with any held sync
    /// sets.
    @Test func syncSetsArePacedAndLocalSetsAreNot() async throws {
        let fake = Fake(); let (hub, updater) = make(fake, pacing: .milliseconds(400))
        commit(hub, fake, set(1, origin: .sync))
        try await wait("first sync patch") { updater.covered == 1 }
        let first = ContinuousClock.now
        commit(hub, fake, set(2, origin: .sync))
        try await Task.sleep(for: .milliseconds(100))
        #expect(updater.covered == 1, "the second sync patch waits for the pacing")
        commit(hub, fake, set(3, origin: .local))
        try await wait("the local set and the held sync set at once") { updater.covered == 3 }
        #expect(first.duration(to: .now) < .milliseconds(400), "the local set did not wait")
        commit(hub, fake, set(4, origin: .sync))
        let second = ContinuousClock.now
        try await wait("next sync patch") { updater.covered == 4 }
        #expect(second.duration(to: .now) >= .milliseconds(250))
        updater.stop()
    }

    /// In the background sets accumulate; settle is deferred; activation applies them in one patch. Past the cap the
    /// screen opens again instead.
    @Test func theBackgroundAccumulatesAndTheCapReopens() async throws {
        let fake = Fake()
        var active = false
        let (hub, updater) = make(fake, active: { active })
        for sequence in Int64(1)...5 { commit(hub, fake, set(sequence, episodes: [sequence])) }
        #expect(await updater.settle(receipt: 5) == .deferred)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fake.reads == 0)
        active = true
        updater.activate()
        try await wait("one patch") { updater.covered == 5 }
        #expect(fake.reads == 1 && fake.requests[0].episodes == Set(1...5))
        // A catch-up larger than the cap: the screen opens again.
        active = false
        commit(hub, fake, set(6, episodes: Array(1...500)))
        active = true
        updater.activate()
        try await wait("reopened") { fake.reopened == 1 }
        #expect(fake.reads == 1, "no patch read for the catch-up")
        updater.beginOpen(); updater.opened(at: 6)
        #expect(updater.covered == 6 && updater.pendingCount == 0)
        updater.stop()
    }

    /// A set of another library (a switch, with reused sequences and IDs) is never applied.
    @Test func anotherLibrarysSetsAreIgnored() async throws {
        let fake = Fake(); let (hub, updater) = make(fake)
        hub.emit(set(1, identity: .init(library: "library", incarnation: UUID())))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fake.reads == 0 && updater.covered == 0 && updater.delivered == 0)
        updater.stop()
    }

    /// A read failure is shown once, retried, and the screen converges; teardown cancels waiters.
    @Test func failuresAreShownOnceAndRetried() async throws {
        let fake = Fake(); let (hub, updater) = make(fake)
        fake.state.withLock { $0.failures = 2 }
        commit(hub, fake, set(1))
        try await wait("converged") { updater.covered == 1 }
        #expect(fake.errors == 1 && fake.reads == 3)
        fake.state.withLock { $0.held = true }
        commit(hub, fake, set(2))
        let waiter = Task { await updater.settle(receipt: 2) }
        try await wait("read started") { fake.reads == 4 }
        updater.stop()
        #expect(await waiter.value == .cancelled)
        fake.release()
    }
}

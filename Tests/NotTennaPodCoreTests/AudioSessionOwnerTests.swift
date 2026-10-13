import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// One app-wide owner of the audio session: every engine claims the same owner, whose OS
/// calls never overlap. The owner is responsible for every activation it applied or has in flight and
/// releases it once no live claim wants it, so a retired engine's release, even in flight, cannot stop its
/// successor, and a cancelled successor cannot leave an activation behind. The session is kept through
/// pauses and from one item to the next (as Media3 keeps audio focus); end of queue, stop,
/// close and failure release it. Every check of the call history is of the whole history, after an
/// explicit barrier (the owner idle, OS calls completed by hand).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct AudioSessionOwnerTests {
    /// The OS session shared by every engine: records each call, completes on demand, never two at once.
    @MainActor final class SessionDriver: AudioSessionActivationDriver {
        var calls: [Bool] = []
        var preparations = 0
        var autoComplete = false
        private(set) var active = false
        private var pending: (active: Bool, continuation: CheckedContinuation<Bool, any Error>)?
        var isPending: Bool { pending != nil }
        var pendingActive: Bool? { pending?.active }
        func prepareForActivation() throws { preparations += 1 }
        func setActive(_ active: Bool) async throws -> Bool {
            #expect(pending == nil, "two OS session calls overlapped")
            calls.append(active)
            if autoComplete { self.active = active; return true }
            return try await withCheckedThrowingContinuation { pending = (active, $0) }
        }
        func complete(_ granted: Bool = true) {
            guard let current = pending else { return }
            pending = nil
            if granted { active = current.active }
            current.continuation.resume(returning: granted)
        }
        func fail() {
            guard let current = pending else { return }
            pending = nil
            current.continuation.resume(throwing: URLError(.cannotConnectToHost))
        }
    }
    typealias Transport = SampleBufferPCMOutputTests.Transport
    typealias SystemEvents = PCMSystemSessionTests.SystemEvents

    // MARK: Owner

    /// A retired claim's release is dropped while a newer claim wants the session, whether the retired
    /// claim's own activation completes before or after the successor asks.
    @Test(arguments: [false, true])
    func retiredReleaseCannotDeactivateTheSuccessor(activationCompletesFirst: Bool) async throws {
        let driver = SessionDriver(), owner = AudioSessionOwner(driver: driver)
        let a = AudioSessionActivationController(owner: owner), b = AudioSessionActivationController(owner: owner)
        var results: [String] = []
        a.onResult = { results.append("A \($0.active) \($0.outcome)") }
        b.onResult = { results.append("B \($0.active) \($0.outcome)") }
        try a.request(active: true)
        try await wait { driver.isPending }
        if activationCompletesFirst { driver.complete(); try await wait { results == ["A true applied"] } }
        try b.request(active: true)
        a.close() // Retired: its release must not reach the OS.
        if !activationCompletesFirst { driver.complete() }
        try await wait { results.last == "B true applied" && owner.isIdle }
        #expect(driver.calls == [true] && driver.active && owner.actual == true)
        b.close()
        try await wait { driver.pendingActive == false }; driver.complete()
        try await wait { owner.isIdle }
        #expect(driver.calls == [true, false])
    }

    /// The retired engine's deactivation already started when the successor asks: the successor is
    /// activated right after it, and the app's own deactivation notice (before or after that activation
    /// completes) is not forwarded and cannot stop it.
    @Test(arguments: [false, true])
    func releaseAlreadyInFlightIsFollowedByTheSuccessorsActivation(noticeAfterActivation: Bool) async throws {
        let driver = SessionDriver(), events = SystemEvents()
        let owner = AudioSessionOwner(driver: driver, events: events.subscribe)
        let a = AudioSessionActivationController(owner: owner), b = AudioSessionActivationController(owner: owner)
        var bResults: [AudioSessionActivationController.Outcome] = [], bEvents: [AudioSessionEvent] = []
        b.onResult = { bResults.append($0.outcome) }
        b.onSystemEvent = { bEvents.append($0) }
        try a.request(active: true); try await wait { driver.isPending }; driver.complete()
        try await wait { owner.actual == true }
        a.close()
        try await wait { driver.pendingActive == false }
        try b.request(active: true)
        driver.complete()
        if !noticeAfterActivation { events.post(.appDeactivated) }
        try await wait { driver.pendingActive == true }
        driver.complete()
        try await wait { bResults == [.applied] && owner.isIdle }
        if noticeAfterActivation { events.post(.appDeactivated) }
        #expect(driver.calls == [true, false, true] && owner.actual == true && bEvents.isEmpty)
        // A real system interruption stays authoritative and reaches the claimant.
        events.post(.interrupted(reason: 0))
        #expect(owner.actual == false && bEvents == [.interrupted(reason: 0)])
        b.close()
    }

    /// A claim that has not asked for the session does not hold it: the release goes ahead, and its later
    /// Play activates again.
    @Test func claimThatNeverAskedDoesNotHoldTheSession() async throws {
        let driver = SessionDriver(); driver.autoComplete = true
        let owner = AudioSessionOwner(driver: driver)
        let a = AudioSessionActivationController(owner: owner), b = AudioSessionActivationController(owner: owner)
        var bApplied = false
        b.onResult = { bApplied = $0.outcome == .applied && $0.active }
        try a.request(active: true); try await wait { owner.actual == true }
        a.close(); try await wait { owner.actual == false && owner.isIdle }
        try b.request(active: true); try await wait { bApplied }
        #expect(driver.calls == [true, false, true])
        b.close(); try await wait { owner.actual == false && owner.isIdle }
        #expect(driver.calls == [true, false, true, false])
    }

    /// Pending effects follow current intent: a failed or declined activation is not a success for the
    /// claim that asked, and is retried only for a claim that asked meanwhile; a claim cancelled while its
    /// activation is in flight is compensated when nobody else wants the session.
    @Test(arguments: [false, true])
    func failedOrCancelledActivationReconcilesWithCurrentIntent(declined: Bool) async throws {
        let driver = SessionDriver(), owner = AudioSessionOwner(driver: driver)
        let a = AudioSessionActivationController(owner: owner), b = AudioSessionActivationController(owner: owner)
        var aResults: [AudioSessionActivationController.Outcome] = [], bResults: [AudioSessionActivationController.Outcome] = []
        a.onResult = { aResults.append($0.outcome) }
        b.onResult = { bResults.append($0.outcome) }
        try a.request(active: true); try await wait { driver.isPending }
        try b.request(active: true)
        if declined { driver.complete(false) } else { driver.fail() }
        try await wait { driver.pendingActive == true && driver.calls.count == 2 }
        driver.complete()
        try await wait { bResults == [.applied] }
        #expect(aResults == [declined ? .declined : .failed] && owner.actual == true)
        a.close(); b.close()
        try await wait { driver.pendingActive == false }; driver.complete()
        let c = AudioSessionActivationController(owner: owner)
        try c.request(active: true); try await wait { driver.isPending }
        c.close()
        driver.complete()
        try await wait { driver.pendingActive == false }; driver.complete()
        try await wait { owner.isIdle }
        #expect(driver.calls == [true, true, false, true, false] && owner.actual == false)
    }

    /// Schedules (a) and (b): the successor asks, then releases and closes before the owner gets to
    /// it, with A's activation still in flight or already applied. The owner still releases the session.
    @Test(arguments: [false, true])
    func cancelledSuccessorCannotLeaveTheSessionActive(activationApplied: Bool) async throws {
        let driver = SessionDriver(), owner = AudioSessionOwner(driver: driver)
        let a = AudioSessionActivationController(owner: owner), b = AudioSessionActivationController(owner: owner)
        try a.request(active: true); try await wait { driver.isPending }
        if activationApplied { driver.complete(); try await wait { owner.actual == true && owner.isIdle } }
        a.close()
        try b.request(active: true)
        try b.request(active: false)
        b.close()
        if !activationApplied { driver.complete() }
        try await wait { driver.pendingActive == false }
        driver.complete()
        try await wait { owner.isIdle }
        #expect(driver.calls == [true, false] && !driver.active && owner.actual == false)
    }

    /// A successor that asks while a release is in flight and is cancelled before it completes: the
    /// session ends inactive, with no reactivation.
    @Test func successorCancelledDuringAnInFlightReleaseLeavesItReleased() async throws {
        let driver = SessionDriver(), owner = AudioSessionOwner(driver: driver)
        let a = AudioSessionActivationController(owner: owner), b = AudioSessionActivationController(owner: owner)
        try a.request(active: true); try await wait { driver.isPending }; driver.complete()
        try await wait { owner.actual == true && owner.isIdle }
        a.close()
        try await wait { driver.pendingActive == false }
        try b.request(active: true)
        b.close()
        driver.complete()
        try await wait { owner.isIdle }
        #expect(driver.calls == [true, false] && !driver.active && owner.actual == false)
    }

    /// A claim that used the session closes while a release is in flight and the session was seen active
    /// again meanwhile: the release's result cannot clear the responsibility it handed over, so the owner
    /// releases once more. A claim that never used the session hands over nothing.
    @Test(arguments: [false, true])
    func closeDuringAnInFlightReleaseKeepsTheHandedOverResponsibility(used: Bool) async throws {
        let driver = SessionDriver(), events = SystemEvents()
        let owner = AudioSessionOwner(driver: driver, events: events.subscribe)
        let a = AudioSessionActivationController(owner: owner), unused = AudioSessionActivationController(owner: owner)
        try a.request(active: true); try await wait { driver.isPending }; driver.complete()
        try await wait { owner.actual == true && owner.isIdle }
        try a.request(active: false)
        try await wait { driver.pendingActive == false }
        events.post(.becameActive)
        if used { a.close() } else { unused.close() }
        driver.complete()
        if used { try await wait { driver.pendingActive == false && driver.calls.count == 3 }; driver.complete() }
        try await wait { owner.isIdle }
        #expect(driver.calls == (used ? [true, false, false] : [true, false]))
        // The session was seen active after A's release: closing A, which used it, releases it.
        a.close()
        if !used { try await wait { driver.pendingActive == false }; driver.complete() }
        try await wait { owner.isIdle }
        #expect(driver.calls == [true, false, false])
    }

    // MARK: Engines on one owner

    /// A's activation pending, the user switches to B, completions in request
    /// order. B plays and stays playing; the session is never deactivated after B's activation.
    @Test func switchingWhileActivationIsPendingLeavesTheSuccessorPlaying() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let a = UUID(); rig.app.load(episode: rig.episode(1), generation: a, positionMilliseconds: 0); rig.app.play(commandID: a)
        try await wait { rig.driver.pendingActive == true && rig.transports.count == 1 }
        let b = UUID(); rig.app.load(episode: rig.episode(2), generation: b, positionMilliseconds: 0); rig.app.play(commandID: b)
        // B has asked for the session (its output is created after its Play) before A's activation completes.
        try await wait { rig.transports.count == 2 }
        rig.driver.complete()
        try await wait { rig.isPlaying(b) && rig.owner.isIdle }
        #expect(rig.driver.calls == [true] && rig.driver.active && rig.transports.last?.playing == true)
        #expect(rig.app.reading?.sample.status == .playing && rig.app.reading?.buffering == false)
    }

    /// A plays with its activation outstanding, B replaces it and creates its output,
    /// then the application engine stops before A's activation completes. The session is released.
    @Test func stopWhileTheReplacedActivationIsOutstandingReleasesTheSession() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let a = UUID(); rig.app.load(episode: rig.episode(1), generation: a, positionMilliseconds: 0); rig.app.play(commandID: a)
        try await wait { rig.driver.pendingActive == true && rig.transports.count == 1 }
        let b = UUID(); rig.app.load(episode: rig.episode(2), generation: b, positionMilliseconds: 0); rig.app.play(commandID: b)
        try await wait { rig.transports.count == 2 }
        rig.app.unload()
        // Both replaced engines are gone, their claims closed with A's activation still outstanding.
        #expect(rig.engines.allSatisfy { $0.engine == nil })
        rig.driver.complete()
        try await wait { rig.driver.pendingActive == false }
        rig.driver.complete()
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.calls == [true, false] && !rig.driver.active && rig.owner.actual == false)
        #expect(rig.app.reading == nil && rig.transports.allSatisfy { !$0.playing })
    }

    /// Rapid selection across several items with activations and releases in flight: only the last item
    /// plays, and the final OS call is its activation.
    @Test func rapidSelectionEndsWithTheLastItemPlaying() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var last = UUID()
        for id in 1...4 {
            last = UUID()
            rig.app.load(episode: rig.episode(Int64(id)), generation: last, positionMilliseconds: 0)
            rig.app.play(commandID: last)
            if rig.driver.isPending { rig.driver.complete() }
            await Task.yield()
        }
        try await wait {
            if rig.driver.isPending { rig.driver.complete() }
            return rig.isPlaying(last) && rig.owner.isIdle
        }
        #expect(rig.driver.calls.last == true && rig.driver.active && !rig.driver.isPending)
        #expect(rig.transports.dropLast().allSatisfy { !$0.playing })
    }

    /// The AVPlayer route claims the same owner: it starts once the owner has activated the session, keeps
    /// it through a pause, and releases it when the item stops for good (unload or a failing reload).
    @Test(arguments: [false, true])
    func fallbackEngineKeepsTheSessionWhilePausedAndReleasesItWhenDone(failingReload: Bool) async throws {
        let driver = SessionDriver(), owner = AudioSessionOwner(driver: driver)
        let mp3 = try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
        var source = mp3
        let engine = AVPlayerPlaybackEngine(muted: true, source: { _ in source }, configureAudioSession: {}, sessionOwner: owner)
        var failures = 0
        engine.onEvent = { if case .failed = $0 { failures += 1 } }
        defer { engine.unload() }
        let episode = LibraryEpisode(id: 1, details: .init(identifier: "1", title: "Fallback", media: .init(url: mp3.absoluteString, size: 0)))
        engine.load(episode: episode, generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        try await wait { driver.isPending }
        #expect((engine.nativePlayer?.rate ?? 0) == 0) // Not before the session is active.
        driver.complete()
        try await wait { (engine.nativePlayer?.rate ?? 0) > 0 }
        engine.pause(commandID: UUID()); engine.play(commandID: UUID())
        try await wait { (engine.nativePlayer?.rate ?? 0) > 0 && owner.isIdle }
        #expect(driver.calls == [true] && !driver.isPending)
        if failingReload {
            source = URL(fileURLWithPath: "/nonexistent/missing.mp3")
            engine.load(episode: episode, generation: UUID(), positionMilliseconds: 0) // Its unload releases, then the load fails.
            try await wait { failures == 1 && driver.isPending }
        } else {
            engine.unload()
            try await wait { driver.isPending }
        }
        driver.complete()
        try await wait { owner.isIdle }
        #expect(driver.calls == [true, false] && owner.actual == false)
    }

    // MARK: Through the coordinator

    enum Transition: String, CaseIterable, Sendable { case processedToProcessed, processedToFallback, fallbackToProcessed }

    /// A queue transition keeps the session while the next item's source is resolved (held behind a gate)
    /// and prepared, as Media3 keeps focus across items: the old engine is closed, and the whole OS call
    /// history has no release until Stop, which releases once.
    @Test(arguments: Transition.allCases, [false, true])
    func queueTransitionKeepsTheSessionUntilStop(transition: Transition, routed: Bool) async throws {
        let rig = try Rig(fallback: transition == .fallbackToProcessed ? [1] : transition == .processedToFallback ? [2] : [], routed: routed)
        defer { rig.close() }
        rig.driver.autoComplete = true
        let player = try await rig.coordinator()
        _ = try await store(rig).enqueue([1, 2])
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle }
        #expect(rig.driver.calls == [true])
        rig.gate.hold(2)
        if transition == .fallbackToProcessed { try await player.skip() }
        else { try await drain(rig.transports[0]) { rig.gate.isWaiting(2) } }
        try await wait { rig.gate.isWaiting(2) && rig.owner.isIdle }
        // Between the items: the old engine is closed, the session still active, nothing released.
        #expect(rig.driver.calls == [true] && rig.driver.active)
        #expect(rig.transports.allSatisfy { $0.closed || !$0.playing } && rig.players.allSatisfy { $0.nativePlayer == nil })
        rig.gate.release(2)
        try await wait { rig.playingEpisode == 2 && rig.owner.isIdle }
        #expect(rig.driver.calls == [true] && rig.driver.active && player.episode?.id == 2)
        try await player.stop()
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.calls == [true, false] && !rig.driver.active)
    }

    /// A successor intentionally left paused (continuous playback off) inherits the session; an unused
    /// initial paused load does not newly take it.
    @Test func pausedSuccessorInheritsTheSessionButAPausedFirstLoadDoesNotTakeIt() async throws {
        let rig = try Rig(followQueue: false)
        defer { rig.close() }
        rig.driver.autoComplete = true
        let player = try await rig.coordinator()
        _ = try await store(rig).enqueue([1, 2, 3])
        try await player.select(episodeID: 3, play: false)
        try await wait { player.phase == .paused && rig.owner.isIdle }
        #expect(rig.driver.calls.isEmpty) // A paused first load takes no session.
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle }
        #expect(rig.driver.calls == [true])
        try await drain(rig.transports.last!) { player.episode?.id == 2 && player.phase == .paused }
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.calls == [true] && rig.driver.active && !player.wantsPlayback)
        try await player.play()
        try await wait { rig.playingEpisode == 2 && rig.owner.isIdle }
        #expect(rig.driver.calls == [true])
        try await player.stop()
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.calls == [true, false])
    }

    /// A transition cancelled while the next item's source is still being resolved (Stop), or failing in
    /// that preparation, releases the session exactly once; the late resolution changes nothing.
    @Test(arguments: [false, true])
    func cancelledOrFailedTransitionReleasesOnce(failure: Bool) async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.driver.autoComplete = true
        let player = try await rig.coordinator()
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle }
        rig.gate.hold(2)
        try await player.select(episodeID: 2)
        try await wait { rig.gate.isWaiting(2) && rig.owner.isIdle }
        #expect(rig.driver.calls == [true] && rig.driver.active)
        if failure {
            rig.gate.fail(2)
            try await wait { player.phase == .failed && rig.owner.isIdle }
        } else {
            try await player.stop()
            try await wait { rig.owner.isIdle }
            #expect(rig.driver.calls == [true, false])
            rig.gate.release(2)
            try await wait { rig.resolved == [1, 2] }
            try await player.awaitPendingOperations()
        }
        try await wait { rig.owner.isIdle && !rig.gate.isWaiting(2) }
        #expect(rig.driver.calls == [true, false] && !rig.driver.active)
        #expect(rig.transports.allSatisfy { !$0.playing })
    }

    enum Abandon: String, CaseIterable, Sendable { case cancelled, failed, streamingConfirmation }

    /// A replacement abandoned after the old engine was retired but before the next item's engine loads
    /// (cancelled, failed, or stopped for a mobile-data confirmation) keeps the session while pending and
    /// then releases it exactly once.
    @Test(arguments: Abandon.allCases)
    func replacementAbandonedBeforeTheNextLoadReleasesOnce(abandon: Abandon) async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.driver.autoComplete = true
        let access = Gate()
        let player = try await rig.coordinator(streamingAccess: { episode in
            guard episode.id == 2 else { return .init(needsStreaming: false, streamingAllowed: true) }
            try await access.pass(episode.id)
            switch abandon {
            case .cancelled: throw CancellationError()
            case .failed: throw URLError(.cannotConnectToHost)
            case .streamingConfirmation: return .init(needsStreaming: true, streamingAllowed: false)
            }
        })
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle }
        access.hold(2)
        let switching = Task { try await player.select(episodeID: 2) }
        try await wait { access.isWaiting(2) && rig.owner.isIdle }
        #expect(rig.driver.calls == [true] && rig.driver.active && rig.transports.allSatisfy { !$0.playing })
        access.release(2)
        _ = await switching.result
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.calls == [true, false] && !rig.driver.active && rig.engines.count == 1)
    }

    enum CastEntry: String, CaseIterable, Sendable { case connect, adoption }

    /// Cast connects (or a receiver session is adopted) while a local replacement holds
    /// the session and the next item's access check is still pending. Giving the route to the receiver
    /// releases the local session at once; the next item then plays remotely and Stop adds no OS call.
    @Test(arguments: CastEntry.allCases)
    func castDuringAReservedLocalReplacementReleasesTheLocalSession(entry: CastEntry) async throws {
        let rig = try Rig(routed: true)
        defer { rig.close() }
        rig.driver.autoComplete = true
        let access = Gate()
        let player = try await rig.coordinator(streamingAccess: { episode in
            try await access.pass(episode.id)
            return .init(needsStreaming: false, streamingAllowed: true)
        })
        let routes = try #require(rig.routes)
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle }
        access.hold(2)
        let switching = Task { try await player.select(episodeID: 2) }
        try await wait { access.isWaiting(2) && rig.owner.isIdle }
        // The old local engine is gone; the session is reserved for the next item.
        #expect(rig.driver.calls == [true] && rig.driver.active && rig.engines.allSatisfy { $0.engine == nil })
        let remote = Remote()
        switch entry {
        case .connect: routes.setRemote(remote)
        case .adoption: routes.setRemoteForAdoption(remote)
        }
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.calls == [true, false] && !rig.driver.active && rig.owner.actual == false)
        access.release(2)
        try await switching.value
        try await player.awaitPendingOperations()
        #expect(remote.playingEpisode == 2 && player.episode?.id == 2 && rig.engines.count == 1)
        try await player.stop()
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.calls == [true, false] && !rig.driver.active && rig.owner.actual == false)
        #expect(remote.playingEpisode == nil)
    }

    /// Casting releases the local session; the receiver's own queue handoff makes no OS call (a remote load
    /// never takes a local reservation); returning to the phone activates it again, and Stop releases it.
    @Test func castingAndReturningMovesTheSessionWithTheRoute() async throws {
        let rig = try Rig(routed: true)
        defer { rig.close() }
        rig.driver.autoComplete = true
        let player = try await rig.coordinator()
        let routes = try #require(rig.routes)
        _ = try await store(rig).enqueue([1, 2])
        try await player.select(episodeID: 1)
        try await wait { rig.playingEpisode == 1 && rig.owner.isIdle }
        #expect(rig.driver.calls == [true])
        let remote = Remote()
        routes.setRemote(remote)
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.calls == [true, false] && remote.playingEpisode == 1 && rig.engines.allSatisfy { $0.engine == nil })
        try await player.skip()
        try await player.awaitPendingOperations()
        try await wait { rig.owner.isIdle }
        #expect(remote.playingEpisode == 2 && rig.driver.calls == [true, false] && rig.engines.count == 1)
        routes.setRemote(nil)
        try await wait { rig.playingEpisode == 2 && rig.owner.isIdle }
        #expect(rig.driver.calls == [true, false, true] && remote.playingEpisode == nil)
        try await player.stop()
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.calls == [true, false, true, false] && !rig.driver.active)
    }

    /// The application engine itself releases an inherited session when the next item's source fails,
    /// synchronously or while resolving, even if its observer does not unload it.
    @Test(arguments: [false, true])
    func applicationEngineReleasesAnInheritedSessionWhenTheNextSourceFails(synchronously: Bool) async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.driver.autoComplete = true
        var failures: [UUID] = []
        rig.app.onEvent = { if case .failed(let generation, _) = $0 { failures.append(generation) } }
        let a = UUID()
        rig.app.load(episode: rig.episode(1), generation: a, positionMilliseconds: 0); rig.app.play(commandID: a)
        try await wait { rig.isPlaying(a) && rig.owner.isIdle }
        #expect(rig.driver.calls == [true])
        rig.app.reserveSessionForNextItem()
        if synchronously { rig.gate.failSynchronously(2) } else { rig.gate.hold(2) }
        let b = UUID()
        rig.app.load(episode: rig.episode(2), generation: b, positionMilliseconds: 0); rig.app.play(commandID: b)
        if !synchronously {
            try await wait { rig.gate.isWaiting(2) && rig.owner.isIdle }
            #expect(rig.driver.calls == [true] && rig.driver.active && failures.isEmpty)
            rig.gate.fail(2)
        }
        try await wait { failures == [b] && rig.owner.isIdle }
        #expect(rig.driver.calls == [true, false] && !rig.driver.active && rig.engines.allSatisfy { $0.engine == nil })
    }

    /// Normal queue handoff, pause, interruption and pause intent, then the end of the queue: the whole
    /// call history has one activation per interruption and one final release.
    @Test func queueHandoffPauseAndInterruptionKeepIntentAndTheEndReleases() async throws {
        let rig = try Rig(events: true)
        defer { rig.close() }
        rig.driver.autoComplete = true
        let player = try await rig.coordinator()
        _ = try await store(rig).enqueue([1, 2])
        try await player.select(episodeID: 1)
        try await wait { rig.transports.first?.playing == true }
        // Pausing keeps the session; playing again needs no new activation.
        try await player.pause()
        try await player.play(); try await wait { rig.transports[0].playing && rig.owner.isIdle }
        #expect(rig.driver.calls == [true])
        // Episode 1 ends: the next queued episode plays on the same session.
        try await drain(rig.transports[0]) { player.episode?.id == 2 && rig.transports.count == 2 && rig.transports[1].playing }
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.active && rig.driver.calls == [true])
        // A system interruption pauses and keeps the intent; its end resumes with a new activation.
        rig.events.post(.interrupted(reason: 0))
        try await wait { !rig.transports[1].playing }
        #expect(player.wantsPlayback || rig.app.resumesAfterInterruption)
        rig.events.post(.resumptionRecommended(true))
        try await wait { rig.transports.last?.playing == true && rig.owner.isIdle }
        #expect(rig.driver.calls == [true, true])
        // A manual pause during an interruption stays paused when it ends.
        rig.events.post(.interrupted(reason: 0))
        try await wait { rig.transports.last?.playing == false }
        try await player.pause()
        rig.events.post(.resumptionRecommended(true))
        try await player.awaitPendingOperations()
        try await wait { rig.owner.isIdle }
        #expect(!player.wantsPlayback && rig.transports.allSatisfy { !$0.playing } && rig.driver.calls == [true, true])
        // End of the queue releases the session.
        try await player.play(); try await wait { rig.transports.last?.playing == true }
        try await drain(rig.transports.last!) { player.phase == .idle }
        try await wait { rig.owner.isIdle }
        #expect(rig.driver.calls == [true, true, true, false] && !rig.driver.active)
    }

    /// Stop and a playback failure release the session once.
    @Test(arguments: [false, true])
    func stopAndFailureReleaseTheSession(failure: Bool) async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.driver.autoComplete = true
        let player = try await rig.coordinator()
        try await player.select(episodeID: 1)
        try await wait { rig.transports.first?.playing == true && rig.driver.active }
        if failure {
            rig.transports[0].error = URLError(.cannotDecodeRawData)
            rig.transports[0].advance(4096)
            try await wait { player.phase == .failed }
        } else {
            try await player.stop()
        }
        try await wait { rig.owner.isIdle && !rig.driver.active }
        #expect(rig.driver.calls == [true, false])
    }

    // MARK: Rig

    /// Holds chosen items' source resolution until released (or failed) by the test.
    @MainActor final class Gate {
        private var held: Set<Int64> = []
        private var waiting: [Int64: CheckedContinuation<Void, any Error>] = [:]
        func hold(_ id: Int64) { held.insert(id) }
        func isWaiting(_ id: Int64) -> Bool { waiting[id] != nil }
        func pass(_ id: Int64) async throws {
            guard held.contains(id) else { return }
            try await withCheckedThrowingContinuation { waiting[id] = $0 }
        }
        func release(_ id: Int64) { held.remove(id); waiting.removeValue(forKey: id)?.resume() }
        func fail(_ id: Int64) { held.remove(id); waiting.removeValue(forKey: id)?.resume(throwing: URLError(.cannotConnectToHost)) }
        /// The item's source cannot even start resolving (a missing local file).
        private var synchronousFailures: Set<Int64> = []
        func failSynchronously(_ id: Int64) { synchronousFailures.insert(id) }
        func check(_ id: Int64) throws { if synchronousFailures.contains(id) { throw URLError(.fileDoesNotExist) } }
    }

    /// A Cast receiver stand-in that can also adopt a session already playing on it.
    @MainActor final class Remote: PlaybackExternalStateAdopting {
        let engine = RoutedPlaybackEngineTests.Engine()
        init() { engine.automaticReady = true }
        var reading: PlaybackEngineReading? { engine.reading }
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)? { get { engine.onEvent } set { engine.onEvent = newValue } }
        var playingEpisode: Int64? { engine.wantsPlayback ? engine.loaded.last?.0.id : nil }
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            engine.load(episode: episode, generation: generation, positionMilliseconds: positionMilliseconds)
        }
        func adopt(episode: LibraryEpisode, generation: UUID, state: PlaybackExternalState) throws {
            engine.load(episode: episode, generation: generation, positionMilliseconds: Int64(state.sample.positionMilliseconds))
        }
        func play(commandID: UUID) { engine.play(commandID: commandID) }
        func pause(commandID: UUID) { engine.pause(commandID: commandID) }
        func seek(to positionMilliseconds: Int64, commandID: UUID) { engine.seek(to: positionMilliseconds, commandID: commandID) }
        func setSpeed(_ speed: Float, commandID: UUID) throws { engine.setSpeed(speed, commandID: commandID) }
        func unload() { engine.unload() }
    }

    @MainActor final class Rig {
        let driver = SessionDriver()
        let events = SystemEvents()
        let gate = Gate()
        let owner: AudioSessionOwner
        let app: ApplicationPlaybackEngine
        /// The local application engine behind the Cast route switch, when the rig is routed.
        let routes: RoutedPlaybackEngine?
        let wave: URL
        let store: FeedLibraryStore
        let followQueue: Bool
        var transports: [Transport] = []
        /// The engine made for each item, in order, held weakly as the application engine alone owns it
        /// (a retired engine is released, closing its session claim).
        final class Made { let id: Int64; weak var engine: (any PlaybackEngine)?; init(_ id: Int64, _ engine: any PlaybackEngine) { self.id = id; self.engine = engine } }
        var engines: [Made] = []
        var players: [AVPlayerPlaybackEngine] { engines.compactMap { $0.engine as? AVPlayerPlaybackEngine } }
        /// Items whose source resolution has finished (an explicit completion for late resolutions).
        var resolved: [Int64] = []

        init(fallback: Set<Int64> = [], events useEvents: Bool = false, followQueue: Bool = true, routed: Bool = false) throws {
            let (url, _) = try PCMTestFixture.waveFixture(frames: 48_000)
            wave = url
            self.followQueue = followQueue
            store = try FeedLibraryStore(url: url.deletingLastPathComponent().appendingPathComponent("library.sqlite"))
            let owner = useEvents ? AudioSessionOwner(driver: driver, events: events.subscribe) : AudioSessionOwner(driver: driver)
            self.owner = owner
            var made: (@MainActor (Int64, any PlaybackEngine) -> Void)?
            var madeTransport: (@MainActor (Transport) -> Void)?
            var finished: (@MainActor (Int64) -> Void)?
            let mp3 = Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
            let gate = gate
            app = ApplicationPlaybackEngine(resolve: { episode in
                try gate.check(episode.id)
                return {
                    try await gate.pass(episode.id)
                    defer { finished?(episode.id) }
                    if fallback.contains(episode.id) {
                        let engine = AVPlayerPlaybackEngine(muted: true, source: { _ in mp3 }, configureAudioSession: {}, sessionOwner: owner)
                        made?(episode.id, engine)
                        return engine
                    }
                    let engine = PCMPlaybackEngine(sessionOwner: owner, resolveFactory: { _, url in
                        try PCMRecoveryFactory(url: url, makeTransport: { let t = Transport(); madeTransport?(t); return t })
                    }, source: { _ in url }, duration: { _ in 1000 }, positionTicker: PCMPlaybackEngineTests.Ticker())
                    made?(episode.id, engine)
                    return engine
                }
            }, sessionOwner: owner)
            routes = routed ? RoutedPlaybackEngine(local: app) : nil
            if !routed { app.bindStatistics(lastPlayed: { _ in 0 }, synchronize: { _ in }) }
            finished = { [weak self] in self?.resolved.append($0) }
            made = { [weak self] id, engine in self?.engines.append(Made(id, engine)) }
            madeTransport = { [weak self] in self?.transports.append($0) }
        }

        func episode(_ id: Int64) -> LibraryEpisode {
            LibraryEpisode(id: id, details: .init(identifier: "\(id)", title: "Episode \(id)",
                media: .init(url: wave.absoluteString, size: 0, durationMilliseconds: 1000)))
        }

        func isPlaying(_ generation: UUID) -> Bool {
            guard app.reading?.generation == generation, app.reading?.isPrepared == true, app.reading?.sample.status == .playing else { return false }
            return (players.last?.nativePlayer?.rate ?? 0) > 0 || transports.last?.playing == true
        }

        /// The item whose engine is audibly playing, if any.
        var playingEpisode: Int64? {
            guard let last = engines.last, let engine = last.engine, app.reading?.isPrepared == true,
                  app.reading?.sample.status == .playing else { return nil }
            if let player = engine as? AVPlayerPlaybackEngine { return (player.nativePlayer?.rate ?? 0) > 0 ? last.id : nil }
            return transports.last?.playing == true ? last.id : nil
        }

        func coordinator(streamingAccess: (@MainActor (LibraryEpisode) async throws -> PlaybackStreamingAccess)? = nil) async throws -> PlaybackCoordinator {
            let episodes = (1...3).map { ParsedEpisode(identifier: "\($0)", title: "Episode \($0)",
                media: ParsedMedia(url: "https://example.test/\($0).wav", size: 0, durationMilliseconds: 1000)) }
            _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Session", episodes: episodes),
                source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                validator: nil, permanentRedirectURL: nil))
            let followQueue = followQueue
            let player = PlaybackCoordinator(store: store, engine: routes ?? app, preferences: { _ in
                var preferences = PlaybackPreferences(); preferences.end.smartMarkAsPlayedSeconds = 0
                preferences.followQueue = followQueue
                return preferences
            }, streamingAccess: streamingAccess)
            coordinatorRetained = player
            return player
        }
        private var coordinatorRetained: PlaybackCoordinator?

        func close() {
            routes?.unload()
            app.unload()
            gate.release(1); gate.release(2); gate.release(3)
            driver.autoComplete = true
            driver.complete()
            try? FileManager.default.removeItem(at: wave.deletingLastPathComponent())
        }
    }

    private func store(_ rig: Rig) -> FeedLibraryStore { rig.store }

    private func drain(_ output: Transport, until condition: () -> Bool) async throws {
        try await PCMPlaybackEngineTests().drain(output, until: condition)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
}

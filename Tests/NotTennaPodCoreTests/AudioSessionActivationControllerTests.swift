import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct AudioSessionActivationControllerTests {
    enum Problem: Error { case rejected }
    @MainActor final class Driver: AudioSessionActivationDriver {
        var requests: [Bool] = []
        var pending: CheckedContinuation<Bool, any Error>?
        var preparations = 0
        var configure: (@MainActor () throws -> Void)?
        func prepareForActivation() throws { preparations += 1; try configure?() }
        func setActive(_ active: Bool) async throws -> Bool {
            #expect(pending == nil)
            requests.append(active)
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        func complete(_ value: Bool = true) { let current = pending; pending = nil; current?.resume(returning: value) }
        func fail() { let current = pending; pending = nil; current?.resume(throwing: Problem.rejected) }
    }

    @Test func pendingActivationThenPauseDeactivatesBeforePublishingLatestResult() async throws {
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        var results: [AudioSessionActivationController.Result] = []
        owner.onResult = { results.append($0) }
        try owner.request(active: true)
        try await wait { driver.pending != nil }
        let paused = try owner.request(active: false)
        driver.complete()
        try await wait { driver.requests == [true, false] }
        #expect(results.isEmpty)
        driver.complete()
        try await wait { results.count == 1 }
        #expect(results[0].requestID == paused && !results[0].active && results[0].outcome == .applied)
        #expect(owner.knownActive == false)
        owner.close()
    }

    @Test func newerPlayUsesCompletedActivationWithoutDuplicatingOSOperation() async throws {
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        var results: [AudioSessionActivationController.Result] = []
        owner.onResult = { results.append($0) }
        try owner.request(active: true); try await wait { driver.pending != nil }
        try owner.request(active: false)
        let latest = try owner.request(active: true)
        driver.complete(); try await wait { results.count == 1 }
        #expect(driver.requests == [true] && results[0].requestID == latest && results[0].active)
        let off = try owner.request(active: false)
        try await wait { driver.pending != nil }; driver.complete()
        try await wait { results.count == 2 }
        #expect(results[1].requestID == off)
        owner.close()
    }

    @Test(arguments: [false, true])
    func failureAndDenialAreNotActivationSuccess(throwsError: Bool) async throws {
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        var results: [AudioSessionActivationController.Result] = []
        owner.onResult = { results.append($0) }
        let first = try owner.request(active: true); try await wait { driver.pending != nil }
        if throwsError { driver.fail() } else { driver.complete(false) }
        try await wait { results.count == 1 }
        #expect(results[0].requestID == first && results[0].outcome == (throwsError ? .failed : .declined))
        #expect(owner.knownActive == nil)
        let retry = try owner.request(active: false)
        try await wait { driver.pending != nil }; driver.complete()
        try await wait { results.count == 2 }
        #expect(results[1].requestID == retry && results[1].outcome == .applied)
        owner.close()
    }

    @Test func ownerReleaseCompensatesPendingActivationWithoutStaleCallback() async throws {
        let driver = Driver()
        var owner: AudioSessionActivationController? = AudioSessionActivationController(driver: driver)
        var calls = 0
        owner?.onResult = { _ in calls += 1 }
        try owner?.request(active: true); try await wait { driver.pending != nil }
        // Releasing the player while activation is pending deactivates the
        // session again (other audio can resume) without a stale callback.
        owner = nil
        driver.complete(); try await wait { driver.requests == [true, false] }
        driver.complete()
        await Task.yield()
        #expect(calls == 0)
    }

    @Test func unusedOwnerAndClosedRequestsHaveNoSystemEffects() async throws {
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        owner.close()
        #expect(throws: AudioSessionActivationController.Failure.closed) { try owner.request(active: true) }
        await Task.yield()
        #expect(driver.requests.isEmpty && driver.preparations == 0)
    }

    @Test func explicitlyClaimingAnAlreadyActiveSessionStillDeactivatesOnClose() async throws {
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        var applied = false
        owner.onResult = { applied = $0.outcome == .applied }
        owner.receive(.becameActive)
        try owner.request(active: true)
        try await wait { applied }
        #expect(driver.requests.isEmpty && driver.preparations == 1)
        owner.close()
        try await wait { driver.requests == [false] }
        driver.complete()
        await Task.yield()
    }

    @Test func typedInterruptionPreventsLateActivationFromOverwritingNewerSystemState() async throws {
        let center = NotificationCenter(); let subject = NSObject()
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        let source = AudioSessionEventSource(center: center, subject: subject,
            names: AudioSessionEventSourceTests.names) { owner.receive($0) }
        source.observe(subject: subject, message: AudioSessionEventSourceTests.SystemFact.self) { $0.event }
        defer { source.close(); owner.close() }
        var results: [AudioSessionActivationController.Result] = []
        owner.onResult = { results.append($0) }
        try owner.request(active: true); try await wait { driver.pending != nil }
        center.post(AudioSessionEventSourceTests.SystemFact(event: .becameActive), subject: subject)
        center.post(AudioSessionEventSourceTests.SystemFact(event: .interrupted(reason: 0)), subject: subject)
        driver.complete()
        try await wait { results.count == 1 }
        #expect(results[0].outcome == .declined && owner.knownActive == false)
        center.post(AudioSessionEventSourceTests.SystemFact(event: .resumptionRecommended(true)), subject: subject)
        #expect(owner.knownActive == false && driver.requests == [true])
        let resumed = try owner.request(active: true)
        try await wait { driver.requests == [true, true] }
        driver.complete(); try await wait { results.count == 2 }
        #expect(results[1].requestID == resumed && results[1].outcome == .applied)
        try owner.request(active: false); try await wait { driver.pending != nil }
        driver.complete(); try await wait { results.count == 3 }
    }

    @Test func staleRequestFailureStillReconcilesLatestIntent() async throws {
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        var results: [AudioSessionActivationController.Result] = []
        owner.onResult = { results.append($0) }
        try owner.request(active: true); try await wait { driver.pending != nil }
        let paused = try owner.request(active: false)
        driver.fail(); try await wait { driver.requests == [true, false] }
        #expect(results.isEmpty)
        driver.complete(); try await wait { results.count == 1 }
        #expect(results[0].requestID == paused && results[0].outcome == .applied)
        owner.close()
    }

    @Test func mediaServicesLossInvalidatesCacheWithoutInventingActivation() async throws {
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        var results: [AudioSessionActivationController.Result] = []
        owner.onResult = { results.append($0) }
        try owner.request(active: true); try await wait { driver.pending != nil }
        owner.receive(.mediaServicesLost)
        driver.complete(); try await wait { results.count == 1 }
        #expect(owner.knownActive == nil && results[0].outcome == .declined)
        owner.receive(.mediaServicesReset)
        #expect(driver.requests == [true] && owner.knownActive == nil)
        try owner.request(active: false); try await wait { driver.pending != nil }
        driver.complete(); try await wait { results.count == 2 }
        owner.close()
    }

    @Test func callbackCanRequestDeactivationWithoutLostWorkOrParallelCalls() async throws {
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        var results: [Bool] = []
        owner.onResult = { [weak owner] result in
            results.append(result.active)
            if result.active { _ = try? owner?.request(active: false) }
        }
        try owner.request(active: true); try await wait { driver.pending != nil }
        driver.complete(); try await wait { driver.requests == [true, false] }
        driver.complete(); try await wait { results == [true, false] }
        owner.close()
    }

    @Test(arguments: [false, true])
    func configurationFailureCannotActivateOrBypassAnAlreadyActiveSession(alreadyActive: Bool) async throws {
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        if alreadyActive { owner.receive(.becameActive) }
        driver.configure = { throw Problem.rejected }
        var results: [AudioSessionActivationController.Result] = []
        owner.onResult = { results.append($0) }
        let request = try owner.request(active: true)
        try await wait { results.count == 1 }
        #expect(results[0].requestID == request && results[0].outcome == .failed)
        #expect(results[0].error as? Problem == .rejected && driver.requests.isEmpty)
        #expect(driver.preparations == 1 && owner.knownActive == (alreadyActive ? true : nil))
        driver.configure = nil
        try owner.request(active: true)
        if !alreadyActive { try await wait { driver.pending != nil }; driver.complete() }
        try await wait { results.count == 2 }
        #expect(results[1].outcome == .applied && driver.preparations == 2)
        try owner.request(active: false); try await wait { driver.pending != nil }; driver.complete()
        try await wait { results.count == 3 }
        #expect(driver.preparations == 2)
        owner.close()
    }

    @Test(arguments: [false, true])
    func configurationCannotActivateAfterSynchronousPauseOrOwnerClose(close: Bool) async throws {
        let driver = Driver(); let owner = AudioSessionActivationController(driver: driver)
        var results: [AudioSessionActivationController.Result] = []
        owner.onResult = { results.append($0) }
        driver.configure = { [weak owner] in
            if close { owner?.close() } else { try owner?.request(active: false) }
        }
        try owner.request(active: true)
        try await wait { driver.preparations == 1 }
        if close {
            #expect(driver.requests.isEmpty && results.isEmpty)
        } else {
            try await wait { driver.pending != nil }
            #expect(driver.requests == [false] && results.isEmpty)
            driver.complete(); try await wait { results.count == 1 }
            #expect(!results[0].active && results[0].outcome == .applied)
        }
        owner.close()
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}

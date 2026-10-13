import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor
struct FeedURLConfirmationCountdownTests {
    @Test func originalIntegerCountdownBoundariesAndLocalizedLabels() {
        for (milliseconds, expected) in [(-1, 0), (0, 0), (1, 1), (999, 1), (1000, 2), (1001, 2), (14999, 15), (15000, 16)] {
            let state = FeedURLConfirmationCountdown.state(remaining: .milliseconds(milliseconds))
            #expect(state == (expected == 0 ? .ready : .waiting(expected)))
            #expect(state.canConfirm == (milliseconds <= 0))
        }
        #expect(FeedURLConfirmationCountdown.State.waiting(15).title(ok: "OK", locale: Locale(identifier: "en-US")) == "OK (15)")
        #expect(FeedURLConfirmationCountdown.State.waiting(15).title(ok: "حسنًا", locale: Locale(identifier: "ar-EG")) == "حسنًا (١٥)")
        #expect(FeedURLConfirmationCountdown.State.ready.title(ok: "OK") == "OK")
        #expect(!FeedURLConfirmationCountdown.State.idle.canConfirm)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await condition())
    }
    @Test func delayedTicksFollowDeadlineRatherThanNumberOfCallbacks() async throws {
        let time = ConfirmationTestTime(), gate = ConfirmationSleepGate()
        let countdown = FeedURLConfirmationCountdown(now: { time.now }, sleep: { await gate.sleep($0) })
        let task = countdown.start()
        try await waitUntil { await gate.count == 1 }
        #expect(countdown.state == .waiting(16))
        time.now = .milliseconds(1); await gate.resume(0)
        try await waitUntil { await gate.count == 2 }
        #expect(countdown.state == .waiting(15))
        time.now = .milliseconds(14999); await gate.resume(1)
        try await waitUntil { await gate.count == 3 }
        #expect(countdown.state == .waiting(1) && !countdown.state.canConfirm)
        #expect(await gate.delays == [.seconds(1), .seconds(1), .milliseconds(1)])
        time.now = .seconds(15); await gate.resume(2); await task.value
        #expect(countdown.state == .ready)
        let resumed = countdown.start()
        #expect(countdown.state == .idle && !countdown.state.canConfirm)
        try await waitUntil { await gate.count == 4 }
        time.now = .seconds(100); await gate.resume(3); await resumed.value
        #expect(countdown.state == .ready)
    }
    /// Reopening the dialog restarts the full 15 s wait, and an earlier dialog's timer cannot enable OK;
    /// closing it leaves OK disabled.
    @Test func reopeningRestartsTheWaitAndClosingLeavesOKDisabled() async throws {
        let time = ConfirmationTestTime(), gate = ConfirmationSleepGate()
        let countdown = FeedURLConfirmationCountdown(now: { time.now }, sleep: { await gate.sleep($0) })
        let first = countdown.start()
        try await waitUntil { await gate.count == 1 }
        time.now = .seconds(5)
        let second = countdown.start()
        try await waitUntil { await gate.count == 2 }
        time.now = .seconds(15); await gate.resume(0); await first.value
        #expect(countdown.state == .waiting(16) && !countdown.state.canConfirm)
        countdown.cancel(); await gate.resume(1); await second.value
        #expect(countdown.state == .idle && !countdown.state.canConfirm)
    }
}

@MainActor private final class ConfirmationTestTime { var now: Duration = .zero }
private actor ConfirmationSleepGate {
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var delays: [Duration] = []
    var count: Int { delays.count }
    func sleep(_ delay: Duration) async {
        let id = delays.count; delays.append(delay)
        await withCheckedContinuation { continuations[id] = $0 }
    }
    func resume(_ id: Int) { continuations.removeValue(forKey: id)?.resume() }
}

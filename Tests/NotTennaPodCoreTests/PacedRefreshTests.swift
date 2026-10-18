import Foundation
import Testing
@testable import NotTennaPodCore

/// The Download Log's reads while downloads and refreshes change it: at most one per interval while shown, none while
/// hidden, and one final read after the last change.
@MainActor @Suite(.serialized) struct PacedRefreshTests {
    final class Counter { var reads = 0; var running = false }

    func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition(), "\(label)")
    }

    @Test func burstsAreReadAtMostOncePerIntervalAndOnceAfterTheLast() async throws {
        let counter = Counter()
        let refresh = PacedRefresh(interval: .milliseconds(100)) { counter.reads += 1 }
        let start = ContinuousClock.now
        // 300 changes over about 300 ms.
        for _ in 0..<300 {
            refresh.changed()
            try await Task.sleep(for: .milliseconds(1))
        }
        let elapsed = start.duration(to: .now)
        let allowed = Int(elapsed / .milliseconds(100)) + 2
        #expect(counter.reads <= allowed, "\(counter.reads) reads in \(elapsed)")
        // The last change is read once the interval passes.
        let before = counter.reads
        try await wait("the final read") { counter.reads == before + 1 }
        try await Task.sleep(for: .milliseconds(250))
        #expect(counter.reads == before + 1, "nothing more without a change")
    }

    @Test func nothingIsReadWhileHiddenAndOnceOnReturn() async throws {
        let counter = Counter()
        var shown = false
        let refresh = PacedRefresh(interval: .milliseconds(50)) { counter.reads += 1 }
        refresh.isActive = { shown }
        for _ in 0..<20 { refresh.changed(); try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .milliseconds(120))
        #expect(counter.reads == 0, "hidden: no read")
        shown = true
        refresh.activate()
        try await wait("one read on return") { counter.reads == 1 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(counter.reads == 1)
    }
}

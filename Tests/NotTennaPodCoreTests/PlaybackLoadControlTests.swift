import Foundation
import Testing
@testable import NotTennaPodCore

struct PlaybackLoadControlTests {
    private struct Oracle: Decodable {
        let retry: [Retry]
        let recovery: [Recovery]
    }
    private struct Retry: Decodable {
        let cause: PlaybackLoadRetryPolicy.Cause
        let count: Int
        let nested: Bool
        let delay: Int64?
        let finiteMinimum, liveMinimum: Int
    }
    private struct Recovery: Decodable {
        let length, duration, prepared, suppressed, discontinuity: Bool
        let action: String
    }
    private func oracle() throws -> Oracle {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "stream-loading-oracle", withExtension: "json", subdirectory: "Fixtures"))
#else
        let url = try #require(Bundle(for: PlaybackLoadFixtures.self).url(forResource: "stream-loading-oracle", withExtension: "json"))
#endif
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    @Test func originalJavaRetryDelaysNestedCausesAndProgressiveRecovery() throws {
        let reference = try oracle()
        #expect(reference.retry.count == 168 && reference.recovery.count == 16)
        for row in reference.retry {
            let causes: [PlaybackLoadRetryPolicy.Cause] = row.nested ? [.network, row.cause] : [row.cause]
            #expect(try PlaybackLoadRetryPolicy.retryDelayMilliseconds(errorCount: row.count, causes: causes) == row.delay)
            #expect(PlaybackLoadRetryPolicy.minimumRetryCount(progressiveLive: false) == row.finiteMinimum)
            #expect(PlaybackLoadRetryPolicy.minimumRetryCount(progressiveLive: true) == row.liveMinimum)
            #expect(PlaybackLoadRetryPolicy.mayThrowCurrentError(errorCount: row.count, progressiveLive: false) == (row.count > row.finiteMinimum))
            #expect(PlaybackLoadRetryPolicy.mayThrowCurrentError(errorCount: row.count, progressiveLive: true) == (row.count > row.liveMinimum))
        }
        for row in reference.recovery {
            let result = PlaybackLoadRetryPolicy.recovery(lengthKnown: row.length, durationKnown: row.duration,
                prepared: row.prepared, readSuppressed: row.suppressed)
            switch row.action {
            case "resume": #expect(result == .resumeCurrentPosition)
            case "defer": #expect(result == .deferUntilSamplesExhausted)
            case "restart": #expect(result == .restartAtZero(notifyDiscontinuity: row.discontinuity))
            default: Issue.record("Unknown original retry decision")
            }
        }
    }
}

private final class PlaybackLoadFixtures: NSObject {}

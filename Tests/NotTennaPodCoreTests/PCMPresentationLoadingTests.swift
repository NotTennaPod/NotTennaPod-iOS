import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor
struct PCMPresentationLoadingTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    private enum Failure: Error { case deadline, playbackDeadline(reached: Int64, target: Int64) }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func state(_ position: Int64, _ speed: Float = 1) throws -> PCMPlaybackLoadState {
        try PCMPlaybackLoadState(positionMicroseconds: position, speed: speed)
    }

    @Test func loadingErrorStopsPlaybackAndReportsItsCause() async throws {
        let decoder = Decoder(), transport = Transport()
        let session = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoder,
            skipSilence: false, maximumOutputFrames: 127), transport: transport)
        defer { session.close() }
        try await session.prepare()
        try await wait { await decoder.updates.count == 1 }
        await decoder.failUpdates(URLError(.timedOut))
        try session.play(); transport.advance(64)
        try await wait { session.failure != nil }
        #expect((session.failure as? URLError)?.code == .timedOut)
        #expect(session.state == .failed && transport.closed)
        try await wait { await decoder.cancelled }
    }

    @Test func longEpisodeKeepsLoadingAndPlayingPastTheMemoryBudget() async throws {
        let url = try #require(Bundle.module.url(forResource: "long-opus", withExtension: "webm", subdirectory: "Fixtures/PacketProducer"))
        // A small target forces retention to block loading before the five-minute
        // back-buffer window expires. The half-second safeguard must free it.
        let decoder = try await FFmpegPCMDecoder.openBuffered(url: url, maximumFrames: 65_536, targetBytes: 2 * 65_536)
        let transport = ClockTransport()
        let session = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoder,
            skipSilence: false, maximumOutputFrames: 65_536), transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare()
        try await wait { await decoder.producerSnapshot()?.waitingForBudget == true }
        let initial = try #require(await decoder.producerSnapshot())
        let end = try #require(initial.bufferedThroughMicroseconds)
        #expect(end < 300_000_000 && initial.playbackPositionMicroseconds == 0)
        let target = end + 5_000_000
        try session.play()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while (try session.mediaMicroseconds ?? 0) < target {
            guard ContinuousClock.now < deadline else { throw Failure.playbackDeadline(reached: (try? session.mediaMicroseconds) ?? -1, target: target) }
            if let error = session.failure { throw error }
            if session.state == .playing { transport.advance(session.writtenFrames) }
            await Task.yield()
        }
        try session.pause()
        let presented = try #require(try session.mediaMicroseconds)
        try await wait { await decoder.producerSnapshot()?.playbackPositionMicroseconds == presented }
        #expect(presented >= target && session.failure == nil)
        let final = try #require(await decoder.producerSnapshot())
        #expect(try #require(final.bufferedThroughMicroseconds) > end)
    }

    /// Real-time sufficiency where loading resumes past the memory budget, with production
    /// pipeline sizes (4096-frame decoder/output packets, four queued output buffers). The
    /// transport first runs ahead of real time to just before the point where the budget
    /// stopped loading, then plays in wall-clock time like the audio hardware: any time it runs
    /// out of written audio is a gap a listener would hear. 4× is the fastest offered speed.
    @Test(arguments: [Float(1), 4])
    func pastTheMemoryBudgetLoadingKeepsUpWithRealTimePlayback(speed: Float) async throws {
        let url = try #require(Bundle.module.url(forResource: "long-opus", withExtension: "webm", subdirectory: "Fixtures/PacketProducer"))
        let decoder = try await FFmpegPCMDecoder.openBuffered(url: url, targetBytes: 2 * 65_536)
        let transport = ClockTransport()
        let session = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoder,
            skipSilence: false, speed: speed), transport: transport)
        defer { session.close() }
        try await session.prepare()
        try await wait { await decoder.producerSnapshot()?.waitingForBudget == true }
        let budgetSnapshot = try #require(await decoder.producerSnapshot())
        let end = try #require(budgetSnapshot.bufferedThroughMicroseconds)
        try session.play()
        // Fast-forward to three seconds before the budget stopped loading.
        let fastDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        while (try session.mediaMicroseconds ?? 0) < end - 3_000_000 {
            guard ContinuousClock.now < fastDeadline else { throw Failure.playbackDeadline(reached: (try? session.mediaMicroseconds) ?? -1, target: end) }
            if let error = session.failure { throw error }
            if session.state == .playing { transport.advance(session.writtenFrames) }
            await Task.yield()
        }
        // Then play ten seconds of wall-clock time across the budget point.
        let base = session.presentedFrames, start = ContinuousClock.now
        var starved: Duration = .zero, last = start
        while start.duration(to: .now) < .seconds(10) {
            if let error = session.failure { throw error }
            let now = ContinuousClock.now, elapsed = start.duration(to: now)
            let due = base + Int64(Double(elapsed.components.seconds) * 48_000 + Double(elapsed.components.attoseconds) * 48_000 / 1e18)
            // The hardware can only play what was written; a shortfall is silence.
            if due > session.writtenFrames { starved += last.duration(to: now) }
            last = now
            if session.state == .playing || session.state == .buffering { transport.advance(min(due, session.writtenFrames)) }
            try await Task.sleep(for: .milliseconds(5))
        }
        let reached = try #require(try session.mediaMicroseconds)
        #expect(reached > end + Int64(Double(speed) * 5_000_000), "playback reached \(reached) µs; loading had stopped at \(end) µs")
        // Allow scheduling jitter; an audible gap or a stall is far larger.
        #expect(starved < .milliseconds(150), "audio ran out for \(starved) around the memory budget")
        #expect(session.failure == nil)
    }

    private actor Decoder: PCMDecoding {
        nonisolated let sampleRate = 48_000, channels = 1
        nonisolated let startFrame: Int64 = 0
        private var frames: Int64 = 0
        private(set) var updates: [PCMPlaybackLoadState] = []
        private(set) var started: [PCMPlaybackLoadState] = []
        private(set) var cancelled = false
        var waiting: Bool { pending != nil }
        private var hold: Bool
        private var pending: CheckedContinuation<Void, any Error>?
        private var failure: (any Error)?
        init(hold: Bool = false) { self.hold = hold }
        func next() throws -> NativePCMDecoder.Packet? {
            guard !cancelled else { throw CancellationError() }
            defer { frames += 4096 }
            return .init(samples: Array(repeating: 1000, count: 4096), sampleRate: sampleRate, channels: channels,
                         presentationTime: CMTime(value: frames, timescale: 48_000))
        }
        func updatePlayback(_ state: PCMPlaybackLoadState) async throws {
            started.append(state)
            if hold {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { pending = $0 }
                } onCancel: { Task { await self.release(cancel: true) } }
            }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            if let failure { throw failure }
            updates.append(state)
        }
        func failUpdates(_ error: any Error) { failure = error }
        func release(cancel: Bool = false) {
            hold = false
            if cancel { pending?.resume(throwing: CancellationError()) } else { pending?.resume() }
            pending = nil
        }
        func cancel() { cancelled = true; release(cancel: true) }
    }

    /// Do not retain every rendered buffer during the long virtual-clock journey.
    private final class ClockTransport: PCMPresentationTransport {
        var currentTime = CMTime.zero
        var onTimeChanged: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {}
        func setPlaying(_ playing: Bool, at time: CMTime) { currentTime = time }
        func observeEnd(_ time: CMTime) {}
        func finishEnqueuing() {}
        func stopMonitoring() {}
        func close() {}
        func advance(_ frame: Int64) { currentTime = CMTime(value: frame, timescale: 48000); onTimeChanged?() }
    }
}

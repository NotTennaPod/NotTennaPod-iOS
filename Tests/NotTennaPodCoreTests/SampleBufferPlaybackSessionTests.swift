import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor struct SampleBufferPlaybackSessionTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport

    private func drain(_ session: SampleBufferPlaybackSession, _ transport: Transport) async throws {
        var progressDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var previous = (session.writtenFrames, session.presentedFrames)
        while session.state != .ended {
            try Task.checkCancellation()
            if let failure = session.failure { throw failure }
            if session.state == .playing { transport.advance(session.writtenFrames) }
            let current = (session.writtenFrames, session.presentedFrames)
            if current != previous {
                progressDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                previous = current
            }
            try #require(ContinuousClock.now <= progressDeadline, "PCM drain stalled before EOF")
            await Task.yield()
        }
        try #require(session.state == .ended)
    }

    private func payload(_ transport: Transport) throws -> Data {
        try transport.buffers.reduce(into: Data()) {
            $0.append(try #require($1.content.withContiguousStorageIfAvailable { Data($0) }))
        }
    }

    @Test func EOFAndPausedMediaTimeFollowPresentationInsteadOfDecoder() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: false, maximumOutputFrames: 65536)
        let t = Transport()
        let session = try SampleBufferPlaybackSession(stream: stream, transport: t, maximumQueuedBuffers: 2)
        defer { session.close() }
        var endings = 0
        session.onChange = { [weak session] in if session?.state == .ended { endings += 1 } }
        try await session.prepare()
        #expect(session.sourceEnded && session.state == .paused)
        #expect(try session.mediaMicroseconds == 0)
        try session.play(); t.advance(14400); try session.pause()
        #expect(try session.mediaMicroseconds == 300_000)
        t.advance(28800)
        #expect(try session.mediaMicroseconds == 300_000)
        #expect(endings == 0)
        try session.play(); try await drain(session, t)
        #expect(try session.mediaMicroseconds == 600_000)
        #expect(endings == 1 && session.presentedFrames == 28800)
        #expect(try payload(t) == input.withUnsafeBytes { Data($0) })
    }

    @Test(arguments: [127, 256, 257], [2, 3, 4])
    func liveSpeedChangeTakesEffectWithoutTimelineGaps(capacity: Int, queueSize: Int) async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: false, maximumOutputFrames: capacity)
        let t = Transport()
        let session = try SampleBufferPlaybackSession(stream: stream, transport: t, maximumQueuedBuffers: queueSize)
        defer { session.close() }
        try await session.prepare(); try session.play()
        t.advance(Int64(capacity / 2)); try session.pause()
        let frozen = try session.mediaMicroseconds
        try await session.setParameters(speed: 2, skipSilence: true)
        #expect(try session.mediaMicroseconds == frozen)
        try session.play(); try await drain(session, t)
        // The change takes effect: after the change the audio is silence-skipped and played at 2x,
        // so the presented duration matches that processing chain within 10 ms. Exact samples and
        // packet boundaries are not compared.
        var silence = try SilenceSkippingProcessor(sampleRate: 48000, channels: 2)
        var speed = try PCMSpeedProcessor(sampleRate: 48000, channels: 2, speed: 2)
        var expected = Array(input.prefix(8192)) // First decoded packet predates the change.
        for offset in stride(from: 8192, to: input.count, by: 8192) {
            expected += try speed.process(silence.process(Array(input[offset..<min(input.count, offset + 8192)])))
        }
        expected += try speed.process(silence.finish())
        expected += speed.finish()
        let played = try payload(t).count / 4
        #expect(abs(played - expected.count / 2) <= 480)
        #expect(played < input.count / 2 * 3 / 4) // Clearly shorter than the unprocessed audio.
        #expect(session.presentedFrames == Int64(played))
        #expect(session.failure == nil)
        // No gaps or overlaps in the presentation timeline.
        var end = CMTime.zero
        for buffer in t.buffers {
            #expect(buffer.presentationTimeStamp == end)
            end = end + buffer.duration
        }
    }

    @Test func blockedDecodeFreezesMediaTimeAndRecoversWithoutLostPCM() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let decoder = try GateDecoder(url: url, blockOnRead: 3)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, maximumOutputFrames: 4096)
        let t = Transport(); let session = try SampleBufferPlaybackSession(stream: stream, transport: t, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare(); try session.play()
        t.advance(4096); await decoder.waitUntilBlocked(); t.advance(8192)
        #expect(session.state == .buffering && session.presentedFrames == 8192)
        #expect(try session.mediaMicroseconds == 170_666)
        t.advance(99999)
        #expect(try session.mediaMicroseconds == 170_666)
        await decoder.release(); try await drain(session, t)
        #expect(try payload(t) == input.withUnsafeBytes { Data($0) })
        #expect(try session.mediaMicroseconds == 600_000)
    }

    @Test func cachedDecodeGapDoesNotCommitOutstandingNetworkError() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let retry = PCMSourceRetry(), error = URLError(.networkConnectionLost)
        retry.recordSamples(100, durationKnown: true)
        for _ in 0..<4 { _ = try retry.plan(for: error, lengthKnown: true) }
        let source = PCMBufferState(.init(bufferedThroughMicroseconds: 600_000,
            allocatedBytes: Int64(input.count * 2), targetBytes: PlaybackLoadControl.audioTargetBytes,
            isLoading: true, isFinalBuffered: false), sourceRetry: retry)
        let decoder = try GateDecoder(url: url, blockOnRead: 3, bufferState: source)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, maximumOutputFrames: 4096)
        let t = Transport(); let session = try SampleBufferPlaybackSession(stream: stream, transport: t, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare(); try session.play()
        t.advance(4096); await decoder.waitUntilBlocked()
        // Cached parsing is temporarily behind the consumer; upstream is not dry.
        var state = source.snapshot
        state.isWaitingForSamples = true; state.isWaitingForSource = false
        source.update(state)
        t.advance(8192)
        #expect(session.state == .buffering && retry.committedError == nil && session.failure == nil)
        state.isWaitingForSamples = false; source.update(state)
        await decoder.release(); try await drain(session, t)
        #expect(try payload(t) == input.withUnsafeBytes { Data($0) })
        #expect(retry.committedError == nil)
    }
    @Test(arguments: [false, true])
    func closeOrCancelPrimeReleasesBlockedDecoder(cancel: Bool) async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let decoder = try GateDecoder(url: url, blockOnRead: 1)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false)
        let t = Transport(); let session = try SampleBufferPlaybackSession(stream: stream, transport: t)
        let task = Task { try await session.prepare() }
        await decoder.waitUntilBlocked()
        if cancel { task.cancel() } else { session.close() }
        await #expect(throws: NativePCMDecoder.Failure.cancelled) { try await task.value }
        #expect(session.state == .closed && t.closed && t.buffers.isEmpty)
    }

    @Test func seekReplacementUsesNewMediaAnchorAndNoOldCallbacks() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let t = Transport()
        let first = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(url: url, skipSilence: false), transport: t)
        try await first.prepare(); try first.play()
        let stale = t.onTimeChanged
        first.close()
        let replacementTransport = Transport()
        let replacement = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(url: url,
            start: CMTime(value: 14400, timescale: 48000), skipSilence: false), transport: replacementTransport)
        defer { replacement.close() }
        try await replacement.prepare()
        #expect(try replacement.mediaMicroseconds == 300_000)
        stale?(); #expect(first.state == .closed && replacement.presentedFrames == 0)
        try replacement.play(); try await drain(replacement, replacementTransport)
        #expect(try replacement.mediaMicroseconds == 600_000)
        #expect(try payload(replacementTransport) == Array(input.dropFirst(28800)).withUnsafeBytes { Data($0) })
    }

    @Test func observerCanCloseDuringStartWithoutDecodedSideEffects() throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let t = Transport()
        let session = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(url: url, skipSilence: false), transport: t)
        session.onChange = { [weak session] in if session?.state == .buffering { session?.close() } }
        try session.play()
        #expect(session.state == .closed && t.buffers.isEmpty)
    }
}

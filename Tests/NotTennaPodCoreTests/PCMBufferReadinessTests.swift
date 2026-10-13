import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct PCMBufferReadinessTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    private enum Failure: Error { case deadline }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func state(_ through: Int64, loading: Bool = true, final: Bool = false, bytes: Int64 = 0) -> PCMBufferState.Snapshot {
        .init(bufferedThroughMicroseconds: through, allocatedBytes: bytes,
              targetBytes: PlaybackLoadControl.audioTargetBytes, isLoading: loading, isFinalBuffered: final)
    }
    private func session(_ decoder: Decoder, _ transport: Transport) throws -> SampleBufferPlaybackSession {
        try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoder, skipSilence: false,
            maximumOutputFrames: 127), transport: transport, maximumQueuedBuffers: 2)
    }

    @Test func startupShowsBufferingUntilAboutASecondIsLoaded() async throws {
        let decoder = Decoder(), transport = Transport(), session = try session(decoder, transport)
        defer { session.close() }
        decoder.bufferState?.update(state(500_000))
        try await session.prepare()
        try session.play()
        #expect(session.state == .buffering && session.wantsPlayback && !transport.playing)
        decoder.bufferState?.update(state(1_500_000))
        try await wait { session.state == .playing }
        #expect(transport.playing)
        decoder.bufferState?.update(state(0))
        try session.output.refreshReadiness()
        #expect(session.state == .playing) // Shrinking data does not prematurely stop queued audio.
    }

    @Test func rebufferingWaitsForAboutTwoSecondsAndRepeatedPlayDoesNotResetIt() async throws {
        let decoder = Decoder(), transport = Transport(), session = try session(decoder, transport)
        defer { session.close() }
        decoder.bufferState?.update(state(1_000_000))
        try await session.prepare(); try session.play()
        transport.advance(session.writtenFrames)
        #expect(session.state == .buffering && session.output.isRebuffering)
        try await wait { session.output.availableBufferCount == 0 }
        let position = try #require(try session.mediaMicroseconds)
        decoder.bufferState?.update(state(position + 1_000_000))
        try session.output.refreshReadiness(); try session.play()
        #expect(session.state == .buffering && session.output.isRebuffering)
        decoder.bufferState?.update(state(position + 2_500_000))
        try await wait { session.state == .playing }
        #expect(!session.output.isRebuffering)
    }

    @Test func pauseDuringRebufferingPreservesIntentAndResetsTheThreshold() async throws {
        let decoder = Decoder(), transport = Transport(), session = try session(decoder, transport)
        defer { session.close() }
        decoder.bufferState?.update(state(1_000_000))
        try await session.prepare(); try session.play()
        transport.advance(session.writtenFrames)
        try await wait { session.output.availableBufferCount == 0 }
        #expect(session.output.isRebuffering)
        try session.pause()
        let position = try #require(try session.mediaMicroseconds)
        decoder.bufferState?.update(state(position + 1_500_000))
        try session.output.refreshReadiness()
        #expect(session.state == .paused && !transport.playing && !session.output.isRebuffering)
        try session.play()
        #expect(session.state == .playing)
    }

    @Test func acceptedSpeedChangesReadinessWithoutMovingPausedPresentation() async throws {
        let decoder = Decoder(), transport = Transport(), session = try session(decoder, transport)
        defer { session.close() }
        decoder.bufferState?.update(state(1_000_000))
        try await session.setParameters(speed: 2, skipSilence: false)
        try await session.prepare(); try session.play()
        #expect(session.state == .buffering)
        try await session.setParameters(speed: 1, skipSilence: false)
        #expect(session.state == .playing && session.presentedFrames == 0)
        #expect(try session.mediaMicroseconds == 0)
    }

    @Test(arguments: [false, true])
    func stoppedLoadingOrFinalBufferBypassesThresholdButNeverPause(final: Bool) async throws {
        let decoder = Decoder(), transport = Transport(), session = try session(decoder, transport)
        defer { session.close() }
        try await session.prepare()
        decoder.bufferState?.update(state(20_000, loading: final, final: final))
        try session.output.refreshReadiness()
        #expect(session.state == .paused && !transport.playing)
        try session.play()
        #expect(session.state == .playing)
    }

    @Test func closedWaitingSessionNeverStartsPlayingLater() async throws {
        let decoder = Decoder(), transport = Transport()
        var session: SampleBufferPlaybackSession? = try session(decoder, transport)
        try await session?.prepare(); try session?.play()
        #expect(session?.state == .buffering)
        session = nil
        #expect(transport.closed)
        try await wait { decoder.bufferState?.subscriberCount == 0 }
        decoder.bufferState?.update(state(5_000_000))
        #expect(!transport.playing)
    }

    @Test func realShortCompletedCodecStreamStartsWithoutOneSecondOfAudio() async throws {
        let url = try #require(Bundle.module.url(forResource: "short-opus", withExtension: "webm", subdirectory: "Fixtures/BufferReadiness"))
        let decoder = try await FFmpegPCMDecoder.openBuffered(url: url)
        let transport = Transport()
        let session = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoder,
            skipSilence: false, maximumOutputFrames: 4096), transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare()
        let signal = try #require(decoder.bufferState)
        try await wait { signal.snapshot.isFinalBuffered }
        #expect(try #require(signal.snapshot.bufferedThroughMicroseconds) < 1_000_000)
        try session.play()
        #expect(session.state == .playing)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.state != .ended {
            if let error = session.failure { throw error }
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            if session.state == .playing { transport.advance(session.writtenFrames) }
            await Task.yield()
        }
        #expect(session.writtenFrames > 0 && session.writtenFrames < 48_000)
    }

    @Test func realHTTPStartupAndRebufferWaitAfterPreparingFromHalfSecondPrefix() async throws {
        let url = try #require(Bundle.module.url(forResource: "tone-opus", withExtension: "webm", subdirectory: "Fixtures/StreamingFormats"))
        let data = try Data(contentsOf: url)
        let demux = try FFmpegDemuxContext(url: url)
        var prefix: Int?, release: Int?, rebuffer: Int?
        while let packet = try demux.next() {
            let time = CMTime(value: packet.presentationTimestamp * Int64(demux.timeBase.num), timescale: demux.timeBase.den)
            if prefix == nil, time >= CMTime(value: 500, timescale: 1000) { prefix = Int(packet.snapshot().position) }
            if release == nil, time >= CMTime(value: 1200, timescale: 1000) { release = Int(packet.snapshot().position) }
            if time >= CMTime(value: 2400, timescale: 1000) { rebuffer = Int(packet.snapshot().position); break }
        }
        let initialEnd = try #require(prefix), readyEnd = try #require(release)
        let rebufferEnd = try #require(rebuffer)
        #expect(initialEnd > 0 && readyEnd > initialEnd && readyEnd < data.count)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(initialEnd), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        var prepared = false
        let opening = Task {
            let decoder = try await FFmpegPCMDecoder.openBuffered(input: input, maximumFrames: 127)
            prepared = true
            return decoder
        }
        do { try await wait { prepared } }
        catch {
            print("Half-second preparation blocked: \(input.snapshot())")
            opening.cancel()
            _ = try? await opening.value
            throw error
        }
        let decoder = try await opening.value
        let transport = Transport()
        let session = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoder,
            skipSilence: false, maximumOutputFrames: 127), transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare(); try session.play()
        #expect(session.state == .buffering)
        let signal = try #require(decoder.bufferState)
        #expect(try #require(signal.snapshot.bufferedThroughMicroseconds) < 1_000_000)
        try await server.appendResponseBody(data[initialEnd..<readyEnd])
        try await wait { session.state == .playing }
        #expect(!input.snapshot().completed)
        transport.advance(session.writtenFrames)
        try await wait { session.output.availableBufferCount == 0 }
        #expect(session.state == .buffering && session.output.isRebuffering)
        try session.play()
        #expect(session.state == .buffering)
        try await server.appendResponseBody(data[readyEnd..<rebufferEnd])
        try await wait { session.state == .playing }
        #expect(!session.output.isRebuffering && !input.snapshot().completed)
        try session.pause()
        try await server.appendResponseBody(data[rebufferEnd...])
        try await wait { signal.snapshot.isFinalBuffered }
        #expect(session.state == .paused && !transport.playing)
    }

    /// After a stall the renderer waits for 0.5 s of audio (production threshold) before restarting.
    /// A final piece shorter than that must still play once the source ends, exactly once, and never
    /// override a pause. Tails: none, below, equal to and above the threshold (24000 frames).
    @Test(arguments: [0, 2400, 24_000, 36_000], [false, true])
    func finalPieceAfterStallPlaysOnceWhenTheSourceEnds(tail: Int, streaming: Bool) async throws {
        let decoder = TailDecoder(tail: tail, streaming: streaming), transport = Transport()
        let session = try await stalledTailSession(decoder, transport)
        defer { session.onChange = nil; session.close() }
        var endings = 0
        session.onChange = { if session.state == .ended { endings += 1 } }
        await decoder.release()
        try await wait { session.sourceEnded }
        #expect(session.writtenFrames == 49_152 + Int64(tail))
        if tail == 0 {
            #expect(session.state == .ended && !transport.playing)
        } else {
            #expect(session.state == .playing && transport.playing && session.wantsPlayback)
            transport.advance(session.writtenFrames)
            #expect(session.state == .ended && !transport.playing)
        }
        #expect(endings == 1 && session.presentedFrames == session.writtenFrames)
        session.output.refresh(); try session.output.refreshReadiness()
        #expect(endings == 1)
    }

    @Test(arguments: [2400, 36_000])
    func finalPieceAfterStallKeepsAPauseMadeWhileWaiting(tail: Int) async throws {
        let decoder = TailDecoder(tail: tail, streaming: false), transport = Transport()
        let session = try await stalledTailSession(decoder, transport)
        defer { session.onChange = nil; session.close() }
        var endings = 0
        session.onChange = { if session.state == .ended { endings += 1 } }
        try session.pause()
        await decoder.release()
        try await wait { session.sourceEnded }
        #expect(session.state == .paused && !transport.playing && !session.wantsPlayback && endings == 0)
        try session.play()
        #expect(session.state == .playing && transport.playing)
        transport.advance(session.writtenFrames)
        #expect(session.state == .ended && endings == 1)
    }

    @Test func sourceFailureAfterAShortFinalPieceIsAFailureNotACompletion() async throws {
        let decoder = TailDecoder(tail: 2400, streaming: false, failure: true), transport = Transport()
        let session = try await stalledTailSession(decoder, transport)
        defer { session.onChange = nil; session.close() }
        var endings = 0
        session.onChange = { if session.state == .ended { endings += 1 } }
        await decoder.release()
        try await wait { session.failure != nil }
        #expect(session.state == .failed && !session.sourceEnded && endings == 0)
        #expect(transport.closed && !transport.playing && !session.wantsPlayback)
    }

    /// An unknown-length stream fails after a stall: its decoder drains what it had and waits for the
    /// deferred restart (restart at zero). Less than the threshold remains: it plays now, without
    /// Pause/Play, then the restart is requested. A pause made while waiting is kept.
    @Test(arguments: [false, true])
    func shortPieceBeforeADeferredRestartPlaysThenTheRestartIsRequested(paused: Bool) async throws {
        let retry = PCMSourceRetry(sleep: { _ in })
        let decoder = TailDecoder(tail: 2400, streaming: true, retry: retry), transport = Transport()
        let session = try await stalledTailSession(decoder, transport)
        defer { session.onChange = nil; session.close() }
        if paused { try session.pause() }
        try Self.failLiveSource(retry)
        #expect(retry.requiresDeferredRestart)
        await decoder.release()
        try await wait { session.writtenFrames == 51_552 && session.output.inputDrained }
        #expect(!session.sourceEnded && !session.sourceRestartRequired && session.failure == nil)
        if paused {
            #expect(session.state == .paused && !transport.playing && !session.wantsPlayback)
            try session.play()
        }
        #expect(session.state == .playing && transport.playing)
        transport.advance(51_552)
        #expect(session.presentedFrames == 51_552 && session.sourceRestartRequired && session.wantsPlayback)
        #expect(session.failure == nil && session.state != .ended && !session.sourceEnded)
    }

    /// The same short piece before a retry that has already given up: it plays, then the error is
    /// reported as today (no completion, no restart).
    @Test func shortPieceBeforeAFailedRetryPlaysThenTheFailureIsReported() async throws {
        let retry = PCMSourceRetry(sleep: { _ in })
        let decoder = TailDecoder(tail: 2400, streaming: true, retry: retry), transport = Transport()
        let session = try await stalledTailSession(decoder, transport)
        defer { session.onChange = nil; session.close() }
        var endings = 0
        session.onChange = { if session.state == .ended { endings += 1 } }
        for _ in 0...PlaybackLoadRetryPolicy.minimumRetryCount(progressiveLive: false) {
            _ = try retry.plan(for: URLError(.networkConnectionLost), lengthKnown: true)
        }
        #expect(retry.commitErrorForDrain() && !retry.requiresDeferredRestart)
        await decoder.release()
        try await wait { session.writtenFrames == 51_552 && session.output.inputDrained }
        #expect(session.state == .playing && transport.playing && session.failure == nil)
        transport.advance(51_552)
        try await wait { session.failure != nil }
        #expect((session.failure as? URLError)?.code == .networkConnectionLost)
        #expect(session.state == .failed && !session.sourceEnded && !session.sourceRestartRequired && endings == 0)
    }

    /// After the short piece, the restart (as the engine performs it: a new generation at zero, keeping
    /// play intent) succeeds and buffers normally: it waits for about a second of audio, then plays.
    @Test func retryAfterTheShortPieceBuffersNormally() async throws {
        let retry = PCMSourceRetry(sleep: { _ in })
        let first = TailDecoder(tail: 2400, streaming: true, retry: retry), restarted = Decoder()
        var transports: [Transport] = []
        var decoders: [any PCMDecoding] = [first, restarted]
        let owner = PCMRecoverySession(parameters: .init(speed: 1, skipSilence: false),
            lastPlayedMilliseconds: { 0 }, synchronizeStatistics: {}) { _, _ in
                let transport = Transport(); transports.append(transport)
                return try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoders.removeFirst(), skipSilence: false),
                    transport: transport, maximumQueuedBuffers: 12, starvationResumeSeconds: 0.5)
            }
        defer { owner.close() }
        try await owner.seekPaused(to: 0)
        try owner.play()
        transports[0].advance(49_152)
        await first.waitUntilHeld()
        try Self.failLiveSource(retry)
        await first.release()
        try await wait { transports[0].playing }
        transports[0].advance(51_552)
        #expect(owner.sourceRestartRequired && owner.failure == nil)
        try await owner.seekPaused(to: 0)
        try owner.play()
        #expect(transports.count == 2 && transports[0].closed && owner.outputState == .buffering && !transports[1].playing)
        restarted.bufferState?.update(state(1_500_000))
        try await wait { owner.outputState == .playing && transports[1].playing }
        let position = try owner.positionMilliseconds
        #expect(!owner.sourceRestartRequired && position == 0)
    }

    /// Unknown length and duration, already prepared: the network failure defers the restart to zero
    /// until the decoded audio is used up, as `PlaybackLoadRetryPolicy` decides for a live stream.
    private static func failLiveSource(_ retry: PCMSourceRetry) throws {
        retry.recordSamples(4096, durationKnown: false)
        _ = try retry.plan(for: URLError(.networkConnectionLost), lengthKnown: false)
    }

    /// Production-sized queue (12 × 4096 frames at 48 kHz) prepared and played, then consumed while the
    /// decoder is held: the renderer runs dry before the source's final piece arrives.
    private func stalledTailSession(_ decoder: TailDecoder, _ transport: Transport) async throws -> SampleBufferPlaybackSession {
        let session = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoder, skipSilence: false),
            transport: transport, maximumQueuedBuffers: 12, starvationResumeSeconds: 0.5)
        try await session.prepare()
        #expect(session.writtenFrames == 49_152 && session.state == .paused)
        try session.play()
        transport.advance(49_152)
        await decoder.waitUntilHeld()
        #expect(session.state == .buffering && session.output.isRebuffering && !transport.playing)
        return session
    }

    private actor TailDecoder: PCMDecoding {
        nonisolated let sampleRate = 48_000, channels = 1
        nonisolated let startFrame: Int64 = 0
        /// Streaming sources have already announced their final buffered state, so no later
        /// source event rechecks readiness; local files have no source events at all.
        nonisolated let bufferState: PCMBufferState?
        private let tail: Int, failure: Bool
        private var written: Int64 = 0, held = false, released = false
        private var gate: CheckedContinuation<Void, Never>?, arrival: CheckedContinuation<Void, Never>?
        /// `retry`: a live stream of unknown length, still loading, whose producer drains (ends this
        /// generation) once its retry is deferred or has given up, as the native producers do.
        init(tail: Int, streaming: Bool, failure: Bool = false, retry: PCMSourceRetry? = nil) {
            self.tail = tail; self.failure = failure
            if let retry {
                var live = PCMBufferState.Snapshot(bufferedThroughMicroseconds: 5_000_000, allocatedBytes: 100,
                    targetBytes: PlaybackLoadControl.audioTargetBytes, isLoading: true, isFinalBuffered: false)
                live.sourceSeekable = false
                bufferState = PCMBufferState(live, sourceRetry: retry)
            } else {
                bufferState = streaming ? PCMBufferState(.init(bufferedThroughMicroseconds: 1_074_000, allocatedBytes: 100,
                    targetBytes: PlaybackLoadControl.audioTargetBytes, isLoading: false, isFinalBuffered: true)) : nil
            }
        }
        func next() async throws -> NativePCMDecoder.Packet? {
            if written == 49_152 && !released {
                held = true; arrival?.resume(); arrival = nil
                await withCheckedContinuation { gate = $0 }
            }
            let remaining = 49_152 + Int64(tail) - written
            guard remaining > 0 else {
                if failure { throw URLError(.networkConnectionLost) }
                return nil
            }
            let frames = Int(min(4096, remaining))
            defer { written += Int64(frames) }
            return .init(samples: [Int16](repeating: 1000, count: frames), sampleRate: sampleRate, channels: channels,
                presentationTime: CMTime(value: written, timescale: 48_000))
        }
        func waitUntilHeld() async { if !held { await withCheckedContinuation { arrival = $0 } } }
        func release() { released = true; gate?.resume(); gate = nil }
        func cancel() { release() }
    }

    private actor Decoder: PCMDecoding {
        nonisolated let sampleRate = 48_000, channels = 1
        nonisolated let startFrame: Int64 = 0
        nonisolated let bufferState: PCMBufferState? = PCMBufferState()
        private(set) var reads: Int64 = 0
        private var cancelled = false
        func next() throws -> NativePCMDecoder.Packet? {
            guard !cancelled else { throw CancellationError() }
            defer { reads += 1 }
            return .init(samples: Array(repeating: 1000, count: 4096), sampleRate: sampleRate, channels: channels,
                presentationTime: CMTime(value: reads * 4096, timescale: 48_000))
        }
        func cancel() { cancelled = true; bufferState?.finish() }
    }
}

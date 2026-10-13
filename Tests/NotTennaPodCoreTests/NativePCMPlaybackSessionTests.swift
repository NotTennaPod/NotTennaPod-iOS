import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor struct NativePCMPlaybackSessionTests {
    private struct Timeout: Error { let detail: String }
    private func wait(_ predicate: @MainActor () -> Bool,
                      detail: @MainActor () -> String = { "Condition not reached" }) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            if ContinuousClock.now > deadline { throw Timeout(detail: detail()) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func renderToEnd(_ session: NativePCMPlaybackSession) async throws -> [Float] {
        var samples: [Float] = []
        while session.state != .ended {
            if let failure = session.failure { throw failure }
            let available = session.writtenFrames - session.renderedFrames
            if available == 0 || session.state != .playing {
                try await wait({ session.state == .ended || session.failure != nil
                    || (session.state == .playing && session.writtenFrames > session.renderedFrames) },
                    detail: { "state=\(session.state) EOF=\(session.sourceEnded) written=\(session.writtenFrames) rendered=\(session.renderedFrames) queued=\(session.queuedBufferCount) nativeWritten=\(session.output.scheduledFrames) nativeRendered=\(session.output.renderedFrames) engine=\(session.output.isEngineRunning) intent=\(session.wantsPlayback)" })
                continue
            }
            samples += try session.renderOffline(frames: min(session.output.bufferCapacity, Int(available)))
            // Allow native completion/producer refill to run; no wall-clock audio is played.
            await Task.yield()
        }
        return samples
    }

    @Test func sourceEOFDoesNotEndPlaybackUntilNativeOutputCompletes() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: false, maximumOutputFrames: 65536)
        let session = try NativePCMPlaybackSession(stream: stream, mode: .offline, maximumQueuedBuffers: 2)
        defer { session.close() }
        var states: [NativePCMPlaybackSession.State] = []
        session.onStateChanged = { states.append($0) }
        try await session.prepare()
        #expect(session.sourceEnded && session.state == .paused && session.queuedBufferCount == 1)
        #expect(try session.renderedMediaMicroseconds == 0)
        try session.play()
        let first = try session.renderOffline(frames: 14400)
        try session.pause()
        #expect(try session.renderedMediaMicroseconds == 300_000)
        #expect(session.sourceEnded && session.state == .paused)
        #expect(!states.contains(.ended))
        try session.play()
        let second = try await renderToEnd(session)
        #expect(first + second == input.map { Float($0) / 32768 })
        #expect(states.filter { $0 == .ended }.count == 1)
        #expect(session.renderedFrames == 28_800)
        #expect(try session.renderedMediaMicroseconds == 600_000)
        #expect(throws: NativePCMPlaybackSession.Failure.ended) { try session.play() }
    }

    @Test(arguments: [127, 256, 257], [2, 3, 4])
    func parameterSegmentsReachNativeOutputInOrderAcrossPause(capacity: Int, queueSize: Int) async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: false, maximumOutputFrames: capacity)
        let session = try NativePCMPlaybackSession(stream: stream, mode: .offline, maximumQueuedBuffers: queueSize)
        defer { session.close() }
        try await session.prepare()
        try session.play()
        var samples = try session.renderOffline(frames: min(128, capacity / 2))
        try session.pause()
        let frozen = try session.renderedMediaMicroseconds
        try await session.setParameters(speed: 2, skipSilence: true)
        #expect(try session.renderedMediaMicroseconds == frozen)
        try session.play()
        samples += try await renderToEnd(session)
        var silence = try SilenceSkippingProcessor(sampleRate: 48000, channels: 2)
        var rate = try PCMSpeedProcessor(sampleRate: 48000, channels: 2, speed: 2)
        var expected = Array(input.prefix(8192))
        for start in stride(from: 8192, to: input.count, by: 8192) {
            expected += try rate.process(silence.process(Array(input[start..<min(input.count, start + 8192)])))
        }
        expected += try rate.process(silence.finish())
        expected += rate.finish()
        let expectedSamples = expected.map { Float($0) / 32768 }
        let difference = zip(samples, expectedSamples).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        let detail = "first different sample=\(String(describing: difference)), actual count=\(samples.count), expected count=\(expectedSamples.count)"
        let identical = samples == expectedSamples
        #expect(identical, Comment(rawValue: detail))
        #expect(session.writtenFrames == Int64(expected.count / 2))
        #expect(session.renderedFrames == session.writtenFrames)
        #expect(session.state == .ended && session.failure == nil)
    }

    @Test func producerUnderrunResumesNativeOutputWithoutDroppingSourceSamples() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let decoder = try GateDecoder(url: url, blockOnRead: 3)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, maximumOutputFrames: 4096)
        let session = try NativePCMPlaybackSession(stream: stream, mode: .offline, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare()
        try session.play()
        var samples = try session.renderOffline(frames: 4096)
        await decoder.waitUntilBlocked()
        samples += try session.renderOffline(frames: 4096)
        try await wait { session.state == .buffering }
        let frozen = try session.renderedMediaMicroseconds
        #expect(session.renderedFrames == 8192 && session.writtenFrames == 8192)
        #expect(frozen == 170_666)
        await decoder.release()
        try await wait { session.state == .playing && session.writtenFrames > 8192 }
        #expect(session.renderedFrames == 8192)
        samples += try await renderToEnd(session)
        #expect(samples == input.map { Float($0) / 32768 })
        #expect(session.renderedFrames == 28_800 && session.state == .ended)
        #expect(try session.renderedMediaMicroseconds == 600_000)
    }

    @Test func closeDuringPendingReadFencesLateAudioAndCompletion() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let decoder = try GateDecoder(url: url, blockOnRead: 1)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false)
        let session = try NativePCMPlaybackSession(stream: stream, mode: .offline)
        var states: [NativePCMPlaybackSession.State] = []
        session.onStateChanged = { states.append($0) }
        let prepare = Task { try await session.prepare() }
        await decoder.waitUntilBlocked()
        session.close()
        await #expect(throws: NativePCMDecoder.Failure.cancelled) { try await prepare.value }
        #expect(session.state == .closed && session.queuedBufferCount == 0 && session.writtenFrames == 0)
        #expect(!states.contains(.ended) && !states.contains(.failed))
        await #expect(throws: NativePCMPlaybackSession.Failure.closed) { try await session.prepare() }
    }

    @Test func pauseDuringPrimePreventsLateAutoplay() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let decoder = try GateDecoder(url: url, blockOnRead: 1)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false)
        let session = try NativePCMPlaybackSession(stream: stream, mode: .offline)
        defer { session.close() }
        try session.play()
        await decoder.waitUntilBlocked()
        try session.pause()
        await decoder.release()
        try await wait { session.queuedBufferCount == 4 }
        #expect(session.state == .paused && !session.wantsPlayback && !session.output.wantsPlayback)
        #expect(session.renderedFrames == 0)
        #expect(try session.renderedMediaMicroseconds == 0)
        try session.play()
        #expect(try await renderToEnd(session) == input.map { Float($0) / 32768 })
    }

    @Test func closingFromObserverDuringStartStopsPlaybackSafely() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: false)
        let session = try NativePCMPlaybackSession(stream: stream, mode: .offline)
        var states: [NativePCMPlaybackSession.State] = []
        session.onStateChanged = { [weak session] state in
            states.append(state)
            if state == .buffering { session?.close() }
        }
        try session.play()
        #expect(session.state == .closed && !session.wantsPlayback)
        #expect(states.last == .closed && !states.contains(.playing) && !states.contains(.ended))
        #expect(session.writtenFrames == 0 && session.queuedBufferCount == 0)
        await #expect(throws: NativePCMPlaybackSession.Failure.closed) { try await session.prepare() }
    }
}

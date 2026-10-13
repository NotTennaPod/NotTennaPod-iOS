import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct PCMStreamingFailureTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    private enum Failure: Error { case deadline }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil,
                                                        subdirectory: "Fixtures/StreamingFormats")))
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"], [false, true])
    func failedHTTPSourceAbortsFullOutputWithoutAnotherPull(name: String, playing: Bool) async throws {
        let data = try fixture(name)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4),
                  keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let decoder = try await FFmpegPCMDecoder.open(input: input, maximumFrames: 4096)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: true, speed: 1.5,
                                                maximumOutputFrames: 127)
        let transport = Transport()
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        var failureNotifications = 0
        session.onChange = { [weak session] in
            if session?.state == .failed { failureNotifications += 1 }
        }
        try await session.prepare()
        if playing { try session.play() }
        #expect(!session.sourceEnded && !input.snapshot().completed)
        server.stop()
        try await wait { session.failure != nil }
        #expect((session.failure as? URLError)?.code == .networkConnectionLost)
        #expect(session.state == .failed && transport.closed && !transport.playing)
        #expect(failureNotifications == 1)
        // Late transport notifications cannot restart output or report a second failure.
        transport.advance(254)
        #expect(session.state == .failed && failureNotifications == 1)
    }

    @Test func failureBeforeSessionSubscriptionIsNotLost() async throws {
        let decoder = FailureDecoder()
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false)
        decoder.sourceFailure?.fail(URLError(.timedOut))
        let transport = Transport()
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport)
        defer { session.close() }
        await #expect(throws: URLError(.timedOut)) { try await session.prepare() }
        #expect(session.state == .failed && transport.closed && transport.buffers.isEmpty)
        #expect(await decoder.reads == 0)
    }

    @Test func queuedOldFailureCannotAffectReplacementGeneration() async throws {
        let oldDecoder = FailureDecoder(), newDecoder = FailureDecoder()
        let oldTransport = Transport(), newTransport = Transport()
        let old = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: oldDecoder,
            skipSilence: false, maximumOutputFrames: 127), transport: oldTransport)
        let replacement = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: newDecoder,
            skipSilence: false, maximumOutputFrames: 127), transport: newTransport)
        let owner = PCMRecoverySession(initial: old, parameters: .init(speed: 1, skipSilence: false),
            lastPlayedMilliseconds: { 0 }, synchronizeStatistics: {}, factory: { _, _ in replacement })
        defer { owner.close() }
        try await old.prepare()
        // Enqueue the event while MainActor is occupied, then retire the old generation
        // before yielding to its observer. The replacement is owned by PCMRecoverySession.
        oldDecoder.sourceFailure?.fail(URLError(.networkConnectionLost))
        try await owner.seekPaused(to: 0)
        await Task.yield()
        #expect(old.state == .closed && oldTransport.closed)
        #expect(owner.failure == nil && owner.outputState == .paused)
        #expect(!newTransport.closed)
        try owner.play()
        #expect(owner.outputState == .playing)
    }

    @Test func sourceFailureWinsOverLateNativeEnqueueFlushDuringPreparation() async throws {
        let decoder = FailureDecoder()
        let transport = Transport()
        transport.hold = true
        let session = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoder,
            skipSilence: false, maximumOutputFrames: 127), transport: transport)
        defer { transport.release(); session.close() }
        var failures = 0
        session.onChange = { [weak session] in if session?.state == .failed { failures += 1 } }
        let preparing = Task { try await session.prepare() }
        try await wait { transport.pending != nil }
        decoder.sourceFailure?.fail(URLError(.timedOut))
        try await wait { session.failure != nil }
        // Native retirement can unblock enqueue with its own flush/cancellation error.
        transport.pending?.resume(throwing: NativeSampleBufferTransport.Failure.flushed)
        transport.pending = nil
        await #expect(throws: URLError(.timedOut)) { try await preparing.value }
        #expect((session.failure as? URLError)?.code == .timedOut)
        #expect(failures == 1 && session.state == .failed)
        #expect(transport.closed)
    }

    @Test func realHTTPFailureRetiresPausedNativeRenderer() async throws {
        let data = try fixture("tone-opus.webm")
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4),
                  keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let decoder = try await FFmpegPCMDecoder.open(input: input)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: true, speed: 1.5,
                                                maximumOutputFrames: 4096)
        let transport = NativeSampleBufferTransport(muted: true)
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare()
        #expect(session.state == .paused)
        #expect(!input.snapshot().completed)
        server.stop()
        try await wait { session.failure != nil }
        #expect((session.failure as? URLError)?.code == .networkConnectionLost)
        #expect(session.state == .failed && !session.wantsPlayback)
        #expect(try session.mediaMicroseconds == 0 && session.presentedFrames == 0)
    }

    private actor FailureDecoder: PCMDecoding {
        nonisolated let sourceFailure: PCMSourceFailure? = PCMSourceFailure()
        nonisolated let sampleRate = 48_000
        nonisolated let channels = 1
        nonisolated let startFrame: Int64 = 0
        private(set) var reads = 0
        private(set) var cancelled = false
        func next() throws -> NativePCMDecoder.Packet? {
            try sourceFailure?.check()
            guard !cancelled else { throw CancellationError() }
            defer { reads += 1 }
            return .init(samples: Array(repeating: 1000, count: 4096), sampleRate: sampleRate, channels: channels,
                         presentationTime: CMTime(value: Int64(reads) * 4096, timescale: 48_000))
        }
        func cancel() { cancelled = true; sourceFailure?.finish() }
    }
}

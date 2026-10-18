import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor
struct BufferedProducerFailureTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    private enum Failure: Error { case deadline }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil,
                                                      subdirectory: "Fixtures/StreamingFormats")))
    }
    private func source(_ name: String = "tone-opus.webm") async throws -> (LoopbackHTTPServer, HTTPCodecByteInput) {
        let data = try fixture(name)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        return (server, try HTTPCodecByteInput(url: server.url))
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"], [false, true])
    func producerErrorAbortsFullOutputWithoutHTTPNotificationOrAnotherPull(name: String, playing: Bool) async throws {
        let (server, input) = try await source(name)
        defer { server.stop(); input.cancel() }
        let decoder = try await FFmpegPCMDecoder.openBuffered(input: UnobservedSource(input: input))
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: true, speed: 1.5, maximumOutputFrames: 127)
        let transport = Transport()
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        var failures = 0
        session.onChange = { [weak session] in if session?.state == .failed { failures += 1 } }
        try await session.prepare()
        if playing { try session.play() }
        try await wait { input.snapshot().waitingReaders > 0 }
        #expect(input.sourceFailure?.subscriberCount == 0) // No network observer can satisfy this test.
        server.stop()
        try await wait { session.failure != nil }
        let expected = try #require(input.sourceFailure?.error)
        #expect((expected as? URLError)?.code == .networkConnectionLost)
        #expect((try #require(session.failure) as NSError).isEqual(expected as NSError))
        #expect((try #require(decoder.sourceFailure?.error) as NSError).isEqual(expected as NSError))
        // A dropped connection is reported once as a network error, audio
        // stops, and the temporary stream cache is deleted.
        #expect(session.state == .failed && failures == 1 && transport.closed && !transport.playing)
        try await wait { input.snapshot().cancelled && input.snapshot().waitingReaders == 0 }
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        transport.advance(254)
        #expect(failures == 1 && session.state == .failed)
    }

    @Test func producerFailureBeforeSessionSubscriptionIsReplayed() async throws {
        let (server, input) = try await source()
        defer { server.stop(); input.cancel() }
        let decoder = try await FFmpegPCMDecoder.openBuffered(input: UnobservedSource(input: input))
        try await wait { input.snapshot().waitingReaders > 0 }
        server.stop()
        try await wait { decoder.sourceFailure?.error != nil }
        let expected = try #require(decoder.sourceFailure?.error)
        let transport = Transport()
        let session = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoder,
            skipSilence: false), transport: transport)
        defer { session.close() }
        do { try await session.prepare(); Issue.record("Failed prepared source was admitted") }
        catch { #expect((error as NSError).isEqual(expected as NSError)) }
        #expect(session.state == .failed && session.writtenFrames == 0 && transport.closed)
    }

    @Test func nativePausedOutputRetiresOnProducerOnlyFailure() async throws {
        let (server, input) = try await source()
        defer { server.stop(); input.cancel() }
        let decoder = try await FFmpegPCMDecoder.openBuffered(input: UnobservedSource(input: input))
        let transport = NativeSampleBufferTransport(muted: true)
        let session = try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(decoder: decoder,
            skipSilence: true, speed: 1.5, maximumOutputFrames: 4096), transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare()
        #expect(session.state == .paused)
        try await wait { input.snapshot().waitingReaders > 0 }
        #expect(input.sourceFailure?.subscriberCount == 0)
        server.stop()
        try await wait { session.failure != nil }
        #expect((session.failure as? URLError)?.code == .networkConnectionLost)
        // Failure while paused is reported and does not start playback.
        #expect(session.state == .failed && !session.wantsPlayback)
        #expect(try session.mediaMicroseconds == 0 && session.presentedFrames == 0)
        try await wait { input.snapshot().cancelled }
    }

    @Test func cancelledSeekGenerationKeepsStableErrorSignalQuiet() async throws {
        let (server, input) = try await source()
        defer { server.stop(); input.cancel() }
        let reader = try await FFmpegAudioReader.openBuffered(input: UnobservedSource(input: input), timing: .media3)
        // Repeated seeks while the download is still running report no error
        // and keep delivering audio; the later real network drop is reported.
        for _ in 0..<4 {
            try await wait { input.snapshot().waitingReaders > 0 }
            try await reader.seek(to: .zero)
            #expect(reader.sourceFailure?.error == nil)
            #expect(try await reader.next() != nil)
        }
        server.stop()
        try await wait { reader.sourceFailure?.error != nil }
        #expect((reader.sourceFailure?.error as? URLError)?.code == .networkConnectionLost)
        await reader.cancel()
        #expect(reader.sourceFailure?.error != nil)
    }

    @Test func droppingReaderFinishesStableSignalAndReleasesBlockedProducer() async throws {
        let (server, input) = try await source()
        defer { server.stop(); input.cancel() }
        var reader: FFmpegAudioReader? = try await FFmpegAudioReader.openBuffered(input: UnobservedSource(input: input))
        try await wait { input.snapshot().waitingReaders > 0 }
        _ = reader
        reader = nil
        // Closing the episode mid-download stops the network transfer without
        // reporting an error, and deletes the temporary cache.
        try await wait { input.snapshot().cancelled && input.snapshot().waitingReaders == 0 }
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    /// Suppress HTTP's asynchronous signal without changing its bytes, errors or cancellation.
    /// A failure must pass through native read -> producer -> reader -> stream -> session.
    private struct UnobservedSource: MediaByteLeaseSource {
        let input: HTTPCodecByteInput
        var length: Int64? { input.length }
        var supportsRandomAccess: Bool { input.supportsRandomAccess }
        func prepareForSeek() { input.prepareForSeek() }
        func read(at offset: Int64, maximumCount: Int) throws -> Data { try input.read(at: offset, maximumCount: maximumCount) }
        func checkFailure() throws { try input.checkFailure() }
        func cancel() { input.cancel() }
        func makeReadLease() -> any MediaByteInput { UnobservedInput(input: input.makeReadLease()) }
    }
    private struct UnobservedInput: MediaByteInput {
        let input: any MediaByteInput
        var length: Int64? { input.length }
        var supportsRandomAccess: Bool { input.supportsRandomAccess }
        func prepareForSeek() { input.prepareForSeek() }
        func read(at offset: Int64, maximumCount: Int) throws -> Data { try input.read(at: offset, maximumCount: maximumCount) }
        func checkFailure() throws { try input.checkFailure() }
        func cancel() { input.cancel() }
    }
}

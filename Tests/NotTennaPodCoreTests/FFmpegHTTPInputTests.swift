import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized)
struct FFmpegHTTPInputTests {
    private static let names = ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"]
    private enum Failure: Error { case deadline }
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate() {
            if ContinuousClock.now >= deadline { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func chunked(_ data: Data, end: Bool) -> Data {
        Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data((end ? "\r\n0\r\n\r\n" : "\r\n").utf8)
    }

    @Test(arguments: names, [false, true])
    func progressiveDecodeProducesPCMBeforeEOFAndCancelWakesBlockedNext(name: String, unknownLength: Bool) async throws {
        let data = try Data(contentsOf: fixture(name))
        let prefix = Data(data.prefix(data.count * 3 / 4))
        let body = unknownLength ? chunked(prefix, end: false) : prefix
        let headers = unknownLength ? ["Transfer-Encoding": "chunked"] : ["Content-Length": String(data.count)]
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: headers, body: body, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        // Native initialization must not wait for EOF. This also prevents a broken native
        // probe from hanging the test runner on a dedicated executor.
        let watchdog = Task { try await Task.sleep(for: .seconds(8)); input.cancel() }
        defer { watchdog.cancel() }
        let reader = try await FFmpegAudioReader.open(input: input, maximumFrames: 127, timing: .media3)
        let first = try #require(try await reader.next())
        #expect(first.frameCount > 0 && first.frameCount <= 127)
        #expect(first.sampleRate == 48_000 && first.presentationTime.isNumeric)
        #expect(input.snapshot().received < Int64(data.count) && !input.snapshot().completed)
        #expect(input.length == (unknownLength ? nil : Int64(data.count)))
        let pump = Task { while try await reader.next() != nil {} }
        try await wait { input.snapshot().waitingReaders > 0 }
        await reader.cancel() // Must wake the read before awaiting the occupied reader actor.
        do { try await pump.value; Issue.record("Cancelled stream returned EOF") }
        catch { #expect(error is CancellationError || (error as? FFmpegAudioReader.Failure) == .cancelled) }
        #expect(await reader.status == .cancelled)
        #expect(input.snapshot().cancelled && input.snapshot().waitingReaders == 0)
        #expect(input.snapshot().largestRead <= 65_536 && input.snapshot().cleanupFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        await #expect(throws: FFmpegAudioReader.Failure.cancelled) { try await reader.next() }
    }

    @Test(arguments: names, [false, true])
    func completeHTTPStreamSoundsLikeLocalFileAndSeeksAfterEOF(name: String, unknownLength: Bool) async throws {
        let url = try fixture(name)
        let data = try Data(contentsOf: url)
        let body = unknownLength ? chunked(data, end: true) : data
        let headers = unknownLength ? ["Transfer-Encoding": "chunked"] : ["Content-Length": String(data.count)]
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: headers, body: body) }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let remote = try await FFmpegAudioReader.open(input: input, maximumFrames: 127, timing: .media3)
        let local = try FFmpegAudioReader(url: url, maximumFrames: 127, timing: .media3)
        var expected = AudibleAudio(), actual = AudibleAudio()
        while let chunk = try await local.next() { expected.add(chunk) }
        while let chunk = try await remote.next() { actual.add(chunk) }
        FFmpegBufferedSeekReferenceTests.expectSameAudible(actual, expected, "\(name) streamed")
        #expect(abs(actual.totalFrames - 384_000) <= 48_000 / 10) // About eight seconds of audio.
        #expect(try await remote.next() == nil)
        #expect(await remote.status == .ended)
        #expect(input.snapshot().completed && input.length == Int64(data.count))
        // EOF retains the cache for subsequent seek/reset until its owner retires it.
        try await remote.seek(to: CMTime(value: 3883, timescale: 1000))
        let resumed = try #require(try await remote.next())
        #expect(abs(resumed.presentationTime.seconds - 3.883) <= 0.25 && !resumed.samples.isEmpty)
        await remote.cancel(); await local.cancel()
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test func cancellationDuringOpeningHasNoActorQueueDependency() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let opening = Task { try await FFmpegAudioReader.open(input: input) }
        try await wait { !server.requests.isEmpty && input.snapshot().waitingReaders == 1 }
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(input.snapshot().cancelled && input.snapshot().waitingReaders == 0)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test(arguments: [401, 403, 404, 500])
    func HTTPFailureReachesCallerAndReleasesCache(status: Int) async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(status: status, body: Data()) }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        await #expect(throws: MediaDownloadError.httpStatus(status)) { try await FFmpegAudioReader.open(input: input) }
        #expect(input.snapshot().failure != nil && input.snapshot().cleanupFailure == nil)
        #expect(input.snapshot().cancelled && !FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test(arguments: names)
    func HTTPDecoderConnectsToPCMAdapterWithOriginalSeekAnchor(name: String) async throws {
        let url = try fixture(name), data = try Data(contentsOf: url)
        let server = try await LoopbackHTTPServer.start { _ in .init(body: data) }
        defer { server.stop() }
        let remote = try await FFmpegPCMDecoder.open(url: server.url, start: CMTime(value: 3883, timescale: 1000))
        let local = try await FFmpegPCMDecoder.open(url: url, start: CMTime(value: 3883, timescale: 1000))
        // Streamed playback started at 3.883 s begins where the local file does, within 0.25 s.
        #expect(abs(remote.startTime.seconds - 3.883) <= 0.25 && abs(remote.startTime.seconds - local.startTime.seconds) <= 0.25)
        var expected = AudibleAudio(), actual = AudibleAudio()
        for _ in 0..<5 {
            actual.add(try #require(try await remote.next())); expected.add(try #require(try await local.next()))
        }
        FFmpegBufferedSeekReferenceTests.expectSameAudible(actual, expected, "\(name) streamed from 3.883 s")
        #expect(actual.peak > 1000)
        await remote.cancel(); await local.cancel()
    }

    @Test(arguments: names, [Float(0.5), Float(1.5), Float(2)])
    func openEndedHTTPFeedsSpeedProcessorBeforeEOF(name: String, speed: Float) async throws {
        let url = try fixture(name), data = try Data(contentsOf: url)
        let body = chunked(Data(data.prefix(data.count * 3 / 4)), end: false)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Transfer-Encoding": "chunked"], body: body, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let watchdog = Task { try await Task.sleep(for: .seconds(8)); input.cancel() }
        defer { watchdog.cancel() }
        let remoteDecoder = try await FFmpegPCMDecoder.open(input: input, maximumFrames: 127)
        let localDecoder = try await FFmpegPCMDecoder.open(url: url, maximumFrames: 127)
        let remote = try LocalPCMPlaybackStream(decoder: remoteDecoder, skipSilence: false, speed: speed, maximumOutputFrames: 127)
        let local = try LocalPCMPlaybackStream(decoder: localDecoder, skipSilence: false, speed: speed, maximumOutputFrames: 127)
        // Speed-adjusted output is produced before the download finishes and matches the local file's.
        var remoteFrames = 0, localFrames = 0
        for _ in 0..<5 {
            let actual = try #require(try await remote.nextPacket()), expected = try #require(try await local.nextPacket())
            #expect(!actual.samples.isEmpty)
            #expect(actual.outputStartFrame == Int64(remoteFrames)) // Contiguous output, nothing skipped.
            #expect(abs(actual.segment.mediaStartTime.seconds - expected.segment.mediaStartTime.seconds) <= 0.25)
            remoteFrames += actual.samples.count / remoteDecoder.channels
            localFrames += expected.samples.count / localDecoder.channels
        }
        #expect(abs(remoteFrames - localFrames) <= 2400)
        #expect(input.length == nil && !input.snapshot().completed)
        await remote.cancel(); await local.cancel()
        #expect(input.snapshot().cancelled && !FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test func sourceErrorStopsPendingPCMAndRetainsItsOriginalCause() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.ogg"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let watchdog = Task { try await Task.sleep(for: .seconds(8)); input.cancel() }
        defer { watchdog.cancel() }
        let reader = try await FFmpegAudioReader.open(input: input, maximumFrames: 1)
        #expect(try await reader.next()?.frameCount == 1) // Leaves pending decoded PCM in the reader.
        server.stop()
        try await wait { input.snapshot().failure != nil }
        await #expect(throws: URLError.self) { try await reader.next() }
        #expect(await reader.status == .failed)
        #expect(input.snapshot().cancelled)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        await #expect(throws: URLError.self) { try await reader.next() }
        await reader.cancel()
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"], [false, true])
    func preparedAdapterPacketCannotSurviveSourceFailureOrCancellation(name: String, cancelSource: Bool) async throws {
        let data = try Data(contentsOf: fixture(name))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let watchdog = Task { try await Task.sleep(for: .seconds(8)); input.cancel() }
        defer { watchdog.cancel() }
        // Opening retains the first admitted PCM packet without handing it to the stream yet.
        let decoder = try await FFmpegPCMDecoder.open(input: input, maximumFrames: 127)
        #expect(!input.snapshot().completed)
        if cancelSource { input.cancel() }
        else {
            server.stop()
            try await wait { input.snapshot().failure != nil }
        }
        if cancelSource {
            await #expect(throws: CancellationError.self) { try await decoder.next() }
        } else {
            await #expect(throws: URLError.self) { try await decoder.next() }
        }
        #expect(input.snapshot().cancelled && input.snapshot().activeTransfers == 0)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        await #expect(throws: FFmpegPCMDecoder.Failure.cancelled) { try await decoder.next() }
        await decoder.cancel()
    }

    @Test func releasingReaderRetiresItsInputEvenWhenCallerRetainsInput() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { _ in .init(body: data) }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        var reader: FFmpegAudioReader? = try await FFmpegAudioReader.open(input: input)
        weak let observed = reader
        #expect(reader != nil && FileManager.default.fileExists(atPath: input.cacheURL.path))
        reader = nil
        #expect(observed == nil)
        #expect(input.snapshot().cancelled && !FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

}

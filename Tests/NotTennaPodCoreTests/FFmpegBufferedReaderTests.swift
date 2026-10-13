import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2)))
struct FFmpegBufferedReaderTests {
    private static let names = ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"]
    private enum Failure: Error { case deadline }
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(arguments: names)
    func decoderContinuesWhileNativeHTTPInputIsBlocked(name: String) async throws {
        let url = try fixture(name), data = try Data(contentsOf: url)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let reader = try await FFmpegAudioReader.openBuffered(input: input, maximumFrames: 127, timing: .media3)
        let local = try FFmpegAudioReader(url: url, maximumFrames: 127, timing: .media3)
        do {
            try await wait { input.snapshot().waitingReaders > 0 }
            #expect(await reader.producerSnapshot()?.reading == true)
            // Audio keeps playing from what has arrived while the download is stalled.
            var expected = AudibleAudio(), actual = AudibleAudio()
            for _ in 0..<64 {
                expected.add(try #require(try await local.next())); actual.add(try #require(try await reader.next()))
            }
            FFmpegBufferedSeekReferenceTests.expectSameAudible(actual, expected, "\(name) while download is stalled")
            #expect(input.snapshot().waitingReaders > 0)
        } catch { await reader.cancel(); await local.cancel(); throw error }
        await reader.cancel(); await local.cancel()
        #expect(input.snapshot().cancelled && input.snapshot().waitingReaders == 0)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test(arguments: names)
    func seekSupersedesWaitingReadAndPreservesReplacementPCM(name: String) async throws {
        let url = try fixture(name), data = try Data(contentsOf: url)
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], body: data.dropFirst(offset))
            }
            return .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let reader = try await FFmpegAudioReader.openBuffered(input: input, maximumFrames: 127, timing: .media3)
        let draining = Task { while try await reader.next() != nil {} }
        do {
            try await wait { await reader.producerSnapshot()?.waitingConsumer == true }
            await #expect(throws: FFmpegAudioReader.Failure.concurrentOperation) { try await reader.next() }
            try await reader.seek(to: CMTime(value: 7, timescale: 1))
            await #expect(throws: CancellationError.self) { try await draining.value }
            draining.cancel() // Late cancellation of a retired pull must not retire the replacement.
            let local = try FFmpegAudioReader(url: url, maximumFrames: 127, timing: .media3)
            try await local.seek(to: CMTime(value: 7, timescale: 1))
            var expected = AudibleAudio(), actual = AudibleAudio()
            while let chunk = try await local.next() { expected.add(chunk) }
            while let chunk = try await reader.next() { actual.add(chunk) }
            FFmpegBufferedSeekReferenceTests.expectSameAudible(actual, expected, "\(name) seek to 7 s during stalled download")
            #expect(abs((actual.starts.first ?? 0) - 7_000_000) <= 250_000)
            await local.cancel()
            #expect(!input.snapshot().cancelled)
        } catch { await reader.cancel(); draining.cancel(); throw error }
        await reader.cancel()
        #expect(input.snapshot().waitingReaders == 0 && input.snapshot().activeTransfers == 0)
    }

    @Test(arguments: [false, true])
    func cancellationWakesDecoderAndProducer(cancelTask: Bool) async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let reader = try await FFmpegAudioReader.openBuffered(input: input, timing: .media3)
        let pulling = Task { while try await reader.next() != nil {} }
        try await wait { await reader.producerSnapshot()?.waitingConsumer == true }
        if cancelTask { pulling.cancel() } else { await reader.cancel() }
        await #expect(throws: CancellationError.self) { try await pulling.value }
        #expect(await reader.status == .cancelled)
        #expect(input.snapshot().cancelled && input.snapshot().waitingReaders == 0)
        #expect(input.snapshot().activeTransfers == 0 && input.sourceFailure?.error == nil)
    }

    @Test func blockedSeekRejectsOverlappingOperationsAndCancelsOpeningGeneration() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] != nil { return nil }
            return .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let reader = try await FFmpegAudioReader.openBuffered(input: input, timing: .media3)
        let seeking = Task { try await reader.seek(to: CMTime(value: 7, timescale: 1)) }
        try await wait { server.requests.contains { $0.headers["range"] != nil } }
        await #expect(throws: FFmpegAudioReader.Failure.concurrentOperation) { try await reader.next() }
        await #expect(throws: FFmpegAudioReader.Failure.concurrentOperation) { try await reader.seek(to: .zero) }
        await reader.cancel()
        await #expect(throws: CancellationError.self) { try await seeking.value }
        #expect(await reader.status == .cancelled)
        #expect(input.snapshot().waitingReaders == 0 && input.snapshot().activeTransfers == 0)
    }

    @Test(arguments: [false, true])
    func failedOrCancelledOpeningRetiresOwnedSource(cancel: Bool) async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            cancel ? nil : .init(status: 403, body: Data())
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let opening = Task { try await FFmpegAudioReader.openBuffered(input: input) }
        if cancel {
            try await wait { input.snapshot().waitingReaders > 0 }
            opening.cancel()
            await #expect(throws: CancellationError.self) { try await opening.value }
        } else {
            await #expect(throws: MediaDownloadError.httpStatus(403)) { try await opening.value }
        }
        #expect(input.snapshot().cancelled && input.snapshot().waitingReaders == 0)
        #expect(input.snapshot().activeTransfers == 0 && !FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test func preparedBufferedPCMRejectsSourceFailureBeforeFirstDelivery() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let decoder = try await FFmpegPCMDecoder.openBuffered(input: input, maximumFrames: 1)
        server.stop()
        try await wait { input.sourceFailure?.error != nil }
        let expected = try #require(input.sourceFailure?.error)
        do { _ = try await decoder.next(); Issue.record("Prepared PCM hid a source failure") }
        catch { #expect((error as NSError).isEqual(expected as NSError)) }
        await decoder.cancel()
        try await wait { input.snapshot().waitingReaders == 0 }
        #expect(input.snapshot().cancelled && !FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test func releasingBufferedReaderRetiresBlockedNativeInput() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        var reader: FFmpegAudioReader? = try await FFmpegAudioReader.openBuffered(input: input)
        weak let observed = reader
        try await wait { input.snapshot().waitingReaders > 0 }
        reader = nil
        // A queued actor observation can hold a temporary reference; native
        // cancellation also wakes a blocked reader asynchronously. Wait for
        // ownership retirement, retaining every cleanup assertion below.
        try await wait {
            observed == nil && input.snapshot().cancelled && input.snapshot().waitingReaders == 0
                && input.sourceFailure?.subscriberCount == 0 && !FileManager.default.fileExists(atPath: input.cacheURL.path)
        }
        #expect(observed == nil)
        #expect(input.sourceFailure?.subscriberCount == 0)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }
}

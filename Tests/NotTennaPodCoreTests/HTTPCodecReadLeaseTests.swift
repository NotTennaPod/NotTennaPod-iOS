import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized)
struct HTTPCodecReadLeaseTests {
    private static let names = ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"]
    private enum Failure: Error { case deadline }
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func read(_ input: any MediaByteInput, at offset: Int64 = 0) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try input.read(at: offset, maximumCount: 1024) })
            }
        }
    }

    @Test(arguments: names)
    func retiredBlockedProducerAllowsReplacementDecoderSeekWithoutLosingCache(name: String) async throws {
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
        let watchdog = Task { try await Task.sleep(for: .seconds(8)); input.cancel() }
        defer { watchdog.cancel() }
        let previous = try await FFmpegPacketProducer.open(input: input.makeReadLease())
        do { try await wait { input.snapshot().waitingReaders > 0 } }
        catch { await previous.cancel(); throw error }
        await previous.cancel()
        let preserved = input.snapshot().received
        let local = try await FFmpegPCMDecoder.open(url: url, start: CMTime(value: 7, timescale: 1), maximumFrames: 127)
        let replacement = try await FFmpegPCMDecoder.open(input: input.makeReadLease(), start: CMTime(value: 7, timescale: 1), maximumFrames: 127)
        do {
            // After a stalled download, seeking to 7 s plays the rest of the episode from 7 s.
            #expect(abs(replacement.startTime.seconds - 7) <= 0.25)
            var expected = AudibleAudio(), actual = AudibleAudio()
            while let packet = try await local.next() { expected.add(packet) }
            while let packet = try await replacement.next() { actual.add(packet) }
            FFmpegBufferedSeekReferenceTests.expectSameAudible(actual, expected, "\(name) seek to 7 s after stall")
        } catch { await local.cancel(); await replacement.cancel(); throw error }
        await local.cancel(); await replacement.cancel()
        #expect(!input.snapshot().cancelled && input.snapshot().received >= preserved)
        #expect(FileManager.default.fileExists(atPath: input.cacheURL.path))
        input.cancel()
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test func retiringProducerDoesNotFinishFailureSignalNeededByBudgetPausedReplacement() async throws {
        let url = try #require(Bundle.module.url(forResource: "long-opus", withExtension: "webm", subdirectory: "Fixtures/PacketProducer"))
        let data = try Data(contentsOf: url)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let previous = try await FFmpegPacketProducer.open(input: input.makeReadLease(), targetBytes: 4 * 1024 * 1024)
        do { try await wait { previous.snapshot().waitingForBudget } }
        catch { await previous.cancel(); throw error }
        await previous.cancel()
        let replacement = try await FFmpegPacketProducer.open(input: input.makeReadLease(), targetBytes: 4 * 1024 * 1024)
        do {
            try await wait { replacement.snapshot().waitingForBudget }
            server.stop()
            try await wait { replacement.sourceFailure.error != nil && replacement.snapshot().exited }
            let expected = try #require(input.sourceFailure?.error)
            #expect((expected as? URLError)?.code == .networkConnectionLost)
            #expect((try #require(replacement.sourceFailure.error) as NSError).isEqual(expected as NSError))
            do { _ = try await replacement.next(); Issue.record("A failed source returned a packet") }
            catch { #expect((error as NSError).isEqual(expected as NSError)) }
            #expect(previous.sourceFailure.error == nil && replacement.snapshot().retained == 0)
        } catch { await replacement.cancel(); throw error }
        await replacement.cancel()
    }

    @Test func finalLeaseReleaseRetiresAnOtherwiseUnownedCache() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data(repeating: 19, count: 1024)) }
        defer { server.stop() }
        var input: HTTPCodecByteInput? = try HTTPCodecByteInput(url: server.url)
        let cache = try #require(input?.cacheURL)
        var lease: (any MediaByteInput)? = input?.makeReadLease()
        #expect(try await read(try #require(lease)).count == 1024)
        input = nil
        // The remaining reader still reads the downloaded audio from the cache file...
        #expect(try await read(try #require(lease), at: 512).count == 512)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        lease = nil
        // ...and releasing the last reader leaves no stray media file on disk.
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func queuedPacketChecksUnderlyingFailureWithoutWaitingForNotificationTask() async throws {
        let input = CheckedInput(data: try Data(contentsOf: fixture("tone-opus.webm")))
        let producer = try await FFmpegPacketProducer.open(input: input)
        do {
            try await wait { producer.snapshot().ended && producer.snapshot().unread > 32 }
            // This input intentionally has no asynchronous failure signal. The same
            // check is required while a real source's observer task is still queued.
            let expected = NSError(domain: "ReadLeaseTest", code: 12, userInfo: [NSLocalizedDescriptionKey: "Original failure details"])
            input.fail(expected)
            do { _ = try await producer.next(); Issue.record("A cached packet hid the source failure") }
            catch { #expect((error as NSError).isEqual(expected)) }
            #expect((try #require(producer.sourceFailure.error) as NSError).isEqual(expected))
            #expect(producer.snapshot().retained == 0)
        } catch { await producer.cancel(); throw error }
        await producer.cancel()
    }

    private final class CheckedInput: MediaByteInput, @unchecked Sendable {
        let data: Data
        private let lock = NSLock()
        private var error: (any Error)?
        private var cancelled = false
        init(data: Data) { self.data = data }
        var length: Int64? { Int64(data.count) }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            guard offset < data.count else { return Data() }
            return Data(data[Int(offset)..<min(data.count, Int(offset) + maximumCount)])
        }
        func checkFailure() throws {
            try lock.withLock {
                if let error { throw error }
                if cancelled { throw CancellationError() }
            }
        }
        func fail(_ error: any Error) { lock.withLock { self.error = error } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}

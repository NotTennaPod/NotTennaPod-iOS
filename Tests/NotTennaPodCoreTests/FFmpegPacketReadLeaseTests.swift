import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) struct FFmpegPacketReadLeaseTests {
    private static let names = ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"]
    private enum Failure: Error { case deadline }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }
    private func packets(_ url: URL) throws -> [FFmpegEncodedPacket.Snapshot] {
        let demux = try FFmpegDemuxContext(url: url)
        var result: [FFmpegEncodedPacket.Snapshot] = []
        while let packet = try demux.next() { result.append(packet.snapshot()) }
        return result
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private struct HeldSource {
        let data: Data
        let prefixCount: Int
        let server: LoopbackHTTPServer
        let input: HTTPCodecByteInput
        let producer: FFmpegPacketProducer
        func stop() { producer.stop(); input.cancel(); server.stop() }
    }
    private func held(_ name: String) async throws -> HeldSource {
        let data = try Data(contentsOf: fixture(name)), prefix = data.count * 3 / 4
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(prefix), keepConnectionOpen: true)
        }
        do {
            let input = try HTTPCodecByteInput(url: server.url)
            let producer = try await FFmpegPacketProducer.open(input: input)
            return HeldSource(data: data, prefixCount: prefix, server: server, input: input, producer: producer)
        } catch { server.stop(); throw error }
    }
    private func drainPrefix(_ source: HeldSource, lease: FFmpegPacketProducer.ReadLease) async throws -> [FFmpegEncodedPacket.Snapshot] {
        try await wait { source.input.snapshot().waitingReaders > 0 && source.producer.snapshot().unread > 0 }
        let count = source.producer.snapshot().unread
        var result: [FFmpegEncodedPacket.Snapshot] = []
        for _ in 0..<count { result.append(try #require(try await lease.next()).snapshot()) }
        #expect(source.producer.snapshot().unread == 0 && source.producer.snapshot().reading)
        return result
    }

    @Test(arguments: names, [false, true])
    func retiringPendingReadKeepsLoadingAndReplacementReceivesEveryRemainingPacket(name: String, cancelTask: Bool) async throws {
        let expected = try packets(fixture(name)), source = try await held(name)
        defer { source.stop() }
        let old = source.producer.makeReadLease()
        let prefix = try await drainPrefix(source, lease: old)
        #expect(prefix == Array(expected.prefix(prefix.count)))
        let before = source.producer.snapshot()
        let waiting = Task { try await old.next() }
        defer { waiting.cancel() }
        try await wait { source.producer.snapshot().waitingConsumer }
        if cancelTask { waiting.cancel() } else { old.cancel() }
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(!source.producer.snapshot().waitingConsumer && !source.producer.snapshot().cancelled)
        #expect(source.producer.snapshot().retained == before.retained)
        #expect(source.producer.snapshot().readIndex == before.readIndex)
        #expect(source.producer.snapshot().allocatedBytes == before.allocatedBytes)
        #expect(source.input.snapshot().waitingReaders > 0 && !source.input.snapshot().cancelled)
        #expect(FileManager.default.fileExists(atPath: source.input.cacheURL.path))

        let replacement = source.producer.makeReadLease()
        let remaining = Task {
            var result: [FFmpegEncodedPacket.Snapshot] = []
            while let packet = try await replacement.next() { result.append(packet.snapshot()) }
            return result
        }
        defer { remaining.cancel() }
        try await wait { source.producer.snapshot().waitingConsumer }
        old.cancel() // A late old callback must not clear the replacement's pending read.
        #expect(source.producer.snapshot().waitingConsumer)
        await #expect(throws: CancellationError.self) { try await old.next() }
        #expect(throws: CancellationError.self) { try old.seekWithinBuffer(to: 0) }
        #expect(throws: CancellationError.self) { try old.updatePlayback(positionMicroseconds: 400_000_000, speed: 2) }
        #expect(source.producer.snapshot().playbackPositionMicroseconds == before.playbackPositionMicroseconds)
        #expect(source.producer.snapshot().speed == before.speed)
        try await source.server.appendResponseBody(source.data.dropFirst(source.prefixCount))
        #expect(try await remaining.value == Array(expected.dropFirst(prefix.count)))
        #expect(source.producer.snapshot().ended && source.producer.snapshot().retained == expected.count)
        #expect(source.server.requests.count == 1)
        try replacement.checkFailure()
        await source.producer.cancel()
        #expect(source.producer.snapshot().exited && source.input.snapshot().waitingReaders == 0)
    }

    @Test(arguments: [false, true])
    func stoppingOrDroppingSourceTerminatesLeaseWithoutOwnershipCycle(drop: Bool) async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        var producer: FFmpegPacketProducer? = try await FFmpegPacketProducer.open(input: input)
        weak var observed = producer
        let lease = try #require(producer).makeReadLease()
        let waiting = Task { while try await lease.next() != nil {} }
        defer { waiting.cancel() }
        try await wait { producer?.snapshot().waitingConsumer == true && input.snapshot().waitingReaders > 0 }
        if drop { producer = nil } else { await producer?.cancel() }
        await #expect(throws: CancellationError.self) { try await waiting.value }
        try await wait { input.snapshot().cancelled && input.snapshot().waitingReaders == 0 }
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        #expect(throws: CancellationError.self) { try lease.checkFailure() }
        if drop { #expect(observed == nil) }
        else { #expect(producer?.snapshot().exited == true) }
    }

    @Test(arguments: names)
    func cancelledLeaseCannotConsumeAlreadyQueuedPackets(name: String) async throws {
        let url = try fixture(name), expected = try packets(url)
        let producer = try await FFmpegPacketProducer.open(url: url)
        defer { producer.stop() }
        try await wait { producer.snapshot().ended }
        let old = producer.makeReadLease(), current = producer.makeReadLease()
        old.cancel()
        await #expect(throws: CancellationError.self) { try await old.next() }
        #expect(throws: CancellationError.self) { try old.seekWithinBuffer(to: 0) }
        #expect(throws: CancellationError.self) { try old.updatePlayback(positionMicroseconds: 400_000_000, speed: 2) }
        #expect(producer.snapshot().readIndex == 0 && producer.snapshot().firstIndex == 0)
        for expectedPacket in expected {
            #expect(try #require(try await current.next()).snapshot() == expectedPacket)
        }
        #expect(try await current.next() == nil)
        await producer.cancel()
    }

    @Test(arguments: 0..<12)
    func deliveryRacingCancellationPreservesPacketsForReplacementSeek(iteration: Int) async throws {
        let source = try await held("tone-opus.webm"), expected = try packets(fixture("tone-opus.webm"))
        defer { source.stop() }
        let old = source.producer.makeReadLease()
        let prefix = try await drainPrefix(source, lease: old)
        let waiting = Task { try await old.next() }
        defer { waiting.cancel() }
        try await wait { source.producer.snapshot().waitingConsumer }
        let cancellation = Task.detached { old.cancel() }
        try await source.server.appendResponseBody(source.data.dropFirst(source.prefixCount))
        await cancellation.value
        // A read that completes before cancellation may win; a canceled read
        // must throw. In both orders, no sample may be lost from retained storage.
        do { #expect(try #require(try await waiting.value).snapshot() == expected[prefix.count]) }
        catch { #expect(error is CancellationError) }
        try await wait { source.producer.snapshot().ended }
        let current = source.producer.makeReadLease()
        #expect(try current.seekWithinBuffer(to: 0))
        old.cancel()
        #expect(throws: CancellationError.self) { try old.updatePlayback(positionMicroseconds: 400_000_000, speed: 2) }
        await #expect(throws: CancellationError.self) { try await old.next() }
        for packet in expected { #expect(try #require(try await current.next()).snapshot() == packet) }
        #expect(try await current.next() == nil)
        #expect(source.producer.snapshot().retained == expected.count && source.server.requests.count == 1)
        await source.producer.cancel()
    }

    @Test func sourceFailureReachesPendingAndFutureLeasesWithOriginalError() async throws {
        let source = try await held("tone-opus.webm")
        defer { source.stop() }
        let lease = source.producer.makeReadLease()
        _ = try await drainPrefix(source, lease: lease)
        let waiting = Task { try await lease.next() }
        defer { waiting.cancel() }
        try await wait { source.producer.snapshot().waitingConsumer }
        source.server.stop()
        try await wait { source.producer.sourceFailure.error != nil && source.producer.snapshot().exited }
        let expected = try #require(source.producer.sourceFailure.error)
        #expect((expected as? URLError)?.code == .networkConnectionLost)
        do { _ = try await waiting.value; Issue.record("Failed source delivered a packet") }
        catch { #expect((error as NSError).isEqual(expected as NSError)) }
        let next = source.producer.makeReadLease()
        do { _ = try await next.next(); Issue.record("New lease ignored original source failure") }
        catch { #expect((error as NSError).isEqual(expected as NSError)) }
        do { _ = try next.seekWithinBuffer(to: 0); Issue.record("Failed source accepted a seek") }
        catch { #expect((error as NSError).isEqual(expected as NSError)) }
        #expect(source.producer.snapshot().retained == 0 && !source.producer.snapshot().waitingConsumer)
        await source.producer.cancel()
    }
}

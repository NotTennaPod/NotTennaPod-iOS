import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct FFmpegPacketProducerTests {
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
    private func packets(_ url: URL) throws -> [FFmpegEncodedPacket.Snapshot] {
        let demux = try FFmpegDemuxContext(url: url)
        var result: [FFmpegEncodedPacket.Snapshot] = []
        while let packet = try demux.next() { result.append(packet.snapshot()) }
        return result
    }

    @Test(arguments: names)
    func queuedPacketsRemainReadableWhileHTTPProducerIsBlocked(name: String) async throws {
        let url = try fixture(name), expected = try packets(url), data = try Data(contentsOf: url)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let producer = try await FFmpegPacketProducer.open(input: input)
        do {
            try await wait { input.snapshot().waitingReaders > 0 && producer.snapshot().unread > 32 }
            #expect(producer.snapshot().reading && !producer.snapshot().ended)
            for index in 0..<32 {
                let packet = try #require(try await producer.next())
                #expect(packet.snapshot() == expected[index])
            }
            #expect(input.snapshot().waitingReaders > 0 && producer.snapshot().reading)
        } catch { await producer.cancel(); throw error }
        await producer.cancel()
        #expect(producer.snapshot().cancelled && producer.snapshot().exited && !producer.snapshot().reading)
        #expect(producer.snapshot().retained == 0 && producer.sourceFailure.error == nil)
        #expect(input.snapshot().waitingReaders == 0 && input.snapshot().activeTransfers == 0)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        await #expect(throws: CancellationError.self) { try await producer.next() }
    }

    @Test(arguments: names)
    func fullLocalProducerPreservesEveryPacketAndTerminalEOF(name: String) async throws {
        let url = try fixture(name), expected = try packets(url)
        let producer = try await FFmpegPacketProducer.open(url: url)
        for snapshot in expected {
            let packet = try #require(try await producer.next())
            #expect(packet.snapshot() == snapshot)
        }
        #expect(try await producer.next() == nil)
        #expect(try await producer.next() == nil)
        #expect(producer.snapshot().retained == expected.count && producer.snapshot().ended)
        await producer.cancel()
        #expect(producer.snapshot().exited && producer.snapshot().allocatedBytes == 0)
    }

    @Test func cancellationDuringOpeningWakesAndJoinsNativeRead() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        let opening = Task { try await FFmpegPacketProducer.open(input: input) }
        try await wait { input.snapshot().waitingReaders > 0 }
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(input.snapshot().cancelled && input.snapshot().waitingReaders == 0)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test func droppingOwnerStopsAnOutstandingProducerWithoutCycle() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        var producer: FFmpegPacketProducer? = try await FFmpegPacketProducer.open(input: input)
        weak var observed = producer
        try await wait { input.snapshot().waitingReaders > 0 }
        producer = nil
        #expect(observed == nil)
        try await wait { input.snapshot().cancelled && input.snapshot().waitingReaders == 0 }
        #expect(input.sourceFailure?.subscriberCount == 0)
    }

    @Test func cancellingWaitingConsumerWakesBothSidesAndRejectsConcurrentPull() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        let producer = try await FFmpegPacketProducer.open(input: input)
        let consumer = Task { while try await producer.next() != nil {} }
        do { try await wait { producer.snapshot().waitingConsumer && input.snapshot().waitingReaders > 0 } }
        catch { await producer.cancel(); throw error }
        await #expect(throws: FFmpegPacketProducer.Failure.concurrentRead) { try await producer.next() }
        consumer.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        await producer.cancel()
        #expect(producer.snapshot().exited && !producer.snapshot().waitingConsumer)
        #expect(input.snapshot().waitingReaders == 0 && input.snapshot().cancelled)
    }

    @Test func allocationGateResumesAfterPresentedBackBufferIsDiscarded() async throws {
        let url = try #require(Bundle.module.url(forResource: "long-opus", withExtension: "webm", subdirectory: "Fixtures/PacketProducer"))
        let producer = try await FFmpegPacketProducer.open(url: url, targetBytes: 4 * 1024 * 1024)
        do {
            try await wait { producer.snapshot().waitingForBudget }
            #expect(!producer.snapshot().ended && !producer.snapshot().reading)
            let first = producer.snapshot()
            var lastTime: Int64 = 0
            for _ in 0..<first.unread {
                let packet = try #require(try await producer.next())
                lastTime = packet.presentationTimestamp * 1000 // The fixture's WebM time base is milliseconds.
            }
            #expect(lastTime > 300_000_000 && producer.snapshot().waitingForBudget)
            try producer.updatePlayback(positionMicroseconds: lastTime, speed: 1)
            try await wait { producer.snapshot().unread > 0 }
            let next = try #require(try await producer.next())
            #expect(next.presentationTimestamp * 1000 > lastTime)
            try await wait { producer.snapshot().waitingForBudget || producer.snapshot().ended }
        } catch { await producer.cancel(); throw error }
        await producer.cancel()
        #expect(producer.snapshot().exited && producer.snapshot().retained == 0)
    }

    @Test func sourceFailureWakesProducerWaitingForAllocationBudget() async throws {
        let url = try #require(Bundle.module.url(forResource: "long-opus", withExtension: "webm", subdirectory: "Fixtures/PacketProducer"))
        let data = try Data(contentsOf: url)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        let producer = try await FFmpegPacketProducer.open(input: input, targetBytes: 4 * 1024 * 1024)
        do {
            try await wait { producer.snapshot().waitingForBudget }
            server.stop()
            try await wait { producer.sourceFailure.error != nil && producer.snapshot().exited }
            let expected = try #require(producer.sourceFailure.error)
            #expect((expected as? URLError)?.code == .networkConnectionLost)
            do { _ = try await producer.next(); Issue.record("Failed source returned a packet") }
            catch { #expect((error as NSError).isEqual(expected as NSError)) }
            #expect(producer.snapshot().retained == 0 && !producer.snapshot().waitingForBudget)
            #expect(input.snapshot().cancelled && input.snapshot().activeTransfers == 0)
        } catch { await producer.cancel(); throw error }
        await producer.cancel()
    }
}

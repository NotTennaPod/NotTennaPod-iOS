import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct HTTPCodecDemandTests {
    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(try await condition())
    }
    private func read(_ input: any MediaByteInput, at offset: Int64, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try input.read(at: offset, maximumCount: count) })
            }
        }
    }
    private func exact(_ input: any MediaByteInput, at offset: Int, count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let part = try await read(input, at: Int64(offset + result.count), count: min(4096, count - result.count))
            try #require(!part.isEmpty)
            result.append(part)
        }
        return result
    }
    nonisolated private func chunk(_ bytes: Data) -> Data {
        Data("\(String(bytes.count, radix: 16))\r\n".utf8) + bytes + Data("\r\n".utf8)
    }
    private func media() throws -> Data {
#if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "playback-unknown-duration", withExtension: "mp3", subdirectory: "Fixtures")!
#else
        let url = Bundle(for: DemandFixtures.self).url(forResource: "playback-unknown-duration", withExtension: "mp3")!
#endif
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 1150 * 104)
        return bytes
    }
    private func packet(_ producer: NativeMP3PacketProducer) async throws -> NativeMP3PacketParser.Batch? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try producer.next() }) }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func indexedReadSkipsHeldPrefixWithoutLiftingReadAheadBudget(memory: Bool, shared: Bool) async throws {
        let bytes = Data((0..<900_000).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg",
                    "Content-Range": "bytes \(start)-899999/900000"], body: bytes.subdata(in: start..<bytes.count))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "900000"],
                body: Data(bytes.prefix(8192)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("indexed-demand-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let upstream = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 65_536,
            backing: memory ? .memory(capacity: 131_072) : .disk)
        defer { upstream.cancel() }
        let input: any MediaByteInput = shared ? SharedCachedByteInput(upstream: upstream, cache: cache, url: server.url) : upstream.makeReadLease()
        defer { input.cancel() }
        #expect(try await exact(input, at: 0, count: 32) == bytes.prefix(32))
        input.prepareForIndexedSeek(to: 500_000)
        #expect(try await exact(input, at: 500_000, count: 4096) == bytes.subdata(in: 500_000..<504_096))
        try await wait { upstream.snapshot().waitingForDemand }
        // The seek is served by a range request and does not download the rest of the file.
        let state = upstream.snapshot()
        #expect(server.requests.contains { $0.headers["range"] == "bytes=500000-" })
        #expect(!state.completed && state.failure == nil && state.received < Int64(bytes.count))
        #expect(try await exact(input, at: 0, count: 32) == bytes.prefix(32))
    }

    @Test(arguments: [false, true], [false, true])
    func indexedInitialRangeCanRewindToUncachedBeginning(memory: Bool, shared: Bool) async throws {
        let bytes = Data((0..<900_000).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg",
                    "Content-Range": "bytes \(start)-899999/900000"], body: bytes.subdata(in: start..<bytes.count))
            }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: bytes)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("indexed-rewind-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let upstream = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 65_536,
            backing: memory ? .memory(capacity: 131_072) : .disk)
        defer { upstream.cancel() }
        let input: any MediaByteInput = shared ? SharedCachedByteInput(upstream: upstream, cache: cache, url: server.url) : upstream.makeReadLease()
        defer { input.cancel() }
        input.prepareForIndexedSeek(to: 500_000)
        #expect(try await exact(input, at: 500_000, count: 4096) == bytes.subdata(in: 500_000..<504_096))
        try await wait { upstream.snapshot().waitingForDemand }
        input.prepareForIndexedSeek(to: 0)
        #expect(try await exact(input, at: 0, count: 4096) == bytes.prefix(4096))
        #expect(upstream.snapshot().failure == nil)
    }

    @Test(arguments: [0, 4096, 65_536], [false, true])
    func sequentialReadsBoundDiskGrowthAndRetainRewindBytes(readAhead: Int, knownLength: Bool) async throws {
        let bytes = Data((0..<524288).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { _ in
            knownLength ? .init(headers: ["Content-Type": "audio/mpeg"], body: bytes)
                : .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                    body: chunk(bytes) + Data("0\r\n\r\n".utf8))
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: readAhead)
        defer { input.cancel() }
        for (offset, count) in [(0, 32), (16, 32), (262144, 64)] {
            if offset > 0 { input.prepareForSeek() }
            #expect(try await exact(input, at: offset, count: count) == bytes.subdata(in: offset..<(offset + count)))
            // Parked at the demand this read set: just after a read the download can still be counted as waiting on
            // the previous demand while it writes the next bytes, so the waiter flag alone does not freeze the file.
            try await wait {
                let state = input.snapshot()
                return state.waitingForDemand && state.received == state.sequentialDemandLimit && state.cachedRanges == [0..<state.received]
            }
            // Streaming pauses ahead of playback instead of downloading everything at once.
            let snapshot = input.snapshot()
            #expect(!snapshot.completed && snapshot.received < Int64(bytes.count))
            #expect(snapshot.declaredLength == (knownLength ? Int64(bytes.count) : nil))
            #expect(try Data(contentsOf: input.cacheURL) == bytes.prefix(Int(snapshot.received)))
        }
        #expect(try await exact(input, at: 0, count: 32) == bytes.prefix(32))
        #expect(try await exact(input, at: bytes.count - 32, count: 32) == bytes.suffix(32))
        try await wait { input.snapshot().completed }
        #expect(try await read(input, at: Int64(bytes.count), count: 1).isEmpty)
        #expect(input.length == Int64(bytes.count) && input.supportsRandomAccess)
        #expect(try Data(contentsOf: input.cacheURL) == bytes)
    }

    @Test func cancelledLeasePreservesHeldSourceAndOwnerReleaseRemovesCache() async throws {
        let bytes = Data(repeating: 83, count: 1_048_576)
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: bytes) }
        defer { server.stop() }
        var input: HTTPCodecByteInput? = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 4096)
        let cache = try #require(input).cacheURL
        var lease: (any MediaByteInput)? = try #require(input).makeReadLease()
        #expect(try await exact(try #require(lease), at: 0, count: 16) == bytes.prefix(16))
        try await wait { input?.snapshot().waitingForDemand == true }
        lease?.cancel(); lease = nil
        #expect(input?.snapshot().cancelled == false && FileManager.default.fileExists(atPath: cache.path))
        var next: (any MediaByteInput)? = try #require(input).makeReadLease()
        #expect(try await exact(try #require(next), at: 8192, count: 16) == bytes.subdata(in: 8192..<8208))
        try await wait { input?.snapshot().waitingForDemand == true }
        #expect(server.requests.count == 1)
        next?.cancel(); next = nil
        input = nil
        // Ending playback leaves no stray media file on disk.
        try await wait { !FileManager.default.fileExists(atPath: cache.path) }
    }

    @Test(arguments: [false, true])
    func encodedBudgetPausesDiskGrowthAndPlaybackDemandResumesIt(proxyEnabled: Bool) async throws {
        var bytes = Data()
        let original = try media()
        for _ in 0..<30 { bytes.append(original) }
        let payload = bytes
        let credentials = FeedCredentials(username: "source", password: "captured")
        let proxyAuth = "Basic " + Data("proxy:captured".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled, request.headers["proxy-authorization"] != proxyAuth {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"demand\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "audio/mpeg"], body: payload)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!,
            username: "proxy", password: "captured") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://demand.invalid/media.mp3")! : server.url
        let relay = try await NativeStreamingRelay.start(url: url, playlist: false, proxy: proxy, credentials: credentials)
        defer { relay.cancel() }
        let input = try HTTPCodecByteInput(url: relay.url, sequentialReadAheadBytes: 65_536)
        defer { input.cancel() }
        let producer = NativeMP3PacketProducer(input: input.makeReadLease(), prepareSourceTimeline: true, targetBytes: 2 * 65_536)
        defer { producer.stop() }
        // Both parked: the producer at its budget, the download at the demand the producer's last read set.
        try await wait {
            let state = input.snapshot()
            return producer.snapshot().waitingForBudget && state.waitingForDemand && state.received == state.sequentialDemandLimit
                && state.cachedRanges == [0..<state.received]
        }
        let cached = input.snapshot().received
        #expect(cached < payload.count) // Buffering pauses before the whole episode is downloaded.
        #expect(!input.snapshot().completed && !producer.bufferState.snapshot.isLoading)
        #expect(try Data(contentsOf: input.cacheURL) == payload.prefix(Int(cached)))
        var frames: Int64 = 0
        while producer.snapshot().unreadPackets > 0 {
            let batch = try #require(try await packet(producer))
            #expect(batch.firstFrame == frames)
            frames += batch.frameCount
        }
        // Reading buffered packets frees budget, so a little more may download; what matters is that the
        // download stays bounded instead of fetching the whole episode ahead of playback.
        let drained = input.snapshot().received
        #expect(drained < payload.count && drained <= cached + 2 * 65_536, "cached \(cached), after reading \(drained)")
        try producer.updatePlayback(PCMPlaybackLoadState(positionMicroseconds: (frames - 1152) * 1_000_000 / 44100, speed: 2))
        try await wait { input.snapshot().received > drained && producer.snapshot().parsedFrames > frames }
        producer.stop(); await producer.waitForExit()
        #expect(!input.snapshot().cancelled && FileManager.default.fileExists(atPath: input.cacheURL.path))
        input.cancel()
        try await wait { !input.snapshot().waitingForDemand }
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        #expect(server.requests.filter { !proxyEnabled || $0.headers["proxy-authorization"] == proxyAuth }.count == 1)
    }

    @Test func actualMP3SourceUsesDemandThroughItsDefaultEncodedBudget() async throws {
        var bytes = Data()
        let original = try media()
        for _ in 0..<150 { bytes.append(original) }
        let payload = bytes
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: payload) }
        defer { server.stop() }
        var source: NativeMP3PlaybackSource? = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let decoder = try await #require(source).makeDecoder(prepareSourceTimeline: true)
        let cache = try #require(await source?.cacheURL)
        try await wait {
            guard let network = await source?.networkSnapshot else { return false }
            return decoder.producerSnapshot.waitingForBudget && network.waitingForDemand && network.received == network.sequentialDemandLimit
                && network.cachedRanges == [0..<network.received]
        }
        let snapshot = try #require(await source?.networkSnapshot)
        #expect(snapshot.received < payload.count) // Buffering pauses before the whole episode is downloaded.
        #expect(try Data(contentsOf: cache) == payload.prefix(Int(snapshot.received)))
        await decoder.cancel()
        source = nil
        try await wait { !FileManager.default.fileExists(atPath: cache.path) }
    }
}
private final class DemandFixtures: NSObject {}

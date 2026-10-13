import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct SharedStreamingCacheTests {
    private let a = URL(string: "https://cache.invalid/a.mp3")!
    private let b = URL(string: "https://cache.invalid/b.mp3")!
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("stream-cache-\(UUID())") }
    private func put(_ cache: SharedStreamingCache, url: URL, position: Int64 = 0, bytes: Data, length: Int64) throws {
        let writer = try #require(try cache.beginWrite(for: url, at: position, contentLength: length))
        try writer.append(bytes); try writer.finish()
    }

    @Test func cacheReopensWithExactBytesAndAnExclusiveDirectoryOwner() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var cache: SharedStreamingCache? = try SharedStreamingCache(directory: dir, maximumBytes: 12, fragmentBytes: 4)
        try put(try #require(cache), url: a, bytes: Data([1,2,3,4]), length: 9)
        try put(try #require(cache), url: a, position: 4, bytes: Data([5,6]), length: 9)
        #expect(throws: SharedStreamingCache.Failure.directoryInUse) { try SharedStreamingCache(directory: dir) }
        cache = nil
        let reopened = try SharedStreamingCache(directory: dir, maximumBytes: 12, fragmentBytes: 4)
        #expect(reopened.length(for: a) == 9)
        #expect(reopened.snapshot(for: a).spans == [0..<4, 4..<6])
        let reader = try #require(try reopened.openReader(for: a, at: 2))
        #expect(try reader.read(at: 2, maximumCount: 64) == Data([3,4]))
        #expect(try reopened.openReader(for: a, at: 6) == nil)
    }

    /// The index keeps no entry for a source whose bytes were all evicted (it grew by one entry per
    /// streamed URL forever); a cache hit does not rewrite the index, yet LRU order survives a reopen.
    @Test func evictedSourcesLeaveNoIndexEntryAndHitsPersistLazily() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = URL(string: "https://cache.invalid/c.mp3")!
        var cache: SharedStreamingCache? = try SharedStreamingCache(directory: dir, maximumBytes: 8, fragmentBytes: 4)
        try cache?.admit(.init(length: 4, validation: .strongETag("\"a\"")), for: a)
        try put(try #require(cache), url: a, bytes: Data([1, 2, 3, 4]), length: 4)
        try put(try #require(cache), url: b, bytes: Data([5, 6, 7, 8]), length: 4)
        let manifest = dir.appendingPathComponent("index.json")
        let before = try Data(contentsOf: manifest)
        _ = try cache?.openReader(for: a, at: 0)
        #expect(try Data(contentsOf: manifest) == before, "a hit only reorders in memory")
        cache = nil
        let reopened = try SharedStreamingCache(directory: dir, maximumBytes: 8, fragmentBytes: 4)
        try put(reopened, url: c, bytes: Data([9]), length: 4)
        // b was least recently used (a was read after it): b goes, and with it b's entry.
        #expect(reopened.snapshot(for: a).spans == [0..<4] && reopened.snapshot(for: b).spans.isEmpty)
        #expect(reopened.length(for: b) == nil && reopened.length(for: a) == 4 && reopened.length(for: c) == 4)
        #expect(reopened.representation(for: a)?.validation == .strongETag("\"a\""))
        struct Index: Decodable { var lengths: [String: Int64] }
        #expect(try JSONDecoder().decode(Index.self, from: Data(contentsOf: manifest)).lengths.count == 2)
    }

    @Test func launchSweepRemovesOnlyOrphanedPlaybackTempFiles() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let orphans = ["antennapod-track-bytes-1.cache", "antennapod-codec-2.cache", "antennapod-stream-3.cache",
                       "antennapod-mllt-4.index"]
        let kept = ["antennapod-feeds-2026.opml", "antennapod-mllt-5.tmp", "other.cache", "antennapod-local.index"]
        for name in orphans + kept { try Data([1]).write(to: dir.appendingPathComponent(name)) }
        PlaybackTemporaryFiles.removeOrphaned(in: dir)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == Set(kept))
    }

    /// Keys are memoized per source now; they must stay the SHA-256 hex names that existing caches use.
    @Test func keysStayCompatibleWithExistingCaches() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try SharedStreamingCache(directory: dir, maximumBytes: 12, fragmentBytes: 4)
        for _ in 0..<3 { _ = cache.length(for: a); _ = cache.snapshot(for: b) }
        try put(cache, url: a, bytes: Data([1, 2]), length: 4)
        try put(cache, url: b, bytes: Data([3]), length: 4)
        struct Index: Decodable { var lengths: [String: Int64]; var spans: [Span]; struct Span: Decodable { var key: String } }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: dir.appendingPathComponent("index.json")))
        let expected = [a, b].map { url in
            SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        #expect(Set(index.lengths.keys) == Set(expected) && Set(index.spans.map(\.key)) == Set(expected))
        #expect(cache.snapshot(for: a).spans == [0..<2] && cache.snapshot(for: b).spans == [0..<1])
    }

    @Test func persistedRepresentationRejectsChangedBytesBeforeAdmission() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var cache: SharedStreamingCache? = try SharedStreamingCache(directory: dir)
        let original = HTTPMediaRepresentation(length: 10, validation: .strongETag("\"original\""))
        try cache?.admit(original, for: a)
        try put(try #require(cache), url: a, bytes: Data([1,2,3]), length: 10)
        cache = nil
        let reopened = try SharedStreamingCache(directory: dir)
        #expect(reopened.representation(for: a) == original)
        #expect(throws: URLError.self) {
            try reopened.admit(.init(length: 10, validation: .strongETag("\"changed\"")), for: a)
        }
        #expect(throws: SharedStreamingCache.Failure.conflictingLength) {
            try reopened.admit(.init(length: 11, validation: original.validation), for: a)
        }
        #expect(reopened.representation(for: a) == original)
        #expect(try reopened.openReader(for: a, at: 0)?.read(at: 0, maximumCount: 3) == Data([1,2,3]))
    }

    @Test func legacyUnvalidatedSpansDoNotAcquireAnUnprovenNewValidator() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var cache: SharedStreamingCache? = try SharedStreamingCache(directory: dir)
        try put(try #require(cache), url: a, bytes: Data([1,2,3]), length: 10)
        cache = nil
        let reopened = try SharedStreamingCache(directory: dir)
        try reopened.admit(.init(length: 10, validation: .strongETag("\"new\"")), for: a)
        #expect(reopened.representation(for: a) == .init(length: 10, validation: .unvalidated))
        #expect(try reopened.openReader(for: a, at: 0)?.read(at: 0, maximumCount: 3) == Data([1,2,3]))
    }
    @Test func invalidationFencesLateWritersAndReadersWithoutDeletingANewerIdentity() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try SharedStreamingCache(directory: dir)
        let old = HTTPMediaRepresentation(length: 20, validation: .strongETag("\"old\""))
        let token = cache.generation(for: a)
        try cache.admit(old, for: a, generation: token)
        try put(cache, url: a, bytes: Data([1,2,3]), length: 20)
        let writer = try #require(try cache.beginWrite(for: a, at: 3, contentLength: 20, generation: token))
        try writer.append(Data([4,5]))
        try cache.invalidate(for: a, matching: old)
        #expect(cache.representation(for: a) == nil && cache.snapshot(for: a).spans.isEmpty)
        #expect(throws: SharedStreamingCache.Failure.staleGeneration) { try cache.admit(old, for: a, generation: token) }
        #expect(throws: SharedStreamingCache.Failure.staleGeneration) { try cache.openReader(for: a, at: 0, generation: token) }
        #expect(throws: SharedStreamingCache.Failure.staleGeneration) { try cache.beginWrite(for: a, at: 0, contentLength: 20, generation: token) }
        try writer.append(Data([6])); try writer.finish()
        #expect(cache.snapshot(for: a).spans.isEmpty && cache.snapshot(for: a).writers == 0)
        let fresh = HTTPMediaRepresentation(length: 10, validation: .strongETag("\"new\""))
        try cache.admit(fresh, for: a, generation: cache.generation(for: a))
        try put(cache, url: a, bytes: Data([9,8]), length: 10)
        #expect(throws: SharedStreamingCache.Failure.conflictingRepresentation) {
            try cache.check(cache.generation(for: a), for: a, representation: old)
        }
        try cache.invalidate(for: a, matching: old)
        #expect(cache.representation(for: a) == fresh)
        #expect(try cache.openReader(for: a, at: 0)?.read(at: 0, maximumCount: 2) == Data([9,8]))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.filter { $0.pathExtension == "pending" }.isEmpty)
        #expect(files.filter { $0.pathExtension == "span" }.count == 1)
    }
    @Test func crossEpisodeReadsRefreshLRUAndOpenReadersSurviveEviction() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try SharedStreamingCache(directory: dir, maximumBytes: 8, fragmentBytes: 4)
        try put(cache, url: a, bytes: Data([1,2,3,4]), length: 8)
        let retained = try #require(try cache.openReader(for: a, at: 0))
        try put(cache, url: b, bytes: Data([5,6,7,8]), length: 4)
        _ = try cache.openReader(for: b, at: 0)
        try put(cache, url: a, position: 4, bytes: Data([9,10,11,12]), length: 8)
        #expect(cache.snapshot(for: a).committedBytes == 8)
        #expect(cache.snapshot(for: a).spans == [4..<8])
        #expect(try cache.openReader(for: a, at: 0) == nil)
        #expect(try retained.read(at: 0, maximumCount: 4) == Data([1,2,3,4]))
        #expect(try cache.openReader(for: b, at: 0)?.read(at: 0, maximumCount: 4) == Data([5,6,7,8]))
    }
    @Test func unfinishedFragmentLocksOverlapsAndPublishesOnlyWrittenPrefix() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try SharedStreamingCache(directory: dir, maximumBytes: 32, fragmentBytes: 8)
        var writer: SharedStreamingCache.Writer? = try #require(try cache.beginWrite(for: a, at: 0, contentLength: 20))
        try writer?.append(Data([1,2,3]))
        #expect(try writer?.read(at: 0, maximumCount: 2) == Data([1,2]))
        #expect(cache.snapshot(for: a).spans.isEmpty)
        #expect(try cache.beginWrite(for: a, at: 2, contentLength: 20) == nil)
        #expect(try cache.openReader(for: a, at: 0) == nil)
        writer = nil
        #expect(cache.snapshot(for: a).writers == 0)
        #expect(cache.snapshot(for: a).spans == [0..<3])
        let next = try #require(try cache.beginWrite(for: a, at: 3, contentLength: 20))
        try next.finish()
        #expect(cache.snapshot(for: a).spans == [0..<3])
        #expect(throws: SharedStreamingCache.Failure.conflictingLength) { try cache.setLength(21, for: a) }
    }
    @Test func unknownLengthIsNotCachedAndAdjacentCachedSpanBoundsWriter() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try SharedStreamingCache(directory: dir, maximumBytes: 32, fragmentBytes: 8)
        #expect(try cache.beginWrite(for: a, at: 0, contentLength: nil) == nil)
        #expect(cache.length(for: a) == nil)
        try put(cache, url: a, position: 4, bytes: Data([5,6]), length: 10)
        let writer = try #require(try cache.beginWrite(for: a, at: 0, contentLength: 10))
        #expect(writer.range == 0..<4)
        #expect(throws: SharedStreamingCache.Failure.invalidRange) { try writer.append(Data(repeating: 8, count: 5)) }
        try writer.append(Data([1,2,3,4])); try writer.finish()
        #expect(cache.snapshot(for: a).spans == [0..<4,4..<6])
    }
    @Test func actualDefaultBudgetEvictsOneFiveMiBFragmentAndRetainsTouchedAudio() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try SharedStreamingCache(directory: dir)
        let bytes = Data(repeating: 19, count: 5 * 1024 * 1024), total: Int64 = 21 * 5 * 1024 * 1024
        for index in 0..<20 { try put(cache, url: a, position: Int64(index * bytes.count), bytes: bytes, length: total) }
        _ = try cache.openReader(for: a, at: 0)
        try put(cache, url: a, position: Int64(20 * bytes.count), bytes: bytes, length: total)
        let snapshot = cache.snapshot(for: a)
        #expect(snapshot.committedBytes == 100 * 1024 * 1024)
        #expect(snapshot.spans.count == 20)
        #expect(try cache.openReader(for: a, at: Int64(bytes.count)) == nil)
        #expect(try cache.openReader(for: a, at: 0)?.read(at: 0, maximumCount: 64) == bytes.prefix(64))
    }
    @Test func activeOwnerDropsTruncatedSpanBeforeServingBytes() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try SharedStreamingCache(directory: dir)
        try put(cache, url: a, bytes: Data([1,2,3]), length: 3)
        let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.pathExtension == "span" })
        try Data([1]).write(to: file)
        #expect(try cache.openReader(for: a, at: 0) == nil)
        #expect(cache.snapshot(for: a).committedBytes == 0)
    }
    @Test func restartDropsOrphanPendingAndPurgedSpansWithoutInventingBytes() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var cache: SharedStreamingCache? = try SharedStreamingCache(directory: dir)
        try put(try #require(cache), url: a, bytes: Data([1,2,3]), length: 3)
        cache = nil
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "span" {
            try FileManager.default.removeItem(at: file)
        }
        let pending = dir.appendingPathComponent(UUID().uuidString + ".pending")
        try Data([1,2]).write(to: pending)
        let reopened = try SharedStreamingCache(directory: dir)
        #expect(reopened.length(for: a) == 3 && reopened.snapshot(for: a).spans.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        #expect(try reopened.openReader(for: a, at: 0) == nil)
    }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct SharedMP3CacheTests {
    private func media() throws -> Data {
#if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
#else
        let url = Bundle(for: SharedCacheFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3")!
#endif
        return try Data(contentsOf: url)
    }
    private func drain(_ source: NativeMP3PlaybackSource) async throws -> [Int16] {
        let decoder = try await source.makeDecoder(prepareSourceTimeline: true)
        var samples: [Int16] = []
        do {
            while let packet = try await decoder.next() { samples.append(contentsOf: packet.samples) }
            await decoder.cancel(); return samples
        } catch { await decoder.cancel(); throw error }
    }
    @Test(arguments: [false, true])
    func freshMP3SourceReusesCommittedAudioWithServerOffline(proxyEnabled: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-shared-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var cache: SharedStreamingCache? = try SharedStreamingCache(directory: dir)
        let bytes = try media(), credentials = FeedCredentials(username: "cache", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "audio/mpeg"], body: bytes)
        }
        defer { server.stop() }
        let url = proxyEnabled ? URL(string: "http://shared-cache.invalid/audio.mp3")! : server.url
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        var first: NativeMP3PlaybackSource? = NativeMP3PlaybackSource(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let expected = try await drain(try #require(first))
        #expect(!expected.isEmpty)
        let stagingURL = try #require(await first?.cacheURL)
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
        let firstSnapshot = try #require(cache).snapshot(for: url)
        #expect(firstSnapshot.spans == [0..<Int64(bytes.count)])
        first = nil; cache = nil
        server.stop()
        let reopened = try SharedStreamingCache(directory: dir)
        let second = NativeMP3PlaybackSource(url: url, proxy: proxy, credentials: credentials, cache: reopened)
        #expect(try await drain(second) == expected)
        let network = try #require(await second.networkSnapshot)
        #expect(network.received == 0 && network.activeTransfers == 0)
        #expect(server.requests.count == 1)
    }
    @Test func cancellationPublishesPartialFragmentAndReplacementKeepsCapturedRequest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("partial-shared-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try SharedStreamingCache(directory: dir)
        let bytes = Data((0..<8192).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "8192"], body: Data(bytes.prefix(128)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let raw = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 64, backing: .memory(capacity: 131_072))
        let input = SharedCachedByteInput(upstream: raw, cache: cache, url: server.url)
        defer { input.cancel() }
        let first = input.makeReadLease()
        func read(_ lease: any MediaByteInput, _ offset: Int64, _ count: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(with: Result { try lease.read(at: offset, maximumCount: count) }) }
            }
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(condition())
        }
        #expect(try await read(first, 0, 128) == bytes.prefix(128))
        let pending = Task { try await read(first, 128, 64) }
        defer { pending.cancel(); first.cancel() }
        try await wait { raw.snapshot().waitingReaders == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(cache.snapshot(for: server.url).spans == [0..<128])
        #expect(!raw.snapshot().cancelled)
        let next = input.makeReadLease(); defer { next.cancel() }
        #expect(try await read(next, 0, 128) == bytes.prefix(128))
        try await server.appendResponseBody(Data(bytes.dropFirst(128)), isFinal: true)
        var actual = Data(bytes.prefix(128))
        while actual.count < bytes.count { actual.append(try await read(next, Int64(actual.count), min(4096, bytes.count - actual.count))) }
        #expect(actual == bytes && server.requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: raw.cacheURL.path))
        next.cancel()
        #expect(cache.snapshot(for: server.url).committedBytes == Int64(bytes.count))
    }
    @Test(arguments: [4096, 8192])
    func cacheWriteCrossesExistingSpanWithoutDroppingFollowingBytes(readSize: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-crossing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data((0..<8192).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { _ in .init(body: bytes) }
        defer { server.stop() }
        let cache = try SharedStreamingCache(directory: directory)
        let earlier = try #require(try cache.beginWrite(for: server.url, at: 1000, contentLength: Int64(bytes.count)))
        try earlier.append(bytes.subdata(in: 1000..<1001)); try earlier.finish()
        let raw = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 65_536, backing: .memory(capacity: 131_072))
        let input = SharedCachedByteInput(upstream: raw, cache: cache, url: server.url)
        defer { input.cancel() }
        let lease = input.makeReadLease()
        let actual: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    var result = Data()
                    while result.count < bytes.count {
                        let chunk = try lease.read(at: Int64(result.count), maximumCount: min(readSize, bytes.count - result.count))
                        guard !chunk.isEmpty else { throw SharedStreamingCache.Failure.invalidRange }
                        result.append(chunk)
                    }
                    lease.cancel()
                    return result
                })
            }
        }
        #expect(actual == bytes)
        let snapshot = cache.snapshot(for: server.url)
        #expect(snapshot.committedBytes == Int64(bytes.count) && snapshot.writers == 0)
        var cached = Data()
        while cached.count < bytes.count {
            let reader = try #require(try cache.openReader(for: server.url, at: Int64(cached.count)))
            cached.append(try reader.read(at: Int64(cached.count), maximumCount: 8192))
        }
        #expect(cached == bytes && server.requests.count == 1)
    }

    @Test func chunkedMP3DoesNotBecomeSharedCachedAtEOF() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-live-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try SharedStreamingCache(directory: dir), bytes = try media()
        let wire = Data("\(String(bytes.count, radix: 16))\r\n".utf8) + bytes + Data("\r\n0\r\n\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: wire)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy(), cache: cache)
        #expect(!(try await drain(source)).isEmpty)
        #expect(cache.length(for: server.url) == nil && cache.snapshot(for: server.url).committedBytes == 0)
    }
}
private final class SharedCacheFixtures: NSObject {}

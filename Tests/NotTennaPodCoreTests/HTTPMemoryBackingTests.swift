import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct HTTPMemoryBackingTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        repeat {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < deadline
        try #require(condition())
    }
    private func read(_ input: any MediaByteInput, at offset: Int64, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try input.read(at: offset, maximumCount: count) }) }
        }
    }
    private func exact(_ input: any MediaByteInput, at offset: Int, count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            let part = try await read(input, at: Int64(offset + bytes.count), count: min(4096, count - bytes.count))
            try #require(!part.isEmpty)
            bytes.append(part)
        }
        return bytes
    }
    nonisolated private func rangeStart(_ header: String?) -> Int? {
        guard let header, header.hasPrefix("bytes="), header.hasSuffix("-") else { return nil }
        return Int(header.dropFirst(6).dropLast())
    }
    @Test(arguments: [false, true])
    func inheritedRepresentationSurvivesRetryBeforeNewPacketAdmission(memory: Bool) async throws {
        let payload = Data(repeating: 19, count: 262144), counter = Counter()
        let server = try await LoopbackHTTPServer.start { request in
            if counter.next() == 1 {
                #expect(request.headers["range"] == "bytes=131072-" && request.headers["if-range"] == "\"original\"")
                return .init(status: 503)
            }
            #expect(request.headers["range"] == nil)
            return .init(headers: ["ETag": "\"replacement\""], body: payload)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 65536,
            backing: memory ? .memory(capacity: 131072) : .disk, retry: PCMSourceRetry(sleep: { _ in }),
            expectedRepresentation: .init(length: nil, validation: .strongETag("\"original\"")))
        defer { input.cancel() }
        input.prepareForIndexedSeek(to: 131072)
        await #expect(throws: URLError.self) { try await read(input, at: 131072, count: 32) }
        // A changed file on the server must fail rather than splice foreign bytes into playback.
        #expect(input.snapshot().representationRejected && input.snapshot().received == 0)
    }
    @Test(arguments: [false, true])
    func boundedWindowReacquiresDiscardedBytesAndPreservesFullBodyFallback(ignoreRange: Bool) async throws {
        let payload = Data((0..<524288).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { request in
            if let offset = rangeStart(request.headers["range"]), !ignoreRange {
                #expect(request.headers["if-range"] == "\"stable\"")
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"stable\"",
                    "Content-Range": "bytes \(offset)-\(payload.count-1)/\(payload.count)"], body: Data(payload.dropFirst(offset)))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"stable\""], body: payload)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 65_536, backing: .memory(capacity: 131_072))
        defer { input.cancel() }
        for (offset, count) in [(0,32), (262144,64), (524256,32), (262144,64), (0,32), (262144,64)] {
            #expect(try await exact(input, at: offset, count: count) == payload.subdata(in: offset..<(offset+count)))
            let snapshot = input.snapshot()
            #expect(snapshot.memoryBytes <= 131_072 && snapshot.received <= 131_072)
            #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        }
        #expect(input.length == Int64(payload.count) && input.declaredLength == Int64(payload.count))
        #expect(try await read(input, at: Int64(payload.count), count: 1).isEmpty)
        #expect(server.requests.contains { $0.headers["range"] == "bytes=262144-" })
    }
    @Test func firstCacheMissCanStartAtNonzeroRangeWithoutFetchingCachedPrefix() async throws {
        let payload = Data((0..<262144).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { request in
            let offset = rangeStart(request.headers["range"]) ?? 0
            return .init(status: offset == 0 ? 200 : 206,
                headers: ["Content-Type": "audio/mpeg", "Content-Range": "bytes \(offset)-\(payload.count-1)/\(payload.count)"], body: Data(payload.dropFirst(offset)))
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 65_536,
            backing: .memory(capacity: 131_072, knownLength: Int64(payload.count)))
        defer { input.cancel() }
        #expect(try await exact(input, at: 131072, count: 4096) == payload.subdata(in: 131072..<135168))
        #expect(server.requests.count == 1 && server.requests[0].headers["range"] == "bytes=131072-")
        #expect(input.declaredLength == Int64(payload.count))
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }
    @Test(arguments: [false, true])
    func unknownLengthStreamReadsCompletelyAndCancellationWakesParkedTransfer(cancelAtBoundary: Bool) async throws {
        let payload = Data(repeating: 19, count: 524288)
        let wire = Data("\(String(payload.count, radix:16))\r\n".utf8) + payload + Data("\r\n0\r\n\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: wire) }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 65_536, backing: .memory(capacity: 131_072))
        defer { input.cancel() }
        #expect(try await exact(input, at: 0, count: 32) == payload.prefix(32))
        try await wait { input.snapshot().waitingForDemand }
        if cancelAtBoundary {
            input.cancel()
            try await wait { !input.snapshot().waitingForDemand }
            #expect(input.snapshot().memoryBytes == 0)
        } else {
            #expect(try await exact(input, at: 32, count: payload.count - 32) == payload.dropFirst(32))
            #expect(try await read(input, at: Int64(payload.count), count: 1).isEmpty)
            #expect(input.length == Int64(payload.count))
            #expect(input.snapshot().memoryBytes <= 131_072)
            #expect(try await exact(input, at: 0, count: 32) == payload.prefix(32))
        }
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }
    @Test(arguments: [false, true])
    func chunkedStreamRemainsSeekableAfterEOF(ignoreRange: Bool) async throws {
        let payload = Data((0..<524288).map { UInt8($0 % 251) })
        let wire = Data("\(String(payload.count, radix: 16))\r\n".utf8) + payload + Data("\r\n0\r\n\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { request in
            guard let offset = rangeStart(request.headers["range"]) else {
                return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked", "ETag": "\"stable\""], body: wire)
            }
            #expect(offset == 16 && request.headers["if-range"] == "\"stable\"")
            if ignoreRange { return .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"stable\""], body: payload) }
            return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"stable\"",
                "Content-Range": "bytes \(offset)-\(payload.count-1)/\(payload.count)"], body: Data(payload.dropFirst(offset)))
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 65_536, backing: .memory(capacity: 131_072))
        defer { input.cancel() }
        #expect(try await exact(input, at: 0, count: payload.count) == payload)
        #expect(try await read(input, at: Int64(payload.count), count: 1).isEmpty)
        #expect(input.length == Int64(payload.count))
        #expect(try await exact(input, at: 16, count: 32) == payload.subdata(in: 16..<48))
        #expect(input.length == Int64(payload.count) && input.snapshot().memoryBytes <= 131_072)
    }
    @Test(arguments: [false, true])
    func sharedCacheEvictionReacquiresAudioWithoutCreatingPrivateMediaFiles(proxyEnabled: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-shared-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory, maximumBytes: 131072, fragmentBytes: 32768)
        let payload = Data((0..<2097152).map { UInt8($0 % 251) })
        let credentials = FeedCredentials(username: "bounded", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let start = rangeStart(request.headers["range"]) ?? 0
            if start > 0 { #expect(request.headers["if-range"] == "\"stable\"") }
            return .init(status: start == 0 ? 200 : 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"stable\"",
                "Content-Range": "bytes \(start)-\(payload.count-1)/\(payload.count)"], body: Data(payload.dropFirst(start)))
        }
        defer { server.stop() }
        let originalURL = proxyEnabled ? URL(string: "http://bounded-cache.invalid/media.mp3")! : server.url
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let relay = try await NativeStreamingRelay.start(url: originalURL, playlist: false, proxy: proxy, credentials: credentials)
        defer { relay.cancel() }
        let raw = try HTTPCodecByteInput(url: relay.url, sequentialReadAheadBytes: 65536, backing: .memory(capacity: 131072))
        let source = SharedCachedByteInput(upstream: raw, cache: cache, url: originalURL)
        defer { source.cancel() }
        let first = source.makeReadLease(); defer { first.cancel() }
        var position = 0
        while position < payload.count {
            let bytes = try await read(first, at: Int64(position), count: min(65536, payload.count - position))
            try #require(!bytes.isEmpty)
            #expect(bytes == payload.subdata(in: position..<(position + bytes.count)))
            position += bytes.count
            #expect(raw.snapshot().memoryBytes <= 131072)
            #expect(cache.snapshot(for: originalURL).committedBytes <= 131072)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            let mediaBytes = try files.filter { ["span", "pending"].contains($0.pathExtension) }.reduce(0) {
                $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            #expect(mediaBytes <= 131072)
        }
        first.cancel()
        #expect(try cache.openReader(for: originalURL, at: 1048576) == nil)
        #expect(!FileManager.default.fileExists(atPath: raw.cacheURL.path))
        let replacement = source.makeReadLease(); defer { replacement.cancel() }
        #expect(try await exact(replacement, at: 1048576, count: 4096) == payload.subdata(in: 1048576..<1052672))
        #expect(server.requests.contains { $0.headers["range"] == "bytes=1048576-" })
        #expect(try await exact(replacement, at: 0, count: 4096) == payload.prefix(4096))
        #expect(!FileManager.default.fileExists(atPath: raw.cacheURL.path))
    }
    @Test func changedRepresentationOnUncachedRewindCannotMixWithRetainedBytes() async throws {
        let payload = Data(repeating: 18, count: 524288)
        let counter = Counter()
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "ETag": counter.next() == 1 ? "\"first\"" : "\"changed\""], body: payload)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 65_536, backing: .memory(capacity: 131_072))
        defer { input.cancel() }
        _ = try await exact(input, at: 262144, count: 4096)
        await #expect(throws: URLError.self) { try await read(input, at: 0, count: 32) }
        #expect(input.snapshot().failure != nil)
    }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

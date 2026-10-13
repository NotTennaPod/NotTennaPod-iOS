import Foundation

/// Cache-first reader over a captured media source. The URI key is the original
/// media URL, never the relay URL. Each decoder has its own cursor, open span and
/// provisional fragment; overlapping writers bypass the locked hole.
final class SharedCachedByteInput: MediaByteLeaseSource {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws { try lock.withLock { if cancelled { throw CancellationError() } } }
    }
    private let upstream: HTTPCodecByteInput
    private let cache: SharedStreamingCache
    private let url: URL
    let generation: SharedStreamingCache.Generation
    private let cancellation = Cancellation()
    private let direct: Lease
    var sourceFailure: PCMSourceFailure? { upstream.sourceFailure }
    var sourceRetry: PCMSourceRetry? { upstream.sourceRetry }
    var length: Int64? { cache.length(for: url) ?? upstream.length }
    var declaredLength: Int64? { cache.length(for: url) ?? upstream.declaredLength }
    var initialDeclaredLength: Int64? { upstream.initialDeclaredLength }
    var httpRepresentation: HTTPMediaRepresentation? { upstream.httpRepresentation ?? cache.representation(for: url) }
    var supportsRandomAccess: Bool { upstream.supportsRandomAccess }
    var isWaitingForData: Bool { direct.isWaitingForData }
    init(upstream: HTTPCodecByteInput, cache: SharedStreamingCache, url: URL) {
        self.upstream = upstream; self.cache = cache; self.url = url
        generation = cache.generation(for: url)
        direct = Lease(upstream: upstream.makeReadLease(), cache: cache, url: url, ownerCancellation: cancellation, generation: generation)
    }
    deinit { cancel() }
    func prepareForSeek() { upstream.prepareForSeek() }
    func prepareForIndexedSeek(to offset: Int64) { upstream.prepareForIndexedSeek(to: offset) }
    func checkFailure() throws { try cancellation.check(); try upstream.checkFailure() }
    func read(at offset: Int64, maximumCount: Int) throws -> Data { try direct.read(at: offset, maximumCount: maximumCount) }
    func cancel() { cancellation.cancel(); upstream.cancel(); direct.cancel() }
    func makeReadLease() -> any MediaByteInput {
        Lease(upstream: upstream.makeReadLease(), cache: cache, url: url, ownerCancellation: cancellation, generation: generation)
    }

    /// Reader/writer state uses lock; both cancellation tokens and the upstream
    /// interruption path are independently synchronized.
    private final class Lease: MediaByteInput, @unchecked Sendable {
        private let upstream: any MediaByteInput
        private let cache: SharedStreamingCache
        private let url: URL
        private let generation: SharedStreamingCache.Generation
        private let ownerCancellation: Cancellation
        private let cancellation = Cancellation()
        private let lock = NSLock()
        private var reader: SharedStreamingCache.Reader?
        private var writer: SharedStreamingCache.Writer?
        var sourceFailure: PCMSourceFailure? { upstream.sourceFailure }
        var sourceRetry: PCMSourceRetry? { upstream.sourceRetry }
        var length: Int64? { cache.length(for: url) ?? upstream.length }
        var declaredLength: Int64? { cache.length(for: url) ?? upstream.declaredLength }
        var initialDeclaredLength: Int64? { upstream.initialDeclaredLength }
        var httpRepresentation: HTTPMediaRepresentation? { upstream.httpRepresentation ?? cache.representation(for: url) }
        var supportsRandomAccess: Bool { upstream.supportsRandomAccess }
        var isWaitingForData: Bool { upstream.isWaitingForData }
        init(upstream: any MediaByteInput, cache: SharedStreamingCache, url: URL, ownerCancellation: Cancellation,
             generation: SharedStreamingCache.Generation) {
            self.upstream = upstream; self.cache = cache; self.url = url; self.ownerCancellation = ownerCancellation
            self.generation = generation
        }
        deinit { cancel() }
        func prepareForSeek() { upstream.prepareForSeek() }
        func prepareForIndexedSeek(to offset: Int64) { upstream.prepareForIndexedSeek(to: offset) }
        func checkFailure() throws {
            try cancellation.check(); try ownerCancellation.check(); try upstream.checkFailure()
            try cache.check(generation, for: url, representation: upstream.httpRepresentation)
        }
        func cancel() {
            cancellation.cancel()
            // Wake a blocked native read before waiting for the cache reader lock.
            upstream.cancel()
            lock.withLock {
                do { try writer?.finish() } catch { sourceFailure?.fail(error) }
                writer = nil; reader = nil
            }
        }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try lock.withLock {
                try checkFailure()
                guard offset >= 0, (1...65_536).contains(maximumCount) else { throw SharedStreamingCache.Failure.invalidRange }
                do {
                    if let writer, writer.position != offset {
                        if writer.range.contains(offset), offset < writer.position {
                            return try writer.read(at: offset, maximumCount: maximumCount)
                        }
                        try writer.finish(); self.writer = nil
                    }
                    if let length = cache.length(for: url), offset >= length { return Data() }
                    if reader?.range.contains(offset) != true { reader = try cache.openReader(for: url, at: offset, generation: generation) }
                    if let reader { return try reader.read(at: offset, maximumCount: maximumCount) }
                    let data = try upstream.read(at: offset, maximumCount: maximumCount)
                    try checkFailure()
                    // Each accepted response may resolve the content length and
                    // authorize caching. EOF on a live/chunked response does not.
                    if let known = upstream.declaredLength {
                        try cache.admit(upstream.httpRepresentation ?? .init(length: known, validation: .unvalidated), for: url, generation: generation)
                        try store(data, at: offset, length: known)
                    }
                    if data.isEmpty { try writer?.finish(); writer = nil }
                    return data
                } catch {
                    do { try writer?.finish() } catch { sourceFailure?.fail(error) }
                    writer = nil
                    throw error
                }
            }
        }
        private func store(_ data: Data, at offset: Int64, length: Int64) throws {
            var cursor = 0
            while cursor < data.count {
                let position = offset + Int64(cursor)
                if writer == nil { writer = try cache.beginWrite(for: url, at: position, contentLength: length, generation: generation) }
                guard let writer else {
                    // A network read may cross a previously published span.
                    // Skip only that span, then cache the remaining uncached
                    // bytes in this same read; dropping them requires a reread.
                    if let cached = try cache.openReader(for: url, at: position, generation: generation) {
                        cursor += min(data.count - cursor, Int(cached.range.upperBound - position))
                        continue
                    }
                    return // Concurrently locked hole: don't duplicate its writer.
                }
                let count = min(data.count - cursor, Int(writer.range.upperBound - position))
                try writer.append(data.subdata(in: cursor..<(cursor + count)))
                cursor += count
                if writer.position == writer.range.upperBound { try writer.finish(); self.writer = nil }
            }
        }
    }
}

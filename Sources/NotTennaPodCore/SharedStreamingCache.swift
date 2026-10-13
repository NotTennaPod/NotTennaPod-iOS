import CryptoKit
import Darwin
import Foundation

/// Playback-item-independent, persistent span cache. Callers share one owner per
/// directory; the process lock prevents a second owner from deleting live files.
/// Limits count committed media bytes, as in the reference LRU evictor. Open
/// writers are provisional, and an open reader survives removal of its directory entry.
final class SharedStreamingCache: @unchecked Sendable {
    static let capacity: Int64 = 100 * 1024 * 1024
    static let fragmentSize = 5 * 1024 * 1024
    enum Failure: Error, Equatable { case invalidRange, directoryInUse, invalidIndex, conflictingLength, closedWriter, staleGeneration, conflictingRepresentation }
    private struct Span: Codable {
        let id: UUID
        let key: String
        let position: Int64
        let length: Int64
        var touch: UInt64
        var end: Int64 { position + length }
    }
    private struct Index: Codable {
        var version = 1
        var clock: UInt64 = 0
        var lengths: [String: Int64] = [:]
        var spans: [Span] = []
        // Optional for version1 indexes written before validator retention.
        var validators: [String: String]? = nil
    }
    struct Snapshot: Sendable {
        let committedBytes: Int64
        let spans: [Range<Int64>]
        let writers: Int
    }
    private struct Reservation { let key: String; let range: Range<Int64> }
    let directory: URL
    private let maxBytes: Int64
    private let fragmentBytes: Int
    private let lock = NSLock()
    private let directoryLock: Int32
    private var index: Index
    private var reservations: [UUID: Reservation] = [:]
    struct Generation: Equatable, Sendable { fileprivate let id: UUID? }
    private var generations: [String: UUID] = [:]
    private var keys: [String: String] = [:]
    /// LRU order bumped by cache hits, written with the next structural change (or on close).
    private var touchesPending = false

    init(directory: URL, maximumBytes: Int64 = capacity, fragmentBytes: Int = fragmentSize) throws {
        guard maximumBytes > 0, fragmentBytes > 0 else { throw Failure.invalidRange }
        self.directory = directory
        self.maxBytes = maximumBytes; self.fragmentBytes = fragmentBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(directory.appendingPathComponent("owner.lock").path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw Failure.directoryInUse }
        directoryLock = descriptor
        do {
            let manifest = directory.appendingPathComponent("index.json")
            index = FileManager.default.fileExists(atPath: manifest.path)
                ? try JSONDecoder().decode(Index.self, from: Data(contentsOf: manifest)) : Index()
            guard index.version == 1, index.lengths.values.allSatisfy({ $0 >= 0 }),
                  index.validators?.values.allSatisfy({ HTTPMediaRangeValidation(etag: $0).ifRange == $0 }) ?? true,
                  index.spans.allSatisfy({ span in
                      span.position >= 0 && span.length > 0 && span.length <= Int64(fragmentBytes)
                        && Int128(span.position) + Int128(span.length) <= Int128(index.lengths[span.key] ?? -1)
                        && span.touch <= index.clock
                  }), Set(index.spans.map(\.id)).count == index.spans.count else { throw Failure.invalidIndex }
            for key in Set(index.spans.map(\.key)) {
                let spans = index.spans.filter { $0.key == key }.sorted { $0.position < $1.position }
                for pair in zip(spans, spans.dropFirst()) where pair.0.end > pair.1.position { throw Failure.invalidIndex }
            }
            // An OS purge or interrupted publication creates a cache miss, never fabricated media.
            index.spans.removeAll { span in
                let size = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(span.id.uuidString + ".span").path)[.size] as? NSNumber
                return size?.int64Value != span.length
            }
            let retained = Set(index.spans.map { $0.id.uuidString + ".span" })
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where ["span", "pending"].contains(file.pathExtension) && !retained.contains(file.lastPathComponent) {
                try FileManager.default.removeItem(at: file)
            }
            try evict(required: 0)
            try persist()
        } catch { flock(descriptor, LOCK_UN); Darwin.close(descriptor); throw error }
    }
    deinit {
        if touchesPending { try? persist() }
        flock(directoryLock, LOCK_UN); Darwin.close(directoryLock)
    }


    // Android's default key is the original URI, before redirect resolution;
    // proxy/header identity does not change it. Hashing only changes on-disk naming.
    // Readers ask for the key on every read; hashing and hex-formatting it each time cost ~5 % while
    // streaming in a device profile, so each source's key is computed once. Called with `lock` held.
    private func key(_ url: URL) -> String {
        let source = url.absoluteString
        if let known = keys[source] { return known }
        let digits = Array("0123456789abcdef".utf8)
        var hex = [UInt8](); hex.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(source.utf8)) { hex.append(digits[Int(byte >> 4)]); hex.append(digits[Int(byte & 0x0f)]) }
        let value = String(decoding: hex, as: UTF8.self)
        if keys.count >= 64 { keys.removeAll(keepingCapacity: true) }
        keys[source] = value
        return value
    }
    func length(for url: URL) -> Int64? { lock.withLock { index.lengths[key(url)] } }
    func generation(for url: URL) -> Generation { lock.withLock { Generation(id: generations[key(url)]) } }
    func check(_ generation: Generation, for url: URL, representation: HTTPMediaRepresentation? = nil) throws {
        try lock.withLock {
            let key = key(url)
            try checkGeneration(generation, key: key)
            if let a = representation?.length, let b = index.lengths[key], a != b { throw Failure.conflictingRepresentation }
            if let a = representation?.validation.ifRange, let b = index.validators?[key], a != b { throw Failure.conflictingRepresentation }
        }
    }
    private func checkGeneration(_ generation: Generation?, key: String) throws {
        if let generation, generation.id != generations[key] { throw Failure.staleGeneration }
    }
    /// Retire only the representation that was rejected. Open handles may close
    /// later, but their reservations and reader generation can never republish.
    func invalidate(for url: URL, matching expected: HTTPMediaRepresentation?, generation: Generation? = nil) throws {
        try lock.withLock {
            let key = key(url)
            if let generation, generation.id != generations[key] { return }
            if let current = index.validators?[key], let tag = expected?.validation.ifRange, current != tag { return }
            if let current = index.lengths[key], let length = expected?.length, current != length { return }
            generations[key] = UUID()
            let spans = index.spans.filter { $0.key == key }
            let pending = reservations.filter { $0.value.key == key }.map(\.key)
            for span in spans {
                let file = fileURL(span.id, pending: false)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            for id in pending {
                let file = fileURL(id, pending: true)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                reservations.removeValue(forKey: id)
            }
            index.spans.removeAll { $0.key == key }; index.lengths.removeValue(forKey: key)
            index.validators?.removeValue(forKey: key)
            try persist()
        }
    }
    func representation(for url: URL) -> HTTPMediaRepresentation? {
        lock.withLock {
            let key = key(url)
            guard let length = index.lengths[key] else { return nil }
            return HTTPMediaRepresentation(length: length, validation: HTTPMediaRangeValidation(etag: index.validators?[key]))
        }
    }
    /// Called before bytes are admitted. Do not assign a newly observed tag to
    /// legacy/unvalidated cached bytes whose identity was never established.
    func admit(_ representation: HTTPMediaRepresentation, for url: URL, generation: Generation? = nil) throws {
        try lock.withLock {
            guard let length = representation.length, length >= 0 else { throw Failure.invalidRange }
            let key = key(url)
            try checkGeneration(generation, key: key)
            guard index.lengths[key].map({ $0 == length }) ?? true else { throw Failure.conflictingLength }
            let previous = HTTPMediaRangeValidation(etag: index.validators?[key])
            try previous.validate(etag: representation.validation.ifRange, isFullResponse: true)
            var changed = index.lengths[key] == nil
            index.lengths[key] = length
            if previous.ifRange == nil, let tag = representation.validation.ifRange,
               !index.spans.contains(where: { $0.key == key }), !reservations.values.contains(where: { $0.key == key }) {
                if index.validators == nil { index.validators = [:] }
                index.validators?[key] = tag; changed = true
            }
            if changed { try persist() }
        }
    }
    func setLength(_ length: Int64, for url: URL) throws {
        try lock.withLock {
            guard length >= 0 else { throw Failure.invalidRange }
            let key = key(url)
            guard index.lengths[key].map({ $0 == length }) ?? true else { throw Failure.conflictingLength }
            if index.lengths[key] == nil { index.lengths[key] = length; try persist() }
        }
    }
    func snapshot(for url: URL) -> Snapshot {
        lock.withLock {
            let key = key(url)
            return Snapshot(committedBytes: index.spans.reduce(0) { $0 + $1.length },
                spans: index.spans.filter { $0.key == key }.map { $0.position..<$0.end }.sorted { $0.lowerBound < $1.lowerBound },
                writers: reservations.count)
        }
    }
    func openReader(for url: URL, at position: Int64, generation: Generation? = nil) throws -> Reader? {
        try lock.withLock {
            guard position >= 0 else { throw Failure.invalidRange }
            let key = key(url)
            try checkGeneration(generation, key: key)
            guard let offset = index.spans.firstIndex(where: { $0.key == key && $0.position <= position && position < $0.end }) else { return nil }
            let span = index.spans[offset], file = fileURL(span.id, pending: false)
            let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            guard size?.int64Value == span.length else {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                index.spans.remove(at: offset); try persist(); return nil
            }
            let handle = try FileHandle(forReadingFrom: file)
            do {
                index.spans[offset].touch = try nextTouch()
                touchesPending = true
                return Reader(handle: handle, range: span.position..<span.end)
            } catch { try? handle.close(); throw error }
        }
    }
    /// A nil length deliberately bypasses caching, including streams that later
    /// reveal EOF. Nil also denotes an already cached or concurrently locked hole.
    func beginWrite(for url: URL, at position: Int64, contentLength: Int64?, generation: Generation? = nil) throws -> Writer? {
        try lock.withLock {
            guard position >= 0 else { throw Failure.invalidRange }
            guard let contentLength else { return nil }
            guard position < contentLength else { return nil }
            let key = key(url)
            try checkGeneration(generation, key: key)
            guard index.lengths[key].map({ $0 == contentLength }) ?? true else { throw Failure.conflictingLength }
            guard !index.spans.contains(where: { $0.key == key && $0.position <= position && position < $0.end }) else { return nil }
            let next = index.spans.filter { $0.key == key && $0.position > position }.map(\.position).min() ?? contentLength
            let end = min(contentLength, next, Int64(clamping: Int128(position) + Int128(fragmentBytes)))
            let range = position..<end
            guard !reservations.values.contains(where: { $0.key == key && $0.range.overlaps(range) }) else { return nil }
            index.lengths[key] = contentLength
            try evict(required: end - position, keeping: key)
            try persist()
            let id = UUID(), file = fileURL(id, pending: true)
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forUpdating: file)
            reservations[id] = Reservation(key: key, range: range)
            return Writer(owner: self, id: id, handle: handle, range: range)
        }
    }
    private func fileURL(_ id: UUID, pending: Bool) -> URL { directory.appendingPathComponent(id.uuidString + (pending ? ".pending" : ".span")) }
    private func nextTouch() throws -> UInt64 {
        guard index.clock < .max else { throw Failure.invalidIndex }
        index.clock += 1; return index.clock
    }
    private func persist() throws {
        try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        touchesPending = false
    }
    private func evict(required: Int64, keeping kept: String? = nil) throws {
        var emptied: Set<String> = []
        while index.spans.reduce(Int128(required), { $0 + Int128($1.length) }) > Int128(maxBytes),
              let oldest = index.spans.min(by: { $0.touch < $1.touch }) {
            let file = fileURL(oldest.id, pending: false)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            index.spans.removeAll { $0.id == oldest.id }
            emptied.insert(oldest.key)
        }
        for key in emptied where key != kept { forgetIfUnused(key) }
    }
    /// A source with no cached bytes and no open writer keeps no entry, as Android's content
    /// index drops empty content; its length/validator are learned again if it streams again.
    private func forgetIfUnused(_ key: String) {
        guard !index.spans.contains(where: { $0.key == key }), !reservations.values.contains(where: { $0.key == key }) else { return }
        index.lengths.removeValue(forKey: key)
        index.validators?.removeValue(forKey: key)
    }
    private func finish(_ id: UUID, count: Int64, publish: Bool) throws {
        try lock.withLock {
            guard let reservation = reservations.removeValue(forKey: id) else { return }
            let pending = fileURL(id, pending: true)
            guard publish, count > 0 else { try FileManager.default.removeItem(at: pending); return }
            guard count <= reservation.range.count else { throw Failure.invalidRange }
            try FileManager.default.moveItem(at: pending, to: fileURL(id, pending: false))
            index.spans.append(Span(id: id, key: reservation.key, position: reservation.range.lowerBound,
                length: count, touch: try nextTouch()))
            try evict(required: 0, keeping: reservation.key)
            try persist()
        }
    }

    final class Reader: @unchecked Sendable {
        let range: Range<Int64>
        private let handle: FileHandle
        private let lock = NSLock()
        fileprivate init(handle: FileHandle, range: Range<Int64>) { self.handle = handle; self.range = range }
        deinit { try? handle.close() }
        func read(at position: Int64, maximumCount: Int) throws -> Data {
            try lock.withLock {
                guard range.contains(position), (1...65_536).contains(maximumCount) else { throw Failure.invalidRange }
                let count = min(maximumCount, Int(range.upperBound - position))
                try handle.seek(toOffset: UInt64(position - range.lowerBound))
                guard let data = try handle.read(upToCount: count), data.count == count else { throw CocoaError(.fileReadCorruptFile) }
                return data
            }
        }
    }
    final class Writer: @unchecked Sendable {
        let range: Range<Int64>
        private let owner: SharedStreamingCache
        private let id: UUID
        private let handle: FileHandle
        private let lock = NSLock()
        private var count: Int64 = 0
        private var closed = false
        fileprivate init(owner: SharedStreamingCache, id: UUID, handle: FileHandle, range: Range<Int64>) {
            self.owner = owner; self.id = id; self.handle = handle; self.range = range
        }
        var position: Int64 { lock.withLock { range.lowerBound + count } }
        deinit { try? finish() }
        func read(at position: Int64, maximumCount: Int) throws -> Data {
            try lock.withLock {
                guard !closed, position >= range.lowerBound, position < range.lowerBound + count,
                      (1...65_536).contains(maximumCount) else { throw Failure.invalidRange }
                let size = min(maximumCount, Int(range.lowerBound + count - position))
                try handle.seek(toOffset: UInt64(position - range.lowerBound))
                guard let bytes = try handle.read(upToCount: size), bytes.count == size else { throw CocoaError(.fileReadCorruptFile) }
                return bytes
            }
        }
        func append(_ data: Data) throws {
            try lock.withLock {
                guard !closed else { throw Failure.closedWriter }
                guard Int64(data.count) <= range.upperBound - range.lowerBound - count else { throw Failure.invalidRange }
                do { try handle.seek(toOffset: UInt64(count)); try handle.write(contentsOf: data); count += Int64(data.count) }
                catch {
                    closed = true; try? handle.close(); try? owner.finish(id, count: count, publish: false); throw error
                }
            }
        }
        func finish() throws {
            try lock.withLock {
                guard !closed else { return }; closed = true
                do { try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); try? owner.finish(id, count: count, publish: false); throw error }
                try owner.finish(id, count: count, publish: true)
            }
        }
    }
}

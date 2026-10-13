import Foundation

/// Immutable source-owned references, kept on disk rather than expanding a large
/// bit-packed MLLT tag into a resident array. Queries read only two bracketing
/// records after binary search. File cursor access is serialized by the lock.
final class MP3MLLTSeekTable: @unchecked Sendable {
    let url: URL
    let referenceCount: Int
    private let file: FileHandle
    private let lock = NSLock()

    private init(url: URL, file: FileHandle, count: Int) {
        self.url = url; self.file = file; referenceCount = count
    }
    deinit { try? file.close(); try? FileManager.default.removeItem(at: url) }

    func point(for query: MP3RequiredID3Metadata.Lookup, firstFramePosition: Int64) throws -> MP3SeekIndex.Point? {
        try lock.withLock {
            let forward: Bool, target: Int128
            switch query {
            case .timeMicroseconds(let value): forward = true; target = Int128(max(0, value) / 1000)
            case .bytePosition(let value): forward = false; target = Int128(value)
            }
            func read(_ index: Int) throws -> (x: Int128, y: Int128) {
                try file.seek(toOffset: UInt64(index) * 16)
                guard let bytes = try file.read(upToCount: 16), bytes.count == 16 else { throw CocoaError(.fileReadCorruptFile) }
                let time = bytes.prefix(8).reduce(Int128(0)) { ($0 << 8) | Int128($1) }
                let position = bytes.suffix(8).reduce(Int128(0)) { ($0 << 8) | Int128($1) } + Int128(firstFramePosition)
                return forward ? (time, position) : (position, time)
            }
            var lower = 0, upper = referenceCount
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if try read(middle).x <= target { lower = middle + 1 } else { upper = middle }
            }
            let index = max(0, lower - 1), first = try read(index)
            let x: Int128, y: Int128
            if index + 1 < referenceCount {
                let next = try read(index + 1)
                let fraction = next.x == first.x ? 0 : Double(target - first.x) / Double(next.x - first.x)
                x = target; y = first.y + Int128(fraction * Double(next.y - first.y))
            } else { x = first.x; y = first.y }
            let time = forward ? x * 1000 : y * 1000, position = forward ? y : x
            guard let t = Int64(exactly: time), let p = Int64(exactly: position) else { return nil }
            return .init(timeMicroseconds: t, bytePosition: p)
        }
    }

    /// Confined to the metadata reader's blocking executor. A failed or rejected
    /// tag destroys its temporary table; ownership transfers only on completion.
    final class Builder {
        private let url: URL
        private let file: FileHandle
        private var buffer = Data()
        private var count = 0
        private var lastTime: Int128 = 0, lastPosition: Int128 = 0
        private var valid = true, transferred = false
        private(set) var maximumBufferedBytes = 0

        init(directory: URL = .temporaryDirectory) throws {
            url = directory.appendingPathComponent("antennapod-mllt-\(UUID()).index")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            do { file = try FileHandle(forUpdating: url) }
            catch { try? FileManager.default.removeItem(at: url); throw error }
            try append(milliseconds: 0, position: 0)
        }
        deinit {
            if !transferred { try? file.close(); try? FileManager.default.removeItem(at: url) }
        }
        func append(milliseconds: Int128, position: Int128) throws {
            guard valid else { return }
            guard milliseconds >= lastTime, position >= lastPosition,
                  let time = UInt64(exactly: milliseconds), let byte = UInt64(exactly: position),
                  milliseconds <= Int64.max / 1000, position <= Int64.max else { valid = false; return }
            lastTime = milliseconds; lastPosition = position
            for value in [time, byte] {
                for shift in stride(from: 56, through: 0, by: -8) { buffer.append(UInt8(truncatingIfNeeded: value >> shift)) }
            }
            count += 1; maximumBufferedBytes = max(maximumBufferedBytes, buffer.count)
            if buffer.count == 4096 { try flush() }
        }
        private func flush() throws {
            if !buffer.isEmpty { try file.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        func finish() throws -> MP3MLLTSeekTable? {
            guard valid, !transferred else { return nil }
            try flush(); transferred = true
            return MP3MLLTSeekTable(url: url, file: file, count: count)
        }
    }
}

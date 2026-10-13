import Darwin
import Foundation

/// The facade is never retained by the worker queue, so releasing the last item
/// or reader can wake a blocked upstream acquisition before worker cleanup.
final class PlaybackRetainedByteSource: MediaByteLeaseSource, Sendable {
    typealias Snapshot = PlaybackRetainedByteStorage.Snapshot
    private let storage: PlaybackRetainedByteStorage
    init(input: any MediaByteInput, directory: URL = .temporaryDirectory) throws {
        storage = try PlaybackRetainedByteStorage(input: input, directory: directory)
    }
    deinit { storage.cancel() }
    var sourceFailure: PCMSourceFailure? { storage.sourceFailure }
    var sourceRetry: PCMSourceRetry? { storage.sourceRetry }
    var length: Int64? { storage.length }
    var declaredLength: Int64? { storage.declaredLength }
    var initialDeclaredLength: Int64? { storage.initialDeclaredLength }
    var httpRepresentation: HTTPMediaRepresentation? { storage.httpRepresentation }
    var supportsRandomAccess: Bool { storage.supportsRandomAccess }
    var isWaitingForData: Bool { storage.isWaitingForData }
    func prepareForSeek() {}
    func prepareForIndexedSeek(to offset: Int64) {}
    func cancel() { storage.cancel() }
    func checkFailure() throws { try storage.checkFailure() }
    func read(at offset: Int64, maximumCount: Int) throws -> Data { try storage.read(at: offset, maximumCount: maximumCount) }
    func snapshot() -> Snapshot { storage.snapshot() }
    func makeReadLease() -> any MediaByteInput { OwnedLease(owner: self) }
    private final class OwnedLease: MediaByteInput {
        let owner: PlaybackRetainedByteSource
        let input: any MediaByteInput
        init(owner: PlaybackRetainedByteSource) { self.owner = owner; input = owner.storage.makeReadLease() }
        deinit { input.cancel() }
        var sourceFailure: PCMSourceFailure? { input.sourceFailure }
        var sourceRetry: PCMSourceRetry? { input.sourceRetry }
        var length: Int64? { input.length }
        var declaredLength: Int64? { input.declaredLength }
        var initialDeclaredLength: Int64? { input.initialDeclaredLength }
        var httpRepresentation: HTTPMediaRepresentation? { input.httpRepresentation }
        var supportsRandomAccess: Bool { input.supportsRandomAccess }
        var isWaitingForData: Bool { input.isWaitingForData }
        func prepareForSeek() {}
        func prepareForIndexedSeek(to offset: Int64) {}
        func cancel() { input.cancel() }
        func checkFailure() throws { try input.checkFailure() }
        func read(at offset: Int64, maximumCount: Int) throws -> Data { try input.read(at: offset, maximumCount: maximumCount) }
    }
}

/// One sequential transfer with independent positional readers. Compressed bytes,
/// not decoded pictures, provide history for noninterleaved tracks and backward
/// demux reads. RAM stays bounded by one 64 KiB acquisition; disk grows only with
/// bytes actually requested and is released with the last source/lease owner.
/// We retain history while the item is alive: dropping it would break backward
/// seeking on a server that cannot reproduce an earlier response.
final class PlaybackRetainedByteStorage: MediaByteLeaseSource, @unchecked Sendable {
    struct Snapshot: Sendable {
        let retainedBytes: Int64
        let largestAcquisition: Int
        let activeReaders: Int
        let waitingReaders: Int
        let completed: Bool
        let cancelled: Bool
    }
    private let input: any MediaByteInput
    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "AntennaPod.PlaybackRetainedBytes")
    private let cacheURL: URL
    private var file: FileHandle?
    private var retained: Int64 = 0
    private var largestAcquisition = 0
    private var readers: Set<UUID> = []
    private var demands: [UUID: Int64] = [:]
    private var loading = false, completed = false, cancelled = false
    private var failure: (any Error)?
    private let recordedFailure = PCMSourceFailure()
    private let directID = UUID()

    init(input: any MediaByteInput, directory: URL = .temporaryDirectory) throws {
        self.input = input
        cacheURL = directory.appendingPathComponent("antennapod-track-bytes-\(UUID()).cache")
        guard FileManager.default.createFile(atPath: cacheURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        do { file = try FileHandle(forUpdating: cacheURL) }
        catch { try? FileManager.default.removeItem(at: cacheURL); throw error }
    }
    deinit { cancel() }
    var sourceFailure: PCMSourceFailure? { input.sourceFailure ?? recordedFailure }
    var sourceRetry: PCMSourceRetry? { input.sourceRetry }
    var length: Int64? { condition.withLock { completed ? retained : input.length } }
    var declaredLength: Int64? { input.declaredLength }
    var initialDeclaredLength: Int64? { input.initialDeclaredLength }
    var httpRepresentation: HTTPMediaRepresentation? { input.httpRepresentation }
    var supportsRandomAccess: Bool { condition.withLock { !cancelled && (completed || input.initialDeclaredLength != nil) } }
    var isWaitingForData: Bool { condition.withLock { !demands.isEmpty } && input.isWaitingForData }
    func prepareForSeek() {}
    func prepareForIndexedSeek(to offset: Int64) {}
    func snapshot() -> Snapshot {
        condition.withLock { .init(retainedBytes: retained, largestAcquisition: largestAcquisition,
            activeReaders: readers.count, waitingReaders: demands.count, completed: completed, cancelled: cancelled) }
    }
    func makeReadLease() -> any MediaByteInput { Lease(owner: self) }
    func checkFailure() throws {
        try condition.withLock {
            if cancelled { throw CancellationError() }
            if let failure { throw failure }
        }
        try input.checkFailure()
    }
    func read(at offset: Int64, maximumCount: Int) throws -> Data {
        try read(id: directID, at: offset, maximumCount: maximumCount, direct: true)
    }
    func cancel() {
        condition.lock()
        guard !cancelled else { condition.unlock(); return }
        cancelled = true; demands.removeAll(); condition.broadcast()
        condition.unlock()
        input.cancel() // Wake a blocking upstream read without waiting for its executor.
        condition.withLock {
            try? file?.close(); file = nil
            try? FileManager.default.removeItem(at: cacheURL)
        }
        recordedFailure.finish()
    }
    private func addReader(_ id: UUID) { condition.withLock { _ = readers.insert(id) } }
    private func removeReader(_ id: UUID) {
        condition.withLock { readers.remove(id); demands[id] = nil; condition.broadcast() }
    }
    private func read(id: UUID, at offset: Int64, maximumCount: Int, direct: Bool = false) throws -> Data {
        guard offset >= 0, (1...65_536).contains(maximumCount), offset <= Int64.max - Int64(maximumCount) else {
            throw SharedStreamingCache.Failure.invalidRange
        }
        condition.lock()
        defer { demands[id] = nil; condition.unlock() }
        while true {
            if cancelled || (!direct && !readers.contains(id)) { throw CancellationError() }
            if let failure { throw failure }
            if offset < retained {
                guard let file else { throw CancellationError() }
                let count = Int(min(Int64(maximumCount), retained - offset))
                var data = Data(count: count)
                try data.withUnsafeMutableBytes { buffer in
                    var completed = 0
                    while completed < count {
                        let result = pread(file.fileDescriptor, buffer.baseAddress!.advanced(by: completed),
                            count - completed, offset + Int64(completed))
                        if result < 0, errno == EINTR { continue }
                        guard result > 0 else { throw CocoaError(.fileReadCorruptFile) }
                        completed += result
                    }
                }
                return data
            }
            if completed { return Data() }
            demands[id] = offset + Int64(maximumCount)
            if !loading {
                loading = true
                queue.async { [weak self] in self?.acquire() }
            }
            condition.wait()
        }
    }
    private func acquire() {
        while true {
            condition.lock()
            guard !cancelled, failure == nil, !completed,
                  let through = demands.values.max(), through > retained else {
                loading = false; condition.broadcast(); condition.unlock(); return
            }
            let offset = retained, count = Int(min(65_536, through - retained))
            condition.unlock()
            let result = Result { try input.read(at: offset, maximumCount: count) }
            condition.lock()
            defer { condition.unlock() }
            guard !cancelled else { loading = false; return }
            do {
                let bytes = try result.get()
                guard bytes.count <= count, let file else { throw CocoaError(.fileReadCorruptFile) }
                if bytes.isEmpty { completed = true; loading = false; condition.broadcast(); return }
                largestAcquisition = max(largestAcquisition, bytes.count)
                try bytes.withUnsafeBytes { buffer in
                    var completed = 0
                    while completed < bytes.count {
                        let result = pwrite(file.fileDescriptor, buffer.baseAddress!.advanced(by: completed),
                            bytes.count - completed, offset + Int64(completed))
                        if result < 0, errno == EINTR { continue }
                        guard result > 0 else { throw POSIXError(result == 0 ? .EIO : (.init(rawValue: errno) ?? .EIO)) }
                        completed += result
                    }
                }
                retained += Int64(bytes.count)
                condition.broadcast()
            } catch {
                failure = error; loading = false; sourceFailure?.fail(error); condition.broadcast(); return
            }
        }
    }
    private final class Lease: MediaByteInput {
        let owner: PlaybackRetainedByteStorage
        let id = UUID()
        init(owner: PlaybackRetainedByteStorage) { self.owner = owner; owner.addReader(id) }
        deinit { cancel() }
        var sourceFailure: PCMSourceFailure? { owner.sourceFailure }
        var sourceRetry: PCMSourceRetry? { owner.sourceRetry }
        var length: Int64? { owner.length }
        var declaredLength: Int64? { owner.declaredLength }
        var initialDeclaredLength: Int64? { owner.initialDeclaredLength }
        var httpRepresentation: HTTPMediaRepresentation? { owner.httpRepresentation }
        var supportsRandomAccess: Bool { owner.supportsRandomAccess }
        var isWaitingForData: Bool { owner.condition.withLock { owner.demands[id] != nil } && owner.input.isWaitingForData }
        func prepareForSeek() {}
        func prepareForIndexedSeek(to offset: Int64) {}
        func cancel() { owner.removeReader(id) }
        func checkFailure() throws {
            guard owner.condition.withLock({ owner.readers.contains(id) }) else { throw CancellationError() }
            try owner.checkFailure()
        }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try owner.read(id: id, at: offset, maximumCount: maximumCount)
        }
    }
}

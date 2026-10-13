import Darwin
import Foundation
import Synchronization

/// One captured remote connection, transferred from identification to playback.
/// A bounded prefix is replayed even for live inputs whose bytes are not cached;
/// what identification read beyond it (a large ID3 tag) is kept on item-scoped
/// disk storage, so the decoder continues the original response.
final class PCMRemoteInput: Sendable {
    enum Format: Equatable, Sendable { case mp3, buffered, native(String) }
    enum Failure: Error, Equatable {
        case unidentified, unsupportedFormat(String)
        /// A stream that cannot be read again carries more leading metadata (cover
        /// art) than identification can keep for the decoder (`ProbedBytes.maximumCount`).
        case metadataTooLargeToBuffer
    }
    /// Where and how much identification may keep beyond its in-memory prefix.
    struct Retention: Sendable {
        var directory: URL = .temporaryDirectory
        var limit: Int64 = ProbedBytes.maximumCount
    }
    let relay: NativeStreamingRelay
    let input: HTTPCodecByteInput
    let cached: SharedCachedByteInput
    let retry: PCMSourceRetry
    let userAgent: String
    /// Where the relay is retired when the app may be suspended; replacements use the same.
    let reclaim: StreamingRelayReclaim?
    private let retention: Retention
    private struct Identification: Sendable { var format: Format; var prefix: Data; var probed: ProbedBytes? }
    private let identification: Mutex<Identification>
    var format: Format { identification.withLock { $0.format } }

    private init(relay: NativeStreamingRelay, input: HTTPCodecByteInput, cached: SharedCachedByteInput,
                 retry: PCMSourceRetry, result: Probe.Result, userAgent: String, reclaim: StreamingRelayReclaim?,
                 retention: Retention) {
        self.relay = relay; self.input = input; self.cached = cached
        self.retry = retry; self.userAgent = userAgent; self.reclaim = reclaim; self.retention = retention
        identification = Mutex(Identification(format: result.format, prefix: result.bytes, probed: result.probed))
    }
    deinit { input.cancel(); relay.cancel() }

    static func open(url: URL, proxy: PodcastProxy, credentials: FeedCredentials?, cache: SharedStreamingCache,
                     retry: PCMSourceRetry = PCMSourceRetry(), userAgent: String = HTTPUserAgent.unversioned,
                     reclaim: StreamingRelayReclaim? = .shared,
                     retention: Retention = Retention()) async throws -> PCMRemoteInput {
        try Task.checkCancellation()
        let relay = try await NativeStreamingRelay.start(url: url, playlist: false, proxy: proxy,
            credentials: credentials, userAgent: userAgent, onFailure: { error in retry.recordRelayFailure(error) })
        do {
            try Task.checkCancellation()
            let input = try HTTPCodecByteInput(relay: relay, reclaim: reclaim, sequentialReadAheadBytes: 65_536,
                backing: .memory(capacity: 131_072, knownLength: cache.length(for: url)), retry: retry,
                expectedRepresentation: cache.representation(for: url))
            let cached = SharedCachedByteInput(upstream: input, cache: cache, url: url)
            let lease = cached.makeReadLease()
            defer { lease.cancel() }
            do {
                let probe = Probe(input: lease, retention: retention)
                let result = try await withTaskCancellationHandler {
                    let value = try await probe.identifyWithMediaRejection()
                    try Task.checkCancellation()
                    return value
                } onCancel: { lease.cancel(); input.cancel(); relay.cancel() }
                if result.format == .buffered { input.allowDecoderRangeSeeks() }
                return PCMRemoteInput(relay: relay, input: input, cached: cached, retry: retry,
                    result: result, userAgent: userAgent, reclaim: reclaim, retention: retention)
            } catch {
                input.cancel()
                let rejectedMedia = error as? Probe.RejectedMedia
                if input.snapshot().representationRejected || rejectedMedia != nil {
                    // Identification can reject a cached representation before
                    // a playback owner exists to retire it. Do not leave those
                    // bytes or an unrecognized body blocking every explicit retry.
                    // Finish this probe's writer before fencing its generation;
                    // a newer representation installed elsewhere must survive.
                    lease.cancel()
                    try cache.invalidate(for: url, matching: input.httpRepresentation, generation: cached.generation)
                }
                throw rejectedMedia?.underlying ?? error
            }
        } catch { relay.cancel(); throw error }
    }

    /// After an unprepared load restarts at byte zero, rebuild identification
    /// on the same captured source/retry budget. The item owner serializes this
    /// with retiring its previous metadata/parser/decoder scopes.
    func refreshIdentificationAfterStartupRestart() async throws {
        guard !retry.snapshot.prepared else { throw Failure.unidentified }
        identification.withLock { $0.prefix.removeAll(); $0.probed = nil }
        let lease = cached.makeReadLease()
        defer { lease.cancel() }
        let probe = Probe(input: lease, retention: retention)
        let result = try await withTaskCancellationHandler {
            let result = try await probe.identify()
            try Task.checkCancellation()
            return result
        } onCancel: { lease.cancel() }
        identification.withLock { $0 = Identification(format: result.format, prefix: result.bytes, probed: result.probed) }
        if result.format == .buffered { input.allowDecoderRangeSeeks() }
    }

    func makePlaybackLease() -> any MediaByteLeaseSource { Scope(owner: self) }
    func makeReadLease() -> any MediaByteInput { Scope(owner: self) }

    /// Bytes identification read after its in-memory prefix, contiguous from
    /// `start`, in an unlinked temporary file that lives as long as this object.
    /// A stream without a length is never stored in the shared cache and may
    /// not answer again. Written only while probing; read-only once published.
    /// Readable while the phone is locked after its first unlock, so a queued
    /// episode starts on a locked phone.
    final class ProbedBytes: Sendable {
        /// The most kept for one stream; a longer tag on a stream that cannot be
        /// read again fails identification (`Failure.metadataTooLargeToBuffer`).
        static let maximumCount: Int64 = 64 << 20
        let start: Int64
        private let limit: Int64
        private let descriptor: Int32
        private let count = Mutex<Int64>(0)
        var end: Int64 { start + count.withLock { $0 } }

        init(start: Int64, directory: URL, limit: Int64 = maximumCount) throws {
            let path = directory.appendingPathComponent("antennapod-probe-\(UUID()).bytes").path
            descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
#if os(iOS)
            do {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: path)
            } catch { close(descriptor); unlink(path); throw error }
#endif
            unlink(path)
            self.start = start; self.limit = limit
        }
        deinit { close(descriptor) }

        /// Appends at the end; false once the bound is reached (nothing written).
        func append(_ data: Data) throws -> Bool {
            let written = count.withLock { $0 }
            guard written + Int64(data.count) <= limit else { return false }
            try data.withUnsafeBytes { buffer in
                var done = 0
                while done < buffer.count {
                    let result = pwrite(descriptor, buffer.baseAddress! + done, buffer.count - done, off_t(written) + off_t(done))
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    done += result
                }
            }
            count.withLock { $0 = written + Int64(data.count) }
            return true
        }

        /// The kept bytes at `offset`, or nil outside them.
        func read(at offset: Int64, maximumCount: Int) throws -> Data? {
            let end = self.end
            guard offset >= start, offset < end else { return nil }
            var data = Data(count: Int(min(Int64(maximumCount), end - offset)))
            try data.withUnsafeMutableBytes { buffer in
                var done = 0
                while done < buffer.count {
                    let result = pread(descriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset - start) + off_t(done))
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    done += result
                }
            }
            return data
        }
    }

    /// Synchronous callbacks use a dedicated executor, never a cooperative worker.
    actor Probe {
        nonisolated private let executor = BlockingReadExecutor()
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        let input: any MediaByteInput
        /// Where a stream keeps what it reads beyond the in-memory prefix;
        /// nil for a local file, which the decoder reads again directly.
        let retention: Retention?
        init(input: any MediaByteInput, retention: Retention? = nil) { self.input = input; self.retention = retention }
        struct Result: Sendable {
            let format: Format; let bytes: Data; var probed: ProbedBytes? = nil
        }
        /// Only exhausted media inspection creates this classification. Parser
        /// setup, input failures and cancellation retain their original identity.
        struct RejectedMedia: Error { let underlying: any Error }
        func identify() throws -> Result {
            do { return try identifyWithMediaRejection() }
            catch let rejected as RejectedMedia { throw rejected.underlying }
        }
        func identifyWithMediaRejection() throws -> Result {
            while true {
                do { return try identifyPeriod() }
                catch is PCMSourceRetry.RestartUnprepared {
                    // The source reset to byte zero before admitting audio.
                    // Discard both parser and prefix, retaining retry/cancellation.
                    try Task.checkCancellation()
                    try input.checkFailure()
                }
            }
        }
        private func identifyPeriod() throws -> Result {
            let detector = try StreamingAudioTypeDetector()
            defer { detector.close() }
            var bytes = Data(), nativeFailure: (any Error)?
            // Same bounded probe extent as the bundled demuxer. The retained
            // prefix belongs to this item, not a second HTTP request/download.
            // It always starts at byte zero and stays contiguous: bytes read
            // after it reaches the bound, or after a skip, are not retained.
            let maximum = 1 << 20
            // The latest unretained bytes (at most 64 KiB), so reads stay
            // sequential across a tag end and a header split over several reads.
            var recent = (offset: Int64(0), bytes: Data())
            // A stream's bytes after the prefix, in order, for the decoder's
            // own rereads from byte zero. When the bound or a storage error ends
            // the record, a source that can be read again (a known length, or
            // ranges) gives the decoder those bytes later; one that cannot fails
            // here, with that cause, instead of a later request for lost bytes.
            var probed: ProbedBytes?, recording = retention != nil
            func record(_ data: Data, at position: Int64) throws {
                guard recording, !data.isEmpty, let retention else { return }
                func stop(_ cause: any Error) throws {
                    recording = false
                    guard input.declaredLength != nil || input.supportsRandomAccess else { throw cause }
                }
                do {
                    if probed == nil {
                        // A jump (random access) starts no record; its bytes are read again.
                        guard position == Int64(maximum), bytes.count == maximum else { recording = false; return }
                        probed = try ProbedBytes(start: position, directory: retention.directory, limit: retention.limit)
                    }
                    guard let probed else { return }
                    let end = probed.end
                    if position + Int64(data.count) <= end { return }
                    guard position <= end, try probed.append(Data(data.dropFirst(Int(end - position)))) else {
                        try stop(Failure.metadataTooLargeToBuffer); return
                    }
                } catch let failure as Failure { throw failure }
                catch { try stop(error) }
            }
            func read(at offset: Int64, maximumCount: Int) throws -> Data {
                for (start, data) in [(Int64(0), bytes), (recent.offset, recent.bytes)]
                    where offset >= start && offset < start + Int64(data.count) {
                    let lower = Int(offset - start)
                    return data.subdata(in: lower..<min(data.count, lower + maximumCount))
                }
                if let kept = try probed?.read(at: offset, maximumCount: maximumCount) { return kept }
                try Task.checkCancellation()
                let chunk = try input.read(at: offset, maximumCount: max(maximumCount, 4096))
                let kept = offset == bytes.count ? min(chunk.count, maximum - bytes.count) : 0
                bytes.append(chunk.prefix(kept))
                try record(Data(chunk.dropFirst(kept)), at: offset + Int64(kept))
                if offset + Int64(kept) == recent.offset + Int64(recent.bytes.count) { recent.bytes.append(chunk.dropFirst(kept)) }
                else { recent = (offset + Int64(kept), Data(chunk.dropFirst(kept))) }
                if recent.bytes.count > 65_536 {
                    recent.offset += Int64(recent.bytes.count - 65_536)
                    recent.bytes = Data(recent.bytes.suffix(65_536))
                }
                return Data(chunk.prefix(maximumCount))
            }
            func rejected(_ error: any Error) throws -> Never {
                try Task.checkCancellation()
                try input.checkFailure()
                throw RejectedMedia(underlying: error)
            }
            // Media3's Mp3/Adts/Flac sniffers peek past leading ID3v2 tags of
            // any size (Id3Peeker); large cover art must not exhaust the
            // detection budget. A random-access input (a local file) jumps; a
            // stream is read through in bounded chunks, so a non-range source is
            // consumed sequentially, and the tag is kept on disk (`ProbedBytes`)
            // for the decoder's own metadata and parser reads.
            // A tag that ends beyond EOF is not media, as in Media3.
            var start: Int64 = 0
            while true {
                var header = Data()
                while header.count < 10 {
                    let chunk = try read(at: start + Int64(header.count), maximumCount: 10 - header.count)
                    if chunk.isEmpty { break }
                    header.append(chunk.prefix(10 - header.count))
                }
                guard let length = Self.id3v2TagLength(header) else { break }
                let end = start + length
                if input.supportsRandomAccess {
                    if end > bytes.count, try read(at: end - 1, maximumCount: 1).isEmpty { try rejected(StreamingAudioTypeError.unrecognized) }
                } else {
                    var position = start + Int64(header.count)
                    while position < end {
                        let chunk = try read(at: position, maximumCount: Int(min(65_536, end - position)))
                        if chunk.isEmpty { try rejected(StreamingAudioTypeError.unrecognized) }
                        position += Int64(chunk.count)
                    }
                }
                start = end
            }
            var offset = start, checked = 0
            let limit = start + Int64(maximum)
            while offset < limit {
                let chunk = try read(at: offset, maximumCount: Int(min(4096, limit - offset)))
                if chunk.isEmpty {
                    try Task.checkCancellation()
                    try input.checkFailure()
                    do { return Result(format: classify(try detector.finish()), bytes: bytes, probed: probed) }
                    catch StreamingAudioTypeError.requiresNativePlaylist { throw StreamingAudioTypeError.requiresNativePlaylist }
                    catch { throw RejectedMedia(underlying: nativeFailure ?? error) }
                }
                offset += Int64(chunk.count)
                if bytes.count > checked {
                    checked = bytes.count
                    if PCMFileContainer.isBufferedContainer(bytes) { return Result(format: .buffered, bytes: bytes, probed: probed) }
                }
                if nativeFailure == nil {
                    do { try detector.append(chunk) }
                    catch StreamingAudioTypeError.requiresNativePlaylist { throw StreamingAudioTypeError.requiresNativePlaylist }
                    catch { nativeFailure = error }
                }
                if let type = detector.typeIdentifier { return Result(format: classify(type), bytes: bytes, probed: probed) }
            }
            try rejected(nativeFailure ?? Failure.unidentified)
        }
        /// Header, body and optional v2.4 footer of a structurally valid ID3v2
        /// tag (the checks of `MP3XingMetadata`); nil for anything else.
        static func id3v2TagLength(_ header: Data) -> Int64? {
            guard header.count == 10 else { return nil }
            let b = header.startIndex
            guard header[b] == 0x49, header[b + 1] == 0x44, header[b + 2] == 0x33, (2...4).contains(header[b + 3]),
                  header[b + 4] != 0xff, (6...9).allSatisfy({ header[b + $0] < 128 }) else { return nil }
            let size = (6...9).reduce(Int64(0)) { ($0 << 7) | Int64(header[b + $1]) }
            return 10 + size + (header[b + 3] == 4 && header[b + 5] & 0x10 != 0 ? 10 : 0)
        }
        private func classify(_ type: String) -> Format {
            if type == "public.mp3" { return .mp3 }
            if type == StreamingAudioTypeDetector.bufferedMediaIdentifier { return .buffered }
            return .native(type)
        }
    }

    /// Cancelling a demux/probe scope does not cancel the playback item's source.
    private final class Scope: MediaByteLeaseSource {
        private let owner: PCMRemoteInput
        private let lease: any MediaByteInput
        init(owner: PCMRemoteInput) { self.owner = owner; lease = owner.cached.makeReadLease() }
        deinit { lease.cancel() }
        var sourceFailure: PCMSourceFailure? { lease.sourceFailure }
        var sourceRetry: PCMSourceRetry? { lease.sourceRetry }
        var length: Int64? { lease.length }
        var declaredLength: Int64? { lease.declaredLength }
        var initialDeclaredLength: Int64? { lease.initialDeclaredLength }
        var httpRepresentation: HTTPMediaRepresentation? { lease.httpRepresentation }
        var supportsRandomAccess: Bool { lease.supportsRandomAccess }
        var isWaitingForData: Bool { lease.isWaitingForData }
        func prepareForSeek() { lease.prepareForSeek() }
        func prepareForIndexedSeek(to offset: Int64) { lease.prepareForIndexedSeek(to: offset) }
        func checkFailure() throws { try lease.checkFailure() }
        func cancel() { lease.cancel() }
        func makeReadLease() -> any MediaByteInput { Scope(owner: owner) }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try lease.checkFailure()
            guard offset >= 0, (1...65_536).contains(maximumCount) else { throw SharedStreamingCache.Failure.invalidRange }
            let (prefix, probed) = owner.identification.withLock { state -> (Data?, ProbedBytes?) in
                guard offset < state.prefix.count else { return (nil, state.probed) }
                let end = min(state.prefix.count, Int(offset) + maximumCount)
                return (state.prefix.subdata(in: Int(offset)..<end), nil)
            }
            if let prefix { return prefix }
            if let kept = try probed?.read(at: offset, maximumCount: maximumCount) { return kept }
            do { return try lease.read(at: offset, maximumCount: maximumCount) }
            catch is PCMSourceRetry.RestartUnprepared {
                // A parser may retry this lease from zero. Never replay the
                // identification bytes captured from the failed response.
                owner.identification.withLock { $0.prefix.removeAll(); $0.probed = nil }
                throw PCMSourceRetry.RestartUnprepared()
            }
        }
    }
}

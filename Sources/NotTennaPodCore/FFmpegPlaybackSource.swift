import CoreMedia
import Foundation

/// Playback-item lifetime for the encoded source. Only decoder preparation is
/// serialized; completed decoders consume independent, supersedable read scopes.
/// The factory and each live decoder retain this owner, so the last session can
/// outlive the factory without losing its source/cache.
actor FFmpegPlaybackSource {
    typealias Reopen = @Sendable () async throws -> PCMRemoteInput
    private enum Input: Sendable { case file(LocalAudioBytes), http(HTTPCodecByteInput), remote(PCMRemoteInput) }
    private var input: Input
    private struct RemoteContext: Sendable {
        let url: URL
        let cache: SharedStreamingCache
        let reopen: Reopen
    }
    private let remoteContext: RemoteContext?
    private var needsReopen = false
    private let maximumFrames: Int
    private var reader: FFmpegAudioReader?
    private var seekable: Bool?
    private var operation: (id: UUID, task: Task<FFmpegPCMDecoder, any Error>)?
    private var mediaOperation: (id: UUID, task: Task<FFmpegPlaybackMediaAdapter, any Error>)?
    private var retainedMediaBytes: PlaybackRetainedByteSource?
    private var mediaMetadata: FFmpegMediaMetadata?
    private weak var activeMedia: FFmpegPlaybackMediaAdapter?
    private var selectedAudioTrack: Int32?

    init(url: URL, maximumFrames: Int) throws {
        input = url.isFileURL ? .file(try LocalAudioBytes(url: url)) : .http(try HTTPCodecByteInput(url: url))
        remoteContext = nil
        self.maximumFrames = maximumFrames
    }
    init(file: LocalAudioBytes, maximumFrames: Int) {
        input = .file(file); self.maximumFrames = maximumFrames; remoteContext = nil
    }
    init(input: HTTPCodecByteInput, maximumFrames: Int) {
        self.input = .http(input); self.maximumFrames = maximumFrames; remoteContext = nil
    }

    init(remote: PCMRemoteInput, url: URL, proxy: PodcastProxy, credentials: FeedCredentials?,
         cache: SharedStreamingCache, maximumFrames: Int, reopen: Reopen? = nil) {
        input = .remote(remote); self.maximumFrames = maximumFrames
        let sleep = remote.retry.sleep, userAgent = remote.userAgent, reclaim = remote.reclaim
        remoteContext = RemoteContext(url: url, cache: cache, reopen: reopen ?? {
            try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials,
                cache: cache, retry: PCMSourceRetry(sleep: sleep), userAgent: userAgent, reclaim: reclaim)
        })
    }

    func makeDecoder(start: CMTime) async throws -> FFmpegPCMDecoder {
        try Task.checkCancellation()
        let id = UUID(), previous = operation?.task
        previous?.cancel()
        let task = Task {
            // A canceled native preparation must release its read scope before
            // the next operation can seek or replace the source reader.
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            try await prepareRemoteReplacement()
            while true {
                do { return try await openDecoder(start: start) }
                catch is PCMSourceRetry.RestartUnprepared {
                    guard case .remote(let remote) = input, !remote.retry.snapshot.prepared else { throw PCMSourceRetry.RestartUnprepared() }
                    await retireReader()
                    try await remote.refreshIdentificationAfterStartupRestart()
                    try Task.checkCancellation()
                } catch {
                    let cacheFailure = error as? SharedStreamingCache.Failure
                    let changed = cacheFailure == .staleGeneration || cacheFailure == .conflictingRepresentation
                    try await retireRejectedRepresentation(force: changed)
                    if changed { throw URLError(.resourceUnavailable) }
                    throw error
                }
            }
        }
        operation = (id, task)
        defer { if operation?.id == id { operation = nil } }
        return try await withTaskCancellationHandler {
            let decoder = try await task.value
            do {
                try Task.checkCancellation()
                guard operation?.id == id else { throw CancellationError() }
                return decoder
            } catch { await decoder.cancel(); throw error }
        } onCancel: { task.cancel() }
    }

    private func retireReader() async {
        let old = reader
        reader = nil; seekable = nil
        await old?.cancel()
        await activeMedia?.cancel(); activeMedia = nil
        retainedMediaBytes?.cancel(); retainedMediaBytes = nil; mediaMetadata = nil; selectedAudioTrack = nil
    }

    private func retireRejectedRepresentation(force: Bool = false) async throws {
        guard case .remote(let remote) = input, let context = remoteContext,
              force || remote.input.snapshot().representationRejected else { return }
        let identity = remote.input.httpRepresentation, generation = remote.cached.generation
        await retireReader()
        remote.input.cancel(); remote.relay.cancel(); needsReopen = true
        // Invalidation is conditional on the rejected generation; a newer
        // representation installed by another owner must survive this cleanup.
        try context.cache.invalidate(for: context.url, matching: identity, generation: generation)
    }

    private func prepareRemoteReplacement() async throws {
        guard case .remote(let remote) = input, let context = remoteContext else { return }
        try await retireRejectedRepresentation(force: remote.cached.generation != context.cache.generation(for: context.url))
        let liveReset = remote.retry.snapshot.prepared && remote.input.initialDeclaredLength == nil
            && reader?.bufferState?.snapshot.durationMicroseconds == nil && mediaMetadata?.duration == nil
        if !needsReopen && (remote.retry.requiresDeferredRestart || liveReset) {
            await retireReader()
            remote.input.cancel(); remote.relay.cancel(); needsReopen = true
        }
        if needsReopen {
            // Keep the pending state until identification succeeds, including
            // cancellation or another failure while opening the replacement.
            let replacement = try await context.reopen()
            try Task.checkCancellation()
            guard replacement.format == remote.format else { throw PCMRemoteInput.Failure.unidentified }
            input = .remote(replacement); needsReopen = false
        }
    }

    deinit { retainedMediaBytes?.cancel() }

    /// Metadata comes from the actual captured representation, including video
    /// and nonselected tracks. A filename/container signature is only a candidate.
    func prepareMediaMetadata() async throws -> FFmpegMediaMetadata {
        if let mediaMetadata { return mediaMetadata }
        let input = try mediaInput()
        let probe = try await FFmpegMediaReader.open(input: input.makeReadLease())
        let metadata = probe.metadata
        await probe.cancel()
        try Task.checkCancellation()
        mediaMetadata = metadata
        return metadata
    }

    private func mediaInput() throws -> any MediaByteLeaseSource {
        switch input {
        case .file(let file): return file.lease()
        case .remote(let remote):
            if retainedMediaBytes == nil { retainedMediaBytes = try PlaybackRetainedByteSource(input: remote.makeReadLease()) }
        case .http(let input):
            if retainedMediaBytes == nil { retainedMediaBytes = try PlaybackRetainedByteSource(input: input.makeReadLease()) }
        }
        guard let retainedMediaBytes else { throw FFmpegAudioReader.Failure.invalidFormat }
        return retainedMediaBytes
    }

    func selectAudioTrack(_ id: Int32) async throws {
        let metadata = try await prepareMediaMetadata()
        guard metadata.tracks.contains(where: { $0.id == id && $0.kind == .audio && $0.decodable }) else {
            throw PlaybackTrackSelectionError.invalidTrack
        }
        try Task.checkCancellation()
        selectedAudioTrack = id
    }

    func selectedAudioTrackID() -> Int32? { selectedAudioTrack ?? mediaMetadata?.selectedAudioTrackID }

    func makeMedia(start: CMTime) async throws -> FFmpegPlaybackMediaAdapter {
        let id = UUID(), previous = mediaOperation?.task
        previous?.cancel()
        let task = Task {
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            await activeMedia?.cancel()
            try await prepareRemoteReplacement()
            while true {
                do {
                    let metadata = try await prepareMediaMetadata()
                    let prepared = try await FFmpegPlaybackMediaAdapter.open(input: mediaInput(), metadata: metadata,
                        audioTrackID: selectedAudioTrack, start: metadata.sourceSeekable ? start : .zero, owner: self)
                    activeMedia = prepared
                    return prepared
                } catch is PCMSourceRetry.RestartUnprepared {
                    guard case .remote(let remote) = input, !remote.retry.snapshot.prepared else { throw PCMSourceRetry.RestartUnprepared() }
                    await retireReader()
                    try await remote.refreshIdentificationAfterStartupRestart()
                    try Task.checkCancellation()
                } catch {
                    let failure = error as? SharedStreamingCache.Failure
                    let changed = failure == .staleGeneration || failure == .conflictingRepresentation
                    try await retireRejectedRepresentation(force: changed)
                    if changed { throw URLError(.resourceUnavailable) }
                    throw error
                }
            }
        }
        mediaOperation = (id, task)
        defer { if mediaOperation?.id == id { mediaOperation = nil } }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            do {
                try Task.checkCancellation()
                guard mediaOperation?.id == id else { throw CancellationError() }
                return result
            } catch { await result.cancel(); throw error }
        } onCancel: { task.cancel() }
    }

    private func openDecoder(start: CMTime) async throws -> FFmpegPCMDecoder {
        if reader == nil {
            let opened: FFmpegAudioReader
            switch input {
            case .file(let file):
                opened = try await FFmpegAudioReader.openBuffered(input: file.lease(), maximumFrames: maximumFrames, timing: .media3)
            case .remote(let input):
                opened = try await FFmpegAudioReader.openBuffered(input: (retainedMediaBytes as (any MediaByteLeaseSource)?) ?? input.makePlaybackLease(),
                    maximumFrames: maximumFrames, timing: .media3)
            case .http(let input):
                opened = try await FFmpegAudioReader.openBuffered(input: (retainedMediaBytes as (any MediaByteLeaseSource)?) ?? input.makePlaybackLease(),
                    maximumFrames: maximumFrames, timing: .media3)
            }
            do {
                let preparedSeekability = try await opened.prepareSourceTimeline()
                try Task.checkCancellation()
                seekable = preparedSeekability
                reader = opened
            } catch { await opened.cancel(); throw error }
        }
        guard let reader else { throw FFmpegAudioReader.Failure.invalidFormat }
        do {
            let target = seekable == false ? CMTime.zero : start
            let child = try await reader.makePlaybackReader(to: target)
            return try await FFmpegPCMDecoder.openPrepared(reader: child, start: target, owner: self)
        } catch {
            // Read cancellation leaves a usable source owner intact. A canceled
            // load reset or fatal source failure has retired the parent instead.
            let status = await reader.status
            if status == .cancelled || status == .failed {
                self.reader = nil; seekable = nil
                await reader.cancel()
            }
            throw error
        }
    }

    func producerSnapshot() async -> FFmpegPacketProducer.Snapshot? { await reader?.producerSnapshot() }
}

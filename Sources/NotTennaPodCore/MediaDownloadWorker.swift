import AVFoundation
import AudioToolbox
import Foundation
import Darwin

public protocol MediaTransferring: Sendable {
    func download(_ input: MediaDownloadRequest,
                  progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult
}

extension MediaDownloadTransfer: MediaTransferring {}

public enum MediaDownloadOutcome: Sendable, Equatable {
    case completed, failed(MediaDownloadFailure), interrupted, notStarted
    /// Saved state the attempt needs cannot be reached now (before the first unlock): the job waits, no attempt is
    /// counted, and it is started again once access may have returned (`DownloadCoordinator.resumeParked`).
    case waitingForAccess
}

public actor MediaDownloadWorker {
    private struct Running {
        let token: UUID
        let task: Task<MediaDownloadOutcome, any Error>
    }

    private let store: FeedLibraryStore
    private let transfer: any MediaTransferring
    private let clock: @Sendable () -> Date
    private let wait: @Sendable (TimeInterval) async throws -> Void
    private let duration: @Sendable (URL) async throws -> Int32?
    private let artwork: @Sendable (URL) async throws -> Bool
    private let network: DownloadNetworkMonitor
    private let transcriptLoader: TranscriptLoader?
    private var running: [Int64: Running] = [:]
    private var cancelling: Set<Int64> = []
    private var recovering = false
    private var fileCleanup: Task<Void, any Error>?

    public init(store: FeedLibraryStore, transfer: any MediaTransferring = MediaDownloadTransfer(),
                clock: @escaping @Sendable () -> Date = { Date() },
                wait: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                network: DownloadNetworkMonitor = .shared,
                transcriptLoader: TranscriptLoader? = nil,
                duration: @escaping @Sendable (URL) async throws -> Int32? = MediaDownloadWorker.mediaDuration,
                artwork: @escaping @Sendable (URL) async throws -> Bool = EpisodeArtworkReader.hasArtwork) {
        self.store = store
        self.transfer = transfer
        self.clock = clock
        self.wait = wait
        self.duration = duration
        self.artwork = artwork
        self.network = network; self.transcriptLoader = transcriptLoader
    }

    /// `attemptFailed` receives every failed attempt after it is recorded (the saved job tells whether a
    /// retry follows), so the owner can show Android's per-attempt message.
    /// `accessDenied` is called the moment an attempt finds saved state it cannot reach, before it unwinds.
    public func run(id: Int64, credentials: FeedCredentials? = nil,
                    progress: @escaping @Sendable (MediaDownloadProgress) -> Void = { _ in },
                    attemptFailed: @escaping @Sendable (LibraryDownloadJob, MediaDownloadFailure) async -> Void = { _, _ in },
                    accessDenied: @escaping @Sendable () -> Void = {})
        async throws -> MediaDownloadOutcome {
        guard !recovering, !cancelling.contains(id) else { return .notStarted }
        if let existing = running[id] { return try await existing.task.value }
        try Task.checkCancellation()
        let token = UUID()
        let task = Task { [store, transfer, clock, wait, duration, artwork, network, transcriptLoader] in
            try await Self.execute(id: id, store: store, transfer: transfer, clock: clock, wait: wait,
                                   duration: duration, artwork: artwork, network: network, transcriptLoader: transcriptLoader, credentials: credentials, progress: progress,
                                   attemptFailed: attemptFailed, accessDenied: accessDenied)
        }
        running[id] = Running(token: token, task: task)
        defer { if running[id]?.token == token { running[id] = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func cancel(id: Int64, callerEpisodeID: Int64? = nil, deleteRemovesFromQueue: Bool = false) async throws -> Bool {
        guard !recovering else { throw FeedLibraryError.invalidMutation }
        if let callerEpisodeID {
            guard let job = try await store.downloadJob(id: id), job.state.isActive else { return false }
            guard let caller = try await store.episode(id: callerEpisodeID) else { throw FeedLibraryError.missingEpisode(callerEpisodeID) }
            guard caller.details.media?.url?.utf16.elementsEqual(job.source.utf16) == true else {
                throw FeedLibraryError.invalidMutation
            }
        }
        guard !recovering else { throw FeedLibraryError.invalidMutation }
        guard cancelling.insert(id).inserted else { return false }
        defer { cancelling.remove(id) }
        if let active = running[id] {
            active.task.cancel()
            _ = try await active.task.value
        }
        let cancelled = try await store.cancelDownload(id: id, callerEpisodeID: callerEpisodeID,
                                                       deleteRemovesFromQueue: deleteRemovesFromQueue, now: clock())
        try await cleanCancelledFiles()
        return cancelled
    }

    /// The deletion transaction has removed or cancelled these job records.
    /// Await the writers before unlinking their files, including late transfers.
    public func retireDeletedJobs(_ ids: Set<Int64>) async throws {
        let owned = ids.subtracting(cancelling)
        cancelling.formUnion(owned)
        defer { cancelling.subtract(owned) }
        let tasks = ids.compactMap { running[$0]?.task }
        for task in tasks { task.cancel() }
        for task in tasks { _ = try await task.value }
    }

    public func cleanCancelledFiles() async throws {
        if let fileCleanup { return try await fileCleanup.value }
        let task = Task { try await self.performFileCleanup() }
        fileCleanup = task
        defer { fileCleanup = nil }
        try await task.value
    }

    private func performFileCleanup() async throws {
        for pending in try await store.pendingEffects() {
            switch pending.effect.kind {
            case .deleteDownloadFile(let file, _, let source, _):
                // Legacy local effects must not unlink external paths without a grant.
                guard !source.isLocalFeedSource else { throw FeedLibraryError.invalidMutation }
                // A server library re-checks current references before it deletes (post-commit work, PROTOCOL §15.2).
                if await store.isServerLibrary {
                    try await store.deleteServerDownloadIfUnreferenced(file, remove: Self.deleteIfPresent)
                } else {
                    try Self.deleteIfPresent(file)
                }
                _ = try await store.completeDownloadFileDeletion(effectID: pending.id)
            case .deleteLocalMedia(let reference):
                guard let current = try await store.localFolder(feedID: pending.effect.feedID),
                      current.directoryIdentity == reference.folder.directoryIdentity else {
                    try await store.acknowledgeEffect(id: pending.id); continue
                }
                let documents = LocalFolderDocuments(bookmark: current.bookmark)
                _ = try await documents.delete(fileNamed: reference.filename)
                try await store.completeLocalMediaDeletion(effectID: pending.id, refreshedBookmark: documents.bookmark)
                try await refreshAfterLocalDeletion(pending, identity: reference.folder.directoryIdentity)
            case .refreshAfterLocalMediaDeletion(let identity):
                try await refreshAfterLocalDeletion(pending, identity: identity)
            default: continue
            }
        }
    }

    private func refreshAfterLocalDeletion(_ pending: PendingFeedLibraryEffect, identity: String) async throws {
        if let feed = try await store.feed(id: pending.effect.feedID),
           let folder = try await store.localFolder(feedID: feed.id), folder.directoryIdentity == identity {
            let result = try await LocalFeedRefreshService(store: store).refresh(feedID: feed.id,
                description: feed.metadata.description ?? "", author: feed.metadata.author ?? "")
            switch result {
            case .failed(let failure): throw failure
            case .superseded: throw CancellationError()
            case .updated: break
            }
        }
        try await store.acknowledgeEffect(id: pending.id)
    }

    public func recoverStoppedForegroundWork() async throws {
        guard running.isEmpty, cancelling.isEmpty, !recovering else { throw FeedLibraryError.invalidMutation }
        recovering = true
        defer { recovering = false }
        for job in try await store.downloadJobs() where job.state == .transferring {
            _ = try await store.interruptDownload(id: job.id, attempt: job.attempts, now: clock())
        }
        for job in try await store.downloadJobs(activeOnly: false) where job.fileResetRequired == true {
            try Self.deleteIfPresent(job.destination)
            _ = try await store.acknowledgeDownloadFileReset(id: job.id, attempt: job.attempts)
        }
        try await cleanCancelledFiles()
    }

    public nonisolated static func mediaDuration(_ file: URL) async throws -> Int32? {
        try Task.checkCancellation()
        if let seconds = encodedMP3Duration(file) { return roundedMilliseconds(seconds) }
        let duration = try await AVURLAsset(url: file).load(.duration)
        return roundedMilliseconds(duration.seconds)
    }

    private nonisolated static func roundedMilliseconds(_ seconds: Double) -> Int32? {
        let milliseconds = (seconds * 1000).rounded(.toNearestOrAwayFromZero)
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= Double(Int32.max) else { return nil }
        return Int32(milliseconds)
    }

    private nonisolated static func encodedMP3Duration(_ url: URL) -> Double? {
        // NativeAudioFileInput rather than AudioFileOpenURL: it keeps a flood of tag frames from stalling
        // the download's completion (`ID3FrameFlood`).
        guard let input = try? NativeAudioFileInput(url: url), let handle = input.audioFile else { return nil }
        defer { input.close() }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioFileGetProperty(handle, kAudioFilePropertyDataFormat, &size, &format) == noErr,
              format.mFormatID == kAudioFormatMPEGLayer3 else { return nil }
        var seconds: Float64 = 0
        size = UInt32(MemoryLayout.size(ofValue: seconds))
        guard AudioFileGetProperty(handle, kAudioFilePropertyEstimatedDuration, &size, &seconds) == noErr else { return nil }
        return seconds
    }

    private nonisolated static func execute(id: Int64, store: FeedLibraryStore, transfer: any MediaTransferring,
                                            clock: @Sendable () -> Date,
                                            wait: @Sendable (TimeInterval) async throws -> Void,
                                            duration: @Sendable (URL) async throws -> Int32?,
                                            artwork: @Sendable (URL) async throws -> Bool,
                                            network: DownloadNetworkMonitor,
                                            transcriptLoader: TranscriptLoader?,
                                            credentials: FeedCredentials?,
                                            progress: @escaping @Sendable (MediaDownloadProgress) -> Void,
                                            attemptFailed: @Sendable (LibraryDownloadJob, MediaDownloadFailure) async -> Void,
                                            accessDenied: @Sendable () -> Void) async throws -> MediaDownloadOutcome {
        var currentAttempt: Int?
        do {
            while let pending = try await store.downloadJob(id: id), pending.state == .waiting {
                try Task.checkCancellation()
                if pending.fileResetRequired == true {
                    try deleteIfPresent(pending.destination)
                    guard try await store.acknowledgeDownloadFileReset(id: id, attempt: pending.attempts) else { return .notStarted }
                }
                if let retryAt = pending.retryAt, retryAt > clock() {
                    try await wait(retryAt.timeIntervalSince(clock()))
                    continue
                }
                try await network.waitUntilPermitted(pending.networkConstraint ?? .unmetered)
                try Task.checkCancellation()
                guard let job = try await store.beginDownloadAttempt(id: id, now: clock()) else { return .notStarted }
                currentAttempt = job.attempts
                do {
                    if !FileManager.default.fileExists(atPath: job.destination.path) {
                        try Data().write(to: job.destination, options: .withoutOverwriting)
                    }
                    guard try await store.attachDownloadFile(id: id, attempt: job.attempts) else { return .notStarted }
                    let constraint = job.networkConstraint ?? .unmetered
                    _ = try await network.perform(under: constraint) {
                        try await transfer.download(.init(source: job.source, destination: job.destination, credentials: credentials,
                                                          networkConstraint: constraint, representation: job.representation,
                                                          acceptRepresentation: { representation in
                            guard try await store.acceptDownloadRepresentation(id: id, attempt: job.attempts,
                                                                              representation: representation) else {
                                throw CancellationError()
                            }
                        }), progress: progress)
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    // Saved state that cannot be reached now (before the first unlock) parks the job: no failure is
                    // counted, nothing is deleted, and it is not retried until access may have returned (no loop).
                    if error is SavedStateUnavailable {
                        accessDenied()
                        guard try await store.interruptDownload(id: id, attempt: job.attempts, now: clock()) else { return .notStarted }
                        return .waitingForAccess
                    }
                    if error is DownloadNetworkInterruption {
                        guard try await store.interruptDownload(id: id, attempt: job.attempts, now: clock()) else { return .notStarted }
                        currentAttempt = nil
                        continue
                    }
                    if error is FeedLibraryError { throw error }
                    let failure = MediaDownloadFailure(error)
                    let diagnostic = error is MediaDownloadError || error is MediaDownloadFailure ? nil : error.localizedDescription
                    guard let failed = try await store.recordDownloadFailure(id: id, attempt: job.attempts, failure: failure,
                                                                            diagnostic: diagnostic, now: clock()) else { return .notStarted }
                    currentAttempt = nil
                    if failed.fileResetRequired == true {
                        try deleteIfPresent(failed.destination)
                        _ = try await store.acknowledgeDownloadFileReset(id: id, attempt: failed.attempts)
                    }
                    await attemptFailed(failed, failure)
                    if failed.state == .failed { return .failed(failure) }
                    continue
                }
                if let transcriptLoader, let episode = try await store.episode(id: job.episodeID),
                   let descriptor = episode.details.transcript {
                    do { try await transcriptLoader.storeSidecar(descriptor, media: job.destination) }
                    catch {
                        // Missing/offline transcript never turns successful media into a failed download.
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                    }
                }
                let measured: Int32?
                do { measured = try await duration(job.destination) }
                catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    measured = nil
                }
                try Task.checkCancellation()
                let hasPicture: Bool
                do { hasPicture = try await artwork(job.destination) }
                catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    hasPicture = false
                }
                try Task.checkCancellation()
                return try await store.completeDownload(id: id, attempt: job.attempts, measuredDuration: measured,
                    hasEmbeddedPicture: hasPicture, now: clock()) ? .completed : .notStarted
            }
            return .notStarted
        } catch {
            if Task.isCancelled || error is CancellationError {
                if let attempt = currentAttempt {
                    let interruptedAt = clock()
                    _ = try await Task { try await store.interruptDownload(id: id, attempt: attempt, now: interruptedAt) }.value
                }
                return .interrupted
            }
            throw error
        }
    }

    private nonisolated static func deleteIfPresent(_ file: URL) throws {
        try FeedDeletionCoordinator.unlinkDownload(file)
    }
}

import Darwin
import Foundation
import Synchronization

public struct LocalPlaybackContext: Equatable, Sendable {
    public let episodeID: Int64
    public let reference: LocalDocumentReference
    public let mimeType: String?
}

/// Registered file access only. Backend selection remains with the application's
/// existing playback engine. No provider URL or open handle escapes a read.
public struct LocalPlaybackAccess: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case missingRegistration, notRegularFile, changedDocument, invalidRange, blockingReadOnMainThread
    }
    struct Resolution: Sendable { let directory: URL; let stale: Bool }
    /// Injectable system boundaries permit deterministic grant and I/O failure
    /// tests without pretending that a sandbox file is an external provider.
    struct Environment: Sendable {
        var resolve: @Sendable (Data) throws -> Resolution = { bookmark in
            var stale = false
            let directory = try URL(resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutImplicitStartAccessing], relativeTo: nil, bookmarkDataIsStale: &stale)
            return Resolution(directory: directory, stale: stale)
        }
        var start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stop: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
        var renew: @Sendable (URL) throws -> Data = {
            try $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        var read: @Sendable (FileHandle, Int64, Int) throws -> Data = { file, offset, count in
            try file.seek(toOffset: UInt64(offset))
            return try file.read(upToCount: count) ?? Data()
        }
        /// Starts the pending metadata read of a cloud-first episode for the file playback opened:
        /// one read per playback document, detached at utility priority and not awaited by playback.
        /// The document owns the task and cancels it when it closes. A failure, a different file or
        /// a cancellation leaves the work pending for the next scan or playback.
        var demandMetadata: @Sendable (FeedLibraryStore, LocalPlaybackContext, LocalPlaybackFileIdentity) -> Task<Void, Never> = {
            store, context, identity in
            Task.detached(priority: .utility) {
                _ = try? await LocalPendingMetadata(store: store).fill(episodeID: context.episodeID,
                    reference: context.reference, playbackIdentity: identity)
            }
        }
    }
    private let store: FeedLibraryStore
    private let environment: Environment
    private static let queue = DispatchQueue(label: "org.antennapod.local-playback.open", qos: .utility, attributes: .concurrent)

    public init(store: FeedLibraryStore) { self.init(store: store, environment: Environment()) }
    init(store: FeedLibraryStore, environment: Environment) { self.store = store; self.environment = environment }

    /// Recheck the registered identity after backend preparation, before attach.
    public func confirm(_ document: LocalPlaybackDocument) async throws -> Bool {
        let confirmed = try await store.confirmLocalPlaybackAccess(document.context, refreshedBookmark: document.refreshedBookmark)
        // Playback opened the document, so it is on the device: read metadata it was listed without.
        if confirmed, document.metadataPending {
            document.startMetadataFill { [store, environment] in environment.demandMetadata(store, $0, $1) }
        }
        return confirmed
    }

    /// Nil denotes remote media only. Cancellation/failure releases acquired
    /// access before returning; the caller must fence its own playback generation.
    public func open(episode: LibraryEpisode) async throws -> LocalPlaybackDocument? {
        guard let context = try await store.localPlaybackContext(for: episode) else { return nil }
        let operation = LocalPlaybackOperation()
        return try await withTaskCancellationHandler {
            let document: LocalPlaybackDocument = try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        try operation.check()
                        try LocalFolderDocuments.validateName(context.reference.filename)
                        let resolution = try environment.resolve(context.reference.folder.bookmark)
                        try operation.check()
                        let scope = LocalPlaybackScope(directory: resolution.directory, environment: environment)
                        guard resolution.directory.isFileURL,
                              try resolution.directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                            throw LocalFolderDocuments.Failure.notDirectory
                        }
                        let url = resolution.directory.appendingPathComponent(context.reference.filename, isDirectory: false)
                        let identity = try operation.coordinate(url) { coordinated in
                            let file = try LocalPlaybackFileIdentity.open(coordinated)
                            defer { try? file.close() }
                            return try LocalPlaybackFileIdentity(file: file)
                        }
                        let bookmark = try resolution.stale ? environment.renew(resolution.directory) : context.reference.folder.bookmark
                        try operation.check()
                        return LocalPlaybackDocument(context: context, bookmark: bookmark,
                            resource: LocalPlaybackResource(scope: scope, url: url, identity: identity),
                            metadataPending: episode.details.media?.metadataPending == true)
                    })
                }
            }
            do {
                try Task.checkCancellation()
                guard try await store.confirmLocalPlaybackAccess(context, refreshedBookmark: document.refreshedBookmark) else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                return document
            } catch { document.close(); throw error }
        } onCancel: { operation.cancel() }
    }
}

/// One selected document owns a security scope; each bounded read owns a fresh
/// coordinator and closes its handle before its callback returns. Closing the
/// document cancels all readers while in-flight callbacks retain their scope.
public final class LocalPlaybackDocument: Sendable {
    public static let maximumReadCount = 65_536
    public let context: LocalPlaybackContext
    public let length: Int64
    let refreshedBookmark: Data
    let metadataPending: Bool
    private struct State {
        var resource: LocalPlaybackResource?
        var operations: [UUID: LocalPlaybackOperation] = [:]
        var metadataDemanded = false
        var metadataFill: Task<Void, Never>?
    }
    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "org.antennapod.local-playback.read", qos: .utility)

    fileprivate init(context: LocalPlaybackContext, bookmark: Data, resource: LocalPlaybackResource, metadataPending: Bool = false) {
        self.context = context; refreshedBookmark = bookmark; length = resource.identity.length
        self.metadataPending = metadataPending
        state = Mutex(State(resource: resource))
    }
    deinit { close() }

    public func close() {
        let retired = state.withLock { value in
            let old = value; value.resource = nil; value.operations.removeAll(); value.metadataFill = nil; return old
        }
        retired.operations.values.forEach { $0.cancel() }
        // A metadata read for this document must not commit once it is closed.
        retired.metadataFill?.cancel()
        // The retired resource (and any successful scope) is released outside
        // the lock, after in-flight callbacks release their own resource copies.
    }

    /// The document's one pending-metadata read, for the file it opened. Later requests join it;
    /// closing the document cancels it.
    func startMetadataFill(_ start: (LocalPlaybackContext, LocalPlaybackFileIdentity) -> Task<Void, Never>) {
        let identity: LocalPlaybackFileIdentity? = state.withLock { value in
            guard let resource = value.resource, !value.metadataDemanded else { return nil }
            value.metadataDemanded = true
            return resource.identity
        }
        guard let identity else { return }
        let task = start(context, identity)
        let closed = state.withLock { value in
            guard value.resource != nil else { return true }
            value.metadataFill = task
            return false
        }
        if closed { task.cancel() }
    }

    public func makeReader() -> Reader { Reader(document: self) }

    public func read(at offset: Int64, maximumCount: Int) async throws -> Data {
        try await makeReader().read(at: offset, maximumCount: maximumCount)
    }

    private func begin(_ operation: LocalPlaybackOperation) throws -> LocalPlaybackResource {
        try state.withLock {
            guard let resource = $0.resource else { throw CancellationError() }
            $0.operations[operation.id] = operation
            return resource
        }
    }
    private func finish(_ operation: LocalPlaybackOperation) { _ = state.withLock { $0.operations.removeValue(forKey: operation.id) } }

    private func read(_ resource: LocalPlaybackResource, operation: LocalPlaybackOperation,
                      offset: Int64, maximumCount: Int) throws -> Data {
        try operation.check()
        guard offset >= 0, (1...Self.maximumReadCount).contains(maximumCount) else { throw LocalPlaybackAccess.Failure.invalidRange }
        return try operation.coordinate(resource.url) { url in
            let file = try LocalPlaybackFileIdentity.open(url)
            defer { try? file.close() }
            guard try LocalPlaybackFileIdentity(file: file) == resource.identity else { throw LocalPlaybackAccess.Failure.changedDocument }
            try operation.check()
            let count = Int(min(Int64(maximumCount), max(0, resource.identity.length - offset)))
            let bytes = count == 0 ? Data() : try resource.scope.environment.read(file, offset, count)
            try operation.check()
            guard try LocalPlaybackFileIdentity(file: file) == resource.identity else {
                throw LocalPlaybackAccess.Failure.changedDocument
            }
            // A successful positional read may be shorter than requested. Its
            // caller advances by the returned count, without treating it as a
            // document replacement. Zero progress before known EOF is an I/O error.
            guard bytes.count <= count else { throw LocalPlaybackAccess.Failure.invalidRange }
            if count > 0, bytes.isEmpty {
                throw MediaDownloadError.wrongSize(expected: resource.identity.length, received: offset)
            }
            return bytes
        }
    }

    /// Per-decoder/asset cancellation must not cancel the document or another
    /// consumer. Native decoders use the synchronous entry on their I/O worker;
    /// asynchronous clients always dispatch to this document's dedicated queue.
    public final class Reader: Sendable {
        private let document: LocalPlaybackDocument
        private let operations = Mutex<[UUID: LocalPlaybackOperation]?>([:])
        fileprivate init(document: LocalPlaybackDocument) { self.document = document }
        deinit { cancel() }
        public func cancel() {
            let active = operations.withLock { value in let old = value; value = nil; return old }
            active?.values.forEach { $0.cancel() }
        }
        private func begin() throws -> LocalPlaybackOperation {
            try operations.withLock {
                guard $0 != nil else { throw CancellationError() }
                let operation = LocalPlaybackOperation(); $0?[operation.id] = operation; return operation
            }
        }
        private func finish(_ operation: LocalPlaybackOperation) { _ = operations.withLock { $0?.removeValue(forKey: operation.id) } }

        public func read(at offset: Int64, maximumCount: Int) async throws -> Data {
            try Task.checkCancellation()
            let operation = try begin()
            defer { finish(operation) }
            return try await withTaskCancellationHandler {
                let resource = try document.begin(operation)
                defer { document.finish(operation) }
                let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                    document.queue.async { [document] in
                        continuation.resume(with: Result {
                            try document.read(resource, operation: operation, offset: offset, maximumCount: maximumCount)
                        })
                    }
                }
                try Task.checkCancellation(); try operation.check()
                return bytes
            } onCancel: { operation.cancel() }
        }

        @available(*, noasync, message: "Use read(at:maximumCount:) from asynchronous code")
        public func readSynchronously(at offset: Int64, maximumCount: Int) throws -> Data {
            guard !Thread.isMainThread else { throw LocalPlaybackAccess.Failure.blockingReadOnMainThread }
            let operation = try begin()
            defer { finish(operation) }
            let resource = try document.begin(operation)
            defer { document.finish(operation) }
            return try document.queue.sync {
                try document.read(resource, operation: operation, offset: offset, maximumCount: maximumCount)
            }
        }
    }
}

private final class LocalPlaybackScope: Sendable {
    let directory: URL
    let environment: LocalPlaybackAccess.Environment
    private let started: Bool
    init(directory: URL, environment: LocalPlaybackAccess.Environment) {
        self.directory = directory; self.environment = environment; started = environment.start(directory)
    }
    deinit { if started { environment.stop(directory) } }
}

private struct LocalPlaybackResource: Sendable {
    let scope: LocalPlaybackScope
    let url: URL
    let identity: LocalPlaybackFileIdentity
}

/// Descriptor facts are captured and compared inside coordination. Size and
/// nanosecond change/modification times also reject same-inode edits/truncation.
struct LocalPlaybackFileIdentity: Equatable, Sendable {
    let device: Int32, inode: UInt64, length: Int64
    let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
    static func open(_ url: URL) throws -> FileHandle {
        // A replaced FIFO/device must not block open before the regular-file
        // check. Nonblocking has no effect on admitted regular-file reads.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    init(file: FileHandle) throws {
        var facts = stat()
        guard fstat(file.fileDescriptor, &facts) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard facts.st_mode & S_IFMT == S_IFREG else { throw LocalPlaybackAccess.Failure.notRegularFile }
        device = facts.st_dev; inode = facts.st_ino; length = facts.st_size
        modifiedSeconds = facts.st_mtimespec.tv_sec; modifiedNanoseconds = facts.st_mtimespec.tv_nsec
        changedSeconds = facts.st_ctimespec.tv_sec; changedNanoseconds = facts.st_ctimespec.tv_nsec
    }
}

private final class LocalPlaybackOperation: Sendable {
    let id = UUID()
    private struct State { var cancelled = false; var coordinator: CoordinatorCancellation? }
    private let state = Mutex(State())
    func check() throws { if state.withLock({ $0.cancelled }) { throw CancellationError() } }
    func cancel() {
        let coordinator = state.withLock { $0.cancelled = true; return $0.coordinator }
        coordinator?.cancel()
    }
    func coordinate<Value>(_ url: URL, read: (URL) throws -> Value) throws -> Value {
        try check()
        // Foundation itself opens an existing item before invoking its accessor.
        // Reject a known FIFO/device first; inaccessible/not-yet-materialized
        // provider items still proceed to coordination. This is only a preflight;
        // the authoritative descriptor check remains inside the callback.
        var candidate = stat()
        if fstatat(AT_FDCWD, url.path, &candidate, 0) == 0, candidate.st_mode & S_IFMT != S_IFREG {
            throw LocalPlaybackAccess.Failure.notRegularFile
        }
        let coordinator = NSFileCoordinator()
        try state.withLock {
            guard !$0.cancelled else { throw CancellationError() }
            $0.coordinator = CoordinatorCancellation(coordinator)
        }
        defer { state.withLock { $0.coordinator = nil } }
        var result: Result<Value, any Error>?, error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [.resolvesSymbolicLink], error: &error) { actual in
            result = Result { try check(); let value = try read(actual); try check(); return value }
        }
        try check()
        if let error { throw error }
        guard let result else { throw LocalFolderDocuments.Failure.coordinatorDidNotRun }
        return try result.get()
    }
    /// Foundation explicitly permits cancel() from another thread. All other
    /// coordinator access is confined to the I/O operation that created it.
    private final class CoordinatorCancellation: @unchecked Sendable {
        let coordinator: NSFileCoordinator
        init(_ coordinator: NSFileCoordinator) { self.coordinator = coordinator }
        func cancel() { coordinator.cancel() }
    }
}

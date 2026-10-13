import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// What the file provider says about a listed document's data on this device.
public enum LocalDocumentAvailability: Equatable, Sendable {
    /// Downloaded and current.
    case current
    /// Downloaded, though a newer version may exist elsewhere: still a local file.
    case downloadedStale
    /// The provider positively reports that the data is not on this device (an
    /// evicted or never-downloaded cloud document). Reading it would download it.
    case notDownloaded
    /// Not a cloud document, or the provider did not say: an ordinary local file.
    case unknown

    /// Only a ubiquitous item's own downloading status counts; a missing status is not proof of eviction.
    public init(isUbiquitousItem: Bool?, downloadingStatus: URLUbiquitousItemDownloadingStatus?) {
        guard isUbiquitousItem == true, let downloadingStatus else { self = .unknown; return }
        switch downloadingStatus {
        case .current: self = .current
        case .downloaded: self = .downloadedStale
        case .notDownloaded: self = .notDownloaded
        default: self = .unknown
        }
    }
}

/// File-provider boundary for the linked-folder feature. Operations are coordinated
/// on a dedicated queue; neither UI nor Swift's cooperative executor blocks on providers.
public final class LocalFolderDocuments: Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let identity: String
        public let contentTypeIdentifier, preferredMIMEType: String?
        public let isDirectory, isSymbolicLink: Bool
        public let size: Int64
        public let modified: Date?
        public let resourceIdentity: LocalDocumentResourceIdentity?
        public let availability: LocalDocumentAvailability
    }
    /// Reads a listed URL's availability without opening or downloading it.
    public typealias AvailabilitySource = @Sendable (URL) throws -> LocalDocumentAvailability
    public enum Failure: Error, Equatable, Sendable {
        case notDirectory, invalidName, cannotDeleteDirectory, cannotReadDirectory, coordinatorDidNotRun
        /// Refresh the linked folder before capturing a new deletion action.
        case resourceIdentityUnavailable
    }
    public enum Deletion: Equatable, Sendable { case deleted, alreadyMissing, stale }

    private let bookmarkState: Mutex<Data>
    private let availability: AvailabilitySource
    private let queue = DispatchQueue(label: "org.antennapod.local-documents", qos: .utility)
    public var bookmark: Data { bookmarkState.withLock { $0 } }

    /// Tests supply `availability`; the app reads the provider's ubiquitous-item resource keys.
    public init(bookmark: Data, availability: @escaping AvailabilitySource = { try LocalFolderDocuments.providerAvailability($0) }) {
        bookmarkState = Mutex(bookmark); self.availability = availability
    }

    public static func providerAvailability(_ url: URL) throws -> LocalDocumentAvailability {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return LocalDocumentAvailability(isUbiquitousItem: values.isUbiquitousItem, downloadingStatus: values.ubiquitousItemDownloadingStatus)
    }

    /// Call with the directory URL supplied by the document picker. App-owned
    /// directories do not need an external security scope; actual I/O still checks access.
    public static func makeBookmark(directory: URL) throws -> Data {
        guard directory.isFileURL else { throw Failure.notDirectory }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw Failure.notDirectory }
        return try directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Every immediate child, or a thrown error: a failed listing is never returned in part.
    /// A legacy iCloud placeholder (".Name.icloud") is listed as "Name", not downloaded, when
    /// the provider confirms it; a local file that merely has such a name is listed as itself.
    public func entries() async throws -> [Entry] {
        let availability = self.availability
        return try await perform { folder, coordinator, operation in
            var result: Result<[Entry], any Error>?
            var error: NSError?
            coordinator.coordinate(readingItemAt: folder, options: [], error: &error) { directory in
                result = Result {
                    try operation.checkCancellation()
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey]
                    let listed = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)).map { file in
                        try operation.checkCancellation()
                        let values = try file.resourceValues(forKeys: keys)
                        let state: LocalDocumentAvailability = try values.isDirectory == true ? .unknown : availability(file)
                        if values.isDirectory != true, let placeholder = try Self.placeholder(file, values: values, state: state, probe: availability) {
                            return (entry: placeholder, isPlaceholder: true)
                        }
                        return (entry: Entry(name: file.lastPathComponent, identity: file.absoluteString,
                            contentTypeIdentifier: values.contentType?.identifier, preferredMIMEType: values.contentType?.preferredMIMEType, isDirectory: values.isDirectory == true,
                            isSymbolicLink: values.isSymbolicLink == true, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate,
                            resourceIdentity: try? Self.resourceIdentity(file), availability: state), isPlaceholder: false)
                    }
                    // A document present under its own name wins over a leftover placeholder.
                    let names = Set(listed.filter { !$0.isPlaceholder }.map { Array($0.entry.name.utf16) })
                    return listed.filter { !$0.isPlaceholder || !names.contains(Array($0.entry.name.utf16)) }.map(\.entry)
                }
            }
            if let error { try operation.checkCancellation(); throw error }
            guard let result else { throw Failure.coordinatorDidNotRun }
            return try result.get()
        }
    }

    /// The document name a legacy iCloud placeholder stands for: ".Name.icloud" is "Name".
    static func placeholderName(_ filename: String) -> String? {
        let scalars = Array(filename.unicodeScalars), suffix = Array(".icloud".unicodeScalars)
        guard scalars.count > suffix.count + 1, scalars.first == ".", Array(scalars.suffix(suffix.count)) == suffix else { return nil }
        var name = String.UnicodeScalarView()
        name.append(contentsOf: scalars[1..<(scalars.count - suffix.count)])
        guard (try? validateName(String(name))) != nil else { return nil }
        return String(name)
    }

    /// A placeholder needs provider evidence, from the stub itself or from its document's own URL;
    /// it never has a resource receipt, so no delayed deletion can target the stub. Only a
    /// definite "no such document" makes the stub an ordinary file; any other provider error
    /// fails the listing, so a refresh cannot remove the document's episode on an unanswered question.
    private static func placeholder(_ file: URL, values: URLResourceValues, state: LocalDocumentAvailability,
                                    probe: AvailabilitySource) throws -> Entry? {
        guard let name = placeholderName(file.lastPathComponent) else { return nil }
        let document = file.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
        if state != .notDownloaded {
            let documentState: LocalDocumentAvailability
            do { documentState = try probe(document) }
            catch let error where isMissingDocument(error) { return nil }
            guard documentState == .notDownloaded else { return nil }
        }
        let type = document.pathExtension.isEmpty ? nil : UTType(filenameExtension: document.pathExtension)
        // The stub's bytes are never opened (undocumented, possibly not resident). Its document's own
        // size key is used when the provider answers it; the size otherwise arrives with the next scan.
        let size = (try? document.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        return Entry(name: name, identity: document.absoluteString, contentTypeIdentifier: type?.identifier,
            preferredMIMEType: type?.preferredMIMEType, isDirectory: false, isSymbolicLink: false,
            size: Int64(size), modified: values.contentModificationDate, resourceIdentity: nil, availability: .notDownloaded)
    }

    static func isMissingDocument(_ error: any Error) -> Bool {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileReadNoSuchFileError), (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSPOSIXErrorDomain, Int(ENOENT)): return true
        default: return false
        }
    }

    /// Enumerate and read actual native/codec metadata while each file's
    /// coordinated access remains active.
    public func scanInput() async throws -> LocalFolderScanInput {
        try await scanInput { url, check in
            try LocalMediaMetadataReader.read(url: url, checkCancellation: check)
        }
    }

    /// Alternate owned readers support other providers and deterministic tests.
    public func scanInput(
        readMetadata: @escaping @Sendable (URL, @Sendable () throws -> Void) throws -> LocalFileMetadata
    ) async throws -> LocalFolderScanInput {
        let entries = try await entries()
        let files = entries.filter { !$0.isDirectory }.map { entry in
            LocalFeedFile(name: entry.name, identity: entry.identity,
                providerMIMEType: entry.preferredMIMEType,
                mediaMIMEType: FeedMIME.resolve(entry.preferredMIMEType, url: entry.identity),
                size: entry.size, modified: entry.modified ?? Date(timeIntervalSince1970: 0), availability: entry.availability)
        }
        try Task.checkCancellation()
        let resources = entries.compactMap { entry in
            entry.resourceIdentity.map { LocalDocumentResourceReceipt(filename: entry.name, identity: $0) }
        }
        // Directories are never read as media or artwork, but their names are present too.
        return LocalFolderScanInput(files: files, presentNames: entries.map(\.name), bookmark: { self.bookmark },
                                    documentResources: resources, readMetadata: { file in
            try await self.read(fileNamed: file.name) { url, check in
                let expected = resources.first { $0.filename.utf16.elementsEqual(file.name.utf16) }?.identity
                if let expected, try Self.resourceIdentity(url) != expected { throw LocalPlaybackAccess.Failure.changedDocument }
                let result = try readMetadata(url, check)
                if let expected, try Self.resourceIdentity(url) != expected { throw LocalPlaybackAccess.Failure.changedDocument }
                return result
            }
        })
    }

    /// Inspect one child while coordination and the directory grant remain active.
    /// The reader runs synchronously on the dedicated I/O queue. It must close any
    /// native handles before returning, and poll the supplied probe during long reads.
    /// Returning a URL/handle for later I/O does not extend this access lifetime.
    public func read<Value: Sendable>(fileNamed name: String,
        _ reader: @escaping @Sendable (URL, @Sendable () throws -> Void) throws -> Value
    ) async throws -> Value {
        try Self.validateName(name)
        return try await perform { folder, coordinator, operation in
            let file = folder.appendingPathComponent(name, isDirectory: false)
            var result: Result<Value, any Error>?
            var error: NSError?
            coordinator.coordinate(readingItemAt: file, options: [.resolvesSymbolicLink], error: &error) { coordinatedFile in
                result = Result {
                    try operation.checkCancellation()
                    guard try coordinatedFile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else {
                        throw Failure.cannotReadDirectory
                    }
                    let value = try reader(coordinatedFile, { try operation.checkCancellation() })
                    // No read result from a canceled operation may reach the scanner.
                    try operation.checkCancellation()
                    return value
                }
            }
            if let error { try operation.checkCancellation(); throw error }
            guard let result else { throw Failure.coordinatorDidNotRun }
            return try result.get()
        }
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw Failure.invalidName }
    }

    /// The caller must obtain any required user confirmation before this operation.
    /// Delete only one named child; never interpret a feed filename as a path/URL.
    public func delete(fileNamed name: String) async throws -> Deletion {
        try await delete(fileNamed: name, expected: nil)
    }

    /// Delayed actions require the resource observed by their authoritative scan.
    /// Missing legacy/provider identity is not permission to acquire a new target.
    public func delete(_ reference: LocalDocumentReference) async throws -> Deletion {
        guard let expected = reference.resourceIdentity else { throw Failure.resourceIdentityUnavailable }
        guard expected.size == reference.size else { return .stale }
        return try await delete(fileNamed: reference.filename, expected: expected)
    }

    private func delete(fileNamed name: String, expected: LocalDocumentResourceIdentity?) async throws -> Deletion {
        try Self.validateName(name)
        return try await perform { folder, coordinator, operation in
            let file = folder.appendingPathComponent(name, isDirectory: false)
            var result: Result<Deletion, any Error>?
            var error: NSError?
            coordinator.coordinate(writingItemAt: file, options: .forDeleting, error: &error) { coordinatedFile in
                result = Result {
                    try operation.checkCancellation()
                    do {
                        if let expected, try Self.resourceIdentity(coordinatedFile) != expected { return .stale }
                        let values = try coordinatedFile.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        // A symlink is removed as a link; its target is never recursively deleted.
                        guard values.isDirectory != true || values.isSymbolicLink == true else { throw Failure.cannotDeleteDirectory }
                        try FileManager.default.removeItem(at: coordinatedFile)
                        // Do not report cancellation after a deletion has committed.
                        return .deleted
                    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                        return .alreadyMissing
                    }
                }
            }
            if let error { try operation.checkCancellation(); throw error }
            guard let result else { throw Failure.coordinatorDidNotRun }
            return try result.get()
        }
    }

    static func resourceIdentity(_ url: URL) throws -> LocalDocumentResourceIdentity {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        if status != 0, errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return .init(device: Int64(info.st_dev), inode: UInt64(info.st_ino),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            size: Int64(info.st_size))
    }

    private func perform<Value: Sendable>(
        _ body: @escaping @Sendable (URL, NSFileCoordinator, Operation) throws -> Value
    ) async throws -> Value {
        let operation = Operation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try operation.checkCancellation()
                        var stale = false
                        let directory = try URL(resolvingBookmarkData: bookmark,
                            options: [.withoutUI, .withoutImplicitStartAccessing], relativeTo: nil, bookmarkDataIsStale: &stale)
                        let scoped = directory.startAccessingSecurityScopedResource()
                        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
                        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw Failure.notDirectory }
                        if stale {
                            let refreshed = try Self.makeBookmark(directory: directory)
                            bookmarkState.withLock { $0 = refreshed }
                        }
                        let coordinator = NSFileCoordinator()
                        try operation.install(coordinator)
                        defer { operation.finish() }
                        continuation.resume(returning: try body(directory, coordinator, operation))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { operation.cancel() }
    }

    private final class Operation: Sendable {
        private struct State { var cancelled = false; var cancellation: CoordinatorCancellation? }
        private let state = Mutex(State())
        func install(_ coordinator: NSFileCoordinator) throws {
            try state.withLock {
                guard !$0.cancelled else { throw CancellationError() }
                $0.cancellation = CoordinatorCancellation(coordinator)
            }
        }
        func checkCancellation() throws {
            if state.withLock({ $0.cancelled }) { throw CancellationError() }
        }
        func cancel() { state.withLock { $0.cancelled = true; $0.cancellation?.cancel() } }
        func finish() { state.withLock { $0.cancellation = nil } }
    }
    /// NSFileCoordinator is confined to the I/O queue except cancel(), which
    /// Foundation explicitly permits from any thread. Expose only that exception.
    private final class CoordinatorCancellation: @unchecked Sendable {
        private let coordinator: NSFileCoordinator
        init(_ coordinator: NSFileCoordinator) { self.coordinator = coordinator }
        func cancel() { coordinator.cancel() }
    }

}

import Foundation

public struct LocalFolderScanFailure: Error, Codable, Equatable, Sendable {
    public let code: Int?
    public let message: String

    public init(code: Int? = nil, message: String) { self.code = code; self.message = message }
}

/// A complete enumeration and a reader owning the access needed for each metadata
/// request. Providers must throw on enumeration failure, never return a partial list.
public struct LocalFolderScanInput: Sendable {
    public let files: [LocalFeedFile]
    /// Every immediate child's name, directories included. Nil means the names of `files`.
    public let presentNames: [String]?
    public let readMetadata: @Sendable (LocalFeedFile) async throws -> LocalFileMetadata
    /// Obtain after metadata reads as coordinated access may have renewed the bookmark.
    public let bookmark: @Sendable () -> Data
    public let documentResources: [LocalDocumentResourceReceipt]?

    public init(files: [LocalFeedFile], presentNames: [String]? = nil, bookmark: @escaping @Sendable () -> Data,
                documentResources: [LocalDocumentResourceReceipt]? = nil,
                readMetadata: @escaping @Sendable (LocalFeedFile) async throws -> LocalFileMetadata) {
        self.files = files; self.presentNames = presentNames; self.bookmark = bookmark; self.readMetadata = readMetadata
        self.documentResources = documentResources
    }
}

public struct LocalFeedRefreshService: Sendable {
    public enum Outcome: Equatable, Sendable {
        case updated(FeedRefreshResult)
        case failed(LocalFolderScanFailure)
        case superseded
    }

    private let store: FeedLibraryStore
    private let open: @Sendable (LocalFolderLink) async throws -> LocalFolderScanInput
    private let clock: @Sendable () -> Date

    public init(store: FeedLibraryStore,
                open: @escaping @Sendable (LocalFolderLink) async throws -> LocalFolderScanInput = { link in
                    try await LocalFolderDocuments(bookmark: link.bookmark).scanInput()
                },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.open = open; self.clock = clock
    }

    /// Strings are supplied by the app's localized source catalogue. Database failures
    /// propagate; only provider/scan errors become source-style local I/O status rows.
    public func refresh(feedID: Int64, description: String, author: String,
                        options: FeedRefreshOptions = FeedRefreshOptions(), manualRequestID: UUID? = nil) async throws -> Outcome {
        let context = try await store.beginLocalFolderScan(feedID: feedID, manualRequestID: manualRequestID)
        let snapshot: ParsedFeed
        let bookmark: Data
        let artworkFilename: String?
        let documentResources: [LocalDocumentResourceReceipt]?
        do {
            let input = try await open(context.link)
            try Task.checkCancellation()
            snapshot = try await LocalFeedScanner.scan(files: input.files, presentNames: input.presentNames, saved: context.feed,
                folderIdentity: context.link.directoryIdentity, description: description, author: author,
                readMetadata: input.readMetadata)
            try Task.checkCancellation()
            bookmark = input.bookmark()
            documentResources = input.documentResources
            artworkFilename = input.files.first { file in
                snapshot.imageURL.map { file.identity.utf16.elementsEqual($0.utf16) } == true
            }?.name
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let failure = (error as? LocalFolderScanFailure)
                ?? LocalFolderScanFailure(code: (error as NSError).code, message: error.localizedDescription)
            let recorded = try await store.recordLocalFolderFailure(failure, context: context, date: clock(), manualRequestID: manualRequestID)
            return recorded ? .failed(failure) : .superseded
        }
        var settings = options
        settings.now = clock(); settings.refreshAttempt = settings.now
        do {
            return .updated(try await store.applyLocalFolderScan(snapshot, context: context,
                refreshedBookmark: bookmark, artworkFilename: artworkFilename, documentResources: documentResources, options: settings, manualRequestID: manualRequestID))
        } catch let error as FeedLibraryError {
            // The store validates and commits atomically. Inspect ownership only to
            // distinguish supersession/deletion from a genuine storage failure.
            switch error {
            case .invalidMutation, .missingFeed:
                guard try await store.isCurrentLocalFolderScan(context) else { return .superseded }
            default: break
            }
            throw error
        }
    }
}

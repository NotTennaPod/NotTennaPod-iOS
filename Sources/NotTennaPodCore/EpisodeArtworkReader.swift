import Foundation

struct DownloadedArtworkReference: Equatable, Sendable {
    let path: String
    let mediaURL: String?
    let size: Int64
    let downloadDate: Date?

    init?(_ episode: LibraryEpisode) {
        guard episode.userState.isDownloaded, let path = episode.userState.localFileURL,
              path.hasPrefix("/"), let media = episode.details.media else { return nil }
        self.path = path; mediaURL = media.url; size = media.size
        downloadDate = episode.userState.downloadDate
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path.utf16.elementsEqual(rhs.path.utf16)
            && lhs.mediaURL.map { Array($0.utf16) } == rhs.mediaURL.map { Array($0.utf16) }
            && lhs.size == rhs.size && lhs.downloadDate == rhs.downloadDate
    }
}

/// Resolve artwork from registered local documents or completed app downloads.
/// Parsing is off the UI executor; cancellation reaches the native readers.
public struct EpisodeArtworkReader: Sendable {
    private let store: FeedLibraryStore
    private let readDownloaded: @Sendable (URL) async throws -> Data?

    public init(store: FeedLibraryStore) {
        self.init(store: store, readDownloaded: Self.readOwnedFile)
    }

    init(store: FeedLibraryStore, readDownloaded: @escaping @Sendable (URL) async throws -> Data?) {
        self.store = store; self.readDownloaded = readDownloaded
    }

    public func read(episode: LibraryEpisode) async throws -> Data? {
        try Task.checkCancellation()
        if try await store.localDocument(episodeID: episode.id) != nil {
            return try await LocalEpisodeArtworkReader(store: store).read(episode: episode)
        }
        guard let reference = DownloadedArtworkReference(episode),
              try await store.downloadedArtworkReference(episodeID: episode.id) == reference else { return nil }
        let bytes: Data?
        do { bytes = try await readDownloaded(URL(fileURLWithPath: reference.path)) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            // A failed image reload is not proof that a previously inspected
            // picture disappeared. Unknown lookup failures follow the source's
            // negative-cache rule; explicit deletion clears known presence.
            if episode.details.media?.hasEmbeddedPicture != nil { return nil }
            bytes = nil
        }
        try Task.checkCancellation()
        guard try await store.recordDownloadedArtwork(episodeID: episode.id, reference: reference,
                                                       present: bytes != nil) else { return nil }
        try Task.checkCancellation()
        return bytes
    }

    public static func hasArtwork(_ url: URL) async throws -> Bool {
        do { return try await readOwnedFile(url) != nil }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return false }
    }

    static func readOwnedFile(_ url: URL) async throws -> Data? {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { try LocalMediaMetadataReader.artwork(url: url) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }
}

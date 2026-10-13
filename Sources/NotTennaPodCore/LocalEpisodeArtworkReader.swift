import Foundation

/// Reload embedded bytes using the current registered document, never an
/// arbitrary file URL from feed metadata. Reconnection/removal invalidates an
/// outstanding read before it can deliver an image for an obsolete episode.
/// Showing a known embedded picture reads the file even when it is only in the
/// cloud, which downloads it, as Android does when it reads embedded art from a
/// cloud document. Folder scans never do; a cloud-first episode shows its
/// podcast's image until its metadata is read.
public struct LocalEpisodeArtworkReader: Sendable {
    private let store: FeedLibraryStore
    private let readImage: @Sendable (URL, @Sendable () throws -> Void) throws -> Data?

    public init(store: FeedLibraryStore) {
        self.init(store: store, readImage: { url, check in
            try LocalMediaMetadataReader.artwork(url: url, checkCancellation: check)
        })
    }

    init(store: FeedLibraryStore,
         readImage: @escaping @Sendable (URL, @Sendable () throws -> Void) throws -> Data?) {
        self.store = store; self.readImage = readImage
    }

    public func read(episode: LibraryEpisode) async throws -> Data? {
        try Task.checkCancellation()
        guard let reference = try await store.localDocument(episodeID: episode.id),
              let media = episode.details.media, let identity = media.url,
              let filename = episode.details.link,
              reference.identity.utf16.elementsEqual(identity.utf16),
              reference.filename.utf16.elementsEqual(filename.utf16),
              reference.size == media.size else { return nil }
        let documents = LocalFolderDocuments(bookmark: reference.folder.bookmark)
        let bytes = try await documents.read(fileNamed: reference.filename, readImage)
        try Task.checkCancellation()
        guard try await store.recordLocalArtwork(episodeID: episode.id, reference: reference,
                                                present: bytes != nil, refreshedBookmark: documents.bookmark) else { return nil }
        try Task.checkCancellation()
        return bytes
    }
}

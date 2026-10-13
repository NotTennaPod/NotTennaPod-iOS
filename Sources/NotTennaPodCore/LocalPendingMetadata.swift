import Foundation

/// Reads the metadata of a local-folder episode first listed while its file was only in the
/// cloud (`ParsedMedia.metadataPending`), after playback opened, and so downloaded, that file.
/// One read per playback document, owned and cancelled by it, and not awaited by playback. The
/// result is used only for the very file playback opened (its descriptor identity before and
/// after the read) under the same folder registration and document; otherwise, or on failure,
/// the work stays pending for the next scan or playback.
struct LocalPendingMetadata: Sendable {
    enum Outcome: Equatable, Sendable { case filled, notPending, stale }
    private let store: FeedLibraryStore
    private let readMetadata: @Sendable (URL, @Sendable () throws -> Void) throws -> LocalFileMetadata

    init(store: FeedLibraryStore, readMetadata: @escaping @Sendable (URL, @Sendable () throws -> Void) throws -> LocalFileMetadata = {
        url, check in try LocalMediaMetadataReader.read(url: url, checkCancellation: check)
    }) {
        self.store = store; self.readMetadata = readMetadata
    }

    func fill(episodeID: Int64, reference: LocalDocumentReference, playbackIdentity: LocalPlaybackFileIdentity) async throws -> Outcome {
        try Task.checkCancellation()
        guard try await store.awaitsLocalMetadata(episodeID: episodeID, reference: reference) else { return .notPending }
        let documents = LocalFolderDocuments(bookmark: reference.folder.bookmark)
        let read = readMetadata
        let metadata = try await documents.read(fileNamed: reference.filename) { url, check in
            // The file playback opened, unchanged in place and not replaced by the time the read ends.
            let opened = try LocalPlaybackFileIdentity.open(url)
            defer { try? opened.close() }
            guard try LocalPlaybackFileIdentity(file: opened) == playbackIdentity else { throw LocalPlaybackAccess.Failure.changedDocument }
            let result = try read(url, check)
            let current = try LocalPlaybackFileIdentity.open(url)
            defer { try? current.close() }
            guard try LocalPlaybackFileIdentity(file: opened) == playbackIdentity,
                  try LocalPlaybackFileIdentity(file: current) == playbackIdentity else { throw LocalPlaybackAccess.Failure.changedDocument }
            return result
        }
        try Task.checkCancellation()
        return try await store.recordLocalMetadata(metadata, episodeID: episodeID, reference: reference,
                                                    refreshedBookmark: documents.bookmark) ? .filled : .stale
    }
}

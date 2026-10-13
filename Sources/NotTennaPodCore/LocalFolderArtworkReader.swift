import Foundation

/// Read the selected immediate-child image through the registered folder grant.
/// URI strings alone never grant filesystem access.
public struct LocalFolderArtworkReader: Sendable {
    private let store: FeedLibraryStore
    private let readBytes: @Sendable (URL, @Sendable () throws -> Void) throws -> Data

    public init(store: FeedLibraryStore) { self.init(store: store, readBytes: Self.readBytes) }

    init(store: FeedLibraryStore,
         readBytes: @escaping @Sendable (URL, @Sendable () throws -> Void) throws -> Data) {
        self.store = store; self.readBytes = readBytes
    }

    public func read(feedID: Int64, identity: String) async throws -> Data? {
        try Task.checkCancellation()
        guard let link = try await store.localFolderArtwork(feedID: feedID, identity: identity) else { return nil }
        let documents = LocalFolderDocuments(bookmark: link.bookmark)
        let entries = try await documents.entries()
        let selected = entries.first(where: {
            !$0.isDirectory && $0.identity.utf16.elementsEqual(identity.utf16)
        }) ?? link.artwork.flatMap { artwork in
            guard artwork.identity.utf16.elementsEqual(identity.utf16) else { return nil }
            return entries.first { !$0.isDirectory && $0.name.utf16.elementsEqual(artwork.filename.utf16) }
        }
        guard let entry = selected else { return nil }
        let data = try await documents.read(fileNamed: entry.name, readBytes)
        try Task.checkCancellation()
        guard try await store.recordFolderArtworkRead(feedID: feedID, identity: identity, observed: link,
                                                       refreshedBookmark: documents.bookmark) else { return nil }
        try Task.checkCancellation()
        return data
    }

    static func readBytes(url: URL, check: @Sendable () throws -> Void) throws -> Data {
        try check()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while true {
            try check()
            guard let block = try file.read(upToCount: 65_536), !block.isEmpty else { break }
            data.append(block)
        }
        try check()
        return data
    }
}

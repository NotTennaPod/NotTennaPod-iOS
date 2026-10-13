import Foundation

/// Provider filenames/identities and MIME facts are supplied by the document adapter.
/// Keep provider MIME separate: Android uses resolved MIME for selection, raw MIME in media records/artwork fallback.
public struct LocalFeedFile: Equatable, Sendable {
    public var name, identity: String
    public var providerMIMEType, mediaMIMEType: String?
    public var size: Int64
    public var modified: Date
    public var availability: LocalDocumentAvailability
    public init(name: String, identity: String, providerMIMEType: String?, mediaMIMEType: String?, size: Int64, modified: Date,
                availability: LocalDocumentAvailability = .unknown) {
        self.name = name; self.identity = identity; self.providerMIMEType = providerMIMEType
        self.mediaMIMEType = mediaMIMEType; self.size = size; self.modified = modified
        self.availability = availability
    }
}

public struct LocalFileMetadata: Equatable, Sendable {
    public var title: String?
    public var publicationDate: Date?
    public var durationMilliseconds: Int32?
    public var description: String?
    /// The scanner persists presence only; image bytes are reread from the
    /// registered document instead of being copied into episode JSON.
    public var embeddedArtwork: Data?
    public init(title: String? = nil, publicationDate: Date? = nil, durationMilliseconds: Int32? = nil,
                description: String? = nil, embeddedArtwork: Data? = nil) {
        self.title = title; self.publicationDate = publicationDate
        self.durationMilliseconds = durationMilliseconds; self.description = description
        self.embeddedArtwork = embeddedArtwork
    }
}

public enum LocalFeedScanner {
    public static func isMedia(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.hasPrefix("audio") || mime.hasPrefix("video")
            || ["application/ogg", "application/opus", "application/x-flac"].contains(mime)
    }

    public static func artwork(files: [LocalFeedFile], folderIdentity: String) -> String {
        for preferred in ["folder.jpg", "Folder.jpg", "folder.png", "Folder.png"] {
            if let file = files.first(where: { equal($0.name, preferred) }) { return file.identity }
        }
        if let file = files.first(where: { $0.providerMIMEType?.hasPrefix("image/jpeg") == true || $0.providerMIMEType?.hasPrefix("image/png") == true }) {
            return file.identity
        }
        return GenerativeCoverPattern.artworkPrefix + folderIdentity
    }

    public static func matchingEpisode(filename: String, episodes: [LibraryEpisode]) -> Int? {
        episodes.firstIndex { $0.details.media != nil && $0.details.link.map { equal($0, filename) } == true }
    }

    /// Builds a complete local snapshot for an atomic local-feed merge. This does
    /// not mutate the saved library, so cancellation cannot commit a partial scan.
    /// The listing is complete: every listed name (`presentNames`, else the names of
    /// `files`) is present, whatever its type or availability, so only a file that is
    /// really gone loses its episode.
    public static func scan(files: [LocalFeedFile], presentNames: [String]? = nil, saved: LibraryFeed, folderIdentity: String,
                            description: String, author: String,
                            newIdentifier: @Sendable () -> String = { UUID().uuidString },
                            readMetadata: @Sendable (LocalFeedFile) async throws -> LocalFileMetadata) async throws -> ParsedFeed {
        try Task.checkCancellation()
        var working = saved.episodes
        for file in files {
            try Task.checkCancellation()
            let matched = matchingEpisode(filename: file.name, episodes: working)
            let local = file.availability != .notDownloaded
            // Reading a file that is only in the cloud would download it: its episode stays as saved.
            if !local, matched != nil { continue }
            guard isMedia(file.mediaMIMEType) else { continue }
            let pending = matched.map { working[$0].details.media?.metadataPending == true } ?? false
            var fresh = LibraryEpisode(id: 0, details: ParsedEpisode(identifier: newIdentifier(), title: titleFromFilename(file.name),
                link: file.name, publicationDate: file.modified,
                media: ParsedMedia(url: file.identity, size: file.size, mimeType: file.providerMIMEType)))
            if let cached = working.first(where: { item in
                guard let media = item.details.media, let identity = media.url else { return false }
                // Pending metadata is read once the file is on the device, even if nothing else changed.
                return equal(identity, file.identity) && media.size == file.size && !(local && media.metadataPending == true)
            }) {
                fresh.update(from: cached.details)
                // Metadata reuse must not restore an obsolete filename after a rename.
                // Otherwise the final filename filter removes the newly scanned file.
                fresh.details.link = file.name
            } else if !local {
                // The file name and size stand in, as Android falls back to the file name. Unknown
                // embedded artwork would be read, so downloaded, just to draw the episode list.
                fresh.details.media?.metadataPending = true
                fresh.details.media?.hasEmbeddedPicture = false
            } else {
                do {
                    let metadata = try await readMetadata(file)
                    if let title = metadata.title, !title.isEmpty { fresh.details.title = title }
                    if let date = metadata.publicationDate { fresh.details.publicationDate = date }
                    if let duration = metadata.durationMilliseconds { fresh.details.media?.durationMilliseconds = duration }
                    fresh.details.media?.hasEmbeddedPicture = metadata.embeddedArtwork != nil
                    if let description = metadata.description { fresh.details.setDescriptionIfLonger(description) }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // Pending metadata is cleared only by a successful read: the episode stays as
                    // saved, still pending, for the next scan or playback to read.
                    if pending { continue }
                    fresh.details.setDescriptionIfLonger(error.localizedDescription)
                }
            }
            try Task.checkCancellation()
            if let matched { working[matched].update(from: fresh.details) }
            else { working.append(fresh) }
        }
        let names = Set((presentNames ?? files.map(\.name)).map { Array($0.utf16) })
        working.removeAll { episode in
            guard let link = episode.details.link else { return true }
            return !names.contains(Array(link.utf16))
        }
        var result = saved.metadata
        result.episodes = working.map(\.details)
        result.imageURL = artwork(files: files, folderIdentity: folderIdentity)
        result.description = description; result.author = author
        return result
    }

    private static func titleFromFilename(_ filename: String) -> String {
        // FilenameUtils.removeExtension uses the final dot, including a leading dot.
        guard let dot = filename.lastIndex(of: ".") else { return filename }
        return String(filename[..<dot])
    }
    private static func equal(_ left: String, _ right: String) -> Bool { left.utf16.elementsEqual(right.utf16) }
}

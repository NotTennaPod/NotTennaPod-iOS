import Foundation

/// The grant is private app data, separate from feed URLs and exportable metadata.
public struct LocalFolderLink: Codable, Equatable, Sendable {
    public let feedID: Int64
    public let directoryIdentity: String
    public let bookmark: Data
    public let generation: UUID
    /// A scan is a new read, not a new user-selected folder registration.
    public let registrationID: UUID?
    public let documentResources: [LocalDocumentResourceReceipt]?
    var deletionRegistrationID: UUID { registrationID ?? generation }
    /// The observed immediate child survives a parent-directory move. This is
    /// private access metadata, not a basename inferred from an arbitrary URL.
    public let artwork: LocalFolderArtworkReference?

    init(feedID: Int64, directoryIdentity: String, bookmark: Data, generation: UUID,
         artwork: LocalFolderArtworkReference? = nil, registrationID: UUID? = nil,
         documentResources: [LocalDocumentResourceReceipt]? = nil) {
        self.feedID = feedID; self.directoryIdentity = directoryIdentity
        self.bookmark = bookmark; self.generation = generation; self.artwork = artwork
        self.registrationID = registrationID ?? generation; self.documentResources = documentResources
    }

    /// Renewing bookmark bytes does not select a different folder or start a
    /// newer scan. Keep full Equatable semantics for persistence comparisons.
    func isSameRegistration(as other: Self) -> Bool {
        feedID == other.feedID && generation == other.generation
            && directoryIdentity.utf16.elementsEqual(other.directoryIdentity.utf16)
    }
}

public struct LocalFolderArtworkReference: Codable, Equatable, Sendable {
    public let identity: String
    public let filename: String
}

public struct LocalFolderScanContext: Equatable, Sendable {
    public let feed: LibraryFeed
    public let link: LocalFolderLink
}

public struct LocalDocumentReference: Codable, Equatable, Sendable {
    public let folder: LocalFolderLink
    public let filename: String
    public let identity: String
    public let size: Int64
    public let resourceIdentity: LocalDocumentResourceIdentity?

    init(folder: LocalFolderLink, filename: String, identity: String, size: Int64,
         resourceIdentity: LocalDocumentResourceIdentity? = nil) {
        self.folder = folder; self.filename = filename; self.identity = identity
        self.size = size; self.resourceIdentity = resourceIdentity
    }

    /// Playback keeps its existing scan-generation gate; delayed deletion uses
    /// the selected registration and the authoritative scan's resource receipt.
    func isSameDeletionDocument(as other: Self) -> Bool {
        isSameDeletionLocation(as: other)
            && resourceIdentity != nil && resourceIdentity == other.resourceIdentity
    }

    func isSameDeletionLocation(as other: Self) -> Bool {
        folder.feedID == other.folder.feedID
            && folder.deletionRegistrationID == other.folder.deletionRegistrationID
            && folder.directoryIdentity.utf16.elementsEqual(other.folder.directoryIdentity.utf16)
            && size == other.size && filename.utf16.elementsEqual(other.filename.utf16)
            && identity.utf16.elementsEqual(other.identity.utf16)
    }

    func isSameDocument(as other: Self) -> Bool {
        folder.isSameRegistration(as: other.folder) && size == other.size
            && filename.utf16.elementsEqual(other.filename.utf16)
            && identity.utf16.elementsEqual(other.identity.utf16)
    }
}

/// A coordinated observation of the actual immediate child, rather than its
/// display name or URL. No opaque provider handle escapes the I/O boundary.
public struct LocalDocumentResourceIdentity: Codable, Equatable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let size: Int64
}

public struct LocalDocumentResourceReceipt: Codable, Equatable, Sendable {
    public let filename: String
    public let identity: LocalDocumentResourceIdentity
}

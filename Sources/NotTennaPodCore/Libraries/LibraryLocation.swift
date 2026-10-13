import Foundation

/// Where one library's files live (PROTOCOL §15.4). Device settings stay in the root folder for every library;
/// the standalone library's files stay exactly where they always were, in the root folder itself.
public struct LibraryLocation: Equatable, Sendable {
    public static let serverLibrariesFolderName = "Server Libraries"
    public static let databaseName = "library.sqlite"
    public static let playbackLibraryName = "playback-library.json"

    public static let accountPoliciesName = "account-policies.json"

    /// Application Support, or a DEBUG test library's folder: device settings and `libraries.json`.
    public let root: URL
    public let reference: LibraryReference
    /// The library's own folder: the root for the standalone library, `Server Libraries/<id>/` otherwise.
    public let folder: URL
    /// A library a Keep at logout converted but has not published yet (PROTOCOL §15.4): its database,
    /// `media/` and `streaming-cache/` wherever their markers show them, its preferences in its own folder's files.
    public private(set) var converted: ConvertedFiles?

    public struct ConvertedFiles: Equatable, Sendable {
        public var database: URL
        public var media: URL
        public var streamingCache: URL
        public init(database: URL, media: URL, streamingCache: URL) {
            self.database = database; self.media = media; self.streamingCache = streamingCache
        }
    }

    public init(root: URL, reference: LibraryReference) {
        self.root = root
        self.reference = reference
        switch reference {
        case .standalone: folder = root
        case .server(let id):
            folder = Self.serverLibraries(root: root).appendingPathComponent(id, isDirectory: true)
        }
    }

    /// The converted library `id` opened before its Keep is published: its preferences stay in `Server Libraries/<id>/`.
    public init(root: URL, convertedLibrary id: String, files: ConvertedFiles) {
        self.init(root: root, reference: .server(id))
        converted = files
    }

    public static func serverLibraries(root: URL) -> URL {
        root.appendingPathComponent(serverLibrariesFolderName, isDirectory: true)
    }

    public var database: URL { converted?.database ?? folder.appendingPathComponent(Self.databaseName) }
    public var media: URL { converted?.media ?? folder.appendingPathComponent("media", isDirectory: true) }
    public var streamingCache: URL { converted?.streamingCache ?? folder.appendingPathComponent("streaming-cache", isDirectory: true) }
    /// The folder that holds `media/` now (owned paths are normalized onto it, PROTOCOL §15.4).
    public var ownedRoot: URL { media.deletingLastPathComponent() }
    /// A server library's per-feed speeds and silence, current-episode speed and shownotes position (PROTOCOL §15.4);
    /// the standalone library keeps them in the root's settings files, in their existing format.
    public var playbackLibraryFile: URL? {
        reference == .standalone ? nil : folder.appendingPathComponent(Self.playbackLibraryName)
    }
    /// A converted library's account policies until its Keep is published (PROTOCOL §15.4 "Opening before publication").
    public var accountPoliciesFile: URL? { converted == nil ? nil : folder.appendingPathComponent(Self.accountPoliciesName) }
    /// The sync engine's database (archive, sync log, safeguards); server libraries only.
    public var syncDatabase: URL? { reference == .standalone ? nil : folder.appendingPathComponent("sync.sqlite") }
    /// Pull pages, snapshot spools and shadow projections; excluded from device backups. Server libraries only.
    public var staging: URL? {
        reference == .standalone ? nil : folder.appendingPathComponent("staging", isDirectory: true)
    }

    /// Whether the library's folder exists (the standalone library's always does).
    public var exists: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) && directory.boolValue
    }

    /// Whether the library's folder is there: false only when the file system confirms it is missing (`ENOENT`) or it
    /// is not a folder; a folder that cannot be examined now (before the first unlock, a permission error) is thrown,
    /// never taken for missing.
    public func folderIsPresent() throws -> Bool {
        var info = stat()
        if stat(folder.path, &info) == 0 { return info.st_mode & S_IFMT == S_IFDIR }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Creates a server library's folder with its staging folder, which device backups skip. The standalone
    /// library needs nothing.
    public func prepare() throws {
        guard let staging else { return }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = staging
        try excluded.setResourceValues(values)
    }

    /// Every library on this device: the standalone library and each entry of `Server Libraries/` named by a library
    /// ID (registered or not). Throws when `Server Libraries/` exists but cannot be listed: a failed listing is never
    /// taken for "no server libraries".
    public static func all(root: URL) throws -> [LibraryLocation] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: serverLibraries(root: root).path) }
        catch where isAbsent(serverLibraries(root: root)) { names = [] }
        return [LibraryLocation(root: root, reference: .standalone)] + names.sorted()
            .filter(ContractIdentity.isUUID).map { LibraryLocation(root: root, reference: .server($0)) }
    }

    /// Whether nothing exists at `url`: true only when the file system says so (`ENOENT`), never for a path that
    /// cannot be examined.
    static func isAbsent(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) != 0 && errno == ENOENT
    }
}

/// A library kept aside at logout (PROTOCOL §15.4): `Previous Libraries/<id>/` with its `library.sqlite`, `media/`,
/// `streaming-cache/`, `playback-library.json` and `previous-library.json`. It is never opened writable again; it is
/// exported through the read-only reader and removed with its folder.
public struct PreviousLibraryLocation: Equatable, Sendable {
    public static let folderName = "Previous Libraries"
    public static let descriptionName = "previous-library.json"
    public let root: URL
    public let id: String

    public init(root: URL, id: String) { self.root = root; self.id = id }

    public static func folder(root: URL) -> URL { root.appendingPathComponent(folderName, isDirectory: true) }
    public var folder: URL { Self.folder(root: root).appendingPathComponent(id, isDirectory: true) }
    public var database: URL { folder.appendingPathComponent(LibraryLocation.databaseName) }
    public var media: URL { folder.appendingPathComponent("media", isDirectory: true) }
    public var streamingCache: URL { folder.appendingPathComponent("streaming-cache", isDirectory: true) }
    public var playbackLibraryFile: URL { folder.appendingPathComponent(LibraryLocation.playbackLibraryName) }
    public var descriptionFile: URL { folder.appendingPathComponent(Self.descriptionName) }

    /// Every folder of `Previous Libraries/` named by a UUID (registered or not).
    public static func all(root: URL) throws -> [PreviousLibraryLocation] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: folder(root: root).path) }
        catch where LibraryLocation.isAbsent(folder(root: root)) { names = [] }
        return names.sorted().filter(ContractIdentity.isUUID).map { PreviousLibraryLocation(root: root, id: $0) }
    }
}

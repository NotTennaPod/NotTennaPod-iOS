import Foundation

/// A library on this device: the standalone library (Application Support, unchanged since before server mode)
/// or a server library in `Server Libraries/<id>/` (PROTOCOL §15.4).
public enum LibraryReference: Hashable, Sendable, CustomStringConvertible {
    case standalone
    case server(String)

    /// The registry's name for the standalone library; server libraries are named by their lowercase UUID.
    public static let standaloneName = "standalone"

    public init?(name: String) {
        if name == Self.standaloneName { self = .standalone }
        else if ContractIdentity.isUUID(name) { self = .server(name) }
        else { return nil }
    }

    public var name: String {
        switch self {
        case .standalone: Self.standaloneName
        case .server(let id): id
        }
    }

    public var description: String { name }
}

/// `libraries.json`: the server libraries kept on this device, the active library and a recorded switch.
/// It holds no secrets. A missing file means the standalone library and no server library, and is never
/// written in standalone use.
public struct LibraryRegistry: Equatable, Sendable {
    public enum SwitchReason: String, Codable, Sendable { case attach, logout, resume, newLineage = "new_lineage" }

    /// A switch waiting for the activation rule (PROTOCOL §15.4); applied before any library opens at the next graph start.
    public struct PendingSwitch: Equatable, Sendable {
        public var to: LibraryReference
        public var reason: SwitchReason
        /// Milliseconds since 1970.
        public var requestedAt: Int64
        public init(to: LibraryReference, reason: SwitchReason, requestedAt: Int64) {
            self.to = to; self.reason = reason; self.requestedAt = requestedAt
        }
    }

    public struct ServerLibrary: Codable, Equatable, Sendable {
        /// `keeping`: logged out with "Keep using this library", its Keep at logout not yet published (PROTOCOL §15.4).
        public enum State: String, Codable, Sendable { case attaching, ready, active, keeping, inactive, removing }
        public var id: String
        public var serverURL: String
        public var serverID: String
        public var accountID: String
        public var username: String
        /// The server's log, known once the first snapshot or cursor is decoded.
        public var logID: String?
        public var state: State
        /// The Keep operation while `keeping` (PROTOCOL §15.4).
        public var operation: String?
        /// Milliseconds since 1970.
        public var createdAt: Int64

        public init(id: String, serverURL: String, serverID: String, accountID: String, username: String,
                    logID: String? = nil, state: State, operation: String? = nil, createdAt: Int64) {
            self.id = id; self.serverURL = serverURL; self.serverID = serverID; self.accountID = accountID
            self.username = username; self.logID = logID; self.state = state; self.operation = operation; self.createdAt = createdAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, username, state, operation
            case serverURL = "server_url", serverID = "server_id", accountID = "account_id", logID = "log_id", createdAt = "created_at"
        }
    }

    /// A library kept aside at logout (PROTOCOL §15.4): `Previous Libraries/<id>/`, labelled by `keptAt`, never by a folder name.
    public struct PreviousLibrary: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case ready, removing }
        public var id: String
        /// Its `library_identity`.
        public var identity: String
        /// Milliseconds since 1970.
        public var keptAt: Int64
        public var state: State
        public init(id: String, identity: String, keptAt: Int64, state: State = .ready) {
            self.id = id; self.identity = identity; self.keptAt = keptAt; self.state = state
        }
        private enum CodingKeys: String, CodingKey { case id, identity, state, keptAt = "kept_at" }
    }

    /// A published Keep whose cleanup (phase 7) has not finished.
    public struct Conversion: Codable, Equatable, Sendable {
        public var operation: String
        /// The server library that became this phone's library.
        public var library: String
        /// The previous library the old one became.
        public var previous: String
        /// `cleanup`: published by phase 6's registry write, only cleanup is left (PROTOCOL §15.4). `converted`: a committed Keep
        /// whose name recovery wrote back before it was published. Publication is recorded here, never
        /// read from the removable `previous` list.
        public var state = Conversion.published
        public static let published = "cleanup"
        public static let unpublished = "converted"
        public init(operation: String, library: String, previous: String, state: String = Conversion.published) {
            self.operation = operation; self.library = library; self.previous = previous; self.state = state
        }
    }

    public static let currentVersion = 1
    public var version = LibraryRegistry.currentVersion
    public var active: LibraryReference = .standalone
    public var pendingSwitch: PendingSwitch?
    public var libraries: [ServerLibrary] = []
    /// The identity of the library in the root folder (PROTOCOL §15.4), so a library's folder is found without opening a database.
    public var standaloneIdentity: String?
    public var previous: [PreviousLibrary] = []
    public var conversions: [Conversion] = []

    public init() {}

    public func library(_ id: String) -> ServerLibrary? { libraries.first { $0.id == id } }
    public func previousLibrary(_ id: String) -> PreviousLibrary? { previous.first { $0.id == id } }
    /// The library whose Keep at logout waits (at most one).
    public var keeping: ServerLibrary? { libraries.first { $0.state == .keeping } }

    /// The library to open: the active one, or the standalone library when the active entry is missing.
    public var libraryToOpen: LibraryReference {
        if case .server(let id) = active, library(id) == nil { return .standalone }
        return active
    }

    /// Records a switch; it replaces any earlier one. A switch to the library that is already open needs no
    /// graph restart: it is applied at once (which also cancels a switch away from it that was still waiting).
    public mutating func recordSwitch(to target: LibraryReference, reason: SwitchReason, at time: Int64) throws {
        if case .server(let id) = target, library(id) == nil { throw LibraryRegistryError.unknownLibrary(id) }
        pendingSwitch = PendingSwitch(to: target, reason: reason, requestedAt: time)
        if target == active { applyPendingSwitch() }
    }

    /// Applies the recorded switch: the target becomes the active library and a server library that was
    /// active becomes inactive (its database, outbox and archive stay). A switch to a server library that is
    /// not ready (attaching, removing, inactive, or gone) is dropped and the active library stays.
    /// Returns whether anything changed.
    @discardableResult public mutating func applyPendingSwitch() -> Bool {
        guard let pending = pendingSwitch else { return false }
        pendingSwitch = nil
        if case .server(let id) = pending.to {
            guard let target = libraries.firstIndex(where: { $0.id == id }),
                  [.ready, .active].contains(libraries[target].state) else { return true }
        }
        for index in libraries.indices {
            if case .server(let id) = pending.to, libraries[index].id == id { libraries[index].state = .active }
            else if libraries[index].state == .active { libraries[index].state = .inactive }
        }
        active = pending.to
        return true
    }

    /// The registry's invariants (PROTOCOL §15.4): valid, unique library IDs; at most one library attaching, ready or
    /// active (PROTOCOL §11.5: one server account per phone); the active library and a switch target exist; no
    /// credentials in a server address.
    public func validate() throws {
        guard version == Self.currentVersion else { throw LibraryRegistryError.unsupportedVersion(version) }
        var seen = Set<String>()
        for library in libraries {
            guard ContractIdentity.isUUID(library.id) else { throw LibraryRegistryError.invalidLibraryID(library.id) }
            guard seen.insert(library.id).inserted else { throw LibraryRegistryError.duplicateLibrary(library.id) }
            guard !ContractURL.hasUserinfo(library.serverURL) else { throw LibraryRegistryError.credentialsInAddress }
        }
        guard libraries.filter({ [.attaching, .ready, .active, .keeping].contains($0.state) }).count <= 1 else {
            throw LibraryRegistryError.severalCurrentLibraries
        }
        for library in libraries where library.state == .keeping {
            guard let operation = library.operation, ContractIdentity.isUUID(operation) else { throw LibraryRegistryError.invalidLibraryID(library.id) }
        }
        var previousIDs = Set<String>()
        for entry in previous {
            guard ContractIdentity.isUUID(entry.id), !seen.contains(entry.id) else { throw LibraryRegistryError.invalidLibraryID(entry.id) }
            guard previousIDs.insert(entry.id).inserted else { throw LibraryRegistryError.duplicateLibrary(entry.id) }
        }
        if case .server(let id) = active, library(id) == nil { throw LibraryRegistryError.unknownLibrary(id) }
        if case .server(let id) = pendingSwitch?.to, library(id) == nil { throw LibraryRegistryError.unknownLibrary(id) }
    }
}

public enum LibraryRegistryError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidLibraryID(String)
    case duplicateLibrary(String)
    case unknownLibrary(String)
    case severalCurrentLibraries
    case credentialsInAddress
    case invalidReference(String)
}

extension LibraryRegistry: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, active, pendingSwitch = "switch", libraries, previous, conversions
        case standaloneIdentity = "standalone_identity"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw LibraryRegistryError.unsupportedVersion(version) }
        active = try Self.reference(values.decode(String.self, forKey: .active))
        pendingSwitch = try values.decodeIfPresent(PendingSwitch.self, forKey: .pendingSwitch)
        libraries = try values.decodeIfPresent([ServerLibrary].self, forKey: .libraries) ?? []
        standaloneIdentity = try values.decodeIfPresent(String.self, forKey: .standaloneIdentity)
        previous = try values.decodeIfPresent([PreviousLibrary].self, forKey: .previous) ?? []
        conversions = try values.decodeIfPresent([Conversion].self, forKey: .conversions) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(active.name, forKey: .active)
        try values.encodeIfPresent(pendingSwitch, forKey: .pendingSwitch)
        try values.encode(libraries, forKey: .libraries)
        try values.encodeIfPresent(standaloneIdentity, forKey: .standaloneIdentity)
        if !previous.isEmpty { try values.encode(previous, forKey: .previous) }
        if !conversions.isEmpty { try values.encode(conversions, forKey: .conversions) }
    }

    fileprivate static func reference(_ name: String) throws -> LibraryReference {
        guard let reference = LibraryReference(name: name) else { throw LibraryRegistryError.invalidReference(name) }
        return reference
    }
}

extension LibraryRegistry.PendingSwitch: Codable {
    private enum CodingKeys: String, CodingKey { case to, reason, requestedAt = "requested_at" }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        to = try LibraryRegistry.reference(values.decode(String.self, forKey: .to))
        reason = try values.decode(LibraryRegistry.SwitchReason.self, forKey: .reason)
        requestedAt = try values.decode(Int64.self, forKey: .requestedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(to.name, forKey: .to)
        try values.encode(reason, forKey: .reason)
        try values.encode(requestedAt, forKey: .requestedAt)
    }
}

/// `libraries.json` in the root folder (Application Support, or a DEBUG test library's folder). Written by
/// temporary file, fsync and rename, so a crash leaves either the old or the new registry.
public struct LibraryRegistryFile: Sendable {
    public static let fileName = "libraries.json"
    public let url: URL

    public init(root: URL) { url = root.appendingPathComponent(Self.fileName) }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The saved registry; the default (standalone, no server library) when there is no file. A registry that cannot
    /// be read now (before the first unlock, a folder that cannot be examined) is thrown, never taken for none.
    public func read() throws -> LibraryRegistry {
        guard let data = try SavedState.contents(of: url) else { return LibraryRegistry() }
        let registry = try JSONDecoder().decode(LibraryRegistry.self, from: data)
        try registry.validate()
        return registry
    }

    public func write(_ registry: LibraryRegistry) throws {
        try registry.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFile.replace(url, with: encoder.encode(registry))
    }

    /// Reads, changes and writes the registry; nothing is written when the change leaves it equal.
    @discardableResult public func update(_ change: (inout LibraryRegistry) throws -> Void) throws -> LibraryRegistry {
        let current = try read()
        var next = current
        try change(&next)
        if next != current { try write(next) }
        return next
    }

    /// At a graph start, before any library opens: a recorded switch is applied (nothing can be playing then).
    /// Returns the library to open. Without a registry file nothing is written and the standalone library opens; a
    /// registry that cannot be examined or read now is thrown.
    public func openingLibrary() throws -> LibraryReference {
        guard try SavedState.isPresent(url) else { return .standalone }
        return try update { $0.applyPendingSwitch() }.libraryToOpen
    }
}

/// Atomic, durable file replacement: write a temporary file beside the target, fsync it, rename it over the
/// target and fsync the folder.
enum DurableFile {
    static func replace(_ url: URL, with data: Data) throws {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let directory = open(folder.path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }
}

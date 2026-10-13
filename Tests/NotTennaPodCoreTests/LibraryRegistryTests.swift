import Foundation
import Testing
@testable import NotTennaPodCore

/// PROTOCOL §15.4: the library registry (`libraries.json`), the library folders, and a recorded switch applied
/// before any library opens.
@Suite struct LibraryRegistryTests {
    private let first = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
    private let second = "f1d2c3b4-a5e6-4f70-8a9b-0c1d2e3f4a5b"

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryRegistry-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func server(_ id: String, _ state: LibraryRegistry.ServerLibrary.State) -> LibraryRegistry.ServerLibrary {
        .init(id: id, serverURL: "https://sync.example.test", serverID: "server-1", accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f",
              username: "alice", state: state, createdAt: 1_700_000_000_000)
    }

    /// Standalone use never writes the registry: without the file the standalone library opens, as always.
    @Test func withoutARegistryTheStandaloneLibraryOpensAndNothingIsWritten() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LibraryRegistryFile(root: root)
        #expect(try file.openingLibrary() == .standalone)
        #expect(try file.read() == LibraryRegistry())
        #expect(!file.exists)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    /// The file has the documented shape and round-trips; no temporary file is left beside it.
    @Test func registryIsWrittenInTheDesignedShapeAndReadBack() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LibraryRegistryFile(root: root)
        var registry = LibraryRegistry()
        registry.libraries = [server(first, .ready)]
        registry.pendingSwitch = .init(to: .server(first), reason: .attach, requestedAt: 1_700_000_000_123)
        try file.write(registry)
        #expect(try file.read() == registry)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["active"] as? String == "standalone")
        let pending = try #require(json["switch"] as? [String: Any])
        #expect(pending["to"] as? String == first && pending["reason"] as? String == "attach")
        #expect(pending["requested_at"] as? Int64 == 1_700_000_000_123)
        let library = try #require((json["libraries"] as? [[String: Any]])?.first)
        #expect(Set(library.keys) == ["id", "server_url", "server_id", "account_id", "username", "state", "created_at"])
        #expect(library["state"] as? String == "ready")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [LibraryRegistryFile.fileName])
    }

    /// At most one library attaching, ready or active; IDs are lowercase UUIDs; no credentials in an address.
    @Test func invariantsAreEnforcedOnWriteAndRead() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LibraryRegistryFile(root: root)
        var two = LibraryRegistry()
        two.libraries = [server(first, .ready), server(second, .attaching)]
        #expect(throws: LibraryRegistryError.severalCurrentLibraries) { try file.write(two) }
        var badID = LibraryRegistry()
        badID.libraries = [server("../media", .inactive)]
        #expect(throws: LibraryRegistryError.invalidLibraryID("../media")) { try file.write(badID) }
        var credentials = LibraryRegistry()
        var withUser = server(first, .inactive); withUser.serverURL = "https://alice:secret@sync.example.test"
        credentials.libraries = [withUser]
        #expect(throws: LibraryRegistryError.credentialsInAddress) { try file.write(credentials) }
        var dangling = LibraryRegistry()
        dangling.active = .server(first)
        #expect(throws: LibraryRegistryError.unknownLibrary(first)) { try file.write(dangling) }
        #expect(!file.exists)
        // A registry from a newer app is refused, not misread.
        try Data(#"{"version":2,"active":"standalone","libraries":[]}"#.utf8).write(to: file.url)
        #expect(throws: LibraryRegistryError.unsupportedVersion(2)) { try file.read() }
    }

    /// PROTOCOL §15.4: at a graph start a recorded switch is applied before the library opens; the library that was
    /// active becomes inactive and keeps its data.
    @Test func recordedSwitchIsAppliedWhenTheGraphStarts() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LibraryRegistryFile(root: root)
        var registry = LibraryRegistry()
        registry.libraries = [server(first, .ready)]
        try registry.recordSwitch(to: .server(first), reason: .attach, at: 5)
        try file.write(registry)
        #expect(try file.openingLibrary() == .server(first))
        let attached = try file.read()
        #expect(attached.active == .server(first) && attached.pendingSwitch == nil)
        #expect(attached.library(first)?.state == .active)
        // Logout: the library is marked inactive by the flow and the switch back waits; at the next start it applies.
        _ = try file.update {
            $0.libraries[0].state = .inactive
            try $0.recordSwitch(to: .standalone, reason: .logout, at: 6)
        }
        #expect(try file.read().active == .server(first), "nothing changes before the graph restarts")
        #expect(try file.openingLibrary() == .standalone)
        let back = try file.read()
        #expect(back.active == .standalone && back.pendingSwitch == nil && back.library(first)?.state == .inactive)
    }

    /// A switch to a library that is not ready (still attaching, being removed) is dropped; the active library stays.
    @Test func switchToALibraryThatIsNotReadyIsDropped() throws {
        var registry = LibraryRegistry()
        registry.libraries = [server(first, .attaching)]
        try registry.recordSwitch(to: .server(first), reason: .attach, at: 1)
        let changed = registry.applyPendingSwitch()
        #expect(changed)
        #expect(registry.active == .standalone && registry.pendingSwitch == nil && registry.library(first)?.state == .attaching)
        #expect(throws: LibraryRegistryError.unknownLibrary(second)) { try registry.recordSwitch(to: .server(second), reason: .resume, at: 2) }
    }

    /// Logging in again before a logout's switch ran: the switch away is cancelled and the library is active again,
    /// without a restart.
    @Test func switchBackToTheOpenLibraryAppliesAtOnce() throws {
        var registry = LibraryRegistry()
        registry.libraries = [server(first, .active)]
        registry.active = .server(first)
        registry.libraries[0].state = .inactive
        try registry.recordSwitch(to: .standalone, reason: .logout, at: 1)
        registry.libraries[0].state = .ready
        try registry.recordSwitch(to: .server(first), reason: .resume, at: 2)
        #expect(registry.pendingSwitch == nil && registry.active == .server(first) && registry.library(first)?.state == .active)
    }

    /// An active entry that is missing (a damaged registry) opens the standalone library.
    @Test func missingActiveLibraryOpensStandalone() {
        var registry = LibraryRegistry()
        registry.active = .server(first)
        #expect(registry.libraryToOpen == .standalone)
    }

    /// The standalone library's files stay in the root; a server library's live in `Server Libraries/<id>/`, with a
    /// staging folder that device backups skip.
    @Test func locationsKeepStandaloneInPlaceAndGiveServerLibrariesTheirOwnFolder() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let standalone = LibraryLocation(root: root, reference: .standalone)
        #expect(standalone.folder == root && standalone.database == root.appendingPathComponent("library.sqlite"))
        #expect(standalone.media == root.appendingPathComponent("media", isDirectory: true))
        #expect(standalone.playbackLibraryFile == nil && standalone.staging == nil && standalone.syncDatabase == nil)
        let library = LibraryLocation(root: root, reference: .server(first))
        let folder = root.appendingPathComponent("Server Libraries", isDirectory: true).appendingPathComponent(first, isDirectory: true)
        #expect(library.folder == folder && library.database == folder.appendingPathComponent("library.sqlite"))
        #expect(library.streamingCache == folder.appendingPathComponent("streaming-cache", isDirectory: true))
        #expect(library.playbackLibraryFile == folder.appendingPathComponent("playback-library.json"))
        #expect(library.syncDatabase == folder.appendingPathComponent("sync.sqlite"))
        #expect(!library.exists)
        try library.prepare()
        #expect(library.exists)
        let staging = try #require(library.staging)
        #expect(try staging.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)
        try standalone.prepare()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Server Libraries"])
        // Only folders named by a library ID count as libraries.
        try FileManager.default.createDirectory(at: LibraryLocation.serverLibraries(root: root).appendingPathComponent("notes"),
                                                withIntermediateDirectories: true)
        #expect(try LibraryLocation.all(root: root).map(\.reference) == [.standalone, .server(first)])
    }
}

import Foundation
import Testing
@testable import NotTennaPodCore

/// The message that the chosen server library could not be found on this device, so this device's library is open
/// instead (the fallback for a missing folder or database): due once per occurrence after a graph start that
/// succeeded, never for a damaged registry, a normal start or a library that cannot be read now, and not again when
/// later starts fall back for the same library. Which library opens, the registry and the folders stay as they were.
@Suite(.serialized) struct MissingLibraryNoticeTests {
    private let serverID = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
    private let otherID = "7d2e4f60-1a3b-4c5d-8e9f-0a1b2c3d4e5f"

    private final class Device {
        let root: URL
        private var denied: [URL] = []
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MissingLibraryNotice-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var registryFile: LibraryRegistryFile { LibraryRegistryFile(root: root) }
        func location(_ id: String) -> LibraryLocation { LibraryLocation(root: root, reference: .server(id)) }
        /// The registry lists the server libraries, `active` the one it chooses.
        func choose(_ active: String, among ids: [String]) throws {
            var registry = LibraryRegistry()
            registry.libraries = ids.map {
                .init(id: $0, serverURL: "https://sync.example.test", serverID: "server-1", accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f",
                      username: "alice", state: $0 == active ? .active : .inactive, createdAt: 1_700_000_000_000)
            }
            registry.active = .server(active)
            try registryFile.write(registry)
        }
        /// The library's folder and database exist.
        func install(_ id: String) throws {
            try location(id).prepare()
            try Data("library".utf8).write(to: location(id).database)
        }
        /// Not examinable now, as before the first unlock after a restart.
        func deny(_ item: URL) throws {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: item.path)
            denied.append(item)
        }
        func allow() throws {
            for item in denied.reversed() {
                var directory: ObjCBool = false
                FileManager.default.fileExists(atPath: item.path, isDirectory: &directory)
                try FileManager.default.setAttributes([.posixPermissions: directory.boolValue ? 0o755 : 0o644], ofItemAtPath: item.path)
            }
            denied = []
        }
        /// Every file and folder under the root with its contents, to show a start changed nothing.
        func contents() throws -> [String: Data] {
            var result: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            while let url = enumerator?.nextObject() as? URL {
                let path = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
                result[path] = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true ? Data() : Data(contentsOf: url)
            }
            return result
        }
        deinit {
            try? allow()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A graph start as the app runs it: the library to open, and the notice told only when the start succeeded (an
    /// opening that throws makes the start wait). Returns the opening, nil when the start waits.
    @discardableResult
    private func start(_ device: Device, _ notice: inout MissingLibraryNotice) throws -> LibraryGraphStart.Opening? {
        let opening: LibraryGraphStart.Opening
        do {
            opening = try LibraryGraphStart.openingLibrary(root: device.root, keep: LibraryKeep(.init(root: device.root, secrets: MemoryServerSecrets())))
        } catch where SavedState.isUnavailable(error) { return nil }
        notice.started(opening)
        return opening
    }

    /// Several screens ask in turn (scenes connecting, a scene becoming active again): how many say it.
    private func expectSaid(_ expected: Int, _ notice: inout MissingLibraryNotice, _ comment: Comment? = nil,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        var said = 0
        for _ in 0..<3 where notice.take() { said += 1 }
        #expect(said == expected, comment, sourceLocation: sourceLocation)
    }

    @Test func missingFolderIsSaidOnceAndNotAgainOnLaterStarts() throws {
        let device = try Device()
        try device.choose(serverID, among: [serverID])
        let before = try device.contents()
        var notice = MissingLibraryNotice()
        let started = try start(device, &notice)
        let opening = try #require(started)
        #expect(opening.location.reference == .standalone && opening.fallback == .folderMissing)
        #expect(opening.missing == .server(serverID))
        expectSaid(1, &notice, "the first screen says it; another scene connecting finds nothing due")
        // Restarts after a database import, a switch or a Keep fall back for the same library: nothing more.
        for _ in 0..<2 {
            let again = try start(device, &notice)
            #expect(again?.fallback == .folderMissing)
            expectSaid(0, &notice)
        }
        #expect(try device.contents() == before, "the registry and the folders are unchanged; no folder is created")
    }

    @Test func missingDatabaseIsSaidOnceAndNotAgainOnLaterStarts() throws {
        let device = try Device()
        try device.choose(serverID, among: [serverID])
        try device.location(serverID).prepare()
        let before = try device.contents()
        var notice = MissingLibraryNotice()
        let started = try start(device, &notice)
        let opening = try #require(started)
        #expect(opening.location.reference == .standalone && opening.fallback == .databaseMissing)
        #expect(opening.missing == .server(serverID))
        expectSaid(1, &notice)
        let again = try start(device, &notice)
        #expect(again?.fallback == .databaseMissing)
        expectSaid(0, &notice)
        #expect(try device.contents() == before, "the database is never created")
    }

    @Test func damagedRegistrySaysNothing() throws {
        let device = try Device()
        try Data("{".utf8).write(to: device.registryFile.url)
        var notice = MissingLibraryNotice()
        let started = try start(device, &notice)
        let opening = try #require(started)
        #expect(opening.location.reference == .standalone && opening.fallback == .registryDamaged && opening.missing == nil)
        #expect(!notice.isDue)
        expectSaid(0, &notice)
    }

    @Test func normalStartsSayNothing() throws {
        // Standalone use: no registry.
        let standalone = try Device()
        var notice = MissingLibraryNotice()
        let alone = try start(standalone, &notice)
        #expect(alone?.location.reference == .standalone && alone?.fallback == nil)
        expectSaid(0, &notice)
        // The chosen server library is there.
        let device = try Device()
        try device.choose(serverID, among: [serverID])
        try device.install(serverID)
        let started = try start(device, &notice)
        let opening = try #require(started)
        #expect(opening.location.reference == .server(serverID) && opening.fallback == nil && opening.missing == nil)
        expectSaid(0, &notice)
    }

    /// Before the first unlock the library folder cannot be examined: the start waits (no fallback, nothing due), and
    /// once it can be read the library opens as recorded, with nothing to say.
    @Test func libraryThatCannotBeReadNowDecidesNothing() throws {
        let device = try Device()
        try device.choose(serverID, among: [serverID])
        try device.install(serverID)
        try device.deny(LibraryLocation.serverLibraries(root: device.root))
        var notice = MissingLibraryNotice()
        let waiting = try start(device, &notice)
        #expect(waiting == nil, "the start waits")
        #expect(!notice.isDue)
        try device.deny(device.registryFile.url)
        let stillWaiting = try start(device, &notice)
        #expect(stillWaiting == nil)
        #expect(!notice.isDue)
        try device.allow()
        let readable = try start(device, &notice)
        #expect(readable?.location.reference == .server(serverID))
        expectSaid(0, &notice)
    }

    /// A message no screen has shown yet stays due, once, through a later start for the same library (a restart before
    /// any scene was in the foreground); a start that opens the library as recorded ends the occurrence, so the
    /// message is not said for a library that is no longer missing; the library missing again, or another missing
    /// library, is a new occurrence.
    @Test func occurrenceLastsWhileStartsFallBackForTheSameLibrary() throws {
        let device = try Device()
        try device.choose(serverID, among: [serverID, otherID])
        var notice = MissingLibraryNotice()
        try start(device, &notice)
        try start(device, &notice)
        expectSaid(1, &notice)
        try device.choose(otherID, among: [serverID, otherID])
        try start(device, &notice)
        #expect(notice.isDue, "another missing library is a new occurrence")
        // Due but not shown, then the library opens as recorded: nothing is said.
        try device.install(otherID)
        try start(device, &notice)
        expectSaid(0, &notice)
        // Missing again after a start that opened it: a new occurrence.
        try FileManager.default.removeItem(at: device.location(otherID).database)
        try start(device, &notice)
        expectSaid(1, &notice)
    }

    @Test func messageWording() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../App/Resources/en.lproj/Localizable.strings").standardized
        let strings = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        #expect(strings["ntp_server_library_missing"]
            == "The server library could not be found on this device, so this device's library is open instead.")
    }
}

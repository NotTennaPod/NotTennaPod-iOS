import Foundation
import Testing
@testable import NotTennaPodCore

/// `KeepPendingProbe`: asked on every player state change, it reads `libraries.json` only when the file changed, and
/// always answers what a fresh read answers.
@MainActor @Suite struct KeepPendingProbeTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeepProbe-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func registry(keeping: Bool, name: String = "u") -> LibraryRegistry {
        var registry = LibraryRegistry()
        registry.libraries = [.init(id: UUID().uuidString.lowercased(), serverURL: "https://example.test", serverID: "s",
                                    accountID: "a", username: name, state: keeping ? .keeping : .inactive,
                                    operation: keeping ? UUID().uuidString.lowercased() : nil, createdAt: 0)]
        return registry
    }

    static func fresh(_ root: URL) -> Bool { (try? LibraryRegistryFile(root: root).read())?.keeping != nil }

    @Test func anUnchangedFileIsReadOnce() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try LibraryRegistryFile(root: root).write(Self.registry(keeping: true))
        let probe = KeepPendingProbe(root: root)
        for _ in 0..<1_000 { #expect(probe.isPending) }
        #expect(probe.reads == 1)
    }

    @Test func noFileIsNoKeepWithoutReading() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = KeepPendingProbe(root: root)
        for _ in 0..<100 { #expect(!probe.isPending) }
        #expect(probe.reads == 0)
        try LibraryRegistryFile(root: root).write(Self.registry(keeping: true))
        #expect(probe.isPending)
    }

    /// The registry is written by rename: a replacement of the same size within the same second is a new file.
    @Test func anAtomicReplacementIsSeen() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LibraryRegistryFile(root: root)
        let probe = KeepPendingProbe(root: root)
        try file.write(Self.registry(keeping: false))
        #expect(!probe.isPending)
        try file.write(Self.registry(keeping: true))
        #expect(probe.isPending)
        try file.write(Self.registry(keeping: false))
        #expect(!probe.isPending)
        #expect(probe.reads == 3)
    }

    /// A write into the same file (same inode) changes its times or size.
    @Test func aWriteInPlaceIsSeen() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LibraryRegistryFile(root: root)
        try file.write(Self.registry(keeping: false))
        let probe = KeepPendingProbe(root: root)
        #expect(!probe.isPending)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: try encoder.encode(Self.registry(keeping: true)))
        try handle.close()
        #expect(probe.isPending)
    }

    @Test func itAnswersAsAFreshReadOverRandomRegistries() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LibraryRegistryFile(root: root)
        let probe = KeepPendingProbe(root: root)
        var generator = SystemRandomNumberGenerator()
        for step in 0..<50 {
            if Bool.random(using: &generator) {
                try file.write(Self.registry(keeping: Bool.random(using: &generator), name: String(repeating: "u", count: step % 3 + 1)))
            }
            #expect(probe.isPending == Self.fresh(root), "step \(step)")
        }
    }

    /// A registry that cannot be read now answers false and is read again at the next probe.
    @Test func aFailedReadIsNeverKept() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LibraryRegistryFile(root: root)
        try file.write(Self.registry(keeping: true))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path) }
        let probe = KeepPendingProbe(root: root)
        #expect(!probe.isPending)
        #expect(!probe.isPending)
        #expect(probe.reads == 2, "a failed read is not kept")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path)
        #expect(probe.isPending)
    }
}

import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

struct LocalFolderArtworkTests {
    private func fixture(_ body: (FeedLibraryStore, URL, URL, Data) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderArtwork-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder ü #1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try LocalFolderDocuments.makeBookmark(directory: folder)
        let database = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: database)
        _ = try await store.registerLocalFolder(title: "Local", directoryIdentity: "folder", bookmark: bookmark)
        do { try await body(store, database, folder, bookmark); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func refresh(_ store: FeedLibraryStore) async throws -> String {
        _ = try await LocalFeedRefreshService(store: store).refresh(feedID: 1, description: "Local", author: "Local")
        return try #require(try await store.feed(id: 1)?.metadata.imageURL)
    }

    @Test func preferredCoverBytesSurviveReopenAndChangingTheSelectedImage() async throws {
        try await fixture { store, database, folder, _ in
            let preferred = Data((0..<196_613).map { UInt8($0 % 251) })
            let secondary = Data([4, 5, 6])
            try preferred.write(to: folder.appendingPathComponent("folder.jpg"))
            try secondary.write(to: folder.appendingPathComponent("Folder.png"))
            let identity = try await refresh(store)
            #expect(URL(string: identity)?.lastPathComponent == "folder.jpg")
            #expect(try await LocalFolderArtworkReader(store: store).read(feedID: 1, identity: identity) == preferred)
            let reopened = try FeedLibraryStore(url: database)
            #expect(try await LocalFolderArtworkReader(store: reopened).read(feedID: 1, identity: identity) == preferred)
            try await reopened.close()
            try FileManager.default.removeItem(at: folder.appendingPathComponent("folder.jpg"))
            let next = try await refresh(store)
            #expect(URL(string: next)?.lastPathComponent == "Folder.png")
            let reader = LocalFolderArtworkReader(store: store)
            #expect(try await reader.read(feedID: 1, identity: identity) == nil)
            #expect(try await reader.read(feedID: 1, identity: next) == secondary)
        }
    }

    @Test func literalImageNamesWorkButUnselectedOutsideAndDirectoryURLsDoNot() async throws {
        try await fixture { store, _, folder, _ in
            let name = "Cover ü #100%.png"
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent(name))
            let identity = try await refresh(store)
            let reader = LocalFolderArtworkReader(store: store)
            #expect(URL(string: identity)?.lastPathComponent == name)
            #expect(try await reader.read(feedID: 1, identity: identity) == Data([1, 2, 3]))
            #expect(try await reader.read(feedID: 1, identity: folder.absoluteString) == nil)
            #expect(try await reader.read(feedID: 1, identity: folder.deletingLastPathComponent().appendingPathComponent("library.sqlite").absoluteString) == nil)
            #expect(try await reader.read(feedID: 999, identity: identity) == nil)
            let context = try await store.beginLocalFolderScan(feedID: 1)
            var snapshot = context.feed.metadata
            let outside = folder.deletingLastPathComponent().appendingPathComponent("library.sqlite").absoluteString
            snapshot.imageURL = outside
            _ = try await store.applyLocalFolderScan(snapshot, context: context)
            #expect(try await reader.read(feedID: 1, identity: outside) == nil)
            let restored = try await store.beginLocalFolderScan(feedID: 1)
            var original = restored.feed.metadata; original.imageURL = identity
            _ = try await store.applyLocalFolderScan(original, context: restored)
            #expect(try await store.localFolderArtwork(feedID: 1, identity: identity) != nil)
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            #expect(try await reader.read(feedID: 1, identity: identity) == nil)
        }
    }

    @Test func selectedDirectoryIsNotReadAndEmptyFolderUsesOriginalGenerativeModel() async throws {
        try await fixture { store, _, folder, bookmark in
            let directory = folder.appendingPathComponent("folder.jpg")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let identity = try await refresh(store)
            // Native scan input excludes directories even when their name looks like an image.
            #expect(identity == "antennapod_generative_cover:folder")
            #expect(try await LocalFolderArtworkReader(store: store).read(feedID: 1, identity: identity) == nil)
            let directoryIdentity = try #require(try await LocalFolderDocuments(bookmark: bookmark).entries()
                .first { $0.name == "folder.jpg" }?.identity)
            let context = try await store.beginLocalFolderScan(feedID: 1)
            var snapshot = context.feed.metadata; snapshot.imageURL = directoryIdentity
            _ = try await store.applyLocalFolderScan(snapshot, context: context)
            #expect(try await store.localFolderArtwork(feedID: 1, identity: directoryIdentity) != nil)
            #expect(try await LocalFolderArtworkReader(store: store).read(feedID: 1, identity: directoryIdentity) == nil)
        }
    }

    @Test(arguments: ["reconnect", "selection", "cancel"])
    func supersededOrCancelledCoverReadCannotDeliverBytes(change: String) async throws {
        try await fixture { store, _, folder, bookmark in
            try Data([1]).write(to: folder.appendingPathComponent("Folder.png"))
            let identity = try await refresh(store)
            let began = Mutex(false)
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let reader = LocalFolderArtworkReader(store: store, readBytes: { _, check in
                began.withLock { $0 = true }
                guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
                try check()
                return Data([1])
            })
            let pending = Task { try await reader.read(feedID: 1, identity: identity) }
            for _ in 0..<1000 {
                if began.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(began.withLock { $0 })
            if change == "cancel" { pending.cancel() }
            else if change == "reconnect" {
                _ = try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: "folder", bookmark: bookmark)
            } else {
                // Commit a changed image selection directly; no provider I/O while its read is held.
                let context = try await store.beginLocalFolderScan(feedID: 1)
                var snapshot = context.feed.metadata; snapshot.imageURL = "antennapod_generative_cover:folder"
                _ = try await store.applyLocalFolderScan(snapshot, context: context)
            }
            release.signal()
            if change == "cancel" { await #expect(throws: CancellationError.self) { try await pending.value } }
            else { #expect(try await pending.value == nil) }
        }
    }
}

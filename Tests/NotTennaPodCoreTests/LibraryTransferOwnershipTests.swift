import Foundation
import Testing
@testable import NotTennaPodCore

/// PROTOCOL §15.4: background transfers are reconciled against every library on the device. A transfer of an inactive
/// library is never cancelled as an orphan; transfers that belong to no library still go.
@Suite(.timeLimit(.minutes(1))) struct LibraryTransferOwnershipTests {
    private final class ListedTask: ReconciledTransfer {
        let taskIdentifier: Int
        let taskDescription: String?
        let state: URLSessionTask.State = .running
        private(set) var cancelled = false
        init(_ id: Int, destination: URL) {
            taskIdentifier = id
            taskDescription = BackgroundMediaDownloads.describe(.init(destination: BackgroundMediaDownloads.Files(destination: destination).key, base: 0))
        }
        func cancel() { cancelled = true }
    }

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TransferOwnership-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A library with one feed and an active download job; returns the job's destination.
    private func libraryDownloading(_ location: LibraryLocation) async throws -> (FeedLibraryStore, URL) {
        try location.prepare()
        let store = try FeedLibraryStore(url: location.database)
        let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Transfers", episodes: [
            ParsedEpisode(identifier: "a", title: "A", media: ParsedMedia(url: "https://example.test/a.mp3", size: 10))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let job = try #require(try await store.requestDownload(episodeID: feed.episodes[0].id, directory: location.media, enqueue: false))
        return (store, job.destination)
    }

    @Test func transfersOfInactiveLibrariesAreKept() async throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        // The active server library and the inactive standalone library each have a download running; local IDs
        // repeat, but each library downloads into its own media folder.
        let active = LibraryLocation(root: root, reference: .server("0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"))
        let standalone = LibraryLocation(root: root, reference: .standalone)
        let (inactiveStore, inactiveDestination) = try await libraryDownloading(standalone)
        try await inactiveStore.close()
        let (activeStore, activeDestination) = try await libraryDownloading(active)
        #expect(activeDestination.lastPathComponent == inactiveDestination.lastPathComponent)
        // An inactive server library whose database cannot be read keeps every transfer into its media folder.
        let damaged = LibraryLocation(root: root, reference: .server("f1d2c3b4-a5e6-4f70-8a9b-0c1d2e3f4a5b"))
        try damaged.prepare()
        try Data("not a database".utf8).write(to: damaged.database)
        let damagedDestination = damaged.media.appendingPathComponent("episode-1-download-1.media")

        let tasks = [ListedTask(1, destination: activeDestination), ListedTask(2, destination: inactiveDestination),
                     ListedTask(3, destination: damagedDestination),
                     ListedTask(4, destination: standalone.media.appendingPathComponent("episode-9-download-9.media")),
                     ListedTask(5, destination: root.appendingPathComponent("elsewhere/episode-1-download-1.media"))]
        let downloads = BackgroundMediaDownloads(identifier: "org.nottennapod.app.tests.\(UUID().uuidString)")
        let destinations = try await activeStore.downloadJobs(activeOnly: true).map(\.destination)
        let cancelled = try await downloads.reconcile(listed: tasks, ownership: {
            LibraryTransferOwnership.collect(root: root, active: active.reference, activeDestinations: destinations)
        })
        #expect(tasks.filter(\.cancelled).map(\.taskIdentifier) == [4, 5], "only transfers of no download of any library")
        #expect(cancelled == 2)

        // Before PROTOCOL §15.4, only the active library counted, so the inactive library's transfer was cancelled as an orphan.
        let previous = [ListedTask(2, destination: inactiveDestination)]
        _ = try await downloads.reconcile(previous) { destinations }
        #expect(previous[0].cancelled)
        try await activeStore.close()
    }

    /// When the library folders cannot be listed, or one library's folder cannot be searched, nothing
    /// proves its transfers are orphans: every transfer reconciliation cannot account for is kept. (Only this test's
    /// own temporary folders change permissions, and they are restored.)
    @Test func librariesThatCannotBeListedOrOpenedKeepTheirTransfers() async throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let retained = LibraryLocation(root: root, reference: .server("0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"))
        let (store, destination) = try await libraryDownloading(retained)
        try await store.close()
        let downloads = BackgroundMediaDownloads(identifier: "org.nottennapod.app.tests.\(UUID().uuidString)")
        let orphan = root.appendingPathComponent("media/episode-9-download-9.media")
        for blocked in [LibraryLocation.serverLibraries(root: root), retained.folder] {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
            let ownership = LibraryTransferOwnership.collect(root: root, active: .standalone, activeDestinations: [])
            #expect(ownership.protectedFolders.contains { destination.path.hasPrefix($0.path + "/") }, "\(blocked.lastPathComponent)")
            let tasks = [ListedTask(1, destination: destination), ListedTask(2, destination: orphan)]
            let cancelled = try await downloads.reconcile(listed: tasks, ownership: { ownership })
            #expect(tasks.filter(\.cancelled).map(\.taskIdentifier) == [2], "the retained library's transfer is kept")
            #expect(cancelled == 1)
        }
        // A library folder without a database has no jobs: nothing to keep for it.
        let empty = LibraryLocation(root: root, reference: .server("f1d2c3b4-a5e6-4f70-8a9b-0c1d2e3f4a5b"))
        try empty.prepare()
        let ownership = LibraryTransferOwnership.collect(root: root, active: .standalone, activeDestinations: [])
        #expect(ownership.protectedFolders.isEmpty && ownership.destinations == [destination])
    }

    /// The read-only connection leaves an inactive library's files as they are.
    @Test func inactiveLibraryIsReadWithoutWriting() async throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = LibraryLocation(root: root, reference: .server("0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"))
        let (store, destination) = try await libraryDownloading(location)
        try await store.close()
        let before = try Data(contentsOf: location.database)
        #expect(try LibraryTransferOwnership.activeDownloadDestinations(database: location.database) == [destination])
        #expect(try Data(contentsOf: location.database) == before)
        #expect(throws: FeedLibraryError.self) {
            try LibraryTransferOwnership.activeDownloadDestinations(database: root.appendingPathComponent("absent.sqlite"))
        }
    }
}

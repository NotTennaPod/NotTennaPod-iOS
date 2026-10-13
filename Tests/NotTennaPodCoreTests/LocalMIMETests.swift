import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

struct LocalMIMETests {
    @Test func allCapturedOriginalRuntimeDecisionsMatchSharedResolver() throws {
        struct Oracle: Decodable {
            struct Case: Decodable { let provider, url, expected: String? }
            let referenceCommit, apkSHA256: String
            let mapping: [String: String]
            let cases: [Case]
        }
        let url = try #require(Bundle.module.url(forResource: "local-mime-runtime", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(oracle.apkSHA256 == "43467135b6e12e11179d9b94afb1618c41629775af248384b19eb019701be62c")
        #expect(oracle.mapping.count == 630 && oracle.cases.count == 6645)
        #expect(AndroidMIMEMap.extensions == oracle.mapping)
        for item in oracle.cases {
            #expect(FeedMIME.resolve(item.provider, url: item.url) == item.expected,
                "provider=\(item.provider ?? "nil"), url=\(item.url ?? "nil")")
        }
    }

    @Test func missingProviderMIMEInFeedUsesSameRuntimeMapAsLocalMedia() throws {
        let xml = """
        <rss version="2.0"><channel><title>Fixture</title>
        <item><title>M4A</title><enclosure url="https://example.test/a.M4A" length="100"/></item>
        <item><title>M4B</title><enclosure url="https://example.test/b.m4b" length="100"/></item>
        <item><title>AIFF</title><enclosure url="https://example.test/c.AIFF" length="100"/></item>
        </channel></rss>
        """
        let feed = try FeedParser().parse(Data(xml.utf8))
        #expect(feed.episodes.map { $0.media?.mimeType } == ["audio/mpeg", "audio/mp4", "audio/x-aiff"])
    }

    private func fixture(_ body: (URL, FeedLibraryStore, LocalFolderDocuments) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalMIME-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: false)
        let bookmark = try LocalFolderDocuments.makeBookmark(directory: media)
        let docs = LocalFolderDocuments(bookmark: bookmark)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.registerLocalFolder(title: "Local", directoryIdentity: "fixture:folder", bookmark: bookmark)
        do { try await body(media, store, docs); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    @Test func nativeEnumerationPolicyReadAccessScannerAndStoreWorkTogether() async throws {
        try await fixture { folder, store, docs in
            for name in ["a.MP3", "b.m4b", "notes.txt", "folder.jpg"] {
                try Data(name.utf8).write(to: folder.appendingPathComponent(name))
            }
            // Directories cannot be media; do not make a bogus episode from an extension.
            let directory = folder.appendingPathComponent("directory.mp3", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data([1]).write(to: directory.appendingPathComponent("nested.mp3"))
            let reads = Mutex<[String]>([])
            let service = LocalFeedRefreshService(store: store, open: { _ in
                try await docs.scanInput { url, check in
                    try check(); reads.withLock { $0.append(url.lastPathComponent) }
                    // This fixture reader proves actual coordinated bytes, not media tag extraction.
                    return LocalFileMetadata(title: String(decoding: try Data(contentsOf: url), as: UTF8.self))
                }
            })
            guard case .updated(let result) = try await service.refresh(feedID: 1, description: "Local", author: "Local folder") else {
                Issue.record("Expected complete scan"); return
            }
            #expect(Set(result.feed.episodes.compactMap(\.details.link)) == ["a.MP3", "b.m4b"])
            #expect(Set(reads.withLock { $0 }) == ["a.MP3", "b.m4b"])
            #expect(result.feed.metadata.imageURL?.hasSuffix("/folder.jpg") == true)
            for episode in result.feed.episodes {
                #expect(episode.details.title == episode.details.link)
                let reference = try #require(try await store.localDocument(episodeID: episode.id))
                #expect(reference.identity == episode.details.media?.url)
                #expect(reference.folder.bookmark == docs.bookmark)
            }
            _ = try await service.refresh(feedID: 1, description: "Local", author: "Local folder")
            #expect(reads.withLock { $0.count } == 2, "Unchanged files reuse stored metadata")
        }
    }

    @Test func cancellationDuringCoordinatedMetadataReadCannotCommitPartialRefresh() async throws {
        try await fixture { folder, store, docs in
            try Data([1]).write(to: folder.appendingPathComponent("a.mp3"))
            let before = try await store.feed(id: 1)
            let entered = Mutex(false), release = DispatchSemaphore(value: 0)
            let service = LocalFeedRefreshService(store: store, open: { _ in
                try await docs.scanInput { _, check in
                    entered.withLock { $0 = true }; release.wait() // Only holds the fixture reader's I/O queue.
                    try check(); return LocalFileMetadata(title: "Discard")
                }
            })
            let task = Task { try await service.refresh(feedID: 1, description: "Local", author: "Local folder") }
            defer { task.cancel(); release.signal() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered.withLock({ $0 }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(entered.withLock { $0 })
            task.cancel(); release.signal()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.feed(id: 1) == before)
            #expect(try await store.logs(feedID: 1).isEmpty)
            #expect(try await store.pendingEffects().isEmpty)
        }
    }
}

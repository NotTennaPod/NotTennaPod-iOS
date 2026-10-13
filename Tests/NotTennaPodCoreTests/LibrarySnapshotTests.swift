import Foundation
import Testing
@testable import NotTennaPodCore

struct LibrarySnapshotTests {
    private func fixture(_ title: String) -> FetchedFeed {
        let source = "https://example.test/\(title)"
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: title, episodes: [
            ParsedEpisode(identifier: title, title: title, media: ParsedMedia(url: source + ".mp3", size: 10))
        ]), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
    }

    @Test func snapshotPreservesOrderingFiltersAndQueueWithoutConsumingEffects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        #expect(try await store.snapshot() == FeedLibrarySnapshot(feeds: [], queue: []))
        let z = try await store.insert(fixture("Zebra")), a = try await store.insert(fixture("alpha"))
        let zID = try #require(z.episodes.first?.id), aID = try #require(a.episodes.first?.id)
        _ = try await store.consumeQueueEffects()
        _ = try await store.enqueue([zID, aID])
        try await store.setEpisodeFilter(feedID: a.id, filter: FeedEpisodeFilter(values: ["queued"]))
        let effects = try await store.pendingEffects()
        let snapshot = try await store.snapshot()
        #expect(snapshot.feeds.map(\.id) == [a.id, z.id])
        #expect(snapshot.queue.map(\.id) == [zID, aID])
        #expect(snapshot.feeds.first?.episodeFilter.values == ["queued"])
        #expect(snapshot.feeds.flatMap(\.episodes).count == 2)
        #expect(try await store.pendingEffects() == effects)
        try await store.close()
        await #expect(throws: (any Error).self) { try await store.snapshot() }
    }

    @Test func feedsAndQueueRemainConsistentDuringConcurrentConnectionWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConcurrentSnapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let writer = try FeedLibraryStore(url: url)
        let feed = try await writer.insert(fixture("Concurrent"))
        let id = try #require(feed.episodes.first?.id)
        _ = try await writer.consumeQueueEffects()
        _ = try await writer.enqueue([id])
        let reader = try FeedLibraryStore(url: url)
        let writes = Task {
            for revision in 1...250 {
                try await writer.updateEpisode(id: id) {
                    $0.userState.positionMilliseconds = Int32(revision)
                    $0.userState.isFavorite = revision.isMultiple(of: 2)
                }
            }
        }
        for _ in 0..<250 {
            let snapshot = try await reader.snapshot()
            #expect(snapshot.feeds.first?.episodes.first == snapshot.queue.first)
        }
        try await writes.value
        let final = try await reader.snapshot()
        #expect(final.queue.first?.userState.positionMilliseconds == 250)
        #expect(final.feeds.first?.episodes.first == final.queue.first)
        try await reader.close(); try await writer.close()
    }
}

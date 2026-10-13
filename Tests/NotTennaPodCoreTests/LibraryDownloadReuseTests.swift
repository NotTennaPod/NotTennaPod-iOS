import Foundation
import Testing
@testable import NotTennaPodCore

/// PROTOCOL §15.4: at a first attachment, downloads of the libraries kept on this device are reused by the new server
/// library as APFS clones (independent files), matched by feed URL alias and episode identity.
@Suite(.timeLimit(.minutes(1))) struct LibraryDownloadReuseTests {
    private let namespace = "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f"
    private let source = "https://example.test/feed"
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadReuse-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func feed(_ episodes: [(guid: String, size: Int64)], source: String) -> FetchedFeed {
        FetchedFeed(feed: ParsedFeed(format: .rss, title: "Reuse lab", episodes: episodes.map {
            ParsedEpisode(identifier: $0.guid, title: "Episode " + $0.guid,
                          media: ParsedMedia(url: "https://cdn.example.test/\($0.guid).mp3", size: $0.size))
        }), source: source, responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil)
    }

    /// Downloads `guid` in `store` through the real job path, with `content` as the file.
    private func download(_ store: FeedLibraryStore, guid: String, content: String, media: URL) async throws {
        let episode = try #require(try await store.feeds().flatMap(\.episodes).first { $0.details.identifier == guid })
        let job = try #require(try await store.requestDownload(episodeID: episode.id, directory: media, enqueue: false, now: date))
        _ = try #require(try await store.beginDownloadAttempt(id: job.id, now: date))
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: job.destination)
        #expect(try await store.attachDownloadFile(id: job.id, attempt: 1))
        #expect(try await store.completeDownload(id: job.id, attempt: 1, now: date))
    }

    private func episode(_ store: FeedLibraryStore, _ guid: String) async throws -> LibraryEpisode {
        try #require(try await store.feeds().flatMap(\.episodes).first { $0.details.identifier == guid })
    }

    @Test func downloadsOfMatchingEpisodesAreClonedIntoTheServerLibrary() async throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        // The standalone library, kept on the device: four downloads of the feed, one of an unrelated feed.
        let standalone = LibraryLocation(root: root, reference: .standalone)
        let kept = try FeedLibraryStore(url: standalone.database)
        // Subscribed with credentials in the address and another spelling of the host: it is still the podcast's alias.
        _ = try await kept.insert(feed([("A", 0), ("B", 0), ("C", 0), ("D", 0), ("E", 0)], source: "https://alice:pw@Example.TEST:443/feed"))
        _ = try await kept.insert(feed([("Z", 0)], source: "https://other.example.test/feed"))
        for (guid, content) in [("A", "audio-A"), ("B", "audio-B"), ("C", "audio-C"), ("D", ""), ("Z", "audio-Z")] {
            try await download(kept, guid: guid, content: content, media: standalone.media)
        }
        let original = try await episode(kept, "A")
        let originalFile = try #require(original.userState.localFileURL)
        try await kept.close()

        // The server library: the same podcast; A's recorded size matches, B's does
        // not, C is not in the server's library, D's file is empty with no recorded size, E is not downloaded.
        let location = LibraryLocation(root: root, reference: .server("0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"))
        try location.prepare()
        let server = try FeedLibraryStore(url: location.database)
        _ = try await server.insert(feed([("A", 7), ("B", 999), ("D", 0), ("E", 0)], source: source))
        let before = try await episode(server, "A")
        let podcast = LibraryDownloadReuse.Podcast(podcastID: try ContractIdentity.podcastID(namespace: namespace,
            creatingOpID: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"),
            aliases: [ContractURL.normalize(source)])
        let identity = LibraryDownloadReuse.plainEpisodeIdentity(namespace: namespace)
        // The server library's episodes by wire ID (kept in `ntp_episodes`).
        var targets: [String: Int64] = [:]
        for feed in try await server.feeds() {
            for item in feed.episodes { if let id = try identity(podcast, feed, item) { targets[id] = item.id } }
        }

        let feeds = try LibraryDownloadReuse.downloadedFeeds(database: standalone.database)
        #expect(feeds.map { $0.episodes.count } == [4, 1], "read-only, downloaded episodes only")
        let candidates = LibraryDownloadReuse.candidates(feeds: feeds, podcasts: [podcast], episodeID: identity)
        #expect(candidates.count == 4, "the other feed's download is not a candidate")
        let outcomes = try await LibraryDownloadReuse.clone(candidates, into: server, media: location.media) { targets[$0] }

        let a = try await episode(server, "A")
        let cloned = location.media.appendingPathComponent("episode-\(a.id)-reused.media")
        #expect(outcomes.filter { if case .cloned = $0 { true } else { false } }.count == 1)
        #expect(outcomes.contains(.cloned(episodeID: a.id, file: cloned)))
        #expect(outcomes.contains(.noTarget), "C is not in the server library")
        #expect(outcomes.filter { $0 == .fileMismatch }.count == 2, "B's size differs; D's file is empty")
        #expect(a.userState.isDownloaded && a.userState.localFileURL == cloned.path && a.userState.downloadDate == date)
        #expect(a.details.media?.size == 7 && !a.userState.autoDownloadEnabled)
        #expect(a.userState.playState == before.userState.playState, "play state is the server records'")
        #expect(try await episode(server, "B").userState.isDownloaded == false)
        #expect(try await episode(server, "D").userState.isDownloaded == false)
        #expect(try await episode(server, "E").userState.isDownloaded == false)
        #expect(try Data(contentsOf: cloned) == Data("audio-A".utf8))

        // Independent files: deleting the kept library's download leaves the clone, and the clone changes alone.
        try FileManager.default.removeItem(atPath: originalFile)
        #expect(try Data(contentsOf: cloned) == Data("audio-A".utf8))
        // Running again (a resumed attachment) changes nothing: A is downloaded already.
        let again = try await LibraryDownloadReuse.clone(candidates, into: server, media: location.media) { targets[$0] }
        #expect(!again.contains { if case .cloned = $0 { true } else { false } })
        #expect(try FileManager.default.contentsOfDirectory(atPath: location.media.path) == [cloned.lastPathComponent])
        try await server.close()
    }

    /// A clone left by an attachment that stopped before recording it is replaced, not duplicated.
    @Test func unrecordedCloneIsReplaced() async throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("kept.media")
        try Data("new".utf8).write(to: file)
        let location = LibraryLocation(root: root, reference: .server("0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"))
        try location.prepare()
        let server = try FeedLibraryStore(url: location.database)
        _ = try await server.insert(feed([("A", 0)], source: source))
        let a = try await episode(server, "A")
        try FileManager.default.createDirectory(at: location.media, withIntermediateDirectories: true)
        try Data("stale partial".utf8).write(to: location.media.appendingPathComponent("episode-\(a.id)-reused.media"))
        let outcomes = try await LibraryDownloadReuse.clone([.init(podcastID: "p", episodeID: "e", file: file, downloadDate: nil)],
            into: server, media: location.media) { _ in a.id }
        let clone = location.media.appendingPathComponent("episode-\(a.id)-reused.media")
        #expect(outcomes == [.cloned(episodeID: a.id, file: clone)])
        #expect(try Data(contentsOf: clone) == Data("new".utf8))
        #expect(try await episode(server, "A").userState.downloadDate != nil, "an unknown original date is the reuse date")
        try await server.close()
    }
}

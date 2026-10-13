import Foundation
import Testing
@testable import NotTennaPodCore

/// The 5-second position save while playing writes only the few database pages that change, whatever the size
/// of the episode's show notes, and does not wait for the disk; every other write still does.
@Suite(.timeLimit(.minutes(1))) struct PlaybackPositionSaveTests {
    @Test(arguments: [100, 3_000, 90_000]) func positionSaveWritesAFewPagesWhateverTheShowNotes(notes: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PositionSave-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do {
            let episodes = (0..<30).map { index in
                ParsedEpisode(identifier: "e\(index)", title: "Episode \(index)", description: String(repeating: "n", count: notes),
                              publicationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                              media: ParsedMedia(url: "https://example.test/\(index).mp3", size: 1_000, durationMilliseconds: 3_600_000))
            }
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Feed", episodes: episodes),
                source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
            let id = feed.episodes[10].id
            let session = try await store.beginPlayback(episodeID: id)
            func sample(_ index: Int) -> PlaybackSample {
                .init(positionMilliseconds: Int32(1_000_000 + index * 5_000), durationMilliseconds: 3_600_000, status: .playing)
            }
            func walSize() throws -> Int {
                try #require(try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber).intValue
            }
            _ = try await store.recordPlayback(sessionID: session.id, sample: sample(0))
            let before = try walSize()
            for index in 1...20 {
                _ = try await store.recordPlayback(sessionID: session.id, sample: sample(index),
                                                   now: Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 5)))
                #expect(try await store.synchronousMode() == 2)
            }
            // A page is 4 KB plus a 24-byte frame header; the episode, session and change-generation rows.
            #expect((try walSize() - before) / 20 <= 4 * 4_120)
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.episode(id: id)?.userState.positionMilliseconds == 1_100_000)
            try await reopened.close()
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}

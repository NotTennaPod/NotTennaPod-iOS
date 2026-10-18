import Foundation
import Testing
@testable import NotTennaPodCore

/// The 5-second position save while playing writes only the few database pages that change, the same whatever the size
/// of the episode's show notes and of the library, and does not wait for the disk; every other write still does.
@Suite struct PlaybackPositionSaveTests {
    /// The pages a steady-state save writes: the episode, session and change-generation rows, the episode's key row, the
    /// history, has-history and last-played indexes, whose keys every listening save moves, and the persisted order's row
    /// (`library_change_sequence`, one row update per visible commit) (measured: 8).
    static let pagesPerSave: Int64 = 8

    /// The pages each of twenty steady-state saves wrote (counted by the store's connection, whatever the log's layout),
    /// and the WAL bytes they added, with `notes` bytes of show notes on each of `count` episodes.
    static func saves(notes: Int, episodes count: Int) async throws -> (pages: [Int64], walBytes: Int) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PositionSave-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do {
            let episodes = (0..<count).map { index in
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
            var pages: [Int64] = []
            for index in 1...20 {
                let written = await store.withDatabaseForTesting { $0.pagesWritten }
                _ = try await store.recordPlayback(sessionID: session.id, sample: sample(index),
                                                   now: Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 5)))
                pages.append(await store.withDatabaseForTesting { $0.pagesWritten } - written)
                #expect(try await store.synchronousMode() == 2)
            }
            let walBytes = try walSize() - before
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.episode(id: id)?.userState.positionMilliseconds == 1_100_000)
            try await reopened.close()
            try await store.close()
            return (pages, walBytes)
        } catch { try? await store.close(); throw error }
    }

    /// A save never rewrites the large episode row (its show notes) and never grows with the library: every one of the
    /// twenty saves writes the same pages, with 100 B, 3 KB and 90 KB of notes and with 100 and 5,000 episodes, within
    /// the constant above. (The WAL bytes are printed: a page is 4 KB plus a 24-byte frame header.)
    @Test func positionSaveWritesAFewPagesWhateverTheShowNotesAndTheLibrary() async throws {
        var runs: [String: (pages: [Int64], walBytes: Int)] = [:]
        for notes in [100, 3_000, 90_000] { runs["\(notes) B of notes"] = try await Self.saves(notes: notes, episodes: 30) }
        for count in [100, 5_000] { runs["\(count) episodes"] = try await Self.saves(notes: 3_000, episodes: count) }
        for (name, run) in runs.sorted(by: { $0.key < $1.key }) {
            print("POSITION SAVE \(name): pages per save \(run.pages), WAL \(Double(run.walBytes) / 4_120 / 20) frames per save")
        }
        let steady = Set(runs.values.flatMap(\.pages))
        #expect(steady.count == 1, "every save writes the same pages, whatever the notes and the library: \(runs.mapValues(\.pages))")
        #expect(steady.allSatisfy { $0 <= Self.pagesPerSave }, "within \(Self.pagesPerSave) pages per save: \(steady)")
    }
}

import Foundation
import Testing
@testable import NotTennaPodCore

/// The screens' library holds list projections, so a commit that changes only what a projection leaves out
/// (show notes, chapters) still reaches the screens as a changed ID (`LibraryMirrorDelta.details`): a search re-matches it
/// and an open page shows the notes again. A superseded search's scan is interrupted by its own reader token.
@Suite(.serialized)
struct ProjectedTextChangeTests {
    struct Library {
        let directory: URL, store: FeedLibraryStore, readers: LibraryReaders
        var mirror: LibraryScreenMirror
        var changes: AsyncStream<LibraryChangeSet>.Iterator
    }

    static func library(episodes: Int = 300, feeds: Int = 12) async throws -> Library {
        let directory = try EpisodeListKeysTests.directory()
        let url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: episodes, feeds: feeds)
        let store = try FeedLibraryStore(url: url)
        try await store.waitForDerivedData()
        let changes = store.changes.subscribe().changes.makeAsyncIterator()
        let mirror = LibraryScreenMirror(try await store.screenSnapshot())
        return Library(directory: directory, store: store, readers: try await store.readers(), mirror: mirror, changes: changes)
    }

    /// The matches of `query` as a new query finds them, over `library`'s mirror.
    static func fresh(_ query: String, _ library: Library) async throws -> LibrarySearchMatches {
        try #require(try await LibrarySearchMatches.scan(query: query, reader: library.readers.bulk, mirror: library.mirror, feedID: nil, archived: false))
    }

    /// The next committed set, read and applied to the mirror as the screens do (`request(for:)`, `mirrorRead`, `apply`).
    static func patch(_ library: inout Library) async throws -> LibraryMirrorDelta {
        let set = try #require(await library.changes.next(isolation: #isolation))
        let read = try await library.readers.quick.mirrorRead(library.mirror.request(for: [set]))
        return library.mirror.apply(read)
    }

    /// Notes changed alone. The changed episode is named; a word they lost stops matching and a word they gained
    /// starts, as a new query finds; nothing else is re-matched.
    @Test func aShowNotesOnlyChangeReachesAnOpenSearch() async throws {
        var library = try await Self.library()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let target = try #require(library.mirror.feeds.first { $0.subscriptionState == .subscribed }?.episodes.first).id
        try await library.store.updateEpisode(id: target) { $0.details.description = "<p>zebrafinch</p>" }
        _ = try await Self.patch(&library)
        var old = try await Self.fresh("zebrafinch", library), new = try await Self.fresh("quokkaword", library)
        #expect(old.count == 1 && new.count == 0)
        let text: (Set<Int64>, [String]) throws -> Set<Int64>? = { [detail = library.readers.detail] ids, words in try detail.episodes(ids, matching: words) }
        try await library.store.updateEpisode(id: target) { $0.details.description = "<p>quokkaword</p>" }
        let delta = try await Self.patch(&library)
        #expect(delta.episodes.isEmpty && delta.details == [target] && !delta.isEmpty, "the notes-only change is named")
        old.apply(delta, mirror: library.mirror, text: text)
        new.apply(delta, mirror: library.mirror, text: text)
        #expect(old.metrics.episodesEvaluated == 1 && new.metrics.episodesEvaluated == 1, "only the changed episode is matched again")
        var freshOld = try await Self.fresh("zebrafinch", library), freshNew = try await Self.fresh("quokkaword", library)
        #expect(old.count == 0 && new.count == 1)
        #expect(old.result(mirror: library.mirror) == freshOld.result(mirror: library.mirror))
        #expect(new.result(mirror: library.mirror) == freshNew.result(mirror: library.mirror))
        try await library.store.close()
    }

    /// A user-state change keeps the row's change as before and names nothing else; a header-only change names no episode.
    @Test func otherChangesNameNoDetails() async throws {
        var library = try await Self.library()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let feed = try #require(library.mirror.feeds.first { $0.subscriptionState == .subscribed })
        try await library.store.setFavorite(episodeID: feed.episodes[0].id, favorite: true)
        let favorite = try await Self.patch(&library)
        #expect(favorite.episodes.keys.sorted() == [feed.episodes[0].id] && favorite.details.isEmpty)
        try await library.store.updatePreferences(feedID: feed.id) { $0.customTitle = "Renamed" }
        let header = try await Self.patch(&library)
        #expect(header.episodes.isEmpty && header.details.isEmpty && header.headers == [feed.id])
        try await library.store.close()
    }

    /// A query cancelled before its read starts never reads.
    @Test func aQueryCancelledBeforeItsReadNeverReads() async throws {
        let library = try await Self.library()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let reader = library.readers.bulk, mirror = library.mirror
        let before = await reader.metrics.readTransactions
        let task = Task { try await LibrarySearchMatches.scan(query: "episode", reader: reader, mirror: mirror, feedID: nil, archived: false) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await reader.metrics.readTransactions == before, "the cancelled query's read never ran")
        try await library.store.close()
    }

    /// A query cancelled while its scan runs is interrupted at once (the reader is free for the next query), and only
    /// its own read: the next query's scan completes. At 100,000 episodes with `NTP_SCALE=1`, else 20,000.
    @Test func aCancelledQueryInterruptsItsScan() async throws {
        let scale = ProcessInfo.processInfo.environment["NTP_SCALE"] == "1"
        let library = try await Self.library(episodes: scale ? 100_000 : 20_000, feeds: scale ? 500 : 120)
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let reader = library.readers.bulk, mirror = library.mirror
        // Words with a LIKE wildcard are matched in the records' JSON for every episode: a long scan.
        let query = "e_ a_ o_ i_ n_"
        let clock = ContinuousClock()
        var started = clock.now
        let whole = try await LibrarySearchMatches.scan(query: query, reader: reader, mirror: mirror, feedID: nil, archived: false)
        let full = started.duration(to: clock.now)
        #expect(whole != nil)
        let token = LibraryReader.Token()
        let task = Task { try await LibrarySearchMatches.scan(query: query, reader: reader, mirror: mirror, feedID: nil, archived: false, token: token) }
        let deadline = clock.now.advanced(by: .seconds(30))
        while !reader.isRunning(token), clock.now < deadline { await Task.yield() }
        #expect(reader.isRunning(token), "the scan is running")
        started = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let stopped = started.duration(to: clock.now)
        // The next query is not held behind the superseded one.
        started = clock.now
        let next = try await LibrarySearchMatches.scan(query: "episode", reader: reader, mirror: mirror, feedID: nil, archived: false)
        let following = started.duration(to: clock.now)
        print("SEARCH cancel at \(scale ? 100_000 : 20_000): whole scan \(full), cancelled returned after \(stopped), next query \(following)")
        #expect(next != nil)
        #expect(stopped * 4 < full, "the cancelled scan stopped in \(stopped) (a whole scan takes \(full))")
        try await library.store.close()
    }
}

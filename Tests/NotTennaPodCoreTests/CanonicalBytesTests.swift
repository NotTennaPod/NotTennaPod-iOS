import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

/// The byte-preservation oracle is `DerivedDataOracle.canonicalHashes`: every canonical table's
/// rows (rowid and typed values, in rowid order), `sqlite_sequence` included, the derived tables and `details_generation`
/// left out, kept outside the library under test. Changed tables, by name.
enum CanonicalBytes {
    static func hashes(_ url: URL) throws -> [String: String] { try DerivedDataOracle.canonicalHashes(url) }
    static func changed(_ before: [String: String], _ after: [String: String]) -> [String] {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }
    /// Every table of the library is hashed or one of the agreed exclusions: none drops out unseen.
    static func expectCoverage(_ url: URL, _ hashes: [String: String], required: Set<String>, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let all = Set(try RawLibrary.rows(url, "SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0[0] ?? nil })
        let excluded = all.filter { $0.hasPrefix("sqlite_stat") || DerivedDataOracle.derivedTables.contains($0) }
        #expect(Set(hashes.keys) == all.subtracting(excluded), "uncovered: \(all.subtracting(excluded).subtracting(hashes.keys).sorted())", sourceLocation: sourceLocation)
        #expect(required.isSubset(of: hashes.keys), "missing: \(required.subtracting(hashes.keys).sorted())", sourceLocation: sourceLocation)
    }
}

@Suite
struct CanonicalBytesTests {
    /// Every read-only path the screens, statistics, search, automatic download and the player use leaves every canonical
    /// table byte-identical (the expected hashes are kept here, outside the library).
    @Test(arguments: [false, true])
    func readOnlyPathsKeepEveryCanonicalByte(server: Bool) async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url: URL, store: FeedLibraryStore
        var fixture: ServerLibraryFixture?
        if server {
            let made = try await ServerLibraryFixture(server: true)
            fixture = made
            for index in 0..<3 { _ = try await made.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/s\(index).xml", title: "Show \(index)", count: 40)) }
            url = made.url; store = made.store
        } else {
            url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: 2_000, feeds: 40)
            store = try FeedLibraryStore(url: url)
        }
        let before = try CanonicalBytes.hashes(url)
        try CanonicalBytes.expectCoverage(url, before, required: ["episodes", "feeds", "queue", "sqlite_sequence", "feed_changes", "ntp_ledger", "statistics_units"])
        let open = try await store.screenSnapshot()
        let ids = open.snapshot.feeds.flatMap(\.episodes).map(\.id)
        var request = LibraryMirrorRequest()
        request.episodes = Set(ids.prefix(50)); request.resetFeeds = Set(open.snapshot.feeds.prefix(3).map(\.id)); request.queue = true
        _ = try await store.mirrorRead(request)
        let readers = try await store.readers()
        _ = try await readers.quick.mirrorRead(request)
        _ = try await readers.quick.keys(ids: Array(ids.prefix(100)))
        _ = try await readers.quick.counts()
        _ = try await readers.bulk.listFeedHeaders()
        _ = try await readers.bulk.searchMatches(words: ["the"])
        _ = try readers.detail.episode(id: ids[0])
        _ = try readers.detail.episodes(Set(ids.prefix(200)), matching: ["a"])
        _ = try await store.statisticsLibrary()
        _ = try await store.statisticsFeeds()
        _ = try await store.automaticDownloadLibrary()
        _ = try await store.feedHeaders()
        _ = try await store.listedFeedHeader(id: open.snapshot.feeds[0].id)
        _ = try await store.playbackFeedHeader(id: open.snapshot.feeds[0].id)
        _ = try await store.search(query: "the")
        _ = try await store.statisticsSnapshot(feedID: open.snapshot.feeds[0].id)
        _ = try await store.serverReleaseCandidates()
        _ = try await store.serverReleaseNotifications()
        _ = try await store.snapshot()
        let after = try CanonicalBytes.hashes(url)
        #expect(CanonicalBytes.changed(before, after).isEmpty, "\(CanonicalBytes.changed(before, after))")
        if let fixture { await fixture.close() } else { try await store.close() }
    }

    /// Schema 22's step (its file-name and NEW indexes) keeps every canonical byte.
    @Test func schema22KeepsEveryCanonicalByte() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: 600, feeds: 12)
        // The library as schema 21 left it.
        try RawLibrary.execute(url, "DROP INDEX episode_list_keys_file_name; DROP INDEX episode_list_keys_new; "
            + "CREATE INDEX episode_list_keys_file ON episode_list_keys(local_file_name) WHERE local_file_name > ''; PRAGMA user_version = 21")
        let before = try CanonicalBytes.hashes(url)
        let store = try FeedLibraryStore(url: url)
        try await store.close()
        #expect(try RawLibrary.rows(url, "PRAGMA user_version") == [["22"]])
        #expect(try RawLibrary.rows(url, "SELECT name FROM sqlite_master WHERE name IN ('episode_list_keys_file', 'episode_list_keys_file_name', 'episode_list_keys_new') ORDER BY name")
                == [["episode_list_keys_file_name"], ["episode_list_keys_new"]])
        #expect(CanonicalBytes.changed(before, try CanonicalBytes.hashes(url)).isEmpty)
    }

    /// Mutation: a read path that writes a projection back (its show notes and chapters lost) is caught by the oracle, and
    /// with the writer's guard it cannot happen at all.
    @Test func aProjectionWrittenBackIsCaught() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: 300, feeds: 12)
        let store = try FeedLibraryStore(url: url)
        let open = try await store.screenSnapshot()
        let projection = try #require(open.snapshot.feeds.flatMap(\.episodes).first)
        let feedID = open.snapshot.feeds.first { $0.episodes.contains { $0.id == projection.id } }!.id
        let stored = try #require(try await store.episode(id: projection.id))
        #expect(stored.details.description != nil && projection.details.description == nil)
        let before = try CanonicalBytes.hashes(url)
        // Guarded (every user-state writer): refused, nothing written.
        await #expect(throws: FeedLibraryError.invalidMutation) { try await store.saveForTesting(projection, feedID: feedID, scope: .userState) }
        #expect(CanonicalBytes.changed(before, try CanonicalBytes.hashes(url)).isEmpty)
        // The same write with the guard removed (a metadata write's scope): the oracle sees the lost show notes.
        try await store.saveForTesting(projection, feedID: feedID, scope: .metadata)
        // (`feed_changes` counts the write, as for any episode write.)
        let changed = CanonicalBytes.changed(before, try CanonicalBytes.hashes(url))
        #expect(changed.filter { $0 != "feed_changes" } == ["episodes"], "\(changed)")
        #expect(try await store.episode(id: projection.id)?.details.description == nil, "the show notes are lost")
        try await store.close()
    }
}

@Suite
struct CanonicalBytesMutationTests {
    /// The oracle sees allocation state: an AUTOINCREMENT high-water mark raised (no row of any other table changes).
    @Test func aRaisedSequenceIsDetected() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/seq.xml", count: 2), options: .init(now: EpisodeListKeysTests.now))
        _ = try await store.requestDownload(episodeID: feed.episodes[0].id, directory: directory.appendingPathComponent("downloads"), enqueue: false)
        try await store.close()
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM sqlite_sequence") != [["0"]], "the library allocates by AUTOINCREMENT")
        let before = try CanonicalBytes.hashes(url)
        try RawLibrary.execute(url, "UPDATE sqlite_sequence SET seq = seq + 50000")
        #expect(CanonicalBytes.changed(before, try CanonicalBytes.hashes(url)) == ["sqlite_sequence"])
    }

    /// The oracle sees row identity and order: the release ledger's rows renumbered in reverse (the order release
    /// notifications follow) with every value kept.
    @Test func reversedLedgerRowsAreDetected() async throws {
        let fixture = try await ServerLibraryFixture(server: true)
        let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/ledger-order.xml", title: "Ledger", count: 2))
        for episode in registered.feed.episodes {
            try await fixture.store.executeForTesting("INSERT INTO ntp_ledger(generation_id, occurrence, entry_id, state, notified, record) VALUES ('g', ?, NULL, 'pending', 0, X'7B7D')",
                                                      [.text(FeedLibraryStore.ledgerKey(localEpisode: episode.id))])
        }
        try await fixture.store.updatePreferences(feedID: registered.feed.id) { $0.showEpisodeNotification = true }
        let keys = try await fixture.store.serverReleaseNotifications().flatMap(\.keys)
        let before = try CanonicalBytes.hashes(fixture.url)
        try await fixture.store.executeForTesting("UPDATE ntp_ledger SET rowid = -rowid")
        #expect(try await fixture.store.serverReleaseNotifications().flatMap(\.keys) == keys.reversed(), "the readers' order follows the rows")
        #expect(CanonicalBytes.changed(before, try CanonicalBytes.hashes(fixture.url)) == ["ntp_ledger"])
        await fixture.close()
    }
}

extension FeedLibraryStore {
    /// Tests: one episode write in its own transaction, with the given scope.
    func saveForTesting(_ episode: LibraryEpisode, feedID: Int64, scope: EpisodeWriteScope) throws {
        try write(.local) { try saveEpisode(episode, feedID: feedID, scope: scope) }
    }
}

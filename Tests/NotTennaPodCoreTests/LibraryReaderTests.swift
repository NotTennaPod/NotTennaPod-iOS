import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

/// The screen readers: each call one read transaction of committed data, interrupts scoped to their request, closing
/// before the library's files move, derived data only once complete, REAL and TEXT values, and the list and player
/// visibility of a pinned removal and a staged episode.
@Suite(.serialized) struct LibraryReaderTests {
    /// A long scan (seconds) for interrupt tests.
    static let longScan = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 2000000000) SELECT count(*) FROM c"

    /// A raw connection held open across awaits (another writer of the library).
    final class RawConnection: @unchecked Sendable {
        let handle: OpaquePointer
        init(_ url: URL) throws {
            var db: OpaquePointer?
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { throw FeedLibraryError.invalidLocation }
            handle = db
            sqlite3_busy_timeout(db, 5_000)
        }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw FeedLibraryError.sqlite(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
            }
        }
        deinit { sqlite3_close_v2(handle) }
    }

    static func library() async throws -> (URL, FeedLibraryStore, LibraryFeed, LibraryFeed) {
        let directory = try EpisodeListKeysTests.directory()
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let a = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/a.xml", title: "A", count: 20), options: .init(now: EpisodeListKeysTests.now))
        let b = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/b.xml", title: "B", count: 5), options: .init(now: EpisodeListKeysTests.now))
        return (url, store, a, b)
    }

    static func waitUntilRunning(_ reader: LibraryReader, _ token: LibraryReader.Token) async {
        while !reader.isRunning(token) { await Task.yield() }
    }

    @Test func aReadSeesOnlyCommittedDataAndOneSnapshotPerCall() async throws {
        let (url, store, a, _) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let readers = try await store.readers()
        let id = a.episodes[0].id
        let writer = try RawConnection(url)
        var favorite = a.episodes[0]; favorite.userState.isFavorite = true
        let record = try DerivedDataOracle.record(favorite)
        try writer.execute("BEGIN IMMEDIATE; UPDATE episodes SET record = X'\(record.map { String(format: "%02X", $0) }.joined())' WHERE id = \(id)")
        #expect(try await readers.quick.keys(ids: [id]).first?.isFavorite == false, "an uncommitted write is not seen")
        try writer.execute("COMMIT")
        #expect(try await readers.quick.keys(ids: [id]).first?.isFavorite == true)
        // Two statements of one call see one snapshot, whatever commits between them.
        let (first, second) = try await readers.bulk.read { database in
            let first = try database.scalar("SELECT favorite FROM episode_list_keys WHERE id = \(id)")
            try writer.execute("UPDATE episode_list_keys SET favorite = 0 WHERE id = \(id)")
            return (first, try database.scalar("SELECT favorite FROM episode_list_keys WHERE id = \(id)"))
        }
        #expect(first == 1 && second == 1)
        await store.closeReaders()
        try await store.close()
    }

    @Test func anInterruptCancelsOnlyItsOwnRequest() async throws {
        let (url, store, a, _) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let readers = try await store.readers()
        let bulk = readers.bulk
        // A running scan is interrupted; a keyed read on the quick reader meanwhile is unaffected.
        let scan = LibraryReader.Token()
        let running = Task { try await bulk.read(token: scan) { try $0.scalar(Self.longScan) } }
        await Self.waitUntilRunning(bulk, scan)
        #expect(try await readers.quick.keys(ids: [a.episodes[0].id]).count == 1)
        bulk.interrupt(scan)
        await #expect(throws: CancellationError.self) { try await running.value }
        // The next call on the same reader runs.
        #expect(try await bulk.counts().count == 2)
        // Cancelling A while B runs: B finishes with its result, A never begins.
        let b = LibraryReader.Token(), aToken = LibraryReader.Token()
        let metricsBefore = await bulk.metrics.readTransactions
        let bTask = Task { try await bulk.read(token: b) { try $0.scalar("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3000000) SELECT count(*) FROM c") } }
        await Self.waitUntilRunning(bulk, b)
        let aTask = Task { try await bulk.read(token: aToken) { try $0.scalar("SELECT 1") } }
        bulk.interrupt(aToken)
        #expect(try await bTask.value == 3_000_000)
        await #expect(throws: CancellationError.self) { try await aTask.value }
        #expect(await bulk.metrics.readTransactions == metricsBefore + 1, "A was refused before it began")
        await store.closeReaders()
        try await store.close()
    }

    @Test func closingTheReadersInterruptsAndClosesThemBeforeFilesMove() async throws {
        let (url, store, _, _) = try await Self.library()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readers = try await store.readers()
        let bulk = readers.bulk
        let scan = LibraryReader.Token()
        let running = Task { try await bulk.read(token: scan) { try $0.scalar(Self.longScan) } }
        await Self.waitUntilRunning(bulk, scan)
        await store.closeReaders()
        await #expect(throws: CancellationError.self) { try await running.value }
        let quickClosed = await readers.quick.isClosed, bulkClosed = await readers.bulk.isClosed
        #expect(quickClosed && bulkClosed, "no reader connection is open")
        await #expect(throws: FeedLibraryError.closed) { try await readers.quick.counts() }
        await #expect(throws: FeedLibraryError.closed) { try await store.readers() }
        try await store.close()
        // As a Keep moves the library: nothing holds it.
        try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("moved.sqlite"))
    }

    @Test func realAndTextValuesAndCountersAreRead() async throws {
        let (url, store, a, _) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let readers = try await store.readers()
        let episode = try #require(try await store.episode(id: a.episodes[0].id))
        let keys = try #require(try await readers.quick.keys(ids: [episode.id]).first)
        #expect(keys.publicationReference?.bitPattern == episode.details.publicationDate?.timeIntervalSinceReferenceDate.bitPattern)
        #expect(keys == EpisodeListKeys(episode: episode, feedID: a.id, hidden: false, feedEligible: true))
        // A JSON function's TEXT result decodes as a record.
        let value = try await readers.bulk.read { database in
            try database.rows("SELECT json_remove(CAST(record AS TEXT), '$.details.description') FROM episodes WHERE id = ?", [.integer(episode.id)])[0][0]
        }
        guard case .text = value else { Issue.record("not TEXT: \(value)"); return }
        let decoded: LibraryEpisode = try await readers.bulk.decodeForTesting(value)
        var expected = episode; expected.details.description = nil
        #expect(decoded == expected)
        let metrics = await readers.bulk.metrics, quick = await readers.quick.metrics
        #expect(metrics.readTransactions == 1 && metrics.recordsDecoded == 1 && metrics.bytesDecoded > 0)
        #expect(quick.readTransactions == 1 && quick.keyRows == 1 && quick.statementSteps > 0 && quick.pagesFetched > 0)
        await store.closeReaders()
        try await store.close()
    }

    @Test func listsLeaveOutWhatThePlayerStillReads() async throws {
        let (url, store, a, b) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let readers = try await store.readers()
        let pinnedEpisode = b.episodes[0].id, staged = a.episodes[0].id
        try DerivedDataOracle.write(url, "INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(b.id)])
        try DerivedDataOracle.write(url, "INSERT INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (?, ?)", [.integer(staged), .integer(a.id)])
        #expect(try await readers.bulk.listFeedHeaders().map(\.id) == [a.id], "the pinned removal leaves every list")
        #expect(try await readers.quick.counts().keys.sorted() == [a.id])
        #expect(try await readers.quick.listEpisodes(ids: [pinnedEpisode, staged, a.episodes[1].id]).map(\.id) == [a.episodes[1].id])
        #expect(try await readers.quick.playerFeedHeader(id: b.id)?.id == b.id, "the player keeps its podcast")
        #expect(try await readers.quick.playerEpisode(id: pinnedEpisode)?.id == pinnedEpisode)
        #expect(try await readers.quick.playerEpisode(id: staged)?.id == staged)
        #expect(try await readers.quick.counts(feeds: [a.id, b.id])[a.id]?.total == 19, "the staged row does not count")
        try DerivedDataOracle.write(url, "DELETE FROM pinned_feed_removals")
        #expect(try await readers.bulk.listFeedHeaders().map(\.id) == [a.id, b.id], "released")
        await store.closeReaders()
        try await store.close()
    }
    // MARK: - Direct close and ownership

    /// A reader's own close interrupts the read running on it at once (it does not wait for the actor first).
    @Test func aReadersCloseInterruptsTheReadRunningOnIt() async throws {
        let (url, store, _, _) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let readers = try await store.readers()
        let bulk = readers.bulk, scan = LibraryReader.Token()
        let running = Task { try await bulk.read(token: scan) { try $0.scalar(Self.longScan) } }
        await Self.waitUntilRunning(bulk, scan)
        await bulk.close()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await bulk.isClosed)
        // The pair's close does the same for a scan on the other reader.
        let quick = readers.quick, other = LibraryReader.Token()
        let second = Task { try await quick.read(token: other) { try $0.scalar(Self.longScan) } }
        await Self.waitUntilRunning(quick, other)
        await readers.close()
        await #expect(throws: CancellationError.self) { try await second.value }
        try await store.close()
    }

    /// A reader and its connection are freed with it: nothing owns them in a cycle.
    @Test func aReaderIsFreedWithItsConnection() async throws {
        let (url, store, _, _) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        weak var quickControl: AnyObject?, bulkControl: AnyObject?
        do {
            let readers = try LibraryReaders(url: url)
            quickControl = readers.quick.controlForTesting
            bulkControl = readers.bulk.controlForTesting
            _ = try await readers.quick.counts()
        }
        #expect(quickControl == nil && bulkControl == nil, "the readers' controls (and connections) are freed")
        try await store.close()
    }

    // MARK: - Keyed reads stay keyed

    /// A keyed counts read and a keyed episode read cost the same whatever the number of unrelated podcast mappings,
    /// active or retained with no live feed.
    @Test func keyedReadsDoNotGrowWithUnrelatedPodcastMappings() async throws {
        var countSteps: [Int64] = [], episodeSteps: [Int64] = []
        for mappings in [100, 500, 1_000] {
            let (url, store, a, _) = try await Self.library()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            var statements: [(String, [LibrarySQLValue])] = [("BEGIN", [])]
            for number in 0..<mappings {
                // Half retained with no feed, half naming feeds the library no longer has; one in ten pinned.
                statements.append(("INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES (?, ?, ?)",
                                   [.text("p\(number)"), number.isMultiple(of: 2) ? .null : .integer(100_000 + Int64(number)), .integer(number.isMultiple(of: 10) ? 1 : 0)]))
            }
            statements.append(("COMMIT", []))
            try DerivedDataOracle.write(url, statements)
            let readers = try await store.readers()
            let episode = a.episodes[0].id
            _ = try await readers.quick.counts(feeds: [a.id]); _ = try await readers.quick.listEpisodes(ids: [episode])
            var before = await readers.quick.metrics.statementSteps
            #expect(try await readers.quick.counts(feeds: [a.id])[a.id]?.total == 20)
            countSteps.append(await readers.quick.metrics.statementSteps - before)
            before = await readers.quick.metrics.statementSteps
            #expect(try await readers.quick.listEpisodes(ids: [episode]).map(\.id) == [episode])
            episodeSteps.append(await readers.quick.metrics.statementSteps - before)
            await store.closeReaders()
            try await store.close()
        }
        print("DERIVED reader budget: one feed's counts \(countSteps), one episode \(episodeSteps) VM steps with 100/500/1000 mappings")
        #expect(Double(countSteps.max()!) <= 1.1 * Double(countSteps[0]) + 16, "\(countSteps)")
        #expect(Double(episodeSteps.max()!) <= 1.1 * Double(episodeSteps[0]) + 16, "\(episodeSteps)")
    }

    // MARK: - Visibility matrix

    enum Visibility: CaseIterable { case shown, staging, removing, staged, pinned, serverPinned, stagingAndPinned, stagedAndServerPinned }

    /// Every public list and player read, for a feed and an episode in each visibility state, against an independent
    /// expectation: lists never show a feed hidden as a whole (staging, removing, either pin) or an individually staged
    /// episode; the player reads always do; raw keys flag only the individually staged episode.
    @Test(arguments: Visibility.allCases) func everyReaderFollowsTheVisibilityMatrix(_ state: Visibility) async throws {
        let (url, store, a, b) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let readers = try await store.readers()
        let episode = a.episodes[0].id, other = a.episodes[1].id
        try Self.apply(state, url: url, feed: a.id, episode: episode)
        let failures = try await Self.matrixFailures(state, readers: readers, a: a, b: b, episode: episode, other: other)
        #expect(failures.isEmpty, "\(state): \(failures)")
        // Released: everything shows again.
        try RawLibrary.execute(url, "DELETE FROM ntp_hidden_feeds; DELETE FROM ntp_hidden_episodes; DELETE FROM pinned_feed_removals; DELETE FROM ntp_podcasts")
        let released = try await Self.matrixFailures(.shown, readers: readers, a: a, b: b, episode: episode, other: other)
        #expect(released.isEmpty, "released from \(state): \(released)")
        await store.closeReaders()
        try await store.close()
    }

    static func apply(_ state: Visibility, url: URL, feed: Int64, episode: Int64) throws {
        let staging = "INSERT INTO ntp_hidden_feeds(feed_id, podcast_id, state, seq) VALUES (\(feed), 'p', 'staging', 1)"
        let removing = "INSERT INTO ntp_hidden_feeds(feed_id, podcast_id, state, seq) VALUES (\(feed), 'p', 'removing', 1)"
        let staged = "INSERT INTO ntp_hidden_episodes(episode_id, feed_id, seq) VALUES (\(episode), \(feed), 1)"
        let pinned = "INSERT INTO pinned_feed_removals(feed_id) VALUES (\(feed))"
        let serverPinned = "INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES ('pin', \(feed), 1)"
        let sql: [String] = switch state {
        case .shown: []
        case .staging: [staging]
        case .removing: [removing]
        case .staged: [staged]
        case .pinned: [pinned]
        case .serverPinned: [serverPinned]
        case .stagingAndPinned: [staging, pinned]
        case .stagedAndServerPinned: [staged, serverPinned]
        }
        if !sql.isEmpty { try RawLibrary.execute(url, sql.joined(separator: "; ")) }
    }

    /// What each reader returns that the matrix does not expect.
    static func matrixFailures(_ state: Visibility, readers: LibraryReaders, a: LibraryFeed, b: LibraryFeed, episode: Int64, other: Int64,
                               listEpisodes: ((LibraryReaders, [Int64]) async throws -> [Int64])? = nil) async throws -> [String] {
        let feedHidden = [.staging, .removing, .pinned, .serverPinned, .stagingAndPinned, .stagedAndServerPinned].contains(state)
        let episodeHidden = feedHidden || state == .staged
        var failures: [String] = []
        let headers = try await readers.bulk.listFeedHeaders().map(\.id)
        if headers != (feedHidden ? [b.id] : [a.id, b.id]) { failures.append("headers \(headers)") }
        let counts = try await readers.quick.counts(feeds: [a.id, b.id])
        if Set(counts.keys) != (feedHidden ? [b.id] : [a.id, b.id]) { failures.append("counts feeds \(counts.keys.sorted())") }
        if !feedHidden, counts[a.id]?.total != (state == .staged ? 19 : 20) { failures.append("counts total \(String(describing: counts[a.id]?.total))") }
        let ids = [episode, other, b.episodes[0].id]
        let listed: [Int64]
        if let listEpisodes { listed = try await listEpisodes(readers, ids) } else { listed = try await readers.quick.listEpisodes(ids: ids).map(\.id) }
        let expectedListed = (episodeHidden ? [] : [episode]) + (feedHidden ? [] : [other]) + [b.episodes[0].id]
        if listed != expectedListed { failures.append("listed \(listed), expected \(expectedListed)") }
        if try await readers.quick.playerFeedHeader(id: a.id)?.id != a.id { failures.append("player feed") }
        if try await readers.quick.playerEpisode(id: episode)?.id != episode { failures.append("player episode") }
        let keys = try await readers.quick.keys(ids: [episode, other])
        if keys.map(\.id) != [episode, other] || keys[0].hidden != (state == .staged || state == .stagedAndServerPinned) || keys[1].hidden {
            failures.append("raw keys \(keys.map { ($0.id, $0.hidden) })")
        }
        if keys[0].feedEligible != ![.pinned, .serverPinned, .stagingAndPinned, .stagedAndServerPinned].contains(state) {
            failures.append("eligibility \(keys[0].feedEligible)")
        }
        return failures
    }

    /// The list-episode read without its whole-feed hiding term shows an ordinary episode of a staging or removing feed:
    /// the matrix catches it.
    @Test func theMatrixCatchesAListReadMissingTheHiddenFeedTerm() async throws {
        for state in [Visibility.staging, .removing] {
            let (url, store, a, b) = try await Self.library()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let readers = try await store.readers()
            try Self.apply(state, url: url, feed: a.id, episode: a.episodes[0].id)
            let mutant = LibraryReader.listEpisodesStatement { column in
                "NOT EXISTS (SELECT 1 FROM pinned_feed_removals WHERE feed_id = \(column)) AND NOT EXISTS (SELECT 1 FROM ntp_podcasts p WHERE p.feed_id = \(column) AND p.pinned_removal = 1)"
            }
            let failures = try await Self.matrixFailures(state, readers: readers, a: a, b: b, episode: a.episodes[0].id, other: a.episodes[1].id) { readers, ids in
                let rows = try await readers.quick.read { database in
                    try LibraryReader.chunks(ids).flatMap { try database.rows(mutant, [.text($0)]) }
                }
                var episodes: [LibraryEpisode] = []
                for row in rows { episodes.append(try await readers.quick.decodeForTesting(row[0])) }
                let found = Set(episodes.map(\.id))
                return ids.filter(found.contains)
            }
            #expect(!failures.isEmpty, "the mutant is caught for \(state)")
            print("MUTATION list read without the hidden-feed term (\(state)): \(failures)")
            await store.closeReaders()
            try await store.close()
        }
    }

    /// The earlier uncorrelated pinned-mapping condition scans every mapping: the keyed-read budget catches it.
    @Test func theBudgetCatchesAnUncorrelatedMappingScan() async throws {
        var steps: [Int64] = []
        let scanning = LibraryReader.listEpisodesStatement { column in
            "\(column) NOT IN (SELECT feed_id FROM pinned_feed_removals) AND \(column) NOT IN (SELECT feed_id FROM ntp_hidden_feeds)"
                + " AND \(column) NOT IN (SELECT feed_id FROM ntp_podcasts WHERE pinned_removal = 1 AND feed_id IS NOT NULL)"
        }
        for mappings in [100, 1_000] {
            let (url, store, a, _) = try await Self.library()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            var statements: [(String, [LibrarySQLValue])] = [("BEGIN", [])]
            for number in 0..<mappings {
                statements.append(("INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES (?, NULL, 1)", [.text("p\(number)")]))
            }
            statements.append(("COMMIT", []))
            try DerivedDataOracle.write(url, statements)
            let readers = try await store.readers()
            let chunk = LibraryReader.chunks([a.episodes[0].id])[0]
            _ = try await readers.quick.read { try $0.rows(scanning, [.text(chunk)]) }
            let before = await readers.quick.metrics.statementSteps
            _ = try await readers.quick.read { try $0.rows(scanning, [.text(chunk)]) }
            steps.append(await readers.quick.metrics.statementSteps - before)
            await store.closeReaders()
            try await store.close()
        }
        #expect(Double(steps[1]) > 1.1 * Double(steps[0]) + 16, "the scan grows: \(steps)")
        print("MUTATION uncorrelated mapping scan: \(steps) VM steps at 100/1000 mappings")
    }
}

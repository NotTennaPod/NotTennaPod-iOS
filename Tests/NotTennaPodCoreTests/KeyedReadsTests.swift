import Foundation
import Testing
@testable import NotTennaPodCore

/// Routine non-screen readers read keys: Remove all from Inbox, Clear history, file owners and the release
/// ledger touch only the rows they act on, and each equals the canonical path it replaces, byte for byte.
@Suite(.serialized)
struct KeyedReadsTests {
    typealias Preservation = CanonicalPreservationTests

    /// A rich library with NEW episodes in a subscribed and an archived podcast, and history entries that are zero and
    /// negative as well as dates.
    static func library() async throws -> (URL, FeedLibraryStore, [Int64]) {
        let (url, store, ids) = try await Preservation.richLibrary()
        let archived = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/archived.xml", title: "Archived", count: 5),
                                              options: .init(now: EpisodeListKeysTests.now))
        try await store.updatePreferences(feedID: archived.id) { $0.subscriptionState = .archived }
        for (offset, id) in (ids + archived.episodes.map(\.id)).enumerated() {
            try await store.updateEpisode(id: id) { episode in
                if offset % 3 == 1 { episode.userState.playState = .new }
                if offset % 5 == 2 { episode.userState.lastPlayedHistoryMilliseconds = offset % 2 == 0 ? 0 : -7 }
            }
        }
        return (url, store, ids + archived.episodes.map(\.id))
    }

    /// Remove all from Inbox and Clear history change exactly what they intend (each edited record from its pre-action
    /// bytes), on the keyed path and on the canonical one, with the same result in the same order, and the keyed path
    /// decodes only the episodes it changes.
    @Test(arguments: [true, false])
    func bulkClearsChangeOnlyWhatTheyIntend(keyed: Bool) async throws {
        let (url, store, ids) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await store.setKeyedReadsForTesting(keyed)
        let before = try await store.snapshot()
        let episodes = before.feeds.flatMap(\.episodes)
        let new = episodes.filter { $0.userState.playState == .new }.map(\.id)
        let history = episodes.filter { $0.userState.lastPlayedHistoryMilliseconds != nil }.map(\.id)
        #expect(new.count >= 4 && history.count >= 6 && ids.count == 17)
        // In a feed-by-feed read's order: feed ID, then the feed's stored order.
        let order = before.feeds.sorted { $0.id < $1.id }.flatMap { $0.episodes.map(\.id) }

        var inbox = Preservation.Intent()
        for id in new { inbox.edit(id) { $0.userState.playState = .unplayed } }
        inbox.appended = ["pending_effects", "synchronization_outbox"]
        var snapshot = try Preservation.Snapshot.take(url)
        var decoded = await store.episodeRecordsDecoded
        let dismissed = try await store.removeAllFromInbox()
        let inboxDecoded = await store.episodeRecordsDecoded - decoded
        #expect(try Preservation.check(snapshot, inbox, Preservation.Snapshot.take(url)).found == [])
        #expect(dismissed == order.filter(new.contains))

        var clear = Preservation.Intent()
        for id in history { clear.edit(id) { $0.userState.lastPlayedHistoryMilliseconds = nil } }
        clear.appended = ["pending_effects", "synchronization_outbox"]
        clear.tables["statistics_units"] = { rows, _ in
            for id in rows.values("episode_id") { rows.update(where: "episode_id", is: id) { $0["history"] = .null } }
        }
        snapshot = try Preservation.Snapshot.take(url)
        decoded = await store.episodeRecordsDecoded
        let cleared = try await store.clearPlaybackHistory()
        let clearDecoded = await store.episodeRecordsDecoded - decoded
        #expect(try Preservation.check(snapshot, clear, Preservation.Snapshot.take(url)).found == [])
        #expect(cleared == order.filter(history.contains))
        if keyed {
            // Each changed episode is read once (and once more by its own write's capture, when it has one).
            #expect(inboxDecoded <= 2 * new.count && clearDecoded <= 2 * history.count, "\(inboxDecoded), \(clearDecoded)")
        } else {
            #expect(inboxDecoded >= episodes.count && clearDecoded >= episodes.count)
        }
        #expect(try DerivedDataOracle.mismatches(url) == [])
        try await store.close()
    }

    /// The keyed bulk clears read only the rows they change: flat in the rest of the library.
    @Test func bulkClearsAreFlatInTheRestOfTheLibrary() async throws {
        var work: [Int: (Int, Int64)] = [:]
        for size in [200, 2_000] {
            let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: size, feeds: 10)
            // Exactly five NEW episodes, whatever the size (a raw edit: the library's own triggers keep the derived keys).
            try RawLibrary.execute(url, "UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '$.userState.playState', 0) AS BLOB) WHERE json_extract(CAST(record AS TEXT), '$.userState.playState') = -1")
            let reopened = try FeedLibraryStore(url: url)
            try await reopened.waitForDerivedData()
            let ids = try RawLibrary.rows(url, "SELECT id FROM episodes ORDER BY id LIMIT 5").compactMap { $0[0].flatMap { Int64($0) } }
            for id in ids { try await reopened.updateEpisode(id: id) { $0.userState.playState = .new } }
            let before = await reopened.work
            let changed = try await reopened.removeAllFromInbox()
            let spent = await reopened.work - before
            #expect(changed.count == 5)
            work[size] = (spent.recordsDecoded, spent.steps)
            try await reopened.close()
        }
        let (small, large) = (try #require(work[200]), try #require(work[2_000]))
        print("KEYED remove all from inbox, 5 NEW: 200 episodes \(small), 2,000 episodes \(large)")
        #expect(large.0 == small.0, "decodes flat")
        #expect(large.1 <= small.1 * 11 / 10 + 200, "steps flat")
    }

    /// A file's owners are found by name and compared exactly: other spellings of its path and its transcript own it; an
    /// excluded or staged owner does not. Equal to the canonical scan in every case.
    @Test func fileOwnersByNameEqualTheCanonicalScan() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/files.xml", title: "Files", count: 9),
                                          options: .init(now: EpisodeListKeysTests.now))
        let ids = feed.episodes.map(\.id).sorted()
        let spellings = ["/media/show/a.mp3", "/media/./show/a.mp3", "/media//show/a.mp3", "/media/other/../show/a.mp3",
                         "/media/show/a.mp3/", "/media/show/a.mp3.transcript", "/media/show/b.mp3", "/elsewhere/a.mp3", "a.mp3"]
        for (id, path) in zip(ids, spellings) {
            try await store.updateEpisode(id: id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = path }
        }
        let files = ["/media/show/a.mp3", "/media/show/b.mp3", "/media/show/c.mp3", "/media/show/../show/a.mp3", "/elsewhere/a.mp3"].map(URL.init(fileURLWithPath:))
        for file in files {
            await store.setKeyedReadsForTesting(true)
            let keyed = try await store.fileReferencedForTesting(file)
            let owners = try await store.fileOwnersForTesting(file)
            await store.setKeyedReadsForTesting(false)
            let canonical = try await store.fileReferencedForTesting(file)
            #expect(keyed == canonical, "\(file.path)")
            // Every spelling that standardizes to the file (or its transcript) owns it.
            let expected = zip(ids, spellings).filter { _, path in
                let standard = URL(fileURLWithPath: path).standardizedFileURL.path, target = file.standardizedFileURL.path
                return standard == target || standard == target + ".transcript"
            }.map(\.0)
            #expect(owners == expected, "\(file.path): \(owners) vs \(expected)")
        }
        #expect(try await store.fileOwnersForTesting(URL(fileURLWithPath: "/media/show/a.mp3")).count == 6)
        try await store.close()
    }

    /// The owner lookup reads only the episodes named like the file: flat in the number of other downloaded episodes.
    @Test func fileOwnerLookupIsFlatInTheOtherOwners() async throws {
        var steps: [Int: Int64] = [:]
        for owners in [100, 1_000, 10_000] {
            let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: max(owners, 200) + 10, feeds: 10)
            // A raw edit: the library's own triggers keep the derived keys.
            try RawLibrary.execute(url, "UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '$.userState.isDownloaded', json('true'), '$.userState.localFileURL', '/media/f/' || id || '.mp3') AS BLOB) WHERE id IN (SELECT id FROM episodes ORDER BY id LIMIT \(owners))")
            let reopened = try FeedLibraryStore(url: url)
            try await reopened.waitForDerivedData()
            let before = await reopened.work
            let first = try #require(try RawLibrary.rows(url, "SELECT min(id) FROM episodes").first?.first ?? nil)
            #expect(try await reopened.fileReferencedForTesting(URL(fileURLWithPath: "/media/f/\(first).mp3")))
            #expect(try await !reopened.fileReferencedForTesting(URL(fileURLWithPath: "/media/f/none.mp3")))
            steps[owners] = (await reopened.work - before).steps
            #expect(try DerivedDataOracle.mismatches(url) == [])
            try await reopened.close()
        }
        print("KEYED file owner lookup steps by owners: \(steps.sorted { $0.key < $1.key })")
        let small = try #require(steps[100])
        for owners in [1_000, 10_000] { #expect(try #require(steps[owners]) <= small + 200, "\(owners) owners: \(steps)") }
    }

    /// The release ledger's reads after an exchange (candidates, notifications, finishing) are flat in the settled releases
    /// it keeps: each reads its own partial index.
    @Test func ledgerReadsAreFlatInSettledReleases() async throws {
        var steps: [Int: Int64] = [:]
        for settled in [1_000, 10_000, 54_000, 100_000] where settled <= 10_000 || ProcessInfo.processInfo.environment["NTP_SCALE"] == "1" {
            let fixture = try await ServerLibraryFixture(server: true)
            _ = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/ledger.xml", title: "Ledger", count: 4))
            try await fixture.store.executeForTesting("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(settled)) INSERT INTO ntp_ledger(generation_id, occurrence, entry_id, state, notified, record) SELECT 'g' || (i % 97), 'settled-' || i, NULL, 'done', 1, X'7B7D' FROM n")
            let before = await fixture.store.work
            _ = try await fixture.store.serverReleaseCandidates()
            _ = try await fixture.store.serverReleaseNotifications()
            try await fixture.store.finishServerReleases([1])
            steps[settled] = (await fixture.store.work - before).steps
            let plans = try await fixture.store.queryPlansForTesting([
                "SELECT l.rowid FROM ntp_ledger l WHERE l.state = 'pending'",
                "SELECT l.rowid FROM ntp_ledger l WHERE l.notified = 0"])
            #expect(plans[0].contains("ntp_ledger_pending") && plans[1].contains("ntp_ledger_unnotified"), "\(plans)")
            await fixture.close()
        }
        print("KEYED ledger reads after an exchange, steps by settled releases: \(steps.sorted { $0.key < $1.key })")
        let small = try #require(steps[1_000])
        for (settled, value) in steps { #expect(value <= small + 500, "\(settled) settled: \(steps)") }
    }
}

extension FeedLibraryStore {
    func setKeyedReadsForTesting(_ on: Bool) { keyedReadsEnabled = on }
    func fileReferencedForTesting(_ file: URL) throws -> Bool { try database.transaction(write: false) { try serverFileReferences(file) } }
    func fileOwnersForTesting(_ file: URL) throws -> [Int64] { try database.transaction(write: false) { try fileOwners(of: [file]).map(\.id) } }
    func queryPlansForTesting(_ statements: [String]) throws -> [String] {
        try statements.map { sql in try database.rows("EXPLAIN QUERY PLAN " + sql).map { $0.last?.text ?? "" }.joined(separator: "; ") }
    }
}

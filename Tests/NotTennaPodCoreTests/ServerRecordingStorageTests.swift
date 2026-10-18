import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

/// Schema 19 and the recorder's storage (PROTOCOL §15.4).
@MainActor struct ServerRecordingStorageTests {
    @Test func aSchema18LibraryMigratesWithItsDataAndEmptyServerTables() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        defer { Task { await fixture.close() } }
        let feed = try await fixture.store.insert(ServerLibraryFixture.fetched())
        _ = try await fixture.store.enqueue(feed.episodes.map(\.id))
        try await fixture.store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true)
        try await fixture.store.close()
        // Back to schema 18: no ntp_* tables or triggers, the schema-11 credential trigger.
        let names = try fixture.rows("SELECT type, name FROM sqlite_master WHERE name LIKE 'ntp_%'")
        try sql(fixture.url, names.filter { $0[0] == "trigger" }.map { "DROP TRIGGER \($0[1]!)" }
                + names.filter { $0[0] == "table" }.map { "DROP TABLE \($0[1]!)" }
                + ["DROP TRIGGER retire_feed_credential",
                   "CREATE TRIGGER retire_feed_credential AFTER DELETE ON feed_credentials BEGIN INSERT OR IGNORE INTO feed_credential_cleanup VALUES (OLD.credential_id); END",
                   "PRAGMA user_version = 18"])
        let before = try fixture.libraryRows()
        let reopened = try FeedLibraryStore(url: fixture.url)
        // Schema 19, then schema 20's library tables (PROTOCOL §15.2), then schema 21's derived tables.
        #expect(try fixture.rows("PRAGMA user_version") == [["22"]])
        #expect(try fixture.rows("PRAGMA application_id") == [["1095782212"]])
        // A schema-19 library made before the owed table existed gets it at open, without other changes.
        try await reopened.close()
        try sql(fixture.url, ["DROP TABLE ntp_owed"])
        let schema = try fixture.rows("SELECT name, sql FROM sqlite_master ORDER BY name")
        let again = try FeedLibraryStore(url: fixture.url)
        #expect(try fixture.rows("SELECT name, sql FROM sqlite_master ORDER BY name").filter { $0[0] != "ntp_owed" && $0[0] != "sqlite_autoindex_ntp_owed_1" } == schema)
        try await again.close()
        let reopenedAgain = try FeedLibraryStore(url: fixture.url)
        #expect(try fixture.libraryRows() == before)
        let tables = try fixture.serverTables()
        // Schema 19's tables and the two hidden-row tables schema 21's derived triggers read in every library.
        #expect(tables.count == 21)
        #expect(tables.values.allSatisfy { $0.isEmpty })
        #expect(await reopenedAgain.isServerLibrary == false)
        // Standalone behaviour is unchanged: the credential trigger still retires a replaced credential.
        let vault = MemoryCredentialVault()
        let authentication = FeedAuthentication(store: reopenedAgain, vault: vault)
        try await authentication.save(.init(username: "a", password: "b"), feedID: feed.id)
        let first = try #require(try await reopenedAgain.feedCredentialID(feedID: feed.id))
        try await authentication.save(.init(username: "c", password: "d"), feedID: feed.id)
        #expect(!vault.contains(first))
        try await reopenedAgain.close()
    }

    private func sql(_ url: URL, _ statements: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw FeedLibraryError.invalidLocation }
        defer { sqlite3_close(db) }
        for statement in statements {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
                throw FeedLibraryError.sqlite(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    @Test func theAndroidExportOfAServerLibraryHasNoServerTables() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let registered = try await fixture.subscribeRegistered()
        _ = try await fixture.store.enqueue(registered.feed.episodes.map(\.id))
        _ = try await fixture.store.insert(ServerLibraryFixture.fetched("https://example.test/pending.xml", title: "Pending"))
        #expect(try fixture.rows("SELECT count(*) FROM ntp_registrations") == [["2"]])
        #expect(try fixture.rows("SELECT count(*) FROM ntp_local_items") != [["0"]], "the episodes' identities")
        let data = try await AndroidDatabaseBackup.data(library: fixture.store, speeds: .init()) { _ in nil }
        let file = fixture.directory.appendingPathComponent("export.db")
        try data.write(to: file)
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw FeedLibraryError.invalidLocation }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE name LIKE 'ntp%'", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 0)
    }

    @Test func theMainAuthorAndTransportSlotsSurviveARelaunch() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let registered = try await fixture.subscribeRegistered()
        try await fixture.store.close()
        let reopened = try FeedLibraryStore(url: fixture.url)
        try await reopened.setFavorite(episodeID: registered.feed.episodes[0].id, favorite: true)
        let facts = try fixture.outbox()
        #expect(facts.map(\.installSeq) == [1, 2])
        #expect(facts[1].json["author_id"]?.stringValue == fixture.identity.installID)
        #expect(facts[1].json["author_seq"] == 2)
        #expect(facts[1].json["previous_op_id"]?.stringValue == facts[0].opID)
        // The frontier is the main author's tip.
        #expect(try fixture.rows("SELECT node_id FROM ntp_nodes WHERE frontier = 1") == [[facts[1].opID]])
        // Content hash over the canonical bytes.
        let bytes = try facts[1].json.canonicalBytes()
        #expect(try fixture.rows("SELECT content_hash FROM ntp_outbox WHERE install_seq = 2") == [[ContractIdentity.sha256Hex(bytes)]])
        try await reopened.close()
    }

    @Test func bulkMemberListsSplitAtFiveHundred() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 501))
        for episode in registered.feed.episodes { try await fixture.store.projectForTesting(episode.id) { $0.userState.playState = .new } }
        let before = try fixture.outboxCount()
        try await fixture.store.removeAllFromInbox()
        let facts = try fixture.newFacts(after: before)
        #expect(facts.map(\.type) == ["inbox.dismiss_all", "inbox.dismiss_all"])
        #expect(facts.map(\.episodeIDs.count) == [500, 1])
        #expect(facts[1].json["previous_op_id"]?.stringValue == facts[0].opID)
        let all = facts.flatMap(\.episodeIDs)
        #expect(all == all.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    }

    @Test func noCredentialsInAnyString() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        var fetched = ServerLibraryFixture.fetched("https://user:pw@private.example.test/feed.xml", title: "Private")
        var items = fetched.feed.episodes
        items[0] = ParsedEpisode(identifier: "https://u:p@guid.example.test/1", title: "See https://x:y@example.test/a",
                                 publicationDate: items[0].publicationDate, media: ParsedMedia(url: "https://m:n@media.example.test/1.mp3", size: 1, durationMilliseconds: 1))
        fetched = FetchedFeed(feed: ParsedFeed(format: .rss, title: "Private", episodes: items), source: fetched.source,
                              responseURL: fetched.responseURL, validator: nil, permanentRedirectURL: nil)
        let feed = try await fixture.store.insert(fetched)
        let op = try fixture.registrationOp(feedID: feed.id)
        let ids = try fixture.created(op)
        try await fixture.store.resolveRegistration(opID: op, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
        try await fixture.store.setFavorite(episodeID: try #require(feed.episodes.first { $0.details.title?.hasPrefix("See") == true }).id, favorite: true)
        for fact in try fixture.outbox() {
            let text = try fact.json.canonicalString()
            #expect(!text.contains("pw@") && !text.contains("p@") && !text.contains("y@") && !text.contains("n@"), "\(text)")
        }
        #expect(try fixture.outbox()[0].payload["feed_url"]?.stringValue == "https://private.example.test/feed.xml")
    }

    @Test func aServerLibraryMatchesFeedsOnlyByNormalizedURL() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        // The same podcast:guid-like identifier at two URLs: different feeds are different podcasts (PROTOCOL §3.3).
        func withIdentifier(_ url: String) -> FetchedFeed {
            let base = ServerLibraryFixture.fetched(url, title: "Same")
            var feed = base.feed; feed.identifier = "podcast-guid"
            return FetchedFeed(feed: feed, source: url, responseURL: base.responseURL, validator: nil, permanentRedirectURL: nil)
        }
        let one = try await store.insert(withIdentifier("https://example.test/a.xml"))
        let two = try await store.insert(withIdentifier("https://example.test/b.xml"))
        #expect(one.id != two.id)
        let again = try await store.insert(withIdentifier("HTTPS://EXAMPLE.test/a.xml"))
        #expect(again.id == one.id)
        // A standalone library keeps Android's identifying-value match.
        let standalone = try await ServerLibraryFixture(server: false)
        let first = try await standalone.store.insert(withIdentifier("https://example.test/a.xml"))
        #expect(try await standalone.store.insert(withIdentifier("https://example.test/b.xml")).id == first.id)
        await standalone.close()
    }

    @Test func theAccountPolicyBackingShowsAChangeAtOnceAndRecordsIt() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let backing = try await ServerAccountPolicyBacking.load(store: fixture.store)
        let policy = AccountPolicy(backing: backing)
        #expect(policy.newEpisodesAction == .inbox)
        try policy.setNewEpisodesAction(.nothing)
        try policy.setKeepSorted(true, order: .random)
        #expect(policy.newEpisodesAction == .nothing)
        #expect(policy.keepSorted == false)
        await backing.settle()
        #expect(try fixture.outbox().map(\.type) == ["account.set_discovery_policy", "account.set_queue_policy"])
        #expect(try await ServerAccountPolicyBacking.load(store: fixture.store).newEpisodesAction == .nothing)
        let standalone = try await ServerLibraryFixture(server: false)
        await #expect(throws: ServerRecordingError.notAServerLibrary) { _ = try await ServerAccountPolicyBacking.load(store: standalone.store) }
        await standalone.close()
    }
}

import Foundation
import Testing
@testable import NotTennaPodCore

/// Each derived-data mutation (trigger SQL replaced in the test's own library; production has no hooks) is caught by a
/// named witness: the whole-table oracle, the write budget, the byte-preservation oracle, or a write that fails. The
/// detection is printed (`MUTATION <id>: …`) as the recorded failing assertion.
@Suite(.serialized) struct DerivedDataMutationTests {
    static func trigger(_ name: String) -> String {
        (LibrarySchema21.keyTriggers + LibrarySchema21.visibilityTriggers + LibrarySchema21.countTriggers).first { $0.name == name }!.sql
    }

    /// Replaces trigger `name` in the library at `url` by its production SQL with `replacements` applied (each must match).
    static func mutate(_ url: URL, _ name: String, _ replacements: [(String, String)]) throws {
        var sql = trigger(name)
        for (from, to) in replacements {
            precondition(sql.contains(from), "\(name) has no \(from)")
            sql = sql.replacingOccurrences(of: from, with: to)
        }
        try RawLibrary.execute(url, "DROP TRIGGER \(name); \(sql);")
    }

    static func drop(_ url: URL, _ name: String) throws { try RawLibrary.execute(url, "DROP TRIGGER \(name);") }

    static func library() async throws -> (URL, FeedLibraryStore, LibraryFeed) {
        let directory = try EpisodeListKeysTests.directory()
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/m.xml", count: 12), options: .init(now: EpisodeListKeysTests.now))
        return (url, store, feed)
    }

    /// The oracle's verdict: its mismatches, or the error it could not read the derived data past.
    static func detected(_ id: String, _ url: URL) -> Bool {
        do {
            let found = try DerivedDataOracle.mismatches(url, limit: 1)
            if !found.isEmpty { print("MUTATION \(id): oracle: \(found[0].prefix(400))") }
            return !found.isEmpty
        } catch {
            print("MUTATION \(id): oracle could not read the derived data: \(error)")
            return true
        }
    }

    static func finish(_ url: URL, _ store: FeedLibraryStore) async {
        try? await store.close()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func k1RecordMissingFromTheUpdateTriggerLeavesAPositionStale() async throws {
        let (url, store, feed) = try await Self.library()
        try Self.mutate(url, "derived_keys_update", [("AFTER UPDATE OF id, feed_id, record ON episodes", "AFTER UPDATE OF id, feed_id ON episodes")])
        try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.positionMilliseconds = 4_321 }
        #expect(Self.detected("K1", url))
        await Self.finish(url, store)
    }

    @Test func k2WithoutTheDeleteTriggerARemovedEpisodeKeepsItsRow() async throws {
        let (url, store, feed) = try await Self.library()
        try Self.drop(url, "derived_keys_delete")
        var removing = FeedRefreshOptions(now: EpisodeListKeysTests.now)
        removing.removeUnlistedItems = true
        _ = try await store.applyRefresh(EpisodeListKeysTests.fetched("https://example.test/m.xml", count: 12, removing: [3]), feedID: feed.id, options: removing)
        #expect(Self.detected("K2", url))
        await Self.finish(url, store)
    }

    static let roundedDate = LibrarySchema21.derivedColumns.first { $0.name == "pub_ms" }!.sql
    static let rawDate = "((json_extract(r, '$.details.publicationDate') + 978307200.0) * 1000.0)"

    /// Truncation is caught on dates exactly half a millisecond past (both sides of 1970). SQLite's `round()` differs from
    /// Swift's only for |x| < 0.5 ms, which no stored date reaches (`t + 978307200` has a granularity of 2^-23 s there):
    /// that variant survives every reachable input, as recorded.
    @Test func k3PublicationMillisecondsRoundedAnotherWay() async throws {
        for (variant, expression, caught) in [("K3 truncation", "CAST(\(Self.rawDate) AS INTEGER)", true), ("K3 round()", "CAST(round(\(Self.rawDate)) AS INTEGER)", false)] {
            let (url, store, feed) = try await Self.library()
            for name in ["derived_keys_insert", "derived_keys_update"] { try Self.mutate(url, name, [(Self.roundedDate, expression)]) }
            var generator = EpisodeListKeysRandomTests.Generator()
            var statements: [(String, [LibrarySQLValue])] = [("BEGIN", [])]
            for index in 0..<400 {
                var episode = feed.episodes[0]
                episode.id = 600_000 + Int64(index)
                episode.details.publicationDate = Date(timeIntervalSinceReferenceDate: index.isMultiple(of: 2) ? generator.halfMillisecond()
                    : -978_307_200 + Double(index) * 0.000_000_119_209_29)
                statements.append(("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 0, ?)", [.integer(episode.id), .integer(feed.id), .blob(try DerivedDataOracle.record(episode))]))
            }
            statements.append(("COMMIT", []))
            try DerivedDataOracle.write(url, statements)
            let found = Self.detected(variant, url)
            #expect(found == caught, "\(variant)")
            if !found { print("MUTATION \(variant): survives (equivalent on every reachable stored date)") }
            await Self.finish(url, store)
        }
    }

    @Test func k4ACountsSignErrorOnFavoritesDrifts() async throws {
        let (url, store, feed) = try await Self.library()
        try Self.mutate(url, "derived_counts_update", [("favorite = favorite + (NEW.hidden = 0 AND NEW.favorite = 1) - (OLD.hidden = 0 AND OLD.favorite = 1)",
                                                        "favorite = favorite - (NEW.hidden = 0 AND NEW.favorite = 1) + (OLD.hidden = 0 AND OLD.favorite = 1)")])
        try await store.setFavorite(episodeID: feed.episodes[0].id, favorite: true)
        #expect(Self.detected("K4", url))
        await Self.finish(url, store)
    }

    @Test func k5AMoveThatDoesNotDecrementTheOldFeedDrifts() async throws {
        let (url, store, feed) = try await Self.library()
        let other = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/o.xml", title: "O", count: 2), options: .init(now: EpisodeListKeysTests.now))
        let sql = Self.trigger("derived_counts_update")
        let start = try #require(sql.range(of: "UPDATE feed_list_counts SET total = total - (OLD.hidden = 0)"))
        let end = try #require(sql.range(of: "OLD.feed_id IS NOT NEW.feed_id;", range: start.upperBound..<sql.endIndex))
        try Self.mutate(url, "derived_counts_update", [(String(sql[start.lowerBound..<end.upperBound]), "")])
        try DerivedDataOracle.write(url, "UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(other.id), .integer(feed.episodes[0].id)])
        #expect(Self.detected("K5", url))
        await Self.finish(url, store)
    }

    @Test func k6WithoutTheJSONGuardAMalformedRecordBlocksTheWrite() async throws {
        let (url, store, feed) = try await Self.library()
        try Self.mutate(url, "derived_keys_update", [(LibrarySchema21.recordText("NEW.record"), "CAST(NEW.record AS TEXT)")])
        do {
            try DerivedDataOracle.write(url, "UPDATE episodes SET record = CAST('{broken' AS BLOB) WHERE id = ?", [.integer(feed.episodes[0].id)])
            Issue.record("K6 survived: the malformed write committed")
        } catch {
            print("MUTATION K6: the write failed: \(error)")
        }
        await Self.finish(url, store)
    }

    @Test func k7DownloadDateReadFromAnotherPath() async throws {
        let (url, store, feed) = try await Self.library()
        for name in ["derived_keys_insert", "derived_keys_update"] { try Self.mutate(url, name, [("'$.userState.downloadDate'", "'$.userState.downloaded'")]) }
        try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.isDownloaded = true; $0.userState.downloadDate = EpisodeListKeysTests.now }
        #expect(Self.detected("K7", url))
        await Self.finish(url, store)
    }

    @Test func k8CountsWithoutTheHiddenCorrectionCountAStagedEpisode() async throws {
        let (url, store, feed) = try await Self.library()
        try Self.mutate(url, "derived_counts_insert", [(" WHEN NEW.hidden = 0 AND ", " WHEN "), ("(NEW.hidden = 0)", "(1)"), ("NEW.hidden = 0 AND ", "")])
        try Self.insertStaged(url, feed: feed)
        #expect(Self.detected("K8", url))
        await Self.finish(url, store)
    }

    static func insertStaged(_ url: URL, feed: LibraryFeed, id: Int64 = 650_001) throws {
        var staged = feed.episodes[0]
        staged.id = id; staged.details.identifier = "staged"; staged.userState.playState = .new
        try DerivedDataOracle.write(url, [("BEGIN", []), ("INSERT INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (?, ?)", [.integer(id), .integer(feed.id)]),
                                          ("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 0, ?)", [.integer(id), .integer(feed.id), .blob(try DerivedDataOracle.record(staged))]),
                                          ("COMMIT", [])])
    }

    // MARK: - Visibility, eligibility, media, history and count triggers

    @Test func hiddenMarkerAfterItsRowWithoutTheMarkerTrigger() async throws {
        let (url, store, feed) = try await Self.library()
        try Self.drop(url, "derived_hidden_insert")
        try DerivedDataOracle.write(url, "INSERT INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (?, ?)", [.integer(feed.episodes[0].id), .integer(feed.id)])
        #expect(Self.detected("H1 marker trigger dropped", url))
        await Self.finish(url, store)
    }

    @Test func hiddenMarkerBeforeItsRowIgnoredByTheInsert() async throws {
        let (url, store, feed) = try await Self.library()
        try Self.mutate(url, "derived_keys_insert", [(LibrarySchema21.hiddenSQL("NEW.id"), "0")])
        try Self.insertStaged(url, feed: feed)
        #expect(Self.detected("H2 insert ignores markers", url))
        await Self.finish(url, store)
    }

    @Test func eligibilityWithoutTheSubscriptionTrigger() async throws {
        let (url, store, feed) = try await Self.library()
        try Self.drop(url, "derived_eligible_feed_update")
        try await store.updatePreferences(feedID: feed.id) { $0.subscriptionState = .archived }
        #expect(Self.detected("E1 subscription trigger dropped", url))
        await Self.finish(url, store)
    }

    @Test func eligibilityWithoutThePodcastInsertTrigger() async throws {
        let (url, store, feed) = try await Self.library()
        try Self.drop(url, "derived_eligible_podcast_insert")
        try DerivedDataOracle.write(url, "INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES ('p', ?, 1)", [.integer(feed.id)])
        #expect(Self.detected("E2 podcast insert trigger dropped", url))
        await Self.finish(url, store)
    }

    @Test func eligibilityNotRecomputedOnAParentChange() async throws {
        let (url, store, feed) = try await Self.library()
        let archived = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/x.xml", title: "X", count: 1), options: .init(now: EpisodeListKeysTests.now))
        try await store.updatePreferences(feedID: archived.id) { $0.subscriptionState = .archived }
        try Self.mutate(url, "derived_keys_update", [("feed_eligible = CASE WHEN episode_list_keys.feed_id IS d.feed_id THEN episode_list_keys.feed_eligible ELSE "
                                                      + LibrarySchema21.eligibleSQL("d.feed_id") + " END", "feed_eligible = episode_list_keys.feed_eligible")])
        try DerivedDataOracle.write(url, "UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(archived.id), .integer(feed.episodes[0].id)])
        #expect(Self.detected("E3 parent change keeps eligibility", url))
        await Self.finish(url, store)
    }

    @Test func hasMediaNotCoalesced() async throws {
        let (url, store, feed) = try await Self.library()
        for name in ["derived_keys_insert", "derived_keys_update"] {
            try Self.mutate(url, name, [("coalesce(json_type(r, '$.details.media') = 'object', 0)", "json_type(r, '$.details.media') = 'object'")])
        }
        let medialess = try #require(feed.episodes.first { $0.details.media == nil })
        try await store.updateEpisode(id: medialess.id) { $0.userState.isDownloaded = true; $0.details.title = "Changed" }
        try DerivedDataOracle.write(url, "DELETE FROM episodes WHERE id = ?", [.integer(medialess.id)])
        try DerivedDataOracle.write(url, "INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 0, ?)",
                                    [.integer(medialess.id), .integer(feed.id), .blob(try DerivedDataOracle.record(medialess))])
        #expect(Self.detected("has_media NULL", url))
        await Self.finish(url, store)
    }

    @Test func historyPresenceLost() async throws {
        let (url, store, feed) = try await Self.library()
        for name in ["derived_keys_insert", "derived_keys_update"] {
            try Self.mutate(url, name, [("json_extract(r, '$.userState.lastPlayedHistoryMilliseconds')", "coalesce(json_extract(r, '$.userState.lastPlayedHistoryMilliseconds'), 0)")])
        }
        try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.positionMilliseconds = 1 }
        #expect(Self.detected("history presence coalesced to 0", url))
        await Self.finish(url, store)
    }

    /// One statement setting state, favorite, download and history (the earlier group (b)): a real listening
    /// checkpoint then maintains the state, favorite and download indexes too, over the honest budget.
    @Test func stateAndHistoryInOneGroupBreaksTheCheckpointBudget() async throws {
        let (url, store, feed) = try await Self.library()
        let state = LibrarySchema21.updateGroup(["state", "favorite", "downloaded"]), history = LibrarySchema21.updateGroup(["history_ms", "last_played_ms"])
        try Self.mutate(url, "derived_keys_update", [(state, ""), (history, LibrarySchema21.updateGroup(["state", "favorite", "downloaded", "history_ms", "last_played_ms"]))])
        let id = try #require(feed.episodes.first { $0.details.media != nil }?.id)
        let session = try await store.beginPlayback(episodeID: id)
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 1_000, durationMilliseconds: 90_000, status: .playing), now: EpisodeListKeysTests.now)
        try await DerivedWriteBudgetTests.install(store)
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 6_000, durationMilliseconds: 90_000, status: .playing),
                                           now: EpisodeListKeysTests.now.addingTimeInterval(5))
        let log = try await DerivedWriteBudgetTests.take(store)
        #expect(log.indexOperations > 6, "\(log)")
        print("MUTATION merged state and history group: checkpoint index operations \(log.indexOperations) > 6")
        await Self.finish(url, store)
    }

    @Test func countsWithoutTheirGuardWriteOnEveryMetadataChange() async throws {
        let (url, store, feed) = try await Self.library()
        let sql = Self.trigger("derived_counts_update")
        let start = try #require(sql.range(of: " WHEN ")), end = try #require(sql.range(of: " BEGIN "))
        try Self.mutate(url, "derived_counts_update", [(String(sql[start.lowerBound..<end.lowerBound]), "")])
        try await DerivedWriteBudgetTests.install(store)
        try await store.updateEpisode(id: feed.episodes[0].id) { $0.details.media?.durationMilliseconds = 1 }
        let log = try await DerivedWriteBudgetTests.take(store)
        #expect(log.countWrites > 0, "\(log)")
        print("MUTATION counts guard removed: a duration correction wrote \(log.countWrites) counts rows")
        await Self.finish(url, store)
    }

    @Test func detailsGenerationOnEveryWrite() async throws {
        let (url, store, feed) = try await Self.library()
        let sql = Self.trigger("derived_details_update")
        let start = try #require(sql.range(of: " WHEN ")), end = try #require(sql.range(of: " BEGIN "))
        try Self.mutate(url, "derived_details_update", [(String(sql[start.lowerBound..<end.lowerBound]), " WHEN 1")])
        let before = try RawLibrary.rows(url, "SELECT details_generation FROM feed_changes WHERE feed_id = \(feed.id)")
        try await store.setFavorite(episodeID: feed.episodes[0].id, favorite: true)
        let after = try RawLibrary.rows(url, "SELECT details_generation FROM feed_changes WHERE feed_id = \(feed.id)")
        #expect(before != after)
        print("MUTATION details guard removed: a favorite moved details_generation \(before) → \(after)")
        await Self.finish(url, store)
    }

    /// A derived trigger that writes canonical data (notes taken out of records) during the fill: the byte-preservation
    /// oracle catches it.
    @Test func aTriggerWritingCanonicalDataIsCaughtByTheByteOracle() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await EpisodeListKeysTests.restoredLibrary(in: directory)
        try DerivedDataOracle.downgradeTo20(url)
        let before = try DerivedDataOracle.canonicalHashes(url)
        let store = try FeedLibraryStore(url: url)
        try RawLibrary.execute(url, "CREATE TRIGGER rogue AFTER INSERT ON episode_list_keys BEGIN UPDATE episodes SET record = CAST(json_remove(CAST(record AS TEXT), '$.details.description') AS BLOB) WHERE id = NEW.id; END")
        try await store.fillDerivedData()
        let changes = DerivedDataOracle.byteChanges(before: before, after: try DerivedDataOracle.canonicalHashes(url))
        #expect(changes.contains("episodes changed"), "\(changes)")
        print("MUTATION canonical write: byte oracle: \(changes)")
        try await store.close()
    }
    /// A change to SQLite's AUTOINCREMENT high-water marks alone (canonical allocation state) is caught by the byte oracle.
    @Test func theByteOracleCatchesAnAllocationStateChange() async throws {
        let (url, store, _) = try await Self.library()
        try await store.close()
        try RawLibrary.execute(url, "INSERT INTO pending_effects(kind, record) VALUES ('x', X'00'); DELETE FROM pending_effects WHERE kind = 'x'")
        let before = try DerivedDataOracle.canonicalHashes(url)
        try RawLibrary.execute(url, "UPDATE sqlite_sequence SET seq = 9000 WHERE name = 'pending_effects'")
        let changes = DerivedDataOracle.byteChanges(before: before, after: try DerivedDataOracle.canonicalHashes(url))
        #expect(changes == ["sqlite_sequence changed"], "\(changes)")
        print("MUTATION AUTOINCREMENT high-water mark: byte oracle: \(changes)")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

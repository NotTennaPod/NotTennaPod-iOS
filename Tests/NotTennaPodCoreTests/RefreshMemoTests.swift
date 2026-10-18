import Foundation
import Testing
@testable import NotTennaPodCore

/// A refresh identical to its feed's last applied one decodes no stored episode and writes only what the
/// full merge would have written. Differential byte tests: the same steps on two copies of one library, one with the
/// refresh memo and one without (every refresh merged, as before); after every step every table of both is equal row by
/// row (the memo table itself aside), random identifiers normalized, with a fixed clock. Each step also says whether the
/// memo library must apply it as unchanged (a hit) or merge it (a miss).
@Suite(.serialized)
struct RefreshMemoTests {
    typealias Item = RefreshSharedReadsDifferentialTests.Item

    static let source = "https://example.test/feed.xml"

    static func items(_ count: Int, prefix: String = "guid-", host: String = "media.example.test") -> [Item] {
        (0..<count).map { Item(guid: "\(prefix)\($0)", title: "Episode \(prefix)\($0)", description: "About \($0)", day: Double($0),
                               url: "https://\(host)/\(prefix)\($0).mp3") }
    }

    static func feed(_ items: [Item], source: String = source, title: String = "Show") -> FetchedFeed {
        let episodes = items.map {
            ParsedEpisode(identifier: $0.guid, title: $0.title, description: $0.description,
                          publicationDate: ServerLibraryFixture.now.addingTimeInterval($0.day * 86_400),
                          media: $0.url.map { ParsedMedia(url: $0, size: 1_000, durationMilliseconds: 600_000) })
        }
        var fetched = FetchedFeed(feed: ParsedFeed(format: .rss, title: title, episodes: episodes), source: source,
                                  responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
        fetched.catalog = ServerCatalogRecords.interim(fetched.feed)
        return fetched
    }

    /// A fixed clock: step `step`'s refresh time.
    static func options(_ step: Int) -> FeedRefreshOptions {
        FeedRefreshOptions(now: ServerLibraryFixture.now.addingTimeInterval(Double(30_000 + step) * 86_400), timeZone: .gmt)
    }

    // MARK: - The differential

    /// Two copies of one library: `memo` refreshes with the memo, `reference` merges every refresh.
    final class Pair: @unchecked Sendable {
        let base: ServerLibraryFixture, memo: ServerLibraryFixture, reference: ServerLibraryFixture
        var step = 0
        var hits: [String] = []

        init(_ base: ServerLibraryFixture) async throws {
            self.base = base
            memo = try await base.copy()
            reference = try await base.copy()
            await reference.store.setRefreshMemoEnabled(false)
        }

        func close() async { await memo.close(); await reference.close(); await base.close() }

        /// Runs `action` on both libraries, then requires them equal, every table row by row except the memo's own.
        func both(_ label: String, _ action: (ServerLibraryFixture) async throws -> Void) async throws {
            try await action(memo)
            try await action(reference)
            let left = try Self.rows(memo.url), right = try Self.rows(reference.url)
            #expect(left.count == right.count, "\(label): \(left.count) rows against \(right.count)")
            let differences = zip(left, right).filter { $0 != $1 }.prefix(5)
            #expect(differences.isEmpty, "\(label): \(differences.map { "\n- \($0)\n+ \($1)" }.joined())")
        }

        /// The dump without the memo table. Log and effect records are encoded with unordered keys (today's
        /// `appendLog`), so two equal records may differ in key order: they are compared as JSON values, keys sorted.
        static func rows(_ url: URL) throws -> [String] {
            let rows = try RefreshSharedReadsDifferentialTests.dump(url).filter { $0.table != "feed_refresh_memo" }.map { row in
                guard ["refresh_log", "pending_effects"].contains(row.table) else { return row }
                return RefreshSharedReadsDifferentialTests.Row(table: row.table, cells: row.cells.map { cell in
                    guard cell.column == "record", let object = try? JSONSerialization.jsonObject(with: Data(cell.value.utf8)),
                          let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return cell }
                    return (cell.column, String(decoding: sorted, as: UTF8.self))
                })
            }
            return RefreshSharedReadsDifferentialTests.normalized(rows)
        }

        /// A refresh of `fetched` on both, then what the refresh service does after it: a server library's listed
        /// observations recorded (with the parse after a merge, as after a 304 after a hit). `hit`: whether the memo
        /// library must apply it as unchanged; nil when either may be right.
        @discardableResult
        func refresh(_ label: String, _ fetched: FetchedFeed, feedID: Int64, options: FeedRefreshOptions? = nil, hit: Bool?) async throws -> Bool {
            step += 1
            let settings = options ?? RefreshMemoTests.options(step)
            let before = await memo.store.unchangedRefreshes
            var results: [FeedRefreshResult] = []
            try await both("step \(step) \(label)") { fixture in
                let result = try await fixture.store.applyRefresh(fetched, feedID: feedID, options: settings)
                results.append(result)
                if await fixture.store.isServerLibrary {
                    try await FeedLibraryStore.drainObservations(fixture.store, feedID: feedID, catalog: result.itemsUnchanged ? nil : fetched.catalog,
                                                                 items: result.serverItems)
                }
            }
            let applied = await memo.store.unchangedRefreshes - before == 1
            if let hit { #expect(applied == hit, "step \(step) \(label): \(hit ? "a hit" : "a merge") expected") }
            #expect(await reference.store.unchangedRefreshes == 0)
            // What the caller sees: the same header, filings, removals and duplicates; a hit carries no episodes.
            if results.count == 2 {
                var header = results[1].feed
                header.episodes = []
                #expect(results[0].feed.episodes.isEmpty == applied && results[0].itemsUnchanged == applied)
                var memoHeader = results[0].feed
                memoHeader.episodes = []
                #expect(memoHeader == header, "step \(step) \(label): header")
                #expect(results[0].queueEpisodeIDs == results[1].queueEpisodeIDs && results[0].removedEpisodes == results[1].removedEpisodes
                        && results[0].duplicates == results[1].duplicates && results[0].completedEpisodeSync == results[1].completedEpisodeSync)
            }
            if applied { hits.append(label) }
            return applied
        }

        /// Refreshes `fetched` until the memo library applies it as unchanged (a merge that changed nothing proves the
        /// memo, and a server library's observations may take one more), then once more, which must be a hit.
        func settle(_ label: String, _ fetched: FetchedFeed, feedID: Int64) async throws {
            var applied = false
            for attempt in 0..<4 where !applied {
                applied = try await refresh("\(label) (settling \(attempt))", fetched, feedID: feedID, hit: nil)
            }
            #expect(applied, "\(label): never applied as unchanged")
            try await refresh("\(label) (settled)", fetched, feedID: feedID, hit: true)
        }
    }

    /// Standalone: hits after user-state writes; misses for a parse change, a preference or option change, an episode
    /// deleted elsewhere (re-added as before), another page and unlisted removal; repeated items and episodes restored
    /// with a shared GUID (whose matches change with their order) always merge.
    @Test func aStandaloneHitWritesExactlyWhatTheMergeWrote() async throws {
        let base = try await ServerLibraryFixture(server: false)
        var items = Self.items(30)
        let feedID = try await base.store.insert(Self.feed(items), options: Self.options(0)).id
        // A feed restored with two episodes of one GUID (an Android backup may hold them).
        let twinSource = "https://example.test/twins.xml"
        var twins = Self.items(6, prefix: "t-")
        twins.append(Item(guid: "t-0", title: "Twin", description: "Twin", day: 0.5, url: "https://media.example.test/twin.mp3"))
        let twinsID = try await base.store.insert(Self.feed(twins, source: twinSource), options: Self.options(0)).id
        let pair = try await Pair(base)
        defer { Task { await pair.close() } }
        let first = try #require(try await base.store.feed(id: feedID)?.episodes.map(\.id).min())

        try await pair.refresh("first refresh", Self.feed(items), feedID: feedID, hit: false)
        try await pair.refresh("identical", Self.feed(items), feedID: feedID, hit: true)
        try await pair.both("playback save") { try await $0.store.updateEpisode(id: first) { $0.userState.positionMilliseconds = 30_000 } }
        try await pair.refresh("after a playback save", Self.feed(items), feedID: feedID, hit: true)
        try await pair.both("played") { try await $0.store.markEpisodePlayed(episodeID: first, played: true) }
        try await pair.refresh("after a played mark", Self.feed(items), feedID: feedID, hit: true)
        try await pair.both("favourite") { try await $0.store.setFavorite(episodeID: first, favorite: true) }
        try await pair.refresh("after a favourite", Self.feed(items), feedID: feedID, hit: true)

        items[4].title += " (edited)"
        try await pair.refresh("a parse change", Self.feed(items), feedID: feedID, hit: false)
        try await pair.settle("the changed parse", Self.feed(items), feedID: feedID)

        items.append(Item(guid: "guid-new", title: "New", description: "New", day: 40, url: "https://media.example.test/new.mp3"))
        try await pair.refresh("a new item", Self.feed(items), feedID: feedID, hit: false)
        try await pair.settle("with the new item", Self.feed(items), feedID: feedID)

        try await pair.both("preference") { try await $0.store.updatePreferences(feedID: feedID) { $0.newEpisodesAction = .queue } }
        try await pair.refresh("a preference change", Self.feed(items), feedID: feedID, hit: false)
        try await pair.settle("after the preference change", Self.feed(items), feedID: feedID)

        var global = Self.options(1_000)
        global.globalNewEpisodesAction = .nothing
        global.globalAutoDownload = true
        try await pair.refresh("a global option change", Self.feed(items), feedID: feedID, options: global, hit: false)

        try await pair.both("episode deleted elsewhere") { try await $0.store.executeForTesting("DELETE FROM episodes WHERE id = ?", [.integer(first)]) }
        try await pair.refresh("after an episode deletion", Self.feed(items), feedID: feedID, hit: false)
        try await pair.settle("with the episode re-added", Self.feed(items), feedID: feedID)

        var nextPage = Self.options(2_000)
        nextPage.pageNumber = 1
        try await pair.refresh("another page", Self.feed(items), feedID: feedID, options: nextPage, hit: false)
        try await pair.refresh("the first page after another", Self.feed(items), feedID: feedID, hit: false)
        try await pair.settle("the first page", Self.feed(items), feedID: feedID)

        var unlisted = Self.options(3_000)
        unlisted.removeUnlistedItems = true
        try await pair.refresh("removing unlisted items", Self.feed(items), feedID: feedID, options: unlisted, hit: false)

        // Repeated items: the duplicates are logged every time, as before.
        items.append(items[3])
        for attempt in 0..<3 { try await pair.refresh("a repeated item \(attempt)", Self.feed(items), feedID: feedID, hit: false) }
        items.removeLast()
        try await pair.settle("without the repeated item", Self.feed(items), feedID: feedID)

        // The restored twins, refreshed as listed and with their order swapped, each parse several times: always merged,
        // also when a merge of them changes nothing.
        for attempt in 0..<6 {
            if attempt == 3 { (twins[0].day, twins[6].day) = (twins[6].day, twins[0].day) }
            try await pair.refresh("restored twins \(attempt)", Self.feed(twins, source: twinSource), feedID: twinsID, hit: false)
        }
        #expect(pair.hits.count >= 12, "\(pair.hits)")
    }

    /// Server library: hits after user-state writes and after a projection of canonical podcast metadata between identical
    /// parses (the header keeps the canonical title, by the merge's own rule); misses for a canonical episode projection,
    /// an identity-rules change, a preference change, an episode deleted by sync, a staged (hidden) episode and a parse
    /// change; repeated items always merge.
    @Test func aServerHitWritesExactlyWhatTheMergeWrote() async throws {
        let base = try await ServerLibraryFixture()
        var items = Self.items(30)
        let registered = try await base.subscribeRegistered(Self.feed(items))
        try await base.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                               [.text(registered.podcast), .blob(try (["title": "Show"] as ContractJSON).canonicalData())])
        let pair = try await Pair(base)
        defer { Task { await pair.close() } }
        let feedID = registered.feed.id
        let ids = registered.feed.episodes.map(\.id).sorted()

        try await pair.settle("first refreshes", Self.feed(items), feedID: feedID)
        try await pair.both("played") { try await $0.store.markEpisodePlayed(episodeID: ids[0], played: true) }
        try await pair.refresh("after a played mark", Self.feed(items), feedID: feedID, hit: true)
        try await pair.both("favourite") { try await $0.store.setFavorite(episodeID: ids[1], favorite: true) }
        try await pair.refresh("after a favourite", Self.feed(items), feedID: feedID, hit: true)
        try await pair.both("position save") { fixture in
            try await fixture.store.executeForTesting("UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '$.userState.positionMilliseconds', 45000) AS BLOB) WHERE id = ?",
                                                      [.integer(ids[2])])
        }
        try await pair.refresh("after a position save", Self.feed(items), feedID: feedID, hit: true)

        // Canonical podcast metadata projected onto the header only, between identical parses.
        try await pair.both("canonical header projection") { fixture in
            try await fixture.store.executeForTesting("UPDATE ntp_records SET value = ? WHERE entity = 'podcast' AND id = ? AND field_group = 'metadata'",
                                                      [.blob(try (["title": "Canonical show"] as ContractJSON).canonicalData()), .text(registered.podcast)])
            try await fixture.store.executeForTesting("UPDATE feeds SET record = CAST(json_set(CAST(record AS TEXT), '$.metadata.title', 'Canonical show') AS BLOB), title = 'Canonical show' WHERE id = ?",
                                                      [.integer(feedID)])
        }
        try await pair.refresh("after a canonical header projection", Self.feed(items), feedID: feedID, hit: true)
        #expect(try await pair.memo.store.feedHeader(id: feedID)?.metadata.title == "Canonical show")

        // Canonical episode metadata projected (as a projection writes it).
        try await pair.both("canonical episode projection") { fixture in
            guard let wire = try fixture.wireID(ids[3]) else { Issue.record("no mapping"); return }
            try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', ?, 'metadata', ?, '[]')",
                                                      [.text(wire), .blob(try (["title": "Canonical"] as ContractJSON).canonicalData())])
            try await fixture.store.executeForTesting("UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '$.details.title', 'Canonical') AS BLOB) WHERE id = ?",
                                                      [.integer(ids[3])])
        }
        try await pair.refresh("after a canonical episode projection", Self.feed(items), feedID: feedID, hit: false)
        try await pair.settle("with canonical episode metadata", Self.feed(items), feedID: feedID)

        try await pair.both("identity rules") { fixture in
            try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'identity_rules', ?, '[]')",
                                                      [.text(registered.podcast), .blob(try (["disputed_enclosures": []] as ContractJSON).canonicalData())])
        }
        try await pair.refresh("an identity-rules change", Self.feed(items), feedID: feedID, hit: false)
        try await pair.settle("with the identity rules", Self.feed(items), feedID: feedID)

        try await pair.both("preference") { try await $0.store.updatePreferences(feedID: feedID) { $0.newEpisodesAction = .nothing } }
        try await pair.refresh("a preference change", Self.feed(items), feedID: feedID, hit: false)
        try await pair.settle("after the preference change", Self.feed(items), feedID: feedID)

        try await pair.both("episode deleted by sync") { try await $0.store.executeForTesting("DELETE FROM episodes WHERE id = ?", [.integer(ids[5])]) }
        try await pair.refresh("after an episode deletion", Self.feed(items), feedID: feedID, hit: false)
        try await pair.settle("with the episode re-added", Self.feed(items), feedID: feedID)

        items[7].description += " more"
        try await pair.refresh("a parse change", Self.feed(items), feedID: feedID, hit: false)
        try await pair.settle("the changed parse", Self.feed(items), feedID: feedID)

        items.append(items[9])
        for attempt in 0..<3 { try await pair.refresh("a repeated item \(attempt)", Self.feed(items), feedID: feedID, hit: false) }
        items.removeLast()
        try await pair.settle("without the repeated item", Self.feed(items), feedID: feedID)

        // A staged episode, hidden until its unit reveals it: the merge does not see it.
        try await pair.both("hidden") { try await $0.store.executeForTesting("INSERT INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (?, ?)", [.integer(ids[8]), .integer(feedID)]) }
        try await pair.refresh("with a hidden episode", Self.feed(items), feedID: feedID, hit: false)
        try await pair.refresh("with a hidden episode again", Self.feed(items), feedID: feedID, hit: nil)
        #expect(pair.hits.count >= 12, "\(pair.hits)")
    }

    /// Random server sequences: new, renamed, re-described, re-dated and re-hosted items, repeated and changed GUIDs,
    /// gained media, canonical metadata and marks between them; each parse refreshed three times.
    @Test(arguments: [5, 17, 29])
    func randomServerSequencesMatchTheMerge(seed: UInt64) async throws {
        var random = SeededRandom(seed: seed)
        var items = (0..<40).map { Item(guid: "guid-\($0)", title: "Episode \($0)", description: "About \($0)", day: Double($0),
                                        url: $0 % 7 == 3 ? nil : "https://media.example.test/\($0).mp3") }
        let base = try await ServerLibraryFixture()
        let registered = try await base.subscribeRegistered(Self.feed(items))
        try await base.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                               [.text(registered.podcast), .blob(try (["title": "Show"] as ContractJSON).canonicalData())])
        let pair = try await Pair(base)
        defer { Task { await pair.close() } }
        let feedID = registered.feed.id
        var next = 40
        func any() -> Int { 2 + Int(random.next() % UInt64(items.count - 2)) }
        for step in 0..<12 {
            switch random.next() % 9 {
            case 0: items.append(Item(guid: "guid-\(next)", title: "Episode \(next)", description: "New \(next)", day: Double(next),
                                      url: "https://media.example.test/\(next).mp3")); next += 1
            case 1: items[any()].title += " (edited)"
            case 2: items[any()].description += " more"
            case 3: let i = any(); if items[i].url != nil { items[i].url = "https://other.example.test/\(i)-\(step).mp3" }
            case 4: items.append(items[any()])
            case 5: items[any()].guid += "-changed"
            case 6: if let i = items.indices.first(where: { $0 >= 2 && items[$0].url == nil }) { items[i].url = "https://media.example.test/gained-\(i).mp3" }
            case 7:
                let local = try #require(try await pair.memo.store.feed(id: feedID)?.episodes.map(\.id).min())
                try await pair.both("mark") { try await $0.store.markEpisodePlayed(episodeID: local, played: step % 2 == 0) }
            default: items[any()].day += 0.5
            }
            for attempt in 0..<3 {
                try await pair.refresh("step \(step) refresh \(attempt)", Self.feed(items), feedID: feedID, hit: nil)
            }
        }
        #expect(!pair.hits.isEmpty)
    }

    /// The memo goes with any write to a server table the merge or its observation reads per episode, and stays through
    /// user-state writes and a canonical value that changes without appearing or going.
    @Test func serverTableWritesRetireTheMemo() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let items = Self.items(10)
        let registered = try await fixture.subscribeRegistered(Self.feed(items))
        // Its first canonical metadata arrived: its observations no longer wait (they are listed again by every refresh
        // until then, so the memo is retired each time).
        try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                                  [.text(registered.podcast), .blob(try (["title": "Show"] as ContractJSON).canonicalData())])
        let feedID = registered.feed.id
        let ids = registered.feed.episodes.map(\.id).sorted()
        var step = 0
        func memo() throws -> Bool { try fixture.rows("SELECT count(*) FROM feed_refresh_memo WHERE feed_id = \(feedID) AND parse_digest IS NOT NULL")[0][0] == "1" }
        func settle() async throws {
            for _ in 0..<4 where try !memo() {
                step += 1
                _ = try await fixture.store.applyRefresh(Self.feed(items), feedID: feedID, options: Self.options(step))
            }
            #expect(try memo())
        }
        func expect(_ label: String, retired: Bool, _ sql: String, _ values: [LibrarySQLValue] = []) async throws {
            try await settle()
            try await fixture.store.executeForTesting(sql, values)
            #expect(try memo() == !retired, "\(label)")
        }
        try await settle()
        let wire = try #require(try fixture.wireID(ids[0]))
        try await expect("an observed parse", retired: true, "UPDATE ntp_observed SET parse_hash = 'x' WHERE id = ?", [.text("local-episode:\(ids[0])")])
        try await expect("the podcast's observed parse", retired: true, "UPDATE ntp_observed SET parse_hash = 'x' WHERE id = ?", [.text("local-feed:\(feedID)")])
        try await expect("canonical episode metadata appearing", retired: true,
                         "INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', ?, 'metadata', ?, '[]')",
                         [.text(wire), .blob(try (["title": "Episode guid-0"] as ContractJSON).canonicalData())])
        try await expect("canonical episode metadata changing", retired: false,
                         "UPDATE ntp_records SET value = ? WHERE entity = 'episode' AND id = ? AND field_group = 'metadata'",
                         [.blob(try (["title": "Other"] as ContractJSON).canonicalData()), .text(wire)])
        try await expect("canonical episode metadata going", retired: true,
                         "DELETE FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = 'metadata'", [.text(wire)])
        try await expect("canonical play state", retired: false,
                         "INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', ?, 'play_state', ?, '[]')",
                         [.text(wire), .blob(try (["state": "played"] as ContractJSON).canonicalData())])
        try await expect("a mapping", retired: true, "UPDATE ntp_episodes SET occurrence = ? WHERE episode_id = ?",
                         [.blob(try (["guid": "guid-0"] as ContractJSON).canonicalData()), .text(wire)])
        try await expect("a local identity", retired: true, "UPDATE ntp_local_items SET guid = 'other' WHERE local_id = ?", [.integer(ids[1])])
        try await expect("a listed observation", retired: true,
                         "INSERT INTO ntp_observation_work(feed_id, local_id, batch_id, fetch_time, hash, fields) VALUES (?, ?, 'b', 0, 'h', x'7B7D')",
                         [.integer(feedID), .integer(ids[2])])
        try await fixture.store.executeForTesting("DELETE FROM ntp_observation_work")
        try await expect("a hidden episode", retired: true, "INSERT INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (?, ?)", [.integer(ids[3]), .integer(feedID)])
        try await fixture.store.executeForTesting("DELETE FROM ntp_hidden_episodes")
        try await settle()
        try await fixture.store.markEpisodePlayed(episodeID: ids[4], played: true)
        try await fixture.store.setFavorite(episodeID: ids[4], favorite: true)
        #expect(try memo(), "user state")
    }

    // MARK: - Budgets

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshMemo-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An unchanged refresh of a feed with 100, 1,000 or 4,234 episodes, on a library opened afresh (nothing decoded
    /// before): no episode record decoded, no derived row written, the header and its own log read only.
    @Test(arguments: [100, 1_000, 4_234])
    func anUnchangedRefreshDecodesNoStoredEpisode(episodes: Int) async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let items = Self.items(episodes)
        let store = try FeedLibraryStore(url: url)
        let feedID = try await store.insert(Self.feed(items), options: Self.options(0)).id
        _ = try await store.applyRefresh(Self.feed(items), feedID: feedID, options: Self.options(1))
        try await store.close()

        let fresh = try FeedLibraryStore(url: url)
        try await DerivedWriteBudgetTests.install(fresh)
        // The parse and its digest, made before the store is called, as the refresh service makes them.
        var fetched = Self.feed(items)
        fetched.parseDigest = FeedLibraryStore.refreshParseDigest(fetched)
        let before = await fresh.work, decodedBefore = await fresh.episodeRecordsDecoded
        let started = ContinuousClock.now
        let result = try await fresh.applyRefresh(fetched, feedID: feedID, options: Self.options(2))
        let elapsed = started.duration(to: .now)
        let work = await fresh.work - before
        let log = try await DerivedWriteBudgetTests.take(fresh)
        #expect(result.itemsUnchanged)
        #expect(await fresh.episodeRecordsDecoded - decodedBefore == 0, "\(work)")
        // The header (and the capture's own read of it) and the last log entry, whatever the feed's size.
        #expect(work.recordsDecoded <= 3, "\(work)")
        // Flat in the feed's size: the same statements and about the same VM steps at 100 and 4,234 episodes.
        #expect(work.statements <= 25 && work.steps <= 2_000, "\(work)")
        #expect(log.derivedWrites == 0 && log.detailsBumps == 0, "\(log)")
        print("Unchanged refresh budget: \(episodes) episodes: \(work), \(elapsed)")
        try await fresh.close()
    }

    /// The hourly refresh of 100 podcasts holding 50,000 episodes, on a library opened afresh: unchanged, it decodes no
    /// episode; with three podcasts changed, it decodes exactly those podcasts' episodes, once each.
    @Test func anHourlyRefreshOfAHundredFeedsDecodesOnlyTheChangedFeeds() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let sizes = (0..<100).map { 450 + ($0 * 37) % 201 }
        #expect(sizes.reduce(0, +) >= 50_000)
        func feed(_ index: Int, extra: Bool = false) -> FetchedFeed {
            var items = Self.items(sizes[index], prefix: "f\(index)-", host: "media\(index).example.test")
            if extra { items.append(Item(guid: "f\(index)-new", title: "New", description: "New", day: 9_999, url: "https://media\(index).example.test/new.mp3")) }
            var fetched = Self.feed(items, source: "https://example.test/\(index).xml", title: "Show \(index)")
            // Made outside the store, as the refresh service makes it.
            fetched.parseDigest = FeedLibraryStore.refreshParseDigest(fetched)
            return fetched
        }
        var store = try FeedLibraryStore(url: url)
        var feedIDs: [Int64] = []
        for index in sizes.indices { feedIDs.append(try await store.insert(feed(index), options: Self.options(0)).id) }
        for index in sizes.indices { _ = try await store.applyRefresh(feed(index), feedID: feedIDs[index], options: Self.options(1)) }
        try await store.close()

        store = try FeedLibraryStore(url: url)
        let parses = sizes.indices.map { feed($0) }
        var decoded = await store.episodeRecordsDecoded
        var started = ContinuousClock.now
        for index in sizes.indices { _ = try await store.applyRefresh(parses[index], feedID: feedIDs[index], options: Self.options(2)) }
        let unchanged = started.duration(to: .now)
        let unchangedDecoded = await store.episodeRecordsDecoded - decoded
        #expect(unchangedDecoded == 0)
        #expect(await store.unchangedRefreshes == 100)

        let changed: Set<Int> = [7, 42, 93]
        let next = sizes.indices.map { feed($0, extra: changed.contains($0)) }
        decoded = await store.episodeRecordsDecoded
        started = ContinuousClock.now
        for index in sizes.indices { _ = try await store.applyRefresh(next[index], feedID: feedIDs[index], options: Self.options(3)) }
        let withChanges = started.duration(to: .now)
        let expected = changed.map { sizes[$0] }.reduce(0, +)
        #expect(await store.episodeRecordsDecoded - decoded == expected)
        #expect(await store.unchangedRefreshes == 197)
        let changedDecoded = await store.episodeRecordsDecoded - decoded
        print("Unchanged refresh budget: 100 feeds, \(sizes.reduce(0, +)) episodes: unchanged refresh-all \(unchanged), \(unchangedDecoded) episodes decoded; 3 changed \(withChanges), \(changedDecoded) decoded (\(expected) in those feeds)")
        try await store.close()
    }

    /// A server library's unchanged refresh of a 1,000-episode podcast, on a library opened afresh, decodes no episode.
    @Test func aServerUnchangedRefreshDecodesNoStoredEpisode() async throws {
        let base = try await ServerLibraryFixture()
        let items = Self.items(1_000)
        let registered = try await base.subscribeRegistered(Self.feed(items))
        try await base.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                               [.text(registered.podcast), .blob(try (["title": "Show"] as ContractJSON).canonicalData())])
        for step in 1...3 {
            let result = try await base.store.applyRefresh(Self.feed(items), feedID: registered.feed.id, options: Self.options(step))
            try await FeedLibraryStore.drainObservations(base.store, feedID: registered.feed.id, catalog: Self.feed(items).catalog, items: result.serverItems)
        }
        let fresh = try await base.copy()
        defer { Task { await fresh.close(); await base.close() } }
        let decoded = await fresh.store.episodeRecordsDecoded
        let result = try await fresh.store.applyRefresh(Self.feed(items), feedID: registered.feed.id, options: Self.options(4))
        #expect(result.itemsUnchanged)
        #expect(await fresh.store.episodeRecordsDecoded - decoded == 0)
    }

    /// Through the refresh service (fetch, parse, digest, store): an unchanged refresh reads the feed's header only.
    @Test func theRefreshServiceReadsNoEpisodeOfAnUnchangedFeed() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let body = Data(("<rss version=\"2.0\"><channel><title>Podcast</title>" + (0..<200).map {
            "<item><guid>g\($0)</guid><title>Episode \($0)</title><pubDate>Mon, 01 Jan 2001 00:00:00 GMT</pubDate><enclosure url=\"https://example.test/\($0).mp3\" type=\"audio/mpeg\" length=\"1000\"/></item>"
        }.joined() + "</channel></rss>").utf8)
        let transport = MemoTestTransport { request in FeedHTTPResponse(url: request.url!, status: 200, headers: [:], body: body) }
        let source = "https://example.test/feed"
        var store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(FetchedFeed(feed: try FeedParser().parse(body, now: Self.options(0).now), source: source,
                                                      responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil),
                                          options: Self.options(0))
        for step in 1...2 {
            let options = Self.options(step)
            _ = try await FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport), clock: { options.now })
                .refresh(feedID: feed.id, options: options)
        }
        try await store.close()
        store = try FeedLibraryStore(url: url)
        let decoded = await store.episodeRecordsDecoded
        let options = Self.options(3)
        let outcome = try await FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport), clock: { options.now })
            .refresh(feedID: feed.id, options: options)
        guard case .updated(let result) = outcome else { Issue.record("\(outcome)"); return }
        #expect(result.itemsUnchanged && result.feed.episodes.isEmpty)
        #expect(await store.episodeRecordsDecoded - decoded == 0)
        try await store.close()
    }
}

private struct MemoTestTransport: FeedHTTPTransport {
    var reply: @Sendable (URLRequest) async throws -> FeedHTTPResponse
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse { try await reply(request) }
}

extension FeedLibraryStore {
    func setRefreshMemoEnabled(_ value: Bool) { refreshMemoEnabled = value }
}

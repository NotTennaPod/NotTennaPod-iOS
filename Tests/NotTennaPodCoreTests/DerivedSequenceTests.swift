import Foundation
import Testing
@testable import NotTennaPodCore

/// Seeded sequences of real writes, each committed or rolled back on its own, on a library restored from Android and then
/// upgraded to schema 21 (its fill running between the writes, across relaunches), with Keep's conversion and a restore
/// into a new library amid them. After every step the derived keys and counts equal the reference decoded from the
/// records, and every canonical table equals a reference carried from step to step: the previous reference with the
/// step's intended change applied (`CanonicalPreservationTests.Intent`, from the reference and the step's input only),
/// never the database's result. A coverage manifest counts only steps that ran, and asserts every kind did.
@Suite(.serialized) struct DerivedSequenceTests {
    typealias Preservation = CanonicalPreservationTests
    typealias Snapshot = Preservation.Snapshot
    typealias Intent = Preservation.Intent

    enum Step: String, CaseIterable, Comparable {
        case fill, restart, restartDuringFill, subscribe, refreshAdd, refreshChange, refreshRemove, refreshUnchanged, refreshNotModified, refreshFailed,
             favorite, played, position, download,
             metadata, move, hideEpisode, revealEpisode, hideFeed, revealFeed, archive, subscribeAgain, pin, unpin, serverPin, serverUnpin,
             deleteEpisode, deleteFeed, savepointRollback, rollback, keep, restore
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        /// Steps placed by the sequence itself rather than drawn.
        static let placed: Set<Step> = [.fill, .restartDuringFill, .keep, .restore]
    }

    final class Run {
        let directory: URL
        var url: URL
        var store: FeedLibraryStore
        var reference: Snapshot
        var random: LargeAndroidLibrary.Random
        var manifest: [Step: Int] = [:]
        var failures: [String] = []
        var subscribed = 0
        var queue: [Step] = []

        /// The next write: every drawn kind in turn, in a seeded shuffled order each round (so each runs about as often).
        func next() -> Step {
            if queue.isEmpty {
                queue = Step.allCases.filter { !Step.placed.contains($0) }
                for index in queue.indices.reversed() { queue.swapAt(index, random.int(0...index)) }
            }
            return queue.removeLast()
        }

        init(directory: URL, url: URL, store: FeedLibraryStore, seed: UInt64) throws {
            self.directory = directory; self.url = url; self.store = store; random = LargeAndroidLibrary.Random(state: seed)
            reference = try Snapshot.take(url)
        }

        func pick<T>(_ values: [T]) -> T? { values.isEmpty ? nil : values[random.int(0...(values.count - 1))] }

        func rows(_ sql: String) throws -> [Int64] { try RawLibrary.rows(url, sql).compactMap { $0[0].flatMap { Int64($0) } } }

        /// Feeds and episodes lists show (not hidden as a whole, not pinned), and every episode.
        func shownFeeds() throws -> [Int64] {
            try rows("SELECT id FROM feeds f WHERE " + LibraryReader.listedFeedCondition("f.id") + " AND json_extract(CAST(record AS TEXT), '$.subscriptionState') = 0 ORDER BY id")
        }
        func episodes(of feed: Int64? = nil) throws -> [Int64] {
            try rows("SELECT id FROM episodes" + (feed.map { " WHERE feed_id = \($0) AND id NOT IN (SELECT episode_id FROM ntp_hidden_episodes)" } ?? "") + " ORDER BY id")
        }
    }

    struct Outcome { var manifest: [Step: Int]; var failures: [String] }

    static func library(episodes: Int, feeds: Int) async throws -> (URL, URL) {
        let directory = try EpisodeListKeysTests.directory()
        let url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: episodes, feeds: feeds)
        try DerivedDataOracle.downgradeTo20(url)
        return (directory, url)
    }

    static func report(_ manifest: [Step: Int]) -> String { manifest.sorted { $0.key < $1.key }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ") }

    @Test func aSeededSequenceStaysExactAfterEveryCommitAndRollback() async throws {
        let outcome = try await Self.run(seed: 0x5EED_0D1_0001, episodes: 1_000, feeds: 25, steps: 420)
        print("DERIVED sequence coverage (steps that ran): \(Self.report(outcome.manifest))")
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        for step in Step.allCases where step != .keep && step != .restore {
            #expect(outcome.manifest[step, default: 0] >= 3, "coverage: \(step) ran \(outcome.manifest[step, default: 0]) times")
        }
        #expect(outcome.manifest[.keep] == 1 && outcome.manifest[.restore] == 1)
    }

    /// The power-user variant (`NTP_SCALE=1`): 50,000 episodes in 120 podcasts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NTP_SCALE"] == "1"))
    func aSeededSequenceAtPowerUserScale() async throws {
        let outcome = try await Self.run(seed: 0x5EED_0D1_0002, episodes: 50_000, feeds: 120, steps: 150, fillBatch: 1_000, fillsPerStep: 8)
        print("DERIVED sequence coverage at 50k (steps that ran): \(Self.report(outcome.manifest))")
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        for step in Step.allCases { #expect(outcome.manifest[step, default: 0] >= 1, "coverage: \(step)") }
    }

    /// `corrupt_sequence_metadata`: a trigger dropping an episode's show notes whenever its key's publication date
    /// changes (the derived data stays coherent). The sequence fails by name, at the canonical check of the step that
    /// changed a date (a metadata edit, or a refresh changing an episode).
    static let corruptSequenceMetadata = "CREATE TRIGGER corrupt_sequence_metadata AFTER UPDATE OF pub_ms ON episode_list_keys WHEN NEW.pub_ms IS NOT OLD.pub_ms BEGIN UPDATE episodes SET record = CAST(json_remove(CAST(record AS TEXT), '$.details.description') AS BLOB) WHERE id = NEW.id; END"

    @Test func theSequenceRejectsShowNotesLostOnAMetadataChange() async throws {
        let outcome = try await Self.run(seed: 0x5EED_0D1_0001, episodes: 1_000, feeds: 25, steps: 420) { url in
            try RawLibrary.execute(url, Self.corruptSequenceMetadata)
        }
        let failure = try #require(outcome.failures.first, "corrupt_sequence_metadata must fail the sequence")
        #expect(failure.contains("canonical") && !failure.contains("derived") && (failure.contains(" metadata:") || failure.contains(" refreshChange:")), "\(failure)")
        print("MUTATION corrupt_sequence_metadata: \(failure.prefix(320))")
    }

    /// `corrupt_drop_effects`: a trigger deleting every pending effect when a refresh's removal adds its cleanup
    /// effect. The sequence fails by name, at the canonical check of that removal.
    static let corruptDropEffects = "CREATE TRIGGER corrupt_drop_effects AFTER INSERT ON pending_effects WHEN NEW.kind = 'removeEpisodes' BEGIN DELETE FROM pending_effects; END"

    @Test func theSequenceRejectsLostCleanupWork() async throws {
        let outcome = try await Self.run(seed: 0x5EED_0D1_0001, episodes: 1_000, feeds: 25, steps: 420) { url in
            try RawLibrary.execute(url, Self.corruptDropEffects)
        }
        let failure = try #require(outcome.failures.first, "corrupt_drop_effects must fail the sequence")
        #expect(failure.contains(" refreshRemove: canonical") && failure.contains("pending_effects"), "\(failure)")
        print("MUTATION corrupt_drop_effects: \(failure.prefix(320))")
    }

    static func run(seed: UInt64, episodes: Int, feeds: Int, steps: Int, fillBatch: Int = 60, fillsPerStep: Int = 1,
                    mutation: (URL) throws -> Void = { _ in }) async throws -> Outcome {
        let (directory, url) = try await library(episodes: episodes, feeds: feeds)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try Run(directory: directory, url: url, store: try FeedLibraryStore(url: url), seed: seed)
        try mutation(url)
        let now = EpisodeListKeysTests.now
        var kept = false, restored = false
        for number in 0..<steps {
            var before = run.reference
            let filling = !run.store.derivedReady
            // While filling, every other step advances it; Keep halfway, a restore at two thirds; the other writes drawn.
            var step: Step = filling && number.isMultiple(of: 2) ? .fill : filling && number % 6 == 3 ? .restartDuringFill : run.next()
            if step == .restart && filling { step = .restartDuringFill }
            if !kept && number >= steps / 2 { step = .keep; kept = true }
            if !restored && number >= steps * 2 / 3 { step = .restore; restored = true }
            var intent = Intent(), ran = false
            switch step {
            case .fill:
                for _ in 0..<fillsPerStep { if try await run.store.fillDerivedBatch(fillBatch) { break } }
                ran = true
            case .restart, .restartDuringFill:
                try await run.store.close()
                run.store = try FeedLibraryStore(url: run.url)
                ran = true
            case .subscribe:
                run.subscribed += 1
                let fetched = EpisodeListKeysTests.fetched("https://example.test/sequence-\(run.subscribed).xml", title: "S\(run.subscribed)", count: run.random.int(1...6))
                intent = Self.subscription(fetched, feedID: before.allocated("feed") + 1, firstEpisode: before.allocated("episode") + 1, now: now)
                _ = try await run.store.insert(fetched, options: .init(now: now))
                ran = true
            case .refreshNotModified, .refreshFailed:
                // The feed's host answers "not modified", or the refresh fails, at this step's time.
                guard let feedID = run.pick(try run.shownFeeds()) else { break }
                let clock = now.addingTimeInterval(Double(number))
                if step == .refreshNotModified {
                    try await run.store.recordUnchangedRefresh(feedID: feedID, date: clock)
                    intent = Self.notModified(feedID, at: clock)
                } else {
                    try await run.store.recordFailure(.httpStatus(503), feedID: feedID, date: clock)
                    intent = Self.failed(feedID, at: clock)
                }
                ran = true
            case .refreshAdd, .refreshChange, .refreshRemove, .refreshUnchanged:
                guard let feedID = run.pick(try run.shownFeeds()), let feed = try before.feed(feedID) else { break }
                let saved = try before.episodeIDs(feed: feedID).compactMap { try before.episode($0) }
                var items = saved.map(\.details)
                // Each refresh at its own time, later than the ones before.
                let clock = now.addingTimeInterval(Double(number))
                intent = Self.refresh(feed, saved, now: clock)
                switch step {
                case .refreshUnchanged:
                    break
                case .refreshAdd:
                    let item = ParsedEpisode(identifier: "added-\(number)", title: "Added \(number)", publicationDate: now.addingTimeInterval(Double(number)),
                                             media: ParsedMedia(url: "https://media.example.test/added-\(number).mp3", size: 10, durationMilliseconds: 1_000))
                    items.append(item)
                    let id = before.allocated("episode") + 1
                    intent.added[id] = (feedID, Self.newEpisode(id, item, feed: feed, saved: saved, now: clock))
                    intent.tables["library_ids"] = { rows, _ in rows.update(where: "kind", is: .string("episode")) { $0["value"] = .integer(id) } }
                case .refreshChange:
                    guard !items.isEmpty else { break }
                    let index = run.random.int(0...(items.count - 1))
                    let title = "Retitled \(number)", notes = "Changed \(number)", date = now.addingTimeInterval(Double(number) + 0.0005)
                    items[index].title = title; items[index].description = notes; items[index].publicationDate = date
                    intent.edit(saved[index].id) { $0.details.title = title; $0.details.description = notes; $0.details.publicationDate = date }
                default:
                    guard items.count > 1 else { break }
                    let index = run.random.int(0...(items.count - 1))
                    items.remove(at: index)
                    intent.removed.insert(saved[index].id)
                    Self.renumberQueue(&intent)
                    intent.appended.remove("pending_effects")
                    try Self.cleanupEffects(&intent, before, removing: [saved[index]], feed: feed, deletion: false, now: clock)
                }
                guard step != .refreshChange || !items.isEmpty, step != .refreshRemove || items.count == saved.count - 1 else { break }
                var metadata = feed.metadata
                metadata.episodes = items
                var options = FeedRefreshOptions(now: clock)
                options.removeUnlistedItems = step == .refreshRemove
                _ = try await run.store.applyRefresh(FetchedFeed(feed: metadata, source: feed.source, responseURL: URL(string: "https://example.test/")!,
                                                                 validator: nil, permanentRedirectURL: nil), feedID: feedID, options: options)
                ran = true
            case .favorite, .played, .position, .download:
                guard let id = run.pick(try run.episodes(of: run.pick(try run.shownFeeds()))) else { break }
                switch step {
                case .favorite:
                    let on = run.random.chance(2)
                    try await run.store.setFavorite(episodeID: id, favorite: on)
                    intent = .editing(id) { $0.userState.isFavorite = on }
                case .played:
                    let played = run.random.chance(2)
                    try await run.store.markEpisodePlayed(episodeID: id, played: played)
                    intent = .editing(id) { expected in
                        expected.userState.playState = played ? .played : .unplayed
                        if played && expected.details.media != nil { expected.userState.positionMilliseconds = 0 }
                    }
                    intent.appended = ["pending_effects", "synchronization_outbox"]
                    intent.tables["episode_swipe_undo"] = { rows, _ in rows.remove(where: "episode_id", in: [.integer(id)]) }
                case .position:
                    let position = Int32(run.random.int(0...3_000_000))
                    try await run.store.updateEpisode(id: id) { $0.userState.positionMilliseconds = position }
                    intent = .editing(id) { $0.userState.positionMilliseconds = position }
                default:
                    let on = run.random.chance(2), path = "/media/sequence-\(number).mp3"
                    try await run.store.updateEpisode(id: id) { $0.userState.isDownloaded = on; $0.userState.localFileURL = on ? path : nil; $0.userState.downloadDate = on ? now : nil }
                    intent = .editing(id) { $0.userState.isDownloaded = on; $0.userState.localFileURL = on ? path : nil; $0.userState.downloadDate = on ? now : nil }
                }
                ran = true
            case .metadata:
                guard let id = run.pick(try run.episodes(of: run.pick(try run.shownFeeds()))) else { break }
                let date = now.addingTimeInterval(Double(run.random.int(-100_000...100_000)) + 0.5), title = "Meta \(number)"
                try await run.store.updateEpisode(id: id) { $0.details.title = title; $0.details.publicationDate = date; $0.details.media?.durationMilliseconds = Int32(number) }
                intent = .editing(id) { $0.details.title = title; $0.details.publicationDate = date; $0.details.media?.durationMilliseconds = Int32(number) }
                ran = true
            case .move:
                guard let id = run.pick(try run.episodes()), let target = run.pick(try run.rows("SELECT id FROM feeds")) else { break }
                try DerivedDataOracle.write(run.url, "UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(target), .integer(id)])
                intent.moved[id] = target
                ran = true
            case .hideEpisode:
                guard let id = run.pick(try run.rows("SELECT id FROM episodes WHERE id NOT IN (SELECT episode_id FROM ntp_hidden_episodes)")),
                      let feed = before.tables["episodes"]?[id]?[1] else { break }
                try DerivedDataOracle.write(run.url, "INSERT INTO ntp_hidden_episodes(episode_id, feed_id) SELECT id, feed_id FROM episodes WHERE id = ?", [.integer(id)])
                intent.tables["ntp_hidden_episodes"] = { rows, _ in rows.insert(["episode_id": .integer(id), "feed_id": feed, "seq": .integer(0)]) }
                ran = true
            case .revealEpisode:
                guard let id = run.pick(try run.rows("SELECT episode_id FROM ntp_hidden_episodes")) else { break }
                try DerivedDataOracle.write(run.url, "DELETE FROM ntp_hidden_episodes WHERE episode_id = ?", [.integer(id)])
                intent.tables["ntp_hidden_episodes"] = { rows, _ in rows.remove(where: "episode_id", in: [.integer(id)]) }
                ran = true
            case .hideFeed:
                guard let feed = run.pick(try run.rows("SELECT id FROM feeds WHERE id NOT IN (SELECT feed_id FROM ntp_hidden_feeds)")) else { break }
                let state = run.random.chance(2) ? "staging" : "removing"
                try DerivedDataOracle.write(run.url, "INSERT INTO ntp_hidden_feeds(feed_id, podcast_id, state, seq) VALUES (?, 'p', ?, 1)", [.integer(feed), .text(state)])
                intent.tables["ntp_hidden_feeds"] = { rows, _ in rows.insert(["feed_id": .integer(feed), "podcast_id": .string("p"), "state": .string(state), "seq": .integer(1)]) }
                ran = true
            case .revealFeed:
                guard let feed = run.pick(try run.rows("SELECT feed_id FROM ntp_hidden_feeds")) else { break }
                try DerivedDataOracle.write(run.url, "DELETE FROM ntp_hidden_feeds WHERE feed_id = ?", [.integer(feed)])
                intent.tables["ntp_hidden_feeds"] = { rows, _ in rows.remove(where: "feed_id", in: [.integer(feed)]) }
                ran = true
            case .archive, .subscribeAgain:
                guard let feed = run.pick(try run.rows("SELECT id FROM feeds WHERE json_extract(CAST(record AS TEXT), '$.subscriptionState') = \(step == .archive ? 0 : 2)")) else { break }
                let state: FeedSubscriptionState = step == .archive ? .archived : .subscribed
                try await run.store.updatePreferences(feedID: feed) { $0.subscriptionState = state }
                intent.feedEdits[feed] = { Self.savePreferences(&$0); $0.subscriptionState = state }
                intent.appended = ["pending_effects", "synchronization_outbox"]
                ran = true
            case .pin:
                guard let feed = run.pick(try run.rows("SELECT id FROM feeds WHERE id NOT IN (SELECT feed_id FROM pinned_feed_removals)")) else { break }
                try DerivedDataOracle.write(run.url, "INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(feed)])
                intent.tables["pinned_feed_removals"] = { rows, _ in rows.insert(["feed_id": .integer(feed)]) }
                ran = true
            case .unpin:
                guard let feed = run.pick(try run.rows("SELECT feed_id FROM pinned_feed_removals")) else { break }
                try DerivedDataOracle.write(run.url, "DELETE FROM pinned_feed_removals WHERE feed_id = ?", [.integer(feed)])
                intent.tables["pinned_feed_removals"] = { rows, _ in rows.remove(where: "feed_id", in: [.integer(feed)]) }
                ran = true
            case .serverPin:
                // A feed no podcast maps yet (a feed maps to one podcast).
                guard let feed = run.pick(try run.rows("SELECT id FROM feeds WHERE id NOT IN (SELECT feed_id FROM ntp_podcasts WHERE feed_id IS NOT NULL)")) else { break }
                let podcast = "p\(run.random.int(0...5))"
                try DerivedDataOracle.write(run.url, "INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES (?, ?, 1) ON CONFLICT(podcast_id) DO UPDATE SET feed_id = excluded.feed_id, pinned_removal = 1",
                                            [.text(podcast), .integer(feed)])
                intent.tables["ntp_podcasts"] = { rows, _ in
                    if rows.first(where: "podcast_id", is: .string(podcast)) == nil {
                        rows.insert(["podcast_id": .string(podcast), "feed_id": .integer(feed), "pinned_removal": .integer(1)])
                    } else {
                        rows.update(where: "podcast_id", is: .string(podcast)) { $0["feed_id"] = .integer(feed); $0["pinned_removal"] = .integer(1) }
                    }
                }
                ran = true
            case .serverUnpin:
                guard let podcast = run.pick(try RawLibrary.rows(run.url, "SELECT podcast_id FROM ntp_podcasts ORDER BY podcast_id").compactMap({ $0[0] })) else { break }
                if run.random.chance(2) {
                    try DerivedDataOracle.write(run.url, "UPDATE ntp_podcasts SET pinned_removal = 0 WHERE podcast_id = ?", [.text(podcast)])
                    intent.tables["ntp_podcasts"] = { rows, _ in rows.update(where: "podcast_id", is: .string(podcast)) { $0["pinned_removal"] = .integer(0) } }
                } else {
                    try DerivedDataOracle.write(run.url, "DELETE FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)])
                    intent.tables["ntp_podcasts"] = { rows, _ in rows.remove(where: "podcast_id", in: [.string(podcast)]) }
                }
                ran = true
            case .deleteEpisode:
                guard let id = run.pick(try run.episodes()) else { break }
                try DerivedDataOracle.write(run.url, "DELETE FROM episodes WHERE id = ?", [.integer(id)])
                intent.removed = [id]
                ran = true
            case .deleteFeed:
                guard run.random.chance(2), let feed = run.pick(try run.shownFeeds()), let header = try before.feed(feed) else { break }
                try await run.store.requestFeedDeletion(feedID: feed, now: now)
                intent.feedsRemoved = [feed]
                Self.renumberQueue(&intent)
                intent.appended = ["synchronization_outbox"]
                try Self.cleanupEffects(&intent, before, removing: Self.listed(before, feed: feed), feed: header, deletion: true, now: now)
                ran = true
            case .savepointRollback, .rollback:
                guard let id = run.pick(try run.episodes()), let other = run.pick(try run.episodes()), let feed = run.pick(try run.rows("SELECT id FROM feeds")),
                      var episode = try before.episode(id) else { break }
                episode.userState.isFavorite.toggle(); episode.details.title = "Never \(number)"
                let writes: [(String, [LibrarySQLValue])] = [("UPDATE episodes SET record = ? WHERE id = ?", [.blob(try Preservation.encode(episode)), .integer(id)]),
                                                             ("UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(feed), .integer(other)]),
                                                             ("INSERT OR IGNORE INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (?, ?)", [.integer(other), .integer(feed)]),
                                                             ("DELETE FROM pinned_feed_removals", []), ("DELETE FROM episodes WHERE id = ?", [.integer(other)])]
                if step == .rollback {
                    try DerivedDataOracle.write(run.url, [("BEGIN", [])] + writes + [("ROLLBACK", [])])
                } else {
                    // Everything inside the savepoint is rolled back; the transaction commits nothing else.
                    try DerivedDataOracle.write(run.url, [("BEGIN", []), ("SAVEPOINT s", [])] + writes + [("ROLLBACK TO s", []), ("RELEASE s", []), ("COMMIT", [])])
                }
                ran = true
            case .keep:
                try await run.store.close()
                intent = try Preservation.keepIntent(before, operation: "sequence")
                let database = try LibrarySQLite(url: run.url)
                try database.transaction { try LibraryKeep.convert(database, operation: "sequence") }
                try database.close()
                run.store = try FeedLibraryStore(url: run.url)
                ran = true
            case .restore:
                // An Android backup restored into a new library, which carries the replaced library's state.
                let carried = before
                let carry = try await run.store.restoreCarryOver()
                try await run.store.close()
                let backup = run.directory.appendingPathComponent("restore-\(number).db")
                try LargeAndroidLibrary.write(to: backup, shape: EpisodeListKeysTests.shape(episodes: episodes, feeds: feeds), seed: seed &+ 1)
                let library = try AndroidDatabaseRestore.read(backup, staging: run.directory.appendingPathComponent("restore-staging-\(number)"))
                run.url = run.directory.appendingPathComponent("restored-\(number).sqlite")
                run.store = try FeedLibraryStore(url: run.url)
                before = try Snapshot.take(run.url)
                try await run.store.installRestoredLibrary(library, carrying: carry)
                intent = Preservation.restoreIntent(library, carried: carried)
                if try Preservation.restoreJournal(Snapshot.take(run.url)) != FeedLibraryStore.RestoreJournal(feedSpeeds: library.feedSpeeds, feedSilence: library.feedSilence) {
                    run.failures.append("step \(number) restore: the restore journal")
                }
                ran = true
            }
            // A step whose preconditions did not hold wrote nothing and intends nothing.
            if ran { run.manifest[step, default: 0] += 1 } else { intent = Intent() }
            let derived = try DerivedDataOracle.mismatches(run.url, limit: 3)
            if !derived.isEmpty { run.failures.append("step \(number) \(step): derived \(derived)") }
            let (reference, found) = try Preservation.check(before, intent, Snapshot.take(run.url))
            if !found.isEmpty { run.failures.append("step \(number) \(step): canonical \(found)") }
            run.reference = reference
            if !run.failures.isEmpty { break }
        }
        if run.failures.isEmpty {
            // The fill finishes and everything is exact once more after a relaunch, with no canonical change.
            try await run.store.fillDerivedData(batch: fillBatch)
            try await run.store.close()
            run.store = try FeedLibraryStore(url: run.url)
            if !run.store.derivedReady { run.failures.append("not ready after the sequence") }
            let derived = try DerivedDataOracle.mismatches(run.url)
            if !derived.isEmpty { run.failures.append("after the sequence: derived \(derived)") }
            let found = try Preservation.check(run.reference, Intent(), Snapshot.take(run.url)).found
            if !found.isEmpty { run.failures.append("after the sequence: canonical \(found)") }
        }
        try await run.store.close()
        return Outcome(manifest: run.manifest, failures: run.failures)
    }

    // MARK: - Intents of the drawn steps

    /// A subscription: the feed as fetched, subscribed, attempted now, with the next feed ID; its episodes in order with
    /// the next episode IDs, unplayed, their chapters flagged as stored; the ID counters advanced; effects added.
    static func subscription(_ fetched: FetchedFeed, feedID: Int64, firstEpisode: Int64, now: Date) -> Intent {
        var intent = Intent()
        var feed = LibraryFeed(id: feedID, source: fetched.source, metadata: fetched.feed, episodes: [])
        feed.lastRefreshAttempt = now
        feed.subscriptionState = .subscribed
        intent.feedsAdded[feedID] = feed
        for (offset, item) in fetched.feed.episodes.enumerated() {
            var details = item
            if details.publicationDate == nil { details.publicationDate = now }
            let id = firstEpisode + Int64(offset)
            intent.added[id] = (feedID, LibraryEpisode(id: id, details: details, hasStoredChapters: details.chapters != nil))
        }
        let last = firstEpisode + Int64(fetched.feed.episodes.count) - 1
        intent.tables["library_ids"] = { rows, _ in
            rows.update(where: "kind", is: .string("feed")) { $0["value"] = .integer(feedID) }
            rows.update(where: "kind", is: .string("episode")) { $0["value"] = .integer(last) }
        }
        intent.appended = ["pending_effects", "synchronization_outbox"]
        return intent
    }

    /// A refresh of a feed with its own items: the header records the attempt (now, when later than the last; this
    /// device's own attempt likewise) and a successful, validator-less fetch of a known format; episodes with chapters
    /// are marked as having them stored; effects, the outbox and the refresh log only gain rows.
    static func refresh(_ feed: LibraryFeed, _ episodes: [LibraryEpisode], now: Date) -> Intent {
        var intent = Intent()
        intent.feedEdits[feed.id] = { header in
            if header.pageNumber == 0, now > (header.lastRefreshAttempt ?? Date(timeIntervalSince1970: 0)) { header.lastRefreshAttempt = now }
            if header.pageNumber == 0, now > (header.localRefreshAttempt ?? Date(timeIntervalSince1970: 0)) { header.localRefreshAttempt = now }
            header.validator = nil
            header.lastUpdateFailed = false
        }
        intent.formatKnown = [feed.id]
        for episode in episodes where episode.details.chapters != nil && !episode.hasStoredChapters {
            intent.edit(episode.id) { $0.hasStoredChapters = true }
        }
        intent.appended = ["pending_effects", "synchronization_outbox", "refresh_log"]
        return intent
    }

    /// A refresh the feed's host answered "not modified": this device's attempt time, when later than its last and the last
    /// refresh did not fail; nothing else (no log entry, nothing Android exports).
    static func notModified(_ feed: Int64, at date: Date) -> Intent {
        var intent = Intent()
        intent.feedEdits[feed] = { header in
            if !header.lastUpdateFailed, date > (header.localRefreshAttempt ?? Date(timeIntervalSince1970: 0)) { header.localRefreshAttempt = date }
        }
        return intent
    }

    /// A failed refresh: the failure and its time, as the attempt and as this device's attempt; its log entry.
    static func failed(_ feed: Int64, at date: Date) -> Intent {
        var intent = Intent()
        intent.feedEdits[feed] = { header in
            header.lastUpdateFailed = true; header.lastRefreshAttempt = date; header.localRefreshAttempt = date
        }
        intent.appended = ["refresh_log"]
        return intent
    }

    /// An episode a refresh adds: unplayed, or New when it is at least as recent as the feed's newest and the feed's new
    /// episodes go to the Inbox (the default, and always for a feed downloading automatically).
    static func newEpisode(_ id: Int64, _ item: ParsedEpisode, feed: LibraryFeed, saved: [LibraryEpisode], now: Date) -> LibraryEpisode {
        var episode = LibraryEpisode(id: id, details: item, hasStoredChapters: item.chapters != nil)
        let newest = saved.compactMap(\.details.publicationDate).filter { $0 > Date(timeIntervalSince1970: 0) }.max() ?? now
        if feed.subscriptionState == .subscribed, (item.publicationDate ?? now) >= newest {
            var action = feed.newEpisodesAction == .global ? NewEpisodesAction.inbox : feed.newEpisodesAction
            if !feed.source.isLocalFeedSource && feed.autoDownload == .enabled { action = .inbox }
            if action == .inbox { episode.userState.playState = .new }
        }
        return episode
    }

    /// A preferences save writes every preference explicitly (a preference the header left at its default is stored).
    static func savePreferences(_ feed: inout LibraryFeed) {
        feed.keepUpdated = feed.keepUpdated; feed.showEpisodeNotification = feed.showEpisodeNotification
        feed.automaticDownloadFilter = feed.automaticDownloadFilter; feed.tags = feed.tags; feed.skipPreferences = feed.skipPreferences
        feed.volumeAdaptation = feed.volumeAdaptation; feed.autoDelete = feed.autoDelete
    }

    /// A feed's episodes in the store's order (newest first, then by ID).
    static func listed(_ snapshot: Snapshot, feed: Int64) throws -> [LibraryEpisode] {
        let rows = (snapshot.tables["episodes"] ?? [:]).filter { $0.value[1] == .integer(feed) }
        return try rows.sorted { ($0.value[2].integer ?? 0, -$0.key) > ($1.value[2].integer ?? 0, -$1.key) }.compactMap { try snapshot.episode($0.key) }
    }

    /// What a removal through the store does to the durable effects: queued-episode work loses the removed episodes (and
    /// goes when none is left); one cleanup effect is added, a refresh's removal or the feed's deletion, with the
    /// episodes, their downloaded files and the synchronization account to clean up after; every other effect stays.
    static func cleanupEffects(_ intent: inout Intent, _ before: Snapshot, removing episodes: [LibraryEpisode], feed: LibraryFeed, deletion: Bool, now: Date) throws {
        #expect(before.tables["download_jobs"]?.isEmpty ?? true, "no download job to cancel")
        let account = try before.tables["synchronization_state"]?.values.first.flatMap { $0[1].data }
            .map { try JSONDecoder().decode(SynchronizationState.self, from: $0).accountID } ?? nil
        let local = feed.source.isLocalFeedSource, removed = Set(episodes.map(\.id))
        let downloaded = local ? [] : episodes.filter { $0.details.media != nil && $0.userState.isDownloaded }
        let cleanup = FeedDeletion(feedID: feed.id, episodeIDs: removed, downloadJobIDs: [],
                                   files: Set(downloaded.compactMap { $0.userState.localFileURL.map { URL(fileURLWithPath: $0) } }).sorted { $0.path < $1.path },
                                   source: feed.source, synchronize: !local && feed.subscriptionState != .notSubscribed,
                                   downloadedEpisodes: downloaded, synchronizationAccount: .init(id: account))
        let effect = deletion ? FeedLibraryEffect(feedID: feed.id, date: now, kind: .deleteFeed(cleanup))
            : FeedLibraryEffect(feedID: feed.id, date: now, kind: .removeEpisodes(episodes), removedEpisodeCleanup: cleanup)
        let effects = before.rows("pending_effects")
        let next = max(before.rows("sqlite_sequence").first(where: "name", is: .string("pending_effects"))?["seq"]?.integer ?? 0,
                       effects.rows.keys.max() ?? 0) + 1
        intent.tables["pending_effects"] = { rows, _ in
            for (rowid, row) in rows.rows where row[rows.index("kind")] == .string("queueEpisodes") {
                guard let data = row[rows.index("record")].data else { continue }
                var queued = try JSONDecoder().decode(FeedLibraryEffect.self, from: data)
                guard case .queueEpisodes(let ids) = queued.kind else { continue }
                let remaining = ids.filter { !removed.contains($0) }
                if remaining.isEmpty { rows.rows[rowid] = nil; continue }
                queued.kind = .queueEpisodes(remaining)
                rows.rows[rowid]![rows.index("record")] = .blob(try JSONEncoder().encode(queued))
            }
            rows.insert(["id": .integer(next), "kind": .string(effect.kind.name), "record": .blob(try JSONEncoder().encode(effect))])
        }
        intent.tables["sqlite_sequence"] = { rows, _ in rows.upsert(where: "name", is: .string("pending_effects"), set: "seq", to: .integer(next)) }
    }

    /// The queue after a removal through the store: what remains, in order, at positions 0..<n.
    static func renumberQueue(_ intent: inout Intent) {
        intent.tables["queue"] = { rows, _ in
            let position = rows.index("position"), episode = rows.index("episode_id")
            let remaining = rows.rows.values.sorted { ($0[position].integer ?? 0) < ($1[position].integer ?? 0) }.map { $0[episode] }
            rows.rows = [:]
            for (index, id) in remaining.enumerated() { rows.insert(["position": .integer(Int64(index)), "episode_id": id]) }
        }
    }

    // MARK: - A server library's life

    struct Stop: Error {}

    /// An arriving episode as the protocol projects it from the test's own records (PROTOCOL §6.8), with its ID still to
    /// be allocated: its identity's GUID, every field of its metadata record (null ones absent), its media as the record
    /// gives it, no stored chapters, and the user state of an episode without state records (unplayed, at the start,
    /// never played), favorite when a favorite record says so.
    static func arrivingEpisode(_ number: Int, favorite: Bool = false) throws -> LibraryEpisode {
        typealias Cutover = ServerBoundedCutoverTests
        let identity = try #require(try Cutover.episodeRecords(number...number).first { $0.fieldGroup == "identity" }?.value)
        let metadata = try #require(Cutover.metadata(number, title: "Arriving \(number)").value)
        var details = ParsedEpisode()
        details.identifier = identity["occurrence"]?["guid"]?.stringValue
        details.title = metadata["title"]?.stringValue
        details.description = metadata["description"]?.stringValue
        details.link = metadata["link"]?.stringValue
        details.publicationDate = metadata["pub_date"]?.integerValue.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        details.imageURL = metadata["image_url"]?.stringValue
        details.paymentLink = metadata["payment_link"]?.stringValue
        details.chapterURL = metadata["chapter_url"]?.stringValue
        details.socialInteractionURL = metadata["social_interact_url"]?.stringValue
        let media = try #require(metadata["media"])
        details.media = ParsedMedia(url: media["url"]?.stringValue, size: media["size"]?.stringValue.flatMap { Int64($0) } ?? 0,
                                    mimeType: media["mime_type"]?.stringValue, durationMilliseconds: Int32(media["duration"]?.integerValue ?? 0))
        var episode = LibraryEpisode(id: 0, details: details)
        episode.userState.isFavorite = favorite
        return episode
    }

    /// The arriving podcast as the protocol makes it from its identity and subscription records: its refresh address,
    /// an RSS feed without metadata yet, subscribed, attempted at the unit's time.
    static func arrivingFeed(now: Int64) throws -> LibraryFeed {
        let records = try ServerBoundedCutoverTests.arrivingRecords(count: 1).filter { $0.entity == "podcast" }
        let identity = try #require(records.first { $0.fieldGroup == "identity" }?.value)
        var feed = LibraryFeed(id: 0, source: try #require(identity["refresh_url"]?.stringValue), metadata: ParsedFeed(format: .rss), episodes: [])
        feed.subscriptionState = records.first { $0.fieldGroup == "subscription" }?.value?["state"]?.stringValue == "subscribed" ? .subscribed : .notSubscribed
        feed.lastRefreshAttempt = Date(timeIntervalSince1970: Double(now) / 1_000)
        return feed
    }

    /// A server library composed with ordinary writes, each step checked against its intended change with the reference
    /// carried across them: a direct unit adds a podcast; local writes; a commit is staged hidden, its staging abandoned
    /// and taken out (the recovery), staged again and published; Keep converts the populated library; the standalone
    /// library is written; an Android backup is restored into a new library with the carried state; and written again.
    /// Returns the first failure (`mutation` runs on the library first; `after` right after each action, before its check).
    static func serverLife(mutation: (URL) throws -> Void = { _ in }, after: (String, URL) throws -> Void = { _, _ in }) async throws -> [String] {
        typealias Cutover = ServerBoundedCutoverTests
        let fixture = try await ServerLibraryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let keep = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/keep.xml", title: "Keep", count: 6))
        let ids = keep.feed.episodes.map(\.id).sorted()
        // A second subscription, its fact still pending: its counters equal the local IDs a later edit of the first feed
        // writes (they are not identities).
        let second = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/second.xml", title: "Second", count: 2))
        #expect(try RawLibrary.rows(fixture.url, "SELECT install_seq, author_seq FROM ntp_outbox WHERE op_id IN (SELECT op_id FROM ntp_registrations WHERE feed_id = \(second.feed.id))")
                == [["\(ids[1])", "\(ids[1])"]], "the colliding counters")
        // A tip another client published, known here and in the frontier: no local fact depends on it.
        try DerivedDataOracle.write(fixture.url, "INSERT INTO ntp_nodes(node_id, knowledge_clock, publication_seq, frontier, kind) VALUES ('\(Self.pulledTip)', 1, 1, 1, 'pulled')")
        var url = fixture.url
        var reference = try Snapshot.take(url)
        var failures: [String] = []
        var store: FeedLibraryStore? = fixture.store
        try mutation(url)
        func check(_ label: String, _ intent: Intent) throws {
            try after(label, url)
            let derived = try DerivedDataOracle.mismatches(url, limit: 3)
            if !derived.isEmpty { failures.append("\(label): derived \(derived)") }
            let (next, found) = try Preservation.check(reference, intent, Snapshot.take(url))
            if !found.isEmpty { failures.append("\(label): canonical \(found)") }
            reference = next
            if !failures.isEmpty { throw Stop() }
        }
        func scope(_ tables: [String: Rule], wires: ClosedRange<Int>, episodes: Set<Int64> = [], feeds: Set<Int64> = []) -> Intent.ServerScope {
            .init(tables: tables, wires: Set([Cutover.arriving, Cutover.arrivingGeneration] + wires.map(Cutover.wire)), episodes: episodes, feeds: feeds)
        }
        func arrivals(_ numbers: ClosedRange<Int>, feed: Int64?) throws -> Intent {
            var intent = Intent()
            for number in numbers { intent.arrivals["staged-\(number)"] = (Cutover.wire(number), feed, try Self.arrivingEpisode(number)) }
            intent.reservesIDs = true
            intent.appended = ["pending_effects", "synchronization_outbox"]
            return intent
        }
        do {
            // A direct unit: the arriving podcast, its first 40 episodes, the first three queued in order.
            var start = Self.now()
            let applier = try await ServerProjectionUnitTests.Applier(fixture)
            try await applier.apply(try Cutover.arrivingRecords(count: 40))
            var direct = try arrivals(1...40, feed: nil)
            direct.arrivingFeed = try Self.arrivingFeed(now: 1_760_000_000_000)
            direct.server = scope(Self.unitRules, wires: 1...40)
            Self.unitLibrary(&direct, cursor: try SyncCursor(logID: applier.log, epoch: 1, seq: 1, digest: ContractIdentity.sha256Hex(Array("\(applier.log)1".utf8))),
                             queueKeys: 3, window: start...Self.now())
            // The queue changed: queue work is requested (its token is random).
            direct.free.insert("queue_work")
            direct.tables["queue"] = { rows, context in
                for number in 1...3 {
                    rows.insert(["position": .integer(Int64(rows.rows.count)), "episode_id": context.arrived["staged-\(number)"].map { Snapshot.Value.integer($0) } ?? .null])
                }
            }
            try check("direct unit", direct)
            #expect(try RawLibrary.rows(url, "SELECT kind FROM queue_work") == [["autoDownload"]])
            let arrived = { (number: Int) throws -> Int64 in
                try #require(try reference.tables["episodes"]?.first { try reference.episode($0.key)?.details.identifier == "staged-\(number)" }?.key)
            }
            let podcast = try #require(try reference.tables["feeds"]?.first { try reference.feed($0.key)?.source == Preservation.arrivingSource }?.key)
            // Local writes.
            start = Self.now()
            try await fixture.store.setFavorite(episodeID: ids[0], favorite: true)
            var favorite = Intent.editing(ids[0]) { $0.userState.isFavorite = true }
            try Self.localEdit(&favorite, reference, episode: ids[0], podcast: keep.podcast, generation: keep.generation, type: "favorite.set",
                               payload: ["on": true], overlays: [("favorite", "true")], window: start...Self.now())
            try check("favorite", favorite)
            start = Self.now()
            try await fixture.store.markEpisodePlayed(episodeID: ids[1], played: true)
            var played = Intent.editing(ids[1]) { $0.userState.playState = .played; $0.userState.positionMilliseconds = 0 }
            played.appended = ["pending_effects", "synchronization_outbox"]
            try Self.localEdit(&played, reference, episode: ids[1], podcast: keep.podcast, generation: keep.generation, type: "episode.mark_played",
                               payload: ["reset_position": true], overlays: [("play_state", "\"played\""), ("position", "0")], window: start...Self.now())
            try check("played", played)
            // A commit adding 160 episodes and favoriting the first 40: built in a shadow and staged hidden.
            let input = try await ServerRetainedPublicationTests.nextInput(fixture, try Cutover.episodeRecords(41...200) + (1...40).map(ServerShadowStagingTests.favorite))
            let favorites = Set(try (1...40).map(arrived))
            try await ServerShadowStagingTests.stageAll(fixture, try await ServerRetainedPublicationTests.build(fixture, input), seq: input.commit.seq)
            var staged = try arrivals(41...200, feed: podcast)
            staged.server = scope(Self.stagingRules, wires: 1...200, episodes: favorites, feeds: [podcast])
            try check("staged", staged)
            // The staging abandoned and taken out in bounded transactions (the recovery): its rows go, nothing else.
            var takenOut = Intent()
            takenOut.removed = Set(try (41...200).map(arrived))
            takenOut.server = scope(Self.stagingRules, wires: 1...200, episodes: favorites.union(takenOut.removed), feeds: [podcast])
            while try await fixture.store.discardServerStagingBatch() {}
            try check("staging taken out", takenOut)
            // Staged again from a new shadow, and published: the 160 shown with their staged bytes, the 40 favorites set.
            let shadow = try await ServerRetainedPublicationTests.build(fixture, input)
            try await ServerShadowStagingTests.stageAll(fixture, shadow, seq: input.commit.seq)
            var again = try arrivals(41...200, feed: podcast)
            again.server = scope(Self.stagingRules, wires: 1...200, episodes: favorites, feeds: [podcast])
            try check("staged again", again)
            start = Self.now()
            _ = try await fixture.store.publishServerShadow(shadow, input: input, history: nil)
            let publication = start...Self.now()
            var published = Intent()
            for id in favorites { published.edits[id] = { $0.userState.isFavorite = true } }
            published.appended = ["pending_effects"]
            published.reservesIDs = true
            published.server = scope(Self.publicationRules, wires: 1...200, episodes: Set(try (1...200).map(arrived)), feeds: [podcast])
            Self.unitLibrary(&published, cursor: input.cursor, queueKeys: 0, window: publication)
            try check("published", published)
            // Keep converts the populated library: a played-here time, a statistics unit of the base, a podcast pinned as removed.
            try await fixture.store.close()
            store = nil
            var here = try #require(try reference.episode(ids[2]))
            here.userState.playedHereMilliseconds = 99
            let unit = try arrived(5)
            let wire = try #require(try fixture.rows("SELECT episode_id FROM ntp_episodes WHERE local_id = \(unit)").first?.first ?? nil)
            try DerivedDataOracle.write(url, [("UPDATE episodes SET record = ? WHERE id = ?", [.blob(try Preservation.encode(here)), .integer(ids[2])]),
                                              ("INSERT INTO ntp_statistics_units(episode_id, unit_id, record) VALUES (?, 'u1', ?)", [.text(wire), .blob(Data(#"{"id":"u1","played_ms":4000,"duration_ms":60000,"played":true}"#.utf8))]),
                                              ("UPDATE ntp_podcasts SET pinned_removal = 1 WHERE feed_id = ?", [.integer(keep.feed.id)])])
            var inputs = Intent.editing(ids[2]) { $0.userState.playedHereMilliseconds = 99 }
            inputs.tables["ntp_statistics_units"] = { rows, _ in
                rows.insert(["episode_id": .string(wire), "unit_id": .string("u1"), "record": .blob(Data(#"{"id":"u1","played_ms":4000,"duration_ms":60000,"played":true}"#.utf8))])
            }
            inputs.tables["ntp_podcasts"] = { rows, _ in rows.update(where: "feed_id", is: .integer(keep.feed.id)) { $0["pinned_removal"] = .integer(1) } }
            try check("Keep's inputs written", inputs)
            let conversion = try Preservation.keepIntent(reference, operation: "sequence-keep")
            let database = try LibrarySQLite(url: url)
            try database.transaction { try LibraryKeep.convert(database, operation: "sequence-keep") }
            try database.close()
            try check("Keep", conversion)
            #expect(reference.tables["statistics_units"]?.count == 1 && reference.tables["pinned_feed_removals"]?.count == 1)
            // The standalone library: a write.
            store = try FeedLibraryStore(url: url)
            try await store?.updateEpisode(id: ids[4]) { $0.userState.positionMilliseconds = 1_234 }
            try check("standalone write", .editing(ids[4]) { $0.userState.positionMilliseconds = 1_234 })
            // A restore into a new library, carrying this one's state; then a write.
            let carried = reference
            let carry = try #require(try await store?.restoreCarryOver())
            try await store?.close()
            let backup = fixture.directory.appendingPathComponent("backup.db")
            try LargeAndroidLibrary.write(to: backup, shape: EpisodeListKeysTests.shape(episodes: 400, feeds: 12))
            let library = try AndroidDatabaseRestore.read(backup, staging: fixture.directory.appendingPathComponent("staging"))
            url = fixture.directory.appendingPathComponent("restored.sqlite")
            store = try FeedLibraryStore(url: url)
            reference = try Snapshot.take(url)
            try await store?.installRestoredLibrary(library, carrying: carry)
            try check("restore", Preservation.restoreIntent(library, carried: carried))
            #expect(try Preservation.restoreJournal(Snapshot.take(url)) == FeedLibraryStore.RestoreJournal(feedSpeeds: library.feedSpeeds, feedSilence: library.feedSilence))
            let restoredID = try #require(library.feeds.flatMap(\.episodes).map(\.id).min())
            try await store?.setFavorite(episodeID: restoredID, favorite: true)
            try check("restored write", .editing(restoredID) { $0.userState.isFavorite = true })
        } catch is Stop {}
        try await store?.close()
        return failures
    }

    typealias Rule = Intent.ServerScope.Rule

    /// The server tables a unit or a staging writes, by their identity columns; every other one stays exactly as it was
    /// (the library row as `unitLibrary` predicts it). A unit (direct, or a publication) writes the base records of its
    /// wire entities, the mappings and queue keys of its episodes and its podcast; a staging and its take-out the staging
    /// list, hidden markers, base records and mappings of what they stage.
    static let unitRules: [String: Rule] = ["ntp_episodes": .identified(["episode_id": .wire, "local_id": .episode]),
                                            "ntp_podcasts": .identified(["podcast_id": .wire, "feed_id": .feed]),
                                            "ntp_records": .identified(["id": .wire]),
                                            "ntp_queue_keys": .identified(["episode_id": .episode])]
    static let stagingRules: [String: Rule] = ["ntp_episodes": .identified(["episode_id": .wire, "local_id": .episode]),
                                               "ntp_hidden_episodes": .identified(["episode_id": .episode]),
                                               "ntp_records": .identified(["id": .wire]),
                                               "ntp_staging": .identified(["keys": .wireIn])]
    static let publicationRules = stagingRules

    /// A synthetic tip another client published.
    static let pulledTip = "00000000-0000-4000-8000-000000000098"

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    /// The library row after a unit: the unit's cursor, the knowledge clock one later, the queue revision advanced by the
    /// queue keys it wrote, its time within the unit's; every other column (the account, namespace, installation, server,
    /// counters) as it was.
    static func unitLibrary(_ intent: inout Intent, cursor: SyncCursor, queueKeys: Int64, window: ClosedRange<Int64>) {
        intent.resolvers.append { _, actual in
            let time = actual.rows("ntp_library").first(where: "id", is: .integer(1))?["updated_at"]?.integer
            guard let time, window.contains(time) else { return ([:], ["ntp_library: its time \(String(describing: time)) is not the unit's"]) }
            return (["unit time": .integer(time)], [])
        }
        intent.tables["ntp_library"] = { rows, context in
            rows.update(where: "id", is: .integer(1)) {
                $0["cursor"] = .string(cursor.encoded); $0["log_id"] = .string(cursor.logID); $0["epoch"] = .integer(cursor.epoch)
                $0["seq"] = .integer(cursor.seq); $0["digest"] = .string(cursor.digest)
                $0["knowledge_clock"] = .integer(($0["knowledge_clock"]?.integer ?? 0) + 1)
                $0["queue_revision"] = .integer(($0["queue_revision"]?.integer ?? 0) + queueKeys)
                $0["updated_at"] = context.resolved["unit time"] ?? .null
            }
        }
    }

    /// The groups of an episode's base records a fact of each type comes from (their provenance is its dependencies).
    static let provenanceGroups: [String: Set<String>] = ["favorite.set": ["favorite"], "episode.mark_played": ["play_state", "position"]]

    /// A local edit of one episode in a server library, every change of the server tables predicted from the pre-state and
    /// the action, or preserved. Only the fact's op ID (random) and the action's time (the clock's) are resolved from the
    /// result, each validated: the op ID in the contract's UUID form (lowercase, hyphenated; Foundation's parser takes more),
    /// the times within the action. The episode's wire ID is predicted, never read from the result: its mapping when it has
    /// one, otherwise the derivation every client makes of an unmapped RSS-GUID episode of a podcast without identity rules
    /// (PROTOCOL §3.3, episode-v1 of the namespace, podcast, kind and GUID). The fact is built from the predicted members as
    /// typed contract JSON (a boolean is never a number) and its expected bytes and hash are its canonical encoding's, so
    /// the stored fact must be exactly those bytes. One fact is appended at the next install and author sequence numbers,
    /// with its dependencies (what the episode's base records came from, the latest fact of another author on it, the
    /// author's previous fact), its targets and payload; the episode is mapped (when it was not); its overlays are the
    /// action's values at the next knowledge clock; its dependencies leave the frontier and its node joins it; the author's
    /// tip becomes the fact; the library's install counter, clock and overlay revision advance. Every other row and column
    /// of every server table stays exactly as it was.
    static func localEdit(_ intent: inout Intent, _ before: Snapshot, episode id: Int64, podcast: String, generation: String, type: String,
                          payload: ContractObject, overlays: [(property: String, value: String)], window: ClosedRange<Int64>) throws {
        let library = try #require(before.rows("ntp_library").first(where: "id", is: .integer(1)))
        let main = try #require(library["main_author"]?.stringValue), install = try #require(library["next_install_seq"]?.integer)
        let namespace = try #require(library["namespace"]?.stringValue)
        let clock = try #require(library["knowledge_clock"]?.integer) + 1
        let author = try #require(before.rows("ntp_authors").first(where: "author_id", is: .string(main)))
        let seq = try #require(author["next_seq"]?.integer), previous = author["last_op_id"]?.stringValue
        let episode = try #require(try before.episode(id)), guid = try #require(episode.details.identifier)
        let mapped = before.rows("ntp_episodes").first(where: "local_id", is: .integer(id))?["episode_id"]?.stringValue
        let records = before.rows("ntp_records")
        let rules = records.rows.values.contains {
            $0[records.index("entity")] == .string("podcast") && $0[records.index("id")] == .string(podcast) && $0[records.index("field_group")] == .string("identity_rules")
        }
        try #require(mapped != nil || !rules, "the oracle predicts an unmapped episode's wire ID only for a podcast without identity rules")
        let wire = try mapped ?? ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .rssGUID, value: guid)
        let groups = Self.provenanceGroups[type] ?? []
        // Its dependencies, from the pre-state.
        var dependencies: [String] = previous.map { [$0] } ?? []
        for record in records.rows.values where record[records.index("entity")] == .string("episode") && record[records.index("id")] == .string(wire)
            && groups.contains(record[records.index("field_group")].stringValue ?? "") {
            let list = record[records.index("provenance")].data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
            dependencies += list.filter(ContractIdentity.isUUID)
        }
        let outboxBefore = before.rows("ntp_outbox")
        let authors = Dictionary(outboxBefore.rows.values.map { ($0[outboxBefore.index("op_id")].stringValue ?? "", $0[outboxBefore.index("author_id")].stringValue ?? "") }) { a, _ in a }
        let others = before.rows("ntp_overlays")
        let latest = others.rows.values.filter { overlay in
            overlay[others.index("entity")] == .string("episode") && overlay[others.index("id")] == .string(wire)
                && authors[overlay[others.index("op_id")].stringValue ?? ""].map { $0 != main } == true
        }.max { ($0[others.index("clock")].integer ?? 0) < ($1[others.index("clock")].integer ?? 0) }
        if let op = latest?[others.index("op_id")].stringValue { dependencies.append(op) }
        dependencies = Array(Set(dependencies)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        intent.resolvers.append { before, actual in
            // The one fact appended, its op ID in the contract's form.
            let known = Set(before.rows("ntp_outbox").values("op_id")), outbox = actual.rows("ntp_outbox")
            let new = outbox.rows.values.filter { !known.contains($0[outbox.index("op_id")]) }
            guard new.count == 1, let row = new.first, let op = row[outbox.index("op_id")].stringValue,
                  let data = row[outbox.index("fact")].data else { return ([:], ["ntp_outbox: \(new.count) facts appended, expected 1"]) }
            var found: [String] = []
            if !ContractIdentity.isUUID(op) { found.append("ntp_outbox: op ID \(op) is not in the contract's UUID form") }
            // The episode's one mapping is the predicted wire ID.
            let mappings = actual.rows("ntp_episodes")
            let wires = mappings.rows.values.filter { $0[mappings.index("local_id")] == .integer(id) }.compactMap { $0[mappings.index("episode_id")].stringValue }
            if wires != [wire] { found.append("ntp_episodes: episode \(id) mapped to \(wires), not its wire ID \(wire)") }
            // The client time is the resolved clock value: an integer of the stored fact, within the action.
            let time = (try? ContractJSON.decode(data))?["client_time"]?.integerValue ?? -1
            let created = row[outbox.index("created_at")].integer ?? -1
            if !window.contains(time) || !window.contains(created) { found.append("ntp_outbox: times \(time), \(created) outside the action") }
            // The fact: every member predicted and typed, but for the resolved op ID and time; its bytes the canonical encoding.
            var occurrence: ContractObject = ["guid": .string(guid), "k": "rss-guid", "v": .string(guid)]
            if let url = episode.details.media?.url, !url.isEmpty { occurrence["enclosure_url"] = .string(url) }
            if let title = episode.details.title { occurrence["title"] = .string(title) }
            occurrence["publication_time"] = .integer(Preservation.milliseconds(episode.details.publicationDate))
            var body = payload
            body["episode"] = .object(["episode_id": .string(wire), "generation_id": .string(generation), "podcast_id": .string(podcast),
                                       "occurrence": .object(occurrence)])
            var fact: ContractObject = ["author_id": .string(main), "author_seq": .integer(seq), "client_time": .integer(time),
                                        "dependencies": .array(dependencies.map { .string($0) }), "op_id": .string(op), "payload": .object(body),
                                        "targets": [.object(["entity": "episode", "generation": .string(generation), "id": .string(wire)])],
                                        "type": .string(type), "type_version": 1]
            if let previous { fact["previous_op_id"] = .string(previous) }
            let bytes = Data(try ContractJSON.object(fact).canonicalBytes())
            if bytes != data { found.append("ntp_outbox: the fact is not the action's: \(String(decoding: data, as: UTF8.self).prefix(600))") }
            let hash = ContractIdentity.sha256Hex(Array(bytes))
            if row[outbox.index("content_hash")] != .string(ContractIdentity.sha256Hex(Array(data))) { found.append("ntp_outbox: content hash of another fact") }
            return (["op": .string(op), "fact": .blob(bytes), "hash": .string(hash), "created": .integer(created)], found)
        }
        intent.tables["ntp_outbox"] = { rows, context in
            rows.insert(["install_seq": .integer(install), "op_id": context.resolved["op"] ?? .null, "author_id": .string(main), "author_seq": .integer(seq),
                         "type": .string(type), "fact": context.resolved["fact"] ?? .null, "content_hash": context.resolved["hash"] ?? .null,
                         "created_at": context.resolved["created"] ?? .null])
        }
        if mapped == nil {
            intent.tables["ntp_episodes"] = { rows, _ in
                rows.insert(["episode_id": .string(wire), "local_id": .integer(id), "podcast_id": .string(podcast),
                             "kind": .string("rss-guid"), "value": .string(guid)])
            }
        }
        intent.tables["ntp_overlays"] = { rows, context in
            for overlay in overlays {
                rows.insert(["op_id": context.resolved["op"] ?? .null, "entity": .string("episode"), "id": .string(wire),
                             "property": .string(overlay.property), "kind": .string("register"), "value": .blob(Data(overlay.value.utf8)), "clock": .integer(clock)])
            }
        }
        intent.tables["ntp_nodes"] = { rows, context in
            let leaving = Set(dependencies.map { Snapshot.Value.string($0) })
            for (rowid, row) in rows.rows where leaving.contains(row[rows.index("node_id")]) && row[rows.index("frontier")] != .integer(0) {
                rows.rows[rowid]![rows.index("frontier")] = .integer(0)
            }
            rows.insert(["node_id": context.resolved["op"] ?? .null, "knowledge_clock": .integer(clock), "frontier": .integer(1), "kind": .string("local")])
        }
        intent.tables["ntp_authors"] = { rows, context in
            rows.update(where: "author_id", is: .string(main)) { $0["next_seq"] = .integer(seq + 1); $0["last_op_id"] = context.resolved["op"] ?? .null }
        }
        intent.tables["ntp_library"] = { rows, _ in
            rows.update(where: "id", is: .integer(1)) {
                $0["next_install_seq"] = .integer(install + 1); $0["knowledge_clock"] = .integer(clock)
                $0["overlay_revision"] = .integer(($0["overlay_revision"]?.integer ?? 0) + Int64(overlays.count))
            }
        }
    }

    @Test func aServerLibraryThroughStagingRecoveryPublicationKeepAndRestore() async throws {
        let failures = try await Self.serverLife()
        #expect(failures.isEmpty, "\(failures)")
    }

    /// Server-library corruptions that fail its life by name, at the canonical check of the action that corrupts, while
    /// the derived data stays coherent: `corrupt_arrival_duration` sets each arriving episode's media duration to zero
    /// as its key is written (and the key's with it); `corrupt_duplicate_arrival` stores a second row of one arriving
    /// episode (an extra local ID, its counter advanced); `corrupt_drop_unrelated_outbox` deletes the second
    /// subscription's pending fact when an episode of the first is marked played (its counters equal that episode's
    /// ID); `corrupt_drop_old_facts` deletes every older pending fact when one is added; `corrupt_lose_server_identity`
    /// changes the account when a unit moves the cursor. At the favorite: `corrupt_other_authors` and
    /// `corrupt_change_other_author_tip` give registration authors a tip; `corrupt_frontier` sets every node's frontier
    /// to 2; `corrupt_drop_unrelated_frontier` takes another client's tip out of the frontier; `corrupt_overlay` and
    /// `corrupt_wrong_overlay` store the favorite overlay as false; `corrupt_stale_knowledge_clock` keeps the library's
    /// knowledge clock behind the fact's.
    static let serverMutations: [String: (sql: String, step: String, finding: String)] = [
        "corrupt_arrival_duration": ("""
            CREATE TRIGGER corrupt_arrival_insert AFTER INSERT ON episode_list_keys WHEN NEW.guid LIKE 'staged-%' AND NEW.duration = 600000 BEGIN
              UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '$.details.media.durationMilliseconds', 0) AS BLOB) WHERE id = NEW.id;
              UPDATE episode_list_keys SET duration = 0 WHERE id = NEW.id;
            END;
            CREATE TRIGGER corrupt_arrival_update AFTER UPDATE OF duration ON episode_list_keys WHEN NEW.guid LIKE 'staged-%' AND NEW.duration = 600000 BEGIN
              UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '$.details.media.durationMilliseconds', 0) AS BLOB) WHERE id = NEW.id;
              UPDATE episode_list_keys SET duration = 0 WHERE id = NEW.id;
            END;
            """, "direct unit", "durationMilliseconds"),
        "corrupt_duplicate_arrival": ("""
            CREATE TRIGGER corrupt_duplicate_arrival AFTER INSERT ON episodes WHEN NEW.id < 1000000 AND CAST(NEW.record AS TEXT) LIKE '%"identifier":"staged-4"%' BEGIN
              INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (NEW.id + 1000000, NEW.feed_id, NEW.pubdate, CAST(json_set(CAST(NEW.record AS TEXT), '$.id', NEW.id + 1000000) AS BLOB));
              UPDATE library_ids SET value = max(value, NEW.id + 1000000) WHERE kind = 'episode';
            END;
            """, "direct unit", "arrival staged-4: 2 new rows, expected 1"),
        "corrupt_drop_unrelated_outbox": ("""
            CREATE TRIGGER corrupt_drop_unrelated_outbox AFTER INSERT ON ntp_outbox WHEN NEW.type = 'episode.mark_played' BEGIN
              DELETE FROM ntp_outbox WHERE op_id IN (SELECT op_id FROM ntp_registrations WHERE feed_id = 2);
            END;
            """, "played", "ntp_outbox: expected rows missing"),
        "corrupt_drop_old_facts": ("""
            CREATE TRIGGER corrupt_drop_old_facts AFTER INSERT ON ntp_outbox BEGIN DELETE FROM ntp_outbox WHERE install_seq < NEW.install_seq; END;
            """, "favorite", "ntp_outbox: expected rows missing"),
        "corrupt_lose_server_identity": ("""
            CREATE TRIGGER corrupt_lose_server_identity AFTER UPDATE OF cursor ON ntp_library WHEN NEW.cursor IS NOT OLD.cursor BEGIN
              UPDATE ntp_library SET account_id = '00000000-0000-4000-8000-000000000099' WHERE id = NEW.id;
            END;
            """, "direct unit", "ntp_library: expected rows missing"),
        "corrupt_other_authors": ("""
            CREATE TRIGGER corrupt_other_authors AFTER UPDATE OF last_op_id ON ntp_authors WHEN NEW.role = 'main' BEGIN
              UPDATE ntp_authors SET last_op_id = '00000000-0000-4000-8000-000000000099' WHERE role = 'registration';
            END;
            """, "favorite", "ntp_authors: expected rows missing"),
        "corrupt_change_other_author_tip": ("""
            CREATE TRIGGER corrupt_change_other_author_tip AFTER UPDATE OF last_op_id ON ntp_authors
            WHEN NEW.author_id = (SELECT main_author FROM ntp_library WHERE id = 1) BEGIN
              UPDATE ntp_authors SET last_op_id = NEW.last_op_id WHERE author_id IN (SELECT author_id FROM ntp_registrations WHERE feed_id = 2);
            END;
            """, "favorite", "ntp_authors: expected rows missing"),
        "corrupt_frontier": ("""
            CREATE TRIGGER corrupt_frontier AFTER INSERT ON ntp_nodes WHEN NEW.kind = 'local' BEGIN UPDATE ntp_nodes SET frontier = 2; END;
            """, "favorite", "ntp_nodes: expected rows missing"),
        "corrupt_drop_unrelated_frontier": ("""
            CREATE TRIGGER corrupt_drop_unrelated_frontier AFTER INSERT ON ntp_nodes
            WHEN NEW.kind = 'local' AND EXISTS (SELECT 1 FROM ntp_outbox WHERE op_id = NEW.node_id AND type = 'favorite.set') BEGIN
              UPDATE ntp_nodes SET frontier = 0 WHERE node_id = '00000000-0000-4000-8000-000000000098';
            END;
            """, "favorite", "ntp_nodes: expected rows missing"),
        "corrupt_overlay": ("""
            CREATE TRIGGER corrupt_overlay AFTER INSERT ON ntp_overlays WHEN NEW.property = 'favorite' BEGIN
              UPDATE ntp_overlays SET value = CAST('false' AS BLOB) WHERE op_id = NEW.op_id AND property = NEW.property;
            END;
            """, "favorite", "ntp_overlays: expected rows missing"),
        "corrupt_wrong_overlay": ("""
            CREATE TRIGGER corrupt_wrong_overlay AFTER INSERT ON ntp_overlays
            WHEN NEW.property = 'favorite' AND EXISTS (SELECT 1 FROM ntp_outbox WHERE op_id = NEW.op_id AND type = 'favorite.set') BEGIN
              UPDATE ntp_overlays SET value = CAST('false' AS BLOB) WHERE op_id = NEW.op_id AND property = 'favorite';
            END;
            """, "favorite", "ntp_overlays: expected rows missing"),
        "corrupt_stale_knowledge_clock": ("""
            CREATE TRIGGER corrupt_stale_knowledge_clock AFTER UPDATE OF knowledge_clock ON ntp_library
            WHEN NEW.knowledge_clock > OLD.knowledge_clock AND (SELECT type FROM ntp_outbox ORDER BY install_seq DESC LIMIT 1) = 'favorite.set' BEGIN
              UPDATE ntp_library SET knowledge_clock = OLD.knowledge_clock WHERE id = 1;
            END;
            """, "favorite", "ntp_library: expected rows missing"),
    ]

    @Test(arguments: ["corrupt_arrival_duration", "corrupt_duplicate_arrival", "corrupt_drop_unrelated_outbox", "corrupt_drop_old_facts", "corrupt_lose_server_identity",
                      "corrupt_other_authors", "corrupt_change_other_author_tip", "corrupt_frontier", "corrupt_drop_unrelated_frontier", "corrupt_overlay",
                      "corrupt_wrong_overlay", "corrupt_stale_knowledge_clock"])
    func theServerLifeRejectsACorruption(_ name: String) async throws {
        let mutation = try #require(Self.serverMutations[name])
        let failures = try await Self.serverLife { url in try RawLibrary.execute(url, mutation.sql) }
        #expect(failures.count == 1 && failures[0].hasPrefix("\(mutation.step): canonical") && failures[0].contains(mutation.finding), "\(name): \(failures)")
        let failure = failures.first ?? ""
        print("MUTATION \(name): \(mutation.step): canonical …\(failure.range(of: mutation.finding).map { failure[$0.lowerBound...].prefix(260) } ?? failure.prefix(260))")
    }

    /// Fact and identity corruptions: an edit's fact or identity written wrong in a way the earlier resolver,
    /// which adopted the result's own values, accepted. Each is made right after its action (on the library's file, its
    /// hash recomputed, the overlay revision its diagnostic updates bump restored) and must be rejected at that action's
    /// canonical check by name: a wrong but well-formed wire ID, at the favorite and at the played mark (`e1:` and 64
    /// zeros; 64 `a`s and 64 `b`s), a malformed one at both, `on` and `reset_position` stored as the number 1,
    /// `type_version` as true, and an operation ID in uppercase (the fact's own, and fixed ones at both actions). (A
    /// finding is matched without its apostrophe, which the failure's array description escapes.)
    static let factCorruptions: [String: (step: String, finding: String)] = [
        "wrong_wire_favorite": ("favorite", "not its wire ID"), "wrong_wire_played": ("played", "not its wire ID"),
        "wrong_derived_wire_favorite": ("favorite", "not its wire ID"), "wrong_derived_wire_played": ("played", "not its wire ID"),
        "invalid_wire_favorite": ("favorite", "not its wire ID"), "invalid_wire_played": ("played", "not its wire ID"),
        "numeric_on": ("favorite", "the fact is not the action"), "numeric_reset": ("played", "the fact is not the action"),
        "boolean_version": ("favorite", "the fact is not the action"), "uppercase_op": ("favorite", "is not in the contract"),
        "uppercase_op_aa_favorite": ("favorite", "is not in the contract"), "uppercase_op_bb_played": ("played", "is not in the contract"),
    ]

    /// Corrupts the newest fact of the witness's action, as a faulty encoder or identity writer would have written it.
    static func corruptFact(_ name: String, step: String, url: URL) throws {
        let type = step == "played" ? "episode.mark_played" : "favorite.set"
        let row = try #require(try RawLibrary.rows(url, "SELECT op_id, lower(hex(fact)) FROM ntp_outbox WHERE type = '\(type)' ORDER BY install_seq DESC LIMIT 1").first)
        var op = try #require(row[0])
        let hex = try #require(row[1])
        let original = try ContractJSON.decode(try #require(ContractHex.decode(hex)))
        var fact = try #require(original.objectValue)
        var payload = try #require(fact["payload"]?.objectValue)
        let revision = try #require(try RawLibrary.rows(url, "SELECT overlay_revision FROM ntp_library WHERE id = 1").first?.first ?? nil)
        var statements: [(String, [LibrarySQLValue])] = []
        func replaceWire(_ new: String, wellFormed: Bool) throws {
            var episode = try #require(payload["episode"]?.objectValue)
            let old = try #require(episode["episode_id"]?.stringValue)
            let namespace = try #require(try RawLibrary.rows(url, "SELECT namespace FROM ntp_library WHERE id = 1").first?.first ?? nil)
            let podcast = try #require(episode["podcast_id"]?.stringValue), guid = try #require(episode["occurrence"]?["v"]?.stringValue)
            let derived = try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .rssGUID, value: guid)
            #expect(old == derived && new != old && ContractIdentity.isEpisodeID(new) == wellFormed, "\(name): \(old) was the derivation; \(new)")
            statements += [("UPDATE ntp_episodes SET episode_id = ? WHERE episode_id = ?", [.text(new), .text(old)]),
                           ("UPDATE ntp_overlays SET id = ? WHERE id = ? AND op_id = ?", [.text(new), .text(old), .text(op)])]
            episode["episode_id"] = .string(new)
            payload["episode"] = .object(episode)
            let targets = try #require(fact["targets"]?.arrayValue)
            fact["targets"] = .array(targets.map { target in
                guard var object = target.objectValue else { return target }
                object["id"] = .string(new)
                return .object(object)
            })
        }
        func replaceOp(_ new: String) {
            #expect(UUID(uuidString: new) != nil && !ContractIdentity.isUUID(new), "\(name): Foundation takes \(new), the contract does not")
            statements += [("UPDATE ntp_outbox SET op_id = ? WHERE op_id = ?", [.text(new), .text(op)]),
                           ("UPDATE ntp_nodes SET node_id = ? WHERE node_id = ?", [.text(new), .text(op)]),
                           ("UPDATE ntp_authors SET last_op_id = ? WHERE last_op_id = ?", [.text(new), .text(op)]),
                           ("UPDATE ntp_overlays SET op_id = ? WHERE op_id = ?", [.text(new), .text(op)])]
            fact["op_id"] = .string(new)
            op = new
        }
        switch name {
        case "wrong_wire_favorite", "wrong_wire_played": try replaceWire("e1:" + String(repeating: "0", count: 64), wellFormed: true)
        case "wrong_derived_wire_favorite": try replaceWire("e1:" + String(repeating: "a", count: 64), wellFormed: true)
        case "wrong_derived_wire_played": try replaceWire("e1:" + String(repeating: "b", count: 64), wellFormed: true)
        case "invalid_wire_favorite": try replaceWire("invalid-wire-favorite.set", wellFormed: false)
        case "invalid_wire_played": try replaceWire("invalid-wire-episode.mark_played", wellFormed: false)
        case "numeric_on", "numeric_reset":
            let key = name == "numeric_on" ? "on" : "reset_position"
            #expect(payload[key] == .bool(true), "\(name): written as true")
            payload[key] = .integer(1)
        case "boolean_version":
            #expect(fact["type_version"] == .integer(1), "\(name): written as 1")
            fact["type_version"] = .bool(true)
        case "uppercase_op": replaceOp(op.uppercased())
        case "uppercase_op_aa_favorite": replaceOp("00000000-0000-4000-8000-0000000000AA")
        case "uppercase_op_bb_played": replaceOp("00000000-0000-4000-8000-0000000000BB")
        default: Issue.record("unknown witness \(name)")
        }
        fact["payload"] = .object(payload)
        let bytes = try ContractJSON.object(fact).canonicalBytes()
        statements += [("UPDATE ntp_outbox SET fact = ?, content_hash = ? WHERE op_id = ?", [.blob(Data(bytes)), .text(ContractIdentity.sha256Hex(bytes)), .text(op)]),
                       ("UPDATE ntp_library SET overlay_revision = ? WHERE id = 1", [.integer(Int64(revision) ?? 0)])]
        try DerivedDataOracle.write(url, statements)
    }

    @Test(arguments: ["wrong_wire_favorite", "wrong_wire_played", "wrong_derived_wire_favorite", "wrong_derived_wire_played", "invalid_wire_favorite",
                      "invalid_wire_played", "numeric_on", "numeric_reset", "boolean_version", "uppercase_op", "uppercase_op_aa_favorite",
                      "uppercase_op_bb_played"])
    func theServerLifeRejectsAWrongFact(_ name: String) async throws {
        let witness = try #require(Self.factCorruptions[name])
        let failures = try await Self.serverLife(after: { label, url in if label == witness.step { try Self.corruptFact(name, step: label, url: url) } })
        #expect(failures.count == 1 && failures[0].hasPrefix("\(witness.step): canonical") && failures[0].contains(witness.finding), "\(name): \(failures)")
        let failure = failures.first ?? ""
        print("WITNESS \(name): \(witness.step): canonical …\(failure.range(of: witness.finding).map { failure[$0.lowerBound...].prefix(200) } ?? failure.prefix(200))")
    }
}

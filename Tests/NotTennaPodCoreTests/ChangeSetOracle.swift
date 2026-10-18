import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The capture oracle on every store the sync suites open (`ServerLibraryFixture`, `ExchangePhone`), when the run asks for
/// it (`NTP_CHANGE_ORACLE=1`): the existing sync scenarios (merges, recovery, Force full synchronization, staging, shown-
/// ahead rows, hidden removals, pin release, the exchange prefixes) then check every transaction they make against the
/// oracle, and report any difference when their store closes.
enum ChangeOracleRegistry {
    static let enabled = ProcessInfo.processInfo.environment["NTP_CHANGE_ORACLE"] != nil
    private static let lock = NSLock()
    nonisolated(unsafe) private static var oracles: [ObjectIdentifier: ChangeSetOracle] = [:]
    nonisolated(unsafe) private static var checked = 0

    static func install(_ store: FeedLibraryStore) async {
        guard enabled else { return }
        let oracle = ChangeSetOracle()
        lock.withLock { oracles[ObjectIdentifier(store)] = oracle }
        await store.installChangeOracleForTesting(oracle)
    }

    /// The oracle's verdict on `store`, recorded as an issue when it found a difference.
    static func verify(_ store: FeedLibraryStore, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard enabled, let oracle = lock.withLock({ oracles.removeValue(forKey: ObjectIdentifier(store)) }) else { return }
        lock.withLock { checked += oracle.transactions }
        if !oracle.mismatches.isEmpty {
            Issue.record("change oracle, \(label): \(oracle.mismatches.count) mismatches in \(oracle.transactions) transactions\n\(oracle.report)",
                         sourceLocation: sourceLocation)
        }
    }

    static var transactionsChecked: Int { lock.withLock { checked } }
}

/// The capture oracle: before and after every write transaction it reads the whole visible model with SQL of
/// its own and applies the visibility rules as PROTOCOL §6.8 and §15.4 and the screens state them (a pinned removal, a
/// hidden staging or removal, the server's pinned removal and an unrevealed episode are not shown), independently of the
/// capture's triggers and SQL. The difference, by the change-set contract, must equal the set the capture delivered:
/// no key missing, none extra, the right former feeds and queue links.
final class ChangeSetOracle: @unchecked Sendable {
    struct Image: Equatable { var feed: Int64?; var bytes: Data }

    struct Model: Equatable {
        /// Raw rows, for a semantic comparison (records as JSON values, whatever their bytes' key order).
        var feedRows: [Int64: (title: LibrarySQLValue, record: Data)] = [:]
        var episodeRows: [Int64: (pubdate: LibrarySQLValue, record: Data)] = [:]
        static func == (lhs: Model, rhs: Model) -> Bool {
            lhs.feeds == rhs.feeds && lhs.episodes == rhs.episodes && lhs.statistics == rhs.statistics && lhs.downloads == rhs.downloads
                && lhs.undo == rhs.undo && lhs.folders == rhs.folders && lhs.queue == rhs.queue
        }
        /// The model with feed and episode images built from their records' JSON values (key order and number spelling
        /// do not count): what a person can see.
        var semantic: Model { semantic(withoutTitles: false) }

        /// Each visible episode's statistics units, raw.
        var statisticsUnits: [Int64: Data] = [:]

        /// `withoutTitles`: titles left out, as the agreement tests leave them out (PROTOCOL §6.8: a title may follow this
        /// phone's own parse until the server's canonical metadata arrives).
        func semantic(withoutTitles: Bool) -> Model {
            var model = self
            func canonical(_ data: Data, strip: [[String]]) -> Data {
                guard var value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .mutableContainers]) else { return data }
                if withoutTitles, let object = value as? NSMutableDictionary {
                    for path in strip {
                        var node: NSMutableDictionary? = object
                        for key in path.dropLast() { node = node?[key] as? NSMutableDictionary }
                        node?.removeObject(forKey: path.last!)
                    }
                    value = object
                }
                return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? data
            }
            for (id, row) in feedRows where model.feeds[id] != nil {
                model.feeds[id] = Image(feed: nil, bytes: (withoutTitles ? Data() : ChangeSetOracle.bytes(row.title))
                                        + canonical(row.record, strip: [["metadata", "title"]]))
            }
            for (id, row) in episodeRows where model.episodes[id] != nil {
                model.episodes[id] = Image(feed: model.episodes[id]?.feed,
                                           bytes: ChangeSetOracle.bytes(row.pubdate) + canonical(row.record, strip: [["details", "title"]]))
            }
            return model
        }
        var feeds: [Int64: Image] = [:]
        var episodes: [Int64: Image] = [:]
        var statistics: [Int64: Image] = [:]
        var downloads: [Int64: Image] = [:]
        var undo: [Int64: Image] = [:]
        var folders: [Int64: Image] = [:]
        var queue: [Int64] = []
        /// The derived keys and counts (schema 21), raw by episode and by podcast, and whether they are complete (the lists
        /// read them only then). Model tables of relation `episode`: not part of the visible images above,
        /// whose sources they derive from; `derivedUncovered` checks every change of them is covered by the set.
        var derivedKeys: [Int64: (feed: Int64?, bytes: Data)] = [:]
        var derivedCounts: [Int64: Data] = [:]
        var derivedReady = false
    }

    struct Mismatch: CustomStringConvertible {
        var transaction: Int
        var label: String
        var expected: String
        var delivered: String
        var description: String { "#\(transaction) \(label): expected \(expected), delivered \(delivered)" }
    }

    private let lock = NSLock()
    private var before: Model?
    private(set) var transactions = 0
    private(set) var visibleTransactions = 0
    private(set) var mismatches: [Mismatch] = []
    /// Relations seen changing, for coverage.
    private(set) var coverage: [String: Int] = [:]
    private var statisticsCache: [Data: Data] = [:]
    var enabled = true

    func began(_ db: LibrarySQLite) throws {
        guard enabled else { return }
        before = try Self.read(db, cache: &statisticsCache)
    }

    func committed(_ db: LibrarySQLite, _ commit: LibraryCommit?) {
        guard enabled, let before else { return }
        self.before = nil
        do {
            let after = try Self.read(db, cache: &statisticsCache)
            let expected = Self.difference(before, after)
            let uncovered = Self.derivedUncovered(before, after, commit?.set)
            // The derived data equals what the records give, after every transaction (`LibrarySchema21.discrepancies`).
            let derived = after.derivedKeys.isEmpty && after.derivedCounts.isEmpty ? [] : try LibrarySchema21.discrepancies(db)
            lock.withLock {
                transactions += 1
                if !expected.isEmpty { visibleTransactions += 1 }
                for (name, count) in expected.counts where count > 0 { coverage[name, default: 0] += 1 }
                if Self.derivedChanged(before, after) { coverage["derived", default: 0] += 1 }
                compare(expected, commit?.set)
                if !uncovered.isEmpty {
                    mismatches.append(Mismatch(transaction: transactions, label: "derived", expected: uncovered.prefix(6).joined(separator: "; "),
                                               delivered: "\(String(describing: commit?.set))".prefix(400).description))
                }
                if !derived.isEmpty {
                    mismatches.append(Mismatch(transaction: transactions, label: "derived data", expected: "the records' derivation",
                                               delivered: derived.prefix(4).joined(separator: "; ")))
                }
            }
        } catch {
            lock.withLock { mismatches.append(Mismatch(transaction: transactions, label: "read", expected: "", delivered: "\(error)")) }
        }
    }

    var report: String { lock.withLock { mismatches.prefix(12).map(\.description).joined(separator: "\n") } }

    // MARK: - Reading the visible model

    static func read(_ db: LibrarySQLite, cache: inout [Data: Data]) throws -> Model {
        let tables = Set(try db.rows("SELECT name FROM main.sqlite_master WHERE type = 'table'").compactMap { $0[0].text })
        var hiddenFeeds = Set<Int64>(), marked = Set<Int64>()
        if tables.contains("pinned_feed_removals") {
            for row in try db.rows("SELECT feed_id FROM pinned_feed_removals") { if let id = row[0].integer { hiddenFeeds.insert(id) } }
        }
        if tables.contains("ntp_hidden_feeds") {
            for row in try db.rows("SELECT feed_id FROM ntp_hidden_feeds") { if let id = row[0].integer { hiddenFeeds.insert(id) } }
        }
        if tables.contains("ntp_podcasts") {
            for row in try db.rows("SELECT feed_id FROM ntp_podcasts WHERE pinned_removal = 1 AND feed_id IS NOT NULL") {
                if let id = row[0].integer { hiddenFeeds.insert(id) }
            }
        }
        if tables.contains("ntp_hidden_episodes") {
            for row in try db.rows("SELECT episode_id FROM ntp_hidden_episodes") { if let id = row[0].integer { marked.insert(id) } }
        }
        var model = Model()
        for row in try db.rows("SELECT id, title, record FROM feeds") {
            guard let id = row[0].integer, !hiddenFeeds.contains(id) else { continue }
            model.feeds[id] = Image(feed: nil, bytes: bytes(row[1]) + bytes(row[2]))
            model.feedRows[id] = (row[1], row[2].data ?? Data())
        }
        var units: [Int64: Data] = [:]
        for row in try db.rows("SELECT episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position FROM statistics_units ORDER BY episode_id, unit_id") {
            guard let id = row[0].integer else { continue }
            units[id, default: Data()] += row.dropFirst().reduce(Data()) { $0 + bytes($1) }
        }
        var visible: [Int64: Int64] = [:]
        for row in try db.rows("SELECT id, feed_id, pubdate, record FROM episodes") {
            guard let id = row[0].integer, let feed = row[1].integer, !hiddenFeeds.contains(feed), !marked.contains(id),
                  model.feeds[feed] != nil else { continue }
            visible[id] = feed
            let record = row[3].data ?? Data()
            model.episodes[id] = Image(feed: feed, bytes: bytes(row[2]) + record)
            model.episodeRows[id] = (row[2], record)
            let fields: Data
            if let cached = cache[record] { fields = cached } else {
                fields = statisticsFields(record)
                cache[record] = fields
            }
            model.statistics[id] = Image(feed: feed, bytes: fields + (units[id] ?? Data()))
            if let own = units[id] { model.statisticsUnits[id] = own }
        }
        var jobs: [Int64: Data] = [:]
        for row in try db.rows("SELECT episode_id, id, source, record FROM download_jobs WHERE active = 1 ORDER BY episode_id, id") {
            guard let id = row[0].integer else { continue }
            jobs[id, default: Data()] += bytes(row[1]) + bytes(row[2]) + bytes(row[3])
        }
        for (id, image) in jobs { if let feed = visible[id] { model.downloads[id] = Image(feed: feed, bytes: image) } }
        for row in try db.rows("SELECT episode_id, operation_id FROM episode_swipe_undo") {
            guard let id = row[0].integer, let feed = visible[id] else { continue }
            model.undo[id] = Image(feed: feed, bytes: bytes(row[1]))
        }
        for row in try db.rows("SELECT feed_id, record FROM local_folder_links") {
            guard let id = row[0].integer, model.feeds[id] != nil else { continue }
            model.folders[id] = Image(feed: nil, bytes: bytes(row[1]))
        }
        model.queue = try db.rows("SELECT episode_id FROM queue ORDER BY position").compactMap { $0[0].integer }.filter { visible[$0] != nil }
        if tables.contains("episode_list_keys"), tables.contains("feed_list_counts"), tables.contains("derived_fill") {
            model.derivedReady = try db.scalar("SELECT EXISTS (SELECT 1 FROM derived_fill)") == 0
            for row in try db.rows("SELECT * FROM episode_list_keys") {
                guard let id = row[0].integer else { continue }
                model.derivedKeys[id] = (row[1].integer, row.reduce(Data()) { $0 + bytes($1) })
            }
            for row in try db.rows("SELECT * FROM feed_list_counts") {
                guard let id = row[0].integer else { continue }
                model.derivedCounts[id] = row.reduce(Data()) { $0 + bytes($1) }
            }
        }
        return model
    }

    /// Whether a transaction changed any derived key or counts row of what is shown, once they are complete.
    static func derivedChanged(_ before: Model, _ after: Model) -> Bool {
        guard before.derivedReady, after.derivedReady else { return false }
        if before.derivedCounts != after.derivedCounts { return true }
        return Set(before.derivedKeys.keys).union(after.derivedKeys.keys).contains { before.derivedKeys[$0]?.bytes != after.derivedKeys[$0]?.bytes }
    }

    /// The derived keys and counts a transaction changed that its set does not cover, once they are complete. A key row of
    /// an episode shown before or after must belong to an episode the set names, or to a podcast it names (a podcast's
    /// change carries its episodes); a counts row of a podcast shown before or after, to a podcast the set names or one an
    /// episode it names belongs or belonged to. Rows of what is not shown (staged, hidden) are no visible change.
    static func derivedUncovered(_ before: Model, _ after: Model, _ set: LibraryChangeSet?) -> [String] {
        guard before.derivedReady, after.derivedReady else { return [] }
        let feeds = Set(set.map { Array($0.feeds.keys) } ?? [])
        let episodes = set?.episodes ?? [:]
        var episodeFeeds = Set<Int64>()
        for change in episodes.values { if let feed = change.feed { episodeFeeds.insert(feed) }; if let former = change.formerFeed { episodeFeeds.insert(former) } }
        var found: [String] = []
        for id in Set(before.derivedKeys.keys).union(after.derivedKeys.keys) {
            let old = before.derivedKeys[id], new = after.derivedKeys[id]
            guard old?.bytes != new?.bytes, before.episodes[id] != nil || after.episodes[id] != nil else { continue }
            if episodes[id] != nil { continue }
            if let feed = old?.feed, feeds.contains(feed) { continue }
            if let feed = new?.feed, feeds.contains(feed) { continue }
            found.append("the key row of episode \(id) changed")
        }
        for id in Set(before.derivedCounts.keys).union(after.derivedCounts.keys) where before.derivedCounts[id] != after.derivedCounts[id] {
            guard before.feeds[id] != nil || after.feeds[id] != nil, !feeds.contains(id), !episodeFeeds.contains(id) else { continue }
            found.append("the counts of podcast \(id) changed")
        }
        return found.sorted()
    }

    static func bytes(_ value: LibrarySQLValue) -> Data {
        switch value {
        case .integer(let number): Data("i\(number);".utf8)
        case .real(let number): Data("r\(number.bitPattern);".utf8)
        case .text(let text): Data("t\(text.utf8.count):".utf8) + Data(text.utf8)
        case .blob(let data): Data("b\(data.count):".utf8) + data
        case .null: Data("n;".utf8)
        }
    }

    /// What `LibraryStatistics` reads of an episode, from the decoded record (its bytes when it cannot be decoded).
    static func statisticsFields(_ record: Data) -> Data {
        guard let episode = try? JSONDecoder().decode(LibraryEpisode.self, from: record) else { return Data("raw:".utf8) + record }
        let state = episode.userState, media = episode.details.media
        let fields: [String] = [
            "\(state.playState.rawValue)", "\(state.positionMilliseconds > 0)", "\(state.playedDurationMilliseconds)",
            "\(state.lastPlayedTimeMilliseconds)", "\(state.lastPlayedHistoryMilliseconds.map(String.init) ?? "-")",
            "\(state.downloadDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0)",
            "\(episode.details.publicationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0)",
            "\(media != nil)", "\(media?.durationMilliseconds ?? 0)", "\(media?.size ?? 0)",
        ]
        return Data(fields.joined(separator: "|").utf8)
    }

    // MARK: - The expected set

    struct Expected {
        var feeds: [Int64: LibraryChangeSet.Change] = [:]
        var folders: [Int64: LibraryChangeSet.Change] = [:]
        var episodes: [Int64: LibraryChangeSet.EpisodeChange] = [:]
        var statistics: [Int64: LibraryChangeSet.EpisodeChange] = [:]
        var downloads: [Int64: LibraryChangeSet.EpisodeChange] = [:]
        var undo: [Int64: LibraryChangeSet.EpisodeChange] = [:]
        var queue = LibraryChangeSet.QueueChange()
        var isEmpty: Bool {
            feeds.isEmpty && folders.isEmpty && episodes.isEmpty && statistics.isEmpty && downloads.isEmpty && undo.isEmpty && queue.isEmpty
        }
        var counts: [String: Int] {
            ["feed": feeds.count, "folder": folders.count, "episode": episodes.count, "statistics": statistics.count,
             "download": downloads.count, "undo": undo.count, "queue": queue.added.count + queue.removed.count + queue.relinked.count]
        }
    }

    static func difference(_ before: Model, _ after: Model) -> Expected {
        var expected = Expected()
        func keyed(_ a: [Int64: Image], _ b: [Int64: Image]) -> [Int64: LibraryChangeSet.Change] {
            var result: [Int64: LibraryChangeSet.Change] = [:]
            for key in Set(a.keys).union(b.keys) {
                switch (a[key], b[key]) {
                case (nil, _?): result[key] = .added
                case (_?, nil): result[key] = .removed
                case (let x?, let y?) where x != y: result[key] = .changed
                default: break
                }
            }
            return result
        }
        expected.feeds = keyed(before.feeds, after.feeds)
        // A feed entering or leaving the visible model carries its own keys (the contract).
        for (key, change) in keyed(before.folders, after.folders) where expected.feeds[key] != change || change == .changed {
            expected.folders[key] = change
        }
        func episodes(_ a: [Int64: Image], _ b: [Int64: Image]) -> [Int64: LibraryChangeSet.EpisodeChange] {
            var result: [Int64: LibraryChangeSet.EpisodeChange] = [:]
            for key in Set(a.keys).union(b.keys) {
                switch (a[key], b[key]) {
                case (nil, let y?):
                    if expected.feeds[y.feed ?? -1] != .added { result[key] = .init(change: .added, feed: y.feed) }
                case (let x?, nil):
                    if expected.feeds[x.feed ?? -1] != .removed { result[key] = .init(change: .removed, feed: x.feed) }
                case (let x?, let y?) where x != y:
                    result[key] = .init(change: .changed, feed: y.feed, formerFeed: x.feed != y.feed ? x.feed : nil)
                default: break
                }
            }
            return result
        }
        expected.episodes = episodes(before.episodes, after.episodes)
        expected.statistics = episodes(before.statistics, after.statistics)
        expected.downloads = episodes(before.downloads, after.downloads)
        expected.undo = episodes(before.undo, after.undo)
        // The queue: members added and removed, and members whose predecessor in the whole visible order changed.
        if before.queue != after.queue {
            let old = Set(before.queue), new = Set(after.queue)
            expected.queue.added = new.subtracting(old)
            expected.queue.removed = old.subtracting(new)
            var previous: [Int64: Int64] = [:]
            for index in before.queue.indices { previous[before.queue[index]] = index == 0 ? -1 : before.queue[index - 1] }
            for index in after.queue.indices where old.contains(after.queue[index]) {
                let now = index == 0 ? -1 : after.queue[index - 1]
                if previous[after.queue[index]] != now { expected.queue.relinked.insert(after.queue[index]) }
            }
        }
        return expected
    }

    private func compare(_ expected: Expected, _ delivered: LibraryChangeSet?) {
        func note(_ label: String, _ want: Any, _ got: Any) {
            mismatches.append(Mismatch(transaction: transactions, label: label, expected: "\(want)", delivered: "\(got)"))
        }
        let set = delivered
        if expected.isEmpty {
            if let set, !set.isEmpty { note("empty", "nothing", set) }
            return
        }
        guard let set else { return note("missing", expected, "nothing") }
        if set.feeds != expected.feeds { note("feeds", expected.feeds, set.feeds) }
        if set.localFolders != expected.folders { note("folders", expected.folders, set.localFolders) }
        if set.episodes != expected.episodes { note("episodes", expected.episodes, set.episodes) }
        if set.statistics != expected.statistics { note("statistics", expected.statistics, set.statistics) }
        if set.downloads != expected.downloads { note("downloads", expected.downloads, set.downloads) }
        if set.undo != expected.undo { note("undo", expected.undo, set.undo) }
        if (set.queue ?? .init()) != expected.queue { note("queue", expected.queue, set.queue ?? .init()) }
    }
}

/// Every commit a store's connection delivered, for tests.
final class CommitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LibraryCommit] = []
    func append(_ commit: LibraryCommit) { lock.withLock { entries.append(commit) } }
    var commits: [LibraryCommit] { lock.withLock { entries } }
    var sets: [LibraryChangeSet] { commits.compactMap(\.set) }
    func removeAll() { lock.withLock { entries.removeAll() } }
    /// The union of the visible sets delivered since the last `take`.
    func take() -> (set: LibraryChangeSet?, knowledge: LibraryPositionKnowledge?, commits: [LibraryCommit]) {
        lock.withLock {
            defer { entries.removeAll() }
            var set: LibraryChangeSet?, knowledge: LibraryPositionKnowledge?
            for entry in entries {
                if let next = entry.set { set = set.map { $0.union(next) } ?? next }
                if let next = entry.knowledge { knowledge = knowledge.map { $0.union(next) } ?? next }
            }
            return (set, knowledge, entries)
        }
    }
}

extension FeedLibraryStore {
    /// Runs the capture oracle before and after every write transaction of this store's connection.
    func installChangeOracleForTesting(_ oracle: ChangeSetOracle) {
        database.writeBegan = { db in try oracle.began(db) }
        database.writeCommitted = { db, commit in oracle.committed(db, commit) }
    }

    func removeChangeOracleForTesting() {
        database.writeBegan = nil
        database.writeCommitted = nil
    }

    /// Records every commit the connection delivers (also those the hub does not see: knowledge-only ones).
    func recordCommitsForTesting() -> CommitLog {
        let log = CommitLog()
        let previous = database.onCommit
        database.onCommit = { commit in
            previous?(commit)
            log.append(commit)
        }
        return log
    }

    /// Installs the capture again with test faults (mutation checks).
    func setChangeCaptureFaultsForTesting(_ faults: Set<LibraryChangeCapture.Fault>) throws {
        try database.enableChangeCapture(faults: faults)
    }

    /// The capture's digest inputs so far (its own work budget).
    func captureDigestInputsForTesting() -> Int64 { database.capture?.counter.inputs ?? 0 }
    func captureDrainRowsForTesting() -> Int64 { database.capture?.drainRows ?? 0 }
    func databaseForTesting<T>(_ body: (LibrarySQLite) throws -> T) rethrows -> T { try body(database) }
}

import Foundation
import Synchronization

/// A read-only connection to the open library for screen reads (schema 21): every call is one read transaction that sees
/// only committed data and never holds the store actor. A graph has two (`LibraryReaders`): `quick` for keyed reads,
/// `bulk` for opens, search and statistics, so a long scan never delays a keyed read.
///
/// Requests carry a token; `interrupt(_:)` cancels only that token's request: a running one is interrupted and rolls
/// back, one not yet started is cancelled before it begins, and either throws `CancellationError`. The derived keys and
/// counts are read only once the background fill is complete (`Failure.derivedDataNotReady` before, checked in the same
/// read transaction).
public actor LibraryReader {
    public enum Role: String, Sendable { case quick, bulk }

    public struct Token: Hashable, Sendable {
        let id = UUID()
        public init() {}
    }

    public enum Failure: Error, Equatable, Sendable {
        case derivedDataNotReady
    }

    /// What this reader did (all its calls, all builds): read transactions, rows, records decoded and their bytes, and
    /// SQLite's virtual-machine steps and page-cache lookups.
    public struct Metrics: Equatable, Sendable {
        public var readTransactions = 0
        public var keyRows = 0
        public var countRows = 0
        public var recordRows = 0
        public var recordsDecoded = 0
        public var bytesDecoded = 0
        public var statementSteps: Int64 = 0
        public var pagesFetched: Int64 = 0
    }

    public nonisolated let role: Role
    private var connection: LibrarySQLite?
    private let control = Control()
    public internal(set) var metrics = Metrics()

    final class Control: Sendable {
        struct State: ~Copyable {
            var running: Token?
            var cancelled: Set<Token> = []
            var closed = false
            var interrupter: Interrupter?
        }
        let state = Mutex(State())

        /// The running request is cancelled, or the reader is closing.
        func isCancelled() -> Bool {
            state.withLock { state in state.running != nil && (state.closed || state.cancelled.contains(state.running!)) }
        }
    }

    /// `sqlite3_interrupt` for the connection, only ever called under the control lock while the connection is open.
    final class Interrupter: @unchecked Sendable {
        private let connection: LibrarySQLite
        init(_ connection: LibrarySQLite) { self.connection = connection }
        func interrupt() { connection.interrupt() }
    }

    init(url: URL, role: Role) throws {
        self.role = role
        let connection = try LibrarySQLite(readingOnly: url)
        do {
            let version = try connection.scalar("PRAGMA user_version")
            guard version >= 21 else { throw FeedLibraryError.unsupportedSchema(version) }
        } catch {
            try? connection.close()
            throw error
        }
        // Weak: the control owns the connection (through its interrupter), and the connection's check must not own it
        // back, or neither would ever be freed.
        let control = control
        connection.interruptRequested = { [weak control] in control?.isCancelled() ?? true }
        control.state.withLock { $0.interrupter = Interrupter(connection) }
        self.connection = connection
    }

    // MARK: - Lifecycle

    /// Cancels only `token`'s request: interrupted while it runs, refused if it has not begun.
    public nonisolated func interrupt(_ token: Token) {
        control.state.withLock { state in
            state.cancelled.insert(token)
            if state.running == token { state.interrupter?.interrupt() }
        }
    }

    /// From now on nothing new runs; a running request is interrupted. Synchronous, for a store closing.
    nonisolated func shutdown() {
        control.state.withLock { state in
            state.closed = true
            if state.running != nil { state.interrupter?.interrupt() }
        }
    }

    /// Interrupts whatever runs (at once, before waiting for the actor) and closes the connection once the request
    /// running now has ended.
    public nonisolated func close() async {
        shutdown()
        await closeConnection()
    }

    private func closeConnection() {
        control.state.withLock { $0.interrupter = nil }
        try? connection?.close()
        connection = nil
    }

    /// Tests: the control, to observe that it is freed with its reader.
    nonisolated var controlForTesting: AnyObject { control }

    public var isClosed: Bool { connection == nil }

    /// Whether `token`'s request is running now (tests wait for it).
    nonisolated func isRunning(_ token: Token) -> Bool { control.state.withLock { $0.running == token } }

    // MARK: - Requests

    private enum RequestStart { case run, closed, cancelled }

    /// One read transaction. Internal: the screens' requests are built on it.
    func read<T>(token: Token? = nil, _ body: (LibrarySQLite) throws -> T) throws -> T {
        let token = token ?? Token()
        guard let connection else { throw FeedLibraryError.closed }
        let begin: RequestStart = control.state.withLock { state in
            if state.closed { return .closed }
            if state.cancelled.remove(token) != nil { return .cancelled }
            state.running = token
            return .run
        }
        switch begin {
        case .closed: throw FeedLibraryError.closed
        case .cancelled: throw CancellationError()
        case .run: break
        }
        defer { control.state.withLock { state in state.running = nil; state.cancelled.remove(token) } }
        let steps = connection.statementSteps, pages = connection.pageLookups
        defer {
            metrics.readTransactions += 1
            metrics.statementSteps += connection.statementSteps - steps
            metrics.pagesFetched += connection.pageLookups - pages
        }
        do {
            let result = try connection.transaction(write: false) { try body(connection) }
            if control.state.withLock({ $0.cancelled.contains(token) }) { throw CancellationError() }
            return result
        } catch FeedLibraryError.sqlite(let code, _) where code & 0xff == 9 /* SQLITE_INTERRUPT */ {
            throw control.state.withLock({ $0.cancelled.contains(token) || $0.closed }) ? CancellationError() : FeedLibraryError.closed
        }
    }

    /// Whether the background fill is complete in this reader's snapshot.
    public func derivedReady(token: Token? = nil) throws -> Bool {
        try read(token: token) { try Self.isReady($0) }
    }

    private static func isReady(_ database: LibrarySQLite) throws -> Bool { try LibrarySchema21.isComplete(database) }

    private static func requireReady(_ database: LibrarySQLite) throws {
        guard try isReady(database) else { throw Failure.derivedDataNotReady }
    }

    /// The list keys of `ids` (hidden ones included, flagged), in the order given; IDs with no episode are left out.
    public func keys(ids: [Int64], token: Token? = nil) throws -> [EpisodeListKeys] {
        let found: [Int64: EpisodeListKeys] = try read(token: token) { database in
            try Self.requireReady(database)
            var found: [Int64: EpisodeListKeys] = [:]
            for chunk in Self.chunks(ids) {
                for row in try database.rows("SELECT \(Self.keyList) FROM episode_list_keys WHERE id IN (SELECT value FROM json_each(?))", [.text(chunk)]) {
                    let keys = try EpisodeListKeys(row: row)
                    found[keys.id] = keys
                }
            }
            return found
        }
        metrics.keyRows += found.count
        return ids.compactMap { found[$0] }
    }

    /// The list keys of one feed's episodes (hidden ones included, flagged), newest first, equal dates by ID.
    public func keys(feed: Int64, token: Token? = nil) throws -> [EpisodeListKeys] {
        let keys = try read(token: token) { database in
            try Self.requireReady(database)
            return try database.rows("SELECT \(Self.keyList) FROM episode_list_keys WHERE feed_id = ? ORDER BY pub_ms DESC, id", [.integer(feed)])
                .map(EpisodeListKeys.init(row:))
        }
        metrics.keyRows += keys.count
        return keys
    }

    /// The visible counts of `feeds` (every feed when nil) that lists show: a pinned removal or a hidden podcast has none.
    /// A shown feed with no episodes has zero counts.
    public func counts(feeds: [Int64]? = nil, token: Token? = nil) throws -> [Int64: FeedListCounts] {
        let counts: [Int64: FeedListCounts] = try read(token: token) { database in
            try Self.requireReady(database)
            let columns = "c.feed_id, " + LibrarySchema21.countColumns.map { "c.\($0)" }.joined(separator: ", ")
            var result: [Int64: FeedListCounts] = [:]
            let shown = Self.listedFeedCondition("f.id")
            func add(_ rows: [[LibrarySQLValue]]) throws { for row in rows { let value = try FeedListCounts(row: row); result[value.feedID] = value } }
            if let feeds {
                for chunk in Self.chunks(feeds) {
                    try add(database.rows("SELECT \(columns) FROM feed_list_counts c JOIN feeds f ON f.id = c.feed_id WHERE c.feed_id IN (SELECT value FROM json_each(?)) AND \(shown)", [.text(chunk)]))
                    for row in try database.rows("SELECT f.id FROM feeds f WHERE f.id IN (SELECT value FROM json_each(?)) AND \(shown)", [.text(chunk)]) {
                        if let id = row[0].integer, result[id] == nil { result[id] = FeedListCounts(feedID: id) }
                    }
                }
            } else {
                try add(database.rows("SELECT \(columns) FROM feed_list_counts c JOIN feeds f ON f.id = c.feed_id WHERE \(shown)"))
                for row in try database.rows("SELECT f.id FROM feeds f WHERE \(shown)") {
                    if let id = row[0].integer, result[id] == nil { result[id] = FeedListCounts(feedID: id) }
                }
            }
            return result
        }
        metrics.countRows += counts.count
        return counts
    }

    /// The headers (no episodes) of the feeds lists show, title order (`FeedLibraryStore.feeds()`'s order).
    public func listFeedHeaders(token: Token? = nil) throws -> [LibraryFeed] {
        try read(token: token) { database in
            try database.rows(Self.listFeedHeadersStatement()).map { try decodeHeader($0[0]) }
        }
    }

    /// The episodes of `ids` that lists show (not staged hidden, of a feed lists show), in the order given.
    public func listEpisodes(ids: [Int64], token: Token? = nil) throws -> [LibraryEpisode] {
        let found: [Int64: LibraryEpisode] = try read(token: token) { database in
            var found: [Int64: LibraryEpisode] = [:]
            for chunk in Self.chunks(ids) {
                for row in try database.rows(Self.listEpisodesStatement(), [.text(chunk)]) {
                    let episode: LibraryEpisode = try decode(row[0])
                    found[episode.id] = episode
                }
            }
            return found
        }
        return ids.compactMap { found[$0] }
    }

    /// The player's podcast, also while it is a pinned removal or hidden (`FeedLibraryStore.playbackFeed`): never for lists.
    public func playerFeedHeader(id: Int64, token: Token? = nil) throws -> LibraryFeed? {
        try read(token: token) { database in
            try database.rows("SELECT record FROM feeds WHERE id = ?", [.integer(id)]).first.map { try decodeHeader($0[0]) }
        }
    }

    /// The player's episode, whatever its podcast's visibility (`FeedLibraryStore.episode(id:)`): never for lists.
    public func playerEpisode(id: Int64, token: Token? = nil) throws -> LibraryEpisode? {
        try read(token: token) { database in
            try database.rows("SELECT record FROM episodes WHERE id = ?", [.integer(id)]).first.map { try decode($0[0]) }
        }
    }

    // MARK: - Helpers

    /// A record stored as a BLOB or produced as TEXT by a JSON function (`json_remove`).
    func decode<T: Decodable>(_ value: LibrarySQLValue) throws -> T {
        guard let data = value.recordData else { throw FeedLibraryError.corruptRecord }
        metrics.recordRows += 1
        metrics.recordsDecoded += 1
        metrics.bytesDecoded += data.count
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Tests: `decode` from outside the actor.
    func decodeForTesting<T: Decodable & Sendable>(_ value: LibrarySQLValue) throws -> T { try decode(value) }

    private func decodeHeader(_ value: LibrarySQLValue) throws -> LibraryFeed {
        let feed: LibraryFeed = try decode(value)
        guard feed.episodes.isEmpty, feed.metadata.episodes.isEmpty else { throw FeedLibraryError.corruptRecord }
        return feed
    }

    private static let keyList = LibrarySchema21.keyColumns.joined(separator: ", ")

    /// A feed lists show: not a pinned removal, not hidden, not the server's pinned removal (`hiddenFeedsCondition`). Each
    /// source is probed by the feed's own key, so a keyed read never scans the podcast mappings.
    static func listedFeedCondition(_ column: String) -> String {
        "NOT EXISTS (SELECT 1 FROM pinned_feed_removals WHERE feed_id = \(column))"
            + " AND NOT EXISTS (SELECT 1 FROM ntp_hidden_feeds WHERE feed_id = \(column))"
            + " AND NOT EXISTS (SELECT 1 FROM ntp_podcasts p WHERE p.feed_id = \(column) AND p.pinned_removal = 1)"
    }

    /// The list reads' statements, built from a feed visibility condition (production: `listedFeedCondition`).
    static func listEpisodesStatement(_ shown: (String) -> String = listedFeedCondition) -> String {
        "SELECT e.record FROM episodes e WHERE e.id IN (SELECT value FROM json_each(?)) AND NOT EXISTS (SELECT 1 FROM ntp_hidden_episodes h WHERE h.episode_id = e.id) AND \(shown("e.feed_id"))"
    }
    static func listFeedHeadersStatement(_ shown: (String) -> String = listedFeedCondition) -> String {
        "SELECT f.record FROM feeds f WHERE \(shown("f.id")) ORDER BY f.title COLLATE NOCASE ASC, f.id"
    }

    static func chunks(_ ids: [Int64]) -> [String] {
        stride(from: 0, to: ids.count, by: 500).map { start in
            ContractJSON.array(ids[start..<min(ids.count, start + 500)].map(ContractJSON.integer)).canonicalText
        }
    }
}

/// The readers of a graph's library. Closed before the store and before any Keep, switch, import or restore moves
/// files (`FeedLibraryStore.closeReaders`).
public final class LibraryReaders: Sendable {
    public let quick: LibraryReader
    public let bulk: LibraryReader
    /// The main thread's keyed reads of what the screens' library leaves out (`LibraryDetailReader`).
    public let detail: LibraryDetailReader

    init(url: URL) throws {
        let quick = try LibraryReader(url: url, role: .quick)
        let bulk: LibraryReader
        do { bulk = try LibraryReader(url: url, role: .bulk) } catch {
            // The set is not made: the first reader's connection closes as it is freed.
            quick.shutdown()
            throw error
        }
        do { detail = try LibraryDetailReader(url: url) } catch {
            quick.shutdown(); bulk.shutdown()
            throw error
        }
        self.quick = quick
        self.bulk = bulk
    }

    nonisolated func shutdown() { quick.shutdown(); bulk.shutdown(); detail.close() }

    /// Interrupts the readers at once, then closes each once its running request has ended.
    public func close() async {
        shutdown()
        await quick.close()
        await bulk.close()
    }
}

/// A read-only connection for keyed reads the screens make synchronously: the screens' library holds each
/// episode as lists show it (`LibraryEpisode.listProjection`), and an episode's page reads its show notes and chapters
/// here, as a search reads whether a few changed episodes match. Each read is one keyed statement; nothing else uses the
/// connection, so a read never waits for another. Closed with the other readers; a read after that returns nothing.
public final class LibraryDetailReader: @unchecked Sendable {
    /// Guarded by `lock`: every use of the connection holds it.
    private var connection: LibrarySQLite?
    private let lock = NSLock()
    /// Reads made, for tests.
    public private(set) var reads = 0

    init(url: URL) throws {
        connection = try LibrarySQLite(readingOnly: url)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? connection?.close()
        connection = nil
    }

    private func read<T>(_ body: (LibrarySQLite) throws -> T) throws -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let connection else { return nil }
        reads += 1
        return try connection.transaction(write: false) { try body(connection) }
    }

    /// The stored episode (show notes and chapters included), whatever its podcast's visibility.
    public func episode(id: Int64) throws -> LibraryEpisode? {
        try read { database -> LibraryEpisode? in
            guard let row = try database.rows("SELECT record FROM episodes WHERE id = ?", [.integer(id)]).first,
                  let data = row[0].recordData else { return nil }
            let episode = try JSONDecoder.libraryRecord(LibraryEpisode.self, from: data)
            guard episode.id == id else { throw FeedLibraryError.corruptRecord }
            return episode
        } ?? nil
    }

    /// Of `ids`, the episodes whose title or show notes contain every word, as SQLite's `LIKE` compares
    /// (`FeedLibraryStore.search`).
    public func episodes(_ ids: Set<Int64>, matching words: [String]) throws -> Set<Int64> {
        guard !ids.isEmpty, !words.isEmpty else { return [] }
        return try read { database -> Set<Int64> in
            var found: Set<Int64> = []
            for chunk in LibraryReader.chunks(ids.sorted()) {
                let (condition, values) = LibraryReader.searchCondition(words, prefilter: false)
                for row in try database.rows("SELECT e.id FROM episodes e WHERE e.id IN (SELECT value FROM json_each(?)) AND \(condition)",
                                             [.text(chunk)] + values) {
                    if let id = row[0].integer { found.insert(id) }
                }
            }
            return found
        } ?? []
    }
}

extension LibraryReader {
    /// Characters a word must not contain to be looked for in a record's raw text: those a JSON encoder may escape, and
    /// `LIKE`'s wildcards (one of which could stand for an escaped character).
    static let unfilteredBytes: Set<UInt8> = Set("\"\\/<>&'%_".utf8)

    /// The episode search's text condition over `e` (`FeedLibraryStore.search`): every word in the title or the show
    /// notes. `prefilter`: each word made only of printable ASCII a record never escapes (`unfilteredBytes`) is first
    /// looked for in the record's raw text, which costs no JSON parse; the exact condition follows.
    static func searchCondition(_ words: [String], prefilter: Bool) -> (String, [LibrarySQLValue]) {
        var conditions: [String] = [], values: [LibrarySQLValue] = []
        let record = "CAST(e.record AS TEXT)"
        for word in words {
            if prefilter, word.utf8.allSatisfy({ (0x20...0x7e).contains($0) && !Self.unfilteredBytes.contains($0) }) {
                conditions.append("\(record) LIKE ?"); values.append(.text("%\(word)%"))
            }
            conditions.append("(json_extract(\(record), '$.details.title') LIKE ? OR json_extract(\(record), '$.details.description') LIKE ?)")
            values += [.text("%\(word)%"), .text("%\(word)%")]
        }
        return (conditions.joined(separator: " AND "), values)
    }

    /// Every episode whose title or show notes contain every word (`FeedLibraryStore.search`'s text condition), with its
    /// stored `pubdate`, of podcast `feedID` or of any podcast: a new search query's scan. The caller keeps those the
    /// screens show. `token`: the query's, which interrupts the scan when the query is cancelled.
    public func searchMatches(words: [String], feedID: Int64? = nil, token: Token? = nil) throws -> [(id: Int64, pubdate: Int64)] {
        guard !words.isEmpty else { return [] }
        var (condition, values) = Self.searchCondition(words, prefilter: true)
        if let feedID { condition = "e.feed_id = ? AND " + condition; values.insert(.integer(feedID), at: 0) }
        return try read(token: token) { database in
            try database.rows("SELECT e.id, e.pubdate FROM episodes e WHERE \(condition)", values).compactMap { row in
                guard let id = row[0].integer, let pubdate = row[1].integer else { return nil }
                return (id, pubdate)
            }
        }
    }
}

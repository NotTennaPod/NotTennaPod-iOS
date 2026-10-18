import Foundation

/// What a screen patch reads to bring the screens' library up to date after committed change sets: the current state of
/// exactly the feeds, episodes, statistics units, folder links and queue the sets named, all from one read transaction,
/// stamped with the commit sequence that transaction sees.
public struct LibraryMirrorRequest: Equatable, Sendable {
    /// Feeds whose header is read again.
    public var feeds: Set<Int64> = []
    /// Feeds read whole (header and every visible episode): one that entered or left the screens, or that changed
    /// visibility, so its episodes were not listed one by one.
    public var resetFeeds: Set<Int64> = []
    /// Episodes whose record is read again.
    public var episodes: Set<Int64> = []
    /// Episodes whose statistics units are read again.
    public var statistics: Set<Int64> = []
    /// Feeds whose local folder link is read again.
    public var localFolders: Set<Int64> = []
    /// The visible queue order is read again.
    public var queue = false

    public init() {}
    public var isEmpty: Bool {
        feeds.isEmpty && resetFeeds.isEmpty && episodes.isEmpty && statistics.isEmpty && localFolders.isEmpty && !queue
    }
    /// The episodes the request names one by one (the catch-up cap counts these).
    public var episodeCount: Int { episodes.count }
}

/// The result of a `LibraryMirrorRequest`, read in one transaction.
public struct LibraryMirrorRead: Sendable {
    public struct Episode: Sendable {
        public let feedID: Int64
        public let pubdate: Int64
        public let episode: LibraryEpisode
    }
    /// The commit sequence the read transaction saw (`library_change_sequence`).
    public var sequence: Int64 = 0
    /// Requested headers (`feeds` and `resetFeeds`): nil when the feed is gone or no list shows it.
    public var headers: [Int64: LibraryFeed?] = [:]
    /// The visible episodes of each shown reset feed, in the feed's stored order.
    public var feedEpisodes: [Int64: [Episode]] = [:]
    /// Requested episodes: nil when gone, hidden, or of a feed no list shows.
    public var episodes: [Int64: Episode?] = [:]
    /// Statistics units of the requested episodes (and of reset feeds' episodes); an episode without units is absent.
    public var units: [Int64: [LibraryStatisticsUnit]] = [:]
    /// Episodes whose units were read (absent from `units`: none).
    public var unitsRead: Set<Int64> = []
    public var links: [Int64: LocalFolderLink?] = [:]
    /// The visible queue order, when requested.
    public var queue: [Int64]?
    /// The stored order title (`feeds.title`) of each requested shown feed: the feed order is title without case
    /// (SQLite NOCASE), then ID.
    public var titles: [Int64: String?] = [:]
    /// Records decoded by the read.
    public var recordsDecoded = 0
    /// Sorts of the statistics IDs the read made (one per read, whatever their number).
    public var statisticsSorts = 0

    public init() {}
}

extension LibraryMirrorRead {
    /// Reads `request` in the caller's read transaction.
    static func read(_ database: LibrarySQLite, _ request: LibraryMirrorRequest) throws -> LibraryMirrorRead {
        var result = LibraryMirrorRead()
        result.sequence = try database.rows("SELECT seq FROM library_change_sequence WHERE id = 1").first?.first?.integer ?? 0
        let listed = LibraryReader.listedFeedCondition
        func decode<T: Decodable>(_ value: LibrarySQLValue) throws -> T {
            guard let data = value.recordData else { throw FeedLibraryError.corruptRecord }
            result.recordsDecoded += 1
            return try JSONDecoder.libraryRecord(T.self, from: data)
        }
        let headerIDs = Array(request.feeds.union(request.resetFeeds)).sorted()
        for id in headerIDs { result.headers[id] = .some(nil) }
        for chunk in LibraryReader.chunks(headerIDs) {
            for row in try database.rows("SELECT f.id, f.record, f.title FROM feeds f WHERE f.id IN (SELECT value FROM json_each(?)) AND \(listed("f.id"))", [.text(chunk)]) {
                guard let id = row[0].integer else { throw FeedLibraryError.corruptRecord }
                let feed: LibraryFeed = try decode(row[1])
                guard feed.id == id, feed.episodes.isEmpty, feed.metadata.episodes.isEmpty else { throw FeedLibraryError.corruptRecord }
                result.headers[id] = feed
                result.titles.updateValue(row[2].text, forKey: id)
            }
        }
        let hidden = "NOT EXISTS (SELECT 1 FROM ntp_hidden_episodes h WHERE h.episode_id = e.id)"
        // Episodes as lists show them: SQLite leaves out the show notes and chapters, never decoded.
        let record = LibraryEpisode.listProjectionSQL("e.record")
        for id in request.resetFeeds.sorted() where result.headers[id] ?? nil != nil {
            result.feedEpisodes[id] = try database.rows("SELECT e.id, e.pubdate, \(record) FROM episodes e WHERE e.feed_id = ? AND \(hidden) ORDER BY e.pubdate DESC, e.id", [.integer(id)]).map { row in
                guard let episodeID = row[0].integer, let pubdate = row[1].integer else { throw FeedLibraryError.corruptRecord }
                let episode: LibraryEpisode = try decode(row[2])
                guard episode.id == episodeID else { throw FeedLibraryError.corruptRecord }
                return Episode(feedID: id, pubdate: pubdate, episode: episode)
            }
        }
        let episodeIDs = Array(request.episodes).sorted()
        for id in episodeIDs { result.episodes[id] = .some(nil) }
        for chunk in LibraryReader.chunks(episodeIDs) {
            for row in try database.rows("SELECT e.id, e.feed_id, e.pubdate, \(record) FROM episodes e WHERE e.id IN (SELECT value FROM json_each(?)) AND \(hidden) AND \(listed("e.feed_id"))", [.text(chunk)]) {
                guard let id = row[0].integer, let feed = row[1].integer, let pubdate = row[2].integer else { throw FeedLibraryError.corruptRecord }
                let episode: LibraryEpisode = try decode(row[3])
                guard episode.id == id else { throw FeedLibraryError.corruptRecord }
                result.episodes[id] = Episode(feedID: feed, pubdate: pubdate, episode: episode)
            }
        }
        var unitIDs = request.statistics.union(request.episodes)
        for episodes in result.feedEpisodes.values { unitIDs.formUnion(episodes.map(\.episode.id)) }
        if !unitIDs.isEmpty, try database.scalar("SELECT EXISTS (SELECT 1 FROM statistics_units)") == 1 {
            // One sort, then the chunks.
            let sorted = unitIDs.sorted()
            result.statisticsSorts += 1
            for start in stride(from: 0, to: sorted.count, by: 500) {
                result.units.merge(try database.statisticsUnits(episodes: Array(sorted[start..<min(sorted.count, start + 500)]))) { $1 }
            }
        }
        result.unitsRead = unitIDs
        let linkIDs = Array(request.localFolders.union(headerIDs)).sorted()
        for id in linkIDs { result.links[id] = .some(nil) }
        for chunk in LibraryReader.chunks(linkIDs) {
            for row in try database.rows("SELECT feed_id, record FROM local_folder_links WHERE feed_id IN (SELECT value FROM json_each(?))", [.text(chunk)]) {
                guard let id = row[0].integer else { throw FeedLibraryError.corruptRecord }
                let link: LocalFolderLink = try decode(row[1])
                guard link.feedID == id else { throw FeedLibraryError.corruptRecord }
                result.links[id] = link
            }
        }
        if request.queue {
            result.queue = try database.rows("SELECT q.episode_id FROM queue q JOIN episodes e ON e.id = q.episode_id WHERE \(hidden) AND \(listed("e.feed_id")) ORDER BY q.position").compactMap { $0[0].integer }
        }
        return result
    }
}

/// What the screens show of the library at the open's sequence: the snapshot, with the stored episode order keys, the feed
/// order, the folder links and the sequence, all from one read transaction.
public struct LibraryScreenSnapshot: Sendable {
    public var snapshot: FeedLibrarySnapshot
    public var pubdates: [Int64: Int64]
    public var links: [Int64: LocalFolderLink]
    /// Each feed's stored order title (`feeds.title`).
    public var titles: [Int64: String?]
    public var sequence: Int64
    /// The episodes are list projections (`LibraryEpisode.listProjection`, `FeedLibraryStore.screenSnapshot()`): an
    /// episode's show notes and chapters are read through `detail`.
    public var projected = false
    /// The keyed reads of what a projection leaves out, attached by the screen that opened this library.
    public var detail: LibraryDetailReader?
    public init(snapshot: FeedLibrarySnapshot, pubdates: [Int64: Int64] = [:], links: [Int64: LocalFolderLink] = [:],
                titles: [Int64: String?] = [:], sequence: Int64 = 0) {
        self.snapshot = snapshot; self.pubdates = pubdates; self.links = links; self.titles = titles; self.sequence = sequence
    }
}

extension FeedLibraryStore {
    /// The screens' open read (`snapshot()` with what patches need to keep it), in one read transaction. Its episodes are
    /// as lists show them (`LibraryEpisode.listProjection`): show notes and chapters are read only for an episode's page.
    public func screenSnapshot() throws -> LibraryScreenSnapshot {
        snapshotReads += 1
        return try database.transaction(write: false) {
            let snapshot = try loadSnapshot(projection: true)
            var pubdates: [Int64: Int64] = [:]
            pubdates.reserveCapacity(snapshot.feeds.reduce(0) { $0 + $1.episodes.count })
            for row in try database.rows("SELECT id, pubdate FROM episodes") {
                if let id = row[0].integer, let pubdate = row[1].integer { pubdates[id] = pubdate }
            }
            var links: [Int64: LocalFolderLink] = [:]
            for feed in snapshot.feeds where feed.source.isLocalFeedSource { links[feed.id] = try localFolder(feedID: feed.id) }
            var titles: [Int64: String?] = [:]
            for row in try database.rows("SELECT id, title FROM feeds") { if let id = row[0].integer { titles.updateValue(row[1].text, forKey: id) } }
            let sequence = try database.rows("SELECT seq FROM library_change_sequence WHERE id = 1").first?.first?.integer ?? 0
            var open = LibraryScreenSnapshot(snapshot: snapshot, pubdates: pubdates, links: links, titles: titles, sequence: sequence)
            open.projected = true
            return open
        }
    }

    /// Reads a mirror request on the store's own connection (tests; the screens read through `LibraryReader`).
    public func mirrorRead(_ request: LibraryMirrorRequest) throws -> LibraryMirrorRead {
        try database.transaction(write: false) { try LibraryMirrorRead.read(database, request) }
    }
}

extension LibraryReader {
    /// Reads a mirror request in one read transaction of this reader.
    public func mirrorRead(_ request: LibraryMirrorRequest, token: Token? = nil) throws -> LibraryMirrorRead {
        let result = try read(token: token) { try LibraryMirrorRead.read($0, request) }
        metrics.recordRows += result.recordsDecoded
        metrics.recordsDecoded += result.recordsDecoded
        return result
    }
}

/// What a patch changed in the mirror: the episodes whose value (or podcast) changed, with the value before and after
/// (nil: not in the library), and the feeds, counts, queue, deletion targets and statistics units that changed.
public struct LibraryMirrorDelta: Sendable {
    public typealias Value = (feed: LibraryFeed, episode: LibraryEpisode)
    public var episodes: [Int64: (old: Value?, new: Value?)] = [:]
    /// Feeds whose header changed (any stored field).
    public var headers: Set<Int64> = []
    /// Feeds that entered or left, or whose subscription state changed: lists that depend on it re-evaluate its episodes.
    public var feedStates: Set<Int64> = []
    /// The feed order or set changed.
    public var feedOrder = false
    public var queue = false
    /// The episodes that joined or left the queue (an episode of the queue whose content changed is not one).
    public var queueMembers: Set<Int64> = []
    public var counts: Set<Int64> = []
    public var targets: Set<Int64> = []
    public var units: Set<Int64> = []
    /// Shown episodes a commit changed outside what the screens' library holds of them (their show notes or chapters,
    /// which `LibraryEpisode.listProjection` leaves out): their row is the same, but a search re-matches them and an open
    /// page shows their notes again. Named whenever the change sets named an episode whose projection did not change.
    public var details: Set<Int64> = []
    public init() {}
    public var isEmpty: Bool {
        episodes.isEmpty && headers.isEmpty && feedStates.isEmpty && !feedOrder && !queue && counts.isEmpty && targets.isEmpty && units.isEmpty
            && details.isEmpty
    }
    /// The episodes a search re-matches: those whose value changed, and those changed only outside their projection.
    public var textChanged: Set<Int64> { Set(episodes.keys).union(details) }
}

/// The library the screens show (the decoded feeds and episodes, queue, deletion targets, statistics units and per-feed
/// counts), kept by applying keyed reads of what each committed change set named instead of reading the whole library.
/// A patched mirror equals a fresh `snapshot()` taken at the same sequence.
public struct LibraryScreenMirror: Sendable {
    public private(set) var feeds: [LibraryFeed] = []
    public private(set) var queue: [LibraryEpisode] = []
    public private(set) var deletionTargets: [Int64: EpisodeMediaDeletionTarget] = [:]
    public private(set) var statisticsUnits: [Int64: [LibraryStatisticsUnit]] = [:]
    /// Each shown feed's visible counts (`FeedListCounts(feedID:episodes:)`).
    public private(set) var counts: [Int64: FeedListCounts] = [:]
    public private(set) var queuedIDs: Set<Int64> = []
    public private(set) var downloadedIDs: Set<Int64> = []
    /// The sequence the mirror is current to.
    public internal(set) var sequence: Int64 = 0
    /// Episodes visited by patches (moved, re-indexed, counted, re-targeted): the budgets' measure of patch work.
    public var work = 0
    private var feedPositions: [Int64: Int] = [:]
    private var locations: [Int64: (feed: Int64, index: Int)] = [:]
    private var pubdates: [Int64: Int64] = [:]
    private var links: [Int64: LocalFolderLink] = [:]
    /// Each shown feed's order key: its stored title folded as SQLite's NOCASE folds it (ASCII only), nil for NULL.
    private var titleKeys: [Int64: [UInt8]?] = [:]
    /// An episode with each media address, and the further ones sharing an address (rare): no allocation per episode.
    private var mediaURLs: [String: Int64] = [:]
    private var moreMediaURLs: [String: Set<Int64>] = [:]
    private var queuePositions: [Int64: Int] = [:]

    public init() {}

    public init(_ open: LibraryScreenSnapshot) {
        let snapshot = open.snapshot
        feeds = snapshot.feeds
        queue = snapshot.queue
        deletionTargets = snapshot.deletionTargets
        statisticsUnits = snapshot.statisticsUnits
        pubdates = open.pubdates
        links = open.links
        sequence = open.sequence
        for feed in open.snapshot.feeds { titleKeys[feed.id] = .some(open.titles[feed.id].flatMap { $0 }.map(Self.noCaseKey)) }
        var total = 0
        for feed in feeds { total += feed.episodes.count }
        locations.reserveCapacity(total)
        for (position, feed) in feeds.enumerated() {
            feedPositions[feed.id] = position
            counts[feed.id] = FeedListCounts(feedID: feed.id, episodes: feed.episodes)
            for (index, episode) in feed.episodes.enumerated() where locations[episode.id] == nil {
                locations[episode.id] = (feed.id, index)
                noteAdded(episode)
            }
        }
        reindexQueue()
    }

    // MARK: - Lookups

    public func feed(_ id: Int64) -> LibraryFeed? { feedPositions[id].map { feeds[$0] } }
    public func contains(feed id: Int64) -> Bool { feedPositions[id] != nil }
    public func episode(_ id: Int64) -> Value? {
        guard let location = locations[id], let position = feedPositions[location.feed] else { return nil }
        return (feeds[position], feeds[position].episodes[location.index])
    }
    public typealias Value = LibraryMirrorDelta.Value
    public var episodeCount: Int { locations.count }

    /// The shown episodes whose media address is exactly `url` (code units, as downloads match it).
    public func episodes(mediaURL url: String) -> [Int64] {
        ((mediaURLs[url].map { [$0] } ?? []) + (moreMediaURLs[url] ?? []))
            .filter { id in episode(id)?.episode.details.media?.url?.utf16.elementsEqual(url.utf16) == true }.sorted()
    }

    /// What the screens' snapshot holds.
    public var snapshot: FeedLibrarySnapshot {
        FeedLibrarySnapshot(feeds: feeds, queue: queue, deletionTargets: deletionTargets, statisticsUnits: statisticsUnits)
    }

    // MARK: - Requests

    /// The request that brings the mirror up to date after `sets` (in commit order).
    public func request(for sets: [LibraryChangeSet]) -> LibraryMirrorRequest {
        var request = LibraryMirrorRequest()
        for set in sets {
            for (id, change) in set.feeds {
                request.feeds.insert(id)
                // A feed entering or leaving carries its episodes, which the set does not list again.
                var reset = change != .changed || !contains(feed: id)
#if DEBUG
                if screenModelFaults.contains(.feedResetIgnored) { reset = false }
#endif
                if reset { request.resetFeeds.insert(id) }
            }
            for (id, change) in set.episodes {
                request.episodes.insert(id)
                for feed in [change.feed, change.formerFeed].compactMap({ $0 }) where !contains(feed: feed) {
                    request.feeds.insert(feed); request.resetFeeds.insert(feed)
                }
            }
            request.statistics.formUnion(set.statistics.keys)
            request.localFolders.formUnion(set.localFolders.keys)
            if let queue = set.queue, !queue.isEmpty { request.queue = true }
        }
        if !request.resetFeeds.isEmpty { request.queue = true }
        return request
    }

    // MARK: - Apply

    /// Applies a read; returns what changed.
    @discardableResult
    public mutating func apply(_ read: LibraryMirrorRead) -> LibraryMirrorDelta {
        var delta = LibraryMirrorDelta()
        var targetFeeds: Set<Int64> = []
        for (id, link) in read.links where links[id] != link {
            links[id] = link
            targetFeeds.insert(id)
        }
        // Feeds that left, then headers and whole feeds.
        for (id, header) in read.headers.sorted(by: { $0.key < $1.key }) {
            guard let header else {
                if contains(feed: id) { removeFeed(id, &delta) }
                continue
            }
            if let episodes = read.feedEpisodes[id] {
                replaceFeed(header, episodes, &delta)
                targetFeeds.insert(id)
            } else if let position = feedPositions[id] {
                var old = feeds[position]
                let episodes = old.episodes
                old.episodes = []
                guard old != header else { continue }
                delta.headers.insert(id)
                if old.subscriptionState != header.subscriptionState { delta.feedStates.insert(id) }
                if old.source != header.source { targetFeeds.insert(id) }
                // The feed's rows show the new header; their episodes did not change, so none is listed (an unchanged
                // refresh rewrites the header and must stay flat).
                var updated = header
                updated.episodes = episodes
                feeds[position] = updated
            }
        }
        for (id, row) in read.episodes.sorted(by: { $0.key < $1.key }) {
            if let row, feedPositions[row.feedID] != nil {
                upsert(row, &delta)
            } else if locations[id] != nil {
                removeEpisode(id, &delta)
            }
        }
        // Named by a commit and shown, with the same projection: what changed is what the projection leaves out.
        for (id, row) in read.episodes where row != nil && delta.episodes[id] == nil && locations[id] != nil { delta.details.insert(id) }
        // The feed order (`ORDER BY title COLLATE NOCASE, id`), kept from each feed's stored title: sorted again only when
        // a title changed or a feed came or went (feed-count work, no read).
        var reorder = delta.feedOrder
        for (id, title) in read.titles where feedPositions[id] != nil {
            let key = title.map(Self.noCaseKey)
            if titleKeys[id].map({ $0 != key }) ?? true { titleKeys[id] = .some(key); reorder = true }
        }
        if reorder {
            let sorted = feeds.sorted { Self.feedPrecedes(($0.id, titleKeys[$0.id] ?? nil), ($1.id, titleKeys[$1.id] ?? nil)) }
            if sorted.map(\.id) != feeds.map(\.id) {
                feeds = sorted
                feedPositions = [:]
                for (position, feed) in feeds.enumerated() { feedPositions[feed.id] = position }
                delta.feedOrder = true
            }
        }
        // Statistics units.
        for id in read.unitsRead {
            let units = locations[id] != nil ? read.units[id] : nil
            if statisticsUnits[id] != units {
                statisticsUnits[id] = units
                delta.units.insert(id)
            }
        }
        // Deletion targets.
        var targetIDs = Set(delta.episodes.keys)
        for id in targetFeeds { if let feed = feed(id) { targetIDs.formUnion(feed.episodes.map(\.id)) } }
        for id in targetIDs { updateTarget(id, &delta) }
        work += targetIDs.count
        // The queue.
        if let order = read.queue {
            let visible = order.filter { locations[$0] != nil }
            if visible != queue.map(\.id) || visible.contains(where: { delta.episodes[$0] != nil }) {
                let before = queuedIDs
                queue = visible.compactMap { episode($0)?.episode }
                reindexQueue()
                // Only here, where the commit named the queue and the queue is read and indexed again anyway.
                delta.queueMembers.formUnion(before.symmetricDifference(queuedIDs))
                work += queue.count
                delta.queue = true
            }
        } else {
            for (id, change) in delta.episodes where queuePositions[id] != nil {
                if let new = change.new { queue[queuePositions[id]!] = new.episode } else { dropFromQueue(id); delta.queueMembers.insert(id) }
                delta.queue = true
            }
        }
        sequence = max(sequence, read.sequence)
        return delta
    }

    /// Applies a committed action's state to one episode at once (the change set's read follows and agrees).
    @discardableResult
    public mutating func update(episode id: Int64, _ change: (inout LibraryEpisode) -> Void) -> LibraryMirrorDelta {
        var delta = LibraryMirrorDelta()
        guard let location = locations[id], let position = feedPositions[location.feed] else { return delta }
        let old = feeds[position].episodes[location.index]
        var new = old
        change(&new)
        guard new != old else { return delta }
        // In place: an action never changes the episode's stored order.
        count(old, in: location.feed, sign: -1, &delta)
        noteRemoved(old)
        feeds[position].episodes[location.index] = new
        count(new, in: location.feed, sign: 1, &delta)
        noteAdded(new)
        let header = withoutEpisodes(feeds[position])
        delta.episodes[id] = ((header, old), (header, new))
        updateTarget(id, &delta)
        if let index = queuePositions[id] { queue[index] = new; delta.queue = true }
        return delta
    }

    /// The queue in a committed order of the same members (a move this screen made), at once.
    public mutating func reorderQueue(_ ids: [Int64]) {
        guard Set(ids) == queuedIDs, ids.count == queue.count else { return }
        queue = ids.compactMap { id in queuePositions[id].map { queue[$0] } }
        reindexQueue()
    }

    // MARK: - Helpers

    /// SQLite's NOCASE collation key: the UTF-8 bytes with ASCII capitals folded.
    static func noCaseKey(_ title: String) -> [UInt8] { title.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 } }

    /// `ORDER BY title COLLATE NOCASE ASC, id`: NULL first, then the folded bytes, then the ID.
    static func feedPrecedes(_ a: (id: Int64, key: [UInt8]?), _ b: (id: Int64, key: [UInt8]?)) -> Bool {
        switch (a.key, b.key) {
        case (nil, nil): return a.id < b.id
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return x == y ? a.id < b.id : x.lexicographicallyPrecedes(y)
        }
    }

    private mutating func noteAdded(_ episode: LibraryEpisode) {
        if episode.userState.isDownloaded { downloadedIDs.insert(episode.id) }
        if let url = episode.details.media?.url {
            if let first = mediaURLs[url] { if first != episode.id { moreMediaURLs[url, default: []].insert(episode.id) } }
            else { mediaURLs[url] = episode.id }
        }
    }

    private mutating func noteRemoved(_ episode: LibraryEpisode) {
        downloadedIDs.remove(episode.id)
        if let url = episode.details.media?.url {
            if mediaURLs[url] == episode.id {
                if let next = moreMediaURLs[url]?.min() {
                    mediaURLs[url] = next
                    moreMediaURLs[url]?.remove(next)
                    if moreMediaURLs[url]?.isEmpty == true { moreMediaURLs[url] = nil }
                } else { mediaURLs[url] = nil }
            } else {
                moreMediaURLs[url]?.remove(episode.id)
                if moreMediaURLs[url]?.isEmpty == true { moreMediaURLs[url] = nil }
            }
        }
    }

    private mutating func count(_ episode: LibraryEpisode, in feed: Int64, sign: Int64, _ delta: inout LibraryMirrorDelta) {
#if DEBUG
        if screenModelFaults.contains(.countsNotKept) { return }
#endif
        let state = episode.userState, media = episode.details.media != nil
        var value = counts[feed] ?? FeedListCounts(feedID: feed)
        value.total += sign
        if state.playState == .new { value.new += sign }
        if state.playState == .played { value.played += sign }
        if state.isDownloaded && media { value.downloadedMedia += sign }
        if state.isDownloaded && media && state.playState != .played { value.downloadedMediaUnplayed += sign }
        if state.isDownloaded { value.downloaded += sign }
        if state.isFavorite { value.favorite += sign }
        if counts[feed] != value { counts[feed] = value; delta.counts.insert(feed) }
    }

    private mutating func removeFeed(_ id: Int64, _ delta: inout LibraryMirrorDelta) {
        guard let position = feedPositions[id] else { return }
        let feed = feeds[position], header = withoutEpisodes(feed)
        work += feed.episodes.count
        for episode in feed.episodes {
            locations[episode.id] = nil
            pubdates[episode.id] = nil
            noteRemoved(episode)
            if deletionTargets.removeValue(forKey: episode.id) != nil { delta.targets.insert(episode.id) }
            if statisticsUnits.removeValue(forKey: episode.id) != nil { delta.units.insert(episode.id) }
            let old = delta.episodes[episode.id]?.old ?? (header, episode)
            delta.episodes[episode.id] = (old, nil)
            if queuePositions[episode.id] != nil { dropFromQueue(episode.id); delta.queue = true; delta.queueMembers.insert(episode.id) }
        }
        feeds.remove(at: position)
        feedPositions = [:]
        for (position, feed) in feeds.enumerated() { feedPositions[feed.id] = position }
        counts[id] = nil
        links[id] = nil
        titleKeys[id] = nil
        delta.counts.insert(id); delta.feedStates.insert(id); delta.headers.insert(id); delta.feedOrder = true
    }

    private mutating func replaceFeed(_ header: LibraryFeed, _ episodes: [LibraryMirrorRead.Episode], _ delta: inout LibraryMirrorDelta) {
        let previous = feed(header.id)
        if previous != nil { removeFeed(header.id, &delta) }
        var feed = header
        feed.episodes = []
        let shown = feed
        feed.episodes = episodes.map(\.episode)
        feeds.append(feed)
        feedPositions[feed.id] = feeds.count - 1
        counts[feed.id] = FeedListCounts(feedID: feed.id, episodes: feed.episodes)
        work += episodes.count
        for (index, row) in episodes.enumerated() {
            // An episode listed in another shown feed moves here.
            if locations[row.episode.id] != nil { removeEpisode(row.episode.id, &delta, moving: true) }
            locations[row.episode.id] = (feed.id, index)
            pubdates[row.episode.id] = row.pubdate
            noteAdded(row.episode)
            let old = delta.episodes[row.episode.id]?.old
            delta.episodes[row.episode.id] = (old, (shown, row.episode))
        }
        // Episodes that were shown before and still are, unchanged, are no change to their rows (what their projection
        // leaves out may have changed: the podcast was read whole again).
        for (id, change) in delta.episodes {
            if let old = change.old, let new = change.new, old.episode == new.episode, old.feed == new.feed {
                delta.episodes[id] = nil
                delta.details.insert(id)
            }
        }
        delta.counts.insert(feed.id); delta.feedStates.insert(feed.id); delta.headers.insert(feed.id); delta.feedOrder = true
    }

    /// The index an episode with `pubdate` and `id` takes in `episodes` (newest first, equal dates by ID).
    private func insertionIndex(_ episodes: [LibraryEpisode], pubdate: Int64, id: Int64) -> Int {
        var low = 0, high = episodes.count
        while low < high {
            let middle = (low + high) / 2
            let other = episodes[middle].id, date = pubdates[other] ?? 0
            if date > pubdate || (date == pubdate && other < id) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private mutating func upsert(_ row: LibraryMirrorRead.Episode, _ delta: inout LibraryMirrorDelta) {
        let id = row.episode.id
        guard let position = feedPositions[row.feedID] else { return }
        if let location = locations[id], location.feed == row.feedID, pubdates[id] == row.pubdate {
            let old = feeds[position].episodes[location.index]
            guard old != row.episode else { return }
            count(old, in: row.feedID, sign: -1, &delta)
            noteRemoved(old)
            feeds[position].episodes[location.index] = row.episode
            count(row.episode, in: row.feedID, sign: 1, &delta)
            noteAdded(row.episode)
            let before = delta.episodes[id]?.old ?? (withoutEpisodes(feeds[position]), old)
            delta.episodes[id] = (before, (withoutEpisodes(feeds[position]), row.episode))
            return
        }
        var before: Value?
        if locations[id] != nil {
            before = episode(id).map { (withoutEpisodes($0.feed), $0.episode) }
            // It moves (another date or podcast): it stays in the library, its queue place and statistics with it.
            removeEpisode(id, &delta, moving: true)
        }
        guard let target = feedPositions[row.feedID] else { return }
        pubdates[id] = row.pubdate
        let index = insertionIndex(feeds[target].episodes, pubdate: row.pubdate, id: id)
        feeds[target].episodes.insert(row.episode, at: index)
        for later in feeds[target].episodes[(index + 1)...] { locations[later.id]?.index += 1 }
        work += feeds[target].episodes.count - index
        locations[id] = (row.feedID, index)
        count(row.episode, in: row.feedID, sign: 1, &delta)
        noteAdded(row.episode)
        let old = delta.episodes[id]?.old ?? before
        delta.episodes[id] = (old, (withoutEpisodes(feeds[target]), row.episode))
        if let index = queuePositions[id] { queue[index] = row.episode; delta.queue = true }
    }

    /// `moving`: the episode is placed again at once (another date or podcast), so it keeps its queue place and units.
    private mutating func removeEpisode(_ id: Int64, _ delta: inout LibraryMirrorDelta, moving: Bool = false) {
        guard let location = locations[id], let position = feedPositions[location.feed] else { return }
        let feed = feeds[position], episode = feed.episodes[location.index]
        feeds[position].episodes.remove(at: location.index)
        for later in feeds[position].episodes[location.index...] { locations[later.id]?.index -= 1 }
        work += feeds[position].episodes.count - location.index + 1
        locations[id] = nil
        pubdates[id] = nil
        count(episode, in: location.feed, sign: -1, &delta)
        noteRemoved(episode)
        let old = delta.episodes[id]?.old ?? (withoutEpisodes(feed), episode)
        delta.episodes[id] = (old, nil)
        guard !moving else { return }
        if deletionTargets.removeValue(forKey: id) != nil { delta.targets.insert(id) }
        if statisticsUnits.removeValue(forKey: id) != nil { delta.units.insert(id) }
        if queuePositions[id] != nil { dropFromQueue(id); delta.queue = true; delta.queueMembers.insert(id) }
    }

    /// A row's podcast without its episodes (a delta never carries the feed's episode list).
    private func withoutEpisodes(_ feed: LibraryFeed) -> LibraryFeed {
        var feed = feed
        feed.episodes = []
        return feed
    }

    private mutating func updateTarget(_ id: Int64, _ delta: inout LibraryMirrorDelta) {
        let target = episode(id).flatMap { value in
            FeedLibraryStore.mediaDeletionTarget(episode: value.episode, feed: value.feed,
                localFolder: value.feed.source.isLocalFeedSource ? links[value.feed.id] : nil)
        }
        if deletionTargets[id] != target {
            deletionTargets[id] = target
            delta.targets.insert(id)
        }
    }

    private mutating func dropFromQueue(_ id: Int64) {
        guard let index = queuePositions[id] else { return }
        queue.remove(at: index)
        reindexQueue()
    }

    private mutating func reindexQueue() {
        queuePositions = [:]
        for (index, episode) in queue.enumerated() where queuePositions[episode.id] == nil { queuePositions[episode.id] = index }
        queuedIDs = Set(queuePositions.keys)
    }

    /// Tests: the mirror's own consistency (every lookup structure against the feeds).
    public func inconsistencies() -> [String] {
        var found: [String] = []
        var total = 0
        for (position, feed) in feeds.enumerated() {
            if feedPositions[feed.id] != position { found.append("feed position \(feed.id)") }
            if counts[feed.id] != FeedListCounts(feedID: feed.id, episodes: feed.episodes) { found.append("counts \(feed.id)") }
            for (index, episode) in feed.episodes.enumerated() {
                total += 1
                if locations[episode.id].map({ $0.feed == feed.id && $0.index == index }) != true { found.append("location \(episode.id)") }
                if index > 0 {
                    let previous = feed.episodes[index - 1]
                    let a = pubdates[previous.id] ?? 0, b = pubdates[episode.id] ?? 0
                    if !(a > b || (a == b && previous.id < episode.id)) { found.append("order \(episode.id)") }
                }
                if episode.userState.isDownloaded != downloadedIDs.contains(episode.id) { found.append("downloaded \(episode.id)") }
            }
        }
        if total != locations.count { found.append("location count") }
        if Set(queue.map(\.id)) != queuedIDs { found.append("queued") }
        return found
    }
}

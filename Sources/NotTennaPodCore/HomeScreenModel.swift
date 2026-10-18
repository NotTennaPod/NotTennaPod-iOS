import Foundation

#if DEBUG
/// Test-only mutations of Home, Subscriptions and search kept from patches (`LibraryScreenOtherScreensTests`): Home's
/// Inbox not patched, a Surprise pick that left not picked again, Classics loaded on every patch, the search matches
/// not patched, the newest dates not patched, the clock kept on explicit events (return, Shuffle), and the search's
/// previous result keeping the matches.
enum OtherScreenFault: Hashable, Sendable {
    case homeInboxNotPatched, surpriseNotRepicked, classicsOnEveryPatch, searchNotPatched, latestNotPatched, clockKeptOnEvents
    case searchPreviousKeepsMatches
}
nonisolated(unsafe) var otherScreenFaults: Set<OtherScreenFault> = []
#endif

/// Home's sections (`HomeSectionQueries`) kept from the screens' library patch by patch, so a routine change costs what it
/// changed, never a scan of the library:
/// - **Inbox:** the NEW episodes of subscribed podcasts in the Inbox order, an `EpisodeListIndex` (its first two and its
///   count);
/// - **Get surprised:** per subscribed podcast its pick (`argmax (id·seed) % 46471`, the lower ID on equal hashes) among
///   the candidates, from the podcast's population of unplayed episodes with media kept newest first. Every patch checks
///   each pick against the clock (the time windows only ever remove candidates); a pick that left is picked again from
///   that podcast's recent population only;
/// - **Classics:** loaded at the screen's open and when one of its inputs changes (the subscription set, a podcast's
///   state, title or cover), as Android's `SubscriptionsSection` reloads on `FeedListUpdateEvent` only; never on routine
///   changes;
/// - **Continue:** the queued episodes with a non-zero ordering key (resumed: position from a second, or played in the
///   last 30 seconds) are kept with their keys; the eight cards are the resumed ones by last played time, then the queue's
///   first others in queue order, found by walking only the queue's start. A change names a key, the queue or the clock
///   window, never a sort of the whole queue;
/// - Downloads come from the downloaded episodes (the person's own collection).
public struct HomeScreenModel {
    public struct Metrics: Equatable, Sendable {
        /// Surprise picks made again for one podcast (its pick left the candidates).
        public var candidateRescans = 0
        /// Population members a re-pick looked at.
        public var populationVisited = 0
        /// Population members moved by inserts and removals.
        public var populationMoved = 0
        /// Classics aggregates computed.
        public var classicsLoads = 0
        /// Changed episodes a patch looked at.
        public var episodesVisited = 0
        /// Queue entries Continue looked at (keys sorted, the queue's start walked).
        public var continueVisited = 0
        public init() {}
    }

    /// One episode of a podcast's Surprise population: newest first, equal dates by ID.
    struct SurpriseMember {
        let published: Int64
        let id: Int64
        static func precedes(_ a: Self, _ b: Self) -> Bool { a.published == b.published ? a.id < b.id : a.published > b.published }
    }

    private struct ClassicsInput: Equatable {
        let state: FeedSubscriptionState
        let title: String?
        let imageURL: String?
    }

    public var metrics = Metrics()
    public let inboxSort: EpisodeListSort
    public private(set) var seed: Int32
    public private(set) var now: Int64
    private var inbox: EpisodeListIndex
    private var populations: [Int64: ChunkedOrderedList<SurpriseMember>] = [:]
    private var picks: [Int64: Int64] = [:]
    public private(set) var classics: [Int64] = []
    private var classicsInputs: [Int64: ClassicsInput] = [:]
    private let includeMarkedAsPlayed: Bool
    private let capacity: Int
    /// Queued episodes whose Continue ordering key is not 0, with the key.
    private var continueKeys: [Int64: Int64] = [:]
    /// Of those, the ones resumed only by the 30-second window, with the last moment it counts.
    private var continueWindow: [Int64: Int64] = [:]
    /// Continue's cards (`getPausedQueue(8)`).
    public private(set) var continueIDs: [Int64] = []

    /// Opens Home over the screens' library (explicit: the screen opens): every list is read once.
    public init(mirror: LibraryScreenMirror, inboxSort: EpisodeListSort, seed: Int32, now: Date,
                includeMarkedAsPlayed: Bool, capacity: Int = 256) {
        self.inboxSort = inboxSort; self.seed = seed; self.now = Self.milliseconds(now)
        self.includeMarkedAsPlayed = includeMarkedAsPlayed; self.capacity = capacity
        inbox = EpisodeListIndex(spec: .inbox(inboxSort), candidates: mirror.feeds.lazy.flatMap { feed in
            feed.episodes.lazy.map { (feed: feed, episode: $0) }
        }, queued: [], capacity: capacity)
        for feed in mirror.feeds { openPopulation(feed) }
        for feed in populations.keys { picks[feed] = pick(feed, mirror: mirror) }
        loadClassics(mirror, now: now)
        for episode in mirror.queue { setContinueKey(episode) }
        metrics.continueVisited += mirror.queue.count
        recomputeContinue(mirror)
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    // MARK: - Sections

    /// `HomeSectionQueries.inbox`: the first `limit` NEW episodes in the Inbox order, and their total.
    public mutating func inbox(limit: Int = 2) -> (ids: [Int64], total: Int) { (inbox.ids(0..<limit), inbox.count) }

    /// `HomeSectionQueries.surprise`: the picks, ordered by `(id·wrap32(seed·3)) % 46471` descending, then ID.
    public func surprise(limit: Int = 8) -> [Int64] {
        let seed3 = Int64(seed &* 3)
        return picks.values.sorted { lhs, rhs in
            let left = (lhs &* seed3) % 46471, right = (rhs &* seed3) % 46471
            return left == right ? lhs < rhs : left > right
        }.prefix(limit).map { $0 }
    }


    /// Home's Downloads: the first two downloaded episodes in the Downloads order (no jobs).
    public static func downloads(_ mirror: LibraryScreenMirror, order: FeedEpisodeSortOrder?, limit: Int = 2) -> [Int64] {
        Array(mirror.downloads(jobs: [], order: order).prefix(limit))
    }

    /// `HomeSectionQueries.showsWelcome`, from the kept counts.
    public static func showsWelcome(_ mirror: LibraryScreenMirror) -> Bool {
        !mirror.feeds.contains { $0.subscriptionState == .subscribed && (mirror.counts[$0.id]?.total ?? 0) > 0 }
    }

    // MARK: - Patches

    /// What a patch changed: the sections whose content may differ.
    public struct Change: Equatable, Sendable {
        public var inbox = false
        public var surprise = false
        public var classics = false
        public init() {}
    }

    /// Applies a mirror patch at the time `now` (never earlier than the last).
    @discardableResult
    public mutating func apply(_ delta: LibraryMirrorDelta, mirror: LibraryScreenMirror, now date: Date) -> Change {
        var change = Change()
        now = max(now, Self.milliseconds(date))
        var patchesInbox = true
#if DEBUG
        if otherScreenFaults.contains(.homeInboxNotPatched) { patchesInbox = false }
#endif
        if patchesInbox {
            let inboxChange = inbox.apply(delta, mirror: mirror)
            change.inbox = !inboxChange.isEmpty || !delta.episodes.isEmpty
        }
        patchContinue(delta, mirror: mirror)
        let before = picks
        var repick: Set<Int64> = []
        // A podcast that came, went or changed state: its population and pick from its episodes (feed-proportional, rare).
        for feed in delta.feedStates {
            populations[feed] = nil; picks[feed] = nil
            if let value = mirror.feed(feed) { openPopulation(value) }
            if populations[feed] != nil { repick.insert(feed) }
        }
        for (id, value) in delta.episodes {
            metrics.episodesVisited += 1
            // Still the same member of the same population (a favourite, a position): only its candidacy may differ.
            let kept = value.old.map { old in value.new.map { new in
                old.feed.id == new.feed.id && Self.inPopulation(old.episode) && Self.inPopulation(new.episode)
                    && Self.member(old.episode).published == Self.member(new.episode).published
            } ?? false } ?? false
            if kept, let new = value.new, !delta.feedStates.contains(new.feed.id), populations[new.feed.id] != nil {
                if candidate(new.episode), picks[new.feed.id].map({ beats(id, $0) }) ?? true { picks[new.feed.id] = id }
                continue
            }
            if let old = value.old, !delta.feedStates.contains(old.feed.id), Self.inPopulation(old.episode) {
                if populations[old.feed.id]?.remove(Self.member(old.episode)) != nil { metrics.populationMoved += 1 }
                if picks[old.feed.id] == id, value.new?.feed.id != old.feed.id { repick.insert(old.feed.id) }
            }
            if let new = value.new, !delta.feedStates.contains(new.feed.id), populations[new.feed.id] != nil {
                if Self.inPopulation(new.episode) {
                    populations[new.feed.id]?.insert(Self.member(new.episode))
                    metrics.populationMoved += 1
                }
                if candidate(new.episode), picks[new.feed.id].map({ beats(id, $0) }) ?? true { picks[new.feed.id] = id }
            }
        }
        // The clock and the changes only ever remove candidates from a pick's podcast: a pick that left is picked again.
        for (feed, id) in picks where !repick.contains(feed) {
            if !(mirror.episode(id).map { $0.feed.id == feed && candidate($0.episode) } ?? false) { repick.insert(feed) }
        }
#if DEBUG
        if otherScreenFaults.contains(.surpriseNotRepicked) { repick = repick.intersection(delta.feedStates) }
#endif
        for feed in repick.sorted() {
            metrics.candidateRescans += 1
            picks[feed] = pick(feed, mirror: mirror)
        }
        change.surprise = picks != before || !delta.episodes.isEmpty
        var reloadsClassics = classicsInputsChanged(delta, mirror: mirror)
#if DEBUG
        if otherScreenFaults.contains(.classicsOnEveryPatch) { reloadsClassics = true }
#endif
        if reloadsClassics {
            loadClassics(mirror, now: date)
            change.classics = true
        }
        return change
    }

    /// The shuffle button: new picks for every podcast at the current time (explicit; Android queries with the time now).
    public mutating func reseed(_ seed: Int32, mirror: LibraryScreenMirror, now date: Date) {
        self.seed = seed
#if DEBUG
        if !otherScreenFaults.contains(.clockKeptOnEvents) { now = max(now, Self.milliseconds(date)) }
#else
        now = max(now, Self.milliseconds(date))
#endif
        for feed in populations.keys { picks[feed] = pick(feed, mirror: mirror) }
    }

    /// Home appears again (`onStart`): its clock moves on, every pick is checked against it (and picked again where it
    /// left), and Classics loads.
    public mutating func appear(mirror: LibraryScreenMirror, now date: Date) {
#if DEBUG
        if !otherScreenFaults.contains(.clockKeptOnEvents) { apply(LibraryMirrorDelta(), mirror: mirror, now: date) }
#else
        apply(LibraryMirrorDelta(), mirror: mirror, now: date)
#endif
        loadClassics(mirror, now: date)
    }

    /// Classics again (the screen re-appears, or one of its inputs changed).
    public mutating func loadClassics(_ mirror: LibraryScreenMirror, now: Date) {
        metrics.classicsLoads += 1
        classics = ((try? HomeSectionQueries.classics(mirror.feeds, units: mirror.statisticsUnits,
                                                       includeMarkedAsPlayed: includeMarkedAsPlayed, now: now)) ?? []).map(\.id)
        classicsInputs = [:]
        for feed in mirror.feeds {
            classicsInputs[feed.id] = ClassicsInput(state: feed.subscriptionState, title: feed.title, imageURL: feed.metadata.imageURL)
        }
    }

    // MARK: - Continue

    /// `getPausedQueue`'s ordering key: the last played time of a resumed episode with media (position from a second, or
    /// played in the last 30 seconds), else 0.
    private func continueKey(_ episode: LibraryEpisode) -> Int64 {
        let state = episode.userState
        guard episode.details.media != nil else { return 0 }
        return state.positionMilliseconds >= 1000 || state.lastPlayedTimeMilliseconds >= now - 30_000 ? state.lastPlayedTimeMilliseconds : 0
    }

    private mutating func setContinueKey(_ episode: LibraryEpisode?, id: Int64? = nil) {
        guard let episode else { if let id { continueKeys[id] = nil; continueWindow[id] = nil }; return }
        let key = continueKey(episode), state = episode.userState
        continueKeys[episode.id] = key == 0 ? nil : key
        continueWindow[episode.id] = key != 0 && state.positionMilliseconds < 1000 ? state.lastPlayedTimeMilliseconds + 30_000 : nil
    }

    /// The queue changed (membership, order, a queued episode), a queued episode's key changed, or a 30-second window
    /// ended: the cards again, from the kept keys and the queue's start.
    private mutating func patchContinue(_ delta: LibraryMirrorDelta, mirror: LibraryScreenMirror) {
        var dirty = delta.queue || !delta.queueMembers.isEmpty
        for id in delta.queueMembers { setContinueKey(mirror.queuedIDs.contains(id) ? mirror.episode(id)?.episode : nil, id: id) }
        for (id, value) in delta.episodes where mirror.queuedIDs.contains(id) {
            let before = continueKeys[id]
            setContinueKey(value.new?.episode, id: id)
            if continueKeys[id] != before { dirty = true }
        }
        for (id, last) in continueWindow where now > last {
            metrics.continueVisited += 1
            setContinueKey(mirror.episode(id)?.episode, id: id)
            dirty = true
        }
        if dirty { recomputeContinue(mirror) }
    }

    /// The whole queue ordered by key descending (equal keys in queue order), its first `limit`: the resumed episodes by
    /// key, then the others from the queue's start, then any negative keys.
    private mutating func recomputeContinue(_ mirror: LibraryScreenMirror, limit: Int = 8) {
        var keyed = continueKeys.map { (id: $0.key, key: $0.value) }
        metrics.continueVisited += keyed.count
        var position: [Int64: Int] = [:]
        let sortedKeys = keyed.map(\.key).sorted()
        if zip(sortedKeys, sortedKeys.dropFirst()).contains(where: { $0 == $1 }) {
            // Equal keys (rare): their queue order decides.
            for (index, episode) in mirror.queue.enumerated() where continueKeys[episode.id] != nil { position[episode.id] = index }
            metrics.continueVisited += mirror.queue.count
        }
        keyed.sort { $0.key == $1.key ? (position[$0.id] ?? 0) < (position[$1.id] ?? 0) : $0.key > $1.key }
        var result = keyed.filter { $0.key > 0 }.prefix(limit).map(\.id)
        if result.count < limit {
            for episode in mirror.queue {
                metrics.continueVisited += 1
                guard continueKeys[episode.id] == nil else { continue }
                result.append(episode.id)
                if result.count == limit { break }
            }
        }
        if result.count < limit { result += keyed.filter { $0.key < 0 }.prefix(limit - result.count).map(\.id) }
        continueIDs = result
    }

    // MARK: - Helpers

    static func inPopulation(_ episode: LibraryEpisode) -> Bool {
        episode.details.media != nil && episode.userState.playState != .played
    }

    static func member(_ episode: LibraryEpisode) -> SurpriseMember {
        SurpriseMember(published: episode.details.publicationDate.map(milliseconds) ?? 0, id: episode.id)
    }

    /// `getRandomEpisodes`' window: published in the last 356·2 days, never played or played in the last hour.
    private var since: Int64 { now - 1000 * 3600 * 24 * 356 * 2 }

    private func candidate(_ episode: LibraryEpisode) -> Bool {
        guard Self.inPopulation(episode) else { return false }
        let state = episode.userState
        return Self.member(episode).published > since
            && (state.lastPlayedTimeMilliseconds == 0 || state.lastPlayedTimeMilliseconds > now - 3_600_000)
    }

    private func hash(_ id: Int64) -> Int64 { (id &* Int64(seed)) % 46471 }

    /// Whether `a` is picked over `b`: the larger hash, the lower ID on equal hashes.
    private func beats(_ a: Int64, _ b: Int64) -> Bool {
        let left = hash(a), right = hash(b)
        return left == right ? a < b : left > right
    }

    private mutating func openPopulation(_ feed: LibraryFeed) {
        guard feed.subscriptionState == .subscribed else { return }
        let members = feed.episodes.filter(Self.inPopulation).map(Self.member).sorted(by: SurpriseMember.precedes)
        populations[feed.id] = ChunkedOrderedList(sorted: members, capacity: capacity, by: SurpriseMember.precedes)
    }

    /// The pick of `feed` among its recent population only (newest first, until the publication window ends).
    private mutating func pick(_ feed: Int64, mirror: LibraryScreenMirror) -> Int64? {
        guard var population = populations[feed] else { return nil }
        var best: Int64?
        var rank = 0
        scan: while rank < population.count {
            for member in population.elements(rank..<rank + 64) {
                metrics.populationVisited += 1
                guard member.published > since else { break scan }
                guard let value = mirror.episode(member.id)?.episode, candidate(value) else { continue }
                if best.map({ beats(member.id, $0) }) ?? true { best = member.id }
            }
            rank += 64
        }
        populations[feed] = population
        return best
    }

    private func classicsInputsChanged(_ delta: LibraryMirrorDelta, mirror: LibraryScreenMirror) -> Bool {
        if !delta.feedStates.isEmpty { return true }
        for id in delta.headers {
            let now = mirror.feed(id).map { ClassicsInput(state: $0.subscriptionState, title: $0.title, imageURL: $0.metadata.imageURL) }
            if now != classicsInputs[id] { return true }
        }
        return false
    }

    /// Tests: a podcast's pick.
    func pick(of feed: Int64) -> Int64? { picks[feed] }

    /// Tests: the population of every subscribed podcast in order.
    var populationIDs: [Int64: [Int64]] { populations.mapValues { $0.all.map(\.id) } }
}

import Foundation

/// The projection context a staged publication was built with (PROTOCOL §6.8), kept with it for its switch and every retry: what
/// a re-projection of part of it needs to give the same answer as the original projection.
struct ServerProjectionContext: Sendable, Equatable {
    /// The commit's statistics resets (PROTOCOL §8.8 cuts).
    var commitResets: [String] = []
    /// Episodes a retiring queue add or a discovery filing the server refused had shown as queued (the retirement's
    /// `withdrawnQueue`): they leave the queue unless something else supports them.
    var withdrawnQueue: Set<String> = []
    /// A Force full synchronization: the snapshot's absence and membership semantics (`ServerProjector.fullBase`, the
    /// staged snapshot attached as `full`), and its admissions are seen.
    var full = false
    /// A full projection's admissions the ledger lacks are seen (a repair's); a recovery's are releases this phone never
    /// saw (scenario 38 PROTOCOL §16).
    var admissionsSeen = true
    /// The local feed of each podcast whose pending registration a recovery's snapshot resolves.
    var resolvedFeeds: [String: Int64] = [:]
}

/// What a staged publication projected when it was built (PROTOCOL §6.8): the entities whose images it holds or
/// whose projection it computed, and those its plan changes structurally. Only local changes to these can make it wrong;
/// changes anywhere else in the library (the player's saves and checkpoint exports on another podcast, a favorite
/// elsewhere) are not its concern.
struct ServerShadowScope: Sendable, Equatable {
    /// Wire episodes it projected.
    var episodes: Set<String> = []
    var podcasts: Set<String> = []
    /// Local episode rows it writes (their images replace the live rows).
    var rows: Set<Int64> = []
    /// Local feed rows it writes, and the feeds of the episodes it writes: a podcast-level change to one of them (a
    /// removal, a refresh, a policy) changes what it projects.
    var feeds: Set<Int64> = []
    /// Rows it creates: nobody can have touched them before its switch.
    var created: Set<Int64> = []
    /// It projected the queue.
    var queue = false
    /// It projected every mapped episode (an account-level change, a Force full synchronization).
    var everything = false
    /// The player's selection and session episodes when it was built: the pins it projected through (PROTOCOL §6.8).
    var player: [Int64?] = []
    /// It removes podcasts or episodes, which the player's episode decides (a pinned removal, PROTOCOL §6.8).
    var removals = false
    /// Episode rows its plan removes, merges, transfers (rows, downloads, ledger entries, overlays), holds as absent or
    /// maps anew: a local change to one of them needs the whole original projection, never a re-projected image.
    var structural: Set<Int64> = []
    /// Feed rows its plan removes, merges, maps anew or gives credentials.
    var structuralFeeds: Set<Int64> = []
    /// The addresses (normalized refresh URL and aliases) of the podcasts it creates or maps anew: a local podcast created
    /// or changed meanwhile at one of them is the one its identity matching should have found (`matchingFeed`).
    var matchSources: Set<String> = []

    init() {}

    /// The scope of a build: what its projector visited and what its plan writes and changes structurally, read on the
    /// build's snapshot (`live`).
    init(_ projector: ServerProjector, player: [Int64?], live: LibrarySQLite) throws {
        self = projector.visited
        let plan = projector.plan
        rows = Set(plan.episodes.keys).subtracting(plan.createdEpisodes)
        created = plan.createdEpisodes
        feeds = Set(plan.feeds.keys).union(plan.episodes.values.map(\.feedID)).subtracting(plan.createdFeeds)
        self.player = player
        removals = !plan.removedFeeds.isEmpty || !plan.pinnedRemovals.isEmpty || !plan.removedEpisodes.isEmpty || !plan.hiddenRemovals.isEmpty
        for ids in plan.removedEpisodes.values { structural.formUnion(ids) }
        structural.formUnion(plan.removedEpisodeIDs)
        for removal in plan.pinnedRemovals { structural.insert(removal.episodeID); structuralFeeds.insert(removal.feedID) }
        for absence in plan.deferredAbsences { structural.insert(absence.localID) }
        for transfer in plan.jobTransfers { structural.insert(transfer.from); structural.insert(transfer.to) }
        for move in plan.overlayMoves { structural.insert(move.local) }
        func local(ofKey key: String) throws -> Int64? {
            if key.hasPrefix("local-episode:") { return Int64(key.dropFirst("local-episode:".count)) }
            return try live.rows("SELECT local_id FROM ntp_episodes WHERE episode_id = ?", [.text(key)]).first?.first?.integer
        }
        for move in plan.ledgerMoves {
            for key in [move.from, move.to] { if let id = try local(ofKey: key) { structural.insert(id) } }
        }
        for (wire, mapping) in plan.episodeMappings {
            if let id = mapping.localID, created.contains(id) { continue }
            let current = try live.rows("SELECT local_id FROM ntp_episodes WHERE episode_id = ?", [.text(wire)]).first?.first?.integer
            guard mapping.mergedInto != nil || (mapping.localID != nil && current != mapping.localID) else { continue }
            if let id = mapping.localID { structural.insert(id) }
            if let current { structural.insert(current) }
        }
        structuralFeeds.formUnion(plan.removedFeeds)
        structuralFeeds.formUnion(plan.hiddenRemovals.map(\.feedID))
        structuralFeeds.formUnion(plan.hiddenRemovedFeeds)
        for merge in plan.feedMerges { structuralFeeds.insert(merge.source); structuralFeeds.insert(merge.survivor) }
        structuralFeeds.formUnion(plan.credentials.keys)
        for (podcast, mapping) in plan.podcastMappings {
            guard let feed = mapping.feedID else { continue }
            if !plan.createdFeeds.contains(feed) {
                let current = try live.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.integer
                guard current != feed else { continue }
                structuralFeeds.insert(feed)
                if let current { structuralFeeds.insert(current) }
            }
            // Created or mapped anew: identity matching found (or did not find) a local feed at its addresses.
            if let identity = try projector.record("podcast", podcast, "identity") {
                for alias in identity["aliases"]?.arrayValue ?? [] { if let normalized = alias["normalized"]?.stringValue { matchSources.insert(normalized) } }
                if let url = identity["refresh_url"]?.stringValue { matchSources.insert(ContractURL.normalize(ContractURL.stripUserinfo(url))) }
            }
        }
        // Identity rules it changes (a podcast projected whole names its rules unchanged: that is not a structural change).
        for (podcast, rules) in plan.identityRules {
            guard let row = try live.rows("SELECT feed_id, identity_rules FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first,
                  let feed = row[0].integer else { continue }
            if try row[1].data != rules.map({ try $0.canonicalData() }) { structuralFeeds.insert(feed) }
        }
    }
}

/// What a retained publication was built against (PROTOCOL §6.8): the point of the local-change log it read the library at, the
/// scope it projected, its projection context, and the cursors it moves between. A shadow, a Force full
/// synchronization and the recovery publication share it
/// (`FeedLibraryStore.rebase(_:stagedWork:workLimit:)`).
struct ServerRetainedBasis: Sendable, Equatable {
    var touches: ServerTouchWatermark
    var scope: ServerShadowScope
    var context: ServerProjectionContext
    /// The live cursor it was built on: it publishes only over exactly this one (a recovery publication's `replacing`).
    var source: SyncCursor?
    /// The cursor it publishes (a commit's, a snapshot's head).
    var target: SyncCursor?
}

/// The entities of a retained publication's scope that local writes touched since it was built, all of them simple row
/// images (no structural dependency of its plan): its switch re-projects them from the base and the current overlays, with
/// the original projection context, inside its bounded transaction, instead of writing its own images of them, so those
/// local actions are kept (PROTOCOL §6.8 "a bounded atomic switch that keeps concurrent local operations").
struct ServerTouchedRebase: Sendable {
    /// What to re-project, every field.
    var scope = ServerProjectionScope()
    /// Episode rows whose staged images are not written (the re-projection writes them).
    var rows: Set<Int64> = []
    /// The staged queue is not written; the re-projection projects it with the original context.
    var queue = false
    /// The switch's estimated row writes beside the staged plan's.
    var work = 0

    var isEmpty: Bool { scope.episodes.isEmpty && scope.podcasts.isEmpty && !queue }
}

extension FeedLibraryStore {
    /// Distinct things touched that a switch reads at most (each costs it a few keyed reads inside its transaction); more
    /// defers the publication to the pause.
    static let rebaseTouchLimit = 500
    /// Row writes of re-projecting one episode at a switch: its row, mapping, statistics units and pins.
    static let rebaseEpisodeWork = 4

    /// The rebase of a publication built on `basis`, inside the publication's transaction, before anything is written:
    /// which local changes since it was built it re-projects. Throws `ServerApplyError.deferred` when one of them meets a
    /// structural dependency of its plan or the log cannot be trusted (it is then published as a whole at the pause), or
    /// when its estimated work with `stagedWork` exceeds `workLimit` row writes (nil: no limit).
    /// `plan`: the staged plan, whose statistics units for a re-projected episode count too.
    func rebase(_ basis: ServerRetainedBasis, stagedWork: Int, workLimit: Int?, plan: ServerProjectionPlan? = nil) throws -> ServerTouchedRebase {
        let scope = basis.scope
        let touches = try serverTouches(since: basis.touches, limit: Self.rebaseTouchLimit)
        var rebase = ServerTouchedRebase()
        func deferred(_ reason: String) -> ServerApplyError { .deferred(reason) }
        if touches.unknown { throw deferred("the local changes since its staging cannot be known") }
        if touches.overflow { throw deferred("more local changes since its staging than a publication reads") }
        if touches.holds { throw deferred("recovery holds changed since its staging") }
        if touches.account, scope.everything || !scope.episodes.isEmpty || !scope.podcasts.isEmpty {
            throw deferred("an account-level change since its staging")
        }
        var episodes = touches.episodes, wires = touches.wire, feeds = touches.feeds
        var podcasts = Set<String>()
        for key in touches.overlays {
            guard let bar = key.firstIndex(of: "|") else { continue }
            let entity = key[..<bar], id = String(key[key.index(after: bar)...])
            switch entity {
            case "episode":
                if id.hasPrefix("local-episode:"), let local = Int64(id.dropFirst("local-episode:".count)) { episodes.insert(local) }
                else { wires.insert(id) }
            case "podcast":
                if id.hasPrefix("local-feed:"), let feed = Int64(id.dropFirst("local-feed:".count)) { feeds.insert(feed) }
                else { podcasts.insert(id) }
            default: break
            }
        }
        func podcast(ofFeed feed: Int64) throws -> String? {
            try database.rows("SELECT podcast_id FROM ntp_podcasts WHERE feed_id = ?", [.integer(feed)]).first?.first?.text
        }
        func localFolder(_ feed: Int64) throws -> Bool { try loadFeedHeader(feed)?.source.isLocalFeedSource == true }
        /// A local podcast no wire ID maps at an address of one it creates or maps anew (or gone: it may have been one).
        func couldMatch(_ feed: Int64) throws -> Bool {
            guard !scope.matchSources.isEmpty else { return false }
            guard let header = try loadFeedHeader(feed) else { return true }
            return !header.source.isLocalFeedSource && scope.matchSources.contains(ContractURL.normalize(ContractURL.stripUserinfo(header.source)))
        }
        func feedInScope(_ feed: Int64, _ podcast: String?) -> Bool {
            scope.everything || scope.feeds.contains(feed) || scope.structuralFeeds.contains(feed) || podcast.map(scope.podcasts.contains) == true
        }
        /// A feed its plan depends on whatever maps it live: one whose header or rows it writes, or which it maps anew
        /// or changes structurally (a pending registration's feed a recovery's snapshot resolves, `resolvedFeeds`, has no
        /// live mapping until the publication materializes it). Its image of that feed was read before the change.
        func planHoldsFeed(_ feed: Int64) -> Bool { scope.feeds.contains(feed) || scope.structuralFeeds.contains(feed) }
        // Podcasts: a podcast it projects changed locally, or a local podcast its identity matching could find.
        for feed in feeds {
            let mapped = try podcast(ofFeed: feed)
            if mapped == nil {
                // Never discarded for lacking a live mapping while its plan writes or maps the feed.
                if planHoldsFeed(feed) { throw deferred("a podcast it maps anew changed locally since its staging") }
                if try couldMatch(feed) { throw deferred("a local podcast created or changed since its staging could match what it maps") }
                continue
            }
            if feedInScope(feed, mapped) { throw deferred("a podcast it projects changed locally since its staging") }
        }
        for podcast in podcasts {
            if scope.everything || scope.podcasts.contains(podcast) { throw deferred("a podcast it projects changed locally since its staging") }
            // A podcast it did not project whose live feed it writes or maps anew.
            if let feed = try database.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.integer, planHoldsFeed(feed) {
                throw deferred("a podcast whose feed it writes changed locally since its staging")
            }
        }
        func local(ofWire wire: String) throws -> Int64? {
            try database.rows("SELECT local_id FROM ntp_episodes WHERE episode_id = ?", [.text(wire)]).first?.first?.integer
        }
        func wire(ofLocal local: Int64) throws -> String? {
            try database.rows("SELECT episode_id FROM ntp_episodes WHERE local_id = ?", [.integer(local)]).first?.first?.text
        }
        func inScope(_ local: Int64?, _ wire: String?) -> Bool {
            scope.everything || local.map { scope.rows.contains($0) || scope.structural.contains($0) } == true || wire.map(scope.episodes.contains) == true
        }
        /// An episode of a podcast its plan removes, merges, maps anew, gives credentials or changes the identity rules of
        /// (a podcast-only removal visits none of its episodes): read per touched episode, never by listing the
        /// podcast's. One whose row is gone cannot be placed, so it counts as one.
        func inStructuralFeed(_ local: Int64) throws -> Bool {
            guard !scope.structuralFeeds.isEmpty else { return false }
            guard let feed = try database.rows("SELECT feed_id FROM episodes WHERE id = ?", [.integer(local)]).first?.first?.integer else { return true }
            return scope.structuralFeeds.contains(feed)
        }
        // A download started, stopped or moved on an episode it projects, or of a podcast it changes structurally: its
        // media, merges and removals depend on the jobs.
        for local in touches.jobs where !scope.created.contains(local) {
            if try inScope(local, try wire(ofLocal: local)) || inStructuralFeed(local) {
                throw deferred("a download of an episode it projects started or stopped since its staging")
            }
        }
        if touches.player {
            let current = try ServerFullReprojection.player(database)
            if current != scope.player {
                let affected = (scope.player + current).compactMap { $0 }
                // The player moved onto or off an episode whose removal (a pinned one), merge or move it decides, also one
                // of a podcast it removes as a whole: the whole publication decides it again from the current selection.
                for local in affected {
                    let decided = scope.removals ? inScope(local, try wire(ofLocal: local)) : false
                    if try decided || inStructuralFeed(local) { throw deferred("the player moved off or onto an episode whose removal it decides") }
                }
                episodes.formUnion(affected)
            }
        }
        for wire in wires {
            let local = try local(ofWire: wire)
            if let local { episodes.insert(local) } else if inScope(nil, wire) { throw deferred("an episode it maps changed locally since its staging") }
        }
        for local in episodes where !scope.created.contains(local) {
            // A row its plan removes, merges or moves (mapped or derived), or of a podcast it does so with: its whole
            // original projection is needed.
            if try scope.structural.contains(local) || inStructuralFeed(local) {
                throw deferred("an episode it removes, merges or moves changed locally since its staging")
            }
            let wire = try wire(ofLocal: local)
            guard let wire else {
                // An episode no wire ID names: a local refresh's new item or a new subscription's, which identity
                // matching could find for a podcast it creates or projects.
                guard let row = try database.rows("SELECT feed_id FROM episodes WHERE id = ?", [.integer(local)]).first, let feed = row[0].integer else {
                    // Gone since its staging: an image of it would bring it back.
                    if scope.rows.contains(local) { throw deferred("an episode it writes was removed since its staging") }
                    continue
                }
                if try localFolder(feed), !scope.rows.contains(local) { continue }
                let mapped = try podcast(ofFeed: feed)
                if try (mapped == nil && (planHoldsFeed(feed) || couldMatch(feed))) || (mapped != nil && feedInScope(feed, mapped)) || scope.rows.contains(local) {
                    throw deferred("an episode created or changed since its staging could match what it maps")
                }
                continue
            }
            guard inScope(local, wire) else { continue }
            if scope.structural.contains(local) { throw deferred("an episode it removes, merges or moves changed locally since its staging") }
            rebase.rows.insert(local)
            rebase.scope.episodes[wire] = .all
        }
        if touches.queue, scope.queue || scope.everything {
            rebase.queue = true
            rebase.scope.queue = true
            rebase.scope.withdrawnQueue = basis.context.withdrawnQueue
        }
        // The switch's work, estimated before any of it is done: the staged plan's rows and the re-projection's, the queue
        // with every member and key it rewrites.
        let queueRows = rebase.queue ? Int(try database.scalar("SELECT count(*) FROM queue")) : 0
        // A re-projected episode may replace its statistics units in both tables (an episode can hold thousands): every
        // stored row deleted and as many inserted, and the staged plan's own for it, counted per row.
        var statistics = 0
        for local in rebase.rows {
            let wire = try wire(ofLocal: local)
            let stored = try database.scalar("SELECT count(*) FROM statistics_units WHERE episode_id = ?", [.integer(local)])
                + (try wire.map { try database.scalar("SELECT count(*) FROM ntp_statistics_units WHERE episode_id = ?", [.text($0)]) } ?? 0)
            let planned = (plan?.libraryStatisticsRows[local] ?? 0) + (wire.flatMap { plan?.statisticsRows[$0] } ?? 0)
            statistics += 2 * Int(stored) + 2 * planned
        }
        rebase.work = rebase.rows.count * Self.rebaseEpisodeWork + statistics + (rebase.queue ? 2 * (queueRows + basis.scope.created.count) + 16 : 0)
        if let workLimit, stagedWork + rebase.work > workLimit {
            throw deferred("\(stagedWork + rebase.work) row writes with the local changes since its staging, over the publication budget")
        }
        return rebase
    }

    /// The staged plan without what the rebase re-projects: its queue, and the deferred pins of its episodes (pins merge
    /// by union, so a stale one would outlive the re-projection).
    static func plan(_ plan: ServerProjectionPlan, without rebase: ServerTouchedRebase) -> ServerProjectionPlan {
        guard !rebase.isEmpty else { return plan }
        var plan = plan
        if rebase.queue { plan.queue = nil; plan.queueKeys = [:] }
        plan.deferredPins = plan.deferredPins.filter { rebase.scope.episodes[$0.key] == nil }
        return plan
    }

    /// Re-projects what the rebase names, live, with the original projection context, after the staged images and plan
    /// were written (everything else already shows the commit), and writes it: the touched rows were not overwritten,
    /// and none of them is in a structural change of the plan, so their local changes are kept.
    func writeRebase(_ rebase: ServerTouchedRebase, basis: ServerRetainedBasis, context: ServerLibraryContext, now: Int64,
                     history: ServerHistoryOracle?, result: inout ServerUnitResult) throws {
        guard !rebase.isEmpty else { return }
        let projector = try unitProjector(context: context, now: now)
        projector.history = history
        projector.commitResets = basis.context.commitResets
        if basis.context.full {
            projector.fullBase = "full"
            projector.admissionsSeen = basis.context.admissionsSeen
            projector.resolvedFeeds = basis.context.resolvedFeeds
        }
        try projector.project(rebase.scope)
        try writePlan(projector.plan, now: now, result: &result)
        result.rebased = rebase.rows.count + (rebase.queue ? 1 : 0)
    }
}

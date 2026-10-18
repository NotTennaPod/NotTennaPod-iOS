import Foundation

/// Merges the server decided (PROTOCOL §9.7): an episode whose `identity` record names
/// `merged_into`, a podcast whose `subscription` is `merged`. The survivor's records carry the merged state; this
/// library moves what only it holds (its rows, downloads, discovery ledger entries) to the survivor, never interrupting
/// playback: a row the player holds stays until the player leaves it.
extension ServerProjector {
    /// An episode merged into `survivor`. Without a row of the survivor here, this episode's row becomes the survivor's
    /// (its download, playback and queue entry stay as they are). With one, this row's download moves to the survivor's
    /// row when that has none, and this row goes, once the player no longer holds it; the survivor's records keep one
    /// queue entry. The discovery ledger's entries move to the survivor.
    func projectMergedEpisode(_ episode: String, into survivor: String, podcast: String, kind: String, value: String,
                              occurrence: ContractJSON?, local: Int64?) throws {
        plan.ledgerMoves.append((episode, survivor))
        guard let local, let row = try episodeRow(local) else {
            plan.episodeMappings[episode] = (nil, podcast, kind, value, occurrence, survivor)
            return
        }
        // The survivor's podcast (another one after a podcast merge), its feed here, and its row (mapped, or derived).
        let survivorPodcast = try record("episode", survivor, "identity")?["podcast_id"]?.stringValue ?? podcast
        let survivorFeed = try feed(ofPodcast: survivorPodcast)
        if try localEpisode(survivor) == nil, let survivorFeed,
           let derived = try derivedLocal(survivor, podcast: survivorPodcast, feedID: survivorFeed), derived != local {
            plan.episodeMappings[survivor] = (derived, survivorPodcast, "", "", nil, nil)
        }
        if try localEpisode(survivor) == nil, survivorFeed == row.feedID {
            plan.episodeMappings[survivor] = (local, survivorPodcast, kind, value, occurrence, nil)
            plan.episodeMappings[episode] = (nil, podcast, kind, value, occurrence, survivor)
            try projectEpisode(survivor, fields: .all)
            if try localEpisode(survivor) == local { return }
        } else {
            try projectEpisode(survivor, fields: .all)
        }
        plan.episodeMappings[episode] = (local, podcast, kind, value, occurrence, survivor)
        guard let target = try localEpisode(survivor), target != local else { return }
        try handOver(local, row: row, to: target, episode: episode)
    }

    /// A source row goes, its download (a finished file, or an active job) passing to the survivor's row `target` when
    /// that has none; the player keeps it until it leaves it.
    private func handOver(_ local: Int64, row: (feedID: Int64, episode: LibraryEpisode), to target: Int64, episode: String) throws {
        guard var kept = try episodeRow(target) else { return }
        if row.episode.userState.isDownloaded, row.episode.details.media != nil, !kept.episode.userState.isDownloaded {
            // The file now belongs to the survivor's row; removing this row never deletes a file another row names.
            kept.episode.userState.isDownloaded = true
            kept.episode.userState.localFileURL = row.episode.userState.localFileURL
            kept.episode.userState.downloadDate = row.episode.userState.downloadDate
            if kept.episode.details.media == nil { kept.episode.details.media = row.episode.details.media }
            plan.episodes[target] = (kept.feedID, kept.episode)
            // A finished download wins over one still running that another merged row would have moved here: that one
            // stays with its row and is retired with it.
            plan.jobTransfers.removeAll { $0.to == target }
        } else if !row.episode.userState.isDownloaded, !kept.episode.userState.isDownloaded,
                  !plan.jobTransfers.contains(where: { $0.to == target }),
                  try db.scalar("SELECT count(*) FROM download_jobs WHERE episode_id = ? AND active = 1", [.integer(local)]) > 0,
                  try db.scalar("SELECT count(*) FROM download_jobs WHERE episode_id = ? AND active = 1", [.integer(target)]) == 0 {
            // An active download (waiting or transferring) goes on as the survivor's: the same job, destination and
            // progress; its completion gives the survivor the file. The survivor takes one: as the
            // plan has it so far, it has no file and no job moved to it yet; another merged row's job is retired with
            // its row.
            plan.jobTransfers.append((local, target))
            if kept.episode.userState.localFileURL == nil, let partial = row.episode.userState.localFileURL {
                kept.episode.userState.localFileURL = partial
            }
            if kept.episode.details.media == nil { kept.episode.details.media = row.episode.details.media }
            plan.episodes[target] = (kept.feedID, kept.episode)
        }
        if isPinned(local) {
            // The player keeps it until it leaves it (PROTOCOL §6.8); then it goes (`releaseServerPins`).
            plan.deferredAbsences.append((local, episode, row.feedID))
        } else {
            plan.removedEpisodes[row.feedID, default: []].append(local)
            plan.removedEpisodeIDs.insert(local)
            plan.episodes[local] = nil
            plan.removedEpisodeCount += 1 + (try cascadedStatisticsRows(episode: local))
            plan.queueStale = true
        }
    }

    /// A podcast merged into `survivor` (PROTOCOL §9.7): without a feed of the survivor here, this feed becomes the survivor's;
    /// otherwise its episodes merge as above, the survivor's feed takes this feed's device-only settings when it has
    /// none of its own, and this feed goes once nothing plays from it (a pinned removal, PROTOCOL §6.8). Every episode
    /// merges inside this unit, its row moved or deleted, however many there are; only the emptied feed's removal can
    /// come after it.
    func projectMergedPodcast(_ podcast: String, into survivor: String, feedID: Int64) throws {
        // The source's live generation joins the survivor's live class (PROTOCOL §9.7): its releases are the survivor
        // generation's; a closed source generation stays closed.
        if let from = try db.rows("SELECT live_generation FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.text,
           let to = try record("podcast", survivor, "subscription")?["generation_id"]?.stringValue, from != to {
            plan.generationMoves.append((from, to))
        }
        if try feed(ofPodcast: survivor) == nil {
            plan.podcastMappings[survivor] = (feedID, nil)
            plan.podcastMappings[podcast] = (nil, nil)
            forgetFeed(ofPodcast: podcast)
            forgetFeed(ofPodcast: survivor)
            try projectPodcast(survivor, fields: .all)
            return
        }
        guard let target = try feed(ofPodcast: survivor), target != feedID, var survivorHeader = try feedHeader(target),
              let source = try feedHeader(feedID) else { return }
        if survivorHeader.hasDefaultDeviceSettings, !source.hasDefaultDeviceSettings {
            survivorHeader.adoptDeviceSettings(of: source)
            plan.feeds[target] = survivorHeader
        }
        // Per-feed speed and skip silence live in the library's playback file: the app carries them (`ntp_feed_merges`).
        plan.feedMerges.append((feedID, target))
        // Each episode of this feed merges into its survivor first (its download moves), then the feed goes, unless a row
        // of it is still covered by this library's discovery work (`mergeRows`).
        let classified = try mergeRows(podcast: podcast, feedID: feedID)
        for row in classified.merge {
            let occurrence = row.identity["occurrence"]
            try projectMergedEpisode(row.episode, into: row.into, podcast: podcast, kind: occurrence?["k"]?.stringValue ?? "none",
                                     value: occurrence?["v"]?.stringValue ?? "", occurrence: occurrence, local: row.local)
        }
        if classified.waits { return }
        // A row without a merged identity of its own whose occurrence the survivor holds (a provisional release the
        // server learned under the survivor) hands its download over to the survivor's row before the feed goes.
        for local in classified.unmerged {
            guard let row = try episodeRow(local), try row.episode.userState.isDownloaded || hasActiveJob(local),
                  let survivorEpisode = try survivorEpisode(of: local, source: podcast, survivor: survivor) else { continue }
            plan.ledgerMoves.append((FeedLibraryStore.ledgerKey(localEpisode: local), survivorEpisode))
            if try localEpisode(survivorEpisode) == nil { try projectEpisode(survivorEpisode, fields: .all) }
            guard let target = try localEpisode(survivorEpisode), target != local else { continue }
            try handOver(local, row: row, to: target, episode: survivorEpisode)
        }
        try remove(feedID: feedID, podcast: podcast, merged: true)
    }

    private func hasActiveJob(_ local: Int64) throws -> Bool {
        try db.scalar("SELECT count(*) FROM download_jobs WHERE episode_id = ? AND active = 1", [.integer(local)]) > 0
    }

    /// The survivor's episode a row's own occurrence (its local item's GUID and publication time, or kind and value)
    /// became, when the base has it: a survivor episode with that occurrence, or a source episode with it merged into one.
    private func survivorEpisode(of local: Int64, source: String, survivor: String) throws -> String? {
        guard let item = try db.rows("SELECT kind, value, guid, publication_time FROM ntp_local_items WHERE local_id = ?", [.integer(local)]).first,
              let kind = item[0].text, let value = item[1].text else { return nil }
        let guid = item[2].text, time = item[3].integer
        for row in try db.rows("SELECT id, CAST(value AS TEXT) FROM \(baseTable) WHERE entity = 'episode' AND field_group = 'identity' AND ((json_extract(CAST(value AS TEXT), '$.podcast_id') = ? AND json_extract(CAST(value AS TEXT), '$.merged_into') IS NULL) OR (json_extract(CAST(value AS TEXT), '$.podcast_id') = ? AND json_extract(CAST(value AS TEXT), '$.merged_into') IS NOT NULL))",
                               [.text(survivor), .text(source)]) {
            guard let id = row[0].text, let text = row[1].text else { continue }
            let identity = try ContractJSON.decode(Data(text.utf8))
            guard let occurrence = identity["occurrence"] else { continue }
            let matches: Bool
            if let guid, let time {
                matches = occurrence["guid"]?.stringValue == guid && occurrence["publication_time"]?.integerValue == time
            } else {
                matches = occurrence["k"]?.stringValue == kind && occurrence["v"]?.stringValue == value
            }
            if matches { return identity["merged_into"]?.stringValue ?? id }
        }
        return nil
    }

    /// A merged feed's rows: those to merge (their own wire binding, or an unprotected derivation, has a merged
    /// identity), those without a merged identity, and whether the feed waits. It waits while a row this library's
    /// pending discovery work covers (`pendingDiscoveryRows`, by its own occurrence) has no merged identity of its own:
    /// a provisional release derives an earlier release's wire ID, whose merge says nothing of it.
    func mergeRows(podcast: String, feedID: Int64) throws -> ServerMergeRows {
        if let known = precomputedMerges[feedID] { return known }
        let protected = try pendingDiscoveryRows(feedID: feedID)
        var own: [(episode: String, local: Int64)] = try db.rows("SELECT n.episode_id, n.local_id FROM ntp_episodes n JOIN episodes e ON e.id = n.local_id WHERE e.feed_id = ?",
                                                                 [.integer(feedID)]).compactMap { row in
            guard let episode = row[0].text, let local = row[1].integer else { return nil }
            return (episode, local)
        }
        own.sort { $0.episode.utf8.lexicographicallyPrecedes($1.episode.utf8) }
        let ownLocals = Set(own.map(\.local))
        let derived = try derivationMap(podcast: podcast, feedID: feedID).map { (episode: $0.key, local: $0.value) }
            .sorted { $0.episode.utf8.lexicographicallyPrecedes($1.episode.utf8) }
        var merge: [(episode: String, local: Int64, into: String, identity: ContractJSON)] = []
        var merged = Set<Int64>(), waits = false
        for (episode, local) in own + derived {
            guard let identity = try record("episode", episode, "identity"), let into = identity["merged_into"]?.stringValue, into != episode else {
                if protected.contains(local) { waits = true }
                continue
            }
            // A row merges by its own binding, or by a derivation whose merged identity is its own occurrence: an earlier
            // release's ID a provisional release derives says nothing of it (it is handed over by its own occurrence, or
            // waits while its discovery is pending).
            if !ownLocals.contains(local), try !isOwnOccurrence(local, identity) {
                if protected.contains(local) { waits = true }
                continue
            }
            merge.append((episode, local, into, identity)); merged.insert(local)
        }
        // A covered row no binding or derivation names (a provisional release) waits too.
        if !protected.subtracting(merged).isEmpty { waits = true }
        // Rows without a merged identity that hold a download (a file or an active job): those a survivor may take.
        let holding = try db.rows("SELECT id FROM episodes WHERE feed_id = ? AND (json_extract(CAST(record AS TEXT), '$.userState.isDownloaded') = 1 OR id IN (SELECT episode_id FROM download_jobs WHERE active = 1))",
                                  [.integer(feedID)]).compactMap { $0[0].integer }
        return ServerMergeRows(merge: merge, unmerged: holding.filter { !merged.contains($0) }, waits: waits,
                               token: try ServerMergeRows.token(db, feedID: feedID))
    }

    /// Whether a merged identity's occurrence is a row's own (its local item's GUID and publication time agree; a row or
    /// an occurrence without that evidence is taken as its own, as its derivation names it).
    func isOwnOccurrence(_ local: Int64, _ identity: ContractJSON) throws -> Bool {
        guard let item = try db.rows("SELECT guid, publication_time FROM ntp_local_items WHERE local_id = ?", [.integer(local)]).first else { return true }
        let occurrence = identity["occurrence"]
        if let time = occurrence?["publication_time"]?.integerValue, let own = item[1].integer, time != own { return false }
        if let guid = occurrence?["guid"]?.stringValue, let own = item[0].text, guid != own { return false }
        return true
    }

    /// The rows of a feed this library's discovery work the server has not applied yet covers: listed observation work
    /// of the row, or an unretired observation or proposal (in the outbox, or kept for a recovery and not refused)
    /// naming the row's own occurrence (its local item's kind, value and publication time) or its own wire binding.
    func pendingDiscoveryRows(feedID: Int64) throws -> Set<Int64> {
        var rows = Set(try db.rows("SELECT local_id FROM ntp_observation_work WHERE feed_id = ? AND local_id IS NOT NULL", [.integer(feedID)]).compactMap { $0[0].integer })
        var occurrences = Set<String>(), wires = Set<String>()
        func collect(_ json: ContractJSON) {
            switch json {
            case .object(let object):
                if let occurrence = object["occurrence"], let k = occurrence["k"]?.stringValue, let v = occurrence["v"]?.stringValue {
                    occurrences.insert("\(k)\u{0}\(v)\u{0}\(occurrence["publication_time"]?.integerValue.map(String.init) ?? "")")
                }
                if let id = object["episode_id"]?.stringValue { wires.insert(id) }
                for member in object.members { collect(member.value) }
            case .array(let items): for item in items { collect(item) }
            default: break
            }
        }
        for row in try db.rows("SELECT fact FROM ntp_outbox WHERE type IN ('catalog.observe', 'discovery.propose')") {
            if let data = row[0].data { collect(try ContractJSON.decode(data)) }
        }
        for row in try db.rows("SELECT fact FROM ntp_retained WHERE json_extract(CAST(fact AS TEXT), '$.type') IN ('catalog.observe', 'discovery.propose') AND json_extract(CAST(lineage AS TEXT), '$.unrestored') IS NULL") {
            if let data = row[0].data { collect(try ContractJSON.decode(data)) }
        }
        guard !occurrences.isEmpty || !wires.isEmpty else { return rows }
        for row in try db.rows("SELECT e.id, i.kind, i.value, i.publication_time, n.episode_id FROM episodes e LEFT JOIN ntp_local_items i ON i.local_id = e.id LEFT JOIN ntp_episodes n ON n.local_id = e.id WHERE e.feed_id = ?",
                               [.integer(feedID)]) {
            guard let local = row[0].integer else { continue }
            if let kind = row[1].text, let value = row[2].text,
               occurrences.contains("\(kind)\u{0}\(value)\u{0}\(row[3].integer.map(String.init) ?? "")") { rows.insert(local); continue }
            if let own = row[4].text, wires.contains(own) { rows.insert(local) }
        }
        return rows
    }

    /// Whether a merged podcast's feed still waits for this library's discovery work before its merge completes.
    func mergeWaits(podcast: String, feedID: Int64) throws -> Bool { try mergeRows(podcast: podcast, feedID: feedID).waits }
}

extension ServerMergeRows {
    static func token(_ db: LibrarySQLite, feedID: Int64) throws -> [Int64] {
        [try db.scalar("SELECT knowledge_clock FROM ntp_library WHERE id = 1"),
         try db.rows("SELECT generation FROM feed_changes WHERE feed_id = ?", [.integer(feedID)]).first?.first?.integer ?? 0,
         try db.scalar("SELECT count(*) FROM ntp_observation_work WHERE feed_id = ?", [.integer(feedID)]),
         try db.scalar("SELECT count(*) FROM ntp_outbox"), try db.scalar("SELECT count(*) FROM ntp_retained")]
    }
}

/// A merged feed's rows as `ServerProjector.mergeRows` classifies them, with the state it read them in: a deferred
/// merge's step classifies off the store and its unit uses that classification while the state is the same.
struct ServerMergeRows: Sendable {
    var merge: [(episode: String, local: Int64, into: String, identity: ContractJSON)]
    var unmerged: [Int64]
    var waits: Bool
    /// The knowledge clock, the feed's change generation and its listed observations when read.
    var token: [Int64] = []
}

/// Deferred podcast merges completed one podcast a step, at most `perExchange` an exchange (PROTOCOL §6.8): the
/// candidates (merged podcasts whose feed is still here, not being removed) and whether each still waits are read on a
/// connection of their own; each completion is one store unit, which merges every episode of its podcast and deletes or
/// moves all of its rows (its work grows with the podcast; it is not split into bounded transactions). Candidates are
/// durable state, so a relaunch continues where the steps stopped.
enum ServerDeferredMerges {
    struct Candidate: Sendable, Equatable { var podcast: String; var feedID: Int64 }

    /// At most this many completions an exchange; the rest wait for the next.
    static let perExchange = 8

    static func candidates(_ db: LibrarySQLite) throws -> [Candidate] {
        guard try db.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'ntp_hidden_feeds'") == 1 else { return [] }
        return try db.rows("SELECT p.podcast_id, p.feed_id FROM ntp_podcasts p JOIN ntp_records r ON r.entity = 'podcast' AND r.id = p.podcast_id AND r.field_group = 'subscription' JOIN feeds f ON f.id = p.feed_id WHERE p.pinned_removal = 0 AND json_extract(CAST(r.value AS TEXT), '$.state') = 'merged' AND p.feed_id NOT IN (SELECT feed_id FROM ntp_hidden_feeds) ORDER BY p.feed_id").compactMap { row in
            guard let podcast = row[0].text, let feed = row[1].integer else { return nil }
            return Candidate(podcast: podcast, feedID: feed)
        }
    }

    static func candidates(_ url: URL) throws -> [Candidate] {
        try ServerBlockingSteps.read(url) { try candidates($0) }
    }

    /// A candidate's rows classified on a connection of their own (the derivations of a whole feed are read there, not
    /// under the store).
    static func classify(_ url: URL, _ candidate: Candidate, now: Int64) throws -> ServerMergeRows? {
        try ServerBlockingSteps.read(url) { db in
            guard let row = try db.rows("SELECT namespace, account_id FROM ntp_library WHERE id = 1").first,
                  let namespace = row[0].text, let account = row[1].text else { return nil }
            let projector = ServerProjector(db: db, namespace: namespace, accountID: account, now: now) { _ in throw ServerApplyError.needsLocalIDs }
            return try projector.mergeRows(podcast: candidate.podcast, feedID: candidate.feedID)
        }
    }

    /// One step: the candidate's merge completes in one store unit, with the classification read off the store while
    /// nothing changed since (otherwise a later step classifies again), unless it still waits.
    static func step(_ store: FeedLibraryStore, database url: URL, candidate: Candidate, history: ServerArchiveReader?,
                     now: Int64) async throws -> ServerUnitResult? {
        guard let classified = try classify(url, candidate, now: now), !classified.waits else { return nil }
        return try await store.completeDeferredServerMerge(podcast: candidate.podcast, feedID: candidate.feedID, classified: classified,
                                                           history: history, now: now)
    }
}

/// A podcast merge of two feeds of this library (PROTOCOL §9.7) whose per-feed speed and skip silence, kept in the library's
/// playback file, the app still has to carry to the survivor.
public struct ServerFeedMerge: Sendable, Equatable {
    public let source: Int64
    public let survivor: Int64
}

extension FeedLibraryStore {
    /// Completes one podcast merge a feed's pending discovery work deferred (`ServerDeferredMerges`, in steps): the
    /// merged podcast is projected again in a unit of its own. Nil when it still waits or is done.
    func completeDeferredServerMerge(podcast: String, feedID: Int64? = nil, classified: ServerMergeRows? = nil,
                                     history: ServerHistoryOracle?, now: Int64) throws -> ServerUnitResult? {
        guard let context = serverContext else { return nil }
        try ensureServerExchangeTables()
        let clock = ContinuousClock(), started = clock.now
        var completed = false
        var result = try write(.remote, durable: true) {
            var result = ServerUnitResult(seq: try serverExchangeState().cursor?.seq ?? 0)
            let projector = try unitProjector(context: context, now: now)
            projector.history = history
            if let classified, let feedID {
                // The classification read off the store holds only while nothing changed since.
                guard try ServerMergeRows.token(database, feedID: feedID) == classified.token else { return result }
                projector.precomputedMerges[feedID] = classified
            }
            guard let feed = try projector.feed(ofPodcast: podcast), try !projector.mergeWaits(podcast: podcast, feedID: feed) else { return result }
            var scope = ServerProjectionScope()
            scope.podcasts[podcast] = [.subscription]
            try projector.project(scope)
            let plan = projector.plan
            if !plan.missingSecrets.isEmpty { throw ServerApplyError.missingSecrets(plan.missingSecrets) }
            result.work = plan.work
            try writePlan(plan, now: now, result: &result)
            completed = true
            return result
        }
        guard completed else { return nil }
        result.lockMilliseconds = Self.milliseconds(started.duration(to: clock.now))
        return result
    }

    /// Every deferred merge that no longer waits, one unit each (a small library, tests): the engine runs
    /// `ServerDeferredMerges` steps instead.
    @discardableResult
    func completeDeferredServerMerges(history: ServerHistoryOracle?, now: Int64) throws -> [ServerUnitResult] {
        guard serverContext != nil else { return [] }
        var results: [ServerUnitResult] = []
        for candidate in try database.transaction(write: false, { try ServerDeferredMerges.candidates(database) }) {
            if let result = try completeDeferredServerMerge(podcast: candidate.podcast, history: history, now: now) { results.append(result) }
        }
        return results
    }

    /// The podcast merges whose per-feed speed and skip silence are still to carry, oldest first.
    public func serverFeedMerges() throws -> [ServerFeedMerge] {
        guard serverContext != nil else { return [] }
        return try database.rows("SELECT source_feed, survivor_feed FROM ntp_feed_merges ORDER BY rowid").compactMap { row in
            guard let source = row[0].integer, let survivor = row[1].integer else { return nil }
            return ServerFeedMerge(source: source, survivor: survivor)
        }
    }

    /// Called once the copy is saved: a crash before it redoes the (idempotent) copy. A pair that moved on to another
    /// survivor meanwhile stays.
    public func finishServerFeedMerge(_ merge: ServerFeedMerge) throws {
        guard serverContext != nil else { return }
        try database.transaction {
            try database.execute("DELETE FROM ntp_feed_merges WHERE source_feed = ? AND survivor_feed = ?", [.integer(merge.source), .integer(merge.survivor)])
        }
    }
}

extension PlaybackSpeedPreferenceStore {
    /// Carries each pending podcast merge's per-feed speed and skip silence (PROTOCOL §9.7): the survivor takes the source's when
    /// it has neither of its own; the pair is finished only after the playback file is saved.
    public func carryServerFeedMerges(from store: FeedLibraryStore) async throws {
        for merge in try await store.serverFeedMerges() {
            try adoptFeedSettings(from: merge.source, to: merge.survivor)
            try await store.finishServerFeedMerge(merge)
        }
    }
}

extension LibraryFeed {
    /// The device-only settings a podcast merge carries to a survivor that has none of its own (PROTOCOL §9.7): those PROTOCOL §4
    /// keeps on the device, not the synced subscription, policy and credentials.
    var hasDefaultDeviceSettings: Bool {
        let fresh = LibraryFeed(id: id, source: source, metadata: metadata, episodes: [])
        return customTitle == nil && tags == fresh.tags && autoDownload == fresh.autoDownload
            && automaticDownloadFilter == fresh.automaticDownloadFilter && skipPreferences == fresh.skipPreferences
            && volumeAdaptation == fresh.volumeAdaptation && autoDelete == fresh.autoDelete
            && showEpisodeNotification == fresh.showEpisodeNotification && episodeSortOrderCode == nil && episodeFilterValues == nil
    }

    mutating func adoptDeviceSettings(of source: LibraryFeed) {
        customTitle = source.customTitle; tags = source.tags; autoDownload = source.autoDownload
        automaticDownloadFilter = source.automaticDownloadFilter; skipPreferences = source.skipPreferences
        volumeAdaptation = source.volumeAdaptation; autoDelete = source.autoDelete
        showEpisodeNotification = source.showEpisodeNotification
        episodeSortOrderCode = source.episodeSortOrderCode; episodeFilterValues = source.episodeFilterValues
    }
}

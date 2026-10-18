import Foundation

/// The episode field groups a projection writes (PROTOCOL §6.8).
struct ServerEpisodeFields: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let playState = Self(rawValue: 1 << 0)
    static let position = Self(rawValue: 1 << 1)
    static let favorite = Self(rawValue: 1 << 2)
    static let lastPlayed = Self(rawValue: 1 << 3)
    static let history = Self(rawValue: 1 << 4)
    static let playedTime = Self(rawValue: 1 << 5)
    static let duration = Self(rawValue: 1 << 6)
    static let metadata = Self(rawValue: 1 << 7)
    static let statisticsUnits = Self(rawValue: 1 << 8)
    static let admission = Self(rawValue: 1 << 9)
    static let identity = Self(rawValue: 1 << 10)
    static let all = Self(rawValue: (1 << 11) - 1)

    /// The fields an episode record's field group determines; queue groups are the queue's.
    static func of(group: String) -> Self {
        switch group {
        case "play_state": .playState
        case "position": .position
        case "favorite": .favorite
        case "last_played": .lastPlayed
        case "history": .history
        case "played_time": .playedTime
        case "measured_duration": .duration
        case "metadata": .metadata
        case "statistics_units": .statisticsUnits
        case "admission": .admission
        case "identity": .identity
        default: []
        }
    }

    /// The fields an overlay property shows over (PROTOCOL §6.8).
    static func of(property: String) -> Self {
        switch property {
        case "play_state": .playState
        case "position": .position
        case "favorite": .favorite
        case "last_played": .lastPlayed
        case "history", "history_mark": .history
        case "played_time", "played_time_base": .playedTime
        // A playback completion's bundle (PROTOCOL §6.8): PLAYED and position 0 (and the queue, below).
        case "completion": [.playState, .position]
        default: []
        }
    }
}

struct ServerPodcastFields: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let identity = Self(rawValue: 1 << 0)
    static let subscription = Self(rawValue: 1 << 1)
    static let policy = Self(rawValue: 1 << 2)
    static let credentials = Self(rawValue: 1 << 3)
    static let metadata = Self(rawValue: 1 << 4)
    static let identityRules = Self(rawValue: 1 << 5)
    /// The server's refresh status of the podcast (`LibraryFeed.serverRefresh`).
    static let refreshStatus = Self(rawValue: 1 << 6)
    static let all = Self(rawValue: (1 << 7) - 1)

    static func of(group: String) -> Self {
        switch group {
        case "identity": .identity
        case "subscription": .subscription
        case "policy": .policy
        case "credentials": .credentials
        case "metadata": .metadata
        case "identity_rules": .identityRules
        case "refresh_status": .refreshStatus
        default: []
        }
    }

    static func of(property: String) -> Self {
        switch property {
        case "subscription": .subscription
        case "keep_updated", "new_episodes_action": .policy
        case "credentials": .credentials
        case "refresh_url": .identity
        default: []
        }
    }

    static let queueGroups: Set<String> = ["queue_membership", "queue_position"]
}

/// What a unit re-projects (PROTOCOL §6.8 plan): the entities whose records changed or whose overlays retire, by field.
struct ServerProjectionScope: Sendable {
    var podcasts: [String: ServerPodcastFields] = [:]
    var episodes: [String: ServerEpisodeFields] = [:]
    /// Fields of every mapped episode (an account-level overlay retires: a history clear or statistics reset).
    var allEpisodes: ServerEpisodeFields = []
    var queue = false
    /// The account's policies changed (the `AccountPolicy` facade reloads).
    var accountPolicies = false
    /// Episodes (overlay IDs) a retiring queue add or restore the server refused or did not apply had shown as queued
    ///, or a queue filing whose release another proposal admitted first
    ///: unless something else supports them, they leave the queue.
    var withdrawnQueue: Set<String> = []

    static func withdrawsQueue(type: String, outcome: String?) -> Bool {
        (type == "queue.add" || type == "queue.restore" || type == "discovery.propose")
            && ["rejected", "not_applied", "op_id_conflict"].contains(outcome ?? "")
    }

    /// The episodes a retiring fact's overlays showed as queued, when it withdraws them.
    mutating func withdraw(_ db: LibrarySQLite, opID: String, type: String, outcome: String?) throws {
        guard Self.withdrawsQueue(type: type, outcome: outcome) else { return }
        for row in try db.rows("SELECT id FROM ntp_overlays WHERE op_id = ? AND entity = 'episode' AND property = 'queue_membership' AND kind = 'register' AND CAST(value AS TEXT) = 'true'",
                               [.text(opID)]) {
            if let id = row[0].text { withdrawnQueue.insert(id); queue = true }
        }
    }

    var isEmpty: Bool { podcasts.isEmpty && episodes.isEmpty && allEpisodes.isEmpty && !queue }

    mutating func add(record entity: String, id: String, group: String) {
        switch entity {
        case "podcast": podcasts[id, default: []].formUnion(.of(group: group))
        case "episode":
            if ServerPodcastFields.queueGroups.contains(group) { queue = true; episodes[id, default: []].formUnion([]) }
            else { episodes[id, default: []].formUnion(.of(group: group)) }
        case "account": accountPolicies = true
        default: break
        }
    }

    mutating func add(overlay entity: String, id: String, property: String) {
        switch entity {
        case "podcast": podcasts[id, default: []].formUnion(.of(property: property))
        case "episode":
            if property == "queue_membership" || property == "queue_position" { queue = true }
            else { episodes[id, default: []].formUnion(.of(property: property)) }
            if property == "completion" { queue = true }
        case "account":
            switch property {
            case "history": allEpisodes.insert(.history)
            case "played_time": allEpisodes.insert(.playedTime)
            default: accountPolicies = true
            }
        default: break
        }
    }
}

/// A unit's row writes (PROTOCOL §6.8): full post-commit images of every affected row, written with keyed statements only.
struct ServerProjectionPlan {
    /// Feed headers to upsert (episodes empty), by local feed ID.
    var feeds: [Int64: LibraryFeed] = [:]
    var createdFeeds: Set<Int64> = []
    /// Episodes to upsert, by local episode ID.
    var episodes: [Int64: (feedID: Int64, episode: LibraryEpisode)] = [:]
    var createdEpisodes: Set<Int64> = []
    /// Feeds the server removed (a remote unsubscribe): the existing feed deletion runs in the unit (PROTOCOL §6.8).
    var removedFeeds: [Int64] = []
    /// A removal whose podcast holds the player's current episode (PROTOCOL §6.8): the other episodes go, the playing one stays
    /// for the player only.
    var pinnedRemovals: [(feedID: Int64, podcast: String, episodeID: Int64)] = []
    /// Feeds of `pinnedRemovals` and `hiddenRemovals` that go because their podcast merged into a live one (PROTOCOL
    /// §9.7): no generation closed, so the player's episode keeps its sync identity; every other removal detaches it.
    var mergeRemovals: Set<Int64> = []
    /// Podcasts whose generation this plan closes (a removal, or a new generation over a closed one): the overlays of
    /// this library's pending facts on their episodes are of the closed generation and go with its rows (PROTOCOL §6.8).
    var closedPodcasts: Set<String> = []
    /// The generation each removed feed's podcast had live before this plan (what a removal closes).
    var closedGenerations: [Int64: String] = [:]
    var podcastMappings: [String: (feedID: Int64?, liveGeneration: String?)] = [:]
    var identityRules: [String: ContractJSON?] = [:]
    var episodeMappings: [String: (localID: Int64?, podcast: String, kind: String, value: String, occurrence: ContractJSON?, mergedInto: String?)] = [:]
    /// The queue in its new order and the keys of its members, when it changed: the final order, computed by
    /// `projectQueue` (an empty list empties the queue).
    var queue: [Int64]?
    var queueKeys: [Int64: ServerQueueKeyRow] = [:]
    /// The queue needs projecting again (a removal, a created feed, a completion whose claim changed): only
    /// `projectQueue` clears it, and `writePlan` refuses a plan that still has it, so a queue is written only once computed.
    var queueStale = false
    /// Feed credentials: the local credential the feed shows (nil: none).
    var credentials: [Int64: UUID?] = [:]
    /// Secrets the unit needs that this library has not fetched (PROTOCOL §6.8): the unit cannot run without them.
    var missingSecrets: Set<String> = []
    var statisticsUnits: [String: ContractJSON?] = [:]
    /// The library table's units (`statistics_units`, schema 20) of local episodes whose projection changed: the
    /// record's units by local episode ID, without those a pending local reset covers (PROTOCOL §15.2).
    var libraryStatisticsUnits: [Int64: [LibraryStatisticsUnit]] = [:]
    /// Rows replacing an episode's units writes in each statistics table: the stored rows it deletes and the rows it
    /// inserts (an episode may hold thousands of units).
    var statisticsRows: [String: Int] = [:]
    var libraryStatisticsRows: [Int64: Int] = [:]
    var admissions: [(generation: String, episode: String, admission: String?)] = []
    /// Overlay rows the projection keeps (a statistics reset's base for an episode whose total grew, PROTOCOL §6.8).
    var overlayAdditions: [(op: String, entity: String, id: String, property: String, kind: String, value: ContractJSON)] = []
    /// The account's policies changed.
    var accountPoliciesChanged = false
    /// Admissions of an attach snapshot are seen, a pull's are new releases (PROTOCOL §9.9).
    var admissionsSeen = false
    /// Remote position or duration that wait for the player to leave the episode (PROTOCOL §6.8), by wire episode.
    var deferredPins: [String: ServerEpisodeFields] = [:]
    /// Projected episodes Force full synchronization removes (PROTOCOL §6.14), by local feed.
    var removedEpisodes: [Int64: [Int64]] = [:]
    var removedEpisodeIDs: Set<Int64> = []
    /// Large removals hidden in the unit and deleted in bounded transactions after it.
    var hiddenRemovals: [(feedID: Int64, podcast: String, playing: Int64?)] = []
    var hiddenRemovedFeeds: Set<Int64> = []
    /// Obsolete projected episodes a hold keeps for now: removed when the hold retires.
    var deferredAbsences: [(localID: Int64, episode: String, feedID: Int64)] = []
    /// Episode merges (PROTOCOL §9.7): the discovery ledger's entries move from the merged episode to its survivor.
    var ledgerMoves: [(from: String, to: String)] = []
    /// Rows re-resolved to another episode: the pending overlays of the episode each left become
    /// its own, keyed by its local ID.
    var overlayMoves: [(from: String, local: Int64)] = []
    /// Episode merges (PROTOCOL §9.7): the merged row's active downloads become the survivor row's.
    var jobTransfers: [(from: Int64, to: Int64)] = []
    /// Podcast merges (PROTOCOL §9.7): the source's live generation joins the survivor's, and its discovery ledger
    /// entries with it (finished work stays finished).
    var generationMoves: [(from: String, to: String)] = []
    /// Podcast merges of two feeds here (PROTOCOL §9.7): the app carries the source's per-feed speed and skip silence.
    var feedMerges: [(source: Int64, survivor: Int64)] = []

    /// Row writes the plan makes, cascades included (PROTOCOL §6.8 work).
    var work: Int {
        feeds.count + episodes.count + removedEpisodeCount + (queue.map { $0.count + queueKeys.count } ?? 0)
            + podcastMappings.count + episodeMappings.count + credentials.count
            + statisticsUnits.keys.reduce(0) { $0 + max(1, statisticsRows[$1] ?? 1) }
            + libraryStatisticsUnits.keys.reduce(0) { $0 + max(1, libraryStatisticsRows[$1] ?? 1) } + admissions.count
            + pinnedRemovals.count + overlayAdditions.count + deferredAbsences.count + hiddenRemovals.count
    }
    var removedEpisodeCount = 0
}

/// A queue entry's key row (`ntp_queue_keys`).
struct ServerQueueKeyRow: Equatable, Sendable {
    var key: QueueKey
    var positionID: String
    var deviceOnly: Bool
    var nextAnchor: Int64?
    var previousAnchor: Int64?
}

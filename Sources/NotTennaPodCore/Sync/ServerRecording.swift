import Foundation

/// Why a write in a server library was refused by the recording seam (PROTOCOL §15.2).
public enum ServerRecordingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A synced field changed without a mapping for the write's intent. The whole transaction rolls back.
    case unmappedChange(intent: String, change: String)
    /// A synced row was written outside `write(intent:)`.
    case writeOutsideSeam
    /// The action is not available while a NotTennaPod server library is open (OPML or database import, PROTOCOL §11.5).
    case refusedInServerLibrary(String)
    case notAServerLibrary
    case alreadyAServerLibrary
    case unknownRegistration(String)
    case corruptState(String)
    /// Test failure injection (`FeedLibraryStore.recorderFailureInjection`).
    case injectedFailure
    /// A fact larger than the server accepts (PROTOCOL §6.13 `max_framed_fact_bytes`): it is never numbered. A person's
    /// action that needs it changes nothing (a queue sort of a very long queue); playback keeps its listening here.
    case factTooLarge(type: String, bytes: Int)
    /// A history removal, history clear or statistics reset would cover listening the server refused (its export is too
    /// large): nothing changes until that listening is sent or kept on this device (Settings → Synchronization → Needs
    /// attention).
    case cutBlockedByRefusedListening(intent: String)

    public var description: String {
        switch self {
        case .unmappedChange(let intent, let change): "unmapped change \(change) in a \(intent) write"
        case .writeOutsideSeam: "a synced write outside the recording seam"
        case .refusedInServerLibrary(let action): "\(action) is refused in a server library"
        case .notAServerLibrary: "not a server library"
        case .alreadyAServerLibrary: "already a server library"
        case .unknownRegistration(let op): "unknown registration \(op)"
        case .corruptState(let detail): "corrupt server state: \(detail)"
        case .injectedFailure: "injected recorder failure"
        case .factTooLarge(let type, let bytes): "a \(type) fact of \(bytes) bytes is larger than the server accepts"
        case .cutBlockedByRefusedListening(let intent): "a \(intent) would cover listening the server refused"
        }
    }
}

/// What a store write means (PROTOCOL §15.2). Every public store mutation declares one; in a server library the
/// recorder turns the intent and the captured changes into facts in the same transaction, and a synced change
/// the intent does not map rolls the transaction back. In a standalone library the intent is ignored.
enum ServerIntent: Equatable, Sendable {
    enum QueueRemovalReason: String, Sendable { case user, downloadDeleted = "download_deleted" }

    /// Device-only work (preview expiry, download bookkeeping, file cleanup, swipe-Undo guards): no facts.
    case local
    /// Projecting pulled records: no facts, every change allowed.
    case remote
    /// `preparePreview`: the preview stays local until a synced action (PROTOCOL §15.2); an identity match
    /// merges like a refresh's.
    case preview
    /// Closure APIs (`updatePreferences`, `updateEpisode`): one register fact per changed synced property.
    case registers
    case subscribe
    case unsubscribe
    /// A feed credential change; `cleared` when the saved username and password are empty.
    case credentials(cleared: Bool)
    case changeURL
    case mark(played: Bool, resetPosition: Bool)
    case swipeMark
    case undoMark
    case resetPosition
    case dismiss
    case dismissAll
    case queueAdd
    /// `beginPlayback`: `queue.add` for an unqueued episode; the load's pending session and transition (PROTOCOL §8).
    case playLoad
    case downloadRequest
    case queueRemove(QueueRemovalReason)
    case queueRestore
    case queueMove(boundary: Bool)
    case queueSort
    case queueClear
    case downloadCompleted
    case historyRemove
    case historyRestore
    case historyClear
    case statisticsReset
    case accountPolicy(ServerAccountPolicyChange)
    /// Refresh (`applyRefresh`): `catalog.observe` and the `inbox` and `nothing` releases' `discovery.propose` (PROTOCOL §9).
    case refresh
    /// Refresh-to-queue filing (`consumeFeedRefreshQueueEffects`): the `queue` releases' proposals with bundles (PROTOCOL §9.5).
    case discoveryQueue
    /// A large refresh's deferred observations, up to 200 in one bounded transaction (PROTOCOL §9.4).
    case observe
    /// Playback saves, timeline resets and the coordinator's hooks: the session journal and its exports (PROTOCOL §8). Never fails.
    case playbackSave
    /// The end of playback (`endPlayback`): the pending transition's end, finalization or leave (PROTOCOL §8.4). Never fails.
    case playbackEnd

    var name: String {
        switch self {
        case .local: "local"
        case .remote: "remote"
        case .preview: "preview"
        case .registers: "registers"
        case .subscribe: "subscribe"
        case .unsubscribe: "unsubscribe"
        case .credentials: "credentials"
        case .changeURL: "changeURL"
        case .mark: "mark"
        case .swipeMark: "swipeMark"
        case .undoMark: "undoMark"
        case .resetPosition: "resetPosition"
        case .dismiss: "dismiss"
        case .dismissAll: "dismissAll"
        case .queueAdd: "queueAdd"
        case .playLoad: "playLoad"
        case .downloadRequest: "downloadRequest"
        case .queueRemove: "queueRemove"
        case .queueRestore: "queueRestore"
        case .queueMove: "queueMove"
        case .queueSort: "queueSort"
        case .queueClear: "queueClear"
        case .downloadCompleted: "downloadCompleted"
        case .historyRemove: "historyRemove"
        case .historyRestore: "historyRestore"
        case .historyClear: "historyClear"
        case .statisticsReset: "statisticsReset"
        case .accountPolicy: "accountPolicy"
        case .refresh: "refresh"
        case .discoveryQueue: "discoveryQueue"
        case .observe: "observe"
        case .playbackSave: "playbackSave"
        case .playbackEnd: "playbackEnd"
        }
    }

    /// Playback writes must never fail because of sync (PROTOCOL §15.2): a failed recorder savepoint rolls back alone
    /// and the save commits with `export_owed` set. The play load is held to the same rule: the coordinator has already
    /// retired the previous episode when it calls `beginPlayback`, so a failed recording must not stop the load.
    var neverFails: Bool { self == .playbackSave || self == .playbackEnd || self == .playLoad }

    /// A local cut (PROTOCOL §8.2): recorded only after every unexported save it covers was exported.
    var isCut: Bool { self == .historyRemove || self == .historyClear || self == .statisticsReset }

    /// Whether the write first records what earlier writes owe. Never for playback writes, which are
    /// latency-sensitive and must not wait on recovery work, nor for projecting pulled records.
    var replaysOwedFacts: Bool {
        switch self {
        case .playLoad, .playbackSave, .playbackEnd, .remote, .observe: false
        default: true
        }
    }

    /// The code that maps this intent's facts; nil when recording maps it completely.
    var ownedBy: String? {
        switch self {
        default: nil
        }
    }
}

/// An account-level policy change (PROTOCOL §15.4 `.accountPolicy`).
public enum ServerAccountPolicyChange: Equatable, Sendable {
    case newEpisodesAction(NewEpisodesAction)
    case enqueueLocation(EnqueueLocation)
    case sorting(keepSorted: Bool, order: QueueSortOrder)
}

/// The account-level policies of a server library: the account records with this library's pending changes.
public struct ServerAccountPolicyValues: Equatable, Sendable {
    public var newEpisodesAction: NewEpisodesAction?
    public var enqueueLocation: EnqueueLocation
    public var keepSorted: Bool
    public var keepSortedOrder: QueueSortOrder

    public init(newEpisodesAction: NewEpisodesAction? = nil, enqueueLocation: EnqueueLocation = .back,
                keepSorted: Bool = false, keepSortedOrder: QueueSortOrder = .dateNewOld) {
        self.newEpisodesAction = newEpisodesAction; self.enqueueLocation = enqueueLocation
        self.keepSorted = keepSorted; self.keepSortedOrder = keepSortedOrder
    }
}

/// A server library's identity: the `ntp_library` row (PROTOCOL §15.2).
struct ServerLibraryContext: Equatable, Sendable {
    let libraryID: String
    let accountID: String
    let namespace: String
    let installID: String
    let mainAuthor: String
}

/// What first attachment writes into a new library's `ntp_library` (PROTOCOL §15.4).
struct ServerLibraryIdentity: Sendable {
    var libraryID: String
    var serverURL: String?
    var serverID: String?
    var accountID: String
    var namespace: String
    var username: String?
    var installID: String
    var deviceMarker: String?
}

/// One run of episodes an add or an Undo inserted, as it executed (PROTOCOL §7.6): the members it placed, in
/// order, the whole queue just before (device-only entries included) and the index it inserted at, before any Keep
/// sorted pass. `end` for an add at the back (Android appends), whose `place` is `end` whatever the queue holds.
struct QueueInsertion: Equatable, Sendable {
    var members: [Int64]
    var before: [Int64]
    var index: Int
    var end: Bool
}

/// The synced changes one store transaction made, reported by the low-level writers (PROTOCOL §15.2). `before` is the
/// stored row before the transaction's first write to it; `after` the last value written (nil: deleted).
/// Confined to the store actor: created, filled and read within one `write(intent:)` call.
final class ChangeCapture: @unchecked Sendable {
    struct Episode { var feedID: Int64; var before: LibraryEpisode?; var after: LibraryEpisode? }
    struct Feed { var before: LibraryFeed?; var after: LibraryFeed? }
    struct Credential { var before: UUID?; var after: UUID? }

    var episodes: [Int64: Episode] = [:]
    private(set) var episodeOrder: [Int64] = []
    var feeds: [Int64: Feed] = [:]
    private(set) var feedOrder: [Int64] = []
    var credentials: [Int64: Credential] = [:]
    /// The queue before the transaction (episode IDs in order).
    var queueBefore: [Int64] = []
    /// The action's clock (`client_time`).
    var clientTime: Date

    // What the body tells the recorder about the operation (the intent's details).
    /// Each insertion an add or an Undo made, as it executed it: what its `place` is resolved from (PROTOCOL §7.6, §15.4
    /// ).
    var queueInsertions: [QueueInsertion] = []
    /// The sort sheet's order (`queue.reorder {sort, observed}`, PROTOCOL §7.6); the queue it observed is
    /// `queueBefore`, its result the queue after the transaction.
    var queueSortOrder: QueueSortOrder?
    /// The add re-sorted the whole queue (Keep sorted) after inserting at its place.
    var keepSortedAdd = false
    /// The order that add sorted by: with `keepSortedAdd`, the queue policy of the moment, which an owed add keeps
    /// for its replay.
    var keepSortedOrder: QueueSortOrder?
    /// Episodes a manual move placed (they get new keys; the others keep theirs).
    var movedQueueEpisodes: [Int64] = []
    var queueRestore: (episodeID: Int64, index: Int, operationID: UUID)?
    var queueRemovalReceipt: (operationID: UUID, episodeID: Int64)?
    /// Every episode an explicit Add or Remove favorite named: each is recorded with the value the person asked for, also
    /// one this device already showed with it (another device may have changed it meanwhile, PROTOCOL §7.1 "the last in
    /// order wins").
    var favoriteTargets: Set<Int64> = []
    /// Every podcast an explicit bulk Keep updated, or the New episodes action dialog, named: recorded with the chosen
    /// value, also one already showing it.
    var keepUpdatedTargets: Set<Int64> = []
    var newEpisodesActionTargets: Set<Int64> = []
    /// Every episode an explicit Remove from queue named, in order: as for favorites, one this device did not show queued
    /// is recorded too (another device may have queued it meanwhile).
    var queueRemovalTargets: [Int64] = []
    var historyRemoval: (operationID: UUID, episodeID: Int64)?
    var historyRestore: (operationID: UUID, episodeID: Int64, time: Int64)?
    /// A subscription URL's userinfo, staged as a library credential before the transaction.
    var urlCredential: UUID?
    /// A refresh's discovery batch (PROTOCOL §9.4): what it observes and proposes.
    var discovery: ServerDiscoveryBatch?
    /// Releases a queue filing placed (the `queueEpisodes` effect's evidence, PROTOCOL §9.5), proposed with their bundles.
    var queueReleases: [ServerRelease] = []
    /// Deferred observations to record (`.observe`): the feed, and the refresh's parse of its items by local ID when
    /// this process still has it.
    var observationFeed: Int64?
    var observationInputs: [Int64: ServerCatalogParse.Item] = [:]
    /// Work for the actor's memory once the transaction has committed (Undo offers' op IDs and keys).
    var afterCommit: [(isolated FeedLibraryStore) -> Void] = []
    /// The playback journal made a session fact, finalization or leave due (PROTOCOL §8): the recorder records it.
    var playbackDue = false
    /// Episodes whose playback write is no listening (a pending session's save, PROTOCOL §8): nothing marks them.
    var playbackUnmarked: Set<Int64> = []
    /// The recorder found a session's export too large and refused it (kept here even when the transaction rolls back).
    var refusedExport = false

    init(clientTime: Date) { self.clientTime = clientTime }

    func noteEpisode(_ id: Int64, feedID: Int64, before: @autoclosure () throws -> LibraryEpisode?, after: LibraryEpisode?) rethrows {
        if var existing = episodes[id] {
            existing.after = after
            episodes[id] = existing
        } else {
            episodes[id] = Episode(feedID: feedID, before: try before(), after: after)
            episodeOrder.append(id)
        }
    }

    func noteFeed(_ id: Int64, before: @autoclosure () throws -> LibraryFeed?, after: LibraryFeed?) rethrows {
        if var existing = feeds[id] {
            existing.after = after
            feeds[id] = existing
        } else {
            feeds[id] = Feed(before: try before(), after: after)
            feedOrder.append(id)
        }
    }

    func noteCredential(feedID: Int64, before: UUID?, after: UUID?) {
        if var existing = credentials[feedID] { existing.after = after; credentials[feedID] = existing }
        else { credentials[feedID] = Credential(before: before, after: after) }
    }
}

import Foundation

/// The recording seam (PROTOCOL §15.2): every store mutation runs in `write(intent:)`. In a standalone
/// library it is exactly the store's transaction. In a server library (one with an `ntp_library` row) it captures
/// what the body changed and, before COMMIT, records the facts in one savepoint of the same transaction.
extension FeedLibraryStore {
    static func loadServerContext(_ database: LibrarySQLite) throws -> ServerLibraryContext? {
        guard let row = try database.rows("SELECT library_id, account_id, namespace, install_id, main_author FROM ntp_library WHERE id = 1").first else {
            return nil
        }
        let values = row.map { value -> String? in if case .text(let text) = value { text } else { nil } }
        guard values.count == 5, let library = values[0], let account = values[1], let namespace = values[2],
              let install = values[3], let author = values[4] else { throw ServerRecordingError.corruptState("ntp_library") }
        return ServerLibraryContext(libraryID: library, accountID: account, namespace: namespace, installID: install, mainAuthor: author)
    }

    /// True for a server library (PROTOCOL §15.4).
    public var isServerLibrary: Bool { serverContext != nil }

    /// First attachment's step 1 (PROTOCOL §15.4): makes this new, empty library a server library. The main author is the
    /// installation (`A = T`, PROTOCOL §15.4).
    func initializeServerLibrary(_ identity: ServerLibraryIdentity, now: Date = Date()) throws {
        guard serverContext == nil else { throw ServerRecordingError.alreadyAServerLibrary }
        for (name, value) in [("account_id", identity.accountID), ("namespace", identity.namespace), ("install_id", identity.installID)] {
            guard ContractIdentity.isUUID(value) else { throw ServerRecordingError.corruptState("\(name) is not a UUID") }
        }
        let created = try milliseconds(now)
        try database.transaction {
            guard try database.scalar("SELECT count(*) FROM ntp_library") == 0,
                  try database.scalar("SELECT count(*) FROM feeds") == 0 else { throw ServerRecordingError.alreadyAServerLibrary }
            func text(_ value: String?) -> LibrarySQLValue { value.map(LibrarySQLValue.text) ?? .null }
            try database.execute("INSERT INTO ntp_library(id, library_id, server_url, server_id, account_id, namespace, username, install_id, device_marker, main_author, created_at) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                                 [.text(identity.libraryID), text(identity.serverURL), text(identity.serverID), .text(identity.accountID),
                                  .text(identity.namespace), text(identity.username), .text(identity.installID), text(identity.deviceMarker),
                                  .text(identity.installID), .integer(created)])
            try database.execute("INSERT INTO ntp_authors(author_id, role, next_seq, created_at) VALUES (?, 'main', 1, ?)",
                                 [.text(identity.installID), .integer(created)])
            try ServerExchangeTables.create(database)
            for statement in ServerExchangeTables.indexes { try database.execute(statement) }
            // Its identity and Cast tag are its library ID (schema 20, PROTOCOL §15.2).
            try adoptServerIdentity(identity.libraryID)
        }
        serverContext = try Self.loadServerContext(database)
    }

    /// Runs `body` as one store transaction declaring `intent` (PROTOCOL §15.2).
    func write<T>(_ intent: ServerIntent, durable: Bool = true, now: Date? = nil, _ body: () throws -> T) throws -> T {
        guard let context = serverContext else { return try database.transaction(durable: durable, body) }
        let capture = ChangeCapture(clientTime: ServerActionClock.time(of: now ?? Date()))
        do { return try recordedWrite(intent, capture: capture, context: context, durable: durable, body) }
        catch let error as ServerRecordingError {
            // A cut refused because its flush found listening too large for the server (PROTOCOL §6.13) changed nothing; that
            // listening stays refused and listed under Needs attention, in a transaction of its own.
            if case .cutBlockedByRefusedListening = error, capture.refusedExport {
                let time = try milliseconds(capture.clientTime)
                _ = try? write(.local, now: now) { try journalFlushOpenSessions(now: time) }
            }
            throw error
        }
    }

    private func recordedWrite<T>(_ intent: ServerIntent, capture: ChangeCapture, context: ServerLibraryContext, durable: Bool,
                                  _ body: () throws -> T) throws -> T {
        let result = try database.transaction(durable: durable) { () throws -> T in
            // Earlier owed adds are recorded before this action takes its capture and changes anything, so each
            // recorder sees only its own action's changes; one bounded step, owed adds first.
            // Playback writes never replay.
            if intent.replaysOwedFacts {
                _ = try replayOwedStep(context)
                // The sync log says so once this write commits (PROTOCOL §15.5); a rolled-back write replayed nothing.
                if owedStepAdds > 0 { let adds = owedStepAdds; capture.afterCommit.append { $0.noteOwedReplayed(adds) } }
            }
            capture.queueBefore = try queueEpisodeIDs()
            activeCapture = capture
            defer { activeCapture = nil }
            // The restart export (PROTOCOL §8.2): what an earlier opening journaled is exported before anything of this one.
            let time = try milliseconds(capture.clientTime)
            if intent != .remote, playbackRestartPending { try journalRestartExport(now: time) }
            let value = try body()
            // Flush before cuts (PROTOCOL §8.2).
            if intent == .historyRemove || intent == .historyClear || intent == .statisticsReset { try journalFlushOpenSessions(now: time) }
            // An Undo's restore compensates what came before it, listening included: the episode's listening saved before
            // it is exported first, so the restore follows it on this author's chain (PROTOCOL §6.9, §8.2).
            if intent == .undoMark { try journalFlushOpenSessions(now: time, episodes: Set(capture.episodeOrder)) }
            activeCapture = nil
            // Listening no exported fact carries yet is marked with the save itself.
            if intent == .playbackSave || intent == .playbackEnd { try markLocalPlayback(capture, intent: intent) }
            let writer = ServerOutboxWriter(database: database, context: context, failAfter: recorderFailureInjection, factBound: factBoundOverride)
            do {
                try database.savepoint { try record(intent, capture: capture, writer: writer) }
                recorderWrites = writer.writes
#if DEBUG
                if let observer = ServerDebugHooks.observer, !writer.exported.isEmpty {
                    let exported = writer.exported
                    capture.afterCommit.append { _ in observer.exported(exported) }
                }
#endif
            } catch {
                recorderWrites = writer.writes
                // The sync log reports it (PROTOCOL §15.5); the rollback below keeps the library unchanged.
                if case ServerRecordingError.unmappedChange = error { noteServerDiagnostic("unmapped", "\(error)") }
                // A playback write never fails because of sync: the savepoint rolled back as a whole and the write
                // commits (PROTOCOL §15.2). What it could not record is owed: a play load's queue add durably, replayed by
                // the next successful write and at launch; what its playback journal made due is kept
                // there, and `export_owed` has the next recording export it (PROTOCOL §8.2).
                guard intent.neverFails else { throw error }
                if intent == .playLoad { try oweQueueAdd(context, capture: capture) }
                if intent != .playLoad || capture.playbackDue {
                    try database.execute("UPDATE ntp_library SET export_owed = 1 WHERE id = 1")
                }
                capture.afterCommit.removeAll()
            }
            return value
        }
        if intent != .remote { playbackRestartPending = false }
        for work in capture.afterCommit { work(self) }
        return result
    }

    func queueEpisodeIDs() throws -> [Int64] {
        try database.rows("SELECT episode_id FROM queue ORDER BY position").map {
            guard let id = $0[0].integer else { throw FeedLibraryError.corruptRecord }
            return id
        }
    }

    // MARK: - Capture hooks (called by the low-level writers)

    /// `saveEpisode`: reports the episode before and after. Outside the seam a server library refuses a write
    /// that changes a synced field.
    func captureEpisodeWrite(_ episode: LibraryEpisode, feedID: Int64, before: LibraryEpisode? = nil) throws {
        guard serverContext != nil else { return }
        if let capture = activeCapture {
            try capture.noteEpisode(episode.id, feedID: feedID, before: try before ?? loadEpisode(episode.id), after: episode)
        } else if let stored = try before ?? loadEpisode(episode.id), SyncedEpisode(stored) != SyncedEpisode(episode) {
            throw ServerRecordingError.writeOutsideSeam
        }
    }

    func captureHeaderWrite(_ header: LibraryFeed) throws {
        guard serverContext != nil else { return }
        if let capture = activeCapture {
            try capture.noteFeed(header.id, before: try storedHeader(header.id), after: header)
        } else if let stored = try storedHeader(header.id), SyncedFeed(stored) != SyncedFeed(header) {
            throw ServerRecordingError.writeOutsideSeam
        }
    }

    func captureQueueWrite(_ order: [Int64]) throws {
        guard serverContext != nil, activeCapture == nil else { return }
        if try queueEpisodeIDs() != order { throw ServerRecordingError.writeOutsideSeam }
    }

    /// Before a feed's row (and with it its episodes, queue entries and credential) is deleted.
    func captureFeedDeletion(_ feed: LibraryFeed) throws {
        guard serverContext != nil else { return }
        guard let capture = activeCapture else { throw ServerRecordingError.writeOutsideSeam }
        // The feed was read in this transaction, so its values are the stored ones.
        var header = feed; header.episodes = []
        capture.noteFeed(feed.id, before: header, after: nil)
        for episode in feed.episodes { capture.noteEpisode(episode.id, feedID: feed.id, before: episode, after: nil) }
        if let credential = try feedCredentialID(feedID: feed.id) { capture.noteCredential(feedID: feed.id, before: credential, after: nil) }
    }

    /// Before an episode's row is deleted (a refresh removing it).
    func captureEpisodeDeletion(_ episode: LibraryEpisode, feedID: Int64) throws {
        guard serverContext != nil else { return }
        guard let capture = activeCapture else { throw ServerRecordingError.writeOutsideSeam }
        try capture.noteEpisode(episode.id, feedID: feedID, before: try loadEpisode(episode.id) ?? episode, after: nil)
    }

    func captureCredentialWrite(feedID: Int64, credential: UUID) throws {
        guard serverContext != nil else { return }
        guard let capture = activeCapture else { throw ServerRecordingError.writeOutsideSeam }
        capture.noteCredential(feedID: feedID, before: try feedCredentialID(feedID: feedID), after: credential)
    }

    func storedHeader(_ id: Int64) throws -> LibraryFeed? {
        guard let row = try database.rows("SELECT record FROM feeds WHERE id = ?", [.integer(id)]).first else { return nil }
        return try decode(row[0])
    }
}

/// The synced fields of an episode's user state (PROTOCOL §15.2): what a fact must account for.
struct SyncedEpisode: Equatable {
    var playState: EpisodePlayState
    var favorite: Bool
    var position: Int32
    var playedDuration: Int64
    var lastPlayed: Int64
    var history: Int64?

    init(_ episode: LibraryEpisode) {
        let state = episode.userState
        playState = state.playState; favorite = state.isFavorite; position = state.positionMilliseconds
        playedDuration = state.playedDurationMilliseconds; lastPlayed = state.lastPlayedTimeMilliseconds
        history = state.lastPlayedHistoryMilliseconds
    }
}

/// The synced fields of a feed header: subscription state, the two policy properties and the feed URL.
struct SyncedFeed: Equatable {
    var subscription: FeedSubscriptionState
    var keepUpdated: Bool
    var newEpisodesAction: NewEpisodesAction
    var source: String

    init(_ feed: LibraryFeed) {
        subscription = feed.subscriptionState; keepUpdated = feed.keepUpdated
        newEpisodesAction = feed.newEpisodesAction; source = feed.source
    }

    static func == (lhs: SyncedFeed, rhs: SyncedFeed) -> Bool {
        lhs.subscription == rhs.subscription && lhs.keepUpdated == rhs.keepUpdated
            && lhs.newEpisodesAction == rhs.newEpisodesAction && lhs.source.utf8.elementsEqual(rhs.source.utf8)
    }
}

/// One synced change a transaction made; each must be accounted for by a fact or by the intent's fixed effects.
enum SyncedChange: Hashable, Comparable, CustomStringConvertible {
    enum EpisodeField: String, CaseIterable { case playState = "play_state", favorite, position, playedDuration = "played_time", lastPlayed = "last_played", history }
    enum FeedField: String, CaseIterable { case subscription, keepUpdated = "keep_updated", newEpisodesAction = "new_episodes_action", source = "refresh_url" }

    case episode(Int64, EpisodeField)
    case episodeInserted(Int64)
    case episodeDeleted(Int64)
    case feed(Int64, FeedField)
    case feedInserted(Int64)
    case feedDeleted(Int64)
    case credentials(Int64)
    case queueIn(Int64)
    case queueOut(Int64)
    case queueOrder

    var description: String {
        switch self {
        case .episode(let id, let field): "episode \(id) \(field.rawValue)"
        case .episodeInserted(let id): "episode \(id) inserted"
        case .episodeDeleted(let id): "episode \(id) deleted"
        case .feed(let id, let field): "feed \(id) \(field.rawValue)"
        case .feedInserted(let id): "feed \(id) inserted"
        case .feedDeleted(let id): "feed \(id) deleted"
        case .credentials(let id): "feed \(id) credentials"
        case .queueIn(let id): "queue add \(id)"
        case .queueOut(let id): "queue removal \(id)"
        case .queueOrder: "queue order"
        }
    }

    static func < (lhs: SyncedChange, rhs: SyncedChange) -> Bool { lhs.description < rhs.description }
}

extension FeedLibraryStore {
    /// Test failure injection (PROTOCOL §15.2): the recorder fails right after its `after`th write; nil turns it off.
    func injectRecorderFailure(after: Int?) { recorderFailureInjection = after }

    /// The recorder's writes in the last server-library transaction, for tests.
    func lastRecorderWrites() -> Int { recorderWrites }

    /// Test-only: facts over `bytes` are too large to number, as if the server advertised that bound; nil restores it.
    func setServerFactBoundForTesting(_ bytes: Int?) { factBoundOverride = bytes }
}

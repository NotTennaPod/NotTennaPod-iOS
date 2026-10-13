import Foundation

/// Every local write and its facts (PROTOCOL §15.2).
extension FeedLibraryStore {
    static func wire(_ state: EpisodePlayState) -> ContractJSON {
        switch state { case .new: "new"; case .unplayed: "unplayed"; case .played: "played" }
    }

    static func wire(_ action: NewEpisodesAction) -> ContractJSON {
        switch action { case .global: "global"; case .inbox: "inbox"; case .queue: "queue"; case .nothing: "nothing" }
    }

    static func wire(_ location: EnqueueLocation) -> ContractJSON {
        switch location { case .back: "back"; case .front: "front"; case .afterCurrentlyPlaying: "after_current"; case .random: "random" }
    }

    static func wire(_ order: QueueSortOrder) -> ContractJSON { .string(order.rawValue.lowercased()) }

    private func register(_ entity: String, _ property: String, _ value: ContractJSON, kind: String = "episode") -> ServerOverlay {
        ServerOverlay(entity: kind, id: entity, property: property, kind: .register, value: value)
    }

    func mapIntent(_ s: RecordingSession) throws {
        switch s.intent {
        case .local:
            accountLocalDeletions(s)
        case .preview:
            try accountPreview(s)
            try mapCredentials(s, cleared: false)
        case .remote:
            s.pending.removeAll()
        case .registers:
            try mapRegisters(s)
        case .subscribe:
            try mapSubscribe(s)
        case .unsubscribe:
            try mapUnsubscribe(s)
        case .credentials(let cleared):
            try mapCredentials(s, cleared: cleared)
        case .changeURL:
            try mapChangeURL(s)
        case .mark(let played, let resetPosition):
            try mapMark(s, played: played, resetPosition: resetPosition)
        case .swipeMark:
            try mapSwipe(s)
        case .undoMark:
            try mapUndoMark(s)
        case .resetPosition:
            try mapResetPosition(s)
        case .dismiss, .downloadCompleted:
            try mapDismiss(s, all: false)
        case .dismissAll:
            try mapDismiss(s, all: true)
        case .queueAdd, .playLoad, .downloadRequest:
            try mapQueueAdd(s, record: true)
        case .queueRemove(let reason):
            try mapQueueRemove(s, reason: reason)
        case .queueRestore:
            try mapQueueRestore(s)
        case .queueMove(let boundary):
            try mapQueueMove(s, boundary: boundary)
        case .queueSort:
            try mapQueueSort(s)
        case .queueClear:
            try mapQueueClear(s)
        case .historyRemove:
            try mapHistoryRemove(s)
        case .historyRestore:
            try mapHistoryRestore(s)
        case .historyClear:
            try mapAccountCut(s, type: "history.clear")
        case .statisticsReset:
            try mapAccountCut(s, type: "statistics.reset")
        case .accountPolicy(let change):
            try mapAccountPolicy(s, change: change)
        case .refresh:
            try mapDiscovery(s)
        case .discoveryQueue:
            try mapDiscoveryQueue(s)
        case .observe:
            try mapDeferredObservations(s)
        case .playbackSave, .playbackEnd:
            accountPlayback(s)
        }
    }

    // MARK: - Device-only and later stages

    /// Preview expiry and other local deletions (PROTOCOL §7.2): a not-subscribed feed and its episodes leave locally only.
    private func accountLocalDeletions(_ s: RecordingSession) {
        for change in s.pending {
            switch change {
            case .feedDeleted(let id), .credentials(let id):
                if s.capture.feeds[id]?.before?.subscriptionState == .notSubscribed { s.account(change) }
            case .episodeDeleted(let id), .queueOut(let id):
                if let feed = s.feedOfEpisode[id], s.capture.feeds[feed]?.before?.subscriptionState == .notSubscribed,
                   s.capture.feeds[feed]?.after == nil { s.account(change) }
            default: break
            }
        }
    }

    /// A preview the account does not know stays local: its insertion, first population and staged credential.
    /// A preview that matched an existing feed merged into it like a refresh.
    private func accountPreview(_ s: RecordingSession) throws {
        for change in s.pending {
            switch change {
            case .feedInserted(let id), .credentials(let id), .feed(let id, .keepUpdated):
                if s.capture.feeds[id]?.after?.subscriptionState == .notSubscribed, s.bindings[id] == nil || s.bindings[id] == .unregistered {
                    s.account(change)
                }
            case .episodeInserted(let id):
                if let feed = s.feedOfEpisode[id], s.capture.feeds[feed]?.before == nil { s.account(change) }
            default: break
            }
        }
        // A preview that matched a podcast this library has merges like a refresh (PROTOCOL §9).
        try mapDiscovery(s)
    }

    /// Playback writes (PROTOCOL §8): a save, an end or a hook may change what its session's facts carry (position, last played,
    /// history, played time, NEW dismissed) and what an end, finalization or leave decides (PLAYED, position 0, the
    /// queue removal). `recordPlaybackDue` records those facts from the journal; a pending session's save and a passive
    /// load record nothing (PROTOCOL §8).
    private func accountPlayback(_ s: RecordingSession) {
        for change in s.pending {
            switch change {
            case .episode(_, .position), .episode(_, .lastPlayed), .episode(_, .history), .episode(_, .playedDuration),
                 .episode(_, .playState), .queueOut:
                s.account(change)
            default: break
            }
        }
    }

    // MARK: - Subscriptions and podcast policies

    private func mapRegisters(_ s: RecordingSession) throws {
        for feedID in s.capture.feedOrder {
            guard let change = s.capture.feeds[feedID], let before = change.before, let after = change.after else { continue }
            if before.subscriptionState != after.subscriptionState {
                let type: String
                switch (before.subscriptionState, after.subscriptionState) {
                case (.subscribed, .archived): type = "podcast.archive"
                case (.archived, .subscribed): type = "podcast.restore"
                default: type = ""
                }
                if !type.isEmpty {
                    let state: ContractJSON = after.subscriptionState == .archived ? "archived" : "subscribed"
                    try emitPodcastFact(s, feedID: feedID, type: type, payload: [:],
                                        overlays: { [self.register($0, "subscription", state, kind: "podcast")] },
                                        provenanceGroups: ["subscription"], registerIfNeeded: true)
                    s.account(.feed(feedID, .subscription))
                }
            }
            var policy = ContractObject()
            if before.keepUpdated != after.keepUpdated { policy["keep_updated"] = .bool(after.keepUpdated) }
            if before.newEpisodesAction != after.newEpisodesAction { policy["new_episodes_action"] = Self.wire(after.newEpisodesAction) }
            if !policy.isEmpty {
                let properties = policy.members
                try emitPodcastFact(s, feedID: feedID, type: "podcast.set_policy", payload: policy,
                                    overlays: { entity in properties.map { self.register(entity, $0.name, $0.value, kind: "podcast") } },
                                    provenanceGroups: ["policy"], registerIfNeeded: false)
                s.account(.feed(feedID, .keepUpdated)); s.account(.feed(feedID, .newEpisodesAction))
            }
        }
        let favorites = s.capture.episodeOrder.filter { id in
            guard let change = s.capture.episodes[id], let before = change.before, let after = change.after else { return false }
            return before.userState.isFavorite != after.userState.isFavorite
        }
        try emitEpisodeFacts(s, type: "favorite.set", members: favorites,
                             extra: { id in ["on": .bool(s.capture.episodes[id]?.after?.userState.isFavorite ?? false)] },
                             overlays: { entity, id in [self.register(entity, "favorite", .bool(s.capture.episodes[id]?.after?.userState.isFavorite ?? false))] },
                             provenanceGroups: ["favorite"])
        for id in favorites { s.account(.episode(id, .favorite)) }
    }

    /// `podcast.subscribe` for a preview that became subscribed or a feed inserted subscribed; its first
    /// population is local (it is never proposed, PROTOCOL §15.2).
    private func mapSubscribe(_ s: RecordingSession) throws {
        for feedID in s.capture.feedOrder {
            guard let change = s.capture.feeds[feedID], let after = change.after, after.subscriptionState == .subscribed,
                  change.before?.subscriptionState != .subscribed else { continue }
            if try binding(feedID, s) != .localFolder {
                _ = try register(feedID: feedID, kind: "subscribe", s)
            }
            for change in [SyncedChange.feedInserted(feedID), .feed(feedID, .subscription), .feed(feedID, .keepUpdated)] { s.account(change) }
        }
        // A subscription's first population (never proposed, PROTOCOL §15.2), or an identity match merged like a refresh (PROTOCOL §9).
        try mapDiscovery(s)
    }

    private func mapUnsubscribe(_ s: RecordingSession) throws {
        for feedID in s.capture.feedOrder {
            guard let change = s.capture.feeds[feedID], change.before != nil, change.after == nil else { continue }
            try emitPodcastFact(s, feedID: feedID, type: "podcast.unsubscribe", payload: [:],
                                overlays: { [self.register($0, "subscription", "removed", kind: "podcast")] },
                                provenanceGroups: ["subscription"], registerIfNeeded: false)
            // Closing the generation hides every episode, queue entry and credential of it.
            s.account(.feedDeleted(feedID)); s.account(.credentials(feedID))
            for change in s.pending {
                switch change {
                case .episodeDeleted(let id), .queueOut(let id):
                    if s.feedOfEpisode[id] == feedID { s.account(change) }
                default: break
                }
            }
        }
    }

    private func mapCredentials(_ s: RecordingSession, cleared: Bool) throws {
        for (feedID, change) in s.capture.credentials where change.before != change.after {
            guard let feed = try header(feedID, s), let credential = change.after else { continue }
            var payload = ContractObject()
            var secrets: [String] = []
            if cleared {
                payload["clear"] = true
            } else {
                let secret = try secretID(for: credential, feedURL: ContractURL.stripUserinfo(feed.source), inheriting: change.before, s)
                payload["secret_id"] = .string(secret)
                secrets = [secret]
            }
            let value = payload["secret_id"] ?? .null
            try emitPodcastFact(s, feedID: feedID, type: "podcast.set_credentials", payload: payload,
                                overlays: { [self.register($0, "credentials", value, kind: "podcast")] },
                                provenanceGroups: ["credentials"], secretIDs: secrets, registerIfNeeded: false)
            s.account(.credentials(feedID))
        }
    }

    private func mapChangeURL(_ s: RecordingSession) throws {
        for feedID in s.capture.feedOrder {
            guard let change = s.capture.feeds[feedID], let before = change.before, let after = change.after,
                  !before.source.utf8.elementsEqual(after.source.utf8) else { continue }
            let url = ContractURL.stripUserinfo(after.source)
            try emitPodcastFact(s, feedID: feedID, type: "podcast.change_url", payload: ["url": .string(url)],
                                overlays: { [self.register($0, "refresh_url", .string(url), kind: "podcast")] },
                                provenanceGroups: ["identity"], registerIfNeeded: false)
            s.account(.feed(feedID, .source))
        }
    }

    // MARK: - Episode state, Inbox and favorites

    /// The episodes the body wrote that still exist, in the order it wrote them.
    private func touched(_ s: RecordingSession) -> [Int64] {
        s.capture.episodeOrder.filter { s.capture.episodes[$0]?.before != nil && s.capture.episodes[$0]?.after != nil }
    }

    private func mapMark(_ s: RecordingSession, played: Bool, resetPosition: Bool) throws {
        let members = touched(s)
        if played {
            try emitEpisodeFacts(s, type: "episode.mark_played", members: members,
                                 extra: { id in ["reset_position": .bool(resetPosition && s.capture.episodes[id]?.after?.details.media != nil)] },
                                 overlays: { entity, id in
                                     var list = [self.register(entity, "play_state", "played")]
                                     if resetPosition && s.capture.episodes[id]?.after?.details.media != nil { list.append(self.register(entity, "position", 0)) }
                                     return list
                                 }, provenanceGroups: ["play_state", "position"])
        } else {
            try emitEpisodeFacts(s, type: "episode.mark_unplayed", members: members,
                                 overlays: { entity, _ in [self.register(entity, "play_state", "unplayed")] }, provenanceGroups: ["play_state"])
        }
        for id in members {
            s.account(.episode(id, .playState))
            if played && resetPosition { s.account(.episode(id, .position)) }
        }
    }

    private func mapSwipe(_ s: RecordingSession) throws {
        for id in touched(s) {
            guard let before = s.capture.episodes[id]?.before?.userState.playState,
                  let after = s.capture.episodes[id]?.after?.userState.playState, before != after else { continue }
            switch (before, after) {
            case (.new, .unplayed):
                try emitEpisodeFacts(s, type: "inbox.dismiss", members: [id], bulkKey: "episodes",
                                     overlays: { entity, _ in [ServerOverlay(entity: "episode", id: entity, property: "play_state", kind: .dismiss, value: nil)] },
                                     provenanceGroups: ["play_state"])
            case (_, .played):
                try emitEpisodeFacts(s, type: "episode.mark_played", members: [id], extra: { _ in ["reset_position": false] },
                                     overlays: { entity, _ in [self.register(entity, "play_state", "played")] }, provenanceGroups: ["play_state"])
            default:
                try emitEpisodeFacts(s, type: "episode.mark_unplayed", members: [id],
                                     overlays: { entity, _ in [self.register(entity, "play_state", "unplayed")] }, provenanceGroups: ["play_state"])
            }
            s.account(.episode(id, .playState))
        }
    }

    /// Undo restores the explicit prior values (PROTOCOL §7): `episode.restore_state`.
    private func mapUndoMark(_ s: RecordingSession) throws {
        for id in touched(s) {
            guard let after = s.capture.episodes[id]?.after, s.capture.episodes[id]?.before?.userState.playState != after.userState.playState else { continue }
            try emitEpisodeFacts(s, type: "episode.restore_state", members: [id],
                                 extra: { _ in ["play_state": Self.wire(after.userState.playState),
                                                "position": .integer(Int64(after.userState.positionMilliseconds))] },
                                 overlays: { entity, _ in [self.register(entity, "play_state", Self.wire(after.userState.playState)),
                                                           self.register(entity, "position", .integer(Int64(after.userState.positionMilliseconds)))] },
                                 provenanceGroups: ["play_state", "position"])
            s.account(.episode(id, .playState))
        }
    }

    private func mapResetPosition(_ s: RecordingSession) throws {
        // The episode's live session was flushed first (`recordPlaybackDue`, PROTOCOL §8.2).
        let members = touched(s)
        try emitEpisodeFacts(s, type: "episode.reset_position", members: members,
                             overlays: { entity, _ in [self.register(entity, "play_state", "unplayed"), self.register(entity, "position", 0)] },
                             provenanceGroups: ["play_state", "position"])
        for id in members { s.account(.episode(id, .playState)); s.account(.episode(id, .position)) }
    }

    /// `inbox.dismiss` (or `dismiss_all`) for the members that were NEW; a member that was PLAYED and became
    /// UNPLAYED records `mark_unplayed`.
    private func mapDismiss(_ s: RecordingSession, all: Bool) throws {
        var dismissed: [Int64] = [], unplayed: [Int64] = []
        for id in touched(s) {
            guard let before = s.capture.episodes[id]?.before?.userState.playState,
                  let after = s.capture.episodes[id]?.after?.userState.playState, before != after else { continue }
            if before == .new && after == .unplayed { dismissed.append(id) }
            else if before == .played && after == .unplayed && !all { unplayed.append(id) }
        }
        try emitEpisodeFacts(s, type: all ? "inbox.dismiss_all" : "inbox.dismiss", members: dismissed, bulkKey: "episodes",
                             overlays: { entity, _ in [ServerOverlay(entity: "episode", id: entity, property: "play_state", kind: .dismiss, value: nil)] },
                             provenanceGroups: ["play_state"])
        try emitEpisodeFacts(s, type: "episode.mark_unplayed", members: unplayed,
                             overlays: { entity, _ in [self.register(entity, "play_state", "unplayed")] }, provenanceGroups: ["play_state"])
        for id in dismissed + unplayed { s.account(.episode(id, .playState)) }
    }

    // MARK: - Queue

    /// One queue member a fact names, by its own podcast's binding.
    struct PlacedMember {
        let id: Int64
        let ref: ContractJSON
        let target: ContractJSON
        let entityID: String
        let key: StoredQueueKey
    }

    /// Who names a queue member: every registered podcast's members share the main author (one fact across podcasts),
    /// a pending registration's members its chain; device-only entries and podcasts the account does not know are
    /// never named. `register` lets a synced action register a preview (PROTOCOL §15.2).
    func queueBinding(_ id: Int64, _ s: RecordingSession, register: Bool) throws -> PodcastBinding? {
        guard try !isDeviceOnly(id, s), let feed = try feedOf(id, s) else { return nil }
        let binding = register ? try registeredBinding(feed, s) : try binding(feed, s)
        switch binding {
        case .registered, .pending: return binding
        case .localFolder, .unregistered: return nil
        }
    }

    private static func sameAuthor(_ a: PodcastBinding, _ b: PodcastBinding) -> Bool {
        switch (a, b) {
        case (.registered, .registered): true
        case (.pending(let x, _), .pending(let y, _)): x == y
        default: false
        }
    }

    /// Groups members by the author that names them, keeping their order; each member keeps its own binding.
    func queueGroups(_ ids: [Int64], _ s: RecordingSession, register: Bool) throws -> [(author: PodcastBinding, members: [PlacedMember])] {
        var groups: [(author: PodcastBinding, members: [PlacedMember])] = []
        for id in ids {
            guard let binding = try queueBinding(id, s, register: register), let key = s.queueKeys[id],
                  let reference = try episodeReference(id, binding: binding, s) else { continue }
            let member = PlacedMember(id: id, ref: reference.ref, target: reference.target, entityID: reference.entityID, key: key)
            if let index = groups.firstIndex(where: { Self.sameAuthor($0.author, binding) }) { groups[index].members.append(member) }
            else { groups.append((binding, [member])) }
        }
        return groups
    }

    /// One command's members by author, for placements (PROTOCOL §7.6): the main author's members, every
    /// registered podcast's, are one run (its facts replay in order on one chain). A pending registration's members
    /// are split into runs wherever another author's member comes between them: its drafts depend on the command's
    /// main-author facts, so they replay after them, and each run goes into its own gap. `followedByMain` says whether
    /// a main-author member comes after the run.
    struct AuthorRun {
        var author: PodcastBinding
        var members: [PlacedMember]
        var followedByMain = false
        var isMain: Bool { if case .registered = author { true } else { false } }
    }

    func authorRuns(_ ids: [Int64], _ s: RecordingSession, register: Bool) throws -> [AuthorRun] {
        var runs: [AuthorRun] = []
        var main: Int?, open: Int?
        for id in ids {
            guard let binding = try queueBinding(id, s, register: register), let key = s.queueKeys[id],
                  let reference = try episodeReference(id, binding: binding, s) else { continue }
            let member = PlacedMember(id: id, ref: reference.ref, target: reference.target, entityID: reference.entityID, key: key)
            if case .registered = binding {
                if let main { runs[main].members.append(member) } else { main = runs.count; runs.append(AuthorRun(author: binding, members: [member])) }
                for index in runs.indices where !runs[index].isMain { runs[index].followedByMain = true }
                open = nil
            } else if let open, Self.sameAuthor(runs[open].author, binding) {
                runs[open].members.append(member)
            } else {
                open = runs.count
                runs.append(AuthorRun(author: binding, members: [member]))
            }
        }
        // The main author's facts first: the drafts name them as dependencies.
        return runs.filter(\.isMain) + runs.filter { !$0.isMain }
    }

    private func positionOverlay(_ member: PlacedMember) -> ServerOverlay {
        register(member.entityID, "queue_position", ["key": .string(member.key.key.wire), "position_id": .string(member.key.positionID)])
    }

    // MARK: Placement intent (PROTOCOL §7.6)

    /// A queue `place` (PROTOCOL §7.6) and, for `after`, the anchor's target (what the fact must follow).
    struct QueuePlace {
        var json: ContractJSON
        var anchor: ContractJSON?
        static let start = QueuePlace(json: ["kind": "start"])
        static let end = QueuePlace(json: ["kind": "end"])
        var isStart: Bool { json["kind"]?.stringValue == "start" }
    }

    /// The anchor a fact of `author` can name (PROTOCOL §7.6): a registered podcast's episode for any
    /// author; a pending registration's episode only on its own chain, by its placeholder; never a local folder's, an
    /// unregistered preview's or another registration's episode (a gap next to those is projected onto nameable
    /// neighbours). An anchor is context, never a target.
    private func anchorReference(_ id: Int64, author: PodcastBinding, _ s: RecordingSession) throws -> (ref: ContractJSON, target: ContractJSON)? {
        guard try !isDeviceOnly(id, s), let feed = try feedOf(id, s) else { return nil }
        let binding = try binding(feed, s)
        switch binding {
        case .registered: break
        case .pending: guard Self.sameAuthor(binding, author) else { return nil }
        case .localFolder, .unregistered: return nil
        }
        return try episodeReference(id, binding: binding, s).map { ($0.ref, $0.target) }
    }

    /// `after` the nearest episode of `preceding` (scanned from its end) the author can name, else `start`.
    private func place(after preceding: some BidirectionalCollection<Int64>, author: PodcastBinding, _ s: RecordingSession) throws -> QueuePlace {
        for id in preceding.reversed() {
            if let anchor = try anchorReference(id, author: author, s) {
                return QueuePlace(json: ["kind": "after", "after": anchor.ref], anchor: anchor.target)
            }
        }
        return .start
    }

    /// An inserted run's place for the fact whose first member is `first` (PROTOCOL §7.6): `end` for an add at
    /// the back; otherwise the gap it was inserted into, as executed: `start` at index 0, else `after` the episode
    /// before it (the tail too: after the last, never `end`). A gap next to entries the author cannot name is
    /// projected onto the nearest one before it; the run's earlier members count, so a later chunk or another
    /// author's members follow them. A pending registration's run that a main-author member follows takes its gap at
    /// the back too (`endAllowed` false): its draft replays after the main-author facts.
    func insertionPlace(_ insertion: QueueInsertion, first: Int64, author: PodcastBinding, endAllowed: Bool = true,
                        _ s: RecordingSession) throws -> QueuePlace {
        if insertion.end && endAllowed { return .end }
        let offset = insertion.members.firstIndex(of: first) ?? 0
        return try place(after: insertion.before.prefix(min(insertion.index, insertion.before.count)) + insertion.members.prefix(offset),
                         author: author, s)
    }

    /// A moved run's place in the resulting queue (PROTOCOL §7.6: drags, Move to top and bottom, multi-select
    /// moves): `start` when the author can name no episode before it, `end` when none after it, else `after` the
    /// nearest one before it.
    private func runPlace(_ run: [Int64], in order: [Int64], author: PodcastBinding, _ s: RecordingSession) throws -> QueuePlace {
        guard let first = run.first, let last = run.last, let start = order.firstIndex(of: first),
              let finish = order.lastIndex(of: last) else { return .end }
        let before = try place(after: order[..<start], author: author, s)
        if before.isStart { return before }
        let members = Set(run)
        for id in order[(finish + 1)...] where !members.contains(id) {
            if try anchorReference(id, author: author, s) != nil { return before }
        }
        return .end
    }

    /// What a fact naming `place` depends on besides `dependencies`: on the main author, the latest unretired fact of
    /// another author that placed its anchor, so the server has seen the anchor (as for the members).
    private func dependencies(_ dependencies: [String], place: QueuePlace, author: PodcastBinding, _ s: RecordingSession) throws -> [String] {
        guard case .registered = author, let anchor = place.anchor, let entity = anchor["entity"]?.stringValue,
              let id = anchor["id"]?.stringValue else { return dependencies }
        return dependencies + (try latestRegistrationFacts(on: [ServerFactTarget(entity: entity, id: id, generation: anchor["generation"]?.stringValue)], s))
    }

    /// The predicted keys of members a command re-keyed but does not name (keys are predictions, PROTOCOL §7.6):
    /// a Keep sorted pass, the sort sheet, a re-key of the longest increasing run. They are overlays of the command's
    /// first fact, so the queue shows this device's order until the server's keys arrive.
    func rekeyedOverlays(_ s: RecordingSession, excluding: Set<Int64>) throws -> [ServerOverlay] {
        var overlays: [ServerOverlay] = []
        for id in s.queueAfter where s.freshKeys.contains(id) && !excluding.contains(id) {
            guard let binding = try queueBinding(id, s, register: false), let key = s.queueKeys[id],
                  let reference = try episodeReference(id, binding: binding, s) else { continue }
            overlays.append(register(reference.entityID, "queue_position",
                                     ["key": .string(key.key.wire), "position_id": .string(key.positionID)]))
        }
        return overlays
    }

    // MARK: Placement commands (PROTOCOL §7.6)

    /// `queue.add` or `queue.restore {members, place}`: one author's members in their order with their keys, at most
    /// 500 to a fact (PROTOCOL §15.2); the add's NEW → UNPLAYED is its fixed effect. `extra` overlays go with the first fact.
    @discardableResult
    func emitAdd(_ s: RecordingSession, type: String, author: PodcastBinding, members: [PlacedMember], place: QueuePlace,
                 dependencies: [String], extra: inout [ServerOverlay]) throws -> String {
        var overlays: [ServerOverlay] = []
        for member in members {
            overlays += [register(member.entityID, "queue_membership", true), positionOverlay(member),
                         ServerOverlay(entity: "episode", id: member.entityID, property: "play_state", kind: .dismiss, value: nil)]
        }
        overlays += extra
        extra = []
        return try emit(s, binding: author, type: type, targets: members.map(\.target),
                        payload: ["members": .array(members.map { placement($0.ref, key: $0.key) }), "place": place.json],
                        overlays: overlays, dependencies: try self.dependencies(dependencies, place: place, author: author, s),
                        members: members.map(\.id)).opID
    }

    /// An add's or an Undo's facts for one insertion: per author run (`authorRuns`), its members in order, each fact at
    /// the place that author resolves for its first member (PROTOCOL §7.6); drafts depend on the insertion's
    /// main-author facts.
    @discardableResult
    private func emitInsertion(_ s: RecordingSession, type: String, _ insertion: QueueInsertion, members: [Int64],
                               dependencies: [String], extra: inout [ServerOverlay]) throws -> [String] {
        var mainFacts: [String] = []
        for run in try authorRuns(members, s, register: true) {
            for start in stride(from: 0, to: run.members.count, by: Self.factMemberLimit) {
                let chunk = Array(run.members[start..<min(run.members.count, start + Self.factMemberLimit)])
                // A pending registration's run keeps the gap it was inserted into, at the back too (its draft replays
                // after the main author's facts); with no episode before it its author can name, at the back it goes
                // to the end unless a main-author member follows it.
                var place = try insertionPlace(insertion, first: chunk[0].id, author: run.author, endAllowed: run.isMain, s)
                if !run.isMain, insertion.end, place.isStart, !run.followedByMain { place = .end }
                let op = try emitAdd(s, type: type, author: run.author, members: chunk, place: place,
                                     dependencies: dependencies + (run.isMain ? [] : mainFacts), extra: &extra)
                if run.isMain { mainFacts.append(op) }
            }
        }
        return mainFacts
    }

    /// After a main-author command that placed episodes, each pending registration's queued episodes are placed again
    /// where this phone shows them: a snapshot of drafts on the registration's chain, one per run of its episodes in
    /// the queue, `after` the nearest episode before the run the chain can name (a registered podcast's, or its own),
    /// else `start`, depending on the command's main-author facts. While a registration is pending (a whole outage,
    /// perhaps) the main author's commands cannot name its episodes, and its drafts, which depend on its resolution,
    /// replay after them; the snapshot, made from the queue the person saw when acting, settles them where the phone
    /// shows them, with other devices' changes merged around the anchors. The main author never waits for a
    /// registration. Members this command's own drafts placed are left to them.
    ///
    /// Every snapshot replays after the registration resolves, after all of the main author's commands meanwhile, so
    /// only the latest one has a lasting effect: each replaces the registration's previous one, which was never sent
    /// (its chain is renumbered; the person's own adds, removals and Undo stay). Under Keep sorted there is none: the
    /// sorted adds and sort triggers order the queue at replay, and a snapshot would undo them.
    func replacePendingMembers(_ s: RecordingSession, after mainFacts: [String], placed: Set<Int64>, dependencies: [String]) throws {
        guard !mainFacts.isEmpty else { return }
        for row in try database.rows("SELECT author_id FROM ntp_registrations WHERE state = 'pending'") {
            if let author = row[0].text { try dropPlacementSnapshot(author: author, s.writer) }
        }
        let insertion = queueInsertionSettings.keepSortedOrder
        guard insertion == nil || insertion == .random,
              try !ServerAccountPolicyValues.read(database, accountID: s.context.accountID).keepSorted else { return }
        var runs: [(author: PodcastBinding, ids: [Int64])] = []
        var last: PodcastBinding?
        for id in s.queueAfter {
            if let binding = try queueBinding(id, s, register: false), case .pending = binding {
                if let last, Self.sameAuthor(last, binding) { runs[runs.count - 1].ids.append(id) } else { runs.append((binding, [id])) }
                last = binding
            } else { last = nil }
        }
        for run in runs where !run.ids.allSatisfy(placed.contains) {
            guard case .pending(let registration, let author) = run.author, let first = s.queueAfter.firstIndex(of: run.ids[0]) else { continue }
            var members: [PlacedMember] = []
            for id in run.ids {
                guard let key = s.queueKeys[id], let reference = try episodeReference(id, binding: run.author, s) else { continue }
                members.append(PlacedMember(id: id, ref: reference.ref, target: reference.target, entityID: reference.entityID, key: key))
            }
            for start in stride(from: 0, to: members.count, by: Self.factMemberLimit) {
                let chunk = Array(members[start..<min(members.count, start + Self.factMemberLimit)])
                let place = start == 0 ? try self.place(after: s.queueAfter[..<first], author: run.author, s)
                    : QueuePlace(json: ["kind": "after", "after": members[start - 1].ref])
                let payload: ContractObject = ["run": .array(chunk.map(\.ref)), "place": place.json,
                                               "members": .array(chunk.map { placement($0.ref, key: $0.key) })]
                // The snapshot carries no overlays: it shows nothing new (the command's own facts show any re-keying).
                let template: ContractJSON = ["type": "queue.reorder", "targets": .array(chunk.map(\.target)), "payload": .object(payload),
                                              "secret_ids": [], Self.snapshotMarker: true]
                try s.writer.appendDraft(registrationOp: registration, authorID: author, type: "queue.reorder", template: template,
                                         dependencies: dependencies + mainFacts, clientTime: s.clientTime, now: s.now)
            }
        }
    }

    /// The template member marking an automatic placement snapshot (never part of the fact).
    static let snapshotMarker = "ntp_snapshot"

    /// Removes a registration chain's automatic placement snapshot and renumbers the drafts after it, so the chain
    /// stays contiguous; nothing depends on a snapshot, and drafts are not sent before materialization.
    func dropPlacementSnapshot(author: String, _ writer: ServerOutboxWriter) throws {
        let marker = "%\"\(Self.snapshotMarker)\":true%"
        let dropped = try database.rows("SELECT op_id, author_seq FROM ntp_drafts WHERE author_id = ? AND CAST(template AS TEXT) LIKE ? ORDER BY author_seq",
                                        [.text(author), .text(marker)])
        guard let lowest = dropped.first?[1].integer else { return }
        for row in dropped {
            guard let op = row[0].text else { continue }
            try writer.execute("DELETE FROM ntp_drafts WHERE op_id = ?", [.text(op)])
            try writer.execute("DELETE FROM ntp_overlays WHERE op_id = ?", [.text(op)])
            try writer.execute("DELETE FROM ntp_nodes WHERE node_id = ? AND kind = 'draft'", [.text(op)])
        }
        var previous = try database.rows("SELECT op_id FROM ntp_drafts WHERE author_id = ? AND author_seq < ? ORDER BY author_seq DESC LIMIT 1",
                                         [.text(author), .integer(lowest)]).first?.first?.text
        var next = lowest
        for row in try database.rows("SELECT op_id FROM ntp_drafts WHERE author_id = ? AND author_seq > ? ORDER BY author_seq", [.text(author), .integer(lowest)]) {
            guard let op = row[0].text else { continue }
            try writer.execute("UPDATE ntp_drafts SET author_seq = ?, previous_op_id = ? WHERE op_id = ?",
                               [.integer(next), previous.map(LibrarySQLValue.text) ?? .null, .text(op)])
            previous = op
            next += 1
        }
        try writer.execute("UPDATE ntp_authors SET next_seq = ?, last_op_id = ? WHERE author_id = ?",
                           [.integer(next), previous.map(LibrarySQLValue.text) ?? .null, .text(author)])
    }

    /// `queue.add {members, place}` per insertion, members in requested order with their keys (PROTOCOL §7.6).
    /// An episode already queued is not added (Android skips it, and the sender emits no add for it, PROTOCOL §7). Under
    /// Keep sorted the add inserted at its place and then sorted, as Android does and the server replays; the
    /// members the pass re-keyed are overlays only (a placement carries no `moves`).
    private func mapQueueAdd(_ s: RecordingSession, record: Bool) throws {
        let before = Set(s.capture.queueBefore)
        let added = s.queueAfter.filter { !before.contains($0) }
        if record {
            let addedSet = Set(added)
            let deps = try queueProvenance(s)
            var extra = try rekeyedOverlays(s, excluding: addedSet)
            var mainFacts: [String] = []
            for insertion in s.capture.queueInsertions {
                mainFacts += try emitInsertion(s, type: "queue.add", insertion, members: insertion.members.filter(addedSet.contains),
                                               dependencies: deps, extra: &extra)
            }
            try replacePendingMembers(s, after: mainFacts, placed: addedSet, dependencies: deps)
        }
        for id in added {
            s.account(.queueIn(id))
            if s.capture.episodes[id]?.before?.userState.playState == .new && s.capture.episodes[id]?.after?.userState.playState == .unplayed {
                s.account(.episode(id, .playState))
            }
        }
        if s.capture.keepSortedAdd || !record { s.account(.queueOrder) }
    }

    private func mapQueueRemove(_ s: RecordingSession, reason: ServerIntent.QueueRemovalReason) throws {
        let after = Set(s.queueAfter)
        let removed = s.capture.queueBefore.filter { !after.contains($0) }
        try emitEpisodeFacts(s, type: "queue.remove", members: removed, bulkKey: "episodes",
                             extra: { _ in ["reason": .string(reason.rawValue)] },
                             overlays: { entity, _ in [self.register(entity, "queue_membership", false)] },
                             dependencies: try queueProvenance(s))
        for id in removed { s.account(.queueOut(id)) }
        if let receipt = s.capture.queueRemovalReceipt, let key = s.removedKeys[receipt.episodeID] {
            s.capture.afterCommit.append { store in store.queueRemovalKeys[receipt.operationID] = key }
        }
    }

    /// `queue.restore {members, place}` at the saved index resolved at Undo time (PROTOCOL §7.6), depending on
    /// what the person saw of the queue and of the restored episode (PROTOCOL §15.2). Undo never sorts.
    private func mapQueueRestore(_ s: RecordingSession) throws {
        let before = Set(s.capture.queueBefore)
        let restored = s.queueAfter.filter { !before.contains($0) }
        let restoredSet = Set(restored)
        let deps = try queueProvenance(s)
        var extra = try rekeyedOverlays(s, excluding: restoredSet)
        var mainFacts: [String] = []
        for insertion in s.capture.queueInsertions {
            mainFacts += try emitInsertion(s, type: "queue.restore", insertion, members: insertion.members.filter(restoredSet.contains),
                                           dependencies: deps, extra: &extra)
        }
        try replacePendingMembers(s, after: mainFacts, placed: restoredSet, dependencies: deps)
        for id in restored {
            s.account(.queueIn(id))
            if s.capture.episodes[id]?.before?.userState.playState == .new { s.account(.episode(id, .playState)) }
        }
    }

    /// A drag → `queue.move {episode, key, position_id, place}`; Move to top or bottom and multi-select moves →
    /// `queue.reorder {run, place, members}`: the complete selected run in its resulting order, its place in the
    /// resulting queue, and the device's key predictions (PROTOCOL §15.2, §7.6). Registered members of every
    /// podcast go in one main-author fact, at most 500 to a fact.
    private func mapQueueMove(_ s: RecordingSession, boundary: Bool) throws {
        let selected = Set(s.capture.movedQueueEpisodes)
        let run = s.queueAfter.filter(selected.contains)
        let deps = try queueProvenance(s)
        var extra = try rekeyedOverlays(s, excluding: selected)
        var mainFacts: [String] = []
        for group in try authorRuns(run, s, register: true) {
            for start in stride(from: 0, to: group.members.count, by: Self.factMemberLimit) {
                let chunk = Array(group.members[start..<min(group.members.count, start + Self.factMemberLimit)])
                // A pending registration's run that a moved main-author member follows replays after that member's
                // fact: its place is the gap it landed in.
                let place: QueuePlace
                if !group.isMain && group.followedByMain, let first = s.queueAfter.firstIndex(of: chunk[0].id) {
                    place = try self.place(after: s.queueAfter[..<first], author: group.author, s)
                } else {
                    place = try runPlace(chunk.map(\.id), in: s.queueAfter, author: group.author, s)
                }
                let overlays = chunk.map(positionOverlay) + extra
                extra = []
                let factDeps = try dependencies(deps, place: place, author: group.author, s) + (group.isMain ? [] : mainFacts)
                let fact: RecordedFact
                if !boundary, chunk.count == 1, case .object(var payload) = placement(chunk[0].ref, key: chunk[0].key) {
                    payload["place"] = place.json
                    fact = try emit(s, binding: group.author, type: "queue.move", targets: [chunk[0].target], payload: payload,
                                    overlays: overlays, dependencies: factDeps, members: [chunk[0].id])
                } else {
                    fact = try emit(s, binding: group.author, type: "queue.reorder", targets: chunk.map(\.target),
                                    payload: ["run": .array(chunk.map(\.ref)), "place": place.json,
                                              "members": .array(chunk.map { placement($0.ref, key: $0.key) })],
                                    overlays: overlays, dependencies: factDeps, members: chunk.map(\.id))
                }
                if group.isMain { mainFacts.append(fact.opID) }
            }
        }
        try replacePendingMembers(s, after: mainFacts, placed: selected, dependencies: deps)
        s.account(.queueOrder)
    }

    /// The sort sheet: `queue.reorder {sort: {sort_order, permutation?}, observed}` on the account (PROTOCOL §7.6, §15.4
    /// ), sent even when it changes nothing here, since another phone's unseen add can make it matter. `observed`
    /// is every registered member it saw (possibly none); a random sort's `permutation` is this device's resulting
    /// order of them. Members of pending registrations and local folders cannot be named; their predicted keys, as
    /// every re-keyed member's, are the fact's overlays.
    private func mapQueueSort(_ s: RecordingSession) throws {
        guard let order = s.capture.queueSortOrder else { return }
        var references: [Int64: (ref: ContractJSON, target: ContractJSON)] = [:]
        var observed: [Int64] = []
        for id in s.capture.queueBefore {
            guard let binding = try queueBinding(id, s, register: false), case .registered = binding,
                  let reference = try episodeReference(id, binding: binding, s) else { continue }
            references[id] = (reference.ref, reference.target)
            observed.append(id)
        }
        var sort: ContractObject = ["sort_order": Self.wire(order)]
        if order == .random { sort["permutation"] = .array(s.queueAfter.compactMap { references[$0]?.ref }) }
        let targets = observed.compactMap { id -> ServerFactTarget? in
            guard let target = references[id]?.target, let entity = target["entity"]?.stringValue, let wire = target["id"]?.stringValue else { return nil }
            return ServerFactTarget(entity: entity, id: wire, generation: target["generation"]?.stringValue)
        }
        // The sort follows what it observed: the members' records and any of their placements another author made.
        let deps = try queueProvenance(s) + latestRegistrationFacts(on: targets, s)
        let op = try s.writer.appendFact(type: "queue.reorder", targets: [ServerFactTarget(entity: "account", id: s.context.accountID)],
                                         payload: ["sort": .object(sort), "observed": .array(observed.compactMap { references[$0]?.ref })],
                                         dependencies: deps, overlays: try rekeyedOverlays(s, excluding: []),
                                         clientTime: s.clientTime, now: s.now)
        // A pending registration's members cannot be observed: they are placed again where the sort put them.
        try replacePendingMembers(s, after: [op], placed: [], dependencies: try queueProvenance(s))
        s.account(.queueOrder)
    }

    /// `queue.clear {observed}`: every synced member; device-only entries are cleared locally (PROTOCOL §7).
    private func mapQueueClear(_ s: RecordingSession) throws {
        let after = Set(s.queueAfter)
        let cleared = s.capture.queueBefore.filter { !after.contains($0) }
        try emitEpisodeFacts(s, type: "queue.clear", members: cleared, bulkKey: "observed",
                             overlays: { entity, _ in [self.register(entity, "queue_membership", false)] },
                             dependencies: try queueProvenance(s))
        for id in cleared { s.account(.queueOut(id)) }
    }

    // MARK: - History, statistics, account policies

    /// The registration chains whose drafts name a local episode (deferred `history.remove`, PROTOCOL §15.2).
    private func chainsNaming(_ episodeID: Int64) throws -> [(op: String, author: String)] {
        // A registration's chain continues on its current author (a copy forked it, PROTOCOL §6.10), whose tip descends from
        // every draft before it.
        try database.rows("SELECT DISTINCT d.registration_op, r.author_id FROM ntp_drafts d JOIN ntp_registrations r ON r.op_id = d.registration_op WHERE CAST(d.template AS TEXT) LIKE ? OR CAST(d.template AS TEXT) LIKE ? ORDER BY d.created_at, d.registration_op",
                          [.text("%\"ntp_local_episode\":\(episodeID),%"), .text("%\"ntp_local_episode\":\(episodeID)}%")]).compactMap {
            guard case .text(let op) = $0[0], case .text(let author) = $0[1] else { return nil }
            return (op, author)
        }
    }

    /// Every registration chain holding drafts (deferred cuts, PROTOCOL §15.2).
    private func chainsWithDrafts() throws -> [(op: String, author: String)] {
        try database.rows("SELECT d.registration_op, r.author_id, min(d.created_at) FROM ntp_drafts d JOIN ntp_registrations r ON r.op_id = d.registration_op GROUP BY d.registration_op ORDER BY 3, 1").compactMap {
            guard case .text(let op) = $0[0], case .text(let author) = $0[1] else { return nil }
            return (op, author)
        }
    }

    /// `history.remove` on the main author for a registered episode, depending on the whole frontier, plus a
    /// deferred removal on each registration chain whose drafts name it. The cut set is kept for Undo (PROTOCOL §15.2).
    private func mapHistoryRemove(_ s: RecordingSession) throws {
        guard let removal = s.capture.historyRemoval else { return }
        // Open sessions were flushed first (`recordPlaybackDue`, PROTOCOL §8.2).
        var cuts: [RecordedFact] = []
        let id = removal.episodeID
        if let feed = try feedOf(id, s) {
            switch try binding(feed, s) {
            case .registered:
                cuts += try emitEpisodeFacts(s, type: "history.remove", members: [id],
                                             overlays: { entity, _ in [ServerOverlay(entity: "episode", id: entity, property: "history", kind: .historyCut, value: nil)] },
                                             dependencies: try s.writer.frontier())
            default: break
            }
            var chains = try chainsNaming(id)
            if case .pending(let op, let author) = try binding(feed, s), !chains.contains(where: { $0.op == op }) { chains.append((op, author)) }
            for chain in chains {
                guard let reference = try episodeReference(id, binding: .pending(op: chain.op, author: chain.author), s) else { continue }
                cuts.append(try emit(s, binding: .pending(op: chain.op, author: chain.author), type: "history.remove", targets: [reference.target],
                                     payload: ["episode": reference.ref],
                                     overlays: [ServerOverlay(entity: "episode", id: reference.entityID, property: "history", kind: .historyCut, value: nil)],
                                     members: [id]))
            }
        }
        s.account(.episode(id, .history))
        let operation = removal.operationID
        s.capture.afterCommit.append { store in store.historyRemovalCuts[operation] = cuts }
    }

    /// One `history.restore {removal, time}` per cut of the removal, each depending on its removal (PROTOCOL §15.2).
    private func mapHistoryRestore(_ s: RecordingSession) throws {
        guard let restore = s.capture.historyRestore else { return }
        for cut in historyRemovalCuts[restore.operationID] ?? [] {
            guard let feed = try feedOf(restore.episodeID, s) else { continue }
            let binding: PodcastBinding
            if let registration = cut.registrationOp {
                // A deferred removal still waiting is restored on its chain; one already materialized on the main author.
                if try database.scalar("SELECT count(*) FROM ntp_drafts WHERE op_id = ?", [.text(cut.opID)]) == 1 {
                    binding = .pending(op: registration, author: cut.authorID)
                } else { binding = try self.binding(feed, s) }
            } else { binding = try self.binding(feed, s) }
            guard binding != .localFolder, binding != .unregistered,
                  let reference = try episodeReference(restore.episodeID, binding: binding, s) else { continue }
            _ = try emit(s, binding: binding, type: "history.restore", targets: [reference.target],
                         payload: ["episode": reference.ref, "removal": .string(cut.opID), "time": .integer(restore.time)],
                         overlays: [ServerOverlay(entity: "episode", id: reference.entityID, property: "history", kind: .historyRestore, value: .string(cut.opID))],
                         dependencies: [cut.opID], members: [restore.episodeID])
        }
        s.account(.episode(restore.episodeID, .history))
    }

    /// `history.clear` or `statistics.reset` on the main author, depending on the whole frontier, plus a deferred
    /// cut on every registration chain with drafts, whose causal past is exactly that chain's drafts (PROTOCOL §15.2).
    private func mapAccountCut(_ s: RecordingSession, type: String) throws {
        // Every open session's unexported save was exported first (`recordPlaybackDue`, PROTOCOL §8.2).
        let kind: ServerOverlay.Kind = type == "history.clear" ? .historyCut : .statCut
        let property = type == "history.clear" ? "history" : "played_time"
        let main = try s.writer.appendFact(type: type, targets: [], payload: [:], dependencies: try s.writer.frontier(),
                                           overlays: [ServerOverlay(entity: "account", id: s.context.accountID, property: property, kind: kind, value: nil)],
                                           clientTime: s.clientTime, now: s.now)
        var deferred: [String: String] = [:]
        for chain in try chainsWithDrafts() {
            let template: ContractJSON = ["type": .string(type), "targets": [], "payload": [:], "secret_ids": []]
            deferred[chain.op] = try s.writer.appendDraft(registrationOp: chain.op, authorID: chain.author, type: type, template: template,
                                                          overlays: [ServerOverlay(entity: "account", id: s.context.accountID, property: property, kind: kind, value: nil)],
                                                          clientTime: s.clientTime, now: s.now)
        }
        // The sessions it covers are cut at their latest exports (PROTOCOL §8.8).
        if type == "statistics.reset" { try notePendingStatisticsCut(s, main: main, deferred: deferred) }
        let field: SyncedChange.EpisodeField = type == "history.clear" ? .history : .playedDuration
        for change in s.pending { if case .episode(_, field) = change { s.account(change) } }
    }

    private func mapAccountPolicy(_ s: RecordingSession, change: ServerAccountPolicyChange) throws {
        let account = s.context.accountID
        let target = ServerFactTarget(entity: "account", id: account)
        switch change {
        case .newEpisodesAction(let action):
            let value = Self.wire(action == .global ? .inbox : action)
            try s.writer.appendFact(type: "account.set_discovery_policy", targets: [target], payload: ["new_episodes_action": value],
                                    dependencies: try provenance(entity: "account", id: account, groups: ["discovery_policy"]),
                                    overlays: [register(account, "new_episodes_action", value, kind: "account")], clientTime: s.clientTime, now: s.now)
        case .enqueueLocation(let location):
            try s.writer.appendFact(type: "account.set_queue_policy", targets: [target], payload: ["enqueue_location": Self.wire(location)],
                                    dependencies: try provenance(entity: "account", id: account, groups: ["queue_policy"]),
                                    overlays: [register(account, "enqueue_location", Self.wire(location), kind: "account")], clientTime: s.clientTime, now: s.now)
        case .sorting(let keepSorted, let order):
            // `random` turns Keep sorted off, as Android does (PROTOCOL §7.6).
            let sorting: ContractJSON = ["keep_sorted": .bool(keepSorted && order != .random), "sort_order": Self.wire(order)]
            try s.writer.appendFact(type: "account.set_queue_policy", targets: [target], payload: ["sorting": sorting],
                                    dependencies: try provenance(entity: "account", id: account, groups: ["queue_policy"]),
                                    overlays: [register(account, "sorting", sorting, kind: "account")], clientTime: s.clientTime, now: s.now)
        }
    }

}

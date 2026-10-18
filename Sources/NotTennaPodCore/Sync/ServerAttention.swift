import Foundation

/// An item of the Synchronization page's "Needs attention" list (PROTOCOL §15.5): only what a person can act
/// on. The unit that retires a refused fact records it in `ntp_attention`, in the same transaction; a recovery that
/// could not restore every change records `recovery_incomplete`.
public struct ServerAttentionItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A subscription the server did not complete because the podcast was removed elsewhere (`stale_subscribe`):
        /// "Subscribe again" subscribes afresh, with what this phone knows now.
        case staleSubscription(feedURL: String?, title: String?)
        /// A feed URL edit the server refused because the URL belongs to another podcast (`alias_conflict`).
        case refusedURL(url: String?, podcastTitle: String?, ownerTitle: String?)
        /// "Some changes were refused by the server": every refusal in one item, the log lists them.
        case refusedChanges(count: Int)
        /// A recovery after a server restore that could not restore every change.
        case incompleteRecovery(problems: Int)
        /// Listening on an episode whose export is larger than the server accepts (PROTOCOL §6.13): kept on this device until
        /// "Try again" sends it or "Keep only on this device" keeps it here for good. Never dismissed: until then it holds
        /// back history and statistics cuts.
        case refusedListening(episodeTitle: String?)
        /// A change to a podcast added while its registration was pending, too large for the server once its IDs were known:
        /// kept on this device, and the podcast's later changes made then wait behind it until "Try again" sends them.
        /// Never dismissed while they wait.
        case refusedTooLarge(podcastTitle: String?)
        /// A play load's queue add larger than the server accepts: the episode stays in this device's queue until "Try
        /// again" sends it or "Keep only on this device" keeps it there for good.
        case refusedQueueAdd(episodeTitle: String?)
    }

    /// Whether the item stands for work kept waiting on this device, which is sent or kept, never dismissed.
    public var waits: Bool {
        switch kind {
        case .refusedListening, .refusedTooLarge, .refusedQueueAdd: true
        default: false
        }
    }

    public var kind: Kind
    /// The `ntp_attention` rows the item stands for: dismissing it removes them.
    public var ids: [String]
    /// When it was recorded (its newest row), in milliseconds.
    public var createdAt: Int64

    public init(kind: Kind, ids: [String], createdAt: Int64) { self.kind = kind; self.ids = ids; self.createdAt = createdAt }

    /// Stable across reloads, for the screen's accessibility identifiers: one row's ID, or `rejected` for the refusals.
    public var identifier: String {
        if case .refusedChanges = kind { return "rejected" }
        return ids.first ?? ""
    }
}

extension FeedLibraryStore {
    /// The "Needs attention" items, newest first. A stale subscription that was subscribed again since (here, or on
    /// another device) is resolved and leaves the list (PROTOCOL §15.5 "Items clear when resolved or dismissed").
    public func serverAttentionItems() throws -> [ServerAttentionItem] {
        guard serverContext != nil else { return [] }
        var items: [ServerAttentionItem] = []
        var refused: [(id: String, time: Int64)] = []
        var resolved: [String] = []
        for row in try database.rows("SELECT id, kind, record, created_at FROM ntp_attention ORDER BY created_at DESC, id") {
            guard let id = row[0].text, let kind = row[1].text else { continue }
            let record = row[2].data.flatMap { try? ContractJSON.decode($0) }
            let time = row[3].integer ?? 0
            switch kind {
            case "rejected":
                refused.append((id, time))
            case "stale_subscribe":
                let url = try record?["feed_url"]?.stringValue
                    ?? database.rows("SELECT feed_url FROM ntp_registrations WHERE op_id = ?", [.text(id)]).first?.first?.text
                if try staleSubscriptionResolved(opID: id, url: url, since: time) { resolved.append(id); continue }
                items.append(.init(kind: .staleSubscription(feedURL: url, title: record?["title"]?.stringValue), ids: [id], createdAt: time))
            case "alias_conflict":
                items.append(.init(kind: .refusedURL(url: record?["url"]?.stringValue, podcastTitle: record?["podcast_title"]?.stringValue,
                                                     ownerTitle: record?["owner_title"]?.stringValue), ids: [id], createdAt: time))
            case "recovery_incomplete":
                items.append(.init(kind: .incompleteRecovery(problems: Int(record?["problems"]?.integerValue ?? 0)), ids: [id], createdAt: time))
            case "listening_refused":
                items.append(.init(kind: .refusedListening(episodeTitle: record?["title"]?.stringValue), ids: [id], createdAt: time))
            case "draft_refused":
                items.append(.init(kind: .refusedTooLarge(podcastTitle: record?["title"]?.stringValue), ids: [id], createdAt: time))
            case "queue_add_refused":
                items.append(.init(kind: .refusedQueueAdd(episodeTitle: record?["title"]?.stringValue), ids: [id], createdAt: time))
            default:
                continue
            }
        }
        if let newest = refused.first {
            items.append(.init(kind: .refusedChanges(count: refused.count), ids: refused.map(\.id), createdAt: newest.time))
        }
        if !resolved.isEmpty { try removeServerAttention(resolved) }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    /// Removes the item ("Dismiss"); the refusals stay in the sync log. Work kept waiting on this device is not dismissed:
    /// it is sent ("Try again") or kept here.
    public func dismissServerAttention(_ item: ServerAttentionItem) throws {
        guard serverContext != nil, !item.waits else { return }
        try removeServerAttention(item.ids)
    }

    /// "Try again" (and Synchronize now, Force full synchronization): what the server refused as too large is tried once more
    /// now (PROTOCOL §6.13): listening (sessions, leaves and finalizations) and owed queue adds here; refused again, it stays
    /// listed. Drafts are tried by `resumeRefusedDrafts`. Returns whether there was any.
    @discardableResult
    public func retryRefusedListening() throws -> Bool {
        guard serverContext != nil else { return false }
        // The next recording, this write's own, tries the listening: refused again, it is listed again in the same
        // transaction. An owed add is tried by the next replay (the next write, or the push).
        return try write(.local) {
            let refused = try refusedSessions()
            var transitions = try transitionState()
            let leaves = transitions.due.indices.filter { transitions.due[$0].refused == .tooLarge }
            let adds = try database.rows("SELECT subject FROM ntp_owed WHERE intent = 'queue.add.refused'").compactMap { $0[0].text }
            guard !refused.isEmpty || !leaves.isEmpty || !adds.isEmpty else { return false }
            for var session in refused {
                session.exportRefused = nil
                try storeSyncSession(session, journal)
                try database.execute("DELETE FROM ntp_attention WHERE id = ?", [.text(session.id)])
            }
            for index in leaves {
                transitions.due[index].refused = nil
                try database.execute("DELETE FROM ntp_attention WHERE id = ?", [.text(transitions.due[index].op)])
            }
            if !leaves.isEmpty { try storeTransitionState(transitions, journal) }
            for subject in adds {
                try database.execute("UPDATE ntp_owed SET intent = 'queue.add' WHERE intent = 'queue.add.refused' AND subject = ?", [.text(subject)])
                try database.execute("DELETE FROM ntp_attention WHERE id = ?", [.text(Self.refusedAddAttention(subject))])
            }
            if !refused.isEmpty || !leaves.isEmpty { try database.execute("UPDATE ntp_library SET export_owed = 1 WHERE id = 1") }
            return true
        }
    }

    /// "Keep only on this device": the person's consent that what the server refused stays here (PROTOCOL §6.13). A session's
    /// unexported saves become this device's own listening: shown as now in history and played time, never exported (nor
    /// its end), and covered by later history and statistics cuts here; a leave or finalization the same; an owed queue
    /// add keeps the episode in this device's queue, never sent.
    public func keepRefusedListeningOnThisDevice(_ item: ServerAttentionItem) throws {
        guard serverContext != nil, let id = item.ids.first else { return }
        switch item.kind {
        case .refusedListening, .refusedQueueAdd: break
        default: return
        }
        try write(.local) {
            var transitions = try transitionState()
            var changed = false
            if var session = try syncSession(id), session.exportRefused == .tooLarge {
                session.exportRefused = .keptLocal
                try storeSyncSession(session, journal)
                for index in transitions.due.indices where transitions.due[index].transition.kind == .finalize && transitions.due[index].transition.session == id {
                    transitions.due[index].refused = .keptLocal
                    changed = true
                }
            }
            for index in transitions.due.indices where transitions.due[index].op == id && transitions.due[index].refused == .tooLarge {
                transitions.due[index].refused = .keptLocal
                changed = true
            }
            if changed { try storeTransitionState(transitions, journal) }
            if case .refusedQueueAdd = item.kind, let subject = Self.refusedAddSubject(id) {
                try database.execute("UPDATE ntp_owed SET intent = 'queue.add.kept' WHERE intent = 'queue.add.refused' AND subject = ?", [.text(subject)])
            }
            try database.execute("DELETE FROM ntp_attention WHERE id = ?", [.text(id)])
        }
    }

    /// The attention row of a refused owed queue add (`ntp_owed` subject `episode:<id>`), and back.
    static func refusedAddAttention(_ subject: String) -> String { "queue.add:" + subject }
    static func refusedAddSubject(_ attention: String) -> String? {
        attention.hasPrefix("queue.add:") ? String(attention.dropFirst("queue.add:".count)) : nil
    }

    /// Items of the "Needs attention" list (PROTOCOL §15.5), as the list shows them: the refusals count once.
    func serverAttentionCount() throws -> Int { try serverAttentionItems().count }

    private func removeServerAttention(_ ids: [String]) throws {
        try database.transaction {
            for chunk in Self.chunks(ids) {
                try database.execute("DELETE FROM ntp_attention WHERE id IN (SELECT value FROM json_each(?))",
                                     [.text(ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText)])
            }
        }
    }

    /// Subscribed again since it was refused: a subscription of the same feed made on this phone later, or the
    /// podcast subscribed in the account again (another device).
    private func staleSubscriptionResolved(opID: String, url: String?, since time: Int64) throws -> Bool {
        if let url {
            let normalized = ContractURL.normalize(url)
            for row in try database.rows("SELECT feed_url FROM ntp_registrations WHERE kind = 'subscribe' AND op_id != ? AND created_at > ?",
                                         [.text(opID), .integer(time)]) {
                if let other = row[0].text, ContractURL.normalize(other).utf8.elementsEqual(normalized.utf8) { return true }
            }
        }
        guard let podcast = try database.rows("SELECT podcast_id FROM ntp_registrations WHERE op_id = ?", [.text(opID)]).first?.first?.text else {
            return false
        }
        return try serverRecord("podcast", podcast, "subscription")?["state"]?.stringValue == "subscribed"
    }

    /// What an item needs that the refused fact alone does not say, read in the unit that retires it (before the fact
    /// leaves the outbox and the projection removes a podcast the account no longer has): a stale subscription's feed
    /// URL (without userinfo) and title; the title of the podcast whose feed URL edit was refused.
    func attentionContext(_ kind: String, opID: String) throws -> ContractObject {
        switch kind {
        case "stale_subscribe":
            guard let row = try database.rows("SELECT feed_url, feed_id FROM ntp_registrations WHERE op_id = ?", [.text(opID)]).first else { return [:] }
            var result: ContractObject = [:]
            if let url = row[0].text { result["feed_url"] = .string(ContractURL.stripUserinfo(url)) }
            if let feed = row[1].integer, let title = try loadFeedHeader(feed)?.title { result["title"] = .string(title) }
            return result
        case "alias_conflict":
            guard let data = try database.rows("SELECT fact FROM ntp_outbox WHERE op_id = ?", [.text(opID)]).first?.first?.data,
                  let fact = try? ContractJSON.decode(data),
                  let podcast = fact["targets"]?.arrayValue?.first(where: { $0["entity"]?.stringValue == "podcast" })?["id"]?.stringValue
            else { return [:] }
            var title = try serverRecord("podcast", podcast, "metadata")?["title"]?.stringValue
            if title == nil, let feed = try database.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.integer {
                title = try loadFeedHeader(feed)?.title
            }
            return title.map { ["podcast_title": .string($0)] } ?? [:]
        default:
            return [:]
        }
    }
}

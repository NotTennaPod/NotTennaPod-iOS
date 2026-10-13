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

    /// Removes the item ("Dismiss"); the refusals stay in the sync log.
    public func dismissServerAttention(_ item: ServerAttentionItem) throws {
        guard serverContext != nil else { return }
        try removeServerAttention(item.ids)
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

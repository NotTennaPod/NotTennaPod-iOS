/// The plain episode identity of a fetched item (PROTOCOL §3.3 rules 2–4, without a podcast's identity rules) and
/// the server's rule for repeated items in one fetch.
public enum FetchEpisodeIdentity {
    /// An item's identity kind and value, as the server derives it from what it parsed: the trimmed GUID
    /// (`atom-id` in an Atom feed, else `rss-guid`), else the normalized enclosure URL (`enclosure`); nil
    /// with neither. Userinfo is removed from both first, as the server removes it from every parsed value.
    public static func plainIdentity(guid: String?, enclosureURL: String?, atom: Bool) -> (kind: ContractIdentity.EpisodeKind, value: String)? {
        if let guid = ContractIdentity.trimmedGUID(guid.map(ContractURL.stripUserinfo)) {
            return (atom ? .atomID : .rssGUID, guid)
        }
        if let url = enclosureURL, !url.isEmpty {
            return (.enclosure, ContractURL.normalize(ContractURL.stripUserinfo(url)))
        }
        return nil
    }

    /// The plain episode ID of an item; nil for an item without GUID and enclosure, which a phone
    /// identifies itself (`e0:` and a UUID).
    public static func plainEpisodeID(namespace: String, podcastID: String, guid: String?, enclosureURL: String?,
                                      atom: Bool) throws -> String? {
        guard let identity = plainIdentity(guid: guid, enclosureURL: enclosureURL, atom: atom) else { return nil }
        return try ContractIdentity.episodeID(namespace: namespace, podcastID: podcastID, kind: identity.kind, value: identity.value)
    }

    /// Repeated items in one fetch: the first item per derived episode ID is kept and later ones are skipped,
    /// as the server does. An item without a derived ID is its own episode and is always kept.
    /// Returns the kept positions in fetch order.
    public static func firstPerEpisode(_ episodeIDs: [String?]) -> [Int] {
        var seen = Set<[UInt8]>()
        return episodeIDs.indices.filter { index in
            guard let id = episodeIDs[index] else { return true }
            return seen.insert(Array(id.utf8)).inserted
        }
    }

    /// The first-item rule over a parsed feed with plain derivations.
    public static func firstPerEpisode(_ feed: ParsedFeed, namespace: String, podcastID: String) throws -> [ParsedEpisode] {
        let ids = try feed.episodes.map {
            try plainEpisodeID(namespace: namespace, podcastID: podcastID, guid: $0.identifier,
                               enclosureURL: $0.media?.url, atom: feed.format == .atom)
        }
        return firstPerEpisode(ids).map { feed.episodes[$0] }
    }
}

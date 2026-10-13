import Foundation

/// A refresh's parse at record level (PROTOCOL §9.4), what a server library observes and identifies items by: the
/// podcast `metadata` record's fields and, per item in feed order, its identity evidence and the episode `metadata`
/// record's fields (without `revision` and `fetch_time`; every string without URL userinfo). Its items are the items
/// of the `ParsedFeed` the refresh stores, index for index.
///
/// Server libraries' refreshes parse with the parity parse, which produces these values
/// directly (`init(parity:)`), a server library's subscription too. What the app's own parser fetched is mapped onto the
/// same shape (`ServerCatalogRecords.interim`). A first population is observed once its podcast's first canonical
/// metadata arrives or its wait ends, never filed (PROTOCOL §9.4).
public struct ServerCatalogParse: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var evidence: ServerItemEvidence
        /// The episode `metadata` record fields.
        public var fields: ContractJSON
        /// The fields' hash (`ntp_observed.parse_hash`) and canonical bytes, made with the parse, before the store
        /// compares, keeps (a deferred observation) or sends it; an unserializable record has
        /// none and is never sent.
        public let hash: String
        let canonical: [UInt8]
        var size: Int { canonical.isEmpty ? .max : canonical.count }
        public init(evidence: ServerItemEvidence, fields: ContractJSON) {
            self.evidence = evidence; self.fields = fields
            if let bytes = try? fields.canonicalBytes() {
                hash = ContractIdentity.sha256Hex(bytes); canonical = bytes
            } else {
                hash = ""; canonical = []
            }
        }

        /// An item as a deferred observation kept it (its fields decoded from `canonical`).
        init(evidence: ServerItemEvidence, fields: ContractJSON, canonical: [UInt8], hash: String) {
            self.evidence = evidence; self.fields = fields; self.canonical = canonical; self.hash = hash
        }

        /// Whether the item has an enclosure: a playable discovery (PROTOCOL §9.4); without one it is catalog-only.
        var isPlayable: Bool { (fields["media"]?["url"]?.stringValue).map { !$0.isEmpty } ?? false }
    }

    /// The podcast `metadata` record fields.
    public var feedFields: ContractJSON
    public var items: [Item]
    public let feedHash: String
    let feedCanonical: [UInt8]

    public init(feedFields: ContractJSON, items: [Item]) {
        self.feedFields = feedFields; self.items = items
        feedCanonical = (try? feedFields.canonicalBytes()) ?? []
        feedHash = feedCanonical.isEmpty ? "" : ContractIdentity.sha256Hex(feedCanonical)
    }

    /// The parser version a server library's observations declare (PROTOCOL §9.4): the parity parse's.
    static let parserVersion = ParityFeedParser.version
}

/// The record values of PROTOCOL §9.4 (`S/internal/ops/catalog.go` `podcastMetadataFields`, `episodeMetadataFields`, from
/// `S/internal/feed/model.go` `Object()`).
enum ServerCatalogRecords {
    static let podcastFields = ["title", "description", "author", "language", "link", "image_url", "type", "funding", "paged", "next_page_url"]
    static let episodeFields = ["title", "description", "link", "pub_date", "image_url", "payment_link", "media", "chapters",
                                "chapter_url", "transcript_url", "transcript_type", "social_interact_url"]

    /// The fields of a canonical `metadata` record (its value without `revision` and `fetch_time`), to compare with a
    /// parse.
    static func fields(ofCanonical record: ContractJSON?) -> ContractJSON? {
        guard case .object(var object)? = record else { return nil }
        object["revision"] = nil
        object["fetch_time"] = nil
        return .object(object)
    }

    /// A record value's hash: what a later parse is compared with (`ntp_observed.parse_hash`).
    static func hash(_ fields: ContractJSON) throws -> String { ContractIdentity.sha256Hex(try fields.canonicalBytes()) }

    /// The app's parse mapped onto the record values, for what the app's parser fetched (a subscription's first
    /// population): its values differ from Android's exactly where the app's parser does (`feed-parity-differences.json`);
    /// GUIDs and enclosures, which identify episodes, never do.
    static func interim(_ feed: ParsedFeed) -> ServerCatalogParse {
        func text(_ value: String?) -> ContractJSON { value.map { .string(ContractURL.stripUserinfo($0)) } ?? .null }
        let feedFields: ContractJSON = [
            "title": text(feed.title), "description": text(feed.description), "author": text(feed.author),
            "language": text(feed.language), "link": text(feed.link), "image_url": text(feed.imageURL),
            "type": .string(feed.format.rawValue),
            "funding": .array(feed.funding.map { ["url": text($0.url), "content": text($0.content)] }),
            "paged": .bool(feed.isPaged), "next_page_url": text(feed.nextPageURL),
        ]
        let items = feed.episodes.map { episode in
            item(episode, publicationTime: episode.publicationDate.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) },
                 atom: feed.format == .atom)
        }
        return ServerCatalogParse(feedFields: feedFields, items: items)
    }

    /// One item of a parse as the record values map it: `publicationTime` is the item's own date (nil: none), which a
    /// stored row cannot tell apart from the refresh time it was given.
    static func item(_ episode: ParsedEpisode, publicationTime date: Int64?, atom: Bool) -> ServerCatalogParse.Item {
        func text(_ value: String?) -> ContractJSON { value.map { .string(ContractURL.stripUserinfo($0)) } ?? .null }
        var media: ContractJSON = .null
        if let parsed = episode.media, let url = parsed.url, !url.isEmpty {
            media = ["url": .string(ContractURL.stripUserinfo(url)), "size": .string(String(parsed.size)),
                     "mime_type": text(parsed.mimeType), "duration": .integer(Int64(max(0, parsed.durationMilliseconds)))]
        }
        let chapters: ContractJSON = episode.chapters.map { list in
            .array(list.map { ["start": .string(String($0.startMilliseconds)), "title": text($0.title), "link": text($0.link),
                               "image_url": text($0.imageURL)] })
        } ?? .null
        let fields: ContractJSON = [
            "title": text(episode.title), "description": text(episode.description), "link": text(episode.link),
            "pub_date": date.map(ContractJSON.integer) ?? .null, "image_url": text(episode.imageURL),
            "payment_link": text(episode.paymentLink), "media": media, "chapters": chapters,
            "chapter_url": text(episode.chapterURL), "transcript_url": text(episode.transcript?.url),
            "transcript_type": text(episode.transcript?.format.rawValue), "social_interact_url": text(episode.socialInteractionURL),
        ]
        return .init(evidence: ServerItemEvidence(guid: episode.identifier, enclosureURL: episode.media?.url, publicationTime: date,
                                                  title: episode.title, atom: atom),
                     fields: fields)
    }
}

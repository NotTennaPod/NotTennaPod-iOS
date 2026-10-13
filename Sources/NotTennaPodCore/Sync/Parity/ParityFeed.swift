import Foundation

// The parity parse (PROTOCOL §9): a Swift port of the NotTennaPod server's feed parse
// (`internal/feed`, itself Android AntennaPod 3.12.1's parser rule for rule), used by server libraries, where
// observations, proposals and identity use the parse. Standalone libraries keep the app's own `FeedParser`.
//
// Public entry points:
// - `ParityFeedParser.parse(_:source:now:isCancelled:)`: a downloaded feed document to a `ParityFeed`, or a
//   `ParityParseError` with Android's download-error label (or `CancellationError`). Bounded: budgets on entity
//   expansion, text, items and depth make a hostile feed fail like a parser exception.
// - `ParityFeed.podcastFields` and `ParityItem.episodeFields`: the catalog metadata record fields a phone observes
//   (PROTOCOL §9.4, without `revision` and `fetch_time`; every string without URL userinfo), and
//   `ParityItem.occurrence(feedType:)`: the item's occurrence evidence with its plain derivation (PROTOCOL §3.3).
// - `FetchEpisodeIdentity.firstPerEpisode(_:namespace:podcastID:)` for a `ParityFeed`: the server's rule for repeated
//   items in one fetch on plain derivations; `FetchEpisodeIdentity.firstPerEpisode(_ episodeIDs:)` applies it to IDs
//   derived with a podcast's identity rules.
// - `ParityFeed.vectorObject`: the parse in the shared feed vectors' schema (`contract/vectors/feeds`).

/// A feed Android refuses: its download-error label (`parser_exception`, `unsupported_type` or
/// `unsupported_type_html`) and detail, as the server reports them.
public struct ParityParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var label: String
    public var detail: String?

    public init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }

    static let parserException = ParityParseError(label: "parser_exception")

    public var description: String { "feed: \(label): \(detail ?? "")" }
}

/// A parsed feed: Android's Feed and FeedHandlerResult fields (the server's `feed.Feed`).
public struct ParityFeed: Equatable, Sendable {
    /// "rss" or "atom"; nil for RSS 0.91 and 0.92 (TypeGetter sets no type for them).
    public var type: String?
    public var identifier: String?
    public var title: String?
    public var description: String?
    public var author: String?
    public var language: String?
    public var link: String?
    /// The feed's image, or the generative cover (`antennapod_generative_cover:` and the source URL).
    public var imageURL: String?
    public var funding: [ParityFunding] = []
    public var paged = false
    public var nextPageURL: String?
    /// itunes:new-feed-url.
    public var redirectURL: String?
    /// Podlove alternate feeds, URL and title, in the order their URLs first appear (a repeated URL keeps the later
    /// title, as Android's HashMap does).
    public var alternateURLs: [ParityAlternateFeed] = []
    /// An alternate link without href: Android's HashMap holds it under the null key, with its title (nil when the
    /// title is empty too).
    public var alternateNull: String?
    public var hasAlternateNull = false
    public var items: [ParityItem] = []

    public init() {}
}

public struct ParityAlternateFeed: Equatable, Sendable {
    public var url: String
    public var title: String
}

/// A feed's payment link (FeedFunding).
public struct ParityFunding: Equatable, Sendable {
    public var url: String?
    public var content: String?
}

/// A parsed episode (FeedItem).
public struct ParityItem: Equatable, Sendable {
    public var guid: String?
    public var title: String?
    public var description: String?
    public var link: String?
    /// Milliseconds since the epoch; nil when absent, unparseable or in the future.
    public var pubDate: Int64?
    public var imageURL: String?
    public var paymentLink: String?
    public var media: ParityMedia?
    /// nil when the item has no psc:chapters.
    public var chapters: [ParityChapter]?
    public var chapterURL: String?
    public var transcriptURL: String?
    public var transcriptType: String?
    public var socialInteractURL: String?

    public init() {}

    /// Transcript types and priorities (TranscriptType).
    private static func transcriptKind(_ mime: String) -> (Int, String) {
        if GoStrings.same(mime, "application/json") { return (4, "application/json") }
        if GoStrings.same(mime, "text/vtt") { return (3, "text/vtt") }
        if GoStrings.same(mime, "application/srt") || GoStrings.same(mime, "application/srr")
            || GoStrings.same(mime, "application/x-subrip") {
            return (2, "application/srt")
        }
        return (0, "")
    }

    /// FeedItem.updateTranscriptPreferredFormat.
    mutating func setTranscriptURL(type: String?, url: String?) {
        guard let type, !type.isEmpty, let url, !url.isEmpty else { return }
        let (priority, canonical) = Self.transcriptKind(type)
        let previous = transcriptType.map { Self.transcriptKind($0).0 } ?? 0
        if priority > previous {
            transcriptURL = url
            transcriptType = canonical
        }
    }
}

/// An item's enclosure (FeedMedia).
public struct ParityMedia: Equatable, Sendable {
    public var url: String?
    public var size: Int64
    public var mimeType: String?
    /// Milliseconds; Android keeps an int.
    public var duration: Int32 = 0
}

/// A Podlove simple chapter.
public struct ParityChapter: Equatable, Sendable {
    /// Milliseconds.
    public var start: Int64
    public var title: String?
    public var link: String?
    public var imageURL: String?
}

/// How a parse learns that it should stop (the server's fetch deadline covers parsing). The parse asks after type
/// detection, between tokens, before it returns anything, and inside long work: `tick` counts input-sized work
/// (bytes read, steps of a pass over a token or value) and asks every `interval` units, so one large token, value,
/// date or declaration stops too.
final class ParityCancellation {
    private let isCancelled: () -> Bool
    /// Units of work counted since the parse last asked.
    private var work = 0
    /// Units of work between questions: the server checks every 64 KiB read and every 65,536 steps.
    static let interval = 1 << 16

    init(isCancelled: @escaping () -> Bool) { self.isCancelled = isCancelled }

    /// Whether the parse should stop, asked now.
    var cancelled: Bool { isCancelled() }

    /// Asks now.
    func check() throws {
        if isCancelled() { throw CancellationError() }
    }

    /// Counts units of work, asking every interval of them.
    @inline(__always) func tick(_ units: Int = 1) throws {
        work &+= units
        if work >= Self.interval {
            work = 0
            try check()
        }
    }
}

public enum ParityFeedParser {
    /// The iOS parity parser's declared version (`parser_version`, PROTOCOL §9.4), raised whenever any output changes.
    public static let version = "ntp-ios/1"

    /// Generative cover marker for a feed without an image (a saved-data prefix).
    public static let generativeCoverPrefix = "antennapod_generative_cover:"

    /// Parses a feed document as Android's FeedParserTask, as the server does: TypeGetter picks the type,
    /// FeedHandler's SAX handlers parse, then the title checks and the generative cover. `source` is the feed's
    /// download URL; `now` (milliseconds) is the evaluation time of DateUtils.parseOrNullIfFuture. Throws
    /// `ParityParseError`, or `CancellationError` once `isCancelled` answers true: it is asked as the parse goes (at
    /// most every 65,536 units of work, within one token too) and once more before the parse returns, so a parse that
    /// was cancelled is neither a feed nor a parse error, however close to its end that came.
    public static func parse(_ data: Data, source: String, now: Int64,
                             isCancelled: () -> Bool = { Task.isCancelled }) throws -> ParityFeed {
        try withoutActuallyEscaping(isCancelled) { isCancelled in
            try parse(Array(data), source: source, now: now, cancellation: ParityCancellation(isCancelled: isCancelled))
        }
    }

    static func parse(_ raw: [UInt8], source: String, now: Int64, cancellation: ParityCancellation) throws -> ParityFeed {
        let result = Result { try parseUnchecked(raw, source: source, now: now, cancellation: cancellation) }
        // A parse whose cancellation came is neither a feed nor a parse error (the server's Parse).
        try cancellation.check()
        return try result.get()
    }

    private static func parseUnchecked(_ raw: [UInt8], source: String, now: Int64,
                                       cancellation: ParityCancellation) throws -> ParityFeed {
        guard let text = try ParityDecode.decodeDocument(raw, work: cancellation) else {
            // XmlStreamReader failed: TypeGetter's reader is unusable, and the document is classified as a website.
            throw try ParityWebsite.error(raw, cancellation: cancellation)
        }
        let typed = Result { try ParitySAX.typeOf(text, cancellation: cancellation) }
        try cancellation.check()  // after TypeGetter, before its answer counts (the server's parse.go)
        let (kind, language) = try typed.get()
        let state = ParityHandlerState(kind: kind, now: now, cancellation: cancellation)
        switch kind {  // TypeGetter sets no type for RSS 0.91 and 0.92
        case .atom:
            state.feed.type = "atom"
            if let language { state.feed.language = language }
        case .rss20:
            state.feed.type = "rss"
        case .rss091:
            break
        }
        try ParitySAX.parse(text, state: state)
        var feed = state.feed
        feed.author = state.feedAuthor
        feed.items = state.items
        feed.alternateURLs = state.alternates
        feed.alternateNull = state.alternateNull
        feed.hasAlternateNull = state.hasAlternateNull
        feed.redirectURL = state.redirectURL
        guard feed.title != nil else { throw ParityParseError(label: "parser_exception", detail: "Feed has no title") }
        if feed.items.contains(where: { $0.title == nil }) {
            throw ParityParseError(label: "parser_exception", detail: "Item has no title")
        }
        if feed.imageURL?.isEmpty ?? true { feed.imageURL = generativeCoverPrefix + source }
        return feed
    }
}

// MARK: - Records (PROTOCOL §9.4)

extension ParityFeed {
    /// The podcast metadata record fields of PROTOCOL §9.4 (without `revision` and `fetch_time`), every string without URL
    /// userinfo, as the server's `podcastFields` builds them from its parse.
    public var podcastFields: ContractObject {
        var object = ContractObject()
        let all = vectorObject.objectValue ?? ContractObject()
        for name in ["title", "description", "author", "language", "link", "image_url", "type", "funding", "paged",
                     "next_page_url"] {
            object[name] = Self.strippingUserinfo(all[name] ?? .null)
        }
        return object
    }

    /// StripUserinfo applied to every string of a JSON value (object keys stay).
    static func strippingUserinfo(_ value: ContractJSON) -> ContractJSON {
        switch value {
        case .string(let s): .string(ContractURL.stripUserinfo(s))
        case .array(let elements): .array(elements.map(strippingUserinfo))
        case .object(let object):
            .object(ContractObject(literal: object.members.map { ($0.name, strippingUserinfo($0.value)) }))
        default: value
        }
    }

    /// The parse in the shared feed vectors' schema (the server's `Feed.Object`, Android's GoldenFeedExportTest):
    /// Java longs a feed can make arbitrarily large are decimal strings.
    public var vectorObject: ContractJSON {
        func text(_ s: String?) -> ContractJSON { s.map(ContractJSON.string) ?? .null }
        var alternates = ContractObject()
        for alternate in alternateURLs { alternates[alternate.url] = .string(alternate.title) }
        var object: ContractObject = [
            "type": text(type), "identifier": text(identifier), "title": text(title), "description": text(description),
            "author": text(author), "language": text(language), "link": text(link), "image_url": text(imageURL),
            "funding": .array(funding.map { ["url": text($0.url), "content": text($0.content)] }), "paged": .bool(paged),
            "next_page_url": text(nextPageURL), "redirect_url": text(redirectURL), "alternate_feed_urls": .object(alternates),
            "items": .array(items.map(\.vectorObject))
        ]
        if hasAlternateNull { object["alternate_feed_url_null"] = text(alternateNull) }
        return .object(object)
    }
}

extension ParityItem {
    /// The episode metadata record fields of PROTOCOL §9.4 (without `revision` and `fetch_time`), every string without URL
    /// userinfo, as the server's `itemFields` builds them from its parse.
    public var episodeFields: ContractObject {
        var object = ContractObject()
        let all = vectorObject.objectValue ?? ContractObject()
        for name in ["title", "description", "link", "pub_date", "image_url", "payment_link", "media", "chapters",
                     "chapter_url", "transcript_url", "transcript_type", "social_interact_url"] {
            object[name] = ParityFeed.strippingUserinfo(all[name] ?? .null)
        }
        return object
    }

    /// The item's occurrence (PROTOCOL §3.3, the server's `itemOccurrence`): its trimmed GUID, enclosure, publication time
    /// and title, with the plain derivation (rules 2–4) as `k` and `v`; without GUID and enclosure it has no `k`.
    /// The GUID, enclosure and title lose their URL userinfo first. `feedType` is the feed's `type`.
    public func occurrence(feedType: String?) -> ContractObject {
        var occurrence = ContractObject()
        var guidValue: String?
        if let guid, let trimmed = ContractIdentity.trimmedGUID(ContractURL.stripUserinfo(guid)) {
            guidValue = trimmed
            occurrence["guid"] = .string(trimmed)
        }
        var enclosure: String?
        if let url = media?.url, !url.isEmpty {
            let stripped = ContractURL.stripUserinfo(url)
            occurrence["enclosure_url"] = .string(stripped)
            enclosure = ContractURL.normalize(stripped)
        }
        if let pubDate { occurrence["publication_time"] = .integer(pubDate) }
        if let title { occurrence["title"] = .string(ContractURL.stripUserinfo(title)) }
        if let guidValue {
            let atom = feedType.map { GoStrings.same($0, "atom") } ?? false
            occurrence["k"] = .string(atom ? ContractIdentity.EpisodeKind.atomID.rawValue : ContractIdentity.EpisodeKind.rssGUID.rawValue)
            occurrence["v"] = .string(guidValue)
        } else if let enclosure {
            occurrence["k"] = .string(ContractIdentity.EpisodeKind.enclosure.rawValue)
            occurrence["v"] = .string(enclosure)
        }
        return occurrence
    }

    /// The item in the shared feed vectors' schema (the server's `Item.Object`).
    public var vectorObject: ContractJSON {
        func text(_ s: String?) -> ContractJSON { s.map(ContractJSON.string) ?? .null }
        let mediaObject: ContractJSON = media.map {
            ["url": text($0.url), "size": .string(String($0.size)), "mime_type": text($0.mimeType),
             "duration": .integer(Int64($0.duration))]
        } ?? .null
        let chapterList: ContractJSON = chapters.map { list in
            .array(list.map { ["start": .string(String($0.start)), "title": text($0.title), "link": text($0.link),
                               "image_url": text($0.imageURL)] })
        } ?? .null
        return [
            "guid": text(guid), "title": text(title), "description": text(description), "link": text(link),
            "pub_date": pubDate.map(ContractJSON.integer) ?? .null, "image_url": text(imageURL),
            "payment_link": text(paymentLink), "media": mediaObject, "chapters": chapterList,
            "chapter_url": text(chapterURL), "transcript_url": text(transcriptURL), "transcript_type": text(transcriptType),
            "social_interact_url": text(socialInteractURL)
        ]
    }
}

extension FetchEpisodeIdentity {
    /// The plain episode ID of a parity-parsed item; nil for an item without GUID and enclosure, which a phone
    /// identifies itself (`e0:` and a UUID).
    public static func plainEpisodeID(namespace: String, podcastID: String, item: ParityItem, feedType: String?) throws -> String? {
        try plainEpisodeID(namespace: namespace, podcastID: podcastID, guid: item.guid, enclosureURL: item.media?.url,
                           atom: feedType.map { GoStrings.same($0, "atom") } ?? false)
    }

    /// The first-item rule over a parity parse with plain derivations: the items kept, in feed order.
    public static func firstPerEpisode(_ feed: ParityFeed, namespace: String, podcastID: String) throws -> [ParityItem] {
        let ids = try feed.items.map { try plainEpisodeID(namespace: namespace, podcastID: podcastID, item: $0, feedType: feed.type) }
        return firstPerEpisode(ids).map { feed.items[$0] }
    }
}

import Foundation

/// A server library's refresh parses with the parity parse: its record values are what the
/// library observes and identifies items by, and the same parse is what its rows show until the canonical metadata
/// arrives. A standalone library keeps the app's parser.
extension ServerCatalogParse {
    public init(parity feed: ParityFeed) {
        let atom = feed.type.map { $0 == "atom" } ?? false
        self.init(feedFields: .object(feed.podcastFields), items: feed.items.map { item in
            Item(evidence: ServerItemEvidence(guid: item.guid, enclosureURL: item.media?.url, publicationTime: item.pubDate,
                                              title: item.title, atom: atom),
                 fields: .object(item.episodeFields))
        })
    }
}

extension ParsedFeed {
    /// The parity parse as the rows store it (the fields `FeedParser` fills, index for index with its items).
    public init(parity feed: ParityFeed) {
        self.init(format: feed.type == "atom" ? .atom : .rss)
        identifier = feed.identifier; title = feed.title; description = feed.description; author = feed.author
        language = feed.language; link = feed.link; imageURL = feed.imageURL
        funding = feed.funding.compactMap { entry in entry.content.map { FeedFunding(url: entry.url, content: $0) } }
        isPaged = feed.paged; nextPageURL = feed.nextPageURL; redirectURL = feed.redirectURL
        alternateFeeds = feed.alternateURLs.map { AlternateFeed(title: $0.title, url: $0.url) }
        episodes = feed.items.map { item in
            var episode = ParsedEpisode(identifier: item.guid, title: item.title, description: item.description, link: item.link,
                                        publicationDate: item.pubDate.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
                                        imageURL: item.imageURL, paymentLink: item.paymentLink)
            episode.media = item.media.map { ParsedMedia(url: $0.url, size: $0.size, mimeType: $0.mimeType, durationMilliseconds: $0.duration) }
            episode.chapters = item.chapters?.map { ParsedChapter(startMilliseconds: $0.start, title: $0.title, link: $0.link, imageURL: $0.imageURL) }
            episode.chapterURL = item.chapterURL
            if let url = item.transcriptURL, let type = item.transcriptType, let format = FeedTranscript.Format(rawValue: type) {
                episode.transcript = FeedTranscript(format: format, url: url)
            }
            episode.socialInteractionURL = item.socialInteractURL
            return episode
        }
    }
}

extension FeedFetchError {
    /// A parity parse's refusal as the Download log shows a parse failure: Android's label, with its detail.
    /// `location`: where the document stops being well-formed XML, for a refusal without a detail
    /// (`ParityParseError.readable`).
    init(parity error: ParityParseError, location: (line: Int, column: Int)? = nil) {
        switch error.label {
        case "unsupported_type_html": self = .websiteInsteadOfFeed
        case "unsupported_type": self = .unsupportedFeed
        default:
            switch error.detail {
            case "Feed has no title": self = .missingFeedTitle
            case "Item has no title": self = .missingEpisodeTitle(index: 0)
            case let detail?: self = .parsing(.limitExceeded(detail))
            case nil:
                if let location { self = .parsing(.malformedXML(line: location.line, column: location.column)) }
                else { self = .parsing(.limitExceeded(ParityParseError.unreadableFeed)) }
            }
        }
    }
}

extension ParityParseError {
    /// The technical detail of a refusal with no detail of its own that the app's parser cannot place either.
    static let unreadableFeed = "The feed could not be parsed."

    /// A refusal as a person reads it in the Download log, never with the parse's internal label: its own detail; for one
    /// without, where `body` stops being well-formed XML, as the app's parser reads the same bytes ("Malformed XML at
    /// line N, column M."), else a plain sentence. The app's parser only words the refusal: it stands whatever that
    /// parser makes of the bytes.
    func readable(body: Data) -> (error: FeedFetchError, detail: String) {
        if let detail, !detail.isEmpty { return (FeedFetchError(parity: self), detail) }
        var location: (line: Int, column: Int)?
        do { _ = try FeedParser(timeLimit: .seconds(10)).parse(body) }
        catch FeedParsingError.malformedXML(let line, let column) { location = (line, column) }
        catch {}
        let error = FeedFetchError(parity: self, location: location)
        guard let location else { return (error, Self.unreadableFeed) }
        return (error, FeedDocumentClassifier.parserMessage(.malformedXML(line: location.line, column: location.column)))
    }
}

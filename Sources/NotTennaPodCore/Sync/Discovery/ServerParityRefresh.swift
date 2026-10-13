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
    init(parity error: ParityParseError) {
        switch error.label {
        case "unsupported_type_html": self = .websiteInsteadOfFeed
        case "unsupported_type": self = .unsupportedFeed
        default:
            switch error.detail {
            case "Feed has no title": self = .missingFeedTitle
            case "Item has no title": self = .missingEpisodeTitle(index: 0)
            default: self = .parsing(.limitExceeded(error.detail ?? error.label))
            }
        }
    }
}

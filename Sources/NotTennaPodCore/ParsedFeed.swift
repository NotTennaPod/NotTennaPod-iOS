import Foundation

public struct ParsedFeed: Equatable, Codable, Sendable {
    public enum Format: String, Codable, Sendable {
        case rss, atom
    }

    public var format: Format
    public var identifier: String?
    public var title: String?
    public var description: String?
    public var author: String?
    public var language: String?
    public var link: String?
    public var imageURL: String?
    public var funding: [FeedFunding] = []
    public var episodes: [ParsedEpisode] = []
    public var isPaged = false
    public var nextPageURL: String?
    public var redirectURL: String?
    public var alternateFeeds: [AlternateFeed] = []
}

public struct FeedFunding: Equatable, Codable, Sendable {
    public var url: String?
    public var content: String
}

public struct AlternateFeed: Equatable, Codable, Sendable {
    public var title: String?
    public var url: String?
}

public struct ParsedEpisode: Equatable, Codable, Sendable {
    public var identifier: String?
    public var title: String?
    public var description: String?
    public var link: String?
    public var publicationDate: Date?
    public var imageURL: String?
    public var paymentLink: String?
    public var media: ParsedMedia?
    public var chapters: [ParsedChapter]?
    public var chapterURL: String?
    public var transcript: FeedTranscript?
    public var socialInteractionURL: String?

    public func imageURL(in feed: ParsedFeed) -> String? {
        imageURL ?? feed.imageURL
    }

    mutating func setDescriptionIfLonger(_ value: String) {
        if description == nil || description!.utf16.count < value.utf16.count {
            description = value
        }
    }

    mutating func setTranscript(type: String, url: String) {
        guard !url.isEmpty, let format = FeedTranscript.Format(mimeType: type),
              format.priority > (transcript?.format.priority ?? 0) else { return }
        transcript = FeedTranscript(format: format, url: url)
    }
}

public struct ParsedMedia: Equatable, Codable, Sendable {
    public var url: String?
    public var size: Int64
    public var mimeType: String?
    public var durationMilliseconds: Int32 = 0
    /// Nil means not inspected (including older stored JSON and remote feeds).
    /// Image bytes remain in the media file and are read under its access grant.
    public var hasEmbeddedPicture: Bool?
    /// A local-folder file first listed while it was only in the cloud: its file-name title and
    /// size stand in until its metadata is read successfully, by a scan that finds it on the
    /// device or after playback opens it (`LocalPendingMetadata`). Nil otherwise.
    public var metadataPending: Bool?
}

public struct FeedTranscript: Equatable, Codable, Sendable {
    public enum Format: String, Codable, Sendable {
        case json = "application/json"
        case vtt = "text/vtt"
        case srt = "application/srt"

        init?(mimeType: String) {
            switch mimeType {
            case "application/json": self = .json
            case "text/vtt": self = .vtt
            case "application/srt", "application/srr", "application/x-subrip": self = .srt
            default: return nil
            }
        }

        var priority: Int {
            switch self {
            case .json: 4
            case .vtt: 3
            case .srt: 2
            }
        }
    }

    public var format: Format
    public var url: String
}

public struct ParsedChapter: Equatable, Codable, Sendable {
    public var startMilliseconds: Int64
    public var title: String?
    public var link: String?
    public var imageURL: String?
    public var chapterID: String?

    public init(startMilliseconds: Int64, title: String? = nil, link: String? = nil, imageURL: String? = nil, chapterID: String? = nil) {
        self.startMilliseconds = startMilliseconds; self.title = title
        self.link = link; self.imageURL = imageURL
        self.chapterID = chapterID
    }
}

import Foundation

/// OPML is a subscription list, not a backup of playback state or folder access.
public enum OPMLExportWriter {
    public enum Failure: Error, Equatable, Sendable {
        case missingTitle
        case missingSource
        case invalidXMLCharacter(UInt32)
        case invalidDate
    }

    /// Call with FeedLibraryStore.feeds(), whose original-title SQL order is the
    /// Android export order. Custom names affect output text, never its order.
    public static func data(for feeds: [LibraryFeed], createdAt: Date, timeZone: TimeZone) throws -> Data {
        try data(for: feeds.map(Outline.init), createdAt: createdAt, timeZone: timeZone)
    }

    /// Separate from import records: export preserves absent versus empty fields
    /// and does not validate/normalize a stored address as a network destination.
    struct Outline: Sendable {
        var title: String?
        var source: String?
        var type: String?
        var link: String?
        var state: FeedSubscriptionState

        init(title: String?, source: String?, type: String?, link: String?, state: FeedSubscriptionState) {
            self.title = title; self.source = source; self.type = type; self.link = link; self.state = state
        }

        init(_ feed: LibraryFeed) {
            title = feed.title
            source = feed.source
            // Stored source type: absent for local folders and for OPML-imported
            // placeholders until a successful parsed refresh supplies rss/atom.
            type = feed.sourceFeedType
            link = feed.metadata.link
            state = feed.subscriptionState
        }
    }

    static func data(for outlines: [Outline], createdAt: Date, timeZone: TimeZone) throws -> Data {
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidDate }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd MMM yy HH:mm:ss Z"
        let date = formatter.string(from: createdAt)
        guard !date.isEmpty else { throw Failure.invalidDate }
        var document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
        document += "<opml version=\"2.0\">\n  <head>\n    <title>NotTennaPod Subscriptions</title>\n"
        document += "    <dateCreated>\(date)</dateCreated>\n  </head>\n  <body>\n"
        for outline in outlines where outline.state == .subscribed {
            guard let title = outline.title else { throw Failure.missingTitle }
            guard let source = outline.source else { throw Failure.missingSource }
            let escapedTitle = try attribute(title)
            document += "    <outline text=\"\(escapedTitle)\" title=\"\(escapedTitle)\""
            if let type = outline.type { document += " type=\"\(try attribute(type))\"" }
            document += " xmlUrl=\"\(try attribute(source))\""
            if let link = outline.link { document += " htmlUrl=\"\(try attribute(link))\"" }
            document += " />\n"
        }
        document += "  </body>\n</opml>"
        return Data(document.utf8)
    }

    private static func attribute(_ value: String) throws -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 9: result += "&#9;"
            case 10: result += "&#10;"
            case 13: result += "&#13;"
            case 34: result += "&quot;"
            case 38: result += "&amp;"
            case 60: result += "&lt;"
            case 62: result += "&gt;"
            case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                result.unicodeScalars.append(scalar)
            default: throw Failure.invalidXMLCharacter(scalar.value)
            }
        }
        return result
    }
}

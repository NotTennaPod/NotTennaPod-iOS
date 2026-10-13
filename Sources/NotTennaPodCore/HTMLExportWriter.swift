import Foundation

/// Source `HtmlWriter` (subscriptions) and `FavoritesWriter` (favorite episodes), with the three
/// asset templates byte-exact (CRLF template lines, LF writer literals, no BOM). Decisions: data values are
/// HTML-escaped and placeholders substituted in one pass (the source's raw injection is not copied); NULL feed or
/// episode values in Favorites become "" instead of the source NullPointerException; the
/// subscriptions export keeps the source's literal `null` for absent values.
public enum HTMLExportWriter {
    /// `storage/importexport/src/main/assets/html-export-template.html` (sha256 7b3d210a…), renamed for NotTennaPod:
    /// NotTennaPod title and heading, teal background, no AntennaPod logo or Play Store link.
    static let template = "<?xml version='1.0' encoding='UTF-8' standalone='no' ?>\r\n<html>\r\n    <head>\r\n        <title>NotTennaPod {TITLE}</title>\r\n        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\r\n        <style>\r\n            * {\r\n                font-family: \"Sarabun\", sans-serif;\r\n                font-weight: 300;\r\n                margin: 0;\r\n                padding: 0;\r\n                box-sizing: border-box;\r\n            }\r\n            html {\r\n                background: #158789;\r\n                background-image: linear-gradient(180deg, #1FA8A6, #0B6670);\r\n                text-align: center;\r\n                padding: 10px;\r\n                min-height: 100%;\r\n            }\r\n            h1 {\r\n                color: #fff;\r\n                font-weight: 300;\r\n                display: inline-block;\r\n                margin-top: 30px;\r\n                margin-bottom: 20px;\r\n                vertical-align: top;\r\n            }\r\n            ul {\r\n                text-align: center;\r\n            }\r\n            li {\r\n                width: 100%;\r\n                max-width: 500px;\r\n                display: block;\r\n                display: inline-flex;\r\n                padding: 10px;\r\n            }\r\n            li > div {\r\n                background: #fefefe;\r\n                padding: 10px;\r\n                display: inline-block;\r\n                width: 100%;\r\n                box-shadow: 0 1px 3px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.24);\r\n                text-align: left;\r\n            }\r\n            li span {\r\n                margin-top: 10px;\r\n                display: block;\r\n            }\r\n            a {\r\n                text-decoration: none;\r\n            }\r\n            a:hover {\r\n                text-decoration: underline;\r\n            }\r\n            span a {\r\n                color: #3498db;\r\n            }\r\n            img {\r\n                width: 100px;\r\n                height: 100px;\r\n                margin-right: 10px;\r\n            }\r\n            li > div > img {\r\n                float: left;\r\n                text-indent: -10000px;\r\n                background: #eee;\r\n            }\r\n            li > div > p {\r\n                width: 100%;\r\n            }\r\n            body > a {\r\n                color: #ffffff;\r\n                display: inline-block;\r\n                margin-top: 10px;\r\n                clear:left;\r\n            }\r\n            ul > li > span {\r\n                width: 100%;\r\n                border-top: 1px solid #eee8e8;\r\n                padding: 5px;\r\n                box-shadow: none;\r\n                text-align: left;\r\n            }\r\n        </style>\r\n    </head>\r\n    <body>\r\n        <h1>NotTennaPod {TITLE}</h1>\r\n        <ul>\r\n            {FEEDS}\r\n        </ul>\r\n    </body>\r\n</html>\r\n"
    /// `html-export-feed-template.html` (sha256 5db9cd73…).
    static let feedTemplate = "<img src=\"{FEED_IMG}\" />\r\n<p>\r\n    {FEED_TITLE}\r\n    <span>\r\n        <a href=\"{FEED_LINK}\">Website</a> • <a href=\"{FEED_WEBSITE}\">Feed</a>\r\n    </span>\r\n</p>"
    /// `html-export-favorites-item-template.html` (sha256 24e8b46a…).
    static let itemTemplate = "<li><span>\r\n    {FAV_TITLE}<br>\r\n    <a href=\"{FAV_WEBSITE}\">Website</a> • <a href=\"{FAV_MEDIA}\">Media</a>\r\n</span></li>\r\n"

    /// `HtmlWriter.writeDocument`: call with `FeedLibraryStore.feeds()` (original-title NOCASE order).
    public static func subscriptions(_ feeds: [LibraryFeed]) -> Data {
        let (head, tail) = parts("Subscriptions")
        var document = head
        for feed in feeds where feed.subscriptionState == .subscribed {
            document += "<li><div><img src=\"" + nullable(feed.metadata.imageURL) + "\" /><p>" + nullable(feed.title)
            document += " <span><a href=\"" + nullable(feed.metadata.link) + "\">Website</a> \u{2022} <a href=\""
            document += escape(feed.source) + "\">Feed</a></span></p></div></li>\n"
        }
        return Data((document + tail).utf8)
    }

    /// `FavoritesWriter.writeDocument`: favorites of subscribed feeds, grouped by ascending feed id,
    /// newest publication date first within a feed (`DATE_NEW_OLD`; the source has no tiebreaker).
    public static func favorites(_ feeds: [LibraryFeed]) -> Data {
        let (head, tail) = parts("Favorites")
        var document = head
        for feed in feeds.filter({ $0.subscriptionState == .subscribed }).sorted(by: { $0.id < $1.id }) {
            let favorites = feed.episodes.filter(\.userState.isFavorite).sorted {
                ($0.details.publicationDate ?? .distantPast, $1.id) > ($1.details.publicationDate ?? .distantPast, $0.id)
            }
            guard !favorites.isEmpty else { continue }
            document += "<li><div>\n" + substitute(feedTemplate, [
                "{FEED_IMG}": feed.metadata.imageURL, "{FEED_TITLE}": feed.title,
                "{FEED_LINK}": feed.metadata.link, "{FEED_WEBSITE}": feed.source]) + "<ul>\n"
            for episode in favorites {
                document += substitute(itemTemplate, ["{FAV_TITLE}": episode.details.title.map(JavaString.trim),
                    "{FAV_WEBSITE}": episode.details.link, "{FAV_MEDIA}": episode.details.media?.url])
            }
            document += "</ul></div></li>\n"
        }
        return Data((document + tail).utf8)
    }

    /// `{TITLE}` replaced everywhere, then the document split at `{FEEDS}`.
    static func parts(_ title: String) -> (String, String) {
        let pieces = template.replacingOccurrences(of: "{TITLE}", with: title).components(separatedBy: "{FEEDS}")
        return (pieces[0], pieces.dropFirst().joined(separator: "{FEEDS}"))
    }

    /// Single-pass placeholder substitution: data is never re-scanned for placeholders.
    static func substitute(_ template: String, _ values: [String: String?]) -> String {
        var result = "", rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            if let close = rest[open...].firstIndex(of: "}"), let value = values[String(rest[open...close])] {
                result += escape(value ?? ""); rest = rest[rest.index(after: close)...]
            } else {
                result += "{"; rest = rest[rest.index(after: open)...]
            }
        }
        return result + rest
    }

    static func nullable(_ value: String?) -> String { value.map(escape) ?? "null" }

    /// Text and attribute values are escaped; strings without these characters are unchanged.
    static func escape(_ value: String) -> String {
        var result = ""
        for character in value.unicodeScalars {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.unicodeScalars.append(character)
            }
        }
        return result
    }

}

import Foundation

// What the online feed page does with a downloaded document (TypeGetter, FeedDiscoverer,
// OnlineFeedViewActivity), plus the Add-podcast inputs (AddFeedFragment, Patterns.WEB_URL).

public struct DiscoveredFeedLink: Equatable, Sendable {
    public var url: String
    /// The link's `title`, or the raw `href` when the title is empty.
    public var label: String
    public init(url: String, label: String) { self.url = url; self.label = label }
}

public enum FeedDiscoverer {
    /// FeedDiscoverer.findLinks: `<link rel="alternate|feed" type="application/rss+xml|atom+xml">`
    /// in `<head>` with a non-empty href, in androidx ArrayMap order (ascending signed
    /// `String.hashCode` of the URL; a repeated URL keeps its place and takes the later label).
    /// Relative links resolve against the requested page per RFC 3986 (the source
    /// replaces the page path instead, which points at the wrong resource).
    public static func findLinks(in html: String, base: String) -> [DiscoveredFeedLink] {
        var entries: [(hash: Int32, link: DiscoveredFeedLink)] = []
        for attributes in HTMLHead.parse(html).links {
            let rel = attributes["rel"] ?? "", href = attributes["href"] ?? "", type = attributes["type"] ?? ""
            guard !href.isEmpty, rel == "alternate" || rel == "feed",
                  type == "application/rss+xml" || type == "application/atom+xml",
                  let url = resolve(href, base: base) else { continue }
            let title = attributes["title"] ?? ""
            let label = title.isEmpty ? href : title
            let hash = JavaString.hashCode(url)
            if let existing = entries.firstIndex(where: { $0.hash == hash && $0.link.url == url }) {
                entries[existing].link.label = label; continue
            }
            let position = entries.firstIndex(where: { $0.hash > hash }) ?? entries.count
            entries.insert((hash, DiscoveredFeedLink(url: url, label: label)), at: position)
        }
        return entries.map(\.link)
    }

    private static let allowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        return set
    }()
    static func resolve(_ href: String, base: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
              let baseURL = URL(string: base), let url = URL(string: encoded, relativeTo: baseURL) else { return nil }
        return url.absoluteString
    }
}

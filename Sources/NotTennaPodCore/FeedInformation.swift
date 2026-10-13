import Foundation
import SwiftSoup

/// FeedInfoFragment's presentation rules. These values do not rewrite publisher
/// metadata in storage; in particular funding selection preserves source order.
public struct FeedInformation: Equatable, Sendable {
    public let description: String
    public let funding: String
    public let showsFunding, showsStatistics, showsSubscribe: Bool
    public let showsShare, showsReconnect, showsEditURL, showsWebsite: Bool

    public init(feed: LibraryFeed, websiteCallable: Bool, supportLabel: String) throws {
        description = try FeedDescriptionText.format(feed.metadata.description)
        funding = Self.fundingText(feed.metadata.funding, supportLabel: supportLabel)
        let subscribed = feed.subscriptionState == .subscribed
        let local = feed.source.isLocalFeedSource
        showsSubscribe = feed.subscriptionState == .notSubscribed
        showsStatistics = !showsSubscribe
        showsFunding = !showsSubscribe && !feed.metadata.funding.isEmpty
        showsShare = subscribed && !local
        showsReconnect = subscribed && local
        showsEditURL = subscribed && !local
        showsWebsite = subscribed && feed.metadata.link != nil && websiteCallable
    }

    public static func fundingText(_ entries: [FeedFunding], supportLabel: String) -> String {
        // UTF-16 keys preserve Java URL equality without Swift's canonical
        // Unicode equivalence. Compute maxima once instead of quadratic scans.
        let values = entries.map { (entry: $0, key: $0.url.map { Array($0.utf16) }, length: $0.content.utf16.count) }
        var longest: [[UInt16]?: Int] = [:]
        for value in values {
            longest[value.key] = max(longest[value.key] ?? 0, value.length)
        }
        let selected = values.filter { $0.length == longest[$0.key] }.map(\.entry)
        // The source retains equal-length alternatives, including exact repeats.
        // Its Java string builder prints null for an absent URL.
        return JavaString.trim(selected.map {
            ($0.content.isEmpty ? supportLabel : $0.content) + " " + ($0.url ?? "null") + "\n"
        }.joined())
    }
}

/// The feed information screen's lightweight HTML-to-text formatter. This is
/// deliberately separate from the episode shownotes WebView transformation.
public enum FeedDescriptionText {
    private static let tag = try! NSRegularExpression(pattern: #"<("[^"]*"|'[^']*'|[^'">])*>"#)

    public static func format(_ raw: String?) throws -> String {
        guard let raw, !raw.isEmpty else { return "" }
        guard tag.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil else { return raw }
        // Markup nested deeper than the HTML parser can recurse is read as its text.
        guard !HTMLNesting.exceeds(raw) else { return JavaString.trim(HTMLNesting.plainText(raw, compact: true)) }
        let document = try SwiftSoup.parse(raw)
        let visitor = Visitor()
        try document.traverse(visitor)
        return JavaString.trim(visitor.output)
    }

    private final class Visitor: NodeVisitor {
        var output = ""
        func head(_ node: Node, _ depth: Int) throws {
            if let text = node as? TextNode { append(normalizeText(text.getWholeText())) }
            else {
                switch node.nodeName() {
                case "li": append("\n * ")
                case "dt": append("  ")
                case "p", "h1", "h2", "h3", "h4", "h5", "tr": append("\n")
                default: break
                }
            }
        }
        func tail(_ node: Node, _ depth: Int) throws {
            switch node.nodeName() {
            case "br", "dd", "dt", "p", "h1", "h2", "h3", "h4", "h5": append("\n")
            case "a": append(" <\(try node.absUrl("href"))>")
            default: break
            }
        }
        private func append(_ value: String) {
            if value == " " && (output.isEmpty || output.hasSuffix(" ") || output.hasSuffix("\n")) { return }
            output += value
        }

        /// Jsoup1.15.1 TextNode.text/StringUtil differs from SwiftSoup's default:
        /// NBSP is collapsible; zero-width space and soft hyphen are omitted.
        private func normalizeText(_ value: String) -> String {
            var result = String.UnicodeScalarView(), lastWasSpace = false
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0x20, 0x09, 0x0A, 0x0C, 0x0D, 0xA0:
                    if !lastWasSpace { result.append(" ") }
                    lastWasSpace = true
                case 0x200B, 0xAD: break
                default: result.append(scalar); lastWasSpace = false
                }
            }
            return String(result)
        }
    }
}

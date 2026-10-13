import Foundation
import SwiftSoup

/// Presentation-only transformation. Never persist this HTML over the feed's description.
public enum ShownotesFormatter {
    public struct Style: Sendable {
        public let foreground, accent: String
        public let padding: Int

        public init(foreground: String, accent: String, padding: Int) {
            self.foreground = foreground; self.accent = accent; self.padding = padding
        }

        public var css: String {
            """
            * { color: \(foreground); overflow-wrap: break-word; }
            a { font-style: normal; font-weight: normal; color: \(accent); }
            a.timecode { color: #669900; }
            img, iframe { display: block; margin: 10 auto; max-width: 100%; height: auto; }
            body { padding: \(padding)px \(padding)px \(padding)px \(padding)px; }
            p#apNoShownotes { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); text-align: center; -webkit-text-size-adjust: none; }
            """
        }
    }

    private static let lineBreak = try! NSRegularExpression(pattern: "<br */?>")
    private static let color = try! NSRegularExpression(pattern: #"(?<=(\s|;|^))color\s*:([^;])*;"#)
    private static let comment = try! NSRegularExpression(pattern: #"/\*.*?\*/"#)
    private static let timecode = try! NSRegularExpression(pattern: #"\b(([0-9]+):)?([0-9]+):([0-9]{2})\b"#)
    private static let timecodeLink = try! NSRegularExpression(pattern: #"^antennapod://timecode/([0-9]+)$"#)
    private static let url = try! NSRegularExpression(pattern:
        #"(?:https?://(?:www\.)?|www\.)[-a-zA-Z0-9@:%._+~#=]{1,256}\.[a-zA-Z]{2,6}\b[-a-zA-Z0-9@:%_+.*~#?!&$/=()\[\],;]*"#,
        options: .caseInsensitive)

    public static func format(_ raw: String?, durationMilliseconds: Int32, noShownotesLabel: String,
                              style: Style) throws -> String {
        var source = raw ?? ""
        if source.isEmpty {
            // Use a text node so localized content cannot become markup.
            let document = try SwiftSoup.parse("")
            document.outputSettings().prettyPrint(pretty: false)
            try document.body()?.appendElement("p").attr("id", "apNoShownotes").text(noShownotesLabel)
            source = try document.outerHtml()
        }
        if matches(lineBreak, source).isEmpty && !source.contains("<p>") {
            source = source.replacingOccurrences(of: "\n", with: "<br />")
        }
        // Markup nested deeper than the HTML parser can recurse is shown as its text.
        if HTMLNesting.exceeds(source) { source = HTMLNesting.plainHTML(source) }
        let document = try SwiftSoup.parse(source)
        for element in try document.getAllElements() {
            if element.hasAttr("style") {
                try element.attr("style", remove(color, from: element.attr("style")))
            } else if element.tagName() == "style" {
                try element.html(cleanStyleTag(element.html()))
            }
        }
        try document.head()?.appendElement("style").attr("type", "text/css").text(style.css)
        guard let body = document.body() else { return try document.outerHtml() }
        try convertLinks(body)
        try addTimecodes(body, duration: durationMilliseconds)
        try body.attr("dir", "auto")
        return try document.outerHtml()
    }

    public static func cleanStyleTag(_ css: String) -> String { remove(color, from: remove(comment, from: css)) }

    /// Supply the Android WebView defaults that differ from WKWebView. Publisher
    /// styles retain priority; non-wide Android viewports ignore publisher width.
    /// `leadingCSS` (the large inlined font) starts the same style element but joins the serialised document
    /// afterwards, so the parser never copies or scans it; the result is the same as passing it first in
    /// `defaultFontCSS`.
    public static func webKitDocument(_ html: String, defaultFontCSS: String, leadingCSS: String = "") throws -> String {
        let document = try SwiftSoup.parse(html)
        try document.select("meta[name=viewport]").remove()
        let marker = leadingCSS.isEmpty ? "" : "/*ap-leading-css*/"
        try document.head()?.prepend("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><style>\(marker)\(defaultFontCSS)</style>")
        let output = try document.outerHtml()
        // The prepended style is the head's first element, so the first marker is ours.
        guard !marker.isEmpty, let range = output.range(of: marker) else { return output }
        return output.replacingCharacters(in: range, with: leadingCSS)
    }

    public static func timecodeMilliseconds(for link: String) -> Int32? {
        guard let match = matches(timecodeLink, link).first,
              match.range.length == (link as NSString).length else { return nil }
        return Int32((link as NSString).substring(with: match.range(at: 1)))
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func remove(_ regex: NSRegularExpression, from text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func textNodes(_ root: Node) -> [TextNode] {
        if let text = root as? TextNode { return [text] }
        return root.getChildNodes().flatMap(textNodes)
    }

    private static func insideAnchor(_ node: Node) -> Bool {
        var current: Node? = node.parent()
        while let parent = current {
            if (parent as? Element)?.tagName() == "a" { return true }
            current = parent.parent()
        }
        return false
    }

    private static func replace(_ node: TextNode, matches: [NSTextCheckingResult],
                                link: (String) -> (href: String, className: String)?) throws {
        let text = node.getWholeText() as NSString
        var end = 0
        for match in matches {
            let value = text.substring(with: match.range)
            guard let target = link(value) else { continue }
            if match.range.location > end {
                try node.before(TextNode(text.substring(with: NSRange(location: end, length: match.range.location - end)), ""))
            }
            let anchor = Element(try Tag.valueOf("a"), "")
            try anchor.attr("href", target.href).text(value)
            if !target.className.isEmpty { try anchor.attr("class", target.className) }
            try node.before(anchor)
            end = NSMaxRange(match.range)
        }
        guard end > 0 else { return }
        if end < text.length { try node.before(TextNode(text.substring(from: end), "")) }
        try node.remove()
    }

    private static func convertLinks(_ body: Element) throws {
        for node in textNodes(body) where !insideAnchor(node) {
            try replace(node, matches: matches(url, node.getWholeText())) { value in
                guard let last = value.last, !".,;:?!)([]-_~#@$*+".contains(last) else { return nil }
                return (value.lowercased().hasPrefix("http") ? value : "https://" + value, "")
            }
        }
    }

    private static func addTimecodes(_ body: Element, duration: Int32) throws {
        // Work on visible text, avoiding the original regex-over-HTML corruption of
        // attributes and existing links. Malformed/overflowing times stay as text.
        let nodes = textNodes(body).filter { !insideAnchor($0) }
        var hours = true
        if duration != .max {
            hours = !nodes.contains { node in
                matches(timecode, node.getWholeText()).contains { match in
                    let text = (node.getWholeText() as NSString).substring(with: match.range)
                    return match.range(at: 1).location == NSNotFound && (milliseconds(text, hours: true) ?? .max) > Int64(duration)
                }
            }
        }
        for node in nodes {
            try replace(node, matches: matches(timecode, node.getWholeText())) { value in
                guard let time = milliseconds(value, hours: hours), time < Int64(duration), time <= Int32.max else { return nil }
                return ("antennapod://timecode/\(time)", "timecode")
            }
        }
    }

    private static func milliseconds(_ text: String, hours: Bool) -> Int64? {
        let parts = text.split(separator: ":")
        let factors: [Int64] = parts.count == 3 ? [3_600_000, 60_000, 1_000] : (hours ? [3_600_000, 60_000] : [60_000, 1_000])
        var total: Int64 = 0
        for (part, factor) in zip(parts, factors) {
            guard let number = Int64(part) else { return nil }
            let (value, multipliedOverflow) = number.multipliedReportingOverflow(by: factor)
            let (sum, addedOverflow) = total.addingReportingOverflow(value)
            guard !multipliedOverflow && !addedOverflow else { return nil }
            total = sum
        }
        return total
    }
}

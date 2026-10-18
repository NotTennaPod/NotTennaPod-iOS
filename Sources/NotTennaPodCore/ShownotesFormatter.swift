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
        try preparedWebKitDocument(html, defaultFontCSS: defaultFontCSS, leadingCSS: leadingCSS).html
    }

    /// The remote subresources show notes can load by themselves, each governed by one Mobile updates option.
    public struct SubresourceClasses: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Pictures, styles and fonts: "Cover images".
        public static let small = SubresourceClasses(rawValue: 1)
        /// Media and embedded documents (frames, objects): "Streaming".
        public static let heavy = SubresourceClasses(rawValue: 2)
        public static let all: SubresourceClasses = [.small, .heavy]
    }

    /// The document WebKit loads, and the classes it may load by itself.
    public struct WebKitDocument: Equatable, Sendable {
        public let html: String
        /// Conservative: a class is present when anything in the document could load it (false positives allowed).
        /// An embedded document counts as both, since its own content is not known.
        public let classes: SubresourceClasses
    }

    /// Hints that make WebKit fetch or connect ahead of use (a prefetched main resource is a `document` load), and the
    /// refresh that replaces the notes. They show nothing, so the whole element goes before WebKit sees it.
    private static let resourceHints: Set<String> = ["prefetch", "preload", "modulepreload", "prerender", "preconnect", "dns-prefetch"]

    /// `webKitDocument`, with the classes it may load. `contentSecurityPolicy` (used when content rules are not
    /// available) becomes the head's first element.
    public static func preparedWebKitDocument(_ html: String, defaultFontCSS: String, leadingCSS: String = "",
                                              contentSecurityPolicy: String? = nil) throws -> WebKitDocument {
        let document = try SwiftSoup.parse(html)
        try document.select("meta[name=viewport]").remove()
        for link in try document.select("link[rel]") {
            let tokens = try link.attr("rel").lowercased().split(whereSeparator: { " \t\n\r\u{0C}".contains($0) })
            if tokens.contains(where: { resourceHints.contains(String($0)) }) { try link.remove() }
        }
        for meta in try document.select("meta[http-equiv]") {
            if try meta.attr("http-equiv").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "refresh" { try meta.remove() }
        }
        let classes = try subresourceClasses(document)
        let marker = leadingCSS.isEmpty ? "" : "/*ap-leading-css*/"
        try document.head()?.prepend("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><style>\(marker)\(defaultFontCSS)</style>")
        if let contentSecurityPolicy {
            try document.head()?.prepend("<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">")
        }
        let output = try document.outerHtml()
        // The prepended style is the head's first style element, so the first marker is ours.
        guard !marker.isEmpty, let range = output.range(of: marker) else { return WebKitDocument(html: output, classes: classes) }
        return WebKitDocument(html: output.replacingCharacters(in: range, with: leadingCSS), classes: classes)
    }

    /// A strict policy allowing only the given classes: the fallback when WebKit's content rules cannot be compiled.
    /// Scripts never run; inline styles and `data:` content (the notes' own font) always work. The document's policy
    /// does not reach into a remote frame, and `object-src` admits pictures whatever `img-src` says, so embedded
    /// documents and objects load only when both classes are allowed.
    public static func contentSecurityPolicy(allowing allowed: SubresourceClasses) -> String {
        let small = allowed.contains(.small), heavy = allowed.contains(.heavy)
        let embedded = small && heavy
        return [
            "default-src 'none'", "script-src 'none'",
            small ? "img-src * data: blob:" : "img-src data: blob:",
            small ? "style-src * 'unsafe-inline' data:" : "style-src 'unsafe-inline' data:",
            small ? "font-src * data:" : "font-src data:",
            small ? "connect-src *" : "connect-src 'none'",
            heavy ? "media-src * data: blob:" : "media-src data: blob:",
            embedded ? "frame-src * data:" : "frame-src 'none'",
            embedded ? "child-src * data:" : "child-src 'none'",
            embedded ? "object-src *" : "object-src 'none'"
        ].joined(separator: "; ")
    }

    private static let heavyElements: Set<String> = ["video", "audio", "source", "track", "iframe", "frame", "object", "embed",
                                                     "applet", "portal", "bgsound"]
    /// Embedded documents: whatever they contain may load either class.
    private static let embeddedDocuments: Set<String> = ["iframe", "frame", "object", "embed", "applet", "portal", "source"]
    private static let resourceAttributes: Set<String> = ["src", "srcset", "data", "poster", "background", "href", "xlink:href",
                                                          "imagesrcset", "lowsrc", "dynsrc", "codebase", "archive"]

    private static func subresourceClasses(_ document: Document) throws -> SubresourceClasses {
        var classes: SubresourceClasses = []
        for element in try document.getAllElements() {
            let tag = element.tagName().lowercased()
            if heavyElements.contains(tag) {
                classes.insert(.heavy)
                if embeddedDocuments.contains(tag) { classes.insert(.small) }
            }
            if tag == "svg" || tag == "math" { classes.insert(.small) }
            if tag == "style", cssMayLoad(element.data()) { classes.insert(.small) }
            for attribute in element.getAttributes()?.asList() ?? [] {
                let key = attribute.getKey().lowercased()
                if key == "style", cssMayLoad(attribute.getValue()) { classes.insert(.small) }
                // Links a person taps are not automatic loads; a media element's own source is Heavy.
                guard resourceAttributes.contains(key), !(key == "href" && ["a", "area", "base"].contains(tag)),
                      !(["video", "audio", "track", "bgsound"].contains(tag) && key != "poster") else { continue }
                classes.insert(.small)
            }
            if classes == .all { break }
        }
        return classes
    }

    /// Whether CSS could load anything: a resource function, an import, or an escape (which could spell either).
    private static func cssMayLoad(_ css: String) -> Bool {
        let compact = css.lowercased().filter { !$0.isWhitespace }
        return ["url(", "image(", "image-set(", "cross-fade(", "element(", "src(", "@import", "\\"].contains { compact.contains($0) }
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

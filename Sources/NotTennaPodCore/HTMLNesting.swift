import Foundation

/// The HTML parser (SwiftSoup) recurses once per nesting level, so markup nested about a
/// thousand levels deep in a feed's text exhausted a 512 KB thread stack and ended the app (a title of
/// 5,000 `<b>` tags crashed it). Android's jsoup traverses without recursion. Markup nested deeper than any
/// real show notes is read as text instead: tags removed, block tags as line breaks, character references
/// decoded.
public enum HTMLNesting {
    /// Far above real show notes, far below the measured failure (between 1,024 and 1,500 levels).
    public static let maximumDepth = 256

    private static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link",
                                                    "meta", "param", "source", "track", "wbr"]
    /// Elements a sibling closes implicitly; they do not deepen the tree.
    private static let siblingClosed: Set<String> = ["p", "li", "dt", "dd", "option", "tr", "td", "th"]
    private static let blocks: Set<String> = ["p", "ul", "li", "div", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"]

    private struct Tag { let name: String; let closing: Bool; let selfClosing: Bool; let end: String.UnicodeScalarView.Index }

    /// The tag starting at `index` (which holds `<`), if it is one.
    private static func tag(in scalars: String.UnicodeScalarView, at index: String.UnicodeScalarView.Index) -> Tag? {
        var cursor = scalars.index(after: index)
        var closing = false
        if cursor < scalars.endIndex, scalars[cursor] == "/" { closing = true; cursor = scalars.index(after: cursor) }
        guard cursor < scalars.endIndex, scalars[cursor].properties.isAlphabetic, scalars[cursor].isASCII else { return nil }
        var name = String.UnicodeScalarView()
        while cursor < scalars.endIndex, scalars[cursor].isASCII,
              scalars[cursor].properties.isAlphabetic || ("0"..."9").contains(scalars[cursor]) {
            name.append(scalars[cursor]); cursor = scalars.index(after: cursor)
        }
        var quote: Unicode.Scalar?
        var previous: Unicode.Scalar = " "
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            if let open = quote { if scalar == open { quote = nil } }
            else if scalar == "\"" || scalar == "'" { quote = scalar }
            else if scalar == ">" { break }
            previous = scalar
            cursor = scalars.index(after: cursor)
        }
        let end = cursor < scalars.endIndex ? scalars.index(after: cursor) : cursor
        return Tag(name: String(name).lowercased(), closing: closing, selfClosing: previous == "/", end: end)
    }

    /// Whether the markup may nest deeper than `limit` (linear; counts unclosed tags, so it errs high).
    public static func exceeds(_ html: String, depth limit: Int = maximumDepth) -> Bool {
        let scalars = html.unicodeScalars
        var depth = 0, index = scalars.startIndex
        while let open = scalars[index...].firstIndex(of: "<") {
            guard let tag = tag(in: scalars, at: open) else { index = scalars.index(after: open); continue }
            if tag.closing { depth = max(0, depth - 1) }
            else if !tag.selfClosing, !voidElements.contains(tag.name), !siblingClosed.contains(tag.name) {
                depth += 1
                if depth > limit { return true }
            }
            index = tag.end
        }
        return false
    }

    /// The text of `html` with block boundaries as the feed parser's HTML-to-text conversion places them.
    public static func plainText(_ html: String, compact: Bool) -> String {
        let scalars = html.unicodeScalars
        var output = String.UnicodeScalarView()
        func boundary() {
            guard !output.isEmpty else { return }
            let existing = output.reversed().prefix(while: { $0 == "\n" }).count
            for _ in 0..<max(0, (compact ? 1 : 2) - existing) { output.append("\n") }
        }
        func append(_ scalar: Unicode.Scalar) {
            if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" {
                if let last = output.last, last != " ", last != "\n" { output.append(" ") }
            } else { output.append(scalar) }
        }
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "<", let tag = tag(in: scalars, at: index) {
                if blocks.contains(tag.name) { boundary() }
                if tag.name == "br" { output.append("\n") }
                if tag.name == "img", !tag.closing { output.append("\u{fffc}") }
                index = tag.end
                continue
            }
            if scalar == "&", let (decoded, next) = reference(in: scalars, at: index) {
                decoded.unicodeScalars.forEach(append)
                index = next
                continue
            }
            append(scalar)
            index = scalars.index(after: index)
        }
        return String(output)
    }

    /// Show notes markup for text read this way: escaped, line breaks kept.
    public static func plainHTML(_ html: String) -> String {
        plainText(html, compact: true).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br />")
    }

    private static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}"]

    private static func reference(in scalars: String.UnicodeScalarView,
                                  at index: String.UnicodeScalarView.Index) -> (String, String.UnicodeScalarView.Index)? {
        var cursor = scalars.index(after: index)
        var name = ""
        while cursor < scalars.endIndex, name.unicodeScalars.count < 12, scalars[cursor] != ";" {
            name.unicodeScalars.append(scalars[cursor]); cursor = scalars.index(after: cursor)
        }
        guard cursor < scalars.endIndex, scalars[cursor] == ";" else { return nil }
        let next = scalars.index(after: cursor)
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            guard let value = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
            return (String(scalar), next)
        }
        if name.hasPrefix("#") {
            guard let value = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(value) else { return nil }
            return (String(scalar), next)
        }
        return named[name].map { ($0, next) }
    }
}

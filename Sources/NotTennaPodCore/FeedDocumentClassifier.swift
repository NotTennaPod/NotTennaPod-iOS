import Foundation

/// TypeGetter's classification of a downloaded document.
public enum FeedDocumentKind: Equatable, Sendable {
    /// `<rss>` (version absent, 2.0, 0.91 or 0.92) or Atom `<feed>`: handed to the feed parser.
    case feed
    /// Not a feed. `root` is "html" for every document with a start tag other than rss/feed
    /// (jsoup always builds an `<html>` root), nil for an unsupported RSS version or a document
    /// without any start tag. `message` is the technical reason shown in the error dialog.
    case unsupported(root: String?, message: String)
}

/// Failures of the online feed page that need the document or a parser message.
public enum FeedDocumentError: Error, Equatable, Sendable {
    case unsupported(root: String?, message: String, body: Data)
    /// A feed root whose document then fails to parse.
    case broken(message: String)
}

public enum FeedDocumentClassifier {
    public static let unknownTypeMessage = "Unknown problem when trying to determine feed type"
    public static let unsupportedVersionMessage = "Unsupported rss version"

    public static func classify(_ data: Data) -> FeedDocumentKind {
        // TypeGetter reads through XmlStreamReader; a document it cannot read makes the pull parser fail,
        // and jsoup (which always builds an <html> root) then classifies it as a website.
        guard let text = try? AndroidXMLStreamDecoding.decode(data) else {
            let html = String(decoding: data, as: UTF8.self)
            if let title = HTMLHead.parse(html).title { return .unsupported(root: "html", message: "Website title: \"\(title)\"") }
            return .unsupported(root: "html", message: "Server returned html")
        }
        guard let tag = firstStartTag(text) else { return .unsupported(root: nil, message: unknownTypeMessage) }
        switch tag.name {
        case "feed": return .feed
        case "rss":
            if tag.version == nil || ["2.0", "0.91", "0.92"].contains(tag.version!) { return .feed }
            return .unsupported(root: nil, message: unsupportedVersionMessage)
        default:
            if let title = HTMLHead.parse(text).title { return .unsupported(root: "html", message: "Website title: \"\(title)\"") }
            return .unsupported(root: "html", message: "Server returned html")
        }
    }

    /// The first start tag the XML pull parser reports: comments, CDATA, the doctype and
    /// processing instructions are skipped, and text outside a root is accepted (kxml).
    static func firstStartTag(_ text: String) -> (name: String, version: String?)? {
        let chars = Array(text.unicodeScalars)
        var index = 0
        func starts(_ literal: String, at position: Int) -> Bool {
            let scalars = Array(literal.unicodeScalars)
            guard position + scalars.count <= chars.count else { return false }
            return chars[position..<position + scalars.count].elementsEqual(scalars)
        }
        func skip(past terminator: String, from position: Int) -> Int {
            var cursor = position
            while cursor < chars.count && !starts(terminator, at: cursor) { cursor += 1 }
            return min(chars.count, cursor + terminator.unicodeScalars.count)
        }
        while index < chars.count {
            guard chars[index] == "<" else { index += 1; continue }
            if starts("<!--", at: index) { index = skip(past: "-->", from: index + 4); continue }
            if starts("<![CDATA[", at: index) { index = skip(past: "]]>", from: index + 9); continue }
            if starts("<!", at: index) { index = skip(past: ">", from: index + 2); continue }
            if starts("<?", at: index) { index = skip(past: "?>", from: index + 2); continue }
            var cursor = index + 1
            func isNameStart(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic && c.isASCII || c == "_" }
            func isName(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || ("0"..."9").contains(c) || ".:-".unicodeScalars.contains(c) }
            guard cursor < chars.count, isNameStart(chars[cursor]) else { index += 1; continue }
            while cursor < chars.count && isName(chars[cursor]) { cursor += 1 }
            let name = String(String.UnicodeScalarView(chars[(index + 1)..<cursor]))
            var end = cursor
            while end < chars.count && chars[end] != ">" { end += 1 }
            let attributes = String(String.UnicodeScalarView(chars[cursor..<end]))
            let local = name.split(separator: ":").last.map(String.init) ?? name
            return (local, versionAttribute(attributes))
        }
        return nil
    }
    private static func versionAttribute(_ attributes: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: "(?:^|\\s)version\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"),
              let match = expression.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: attributes) { return String(attributes[range]) }
        }
        return nil
    }

    /// The technical reason for a feed that fails in the parser (the source shows the SAX message).
    public static func parserMessage(_ error: FeedParsingError) -> String {
        switch error {
        case .malformedXML(let line, let column): "Malformed XML at line \(line), column \(column)."
        case .invalidText: "Invalid text content"
        case .unsupportedRoot(let root): "Server returned \(root)"
        case .unsupportedRSSVersion: unsupportedVersionMessage
        case .unreadableEncoding(let name): name
        case .limitExceeded(let message): message
        }
    }
}

import Foundation

/// The `<link>` elements and `<title>` that jsoup's tree builder places in `<head>`: head content
/// before the body starts, also between `</head>` and `<body>`; never after another start tag
/// or text has started the body. A transcription of the rules of the discovery oracle's head-link collector,
/// which the Java run confirmed on every fixture page. (SwiftSoup differs: it keeps an OPML
/// `<head><title>` in the head, where jsoup 1.15.1 puts it in the body.)
public struct HTMLHead: Equatable, Sendable {
    public var links: [[String: String]] = []
    /// `<title>.text()`: ends trimmed, inner whitespace kept (title preserves whitespace).
    public var title: String?

    private static let headContent: Set<String> = ["base", "basefont", "bgsound", "link", "meta", "title", "style",
                                                   "script", "noscript", "noframes", "template"]
    private static let voids: Set<String> = ["link", "meta", "base", "basefont", "bgsound"]
    private static let rawText: Set<String> = ["title", "style", "script", "noframes"]

    public static func parse(_ html: String) -> HTMLHead {
        var head = HTMLHead()
        let chars = Array(html.unicodeScalars)
        var index = 0, depth = 0, inBody = false
        var text = String.UnicodeScalarView()
        func string(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(chars[range])) }
        func matches(_ literal: String, at position: Int) -> Bool {
            let scalars = Array(literal.unicodeScalars)
            guard position + scalars.count <= chars.count else { return false }
            return string(position..<position + scalars.count).lowercased() == literal
        }
        func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\u{0C}" || c == "\r" }
        func find(_ literal: String, from position: Int) -> Int {
            var cursor = position
            while cursor < chars.count && !matches(literal, at: cursor) { cursor += 1 }
            return cursor
        }
        /// Non-whitespace text outside head content starts the body.
        func flushText() {
            if depth == 0 && !text.allSatisfy(isSpace) { inBody = true }
            text = String.UnicodeScalarView()
        }
        while index < chars.count && !inBody {
            let c = chars[index]
            guard c == "<", index + 1 < chars.count else { text.append(c); index += 1; continue }
            let next = chars[index + 1]
            if matches("<!--", at: index) {
                flushText(); index = min(chars.count, find("-->", from: index + 4) + 3); continue
            }
            if next == "!" || next == "?" {
                flushText(); index = min(chars.count, find(">", from: index + 2) + 1); continue
            }
            let closing = next == "/"
            var cursor = index + (closing ? 2 : 1)
            guard cursor < chars.count, chars[cursor].isASCII, chars[cursor].properties.isAlphabetic else {
                text.append(c); index += 1; continue
            }
            flushText()
            if inBody { break }
            let nameStart = cursor
            while cursor < chars.count && !isSpace(chars[cursor]) && chars[cursor] != "/" && chars[cursor] != ">" { cursor += 1 }
            let name = string(nameStart..<cursor).lowercased()
            var attributes: [String: String] = [:]
            while cursor < chars.count && chars[cursor] != ">" {
                if isSpace(chars[cursor]) || chars[cursor] == "/" { cursor += 1; continue }
                let attributeStart = cursor
                while cursor < chars.count && !isSpace(chars[cursor]) && chars[cursor] != "/" && chars[cursor] != ">"
                        && chars[cursor] != "=" { cursor += 1 }
                if cursor == attributeStart { cursor += 1; continue }
                let attribute = string(attributeStart..<cursor).lowercased()
                while cursor < chars.count && isSpace(chars[cursor]) { cursor += 1 }
                var value = ""
                if cursor < chars.count && chars[cursor] == "=" {
                    cursor += 1
                    while cursor < chars.count && isSpace(chars[cursor]) { cursor += 1 }
                    if cursor < chars.count, chars[cursor] == "\"" || chars[cursor] == "'" {
                        let quote = chars[cursor]
                        let valueStart = cursor + 1
                        cursor = valueStart
                        while cursor < chars.count && chars[cursor] != quote { cursor += 1 }
                        value = string(valueStart..<cursor)
                        cursor = min(chars.count, cursor + 1)
                    } else {
                        let valueStart = cursor
                        while cursor < chars.count && !isSpace(chars[cursor]) && chars[cursor] != ">" { cursor += 1 }
                        value = string(valueStart..<cursor)
                    }
                }
                // The first occurrence of an attribute wins.
                if attributes[attribute] == nil { attributes[attribute] = decodeEntities(value) }
            }
            index = min(chars.count, cursor + 1)
            if closing {
                if headContent.contains(name) && !voids.contains(name) { depth = max(0, depth - 1) }
                continue
            }
            if name == "html" || name == "head" { continue }
            guard headContent.contains(name) else { inBody = true; break }
            if name == "link" { head.links.append(attributes) }
            if voids.contains(name) { continue }
            if rawText.contains(name) {
                let end = find("</" + name, from: index)
                if name == "title" && head.title == nil {
                    head.title = JavaString.trim(decodeEntities(string(index..<end)))
                }
                index = min(chars.count, find(">", from: end) + 1)
                continue
            }
            depth += 1
        }
        return head
    }

    static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        var result = "", rest = Substring(value)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semicolon = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: semicolon) <= 10 {
                let entity = String(after[..<semicolon])
                var decoded: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else { decoded = named[entity] }
                if let decoded { result += decoded; rest = after[after.index(after: semicolon)...]; continue }
            }
            result += "&"; rest = after
        }
        return result + rest
    }
}

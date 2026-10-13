// The server's website.go: what Android reads from an HTML page with jsoup 1.15.1, TypeGetter's website title.
// It looks only at document.head(), so this follows jsoup's tokeniser and tree builder until the body starts. It
// works on bytes, as Go does: a page that failed to decode is read as it came. It asks for cancellation between
// tokens and, as the server's jsoupWork, every 64 KiB of work within one: a tag, a value or a title can be as long as
// the page.

enum ParityWebsite {
    /// TypeGetter.throwExceptionIfWebsite: a title in the head names the website; otherwise the root is always html.
    static func error(_ text: [UInt8], cancellation: ParityCancellation) throws -> ParityParseError {
        if let title = try parseHead(text[...], cancellation: cancellation).title {
            return ParityParseError(label: "unsupported_type_html",
                                    detail: "Website title: \"" + GoStrings.string(title) + "\"")
        }
        return ParityParseError(label: "unsupported_type_html", detail: "Server returned html")
    }

    /// What document.head() holds that Android's TypeGetter reads: the text() of its first title. (Its links are
    /// discovery's, which the parse does not keep: a page of many links would cost many times its size.)
    struct Head {
        var title: [UInt8]?
    }

    // jsoup's tree-construction modes before the body (HtmlTreeBuilderState).
    private static let beforeHead = 0, inHead = 1, inHeadNoscript = 2, afterHead = 3

    private static let space: [UInt8] = Array("\t\n\u{0C}\r ".utf8)

    @inline(__always) private static func isSpace(_ c: UInt8) -> Bool { space.contains(c) }

    /// Follows jsoup's tree builder until the body starts, keeping what it puts in the head: title and link start
    /// tags in the head modes (after the head too, where jsoup moves them into it), a head noscript's links, and
    /// everything inside a template in the head.
    static func parseHead(_ input: ArraySlice<UInt8>, cancellation w: ParityCancellation) throws -> Head {
        let cancellation = w
        var h = Head()
        let s = Array(input.starts(with: [0xEF, 0xBB, 0xBF]) ? input.dropFirst(3) : input)
        var mode = beforeHead
        var templates = 0
        var i = 0
        var n = 0
        while i < s.count {
            if n % 1024 == 0 { try cancellation.check() }
            n += 1
            if s[i] != UInt8(ascii: "<") {
                let j = try ParitySAX.index(of: UInt8(ascii: "<"), in: s[i...], w) ?? s.count
                if templates == 0 && mode != inHeadNoscript {
                    if !(try blank(decode(s[i..<j], allowed: 0, inAttribute: false, w), w)) { return h }  // text starts the body
                }
                i = j
                continue
            }
            let next = i + 1 < s.count ? s[i + 1] : 0
            if i + 1 < s.count && next == UInt8(ascii: "!") {
                i = try skipMarkup(s, i, w)
            } else if i + 1 < s.count && next == UInt8(ascii: "?") {
                i = try skipPast(s, i, Array(">".utf8), w)  // a bogus comment
            } else if i + 1 < s.count && next == UInt8(ascii: "/") {
                if letterAt(s, i + 2) {
                    guard let tag = try readTag(s, i + 2, w) else { return h }
                    i = tag.end
                    let name = tag.name
                    if name == Array("template".utf8) && templates > 0 {
                        templates -= 1
                    } else if templates > 0 {
                    } else if mode == inHeadNoscript {
                        if name == Array("noscript".utf8) { mode = inHead }
                    } else if name == Array("head".utf8) && mode != afterHead {
                        mode = afterHead
                    } else if name == Array("body".utf8) || name == Array("html".utf8) || name == Array("br".utf8) {
                        return h  // anything else: it starts the body
                    }
                } else if i + 2 >= s.count {
                    return h  // "</" at the end is text
                } else if s[i + 2] == UInt8(ascii: ">") {
                    i += 3
                } else {
                    i = try skipPast(s, i, Array(">".utf8), w)  // a bogus comment
                }
            } else if letterAt(s, i + 1) {
                guard let tag = try readTag(s, i + 1, w) else { return h }  // a tag cut off by the end of input emits nothing
                i = tag.end
                if mode == inHeadNoscript && templates == 0 {
                    if tag.name.is("noframes") || tag.name.is("style") { i = try skipRawText(s, i, tag.name, w) }
                    continue  // the head's own elements, or text
                }
                switch tag.name {
                case Array("html".utf8):
                    break
                case Array("head".utf8):
                    if mode == beforeHead { mode = inHead }
                case Array("title".utf8):
                    if h.title == nil {
                        // text(): jsoup preserves a title's whitespace, then trims.
                        h.title = javaTrim(try decode(s[i..<endTag(s, i, tag.name, w)], allowed: 0, inAttribute: false, w))
                    }
                    i = try skipRawText(s, i, tag.name, w)
                    mode = max(mode, inHead)
                case Array("template".utf8):
                    templates += 1
                    mode = max(mode, inHead)
                case Array("link".utf8), Array("base".utf8), Array("basefont".utf8), Array("bgsound".utf8), Array("command".utf8),
                     Array("meta".utf8):
                    mode = max(mode, inHead)
                case Array("noframes".utf8), Array("style".utf8), Array("script".utf8):
                    i = try skipRawText(s, i, tag.name, w)
                    mode = max(mode, inHead)
                case Array("noscript".utf8):
                    if templates > 0 { continue }
                    if mode == afterHead { return h }  // only the head's own noscript; after it, the body starts
                    mode = inHeadNoscript
                default:
                    if templates == 0 { return h }  // body, frameset or any other element starts the body
                }
            } else {
                if templates == 0 && mode != inHeadNoscript { return h }  // a lone "<" is text
                i += 1
            }
        }
        return h
    }

    /// String.trim on a Go string: bytes up to U+0020 at both ends.
    private static func javaTrim(_ s: [UInt8]) -> [UInt8] {
        var i = 0
        var j = s.count
        while i < j && s[i] <= 0x20 { i += 1 }
        while i < j && s[j - 1] <= 0x20 { j -= 1 }
        return Array(s[i..<j])
    }

    /// A tag token: its lower-cased name and the index after it. Its attributes are read past, never kept: nothing
    /// the parse reads is in them (keeping a tag of millions took seconds to release at cancellation).
    struct Tag {
        var name: [UInt8] = []
        var end = 0
    }

    /// Reads a tag from its name on, as jsoup's tokeniser (TagName and the attribute states), passing its attributes;
    /// nil when the input ends inside it. Its steps are counted.
    static func readTag(_ s: [UInt8], _ start: Int, _ w: ParityCancellation) throws -> Tag? {
        var t = Tag()
        var j = start
        while j < s.count && !isSpace(s[j]) && s[j] != UInt8(ascii: "/") && s[j] != UInt8(ascii: ">") && s[j] != UInt8(ascii: "<") {
            try w.tick()
            j += 1
        }
        t.name = GoStrings.toLower(bytes: s[start..<j])
        if j < s.count && s[j] == UInt8(ascii: "<") {
            t.end = j  // jsoup ends the tag at a "<" and rereads it
            return t
        }
        while j < s.count {
            try w.tick()
            let c = s[j]
            if isSpace(c) || c == UInt8(ascii: "/") {
                j += 1
            } else if c == UInt8(ascii: ">") {
                t.end = j + 1
                return t
            } else {
                // An attribute name: up to whitespace, "/", "=" or ">" (a leading quote, "<" or "=" belongs to it).
                var k = j + 1
                while k < s.count && !isSpace(s[k]) && s[k] != UInt8(ascii: "/") && s[k] != UInt8(ascii: "=")
                        && s[k] != UInt8(ascii: ">") {
                    try w.tick()
                    k += 1
                }
                while k < s.count && isSpace(s[k]) {
                    try w.tick()
                    k += 1
                }
                if k >= s.count || s[k] != UInt8(ascii: "=") {
                    j = k  // a name without a value
                    continue
                }
                k += 1
                while k < s.count && isSpace(s[k]) {
                    try w.tick()
                    k += 1
                }
                if k >= s.count { return nil }
                switch s[k] {
                case UInt8(ascii: "\""), UInt8(ascii: "'"):
                    guard let e = try ParitySAX.index(of: s[k], in: s[(k + 1)...], w) else { return nil }
                    j = e + 1
                case UInt8(ascii: ">"):
                    t.end = k + 1  // "=" then ">": an empty value, and the tag ends
                    return t
                default:
                    var e = k
                    while e < s.count && !isSpace(s[e]) && s[e] != UInt8(ascii: ">") {
                        try w.tick()
                        e += 1
                    }
                    j = e
                }
            }
        }
        return nil
    }

    private static func letterAt(_ s: [UInt8], _ i: Int) -> Bool {
        i < s.count && ((s[i] | 0x20) >= 0x61 && (s[i] | 0x20) <= 0x7A)
    }

    /// Skips "<!": a comment, a doctype or a bogus comment.
    private static func skipMarkup(_ s: [UInt8], _ i: Int, _ w: ParityCancellation) throws -> Int {
        let rest = s[(i + 2)...]
        if !rest.starts(with: "--".utf8) { return try skipPast(s, i, Array(">".utf8), w) }
        let body = s[(i + 4)...]
        if body.starts(with: ">".utf8) { return i + 5 }
        if body.starts(with: "->".utf8) { return i + 6 }
        // A comment ends at "--" followed by ">" or "!>", found in one pass.
        var p = body.startIndex
        while true {
            guard let k = try ParitySAX.firstIndex(of: Array("--".utf8), in: s, from: p, w) else { return s.count }
            let q = k + 2
            if q < s.count && s[q] == UInt8(ascii: ">") { return q + 1 }
            if q + 1 < s.count && s[q] == UInt8(ascii: "!") && s[q + 1] == UInt8(ascii: ">") { return q + 2 }
            p = k + 1
        }
    }

    private static func skipPast(_ s: [UInt8], _ i: Int, _ closer: [UInt8], _ w: ParityCancellation) throws -> Int {
        guard let k = try ParitySAX.firstIndex(of: closer, in: s, from: i, w) else { return s.count }
        return k + closer.count
    }

    /// Skips a raw-text or RCDATA element's content and end tag.
    private static func skipRawText(_ s: [UInt8], _ i: Int, _ name: [UInt8], _ w: ParityCancellation) throws -> Int {
        let end = try endTag(s, i, name, w)
        if end == s.count { return end }
        return try readTag(s, end + 2, w)?.end ?? s.count
    }

    /// The element's appropriate end tag: "</name" (ASCII letters in any case) then whitespace, "/" or ">".
    private static func endTag(_ s: [UInt8], _ start: Int, _ name: [UInt8], _ w: ParityCancellation) throws -> Int {
        var i = start
        while true {
            guard let k = try ParitySAX.firstIndex(of: Array("</".utf8), in: s, from: i, w) else { return s.count }
            let j = k + 2
            if j + name.count <= s.count && asciiEqualFold(s[j..<(j + name.count)], name[...])
                && (j + name.count == s.count || isSpace(s[j + name.count]) || s[j + name.count] == UInt8(ascii: "/")
                    || s[j + name.count] == UInt8(ascii: ">")) {
                return k
            }
            i = j
        }
    }

    /// Compares ASCII case-insensitively; other bytes must match.
    private static func asciiEqualFold(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            let lx = x >= 0x41 && x <= 0x5A ? x + 0x20 : x
            let ly = y >= 0x41 && y <= 0x5A ? y + 0x20 : y
            if lx != ly { return false }
        }
        return true
    }

    /// StringUtil.isBlank: only HTML whitespace. Its steps are counted.
    private static func blank(_ s: [UInt8], _ w: ParityCancellation) throws -> Bool {
        for c in s {
            try w.tick()
            if !isSpace(c) { return false }
        }
        return true
    }

    /// Tokeniser.win1252Extensions: numeric references 0x80–0x9F.
    private static let win1252: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D,
        0x017D, 0x008F, 0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
        0x0153, 0x009D, 0x017E, 0x0178
    ]

    /// Decodes character references as jsoup's tokeniser does (Tokeniser.consumeCharacterReference). In an
    /// attribute value, allowed is its closing quote (or ">" when unquoted), which is never a reference; a null
    /// becomes U+FFFD outside text. Its steps are counted.
    static func decode(_ s: ArraySlice<UInt8>, allowed: UInt8, inAttribute: Bool, _ w: ParityCancellation) throws -> [UInt8] {
        var plain = true
        for c in s {
            try w.tick()
            if c == UInt8(ascii: "&") || c == 0 {
                plain = false
                break
            }
        }
        if plain { return Array(s) }
        var b: [UInt8] = []
        b.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            try w.tick()
            let c = s[i]
            if c == 0 {
                GoStrings.appendRune(&b, 0xFFFD)
                i += 1
            } else if c != UInt8(ascii: "&") {
                b.append(c)
                i += 1
            } else {
                let rest = s[(i + 1)...]
                if let first = rest.first, allowed != 0, first == allowed {
                    b.append(c)
                    i += 1
                    continue
                }
                guard let (decoded, n) = try reference(rest, inAttribute: inAttribute, w) else {
                    b.append(c)
                    i += 1
                    continue
                }
                b.append(contentsOf: decoded)
                i += 1 + n
            }
        }
        return b
    }

    /// Decodes the reference after an "&": its text and how many bytes it consumed; nil when the "&" is literal.
    private static func reference(_ s: ArraySlice<UInt8>, inAttribute: Bool, _ w: ParityCancellation) throws -> ([UInt8], Int)? {
        guard let first = s.first, !isSpace(first), first != UInt8(ascii: "<"), first != UInt8(ascii: "&") else { return nil }
        let start = s.startIndex
        if first == UInt8(ascii: "#") {
            var j = start + 1
            var hex = false
            if j < s.endIndex && (s[j] == UInt8(ascii: "x") || s[j] == UInt8(ascii: "X")) {
                j = start + 2
                hex = true
            }
            var k = j
            while k < s.endIndex && (s[k] >= 0x30 && s[k] <= 0x39 || hex && ((s[k] | 0x20) >= 0x61 && (s[k] | 0x20) <= 0x66)) {
                try w.tick()
                k += 1
            }
            if k == j { return nil }
            // strconv.ParseInt(…, 32): nil beyond the int32 range.
            var v: Int64? = 0
            for c in s[j..<k] {
                let d = Int64(c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x61 + 10)
                if let current = v { v = current * (hex ? 16 : 10) + d }
                if let current = v, current > Int64(Int32.max) { v = nil }
            }
            if k < s.endIndex && s[k] == UInt8(ascii: ";") { k += 1 }
            var out: [UInt8] = []
            guard var value = v, !(value >= 0xD800 && value <= 0xDFFF), value <= 0x10FFFF else {
                GoStrings.appendRune(&out, 0xFFFD)
                return (out, k - start)
            }
            if value >= 0x80 && value < 0x80 + Int64(win1252.count) { value = Int64(win1252[Int(value - 0x80)]) }
            GoStrings.appendRune(&out, UInt32(value))
            return (out, k - start)
        }
        // A letter-then-digit sequence names it: a base entity with or without the semicolon, any other entity only
        // with it.
        var k = start
        while k < s.endIndex {
            try w.tick()
            let (r, n) = GoStrings.decodeRune(s, k)
            if r > 0xFFFF || (r == 0xFFFD && n == 1) || !GoUnicode.isLetter(r) { break }  // Character.isLetter(char)
            k += n
        }
        while k < s.endIndex && s[k] >= 0x30 && s[k] <= 0x39 {
            try w.tick()
            k += 1
        }
        let name = Array(s[start..<k])
        let semicolon = k < s.endIndex && s[k] == UInt8(ascii: ";")
        if name.isEmpty { return nil }
        guard let value = entity(name, semicolon: semicolon) else { return nil }
        if inAttribute && !semicolon && k < s.endIndex && "=-_".utf8.contains(s[k]) { return nil }
        if semicolon { k += 1 }
        return (value, k - start)
    }

    /// The HTML5 entity table (Go's html package has the same one): with the semicolon any entity, without it only
    /// the legacy (jsoup "base") entities. A name longer than every entry is none, and is not hashed (the server's
    /// jsoupLongestEntity).
    static func entity(_ name: [UInt8], semicolon: Bool, guarded: Bool = true) -> [UInt8]? {
        if guarded && name.count > longestEntity { return nil }
        if let r = singleEntities[name] {
            var out: [UInt8] = []
            GoStrings.appendRune(&out, r)
            return out
        }
        if !semicolon { return nil }
        let key = name + [UInt8(ascii: ";")]
        var out: [UInt8] = []
        if let r = singleEntities[key] {
            GoStrings.appendRune(&out, r)
            return out
        }
        if let (a, b) = doubleEntities[key] {
            GoStrings.appendRune(&out, a)
            GoStrings.appendRune(&out, b)
            return out
        }
        return nil
    }

    /// The longest entry of the entity table, its semicolon included.
    static let longestEntity = (singleEntities.keys.map(\.count) + doubleEntities.keys.map(\.count)).max() ?? 0

    private static let singleEntities: [[UInt8]: UInt32] = {
        var out: [[UInt8]: UInt32] = [:]
        for pair in ParityHTMLEntityTables.single.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let parts = pair.split(separator: "=")
            out[Array(parts[0].utf8)] = UInt32(parts[1], radix: 16)!
        }
        return out
    }()

    private static let doubleEntities: [[UInt8]: (UInt32, UInt32)] = {
        var out: [[UInt8]: (UInt32, UInt32)] = [:]
        for pair in ParityHTMLEntityTables.double.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let parts = pair.split(separator: "=")
            let values = parts[1].split(separator: ",")
            out[Array(parts[0].utf8)] = (UInt32(values[0], radix: 16)!, UInt32(values[1], radix: 16)!)
        }
        return out
    }()
}

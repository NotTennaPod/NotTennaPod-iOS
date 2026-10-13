// The server's htmltext.go and tagsoup_*.go: HtmlCompat.fromHtml(s, FROM_HTML_MODE_COMPACT or _LEGACY).toString()
// on Android 16, which is TagSoup's parser (platform/external/tagsoup) feeding Html's HtmlToSpannedConverter, of
// which only the text is kept. The work is on UTF-16 code units, as in Java; an unpaired surrogate in the result
// becomes U+FFFD, as in the server. Where fromHtml throws (StringIndexOutOfBoundsException), the feed's parse
// fails as Android's does. Some inputs take TagSoup quadratic time, and one tag or text can be as long as the
// description, so the conversion asks for cancellation as it reads, walks the stack, and passes over a token (its
// name, value, reference or text).

enum ParityHTMLText {
    /// The text of an HTML fragment.
    static func text(_ s: String, compact: Bool, cancellation: ParityCancellation) throws -> String {
        let converter = HTMLConverter(margin: compact ? 1 : 2, cancellation: cancellation)
        let parser = TagSoupParser(converter: converter, cancellation: cancellation)
        var source: [UInt16] = []
        source.reserveCapacity(s.utf8.count)
        for unit in s.utf16 {
            try cancellation.tick()
            source.append(unit)
        }
        try parser.parse(source)
        return String(decoding: converter.text, as: UTF16.self)
    }
}

// MARK: - Java's Character and String on UTF-16 code units (tagsoup_java.go)

enum TagSoupJava {
    @inline(__always) static func isSurrogate(_ c: UInt16) -> Bool { c >= 0xD800 && c <= 0xDFFF }

    /// Character.isLetter(char).
    static func isLetter(_ c: UInt16) -> Bool { !isSurrogate(c) && GoUnicode.isLetter(UInt32(c)) }

    /// Character.isDigit(char): general category Nd.
    static func isDigit(_ c: UInt16) -> Bool { !isSurrogate(c) && GoUnicode.isDigit(UInt32(c)) }

    /// Character.isWhitespace(char).
    static func isWhitespace(_ c: UInt16) -> Bool {
        if c >= 0x09 && c <= 0x0D || c >= 0x1C && c <= 0x20 { return true }
        if c < 0x80 || c == 0xA0 || c == 0x2007 || c == 0x202F || isSurrogate(c) { return false }
        return GoUnicode.is(ParityUnicodeTables.z, UInt32(c))
    }

    /// Character.toLowerCase(char), the simple mapping.
    static func toLower(_ c: UInt16) -> UInt16 {
        if isSurrogate(c) { return c }
        let l = GoUnicode.toLower(UInt32(c))
        return l <= 0xFFFF ? UInt16(l) : c
    }

    /// Character.toUpperCase(char), the simple mapping.
    static func toUpper(_ c: UInt16) -> UInt16 {
        if isSurrogate(c) { return c }
        let u = GoUnicode.toUpper(UInt32(c))
        return u <= 0xFFFF ? UInt16(u) : c
    }

    /// Character.digit(char, radix), or -1.
    static func digit(_ c: UInt16, _ radix: Int) -> Int {
        var d = -1
        switch c {
        case 0x30...0x39: d = Int(c - 0x30)
        case 0x61...0x7A: d = Int(c - 0x61) + 10
        case 0x41...0x5A: d = Int(c - 0x41) + 10
        case 0xFF21...0xFF3A: d = Int(c - 0xFF21) + 10  // fullwidth A-Z
        case 0xFF41...0xFF5A: d = Int(c - 0xFF41) + 10  // fullwidth a-z
        default:
            // Nd characters come in runs of ten, 0 to 9, from the start of each range of the table.
            if isDigit(c) { d = GoUnicode.digitValue(UInt32(c)) }
        }
        return d >= radix ? -1 : d
    }

    /// Integer.parseInt(s, radix); nil where Java throws NumberFormatException. Its steps are counted.
    static func parseInt(_ s: ArraySlice<UInt16>, _ radix: Int, _ work: ParityCancellation? = nil) throws -> Int32? {
        guard let first = s.first else { return nil }
        var i = s.startIndex
        var negative = false
        var limit = -Int64(Int32.max)
        if first < 0x30 {
            switch first {
            case UInt16(ascii: "-"):
                negative = true
                limit = Int64(Int32.min)
            case UInt16(ascii: "+"):
                break
            default:
                return nil
            }
            if s.count == 1 { return nil }
            i += 1
        }
        let multmin = limit / Int64(radix)
        var result: Int64 = 0
        while i < s.endIndex {
            try work?.tick()
            let d = digit(s[i], radix)
            if d < 0 || result < multmin { return nil }
            result *= Int64(radix)
            if result < limit + Int64(d) { return nil }
            result -= Int64(d)
            i += 1
        }
        return Int32(truncatingIfNeeded: negative ? result : -result)
    }

    /// Code points of UTF-16 text; an unpaired surrogate is U+FFFD (a Go string holds none). Its steps are counted.
    static func codePoints(_ s: [UInt16], _ work: ParityCancellation? = nil) throws -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            try work?.tick()
            let c = UInt32(s[i])
            if c >= 0xD800 && c < 0xDC00, i + 1 < s.count, s[i + 1] >= 0xDC00 && s[i + 1] < 0xE000 {
                out.append(0x10000 + (c - 0xD800) << 10 + (UInt32(s[i + 1]) - 0xDC00))
                i += 2
            } else {
                out.append(c >= 0xD800 && c < 0xE000 ? 0xFFFD : c)
                i += 1
            }
        }
        return out
    }

    static func utf16(_ codePoints: [UInt32], _ work: ParityCancellation? = nil) throws -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(codePoints.count)
        for r in codePoints {
            try work?.tick()
            if r >= 0x10000 {
                out.append(UInt16(0xD800 + (r - 0x10000) >> 10))
                out.append(UInt16(0xDC00 + (r - 0x10000) & 0x3FF))
            } else {
                out.append(UInt16(r))
            }
        }
        return out
    }

    /// String.toLowerCase(Locale.ROOT) as Android's libcore CaseMapper does it: the simple mapping, U+0130 to "i̇",
    /// and a final sigma between a cased letter and a non-cased one. Its steps are counted.
    static func lowerRoot(_ s: [UInt16], _ work: ParityCancellation? = nil) throws -> [UInt16] {
        var ascii = true
        for c in s {
            try work?.tick()
            if c >= 0x80 {
                ascii = false
                break
            }
        }
        if ascii {
            var out: [UInt16] = []
            out.reserveCapacity(s.count)
            for c in s {
                try work?.tick()
                out.append(c >= 0x41 && c <= 0x5A ? c + 0x20 : c)
            }
            return out
        }
        let rs = try codePoints(s, work)
        func cased(_ r: UInt32) -> Bool {
            GoUnicode.isUpper(r) || GoUnicode.isLower(r) || GoUnicode.isTitle(r)
                || GoUnicode.is(ParityUnicodeTables.otherLowercase, r) || GoUnicode.is(ParityUnicodeTables.otherUppercase, r)
        }
        var out: [UInt32] = []
        for (i, r) in rs.enumerated() {
            try work?.tick()
            if r == 0x130 {
                out.append(0x69)
                out.append(0x307)
            } else if r == 0x3A3 && i > 0 && cased(rs[i - 1]) && (i + 1 == rs.count || !cased(rs[i + 1])) {
                out.append(0x3C2)
            } else {
                out.append(GoUnicode.toLower(r))
            }
        }
        return try utf16(out, work)
    }

    /// String.equalsIgnoreCase(s, t) for an ASCII t: per code unit, equal upper cases or equal lower cases of the
    /// upper cases.
    static func equalsIgnoreCase(_ s: some Collection<UInt16>, _ t: String) -> Bool {
        guard s.count == t.utf8.count else { return false }
        for (c, b) in zip(s, t.utf8) {
            let d = UInt16(b)
            if c == d { continue }
            let u1 = toUpper(c)
            let u2 = toUpper(d)
            if u1 != u2 && toLower(u1) != toLower(u2) { return false }
        }
        return true
    }
}

// MARK: - Html's converter (htmltext.go)

/// What Html's converter does with an element, by its local name.
enum HTMLTag {
    case other, block, br, img, font

    /// handleStartTag's and handleEndTag's choice by local name, with String.equalsIgnoreCase.
    init(localName tag: [UInt16]) {
        if tag.count == 2 && TagSoupJava.toLower(tag[0]) == UInt16(ascii: "h") && tag[1] >= 0x31 && tag[1] <= 0x36 {
            self = .block
            return
        }
        for (name, kind) in [("br", HTMLTag.br), ("p", .block), ("ul", .block), ("li", .block), ("div", .block),
                             ("blockquote", .block), ("font", .font), ("img", .img)]
        where TagSoupJava.equalsIgnoreCase(tag, name) {
            self = kind
            return
        }
        self = .other
    }
}

/// The text side of Html's HtmlToSpannedConverter, a ContentHandler of the TagSoup parser. Spans do not change the
/// text and are left out.
final class HTMLConverter {
    /// getMargin: the newlines around a block element, 1 for every block element with FROM_HTML_MODE_COMPACT (all
    /// six separator flags), 2 with FROM_HTML_MODE_LEGACY.
    let margin: Int
    /// The SpannableStringBuilder.
    var text: [UInt16] = []
    /// The parse's cancellation, asked as text is added.
    private let cancellation: ParityCancellation?
    init(margin: Int, cancellation: ParityCancellation? = nil) {
        self.margin = margin
        self.cancellation = cancellation
    }

    /// handleStartTag: a block element starts on a new line, an image is U+FFFC, a font checks its color (whether
    /// the element's color attribute is "-").
    func startElement(_ html: HTMLTag, colorIsDash: Bool) throws {
        switch html {
        case .block: appendNewlines(margin)
        case .font: if colorIsDash { throw ParityParseError.parserException }
        case .img: text.append(0xFFFC)
        default: break
        }
    }

    /// handleEndTag: <br> is a newline and a block element ends with its newlines. The Newline mark it reads is
    /// the latest one, from the innermost open block element: TagSoup closes every element it opens, in order,
    /// and all block margins are equal.
    func endElement(_ html: HTMLTag) {
        switch html {
        case .br: text.append(0x0A)
        case .block: appendNewlines(margin)
        default: break
        }
    }

    /// Html's appendNewlines: at least min newlines at the end of text that is not empty. Html counts all the
    /// newlines at the end; counting up to min decides the same, in linear time for many blocks after many breaks.
    func appendNewlines(_ min: Int) {
        if text.isEmpty { return }
        var n = 0
        var i = text.count - 1
        while i >= 0 && text[i] == 0x0A && n < min {
            n += 1
            i -= 1
        }
        while n < min {
            text.append(0x0A)
            n += 1
        }
    }

    /// HtmlToSpannedConverter.characters: a space or newline after a space or newline, or at the start, is
    /// dropped; any other is a space.
    func characters(_ buf: some Collection<UInt16>) throws {
        for ch in buf {
            try cancellation?.tick()
            if ch == 0x20 || ch == 0x0A {
                let pred = text.last ?? 0x0A
                if pred != 0x20 && pred != 0x0A { text.append(0x20) }
            } else {
                text.append(ch)
            }
        }
    }

}

// MARK: - TagSoup's schema and elements (tagsoup_parser.go)

/// An element type, by number: HTMLSchema's types (TagSoupSchema), then the unknown elements a parse defines
/// (TagSoupBogons), numbered after them.
typealias TagSoupType = Int32

/// HTMLSchema's element types and entities.
enum TagSoupSchema {
    static let anyModel: UInt32 = 0xFFFF_FFFF
    static let emptyModel: UInt32 = 0
    static let restart = 1
    static let cdata = 2
    static let noforce = 4

    /// ElementType: a name, its content model, the models it belongs to, its flags and its parent's type.
    struct Entry {
        let name: [UInt16]
        let model: UInt32
        let memberOf: UInt32
        let flags: Int
        var parent: TagSoupType
        /// What Html's converter does with the local name.
        let html: HTMLTag
    }

    static let entries: [Entry] = {
        var entries = ParityTagSoupTables.elements.map { name, model, memberOf, flags, _ in
            Entry(name: Array(name.utf16), model: model, memberOf: memberOf, flags: flags, parent: -1,
                  html: HTMLTag(localName: localName(Array(name.utf16))))
        }
        var byName: [String: Int] = [:]
        for (i, element) in ParityTagSoupTables.elements.enumerated() { byName[element.0] = i }
        for (i, element) in ParityTagSoupTables.elements.enumerated() where !element.4.isEmpty {
            entries[i].parent = TagSoupType(byName[element.4]!)
        }
        return entries
    }()

    /// The types by lower-case name.
    static let byName: [[UInt16]: TagSoupType] = Dictionary(
        entries.enumerated().map { ($0.element.name, TagSoupType($0.offset)) }, uniquingKeysWith: { a, _ in a })

    /// The longest type name: a longer name is no type of the schema, and is not hashed.
    static let longestName = entries.map(\.name.count).max() ?? 0

    static let count = TagSoupType(entries.count)

    /// The local name: after the first colon.
    static func localName(_ name: [UInt16]) -> [UInt16] {
        guard let colon = name.firstIndex(of: UInt16(ascii: ":")) else { return name }
        return Array(name[(colon + 1)...])
    }

    /// The longest name in entities.
    static let longestEntity = entities.keys.map(\.count).max() ?? 0

    /// HTMLSchema's entities: name to code point.
    static let entities: [[UInt16]: Int32] = {
        var out: [[UInt16]: Int32] = [:]
        for pair in ParityTagSoupTables.entities.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let parts = pair.split(separator: "=")
            out[Array(parts[0].utf16)] = Int32(parts[1], radix: 16)!
        }
        return out
    }()
}

/// The unknown elements a parse defines, each with an ANY content model, allowed anywhere (Android keeps them in
/// its shared schema, with the same model, so later parses see the same). Their names, lower-case keys and HTML kinds
/// are kept one after another, with an open-addressing index of the keys, so that a parse that defines millions
/// releases a few arrays, not millions of objects. Keys are hashed in counted steps; equal keys are compared byte for
/// byte.
struct TagSoupBogons {
    private var names: [UInt16] = []
    private var nameEnds: [Int] = []
    private var keys: [UInt16] = []
    private var keyEnds: [Int] = []
    private var hashes: [Int] = []
    private var slots = [Int32](repeating: -1, count: 16)
    private(set) var html: [HTMLTag] = []

    var count: Int { nameEnds.count }

    func name(_ i: Int) -> ArraySlice<UInt16> { names[(i == 0 ? 0 : nameEnds[i - 1])..<nameEnds[i]] }

    private func key(_ i: Int) -> ArraySlice<UInt16> { keys[(i == 0 ? 0 : keyEnds[i - 1])..<keyEnds[i]] }

    /// A key's hash, its bytes fed in steps of the cancellation interval, each counted.
    static func hash(_ key: [UInt16], _ work: ParityCancellation) throws -> Int {
        var hasher = Hasher()
        try key.withUnsafeBytes { raw in
            var start = 0
            repeat {
                let end = min(raw.count, start + ParityCancellation.interval)
                try work.tick(end - start)
                hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw[start..<end]))
                start = end
            } while start < raw.count
        }
        return hasher.finalize()
    }

    /// The unknown element with this key.
    func find(_ key: [UInt16], hash: Int) -> Int? {
        let mask = slots.count - 1
        var i = hash & mask
        while slots[i] >= 0 {
            let candidate = Int(slots[i])
            if hashes[candidate] == hash && self.key(candidate).elementsEqual(key) { return candidate }
            i = (i + 1) & mask
        }
        return nil
    }

    /// Defines an unknown element by its name and key (no element has the key). Growing the index places every key
    /// again, a pass as long as the table: its steps are counted.
    mutating func define(name: [UInt16], key: [UInt16], hash: Int, _ work: ParityCancellation) throws -> Int {
        let id = count
        names.append(contentsOf: name)
        nameEnds.append(names.count)
        keys.append(contentsOf: key)
        keyEnds.append(keys.count)
        hashes.append(hash)
        html.append(HTMLTag(localName: TagSoupSchema.localName(name)))
        if 2 * count > slots.count {
            slots = [Int32](repeating: -1, count: 2 * slots.count)
            for j in 0..<count {
                try work.tick()
                place(j)
            }
        } else {
            place(id)
        }
        return id
    }

    private mutating func place(_ id: Int) {
        let mask = slots.count - 1
        var i = hashes[id] & mask
        while slots[i] >= 0 { i = (i + 1) & mask }
        slots[i] = Int32(id)
    }
}

// MARK: - TagSoup's Parser (tagsoup_parser.go)

/// Parser, reporting elements and text to Html's converter, with the features Html.fromHtml leaves at their
/// defaults. Unknown elements are defined for this parse only: Android keeps them in its shared schema, with the
/// same content model, so later parses see the same. Elements live in one array, numbered, with a list of the free
/// ones: the stack and the restart queue are chains of numbers, released with the array, not one object at a time.
final class TagSoupParser {
    /// Element: an element on the stack, on the restart queue, or being started, with what the stack walks read of
    /// its type for every element they pass (its content model, the models it belongs to, its flags, Html's kind).
    /// Of its attributes Html's converter reads only the color, and only whether it is "-": that is all an element
    /// keeps.
    private struct Element {
        var type: TagSoupType
        var next: Int32
        var model: UInt32
        var memberOf: UInt32
        var flags: UInt8
        var html: HTMLTag
        var preclosed = false
        var colorIsDash = false
    }

    private let converter: HTMLConverter
    let cancellation: ParityCancellation
    private var scanner = TagSoupScanner(source: [])
    private var bogons = TagSoupBogons()
    // The stack's state is read and written for every element a walk passes. The parser runs on one thread and
    // holds no access to these across a call that touches them, so their accesses are not checked at run time: the
    // checks took a third of a stack walk's time.
    @exclusivity(unchecked) private var elements: [Element] = []
    @exclusivity(unchecked) private var freeElements: [Int32] = []
    /// The element being started (no element when negative), never on the stack or the restart queue.
    @exclusivity(unchecked) private var newElement: Int32 = -1
    private var attributeName: [UInt16]?
    @exclusivity(unchecked) private var stack: Int32 = -1
    @exclusivity(unchecked) private var saved: Int32 = -1
    @exclusivity(unchecked) private var pcdataElement: Int32 = -1
    @exclusivity(unchecked) private var virginStack = true
    private var doctypeIsPresent = false
    private static let rootType = TagSoupSchema.byName[Array("<root>".utf16)]!
    private static let pcdataType = TagSoupSchema.byName[Array("<pcdata>".utf16)]!
    private static let color = Array("color".utf16)
    private static let dash = [UInt16(ascii: "-")]
    /// Stack steps since cancellation was last checked.
    @exclusivity(unchecked) private var work = 0
    /// How many stack steps (an element passed over in a walk down the stack, popped or pushed) the parser takes
    /// between cancellation checks: some inputs make TagSoup walk a deep stack for every tag, quadratic time on
    /// Android too, and the scanner's own check counts only characters.
    static let checkWork = 1 << 16

    private func step() throws {
        work += 1
        if work < Self.checkWork { return }
        work = 0
        try cancellation.check()
    }

    init(converter: HTMLConverter, cancellation: ParityCancellation) {
        self.converter = converter
        self.cancellation = cancellation
    }

    // MARK: Types and elements

    private func model(_ t: TagSoupType) -> UInt32 { t < TagSoupSchema.count ? TagSoupSchema.entries[Int(t)].model : TagSoupSchema.anyModel }
    private func memberOf(_ t: TagSoupType) -> UInt32 {
        t < TagSoupSchema.count ? TagSoupSchema.entries[Int(t)].memberOf : TagSoupSchema.anyModel
    }
    private func flags(_ t: TagSoupType) -> Int { t < TagSoupSchema.count ? TagSoupSchema.entries[Int(t)].flags : 0 }
    private func parent(_ t: TagSoupType) -> TagSoupType { t < TagSoupSchema.count ? TagSoupSchema.entries[Int(t)].parent : -1 }
    private func html(_ t: TagSoupType) -> HTMLTag {
        t < TagSoupSchema.count ? TagSoupSchema.entries[Int(t)].html : bogons.html[Int(t - TagSoupSchema.count)]
    }
    private func name(_ t: TagSoupType) -> ArraySlice<UInt16> {
        t < TagSoupSchema.count ? TagSoupSchema.entries[Int(t)].name[...] : bogons.name(Int(t - TagSoupSchema.count))
    }

    /// ElementType.canContain for elements.
    private func canContain(_ a: Int32, _ b: Int32) -> Bool {
        elements[Int(a)].model & elements[Int(b)].memberOf != 0
    }

    private func makeElement(_ type: TagSoupType, next: Int32 = -1) -> Int32 {
        let element = Element(type: type, next: next, model: model(type), memberOf: memberOf(type), flags: UInt8(flags(type)),
                              html: html(type))
        if let slot = freeElements.popLast() {
            elements[Int(slot)] = element
            return slot
        }
        elements.append(element)
        return Int32(elements.count - 1)
    }

    private func release(_ e: Int32) { freeElements.append(e) }

    /// Clears the element being started, which nothing else holds.
    private func dropNewElement() {
        if newElement >= 0 { release(newElement) }
        newElement = -1
    }

    /// Parser.parse.
    func parse(_ source: [UInt16]) throws {
        stack = makeElement(Self.rootType)
        pcdataElement = makeElement(Self.pcdataType)
        virginStack = true
        scanner = TagSoupScanner(source: source)
        try scanner.scan(self)
    }

    /// Schema.getElementType, by the name's lower-case key (which the lower-casing, as long as the text, counts):
    /// HTMLSchema's types, then this parse's unknown elements.
    private func elementType(key: [UInt16], hash: inout Int?) throws -> TagSoupType? {
        if key.count <= TagSoupSchema.longestName, let t = TagSoupSchema.byName[key] { return t }
        let h = try TagSoupBogons.hash(key, cancellation)
        hash = h
        return bogons.find(key, hash: h).map { TagSoupSchema.count + TagSoupType($0) }
    }

    private func elementType(_ name: [UInt16]) throws -> TagSoupType? {
        var hash: Int?
        return try elementType(key: TagSoupJava.lowerRoot(name, cancellation), hash: &hash)
    }

    /// ElementType.setAttribute for the element being started, of which only the color is kept: namespace
    /// declarations are ignored, a repeated name replaces the value.
    private func setAttribute(_ name: [UInt16], _ value: () throws -> [UInt16]) rethrows {
        guard name == Self.color else { return }
        elements[Int(newElement)].colorIsDash = try value() == Self.dash
    }

    /// Parser.adup: an attribute without a value takes its name.
    func adup() {
        guard newElement >= 0, let name = attributeName else { return }
        setAttribute(name) { name }
        attributeName = nil
    }

    /// Parser.aname.
    func aname(_ buf: [UInt16]) throws {
        guard newElement >= 0 else { return }
        attributeName = try TagSoupJava.lowerRoot(Self.makeName(buf, cancellation), cancellation)
    }

    /// Parser.aval. Only the color's value is expanded: nothing reads the others.
    func aval(_ buf: [UInt16]) throws {
        guard newElement >= 0, let name = attributeName else { return }
        try setAttribute(name) { try expandEntities(buf) }
        attributeName = nil
    }

    /// Parser.expandEntities: in an attribute value, a reference is expanded only when a semicolon ends it. Its
    /// steps are counted.
    private func expandEntities(_ src: [UInt16]) throws -> [UInt16] {
        var refStart = -1
        var dst = [UInt16](repeating: 0, count: src.count)
        var n = 0
        for ch in src {
            try cancellation.tick()
            dst[n] = ch
            n += 1
            if ch == UInt16(ascii: "&") && refStart == -1 {
                refStart = n  // the start of a reference, after the &
            } else if refStart == -1 {
                continue
            } else if TagSoupJava.isLetter(ch) || TagSoupJava.isDigit(ch) || ch == UInt16(ascii: "#") {
                continue
            } else if ch == UInt16(ascii: ";") {
                var ent = try lookupEntity(dst[refStart..<(n - 1)])
                if ent > 0xFFFF {
                    ent -= 0x10000
                    dst[refStart - 1] = UInt16(truncatingIfNeeded: (ent >> 10) + 0xD800)
                    dst[refStart] = UInt16(truncatingIfNeeded: (ent & 0x3FF) + 0xDC00)
                    n = refStart + 1
                } else if ent != 0 {
                    dst[refStart - 1] = UInt16(truncatingIfNeeded: ent)
                    n = refStart
                }
                refStart = -1
            } else {
                refStart = -1
            }
        }
        return Array(dst[0..<n])
    }

    /// Parser.lookupEntity: a numeric reference, or a named one from the schema; 0 when there is none. A name
    /// longer than every entity's is none, and is not hashed.
    func lookupEntity(_ name: ArraySlice<UInt16>) throws -> Int32 {
        guard let first = name.first else { return 0 }
        if first == UInt16(ascii: "#") {
            if name.count > 1 && (name[name.startIndex + 1] == UInt16(ascii: "x") || name[name.startIndex + 1] == UInt16(ascii: "X")) {
                return try TagSoupJava.parseInt(name[(name.startIndex + 2)...], 16, cancellation) ?? 0
            }
            return try TagSoupJava.parseInt(name[(name.startIndex + 1)...], 10, cancellation) ?? 0
        }
        if name.count > TagSoupSchema.longestEntity { return 0 }
        return TagSoupSchema.entities[Array(name)] ?? 0
    }

    /// Parser.eof.
    func eof() throws {
        if virginStack { try rectify(pcdataElement) }
        while elements[Int(stack)].next >= 0 { release(try pop()) }
    }

    /// Parser.etag.
    func etag(_ buf: [UInt16]) throws {
        if try etagCdata(buf) { return }
        try etagBasic(buf)
    }

    /// Parser.etag_cdata: in script or style, an end tag for another element is text, and the CDATA content goes
    /// on.
    private func etagCdata(_ buf: [UInt16]) throws -> Bool {
        guard Int(elements[Int(stack)].flags) & TagSoupSchema.cdata != 0 else { return false }
        let current = name(elements[Int(stack)].type)
        var realTag = buf.count == current.count
        if realTag {
            for (c, d) in zip(buf, current) where TagSoupJava.toLower(c) != TagSoupJava.toLower(d) {
                realTag = false
                break
            }
        }
        if realTag { return false }
        try converter.characters([UInt16(ascii: "<"), UInt16(ascii: "/")])
        try converter.characters(buf)
        try converter.characters([UInt16(ascii: ">")])
        scanner.startCDATA()
        return true
    }

    /// Parser.etag_basic. Types with equal names are the same type (a name is defined once), so the walk compares
    /// types.
    private func etagBasic(_ buf: [UInt16]) throws {
        dropNewElement()
        let target: TagSoupType
        if !buf.isEmpty {
            guard let type = try elementType(Self.makeName(buf, cancellation)) else { return }  // a mysterious end tag
            target = type
        } else {
            target = elements[Int(stack)].type
        }
        var sp = stack
        var inNoforce = false
        while sp >= 0 {
            try step()
            if elements[Int(sp)].type == target { break }
            if Int(elements[Int(sp)].flags) & TagSoupSchema.noforce != 0 { inNoforce = true }
            sp = elements[Int(sp)].next
        }
        guard sp >= 0, elements[Int(sp)].next >= 0, elements[Int(elements[Int(sp)].next)].next >= 0 else { return }
        if inNoforce {
            elements[Int(sp)].preclosed = true
        } else {
            while stack != sp { try restartablyPop() }
            release(try pop())
        }
        while stack >= 0 && elements[Int(stack)].preclosed { release(try pop()) }
        try restart(-1)
    }

    /// Parser.restart: it pushes saved restartable elements back where they fit; e is the next element to be
    /// started, if known.
    private func restart(_ e: Int32) throws {
        while saved >= 0, canContain(stack, saved), e < 0 || canContain(saved, e) {
            let next = elements[Int(saved)].next
            try push(saved)
            saved = next
        }
    }

    /// Parser.pop: the popped element, for the caller to release or save.
    private func pop() throws -> Int32 {
        let top = stack
        try step()
        converter.endElement(elements[Int(top)].html)
        stack = elements[Int(top)].next
        return top
    }

    /// Parser.restartablyPop: a restartable element is saved to be pushed again later.
    private func restartablyPop() throws {
        let popped = try pop()
        if Int(elements[Int(popped)].flags) & TagSoupSchema.restart != 0 {
            elements[Int(popped)].next = saved
            saved = popped
        } else {
            release(popped)
        }
    }

    /// Parser.push.
    private func push(_ e: Int32) throws {
        try step()
        let element = elements[Int(e)]
        try converter.startElement(element.html, colorIsDash: element.colorIsDash)
        elements[Int(e)].next = stack
        stack = e
        virginStack = false
        if Int(element.flags) & TagSoupSchema.cdata != 0 { scanner.startCDATA() }
    }

    /// Parser.decl. A declaration adds no text, but it can throw StringIndexOutOfBoundsException: in split, when
    /// the trimmed declaration ends in whitespace that String.trim keeps (U+3000, say), outside quotes; in
    /// trimquotes, when the first DOCTYPE's system or public identifier is a lone quote.
    func decl(_ buf: [UInt16]) throws {
        // Of its words only the first five are read (the doctype's, its id kind's and its ids); all are found.
        guard let v = try Self.split(buf[...], cancellation, limit: 5) else { throw ParityParseError.parserException }
        guard let first = v.first, TagSoupJava.equalsIgnoreCase(first, "DOCTYPE") else { return }
        if doctypeIsPresent { return }  // one doctype only
        doctypeIsPresent = true
        var ids: [ArraySlice<UInt16>] = []
        if v.count > 3 {
            if v[2].elementsEqual("SYSTEM".utf16) {
                ids = [v[3]]
            } else if v[2].elementsEqual("PUBLIC".utf16) {
                ids = Array(v[3..<min(v.count, 5)])
            }
        }
        for id in ids where id.count == 1 && (id.first == UInt16(ascii: "'") || id.first == UInt16(ascii: "\"")) {
            throw ParityParseError.parserException
        }
    }

    /// Parser.split: the trimmed value in words, a quoted phrase being one word, the first limit of them (a
    /// declaration of millions of words keeps five); nil where Java throws. Its steps are counted.
    static func split(_ value: ArraySlice<UInt16>, _ work: ParityCancellation? = nil,
                      limit: Int = .max) throws -> [ArraySlice<UInt16>]? {
        var val = value
        while let first = val.first, first <= 0x20 {
            try work?.tick()
            val = val.dropFirst()
        }
        while let last = val.last, last <= 0x20 {
            try work?.tick()
            val = val.dropLast()
        }
        if val.isEmpty { return [] }
        var words: [ArraySlice<UInt16>] = []
        var s = val.startIndex
        var sq = false
        var dq = false
        var last: UInt16 = 0
        var started = true
        for e in val.indices {
            try work?.tick()
            let c = val[e]
            if !dq && c == UInt16(ascii: "'") && last != UInt16(ascii: "\\") {
                sq.toggle()
                if !started { s = e; started = true }
            } else if !sq && c == UInt16(ascii: "\"") && last != UInt16(ascii: "\\") {
                dq.toggle()
                if !started { s = e; started = true }
            } else if !sq && !dq {
                if TagSoupJava.isWhitespace(c) {
                    if started && words.count < limit { words.append(val[s..<e]) }
                    started = false
                } else if !started && c != 0x20 {
                    s = e
                    started = true
                }
            }
            last = c
        }
        if !started { return nil }  // substring(-1, length)
        if words.count < limit { words.append(val[s...]) }
        return words
    }

    /// Parser.gi: the name of a start tag. An unknown element is defined with an ANY content model, allowed
    /// anywhere.
    func gi(_ buf: [UInt16]) throws {
        if newElement >= 0 { return }
        let name = try Self.makeName(buf, cancellation)
        let key = try TagSoupJava.lowerRoot(name, cancellation)
        var hash: Int?
        var type = try elementType(key: key, hash: &hash)
        if type == nil {
            let h = try hash ?? TagSoupBogons.hash(key, cancellation)
            type = TagSoupSchema.count + TagSoupType(try bogons.define(name: name, key: key, hash: h, cancellation))
        }
        newElement = makeElement(type!)
    }

    /// Parser.pcdata: whitespace where text is not allowed is dropped.
    func pcdata(_ buf: [UInt16]) throws {
        if buf.isEmpty { return }
        var allWhite = true
        for c in buf {
            try cancellation.tick()
            if !TagSoupJava.isWhitespace(c) {
                allWhite = false
                break
            }
        }
        if allWhite && !canContain(stack, pcdataElement) { return }
        try rectify(pcdataElement)
        try converter.characters(buf)
    }

    /// Parser.stagc: the end of a start tag.
    func stagc(_ buf: [UInt16]) throws {
        guard newElement >= 0 else { return }
        try rectify(newElement)
        if elements[Int(stack)].model == TagSoupSchema.emptyModel { try etagBasic(buf) }  // an immediate end tag
    }

    /// Parser.stage: the end of an empty-element tag.
    func stage(_ buf: [UInt16]) throws {
        guard newElement >= 0 else { return }
        try rectify(newElement)
        try etagBasic(buf)
    }

    /// Parser.rectify: it pops and pushes elements, implied parents included, so that e can be pushed.
    private func rectify(_ element: Int32) throws {
        var e = element
        var sp: Int32 = -1
        while true {
            sp = stack
            while sp >= 0 {
                try step()
                if canContain(sp, e) { break }
                sp = elements[Int(sp)].next
            }
            if sp >= 0 { break }
            let parentType = parent(elements[Int(e)].type)
            if parentType < 0 { break }
            e = makeElement(parentType, next: e)
        }
        guard sp >= 0 else {
            // No place for it: the implied parents made for it are dropped.
            while e != element {
                let next = elements[Int(e)].next
                release(e)
                e = next
            }
            return
        }
        while stack != sp {
            if stack < 0 || elements[Int(stack)].next < 0 || elements[Int(elements[Int(stack)].next)].next < 0 { break }
            try restartablyPop()
        }
        // The chain ends with element, whose next is not part of it (no element; the pcdata element is never
        // pushed).
        var current = e
        var last = false
        while !last {
            last = current == element
            let next = last ? -1 : elements[Int(current)].next
            if elements[Int(current)].type != Self.pcdataType { try push(current) }
            current = next
            try restart(next)
        }
        if newElement != element { dropNewElement() }
        newElement = -1
    }

    /// Parser.makeName: letters, digits, '-', '.', '_' and one colon, with '_' where a name or local name would not
    /// start with a letter. Its steps are counted.
    static func makeName(_ buf: [UInt16], _ work: ParityCancellation? = nil) throws -> [UInt16] {
        var dst: [UInt16] = []
        dst.reserveCapacity(buf.count + 2)
        var seenColon = false
        var start = true
        for ch in buf {
            try work?.tick()
            if TagSoupJava.isLetter(ch) || ch == UInt16(ascii: "_") {
                start = false
                dst.append(ch)
            } else if TagSoupJava.isDigit(ch) || ch == UInt16(ascii: "-") || ch == UInt16(ascii: ".") {
                if start { dst.append(UInt16(ascii: "_")) }
                start = false
                dst.append(ch)
            } else if ch == UInt16(ascii: ":") && !seenColon {
                seenColon = true
                if start { dst.append(UInt16(ascii: "_")) }
                start = true
                dst.append(ch)
            }
        }
        if dst.isEmpty || dst.last == UInt16(ascii: ":") { dst.append(UInt16(ascii: "_")) }
        return dst
    }
}

// MARK: - TagSoup's HTMLScanner (tagsoup_scanner.go)

/// HTMLScanner: the table-driven scanner that reports lexical events to the Parser, reading UTF-16 code units as
/// the Java Reader does. (A class: the parser changes its state while it scans.)
final class TagSoupScanner {
    // States.
    static let sAname = 1, sApos = 2, sAval = 3, sBB = 4, sBBC = 5, sBBCD = 6, sBBCDA = 7, sBBCDAT = 8, sBBCDATA = 9,
               sCdata = 10, sCdata2 = 11, sCdsect = 12, sCdsect1 = 13, sCdsect2 = 14, sCom = 15, sCom2 = 16, sCom3 = 17,
               sCom4 = 18, sDecl = 19, sDecl2 = 20, sDone = 21, sEmptytag = 22, sEnt = 23, sEq = 24, sEtag = 25, sGi = 26,
               sNcr = 27, sPcdata = 28, sPi = 29, sPitarget = 30, sQuot = 31, sStagc = 32, sTag = 33, sTagws = 34,
               sXncr = 35
    // Actions.
    static let aAdup = 1, aAdupSave = 2, aAdupStagc = 3, aAname = 4, aAnameAdup = 5, aAnameAdupStagc = 6, aAval = 7,
               aAvalStagc = 8, aCdata = 9, aCmnt = 10, aDecl = 11, aEmptytag = 12, aEntity = 13, aEntityStart = 14,
               aEtag = 15, aGi = 16, aGiStagc = 17, aLt = 18, aLtPcdata = 19, aMinus = 20, aMinus2 = 21, aMinus3 = 22,
               aPcdata = 23, aPi = 24, aPitarget = 25, aPitargetPi = 26, aSave = 27, aSkip = 28, aSp = 29, aStagc = 30,
               aUnget = 31, aUnsavePcdata = 32

    /// HTMLScanner.statetable: state, input character (0 for any other, -1 for the end), action, next state.
    static let stateTable: [(Int, Int, Int, Int)] = {
        let sp = Int(UInt8(ascii: " ")), nl = 0x0A, tab = 0x09
        func c(_ s: Character) -> Int { Int(s.asciiValue!) }
        return [
            (sAname, c("/"), aAnameAdup, sEmptytag), (sAname, c("="), aAname, sAval),
            (sAname, c(">"), aAnameAdupStagc, sPcdata), (sAname, 0, aSave, sAname), (sAname, -1, aAnameAdupStagc, sDone),
            (sAname, sp, aAname, sEq), (sAname, nl, aAname, sEq), (sAname, tab, aAname, sEq),
            (sApos, c("'"), aAval, sTagws), (sApos, 0, aSave, sApos), (sApos, -1, aAvalStagc, sDone),
            (sApos, sp, aSp, sApos), (sApos, nl, aSp, sApos), (sApos, tab, aSp, sApos),
            (sAval, c("\""), aSkip, sQuot), (sAval, c("'"), aSkip, sApos), (sAval, c(">"), aAvalStagc, sPcdata),
            (sAval, 0, aSave, sStagc), (sAval, -1, aAvalStagc, sDone), (sAval, sp, aSkip, sAval),
            (sAval, nl, aSkip, sAval), (sAval, tab, aSkip, sAval),
            (sBB, c("C"), aSkip, sBBC), (sBB, 0, aSkip, sDecl), (sBB, -1, aSkip, sDone),
            (sBBC, c("D"), aSkip, sBBCD), (sBBC, 0, aSkip, sDecl), (sBBC, -1, aSkip, sDone),
            (sBBCD, c("A"), aSkip, sBBCDA), (sBBCD, 0, aSkip, sDecl), (sBBCD, -1, aSkip, sDone),
            (sBBCDA, c("T"), aSkip, sBBCDAT), (sBBCDA, 0, aSkip, sDecl), (sBBCDA, -1, aSkip, sDone),
            (sBBCDAT, c("A"), aSkip, sBBCDATA), (sBBCDAT, 0, aSkip, sDecl), (sBBCDAT, -1, aSkip, sDone),
            (sBBCDATA, c("["), aSkip, sCdsect), (sBBCDATA, 0, aSkip, sDecl), (sBBCDATA, -1, aSkip, sDone),
            (sCdata, c("<"), aSave, sCdata2), (sCdata, 0, aSave, sCdata), (sCdata, -1, aPcdata, sDone),
            (sCdata2, c("/"), aUnsavePcdata, sEtag), (sCdata2, 0, aSave, sCdata), (sCdata2, -1, aUnsavePcdata, sDone),
            (sCdsect, c("]"), aSave, sCdsect1), (sCdsect, 0, aSave, sCdsect), (sCdsect, -1, aSkip, sDone),
            (sCdsect1, c("]"), aSave, sCdsect2), (sCdsect1, 0, aSave, sCdsect), (sCdsect1, -1, aSkip, sDone),
            (sCdsect2, c(">"), aCdata, sPcdata), (sCdsect2, 0, aSave, sCdsect), (sCdsect2, -1, aSkip, sDone),
            (sCom, c("-"), aSkip, sCom2), (sCom, 0, aSave, sCom2), (sCom, -1, aCmnt, sDone),
            (sCom2, c("-"), aSkip, sCom3), (sCom2, 0, aSave, sCom2), (sCom2, -1, aCmnt, sDone),
            (sCom3, c("-"), aSkip, sCom4), (sCom3, 0, aMinus, sCom2), (sCom3, -1, aCmnt, sDone),
            (sCom4, c("-"), aMinus3, sCom4), (sCom4, c(">"), aCmnt, sPcdata), (sCom4, 0, aMinus2, sCom2),
            (sCom4, -1, aCmnt, sDone),
            (sDecl, c("-"), aSkip, sCom), (sDecl, c(">"), aSkip, sPcdata), (sDecl, c("["), aSkip, sBB),
            (sDecl, 0, aSave, sDecl2), (sDecl, -1, aSkip, sDone),
            (sDecl2, c(">"), aDecl, sPcdata), (sDecl2, 0, aSave, sDecl2), (sDecl2, -1, aSkip, sDone),
            (sEmptytag, c(">"), aEmptytag, sPcdata), (sEmptytag, 0, aSave, sAname), (sEmptytag, sp, aSkip, sTagws),
            (sEmptytag, nl, aSkip, sTagws), (sEmptytag, tab, aSkip, sTagws),
            (sEnt, 0, aEntity, sEnt), (sEnt, -1, aEntity, sDone),
            (sEq, c("="), aSkip, sAval), (sEq, c(">"), aAdupStagc, sPcdata), (sEq, 0, aAdupSave, sAname),
            (sEq, -1, aAdupStagc, sDone), (sEq, sp, aSkip, sEq), (sEq, nl, aSkip, sEq), (sEq, tab, aSkip, sEq),
            (sEtag, c(">"), aEtag, sPcdata), (sEtag, 0, aSave, sEtag), (sEtag, -1, aEtag, sDone),
            (sEtag, sp, aSkip, sEtag), (sEtag, nl, aSkip, sEtag), (sEtag, tab, aSkip, sEtag),
            (sGi, c("/"), aSkip, sEmptytag), (sGi, c(">"), aGiStagc, sPcdata), (sGi, 0, aSave, sGi),
            (sGi, -1, aSkip, sDone), (sGi, sp, aGi, sTagws), (sGi, nl, aGi, sTagws), (sGi, tab, aGi, sTagws),
            (sNcr, 0, aEntity, sNcr), (sNcr, -1, aEntity, sDone),
            (sPcdata, c("&"), aEntityStart, sEnt), (sPcdata, c("<"), aPcdata, sTag), (sPcdata, 0, aSave, sPcdata),
            (sPcdata, -1, aPcdata, sDone),
            (sPi, c(">"), aPi, sPcdata), (sPi, 0, aSave, sPi), (sPi, -1, aPi, sDone),
            (sPitarget, c(">"), aPitargetPi, sPcdata), (sPitarget, 0, aSave, sPitarget),
            (sPitarget, -1, aPitargetPi, sDone), (sPitarget, sp, aPitarget, sPi), (sPitarget, nl, aPitarget, sPi),
            (sPitarget, tab, aPitarget, sPi),
            (sQuot, c("\""), aAval, sTagws), (sQuot, 0, aSave, sQuot), (sQuot, -1, aAvalStagc, sDone),
            (sQuot, sp, aSp, sQuot), (sQuot, nl, aSp, sQuot), (sQuot, tab, aSp, sQuot),
            (sStagc, c(">"), aAvalStagc, sPcdata), (sStagc, 0, aSave, sStagc), (sStagc, -1, aAvalStagc, sDone),
            (sStagc, sp, aAval, sTagws), (sStagc, nl, aAval, sTagws), (sStagc, tab, aAval, sTagws),
            (sTag, c("!"), aSkip, sDecl), (sTag, c("/"), aSkip, sEtag), (sTag, c("<"), aSave, sTag),
            (sTag, c("?"), aSkip, sPitarget), (sTag, 0, aSave, sGi), (sTag, -1, aLtPcdata, sDone),
            (sTag, sp, aLt, sPcdata), (sTag, nl, aLt, sPcdata), (sTag, tab, aLt, sPcdata),
            (sTagws, c("/"), aSkip, sEmptytag), (sTagws, c(">"), aStagc, sPcdata), (sTagws, 0, aSave, sAname),
            (sTagws, -1, aStagc, sDone), (sTagws, sp, aSkip, sTagws), (sTagws, nl, aSkip, sTagws),
            (sTagws, tab, aSkip, sTagws),
            (sXncr, 0, aEntity, sXncr), (sXncr, -1, aEntity, sDone)
        ]
    }()

    /// HTMLScanner.theWinMap: U+0080-U+009F read as windows-1252.
    static let winMap: [UInt16] = [
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD,
        0x017D, 0xFFFD, 0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
        0x0153, 0xFFFD, 0x017E, 0x0178
    ]

    /// HTMLScanner.statetableIndex: the row for a state and a character up to ']' (the highest in the table),
    /// shifted by 2 so that -2 (any other character) and -1 (the end) are indexes too.
    static let index: [[Int16]] = {
        let width = Int(UInt8(ascii: "]")) + 3
        var index = [[Int16]](repeating: [Int16](repeating: -1, count: width), count: sXncr + 1)
        for state in 0...sXncr {
            for ch in -2...Int(UInt8(ascii: "]")) {
                var hit = -1
                for (i, row) in stateTable.enumerated() where row.0 == state {
                    if row.1 == 0 {
                        hit = i
                    } else if row.1 == ch {
                        hit = i
                        break
                    }
                }
                index[state][ch + 2] = Int16(hit)
            }
        }
        return index
    }()

    private let source: [UInt16]
    private var pos = 0
    private var pushback: [Int] = []
    private var state = 0
    private var nextState = 0
    private var out: [UInt16] = []
    /// theOutputBuffer.length, which decides when text is flushed.
    private var outCap = 0

    init(source: [UInt16]) { self.source = source }

    private func read() -> Int {
        if let c = pushback.popLast() { return c }
        if pos >= source.count { return -1 }
        pos += 1
        return Int(source[pos - 1])
    }

    private func unread(_ c: Int) {
        if c != -1 { pushback.append(c) }
    }

    /// HTMLScanner.startCDATA: only an end tag ends the content.
    func startCDATA() { nextState = Self.sCdata }

    /// HTMLScanner.save: in text the full buffer is flushed as characters; elsewhere it grows.
    private func save(_ ch: Int, _ h: TagSoupParser) throws {
        if out.count >= outCap - 20 {
            if state == Self.sPcdata || state == Self.sCdata {
                try h.pcdata(out)
                out.removeAll(keepingCapacity: true)
            } else {
                outCap *= 2
            }
        }
        out.append(UInt16(truncatingIfNeeded: ch))
    }

    /// HTMLScanner.scan.
    func scan(_ h: TagSoupParser) throws {
        state = Self.sPcdata
        outCap = 200
        let first = read()
        if first != 0xFEFF { unread(first) }  // remove a leading BOM
        var n = 0
        while state != Self.sDone {
            if n % 4096 == 0 { try h.cancellation.check() }
            n += 1
            var ch = read()
            if ch >= 0x80 && ch <= 0x9F { ch = Int(Self.winMap[ch - 0x80]) }
            if ch == 0x0D {
                ch = read()  // expect LF next
                if ch != 0x0A {
                    unread(ch)
                    ch = 0x0A
                }
            }
            if !(ch >= 0x20 || ch == 0x0A || ch == 0x09 || ch == -1) { continue }
            let adjusted = ch > Int(UInt8(ascii: "]")) ? -2 : ch
            var action = 0
            let row = Int(Self.index[state][adjusted + 2])
            if row >= 0 {
                action = Self.stateTable[row].2
                nextState = Self.stateTable[row].3
            }
            let size = out.count
            switch action {
            case Self.aAdup:
                h.adup()
                out.removeAll(keepingCapacity: true)
            case Self.aAdupSave:
                h.adup()
                out.removeAll(keepingCapacity: true)
                try save(ch, h)
            case Self.aAdupStagc:
                h.adup()
                out.removeAll(keepingCapacity: true)
                try h.stagc(out)
            case Self.aAname:
                try h.aname(out)
                out.removeAll(keepingCapacity: true)
            case Self.aAnameAdup:
                try h.aname(out)
                out.removeAll(keepingCapacity: true)
                h.adup()
            case Self.aAnameAdupStagc:
                try h.aname(out)
                out.removeAll(keepingCapacity: true)
                h.adup()
                try h.stagc(out)
            case Self.aAval:
                try h.aval(out)
                out.removeAll(keepingCapacity: true)
            case Self.aAvalStagc:
                try h.aval(out)
                out.removeAll(keepingCapacity: true)
                try h.stagc(out)
            case Self.aCdata:
                if size > 1 { out.removeLast(2) }  // the "]]"
                try h.pcdata(out)
                out.removeAll(keepingCapacity: true)
            case Self.aEntityStart:
                try h.pcdata(out)
                out.removeAll(keepingCapacity: true)
                try save(ch, h)
            case Self.aEntity:
                try entity(ch, h)
            case Self.aEtag:
                try h.etag(out)
                out.removeAll(keepingCapacity: true)
            case Self.aDecl:
                try h.decl(out)
                out.removeAll(keepingCapacity: true)
            case Self.aGi:
                try h.gi(out)
                out.removeAll(keepingCapacity: true)
            case Self.aGiStagc:
                try h.gi(out)
                out.removeAll(keepingCapacity: true)
                try h.stagc(out)
            case Self.aLt:
                try save(Int(UInt8(ascii: "<")), h)
                try save(ch, h)
            case Self.aLtPcdata:
                try save(Int(UInt8(ascii: "<")), h)
                try h.pcdata(out)
                out.removeAll(keepingCapacity: true)
            case Self.aPcdata:
                try h.pcdata(out)
                out.removeAll(keepingCapacity: true)
            case Self.aCmnt, Self.aPi:
                // Comments and processing instructions add no text.
                out.removeAll(keepingCapacity: true)
            case Self.aMinus3:
                try save(Int(UInt8(ascii: "-")), h)
                try save(0x20, h)
            case Self.aMinus2:
                try save(Int(UInt8(ascii: "-")), h)
                try save(0x20, h)
                try save(Int(UInt8(ascii: "-")), h)
                try save(ch, h)
            case Self.aMinus:
                try save(Int(UInt8(ascii: "-")), h)
                try save(ch, h)
            case Self.aPitarget, Self.aPitargetPi:
                out.removeAll(keepingCapacity: true)
            case Self.aSave:
                try save(ch, h)
            case Self.aSkip:
                break
            case Self.aSp:
                try save(0x20, h)
            case Self.aStagc:
                try h.stagc(out)
                out.removeAll(keepingCapacity: true)
            case Self.aEmptytag:
                if size > 0 { try h.gi(out) }
                out.removeAll(keepingCapacity: true)
                try h.stage(out)
            case Self.aUnget:
                unread(ch)
            case Self.aUnsavePcdata:
                if size > 0 { out.removeLast() }
                try h.pcdata(out)
                out.removeAll(keepingCapacity: true)
            default:
                throw ParityParseError.parserException  // HTMLScanner throws an Error; the table has a row for every case
            }
            state = nextState
        }
        try h.eof()
    }

    /// The A_ENTITY action: it extends a character reference by ch, or ends it and replaces it by its character.
    private func entity(_ ch: Int, _ h: TagSoupParser) throws {
        let c = UInt16(truncatingIfNeeded: ch)  // (char) ch: the end of the input is U+FFFF
        if state == Self.sEnt && c == UInt16(ascii: "#") {
            nextState = Self.sNcr
            try save(ch, h)
            return
        }
        if state == Self.sNcr && (c == UInt16(ascii: "x") || c == UInt16(ascii: "X")) {
            nextState = Self.sXncr
            try save(ch, h)
            return
        }
        if state == Self.sEnt && (TagSoupJava.isLetter(c) || TagSoupJava.isDigit(c))
            || state == Self.sNcr && TagSoupJava.isDigit(c)
            || state == Self.sXncr && (TagSoupJava.isDigit(c) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)) {
            try save(ch, h)
            return
        }
        var ent = try h.lookupEntity(out.dropFirst())
        if ent != 0 {
            out.removeAll(keepingCapacity: true)
            if ent >= 0x80 && ent <= 0x9F { ent = Int32(Self.winMap[Int(ent - 0x80)]) }
            if ent < 0x20 {
                // HTMLScanner sets ent to a space but saves nothing.
            } else if ent >= 0xD800 && ent <= 0xDFFF {
            } else if ent <= 0xFFFF {
                try save(Int(ent), h)
            } else {
                ent -= 0x10000
                try save(Int(ent >> 10) + 0xD800, h)
                try save(Int(ent & 0x3FF) + 0xDC00, h)
            }
            if ch != Int(UInt8(ascii: ";")) { unread(ch) }
        } else {
            unread(ch)
        }
        nextState = Self.sPcdata
    }
}

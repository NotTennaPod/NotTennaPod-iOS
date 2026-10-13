// The port of Go's encoding/xml Decoder.RawToken (Go 1.27), which the server's parse reads documents with: Strict,
// no auto-closing, a pass-through CharsetReader (the text is already decoded) and the caller's entity map. It works
// on the document's UTF-8 bytes, as Go does, and reports the same tokens, the same end of input and the same errors.
// Given a cancellation, it asks every 64 KiB of input read, as the server's decoder reads through its ctxReader, and
// as often in its passes over what it read: one token can be as long as the document.

struct GoXMLName: Equatable {
    var space: [UInt8] = []
    var local: [UInt8] = []

    /// The qualified name as written.
    var qualified: [UInt8] { space.isEmpty ? local : space + [UInt8(ascii: ":")] + local }
}

/// A start tag's attributes: every prefix, local name and value one after another in one array, with their ends. A
/// tag of millions of attributes is a few arrays, released at once, not millions.
struct GoXMLAttributes {
    private(set) var bytes: [UInt8] = []
    /// Per attribute, the ends of its prefix, local name and value in bytes.
    private var ends: [Int] = []

    var count: Int { ends.count / 3 }

    private func start(_ i: Int) -> Int { i == 0 ? 0 : ends[3 * i - 1] }

    /// The attribute's prefix ("" for none).
    func space(_ i: Int) -> ArraySlice<UInt8> { bytes[start(i)..<ends[3 * i]] }

    func local(_ i: Int) -> ArraySlice<UInt8> { bytes[ends[3 * i]..<ends[3 * i + 1]] }

    func value(_ i: Int) -> ArraySlice<UInt8> { bytes[ends[3 * i + 1]..<ends[3 * i + 2]] }

    mutating func append(_ name: GoXMLName, _ value: [UInt8]) {
        bytes.append(contentsOf: name.space)
        ends.append(bytes.count)
        bytes.append(contentsOf: name.local)
        ends.append(bytes.count)
        bytes.append(contentsOf: value)
        ends.append(bytes.count)
    }

    /// Whether the attribute's qualified name (prefix:local, or local) is key.
    func qualifiedIs(_ i: Int, _ key: UnsafeBufferPointer<UInt8>) -> Bool {
        let space = self.space(i)
        let local = self.local(i)
        if space.isEmpty { return local.elementsEqual(key) }
        return key.count == space.count + 1 + local.count && key[space.count] == UInt8(ascii: ":")
            && space.elementsEqual(key[..<space.count]) && local.elementsEqual(key[(space.count + 1)...])
    }
}

enum GoXMLToken {
    case start(GoXMLName, GoXMLAttributes)
    case end(GoXMLName)
    case charData([UInt8])
    case comment
    case procInst
    case directive([UInt8])
}

struct GoXMLDecoder {
    /// Why rawToken returned nil: the end of input, an error, or the parse's cancellation.
    enum Failure { case eof, syntax, cancelled }

    private let input: [UInt8]
    private let cancellation: ParityCancellation?
    /// Bytes read or checked since the decoder last asked.
    private var work = 0
    /// Decoder.InputOffset.
    private(set) var offset: Int
    private(set) var failure: Failure?
    /// Decoder.Entity, besides the predefined entities.
    var entities: [[UInt8]: [UInt8]]
    private var needClose = false
    private var toClose = GoXMLName()
    private var buf: [UInt8] = []

    init(_ input: [UInt8], entities: [[UInt8]: [UInt8]] = [:], cancellation: ParityCancellation? = nil) {
        self.input = input
        self.offset = 0
        self.entities = entities
        self.cancellation = cancellation
    }

    /// Counts bytes of work, asking every ParityCancellation.interval of them; false (failure .cancelled) once the
    /// parse is cancelled.
    @inline(__always) private mutating func spend(_ bytes: Int) -> Bool {
        work &+= bytes
        guard work >= ParityCancellation.interval, let cancellation else { return true }
        work = 0
        if cancellation.cancelled {
            failure = .cancelled
            return false
        }
        return true
    }

    /// xml.HTMLEntity.
    static let htmlEntities: [[UInt8]: [UInt8]] = Dictionary(
        ParityXMLNameTables.htmlEntities.map { (Array($0.0.utf8), Array($0.1.utf8)) }, uniquingKeysWith: { a, _ in a })

    // MARK: Bytes

    private mutating func getc() -> UInt8? {
        if failure != nil { return nil }
        guard offset < input.count else {
            failure = .eof
            return nil
        }
        if !spend(1) { return nil }
        offset += 1
        return input[offset - 1]
    }

    private mutating func mustgetc() -> UInt8? {
        guard let b = getc() else {
            if failure == .eof { failure = .syntax }  // unexpected EOF
            return nil
        }
        return b
    }

    /// Decoder.ungetc: the byte just read is read again.
    private mutating func ungetc() { offset -= 1 }

    private mutating func space() {
        while let b = getc() {
            switch b {
            case 0x20, 0x0D, 0x0A, 0x09: continue
            default:
                ungetc()
                return
            }
        }
    }

    // MARK: Tokens

    /// Decoder.RawToken: nil at the end of input (failure .eof), on an error (failure .syntax) or at the parse's
    /// cancellation (failure .cancelled), then always.
    mutating func rawToken() -> GoXMLToken? {
        if failure != nil { return nil }
        if needClose {
            // The last element read was self-closing: its end comes now.
            needClose = false
            return .end(toClose)
        }
        guard let first = getc() else { return nil }
        if first != UInt8(ascii: "<") {
            ungetc()
            guard let data = text(quote: -1, cdata: false) else { return nil }
            return .charData(data)
        }
        guard var b = mustgetc() else { return nil }
        switch b {
        case UInt8(ascii: "/"):
            guard let name = nsname() else { return fail() }
            space()
            guard let c = mustgetc() else { return nil }
            if c != UInt8(ascii: ">") { return fail() }
            return .end(name)

        case UInt8(ascii: "?"):
            guard let target = name() else { return fail() }
            space()
            buf.removeAll(keepingCapacity: true)
            var b0: UInt8 = 0
            while true {
                guard let c = mustgetc() else { return nil }
                buf.append(c)
                if b0 == UInt8(ascii: "?") && c == UInt8(ascii: ">") { break }
                b0 = c
            }
            if target.is("xml") {
                let version = Self.procInst(Array("version".utf8), buf.dropLast(2))
                if !version.isEmpty && version != Array("1.0".utf8) { return fail() }
                // A declared encoding goes to the pass-through CharsetReader: nothing changes.
            }
            return .procInst

        case UInt8(ascii: "!"):
            guard let c = mustgetc() else { return nil }
            b = c
            if b == UInt8(ascii: "-") {
                // <!-- a comment -->
                guard let d = mustgetc() else { return nil }
                if d != UInt8(ascii: "-") { return fail() }
                var b0: UInt8 = 0
                var b1: UInt8 = 0
                while true {
                    guard let e = mustgetc() else { return nil }
                    if b0 == UInt8(ascii: "-") && b1 == UInt8(ascii: "-") {
                        if e != UInt8(ascii: ">") { return fail() }  // "--" is not allowed in comments
                        break
                    }
                    b0 = b1
                    b1 = e
                }
                return .comment
            }
            if b == UInt8(ascii: "[") {
                for expected in Array("CDATA[".utf8) {
                    guard let e = mustgetc() else { return nil }
                    if e != expected { return fail() }
                }
                guard let data = text(quote: -1, cdata: true) else { return nil }
                return .charData(data)
            }
            // A directive (<!DOCTYPE …>, <!ENTITY …>): accumulated for the caller. Quoted angle brackets do not
            // count for nesting; a comment inside is replaced by a space.
            buf.removeAll(keepingCapacity: true)
            buf.append(b)
            var inquote: UInt8 = 0
            var depth = 0
            while true {
                guard var c = mustgetc() else { return nil }
                if inquote == 0 && c == UInt8(ascii: ">") && depth == 0 { break }
                handle: while true {
                    buf.append(c)
                    switch c {
                    case _ where c == inquote:
                        inquote = 0
                    case _ where inquote != 0:
                        break
                    case UInt8(ascii: "'"), UInt8(ascii: "\""):
                        inquote = c
                    case UInt8(ascii: ">"):
                        depth -= 1
                    case UInt8(ascii: "<"):
                        // Look for <!-- to begin a comment.
                        let opener = Array("!--".utf8)
                        for i in 0..<opener.count {
                            guard let e = mustgetc() else { return nil }
                            if e != opener[i] {
                                buf.append(contentsOf: opener[0..<i])
                                depth += 1
                                c = e
                                continue handle
                            }
                        }
                        buf.removeLast()  // the "<" written above
                        var b0: UInt8 = 0
                        var b1: UInt8 = 0
                        while true {
                            guard let e = mustgetc() else { return nil }
                            if b0 == UInt8(ascii: "-") && b1 == UInt8(ascii: "-") && e == UInt8(ascii: ">") { break }
                            b0 = b1
                            b1 = e
                        }
                        buf.append(0x20)
                    default:
                        break
                    }
                    break handle
                }
            }
            return .directive(Self.copy(buf[...]))

        default:
            break
        }

        // An element: <a href="foo">.
        ungetc()
        guard let name = nsname() else { return fail() }
        var attrs = GoXMLAttributes()
        var empty = false
        while true {
            space()
            guard let c = mustgetc() else { return nil }
            if c == UInt8(ascii: "/") {
                empty = true
                guard let d = mustgetc() else { return nil }
                if d != UInt8(ascii: ">") { return fail() }
                break
            }
            if c == UInt8(ascii: ">") { break }
            ungetc()
            guard let attrName = nsname() else { return fail() }
            space()
            guard let e = mustgetc() else { return nil }
            if e != UInt8(ascii: "=") { return fail() }  // Strict: an attribute needs a value
            space()
            guard let value = attrval() else { return nil }
            attrs.append(attrName, value)
        }
        if empty {
            needClose = true
            toClose = name
        }
        return .start(name, attrs)
    }

    /// A token's bytes in an array of their own. Array(buf) or a slice of all of buf would share buf's storage, as
    /// large as the largest token so far: every attribute name and value kept it alive (a feed of 254 KB, a 64 KiB value
    /// then 20,000 attributes, took 645 MB), and buf grew a new one at its next use.
    private static func copy(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        bytes.withUnsafeBufferPointer { [UInt8]($0) }
    }

    private mutating func fail() -> GoXMLToken? {
        if failure == nil { failure = .syntax }
        return nil
    }

    private mutating func attrval() -> [UInt8]? {
        guard let b = mustgetc() else { return nil }
        if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") { return text(quote: Int(b), cdata: false) }
        failure = .syntax  // Strict: an unquoted or missing value
        return nil
    }

    /// Decoder.text: character data up to "<" (or the closing quote, or "]]>" in a CDATA section), with references
    /// replaced and "\r" and "\r\n" read as "\n"; nil on an error.
    private mutating func text(quote: Int, cdata: Bool) -> [UInt8]? {
        var b0: UInt8 = 0
        var b1: UInt8 = 0
        var trunc = 0
        buf.removeAll(keepingCapacity: true)
        input: while true {
            guard var b = getc() else {
                if failure == .cancelled { return nil }
                if cdata {
                    if failure == .eof { failure = .syntax }  // unexpected EOF in a CDATA section
                    return nil
                }
                break input
            }
            // A CDATA section ends with "]]>", which ordinary text may not hold (quoted strings may).
            if quote < 0 && b0 == UInt8(ascii: "]") && b1 == UInt8(ascii: "]") && b == UInt8(ascii: ">") {
                if cdata {
                    trunc = 2
                    break input
                }
                failure = .syntax
                return nil
            }
            if b == UInt8(ascii: "<") && !cdata {
                if quote >= 0 {
                    failure = .syntax  // an unescaped "<" inside a quoted string
                    return nil
                }
                ungetc()
                break input
            }
            if quote >= 0 && Int(b) == quote { break input }
            if b == UInt8(ascii: "&") && !cdata {
                // A reference, up to its semicolon.
                let before = buf.count
                buf.append(b)
                var replacement: [UInt8]?
                guard let c = mustgetc() else { return nil }
                b = c
                if b == UInt8(ascii: "#") {
                    buf.append(b)
                    guard let c = mustgetc() else { return nil }
                    b = c
                    var base: UInt64 = 10
                    if b == UInt8(ascii: "x") {
                        base = 16
                        buf.append(b)
                        guard let c = mustgetc() else { return nil }
                        b = c
                    }
                    let start = buf.count
                    while b >= 0x30 && b <= 0x39 || base == 16 && (b >= 0x61 && b <= 0x66 || b >= 0x41 && b <= 0x46) {
                        buf.append(b)
                        guard let c = mustgetc() else { return nil }
                        b = c
                    }
                    if b != UInt8(ascii: ";") {
                        ungetc()
                    } else {
                        // The digits are read before buf grows: a slice of buf kept across the append would copy
                        // all the text so far (Go copies the digits into a string first).
                        let parsed = Self.parseUint(buf[start...], base: base)
                        buf.append(b)
                        if let n = parsed, n <= 0x10FFFF {
                            var r: [UInt8] = []
                            GoStrings.appendRune(&r, UInt32(n))  // a surrogate is U+FFFD
                            replacement = r
                        }
                    }
                } else {
                    ungetc()
                    if !readName() && failure != nil { return nil }
                    guard let c = mustgetc() else { return nil }
                    if c != UInt8(ascii: ";") {
                        ungetc()
                    } else {
                        let name = Array(buf[(before + 1)...])
                        buf.append(c)
                        guard let valid = isName(counting: name[...]) else { return nil }
                        if valid {
                            if name.is("lt") {
                                replacement = [UInt8(ascii: "<")]
                            } else if name.is("gt") {
                                replacement = [UInt8(ascii: ">")]
                            } else if name.is("amp") {
                                replacement = [UInt8(ascii: "&")]
                            } else if name.is("apos") {
                                replacement = [UInt8(ascii: "'")]
                            } else if name.is("quot") {
                                replacement = [UInt8(ascii: "\"")]
                            } else {
                                replacement = entities[name]
                            }
                        }
                    }
                }
                if let replacement {
                    buf.removeSubrange(before...)
                    buf.append(contentsOf: replacement)
                    b0 = 0
                    b1 = 0
                    continue input
                }
                failure = .syntax  // Strict: an invalid character entity
                return nil
            }
            // Unescaped "\r" and "\r\n" become "\n".
            if b == 0x0D {
                buf.append(0x0A)
            } else if b1 == 0x0D && b == 0x0A {
                // already written
            } else {
                buf.append(b)
            }
            b0 = b1
            b1 = b
        }
        let data = Self.copy(buf[0..<(buf.count - trunc)])
        // Every rune must be UTF-8 and an XML character.
        var i = 0
        let slice = data[...]
        while i < data.count {
            let (r, n) = GoStrings.decodeRune(slice, i)
            if !spend(n) { return nil }
            if r == 0xFFFD && n == 1 {
                failure = .syntax
                return nil
            }
            if !(r == 0x09 || r == 0x0A || r == 0x0D || r >= 0x20 && r <= 0xD7FF || r >= 0xE000 && r <= 0xFFFD
                 || r >= 0x10000 && r <= 0x10FFFF) {
                failure = .syntax  // an illegal character code
                return nil
            }
            i += n
        }
        return data
    }

    /// strconv.ParseUint(s, base, 64) for decimal or hexadecimal digits.
    private static func parseUint(_ s: ArraySlice<UInt8>, base: UInt64) -> UInt64? {
        guard !s.isEmpty else { return nil }
        var n: UInt64 = 0
        for c in s {
            let d: UInt64 = c <= 0x39 ? UInt64(c - 0x30) : UInt64((c | 0x20) - 0x61 + 10)
            let (m, o1) = n.multipliedReportingOverflow(by: base)
            let (v, o2) = m.addingReportingOverflow(d)
            if o1 || o2 { return nil }
            n = v
        }
        return n
    }

    // MARK: Names

    /// Decoder.nsname: a name with at most one colon, split into prefix and local name.
    private mutating func nsname() -> GoXMLName? {
        guard let s = name() else { return nil }
        // strings.Count(s, ":") > 1 fails, then strings.Cut at the colon: one pass that stops at a second colon,
        // keeping one index (a list of every colon of a name of colons was eight bytes for each of its bytes), and
        // counting its steps.
        var colon = -1
        var i = 0
        while i < s.count {
            if !spend(1) { return nil }
            if s[i] == UInt8(ascii: ":") {
                if colon >= 0 { return nil }
                colon = i
            }
            i += 1
        }
        if colon > 0, colon < s.count - 1 {
            return GoXMLName(space: Array(s[..<colon]), local: Array(s[(colon + 1)...]))
        }
        return GoXMLName(space: [], local: s)
    }

    /// Decoder.name: a name, checked against XML's name characters.
    private mutating func name() -> [UInt8]? {
        buf.removeAll(keepingCapacity: true)
        if !readName() { return nil }
        let name = Self.copy(buf[...])
        guard let valid = isName(counting: name[...]) else { return nil }
        if !valid {
            failure = .syntax
            return nil
        }
        return name
    }

    /// Decoder's isName: whether s is a name of XML's name characters; its steps are counted, nil at the parse's
    /// cancellation.
    private mutating func isName(counting s: ArraySlice<UInt8>) -> Bool? {
        guard !s.isEmpty else { return false }
        var i = s.startIndex
        var first = true
        while i < s.endIndex {
            let (c, n) = GoStrings.decodeRune(s, i)
            if !spend(n) { return nil }
            if c == 0xFFFD && n == 1 { return false }
            if !GoUnicode.is(ParityXMLNameTables.first, c) && (first || !GoUnicode.is(ParityXMLNameTables.second, c)) {
                return false
            }
            first = false
            i += n
        }
        return true
    }

    /// Decoder.readName: appends a name's bytes to buf, up to a single-byte character no name holds.
    private mutating func readName() -> Bool {
        guard let b = mustgetc() else { return false }
        if b < 0x80 && !Self.isNameByte(b) {
            ungetc()
            return false
        }
        buf.append(b)
        while true {
            guard let c = mustgetc() else { return false }
            if c < 0x80 && !Self.isNameByte(c) {
                ungetc()
                break
            }
            buf.append(c)
        }
        return true
    }

    private static func isNameByte(_ c: UInt8) -> Bool {
        c >= 0x41 && c <= 0x5A || c >= 0x61 && c <= 0x7A || c >= 0x30 && c <= 0x39
            || c == UInt8(ascii: "_") || c == UInt8(ascii: ":") || c == UInt8(ascii: ".") || c == UInt8(ascii: "-")
    }

    /// procInst: the `param="…"` or `param='…'` value of a processing instruction, or "".
    static func procInst(_ param: [UInt8], _ s: ArraySlice<UInt8>) -> [UInt8] {
        let s = Array(s)
        let param = param + [UInt8(ascii: "=")]
        var i = 0
        var sep: UInt8 = 0
        while i < s.count {
            // Searched in place, as Go slices the string (copying the rest for every "param=" is quadratic).
            guard let k = ParityDecode.firstIndex(of: param, in: s, from: i), k + param.count < s.count else { return [] }
            i = k + param.count + 1
            let c = s[k + param.count]
            if c == UInt8(ascii: "'") || c == UInt8(ascii: "\"") {
                sep = c
                break
            }
        }
        if sep == 0 { return [] }
        guard let j = s[i...].firstIndex(of: sep) else { return [] }
        return Array(s[i..<j])
    }
}

// How Android turns a downloaded feed file into characters (the server's decode.go): FeedHandler and TypeGetter read
// through commons-io XmlStreamReader (lenient), which picks the encoding from the byte-order mark, the first bytes
// and the XML declaration, and decodes with InputStreamReader (malformed input becomes U+FFFD). Other charsets are
// golang.org/x/text's, as the server resolves them (ParityCharset).

enum ParityDecode {
    private static let byteOrderMarks: [([UInt8], String)] = [
        // BOMInputStream tries the longest marks first.
        ([0x00, 0x00, 0xFE, 0xFF], "UTF-32BE"), ([0xFF, 0xFE, 0x00, 0x00], "UTF-32LE"),
        ([0xEF, 0xBB, 0xBF], "UTF-8"), ([0xFE, 0xFF], "UTF-16BE"), ([0xFF, 0xFE], "UTF-16LE")
    ]

    private static let guesses: [([UInt8], String)] = [
        ([0x3C, 0x3F, 0x78, 0x6D], "UTF-8"), ([0x00, 0x3C, 0x00, 0x3F], "UTF-16BE"), ([0x3C, 0x00, 0x3F, 0x00], "UTF-16LE"),
        ([0, 0, 0, 0x3C, 0, 0, 0, 0x3F, 0, 0, 0, 0x78, 0, 0, 0, 0x6D], "UTF-32BE"),
        ([0x3C, 0, 0, 0, 0x3F, 0, 0, 0, 0x78, 0, 0, 0, 0x6D, 0, 0, 0], "UTF-32LE"),
        ([0x4C, 0x6F, 0xA7, 0x94], "CP1047")
    ]

    /// XmlStreamReader's detection and decoding: the document's text as UTF-8, or nil where XmlStreamReader fails
    /// (an unknown declared charset, or a declaration whose end it cannot find). Decoding counts its steps against the
    /// parse's cancellation, if any.
    static func decodeDocument(_ data: [UInt8], work: ParityCancellation? = nil) throws -> [UInt8]? {
        var bom = ""
        var body = data[...]
        for (mark, encoding) in byteOrderMarks where data.starts(with: mark) {
            bom = encoding
            body = data[mark.count...]
            break
        }
        var guess = ""
        for (start, encoding) in guesses where body.starts(with: start) {
            guess = encoding
            break
        }
        guard let declared = try declaredEncoding(body, guess: guess) else { return nil }
        let encoding: String
        switch bom {
        case "":
            if guess.isEmpty || declared.isEmpty {
                encoding = "UTF-8"
            } else if declared == "UTF-16" && (guess == "UTF-16BE" || guess == "UTF-16LE") {
                encoding = guess
            } else {
                encoding = declared
            }
        case "UTF-8":
            // A conflicting guess or declaration throws; lenient detection falls back to the declared encoding.
            if (!guess.isEmpty && guess != "UTF-8") || (!declared.isEmpty && !GoStrings.same(declared, "UTF-8")) {
                encoding = declared.isEmpty ? "UTF-8" : declared
            } else {
                encoding = "UTF-8"
            }
        case "UTF-16BE", "UTF-16LE":
            if (!guess.isEmpty && guess != bom)
                || (!declared.isEmpty && !GoStrings.same(declared, "UTF-16") && !GoStrings.same(declared, bom)) {
                encoding = declared.isEmpty ? "UTF-8" : declared
            } else {
                encoding = bom
            }
        default:
            encoding = declared.isEmpty ? "UTF-8" : declared
        }
        return try decodeCharset(body, name: encoding, work: work)
    }

    /// XmlStreamReader.getXmlProlog: the declaration up to the first '>' within 4096 bytes read with the guessed
    /// encoding, its encoding attribute upper-cased; "" without one; nil where XmlStreamReader fails.
    static func declaredEncoding(_ body: ArraySlice<UInt8>, guess: String) throws -> String? {
        guard !guess.isEmpty else { return "" }
        guard let text = try decodeCharset(body.prefix(4096), name: guess), let end = text.firstIndex(of: UInt8(ascii: ">"))
        else { return nil }
        let prolog = text[...end].filter { $0 != 0x0A && $0 != 0x0D }
        guard let value = prologEncoding(prolog) else { return "" }
        return GoStrings.toUpper(GoStrings.string(value))
    }

    /// The first group of `<\?xml.*encoding[\s]*=[\s]*((?:".[^"]*")|(?:'.[^']*'))` (Go's leftmost-first matching:
    /// the first "<?xml", then the last "encoding" after it that the rest matches), without its quotes.
    static func prologEncoding(_ s: [UInt8]) -> ArraySlice<UInt8>? {
        let xml = Array("<?xml".utf8)
        let encoding = Array("encoding".utf8)
        guard let start = firstIndex(of: xml, in: s, from: 0) else { return nil }
        func space(_ c: UInt8) -> Bool { c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20 }
        var position = s.count - encoding.count
        while position >= start + xml.count {
            defer { position -= 1 }
            guard s[position..<(position + encoding.count)].elementsEqual(encoding) else { continue }
            var i = position + encoding.count
            while i < s.count && space(s[i]) { i += 1 }
            guard i < s.count, s[i] == UInt8(ascii: "=") else { continue }
            i += 1
            while i < s.count && space(s[i]) { i += 1 }
            guard i < s.count, s[i] == UInt8(ascii: "\"") || s[i] == UInt8(ascii: "'") else { continue }
            let quote = s[i]
            // The quote, any one character (a UTF-8 sequence; no newline is left), then up to the next quote.
            let (_, width) = GoStrings.decodeRune(s[...], i + 1 < s.count ? i + 1 : i)
            guard i + 1 < s.count else { continue }
            var j = i + 1 + width
            while j < s.count && s[j] != quote { j += 1 }
            guard j < s.count else { continue }
            return s[(i + 1)..<j]
        }
        return nil
    }

    static func firstIndex(of needle: [UInt8], in s: [UInt8], from: Int) -> Int? {
        guard needle.count <= s.count else { return nil }
        var i = from
        while i + needle.count <= s.count {
            if s[i] == needle[0] && s[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    /// InputStreamReader with a Java charset name: malformed input becomes U+FFFD; nil for an unknown charset.
    static func decodeCharset(_ b: ArraySlice<UInt8>, name: String, work: ParityCancellation? = nil) throws -> [UInt8]? {
        let upper = GoStrings.toUpper(name)
        switch upper {
        case _ where GoStrings.same(upper, "UTF-8") || GoStrings.same(upper, "UTF8"):
            return try decodeUTF8(b, work: work)
        case _ where GoStrings.same(upper, "UTF-16BE") || GoStrings.same(upper, "UTF-16LE") || GoStrings.same(upper, "UTF-16"):
            var little = GoStrings.same(upper, "UTF-16LE")
            var b = b
            if GoStrings.same(upper, "UTF-16") && b.count >= 2 {
                // Java's UTF-16 honours a leading mark and otherwise reads big-endian.
                if b[b.startIndex] == 0xFF && b[b.startIndex + 1] == 0xFE {
                    little = true
                    b = b.dropFirst(2)
                } else if b[b.startIndex] == 0xFE && b[b.startIndex + 1] == 0xFF {
                    b = b.dropFirst(2)
                }
            }
            var units: [UInt16] = []
            units.reserveCapacity(b.count / 2)
            var i = b.startIndex
            while i + 1 < b.endIndex {
                try work?.tick(2)
                units.append(little ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : UInt16(b[i]) << 8 | UInt16(b[i + 1]))
                i += 2
            }
            var out = try utf8(fromUTF16: units, work: work)
            if b.count % 2 == 1 { GoStrings.appendRune(&out, 0xFFFD) }
            return out
        case _ where GoStrings.same(upper, "UTF-32BE") || GoStrings.same(upper, "UTF-32LE") || GoStrings.same(upper, "UTF-32"):
            let little = GoStrings.same(upper, "UTF-32LE")
            var out: [UInt8] = []
            out.reserveCapacity(b.count)
            var i = b.startIndex
            while i + 3 < b.endIndex {
                try work?.tick(4)
                let r: UInt32 = little
                    ? UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
                    : UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
                GoStrings.appendRune(&out, r)
                i += 4
            }
            if b.count % 4 != 0 { GoStrings.appendRune(&out, 0xFFFD) }
            return out
        default:
            return try ParityCharset.lookup(name)?.decode(b, work: work)
        }
    }

    /// utf16.Decode to UTF-8: an unpaired surrogate is U+FFFD.
    static func utf8(fromUTF16 units: some Collection<UInt16>, work: ParityCancellation? = nil) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(units.count)
        var i = units.startIndex
        while i < units.endIndex {
            try work?.tick()
            let c = units[i]
            units.formIndex(after: &i)
            if c < 0x80 {
                out.append(UInt8(c))
            } else if c >= 0xD800 && c < 0xDC00, i < units.endIndex, units[i] >= 0xDC00 && units[i] < 0xE000 {
                GoStrings.appendRune(&out, 0x10000 + (UInt32(c) - 0xD800) << 10 + (UInt32(units[i]) - 0xDC00))
                units.formIndex(after: &i)
            } else {
                GoStrings.appendRune(&out, UInt32(c))  // a lone surrogate becomes U+FFFD
            }
        }
        return out
    }

    /// Bytes decoded as UTF-8 the way Android's (ICU) decoder does: each maximal subpart of an ill-formed sequence
    /// (Unicode 3.9) becomes one U+FFFD. Valid text is checked in steps of the parse's cancellation interval.
    static func decodeUTF8(_ b: ArraySlice<UInt8>, work: ParityCancellation? = nil) throws -> [UInt8] {
        if try isValidUTF8(b, work: work) { return Array(b) }
        var out: [UInt8] = []
        out.reserveCapacity(b.count + 16)
        var i = b.startIndex
        while i < b.endIndex {
            try work?.tick()
            let c = b[i]
            if c < 0x80 {
                out.append(c)
                i += 1
                continue
            }
            // The sequence's length and its second byte's range (Unicode Table 3-7).
            var n = 0
            var lo: UInt8 = 0x80
            var hi: UInt8 = 0xBF
            switch c {
            case 0xC2...0xDF: n = 2
            case 0xE0: n = 3; lo = 0xA0
            case 0xE1...0xEC, 0xEE, 0xEF: n = 3
            case 0xED: n = 3; hi = 0x9F
            case 0xF0: n = 4; lo = 0x90
            case 0xF1...0xF3: n = 4
            case 0xF4: n = 4; hi = 0x8F
            default: break
            }
            var k = 1
            while n > 0 && k < n && i + k < b.endIndex {
                let x = b[i + k]
                if k == 1 && (x < lo || x > hi) || k > 1 && (x < 0x80 || x > 0xBF) { break }
                k += 1
            }
            if n > 0 && k == n {
                out.append(contentsOf: b[i..<(i + n)])
            } else {
                GoStrings.appendRune(&out, 0xFFFD)
            }
            i += k
        }
        return out
    }

    /// Whether b is UTF-8, checked in chunks that end before a character's continuation bytes, each counted.
    private static func isValidUTF8(_ b: ArraySlice<UInt8>, work: ParityCancellation?) throws -> Bool {
        guard let work else { return String(validating: b, as: UTF8.self) != nil }
        var start = b.startIndex
        while start < b.endIndex {
            var end = min(b.endIndex, start + ParityCancellation.interval)
            // A chunk ends before a continuation byte (at most three steps back), so no character is split.
            while end < b.endIndex && end > start && b[end] & 0xC0 == 0x80 { end -= 1 }
            if end == start { end = min(b.endIndex, start + ParityCancellation.interval) }
            try work.tick(end - start)
            if String(validating: b[start..<end], as: UTF8.self) == nil { return false }
            start = end
        }
        return true
    }
}

/// A Java charset name resolved as the server's `charset` does: golang.org/x/text's ianaindex (the name as given,
/// then lower-cased), then its htmlindex (WHATWG labels).
struct ParityCharset {
    enum Kind: Int {
        case charmap, ascii, utf8, utf16BEUseBOM, utf16BEIgnoreBOM, utf16LEIgnoreBOM, utf16BEExpectBOM, utf16LEUseBOM,
             utf16LEExpectBOM, eucJP, iso2022JP, shiftJIS, eucKR, gbk, gb18030, hzGB2312, big5, replacement
    }

    let kind: Kind
    let name: String
    let charmap: [UInt32]

    private static let encodings: [ParityCharset] = ParityCharsetTables.encodings.map {
        ParityCharset(kind: Kind(rawValue: $0.kind)!, name: $0.name, charmap: $0.charmap)
    }
    private static let iana: [[UInt8]: Int] = Dictionary(ParityCharsetTables.ianaAliases.map { (Array($0.0.utf8), $0.1) },
                                                         uniquingKeysWith: { first, _ in first })
    private static let html: [[UInt8]: Int] = Dictionary(ParityCharsetTables.htmlLabels.map { (Array($0.0.utf8), $0.1) },
                                                         uniquingKeysWith: { first, _ in first })

    static func lookup(_ name: String) -> ParityCharset? {
        let trimmed = GoStrings.trimSpace(name)
        if let index = iana[Array(trimmed.utf8)] ?? iana[Array(GoStrings.toLower(trimmed).utf8)] { return encodings[index] }
        if let index = html[Array(GoStrings.toLower(trimmed).utf8)] { return encodings[index] }
        return nil
    }

    /// The decoder's output as UTF-8, or nil where it fails. Its steps are counted against the parse's cancellation.
    func decode(_ b: ArraySlice<UInt8>, work: ParityCancellation? = nil) throws -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(b.count + 16)
        switch kind {
        case .charmap:
            for c in b {
                try work?.tick()
                GoStrings.appendRune(&out, charmap[Int(c)])
            }
        case .ascii:
            for c in b {
                try work?.tick()
                if c < 0x80 { out.append(c) } else { GoStrings.appendRune(&out, 0xFFFD) }
            }
        case .utf8:
            return try ParityDecode.decodeUTF8(b, work: work)
        case .utf16BEUseBOM, .utf16BEIgnoreBOM, .utf16LEIgnoreBOM, .utf16BEExpectBOM, .utf16LEUseBOM, .utf16LEExpectBOM:
            return try decodeUTF16(b, work: work)
        case .replacement:
            GoStrings.appendRune(&out, 0xFFFD)
        case .eucJP, .iso2022JP, .shiftJIS, .eucKR, .gbk, .gb18030, .hzGB2312, .big5:
            return try ParityCJK.decode(b, kind: kind, work: work)
        }
        return out
    }

    /// x/text's utf16Decoder.
    private func decodeUTF16(_ src: ArraySlice<UInt8>, work: ParityCancellation?) throws -> [UInt8]? {
        var little = kind == .utf16LEIgnoreBOM || kind == .utf16LEUseBOM || kind == .utf16LEExpectBOM
        let accept = kind != .utf16BEIgnoreBOM && kind != .utf16LEIgnoreBOM
        let require = kind == .utf16BEExpectBOM || kind == .utf16LEExpectBOM
        if src.count < 2 && require { return nil }
        var out: [UInt8] = []
        if src.isEmpty { return out }
        var i = src.startIndex
        if src.count >= 2 && accept {
            if src[i] == 0xFE && src[i + 1] == 0xFF {
                little = false
                i += 2
            } else if src[i] == 0xFF && src[i + 1] == 0xFE {
                little = true
                i += 2
            } else if require {
                return nil
            }
        }
        func unit(_ k: Int) -> UInt32 {
            let x = UInt32(src[k]) << 8 | UInt32(src[k + 1])
            return little ? (x >> 8 | x << 8) & 0xFFFF : x
        }
        out.reserveCapacity(src.count)
        while i < src.endIndex {
            try work?.tick()
            var r: UInt32
            var size = 2
            if i + 1 < src.endIndex {
                r = unit(i)
                if r >= 0xD800 && r <= 0xDFFF, i + 3 < src.endIndex {
                    let x = unit(i + 2)
                    if x >= 0xDC00 && x <= 0xDFFF {
                        // utf16.DecodeRune: U+FFFD unless r starts a pair.
                        r = r < 0xDC00 ? 0x10000 + (r - 0xD800) << 10 + (x - 0xDC00) : 0xFFFD
                        size = 4
                    }
                }
            } else {
                r = 0xFFFD  // a single trailing byte
                size = 1
            }
            GoStrings.appendRune(&out, r)
            i += size
        }
        return out
    }
}

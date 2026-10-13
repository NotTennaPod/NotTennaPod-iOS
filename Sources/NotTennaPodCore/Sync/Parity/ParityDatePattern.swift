// DateUtils' date patterns and how one is matched against a text.
//
// A pattern is a list of tokens: a run of one ASCII letter is a field, text in single quotes and any other character
// a literal. Matching runs left to right from where the text starts. A literal must be there unit for unit. A field
// first skips blanks (space, tab) and fails at the end of the text; numbers are read where the blanks end, names
// (weekday, month) only where they began. No field has a width: each reads as far as its number goes.

/// A compiled date pattern.
struct DatePattern {
    enum Token {
        case literal([UInt16])
        case field(letter: UInt8, count: Int)
    }

    let text: String
    let tokens: [Token]

    init(_ s: String) {
        text = s
        let bytes = Array(s.utf8)
        var tokens: [Token] = []
        func literal(_ c: UInt8) {
            if case .literal(let units)? = tokens.last {
                tokens[tokens.count - 1] = .literal(units + [UInt16(c)])
            } else {
                tokens.append(.literal([UInt16(c)]))
            }
        }
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) {
                var j = i
                while j < bytes.count && bytes[j] == c { j += 1 }
                tokens.append(.field(letter: c, count: j - i))
                i = j
            } else if c == 0x27 {
                var j = i + 1
                while j < bytes.count && bytes[j] != 0x27 {
                    literal(bytes[j])
                    j += 1
                }
                i = j + 1
            } else {
                literal(c)
                i += 1
            }
        }
        self.tokens = tokens
    }

    /// Tried first, leniently, on the text as given.
    static let rfc822 = DatePattern("EEE, dd MMM yyyy HH:mm:ss Z")

    /// DateUtils' fallback patterns, tried in order, strictly. A shadowed pattern reads exactly what an earlier one
    /// reads (EEE and EEEE, MMM and MMMM parse alike), so it can never answer and is skipped.
    static let fallbacks: [(pattern: DatePattern, shadowed: Bool)] = [
        (DatePattern("dd MMM yy HH:mm:ss Z"), false),                // F0
        (DatePattern("dd MMM yy HH:mm Z"), false),                   // F1
        (DatePattern("EEE, dd MMM yyyy HH:mm:ss Z"), false),         // F2
        (DatePattern("EEE, dd MMM yyyy HH:mm:ss"), false),           // F3
        (DatePattern("EEE, dd MMMM yyyy HH:mm:ss Z"), true),         // F4, as F2
        (DatePattern("EEE, dd MMMM yyyy HH:mm:ss"), true),           // F5, as F3
        (DatePattern("EEEE, dd MMM yyyy HH:mm:ss Z"), true),         // F6, as F2
        (DatePattern("EEEE, dd MMM yy HH:mm:ss Z"), false),          // F7
        (DatePattern("EEEE, dd MMM yyyy HH:mm:ss"), true),           // F8, as F3
        (DatePattern("EEEE, dd MMM yy HH:mm:ss"), false),            // F9
        (DatePattern("EEE MMM d HH:mm:ss yyyy"), false),             // F10
        (DatePattern("EEE, dd MMM yyyy HH:mm Z"), false),            // F11
        (DatePattern("EEE, dd MMM yyyy HH:mm"), false),              // F12
        (DatePattern("EEE, dd MMMM yyyy HH:mm Z"), true),            // F13, as F11
        (DatePattern("EEE, dd MMMM yyyy HH:mm"), true),              // F14, as F12
        (DatePattern("EEEE, dd MMM yyyy HH:mm Z"), true),            // F15, as F11
        (DatePattern("EEEE, dd MMM yy HH:mm Z"), false),             // F16
        (DatePattern("EEEE, dd MMM yyyy HH:mm"), true),              // F17, as F12
        (DatePattern("EEEE, dd MMM yy HH:mm"), false),               // F18
        (DatePattern("EEE MMM d HH:mm yyyy"), false),                // F19
        (DatePattern("yyyy-MM-dd'T'HH:mm:ss"), false),               // F20
        (DatePattern("yyyy-MM-dd'T'HH:mm:ss.SSS Z"), false),         // F21
        (DatePattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"), false),        // F22
        (DatePattern("yyyy-MM-dd'T'HH:mm:ss.SSS"), false),           // F23
        (DatePattern("yyyy-MM-dd'T'HH:mm:ssZ"), false),              // F24
        (DatePattern("yyyy-MM-dd'T'HH:mm:ss'Z'"), false),            // F25
        (DatePattern("yyyy-MM-dd'T'HH:mm:ss.SSSZ"), false),          // F26
        (DatePattern("yyyy-MM-ddZ"), false),                         // F27
        (DatePattern("yyyy-MM-dd"), false),                          // F28
        (DatePattern("EEE d MMM yyyy HH:mm:ss 'GMT'Z (z)"), false)   // F29
    ]

    /// The Locale.US names as UTF-16, Sunday and January first.
    static let weekdays = ParityDateTables.weekdays.dropFirst().map { Array($0.utf16) }
    static let shortWeekdays = ParityDateTables.shortWeekdays.dropFirst().map { Array($0.utf16) }
    static let months = ParityDateTables.months.map { Array($0.utf16) }
    static let shortMonths = ParityDateTables.shortMonths.map { Array($0.utf16) }
    static let gmt = Array("GMT".utf16)
}

extension DateParser {
    /// The RFC 822 pattern, leniently, on the date as given; text after it is ignored.
    func rfc822(_ t: [UInt16]) throws -> Int64? {
        try match(DatePattern.rfc822, t, from: 0, lenient: true)?.instant
    }

    /// The fallback patterns, strictly, on t[start...]: the answer of the first that reads all of it.
    func fallback(_ t: [UInt16], from start: Int) throws -> Int64? {
        for (pattern, shadowed) in DatePattern.fallbacks where !shadowed {
            if let (ms, end) = try match(pattern, t, from: start, lenient: false), end == t.count { return ms }
        }
        return nil
    }

    /// Matches a pattern from t[start] and resolves its fields: the instant and where the pattern ended, or nil.
    func match(_ pattern: DatePattern, _ t: [UInt16], from start: Int, lenient: Bool) throws -> (instant: Int64, end: Int)? {
        var f = DateFields()
        var pos = start
        for token in pattern.tokens {
            switch token {
            case .literal(let units):
                guard t.count - pos >= units.count, t[pos..<(pos + units.count)].elementsEqual(units) else { return nil }
                pos += units.count
            case .field(let letter, let count):
                let blanksStart = pos
                while pos < t.count && DateCharacters.isBlank(t[pos]) {
                    try work.step()
                    pos += 1
                }
                if pos == t.count { return nil }
                let end: Int?
                switch letter {
                case UInt8(ascii: "E"):
                    end = Self.matchName(t, blanksStart, pos, DatePattern.weekdays, DatePattern.shortWeekdays).map {
                        f.record(.weekday, Int64($0.index + 1))
                        return $0.end
                    }
                case UInt8(ascii: "M") where count >= 3:
                    end = Self.matchName(t, blanksStart, pos, DatePattern.months, DatePattern.shortMonths).map {
                        f.record(.month, Int64($0.index))
                        return $0.end
                    }
                case UInt8(ascii: "M"), UInt8(ascii: "y"), UInt8(ascii: "d"), UInt8(ascii: "H"), UInt8(ascii: "m"),
                     UInt8(ascii: "s"), UInt8(ascii: "S"):
                    end = try numericField(t, pos, letter: letter, count: count, &f)
                case UInt8(ascii: "Z"), UInt8(ascii: "z"):
                    end = try zoneField(t, blanksStart, pos, &f)
                default:
                    preconditionFailure("unsupported date pattern letter \(letter)")
                }
                guard let end else { return nil }
                pos = end
            }
        }
        guard var ms = resolve(f, lenient: lenient) else { return nil }
        if f.ambiguousYear && ms < yearWindow.start {
            // The year of a two-digit value equal to the window's start year is a century later when the date falls
            // before the window.
            f[.year] = f[.year] &+ 100
            guard let later = resolve(f, lenient: lenient) else { return nil }
            ms = later
        }
        return (ms, pos)
    }

    /// Reads a numeric field's number at pos and records it: where it ended, or nil.
    private func numericField(_ t: [UInt16], _ pos: Int, letter: UInt8, count: Int, _ f: inout DateFields) throws -> Int? {
        guard let (n, end) = try readNumber(t, at: pos) else { return nil }
        switch letter {
        case UInt8(ascii: "y"):
            let year = n.int32
            if count <= 2 && end - pos == 2 && DateCharacters.isUnitDigit(t[pos]) && DateCharacters.isUnitDigit(t[pos + 1]) {
                let window = yearWindow
                let v = Int64(year)
                var y = window.base &+ v
                if v < window.ambiguous { y = y &+ 100 }
                f.record(.year, Int64(Int32(truncatingIfNeeded: y)))
                f.ambiguousYear = v == window.ambiguous
            } else {
                f.record(.year, Int64(year))
            }
        case UInt8(ascii: "M"): f.record(.month, Int64(n.int32) - 1)
        case UInt8(ascii: "d"): f.record(.day, Int64(n.int32))
        case UInt8(ascii: "H"): f.record(.hour, Int64(n.int32))
        case UInt8(ascii: "m"): f.record(.minute, Int64(n.int32))
        case UInt8(ascii: "s"): f.record(.second, Int64(n.int32))
        default: f.record(.millis, Int64(n.fraction(width: end - pos)))
        }
        return end
    }

    /// A weekday or month name at start (where the field's blanks began; a skipped blank makes it fail): the longest of
    /// the long names, else the longest of the short ones, unit by unit ignoring case. The name's index and its end.
    private static func matchName(_ t: [UInt16], _ start: Int, _ pos: Int, _ long: [[UInt16]],
                                  _ short: [[UInt16]]) -> (index: Int, end: Int)? {
        guard pos == start else { return nil }
        for names in [long, short] {
            var best = -1
            var bestLength = 0
            for (i, name) in names.enumerated()
            where name.count > bestLength && t.count - start >= name.count && nameAt(t, start, name) {
                best = i
                bestLength = name.count
            }
            if best >= 0 { return (best, start + bestLength) }
        }
        return nil
    }

    /// Whether an ASCII name is at t[at...], ignoring case (the caller checks the length).
    private static func nameAt(_ t: [UInt16], _ at: Int, _ name: [UInt16]) -> Bool {
        for (i, c) in name.enumerated() where !DateCharacters.unitsMatchIgnoringCase(t[at + i], c) { return false }
        return true
    }

    /// A zone (Z or z) at pos: a numeric offset, GMT with or without one, or a zone name. Where it ended, or nil.
    private func zoneField(_ t: [UInt16], _ start: Int, _ pos: Int, _ f: inout DateFields) throws -> Int? {
        let c = t[pos]
        if c == 0x2B || c == 0x2D { return Self.readOffset(t, sign: pos, &f) }
        if (c == 0x47 || c == 0x67) && t.count - start >= 3 && Self.nameAt(t, start, DatePattern.gmt) {
            // GMT is looked for where the blanks began: after a blank, "GMT" is read as a zone name instead.
            let q = start + 3
            if q < t.count && (t[q] == 0x2B || t[q] == 0x2D) { return Self.readOffset(t, sign: q, &f) }
            f.record(.zoneOffset, 0)
            f.record(.dstOffset, 0)
            return q
        }
        return zoneName(t, pos, &f)
    }

    /// [+-]H[H][:]MM after the sign at t[sign], ASCII digits only, hours up to 23 and minutes up to 59.
    private static func readOffset(_ t: [UInt16], sign: Int, _ f: inout DateFields) -> Int? {
        func digit(_ i: Int) -> Int64? {
            i < t.count && t[i] >= 0x30 && t[i] <= 0x39 ? Int64(t[i] - 0x30) : nil
        }
        var i = sign + 1
        guard var hours = digit(i) else { return nil }
        i += 1
        if let d = digit(i) {
            hours = hours * 10 + d
            i += 1
        }
        if hours > 23 { return nil }
        if i < t.count && t[i] == 0x3A { i += 1 }
        guard let tens = digit(i), let ones = digit(i + 1), tens * 10 + ones <= 59 else { return nil }
        var ms = (hours * 60 + tens * 10 + ones) * 60_000
        if t[sign] == 0x2D { ms = -ms }
        f.record(.zoneOffset, ms)
        f.record(.dstOffset, 0)
        return i + 2
    }

    /// The longest zone name at pos, code point by code point under simple case folding, resolved to a zone: its own,
    /// or for a metazone name the zone an earlier name chose if it has used that metazone, else the metazone's
    /// reference zone. Where it ended, or nil.
    private func zoneName(_ t: [UInt16], _ pos: Int, _ f: inout DateFields) -> Int? {
        let maxRunes = ParityDates.Zone.nameMaxRunes
        var keys: [UInt32] = []
        var ends: [Int] = []
        keys.reserveCapacity(maxRunes)
        ends.reserveCapacity(maxRunes)
        var i = pos
        while i < t.count && keys.count < maxRunes {
            let (r, size) = DateCharacters.rune(t, at: i)
            i += size
            keys.append(DateCharacters.foldKey(r))
            ends.append(i)
        }
        var best = -1
        var bestEnd = 0
        for (index, name) in ParityDates.Zone.nameKeys.enumerated()
        where name.count <= keys.count && keys[..<name.count].elementsEqual(name) && ends[name.count - 1] > bestEnd {
            best = index
            bestEnd = ends[name.count - 1]
        }
        guard best >= 0 else { return nil }
        let (_, daylight, ownZone, metaZone) = ParityDateTables.zoneNames[best]
        var id = ownZone
        if id.isEmpty {
            let current = f.zone?.id ?? "Etc/GMT"
            id = ParityDateTables.metaZoneRefs[metaZone] ?? ""
            if ParityDateTables.zoneMetaZones[current]?.contains(metaZone) == true { id = current }
        }
        guard let zone = ParityDates.Zone.byID[id] else { return nil }
        f.zone = zone
        if !daylight {
            f.forget(.zoneOffset)
            f.record(.dstOffset, 0)
        } else {
            let saving = zone.savings(now: now)
            if saving != 0 {
                f.forget(.zoneOffset)
                f.record(.dstOffset, saving)
            }
        }
        return bestEnd
    }
}

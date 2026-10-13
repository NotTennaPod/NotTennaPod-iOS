// DateUtils' clean-up of a date before its fallback patterns, and the test for a leading weekday-like word. Each step
// returns its input unchanged or a new array.

extension DateParser {
    /// Every clean-up step, in DateUtils' order.
    func normalize(_ input: [UInt16]) throws -> [UInt16] {
        var t = try trim(input)
        t = try slashToHyphen(t)
        t = try collapseSpaces(t)
        t = try dropZoneColon(t)
        t = Self.replaceAtEnd(t, Self.cest, with: Self.plus0200)
        t = Self.replaceAtEnd(t, Self.cet, with: Self.plus0100)
        t = try septToSep(t)
        return try fractionToMillis(t)
    }

    private static let cest = Array("CEST".utf16)
    private static let cet = Array("CET".utf16)
    private static let plus0200 = Array("+0200".utf16)
    private static let plus0100 = Array("+0100".utf16)

    /// Drops leading and trailing units up to U+0020, as String.trim.
    func trim(_ t: [UInt16]) throws -> [UInt16] {
        var i = 0
        var j = t.count
        while i < j && t[i] <= 0x20 {
            try work.step()
            i += 1
        }
        while j > i && t[j - 1] <= 0x20 {
            try work.step()
            j -= 1
        }
        return i == 0 && j == t.count ? t : Array(t[i..<j])
    }

    /// Replaces every '/' with '-'.
    func slashToHyphen(_ t: [UInt16]) throws -> [UInt16] {
        var out = t
        for (i, c) in t.enumerated() {
            try work.step()
            if c == 0x2F { out[i] = 0x2D }
        }
        return out
    }

    /// Replaces each run of U+0020 with one.
    func collapseSpaces(_ t: [UInt16]) throws -> [UInt16] {
        var out: [UInt16]?
        for (i, c) in t.enumerated() {
            try work.step()
            if c == 0x20 && i > 0 && t[i - 1] == 0x20 {
                if out == nil { out = Array(t[..<i]) }
                continue
            }
            out?.append(c)
        }
        return out ?? t
    }

    /// Where a pattern anchored at the end ($) may end: the end, or before a final line terminator.
    static func textEnd(_ t: [UInt16]) -> Int {
        if let last = t.last, DateCharacters.isLineTerminator(last) { return t.count - 1 }
        return t.count
    }

    /// Removes the colon of a final [+-]DD:DD, D any decimal digit. Read backwards from the end, as only one such
    /// match can end there.
    func dropZoneColon(_ t: [UInt16]) throws -> [UInt16] {
        var i = Self.textEnd(t)
        func digits() throws -> Bool {
            for _ in 0..<2 {
                try work.step()
                let (r, n) = DateCharacters.rune(t, before: i)
                if n == 0 || !DateCharacters.isDigit(r) { return false }
                i -= n
            }
            return true
        }
        guard try digits(), i > 0, t[i - 1] == 0x3A else { return t }
        i -= 1
        let colon = i
        guard try digits(), i > 0, t[i - 1] == 0x2B || t[i - 1] == 0x2D else { return t }
        var out = t
        out.remove(at: colon)
        return out
    }

    /// Replaces a final old (before a final line terminator, if any) with new.
    static func replaceAtEnd(_ t: [UInt16], _ old: [UInt16], with new: [UInt16]) -> [UInt16] {
        let end = textEnd(t)
        let at = end - old.count
        guard at >= 0, t[at..<end].elementsEqual(old) else { return t }
        var out = t
        out.replaceSubrange(at..<end, with: new)
        return out
    }

    /// Replaces each word "Sept" with "Sep" (\bSept\b), left to right.
    func septToSep(_ t: [UInt16]) throws -> [UInt16] {
        var out: [UInt16] = []
        var changed = false
        var last = 0
        var i = 0
        while i + 4 <= t.count {
            try work.step()
            if t[i] == 0x53 && t[i + 1] == 0x65 && t[i + 2] == 0x70 && t[i + 3] == 0x74,
               try wordBoundary(t, i), try wordBoundary(t, i + 4) {
                out.append(contentsOf: t[last..<i])
                out.append(contentsOf: [0x53, 0x65, 0x70])
                changed = true
                last = i + 4
                i += 4
            } else {
                i += 1
            }
        }
        guard changed else { return t }
        out.append(contentsOf: t[last...])
        return out
    }

    /// An ICU word boundary (\b) at t[i]: none before a boundary-transparent code point; otherwise one where a word
    /// character meets a non-word character, looking back through transparent ones.
    func wordBoundary(_ t: [UInt16], _ i: Int) throws -> Bool {
        var after = false
        if i < t.count {
            let (r, _) = DateCharacters.rune(t, at: i)
            if DateCharacters.isBoundaryTransparent(r) { return false }
            after = DateCharacters.isWord(r)
        }
        var before = false
        var j = i
        while j > 0 {
            try work.step()
            let (r, n) = DateCharacters.rune(t, before: j)
            j -= n
            if !DateCharacters.isBoundaryTransparent(r) {
                before = DateCharacters.isWord(r)
                break
            }
        }
        return after != before
    }

    /// Makes the digits after the first '.' three: more are cut, fewer padded with '0'. As in DateUtils, the text
    /// after the digits is kept only when it is longer than one unit.
    func fractionToMillis(_ t: [UInt16]) throws -> [UInt16] {
        var dot = -1
        for (i, c) in t.enumerated() {
            try work.step()
            if c == 0x2E {
                dot = i
                break
            }
        }
        if dot < 0 { return t }
        var end = dot + 1
        while end < t.count && DateCharacters.isUnitDigit(t[end]) {
            try work.step()
            end += 1
        }
        let n = end - dot - 1
        if n == 3 { return t }
        var out: [UInt16]
        if n > 3 {
            out = Array(t[..<(dot + 4)])
        } else {
            out = Array(t[..<end])
            out.append(contentsOf: repeatElement(0x30, count: 3 - n))
        }
        if end < t.count - 1 { out.append(contentsOf: t[end...]) }
        return out
    }

    /// The index of the last line terminator, or -1.
    func lastLineTerminator(_ t: [UInt16]) throws -> Int {
        var i = t.count - 1
        while i >= 0 {
            try work.step()
            if DateCharacters.isLineTerminator(t[i]) { return i }
            i -= 1
        }
        return -1
    }

    /// Whether t[start...] starts with one or more word characters and ", " (DateUtils' "^\w+, .*$" without its
    /// line-terminator condition): the index of that comma, or nil.
    func weekdayWord(_ t: [UInt16], from start: Int) throws -> Int? {
        var i = start
        while i < t.count {
            let (r, n) = DateCharacters.rune(t, at: i)
            if !DateCharacters.isWord(r) { break }
            try work.step()
            i += n
        }
        guard i > start, i + 1 < t.count, t[i] == 0x2C, t[i + 1] == 0x20 else { return nil }
        return i
    }
}

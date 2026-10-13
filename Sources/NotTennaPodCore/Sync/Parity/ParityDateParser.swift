// Feed dates: RSS <pubDate> and <dc:date>, Atom <published> and <updated>.
//
// They are read as AntennaPod 3.12.1's DateUtils.parse reads them on Android 16, with the Locale.US weekday and month
// names, ICU's English time-zone names and metazones, and the zone rules of Android's tzdata 2025a (all in the
// generated ParityDateTables of ParityTables.swift):
//
//  1. The RFC 822 pattern "EEE, dd MMM yyyy HH:mm:ss Z" on the text as given, leniently: out-of-range fields roll
//     over, the weekday is not checked and text after the zone is ignored.
//  2. Otherwise the text is cleaned up (trimmed, '/' to '-', runs of spaces to one, the colon of a final "+hh:mm"
//     dropped, a final CEST or CET to its offset, the word "Sept" to "Sep", a fraction of a second to three digits)
//     and DateUtils' thirty fallback patterns are tried in order, strictly: every field in range, the weekday right,
//     the whole text read.
//  3. Otherwise, if the text starts with a word followed by ", ", the same again on the text after that comma.
//
// Two-digit years fall in the 100 years starting 80 years before now. A standard zone name means the zone's standard
// time at that date; a daylight name adds the zone's current daylight saving, or follows the zone's rules when it has
// none ahead. Numbers are read as ICU reads integers: any script's decimal digits, Unicode minus signs, exponents, NaN
// and ∞.
//
// Deliberate differences from Android, shared with the server's parser: the two-digit year window is computed in UTC
// on the proleptic Gregorian calendar; numbers too long for an exact integer are converted with Go's
// strconv.ParseFloat (GoFloat); 64-bit overflow wraps; Unicode properties are Go's (GoUnicode); nothing is printed
// for an unparseable date; and step 3 is done in linear time (Android's retry is quadratic in the number of leading
// words) with the same answers.
//
// Text is UTF-16 code units throughout. A date can be as long as the feed's text, so the parse counts its steps
// against the feed parse's ParityCancellation (which asks every 65,536 of them) and asks before each retry of step 3.

enum ParityDates {
    /// DateUtils.parseOrNullIfFuture: the date in milliseconds since the epoch, or nil when it does not parse or is
    /// after now.
    static func parseOrNullIfFuture(_ s: String, now: Int64, cancellation: ParityCancellation? = nil) throws -> Int64? {
        guard let ms = try parse(s, now: now, cancellation: cancellation), ms <= now else { return nil }
        return ms
    }

    /// DateUtils.parse: the date in milliseconds since the epoch, or nil. now (milliseconds) decides two-digit years
    /// and daylight names.
    static func parse(_ s: String, now: Int64, cancellation: ParityCancellation? = nil) throws -> Int64? {
        try parse(units: s.utf16, now: now, cancellation: cancellation)
    }

    /// DateUtils.parse of a date given as UTF-16 code units, which may hold unpaired surrogates.
    static func parse(units: some Sequence<UInt16>, now: Int64, cancellation: ParityCancellation? = nil) throws -> Int64? {
        let work = DateWork(cancellation: cancellation)
        let text = try work.copy(units)
        return try DateParser(work: work, now: now).parse(text)
    }

    /// DateUtils.parse with its weekday retry taken literally: each retry starts again from the RFC 822 pattern on
    /// the cleaned-up text after the first comma, and cleans it up again. Quadratic in the number of leading words;
    /// the reference the linear retry of `parse` is tested against. Never cancelled.
    static func dateUtilsParseRenormalizing(_ s: String, now: Int64) throws -> Int64? {
        try DateParser(work: DateWork(cancellation: nil), now: now).parseRenormalizing(Array(s.utf16))
    }
}

/// A parse's step counting against the feed parse's cancellation; without one it neither counts nor asks.
struct DateWork {
    let cancellation: ParityCancellation?

    /// Counts one unit of input-dependent work.
    @inline(__always) func step() throws { try cancellation?.tick() }

    /// Asks at once.
    func check() throws { try cancellation?.check() }

    /// The units, one step each.
    func copy(_ units: some Sequence<UInt16>) throws -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(units.underestimatedCount)
        for unit in units {
            try step()
            out.append(unit)
        }
        return out
    }
}

/// The state of one parse.
final class DateParser {
    let work: DateWork
    let now: Int64
    /// Where two-digit years fall, computed on first use.
    private var window: DateYearWindow?

    init(work: DateWork, now: Int64) {
        self.work = work
        self.now = now
    }

    /// Where two-digit years fall for this parse's now.
    var yearWindow: DateYearWindow {
        if let window { return window }
        let window = DateYearWindow(now: now)
        self.window = window
        return window
    }

    /// The parse, with the weekday retry done in linear time: every retry reads a suffix of the cleaned-up text.
    func parse(_ input: [UInt16]) throws -> Int64? {
        if let ms = try rfc822(input) { return ms }
        let text = try normalize(input)
        // The weekday word must have no line terminator after it, anywhere: as each retry reads a suffix, the last
        // terminator answers for all.
        let lastBreak = try lastLineTerminator(text)
        var start = 0
        while true {
            if let ms = try fallback(text, from: start) { return ms }
            if lastBreak >= start { return nil }
            guard let comma = try weekdayWord(text, from: start) else { return nil }
            // DateUtils parses the text after the comma from the start. The RFC 822 pattern cannot match it (it
            // starts with a space), and cleaning it up again only trims its start: the fallback patterns on the
            // trimmed suffix give the same answer.
            try work.check()
            start = comma + 1
            while start < text.count && text[start] <= 0x20 {
                try work.step()
                start += 1
            }
        }
    }

    /// The parse with DateUtils' retry as written: every retry from the start, on the text after the first comma.
    func parseRenormalizing(_ input: [UInt16]) throws -> Int64? {
        var input = input
        while true {
            if let ms = try rfc822(input) { return ms }
            let text = try normalize(input)
            if let ms = try fallback(text, from: 0) { return ms }
            guard let comma = try weekdayWord(text, from: 0),
                  !text[(comma + 2)...].contains(where: DateCharacters.isLineTerminator) else { return nil }
            input = Array(text[(comma + 1)...])
        }
    }
}

import Foundation

public enum FeedAddressError: Error, Equatable, Sendable {
    case missingDeeplinkURL
    case malformedURL
}

public enum FeedAddress {
    public static func prepare(_ input: String, base: String? = nil) throws -> String {
        if let base {
            let base = try prepare(base)
            let value = JavaString.trim(input)
            if URLComponents(string: value)?.scheme == nil,
               let scheme = URLComponents(string: base)?.scheme {
                return scheme + ":" + value
            }
            return try prepare(value)
        }
        var value = JavaString.trim(input)
        while true {
            let lower = value.lowercased()
            if let prefix = ["feed://", "pcast://", "pcast:", "itpc://", "antennapod-subscribe://"]
                .first(where: { lower.hasPrefix($0) }) {
                value = JavaString.trim(String(value.dropFirst(prefix.count)))
            } else if lower.contains("antennapod.org/deeplink/subscribe") {
                // Uri.parse(url).getQueryParameter("url"), also for shared text such as ShareUtils'
                // "Title\n\nhttps://antennapod.org/deeplink/subscribe/?url=…".
                guard let encoded = try androidQueryParameter("url", in: value) else { throw FeedAddressError.missingDeeplinkURL }
                guard let first = encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                      let second = first.replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                      second != value else { throw FeedAddressError.malformedURL }
                value = JavaString.trim(second)
            } else if lower.contains("subscribeonandroid.com") {
                guard let range = value.range(of: "((www.)?(subscribeonandroid.com/))", options: .regularExpression)
                else { throw FeedAddressError.malformedURL }
                value.removeSubrange(range)
                value = JavaString.trim(value)
            } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                return value
            } else {
                return "http://" + value
            }
        }
    }

    /// android.net.Uri (StringUri) query lookup on arbitrary text: the scheme separator is the first ':';
    /// the query runs from the first '?' after it to the first '#' after it; segments split at '&', the
    /// key is compared still encoded, and a key without '=' has the empty value. Returns the encoded value,
    /// nil when absent. An opaque text (no '/' after the first ':', e.g. "Show: Part 2\n\nhttps://…")
    /// makes Android's getQueryParameter throw and the app crash; here it is a missing podcast URL.
    static func androidQueryParameter(_ key: String, in text: String) throws -> String? {
        let units = Array(text.utf16)
        let colon = UInt16(UInt8(ascii: ":")), slash = UInt16(UInt8(ascii: "/")), question = UInt16(UInt8(ascii: "?"))
        let hash = UInt16(UInt8(ascii: "#")), ampersand = UInt16(UInt8(ascii: "&")), equals = UInt16(UInt8(ascii: "="))
        let schemeEnd = units.firstIndex(of: colon)
        if let schemeEnd, schemeEnd + 1 == units.count || units[schemeEnd + 1] != slash {
            throw FeedAddressError.missingDeeplinkURL
        }
        let searchStart = schemeEnd ?? 0
        guard let queryStart = units[searchStart...].firstIndex(of: question) else { return nil }
        var queryEnd = units.count
        if let fragment = units[searchStart...].firstIndex(of: hash) {
            guard fragment > queryStart else { return nil }
            queryEnd = fragment
        }
        let query = Array(units[(queryStart + 1)..<queryEnd])
        let wanted = Array(key.utf16)
        var start = 0
        while true {
            let ampersandIndex = query[start...].firstIndex(of: ampersand)
            let end = ampersandIndex ?? query.count
            var separator = query[start...].firstIndex(of: equals) ?? end
            if separator > end { separator = end }
            if separator - start == wanted.count, Array(query[start..<separator]) == wanted {
                return separator == end ? "" : String(decoding: query[(separator + 1)..<end], as: UTF16.self)
            }
            guard let ampersandIndex else { return nil }
            start = ampersandIndex + 1
        }
    }

    public static func equivalent(_ first: String, _ second: String) -> Bool {
        guard let a = URLComponents(string: first), let b = URLComponents(string: second),
              let hostA = a.host, let hostB = b.host else { return first == second }
        func segments(_ components: URLComponents) -> [String] {
            components.percentEncodedPath.split(separator: "/").map {
                ($0.removingPercentEncoding ?? String($0)).lowercased()
            }
        }
        return hostA.lowercased() == hostB.lowercased() && segments(a) == segments(b)
            && (a.query ?? "") == (b.query ?? "")
    }

    static func requestURL(_ source: String) throws -> URL {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else {
            throw FeedAddressError.malformedURL
        }
        return url
    }
}

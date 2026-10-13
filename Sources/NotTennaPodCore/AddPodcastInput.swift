import Foundation

// MARK: - Add podcast inputs (AddFeedFragment)

public enum AddPodcastInput {
    public enum Route: Equatable, Sendable {
        /// The online feed page for this exact text, as a manually entered address.
        case feedPage(String)
        /// The combined search screen; `nil` opens it without submitting.
        case combinedSearch(String?)
    }
    /// `performSearch`: `http[s]?://.*` (whole string, case-sensitive, no line breaks) opens the
    /// feed page; anything else opens the combined search.
    public static func route(_ text: String) -> Route {
        if text.range(of: "\\Ahttps?://.*\\z", options: .regularExpression) != nil { return .feedPage(text) }
        // SearchView does not submit an empty or blank query.
        return .combinedSearch(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text)
    }

    /// `android.util.Patterns.WEB_URL` matched against the whole input, without trimming.
    public static func isValidAddress(_ text: String) -> Bool {
        webURL.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let webURL: NSRegularExpression = {
        // UCS_CHAR without the Unicode spaces, as in Patterns.java (API 36).
        var ucs = "\\x{00A1}-\\x{1FFF}\\x{200B}-\\x{2027}\\x{202A}-\\x{202E}\\x{2030}-\\x{2FFF}\\x{3001}-\\x{D7FF}"
        ucs += "\\x{F900}-\\x{FDCF}\\x{FDF0}-\\x{FFEF}"
        for plane in 1...13 {
            let hex: String = String(plane, radix: 16, uppercase: true)
            ucs += "\\x{\(hex)0000}-\\x{\(hex)FFFD}"
        }
        ucs += "\\x{E1000}-\\x{EFFFD}"
        let label = "a-zA-Z0-9" + ucs, tld = "a-zA-Z" + ucs
        let iriLabel = "[" + label + "](?:[" + label + "_\\-]{0,61}[" + label + "]){0,1}"
        let hostName = "(" + iriLabel + "\\.)+" + "(xn\\-\\-[A-Za-z0-9_\\-]{0,58}[A-Za-z0-9_]|[" + tld + "]{2,63})"
        let octet = "(25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9]|0)"
        let ip = "((25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9])\\." + octet + "\\." + octet
            + "\\.(25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[0-9]))"
        let userChar = "(?:[a-zA-Z0-9\\$\\-\\_\\.\\+\\!\\*\\'\\(\\)\\,\\;\\?\\&\\=]|(?:\\%[a-fA-F0-9]{2}))"
        let userInfo = userChar + "{1,64}(?:\\:" + userChar + "{1,25})?\\@"
        let path = "[/\\?](?:(?:[" + label + ";/\\?:@&=#~\\-\\.\\+!\\*'\\(\\),_\\$])|(?:%[a-fA-F0-9]{2}))*"
        let pattern = "\\A(?:((?:(?i:http|https|rtsp|ftp)://(?:" + userInfo + ")?)?(?:(" + hostName + "|" + ip
            + "))(?:\\:[0-9]{1,5})?)(" + path + ")?(?:\\b|$|^))\\z"
        return try! NSRegularExpression(pattern: pattern)
    }()
}

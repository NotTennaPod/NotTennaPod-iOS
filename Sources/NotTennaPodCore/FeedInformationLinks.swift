import Foundation

/// Linkify.WEB_URLS used by feedinfo.xml's funding text. Ranges are UTF-16,
/// matching Android URLSpan and native attributed strings, not Swift graphemes.
public enum FeedInformationLinks {
    public struct Link: Equatable, Sendable {
        public let range: NSRange
        public let url: String
        public init(range: NSRange, url: String) { self.range = range; self.url = url }
    }
    private static let pattern = try! NSRegularExpression(pattern: FeedInformationLinkPattern.value)
    public static func matches(in text: String) -> [Link] {
        // The Android framework rejects the entire text for these bidi controls.
        guard !text.unicodeScalars.contains(where: { (0x202C...0x202E).contains($0.value) }) else { return [] }
        let value = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: value.length)).compactMap { match in
            let range = match.range
            guard range.location == 0 || value.character(at: range.location - 1) != 64 else { return nil }
            var url = value.substring(with: range)
            let prefixes = ["http://", "https://", "rtsp://", "ftp://"]
            if let prefix = prefixes.first(where: { url.prefix($0.count).uppercased().lowercased() == $0 }) {
                url = prefix + url.dropFirst(prefix.count)
            } else { url = "http://" + url }
            return Link(range: range, url: url)
        }
    }
}

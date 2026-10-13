import Foundation

/// What the Share Extension hands to the app. Android's
/// `OnlineFeedViewActivity` receives SEND `text/plain` as one `EXTRA_TEXT` string; the extension passes
/// that text unchanged through an internal link, and the app opens the text's first link
/// (`ExternalEntry.sharedLink(in:)`).
///
/// This file is compiled into both NotTennaPodCore and the Share Extension, so it uses Foundation only.
public enum ShareHandoff {
    /// Internal scheme; not one of Android's podcast protocols.
    public static let scheme = "nottennapod-share"
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// The share sheet's items reduced to Android's single text: a web link item (Safari shares the page
    /// as a URL) wins; otherwise the shared text, whose first link the app opens.
    public static func sharedText(url: URL?, text: String?) -> String? {
        if let url, !url.isFileURL { return url.absoluteString }
        return text
    }

    /// `nottennapod-share://subscribe?text=<percent-encoded text>`; nil text becomes the no-podcast case.
    public static func url(text: String?) -> URL? {
        guard let text else { return URL(string: scheme + "://subscribe") }
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: scheme + "://subscribe?text=" + encoded)
    }

    /// The text carried by a handoff link, nil when it carries none.
    public static func text(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return nil }
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) where pair.hasPrefix("text=") {
            return String(pair.dropFirst(5)).removingPercentEncoding
        }
        return nil
    }
}

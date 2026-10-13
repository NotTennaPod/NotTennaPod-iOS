import Foundation

/// The text shared for a podcast. Android's `ShareUtils.shareFeedLink` shares the title and an
/// `antennapod.org/deeplink/subscribe` link; NotTennaPod shares the title and the plain feed address instead,
/// so nothing points to AntennaPod's website. Any podcast app can subscribe to it.
/// Platform share-sheet presentation belongs to the UI layer.
public enum FeedShareText {
    public static func make(title: String, source: String) -> String {
        title + "\n\n" + link(source)
    }

    /// The address as one unbroken link. A shared link ends at the first whitespace (`ExternalEntry.sharedLink`), and a
    /// stored address can carry whitespace (OPML imports and address edits keep it): around the address it is left out,
    /// inside it is percent-encoded, which is what it means in a URL anyway. Everything else is shared as stored.
    static func link(_ source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        var result = ""
        for scalar in scalars[first...last] {
            if scalar.properties.isWhitespace {
                for byte in String(scalar).utf8 { result += String(format: "%%%02X", byte) }
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

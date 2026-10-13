import Foundation

public struct FeedSkipDraft: Equatable, Sendable {
    public var intro: String
    public var ending: String
    public init(_ value: FeedSkipPreferences) {
        intro = String(String(value.introSeconds).prefix(5))
        ending = String(String(value.endingSeconds).prefix(5))
    }
    public var confirmed: FeedSkipPreferences {
        .init(introSeconds: Int32(intro) ?? 0, endingSeconds: Int32(ending) ?? 0)
    }
    /// The English source number field filters inserted characters, then applies
    /// its five-character limit. A selection replacement frees that capacity.
    public static func edit(_ text: String, range: NSRange, replacement: String) -> String? {
        guard let range = Range(range, in: text) else { return nil }
        let digits = replacement.filter { $0.isASCII && $0 >= "0" && $0 <= "9" }
        let capacity = max(0, 5 - text.count + text[range].count)
        return text.replacingCharacters(in: range, with: digits.prefix(capacity))
    }
}

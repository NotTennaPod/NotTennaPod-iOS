import Foundation

/// EpisodeFilterDialog edits a private list and writes only on Confirm.
/// Unsubmitted input is deliberately not added by Confirm.
public struct AutomaticDownloadFilterDraft: Equatable, Sendable {
    public var exclude: Bool
    public private(set) var terms: [String]
    public var durationEnabled: Bool
    public var minutes: String

    public init(_ filter: AutomaticDownloadFilter) {
        exclude = filter.include.isEmpty && !filter.exclude.isEmpty
        terms = AutomaticDownloadFilter.terms(exclude ? filter.exclude : filter.include)
        durationEnabled = filter.minimumDurationSeconds >= 0
        minutes = durationEnabled ? String(filter.minimumDurationSeconds / 60) : ""
    }
    @discardableResult public mutating func add(_ raw: String) -> Bool {
        let value = JavaString.trim(raw.replacingOccurrences(of: "\"", with: ""))
        guard !value.isEmpty, !terms.contains(where: { $0.utf16.elementsEqual(value.utf16) }) else { return false }
        terms.append(value); return true
    }
    public mutating func remove(at index: Int) { terms.remove(at: index) }
    public static func editMinutes(_ text: String, range: NSRange, replacement: String) -> String? {
        guard let range = Range(range, in: text) else { return nil }
        let retainedPrefix = text[..<range.lowerBound], retainedSuffix = text[range.upperBound...]
        var insertion = ""
        for character in replacement {
            if character.isASCII && character >= "0" && character <= "9" { insertion.append(character) }
            else if (character == "+" || character == "-"), retainedPrefix.isEmpty, insertion.isEmpty,
                    !retainedSuffix.contains("+") && !retainedSuffix.contains("-") { insertion.append(character) }
        }
        // Inserting before a retained sign is rejected by the signed number field.
        if !insertion.isEmpty && (retainedSuffix.first == "+" || retainedSuffix.first == "-") { return text }
        return String(retainedPrefix) + insertion + retainedSuffix
    }
    public var confirmed: AutomaticDownloadFilter {
        let raw = terms.map { "\"\($0)\" " }.joined()
        // Widen before converting minutes: the source's Int32 multiplication
        // wraps large positive thresholds negative and silently disables them.
        let duration = durationEnabled ? Int32(minutes).map { Int($0) * 60 } ?? -1 : -1
        return .init(include: exclude ? "" : raw, exclude: exclude ? raw : "", minimumDurationSeconds: duration)
    }
}

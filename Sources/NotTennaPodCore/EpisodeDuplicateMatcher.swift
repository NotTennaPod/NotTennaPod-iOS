import Foundation

public enum EpisodeDuplicateMatcher {
    public static func canonicalTitle(_ title: String?) -> String {
        guard let title else { return "" }
        return JavaString.trim(title)
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "„", with: "\"")
            .replacingOccurrences(of: "—", with: "-")
    }

    public static func identifyingValue(_ episode: ParsedEpisode) -> String? {
        if let id = episode.identifier, !id.isEmpty { return id }
        if let title = episode.title, !title.isEmpty { return title }
        return episode.media?.url ?? episode.link
    }

    public static func seemDuplicates(_ first: ParsedEpisode, _ second: ParsedEpisode,
                                      timeZone: TimeZone = .current) -> Bool {
        if sameNonempty(first.identifier, second.identifier) { return true }
        guard let lhs = first.media, let rhs = second.media else { return false }
        if sameNonempty(lhs.url, rhs.url) { return true }
        guard sameNonempty(canonicalTitle(first.title), canonicalTitle(second.title)),
              let firstDate = first.publicationDate, let secondDate = second.publicationDate else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d/yy"
        guard formatter.string(from: firstDate) == formatter.string(from: secondDate) else { return false }
        let difference = lhs.durationMilliseconds &- rhs.durationMilliseconds
        let magnitude = difference < 0 ? 0 &- difference : difference
        guard magnitude < 600_000 else { return false }
        guard var firstMIME = lhs.mimeType, var secondMIME = rhs.mimeType else { return true }
        if let firstSlash = firstMIME.firstIndex(of: "/"), let secondSlash = secondMIME.firstIndex(of: "/") {
            firstMIME = String(firstMIME[..<firstSlash])
            secondMIME = String(secondMIME[..<secondSlash])
        }
        return firstMIME.utf16.elementsEqual(secondMIME.utf16)
    }

    private static func sameNonempty(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, !lhs.isEmpty, let rhs, !rhs.isEmpty else { return false }
        return lhs.utf16.elementsEqual(rhs.utf16)
    }
}

final class RefreshEpisode {
    var value: LibraryEpisode

    init(_ value: LibraryEpisode) { self.value = value }
}

struct EpisodeDuplicatePool {
    private var titles: [[UInt16]: [RefreshEpisode]] = [:]
    private var urls: [[UInt16]: RefreshEpisode] = [:]
    private var identifiers: [[UInt16]: RefreshEpisode] = [:]
    let timeZone: TimeZone

    init(_ episodes: [RefreshEpisode], timeZone: TimeZone) {
        self.timeZone = timeZone
        for episode in episodes { add(episode) }
    }

    mutating func add(_ episode: RefreshEpisode) {
        let details = episode.value.details
        titles[Array(EpisodeDuplicateMatcher.canonicalTitle(details.title).utf16), default: []].append(episode)
        if let url = details.media?.url, !url.isEmpty, urls[Array(url.utf16)] == nil { urls[Array(url.utf16)] = episode }
        if let id = EpisodeDuplicateMatcher.identifyingValue(details), identifiers[Array(id.utf16)] == nil {
            identifiers[Array(id.utf16)] = episode
        }
    }

    func findByID(_ episode: ParsedEpisode) -> RefreshEpisode? {
        EpisodeDuplicateMatcher.identifyingValue(episode).flatMap { identifiers[Array($0.utf16)] }
    }

    func guess(_ episode: ParsedEpisode) -> RefreshEpisode? {
        if let url = episode.media?.url, !url.isEmpty, let match = urls[Array(url.utf16)] { return match }
        return titles[Array(EpisodeDuplicateMatcher.canonicalTitle(episode.title).utf16)]?.first {
            EpisodeDuplicateMatcher.seemDuplicates($0.value.details, episode, timeZone: timeZone)
        }
    }
}

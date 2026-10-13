import Foundation

/// Per-feed list filtering follows FeedItemFilterQuery, with all feed states
/// included by DBReader.getFeed. It does not use FeedItemFilter.matches.
public struct FeedEpisodeFilter: Equatable, Sendable {
    public let values: [String]
    public init(values: [String] = []) {
        let joined = values.joined(separator: ",")
        var tokens = joined.isEmpty ? [] : joined.components(separatedBy: ",")
        while tokens.last == "" { tokens.removeLast() }
        self.values = tokens
    }
    public var isActive: Bool { !values.isEmpty }

    public func includes(_ episode: LibraryEpisode, queued: Bool) -> Bool {
        let tokens = Set(values), state = episode.userState, media = episode.details.media != nil
        if tokens.contains("played") { if state.playState != .played { return false } }
        else if tokens.contains("unplayed") { if state.playState == .played { return false } }
        else if tokens.contains("new"), state.playState != .new { return false }
        if tokens.contains("paused") { if !media || state.positionMilliseconds <= 0 { return false } }
        else if tokens.contains("not_paused"), media && state.positionMilliseconds != 0 { return false }
        if tokens.contains("queued") { if !queued { return false } }
        else if tokens.contains("not_queued"), queued { return false }
        // LEFT JOIN absence is SQL NULL: neither > 0 nor = 0 succeeds.
        let downloaded = state.downloadDate?.timeIntervalSince1970 ?? 0
        if tokens.contains("downloaded") { if !media || downloaded <= 0 { return false } }
        else if tokens.contains("not_downloaded"), !media || downloaded != 0 { return false }
        if tokens.contains("has_media") { if !media { return false } }
        else if tokens.contains("no_media"), media { return false }
        if tokens.contains("is_favorite") { if !state.isFavorite { return false } }
        else if tokens.contains("not_favorite"), state.isFavorite { return false }
        if tokens.contains("is_in_history"), !media || (state.lastPlayedHistoryMilliseconds ?? 0) <= 0 { return false }
        return true
    }
}

/// Source enum order and the two exclusive choices in each toggle group.
public enum FeedFilterGroup: Int, CaseIterable, Sendable {
    case played, paused, favorite, media, queued, downloaded
    public var values: [String] {
        switch self {
        case .played: ["played", "unplayed"]
        case .paused: ["paused", "not_paused"]
        case .favorite: ["is_favorite", "not_favorite"]
        case .media: ["has_media", "no_media"]
        case .queued: ["queued", "not_queued"]
        case .downloaded: ["downloaded", "not_downloaded"]
        }
    }
    public var labelKeys: [String] {
        switch self {
        case .played: ["hide_played_episodes_label", "not_played"]
        case .paused: ["hide_paused_episodes_label", "not_paused"]
        case .favorite: ["hide_is_favorite_label", "not_favorite"]
        case .media: ["has_media", "no_media"]
        case .queued: ["queued_label", "not_queued_label"]
        case .downloaded: ["hide_downloaded_episodes_label", "hide_not_downloaded_episodes_label"]
        }
    }
}

public struct FeedFilterSelection: Equatable, Sendable {
    private var selected: Set<String> = []
    public init(_ filter: FeedEpisodeFilter) {
        // Android checks stored IDs in sequence: the last option in a group wins.
        for token in filter.values {
            if let group = FeedFilterGroup.allCases.first(where: { $0.values.contains(token) }) {
                selected.subtract(group.values); selected.insert(token)
            }
        }
    }
    public func contains(_ value: String) -> Bool { selected.contains(value) }
    public var filter: FeedEpisodeFilter {
        FeedEpisodeFilter(values: FeedFilterGroup.allCases.flatMap(\.values).filter(selected.contains))
    }
    public mutating func toggle(group: FeedFilterGroup, index: Int) {
        precondition((0...1).contains(index))
        let token = group.values[index], wasSelected = selected.contains(token)
        selected.subtract(group.values)
        if !wasSelected { selected.insert(token) }
    }
    public mutating func reset() { selected.removeAll() }
}

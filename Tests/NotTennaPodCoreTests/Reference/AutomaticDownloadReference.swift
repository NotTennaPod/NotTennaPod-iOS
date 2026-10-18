import Foundation
@testable import NotTennaPodCore

/// Automatic download's selection as it was before keyed reads (iOS `1ca0d10`), copied verbatim from
/// `AutomaticDownloadPolicy.swift` (`candidates`, `settledReleases`, `cleanupCandidates`, `newestFirst`), only renamed into
/// this namespace. The keyed selection (`AutomaticDownloadPolicy` over the derived keys) must equal these over a
/// full `snapshot()`. `FullReloadReferencePinTests` fails when this file changes.
enum AutomaticDownloadReference {
    /// `releases`: in a server library, the discovery ledger's pending releases take the place of NEW episodes
    /// (PROTOCOL §9.9, §9.10: automatic download no longer needs the Inbox); nil in a standalone library.
    static func candidates(feeds: [LibraryFeed], queue: [LibraryEpisode], preferences: AutomaticDownloadPreferences,
                                  locale: Locale = .current, releases: Set<Int64>? = nil) -> [LibraryEpisode] {
        let owners = Dictionary(uniqueKeysWithValues: feeds.flatMap { feed in feed.episodes.map { ($0.id, feed) } })
        let new = feeds.filter { $0.subscriptionState == .subscribed }.flatMap(\.episodes)
            .filter { episode in
                // A played release is no candidate, as a played episode is never NEW.
                releases.map { $0.contains(episode.id) && episode.userState.playState != .played } ?? (episode.userState.playState == .new)
            }.sorted(by: newestFirst)
        var result: [LibraryEpisode] = [], seen = Set<Int64>()
        var matchers: [Int64: AutomaticDownloadFilter.Matcher] = [:]
        for episode in new {
            guard let feed = owners[episode.id], feed.autoDownload == .enabled || (feed.autoDownload == .global && preferences.global) else { continue }
            let matcher = matchers[feed.id] ?? AutomaticDownloadFilter.Matcher(feed.automaticDownloadFilter, locale: locale)
            matchers[feed.id] = matcher
            guard matcher.includes(episode), seen.insert(episode.id).inserted else { continue }
            result.append(episode)
        }
        if preferences.queue {
            for episode in queue where seen.insert(episode.id).inserted { result.append(episode) }
        }
        return result.filter { episode in
            guard let feed = owners[episode.id] else { return false }
            return episode.userState.autoDownloadEnabled && !episode.userState.isDownloaded
                && episode.details.media != nil && !feed.source.isLocalFeedSource
        }
    }
    /// The releases no automatic download will take (PROTOCOL §9.9): gone, played, without media, downloaded, excluded from
    /// automatic download, or of a local folder. One a podcast's setting or filter, the network, storage or power
    /// leaves out now stays pending, as an Inbox episode does.
    static func settledReleases(feeds: [LibraryFeed], releases: Set<Int64>) -> Set<Int64> {
        var open = Set<Int64>()
        for feed in feeds where !feed.source.isLocalFeedSource {
            for episode in feed.episodes where releases.contains(episode.id) && episode.details.media != nil
                && !episode.userState.isDownloaded && episode.userState.autoDownloadEnabled && episode.userState.playState != .played {
                open.insert(episode.id)
            }
        }
        return releases.subtracting(open)
    }

    static func cleanupCandidates(feeds: [LibraryFeed], queuedIDs: Set<Int64>, policy: Int, now: Date) -> [LibraryEpisode] {
        guard policy != -2 else { return [] }
        // Filtering first keeps the order: the sort is total (date, then id).
        let candidates = feeds.filter { $0.subscriptionState == .subscribed }.flatMap(\.episodes).filter { episode in
            guard episode.details.media != nil, episode.userState.isDownloaded, !episode.userState.isFavorite else { return false }
            if policy == -3 { return true }
            guard !queuedIDs.contains(episode.id) else { return false }
            if policy == -1 { return true }
            guard episode.userState.playState == .played, let played = episode.userState.lastPlayedHistoryMilliseconds else { return false }
            return Double(played) / 1000 < now.timeIntervalSince1970 - Double(policy) * 3600
        }.sorted(by: newestFirst)
        // Stable source sort retains the incoming newest-first order for ties.
        return candidates.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if policy >= 0 || policy < -3 {
                let av = a.userState.lastPlayedHistoryMilliseconds ?? Int64(now.timeIntervalSince1970 * 1000)
                let bv = b.userState.lastPlayedHistoryMilliseconds ?? Int64(now.timeIntervalSince1970 * 1000)
                return av == bv ? left.offset < right.offset : av < bv
            }
            if policy == -3, a.details.publicationDate == nil || b.details.publicationDate == nil { return a.id < b.id }
            let av = a.details.publicationDate ?? now, bv = b.details.publicationDate ?? now
            return av == bv ? left.offset < right.offset : av < bv
        }.map(\.element)
    }
    static func newestFirst(_ a: LibraryEpisode, _ b: LibraryEpisode) -> Bool {
        let av = a.details.publicationDate ?? .distantPast, bv = b.details.publicationDate ?? .distantPast
        return av == bv ? a.id < b.id : av > bv
    }
}

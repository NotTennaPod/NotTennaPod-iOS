import Foundation

/// Episode actions exchanged with the synchronization service.
extension FeedLibraryStore {
    /// Apply remote listening state without echoing sync actions, deleting files,
    /// fabricating listening statistics or triggering queue auto-download.
    @discardableResult
    public func applySynchronizationEpisodes(_ actions: [SynchronizationEpisodeAction], epoch: UUID,
                                             smartMarkAsPlayedSeconds: Int32 = 30) throws -> [Int64] {
        try Task.checkCancellation()
        return try write(.local) {
            _ = try requireSynchronization(epoch)
            let local = try synchronizationQueue().compactMap { change -> SynchronizationEpisodeAction? in
                if case .episode(let action) = change.value { action } else { nil }
            }
            let selected = SynchronizationActionPolicy.remoteOverridingLocal(actions, local: local)
            var queue = try loadQueue(), changed: [Int64] = []
            // The lowest-ID episode for each exact GUID and media URL, built once: matching each remote action by
            // scanning and decoding the library took minutes on a first sync of a long history.
            var byGUID: [[UInt16]: (id: Int64, feedID: Int64)] = [:], byURL: [[UInt16]: (id: Int64, feedID: Int64)] = [:]
            if !selected.isEmpty {
                for feed in try loadFeeds() {
                    for episode in feed.episodes {
                        func keep(_ text: String?, in table: inout [[UInt16]: (id: Int64, feedID: Int64)]) {
                            guard let text else { return }
                            let key = Array(text.utf16)
                            if let existing = table[key], existing.id < episode.id { return }
                            table[key] = (episode.id, feed.id)
                        }
                        keep(episode.details.identifier, in: &byGUID)
                        keep(episode.details.media?.url, in: &byURL)
                    }
                }
            }
            for action in selected {
                // Malformed wire positions and Java overflow must not create a
                // negative persisted playback position. No media is touched.
                let milliseconds = Int64(action.position) * 1_000
                guard milliseconds >= 0, milliseconds <= Int64(Int32.max) else { continue }
                let guid = SynchronizationActionPolicy.validGUID(action.guid)
                // A valid GUID matches only by GUID; otherwise the media URL is matched.
                let match = if let guid { byGUID[Array(guid.utf16)] } else { byURL[Array(action.episode.utf16)] }
                guard let match, var episode = try loadEpisode(match.id), let media = episode.details.media else { continue }
                let id = match.id, feedID = match.feedID
                episode.userState.positionMilliseconds = Int32(milliseconds)
                if milliseconds > 0, episode.userState.playState == .new { episode.userState.playState = .unplayed }
                if media.durationMilliseconds > 0, milliseconds >= Int64(media.durationMilliseconds) - Int64(smartMarkAsPlayedSeconds) * 1_000 {
                    episode.userState.playState = .played
                    episode.userState.positionMilliseconds = 0
                    queue.removeAll { $0.id == id }
                }
                try saveEpisode(episode, feedID: feedID, explicitStateIntent: true)
                changed.append(id)
            }
            try saveQueue(queue)
            try Task.checkCancellation()
            return changed
        }
    }

    /// Source first sync appends a PLAY action for every subscribed played media
    /// item after applying remote changes. Queue IDs identify only persisted work.
    public func synchronizationEpisodeUpload(epoch: UUID, now: Date = Date()) throws
        -> (ids: [Int64], actions: [SynchronizationEpisodeAction]) {
        try database.transaction(write: false) {
            let state = try requireSynchronization(epoch)
            let queued = try synchronizationQueue().filter { $0.value.phase == .episodes }
            var actions = queued.compactMap { change -> SynchronizationEpisodeAction? in
                if case .episode(let action) = change.value { action } else { nil }
            }
            if state.episodeTimestamp == 0 {
                let feeds = try loadFeeds().filter { $0.subscriptionState == .subscribed }
                var items: [(LibraryFeed, LibraryEpisode)] = []
                for feed in feeds {
                    for episode in feed.episodes where episode.userState.playState == .played && episode.details.media != nil {
                        items.append((feed, episode))
                    }
                }
                items.sort { ($0.1.details.publicationDate ?? .distantPast) > ($1.1.details.publicationDate ?? .distantPast) }
                for (feed, episode) in items {
                    guard let media = episode.details.media, let url = media.url else { continue }
                    let seconds = media.durationMilliseconds / 1_000
                    actions.append(.init(podcast: feed.source, episode: url, guid: episode.details.identifier,
                        action: .play, timestamp: now, started: seconds, position: seconds, total: seconds))
                }
            }
            return (queued.map(\.id), actions)
        }
    }
}

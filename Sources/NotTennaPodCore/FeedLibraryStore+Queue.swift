import Foundation

/// The queue and automatic download requests.
extension FeedLibraryStore {
    public func queue() throws -> [LibraryEpisode] {
        try database.transaction(write: false) { try loadVisibleQueue() }
    }

    /// The queue as the screens show it: in a server library never an episode they do not show.
    func loadVisibleQueue() throws -> [LibraryEpisode] {
        let queue = try loadQueue()
        let hidden = try hiddenEpisodeIDs(queue.map(\.id))
        return hidden.isEmpty ? queue : queue.filter { !hidden.contains($0.id) }
    }

    nonisolated public func setQueueInsertionSettings(_ settings: QueueInsertionSettings) {
        queueInsertion.withLock { $0 = settings }
    }

    nonisolated public var queueInsertionSettings: QueueInsertionSettings { queueInsertion.withLock { $0 } }

    /// A user's "Add to queue" (episode menu, details, multi-select): `DBWriter.addQueueItem` with the stored
    /// Enqueue location, the selected episode as "current" and active downloads as "downloading".
    public func enqueueUsingSettings(_ ids: [Int64]) throws -> LibraryQueueChange {
        try Task.checkCancellation()
        return try write(.queueAdd) {
            try addToQueue(ids, location: queueInsertionSettings.location,
                           playing: playbackSelectionEpisodeID().map(PlayingItem.episode),
                           downloadingURLs: Set(downloadJobs().map(\.source)), randomIndex: { Int.random(in: $0) })
        }
    }

    /// `DBWriter.reorderQueue(order, true)`: the Sort sheet re-sorts the whole queue once.
    public func reorderQueue(_ order: QueueSortOrder, locale: Locale? = nil,
                             shuffle: (inout [QueueSortItem]) -> Void = { $0.shuffle() }) throws -> LibraryQueueChange {
        try Task.checkCancellation()
        return try write(.queueSort) {
            activeCapture?.queueSortOrder = order
            let queue = try loadQueue()
            let sorted = try serverContext != nil ? canonicalSortedQueue(queue, order: order, shuffle: shuffle)
                : sortedQueue(queue, order: order, locale: locale ?? queueInsertionSettings.locale, shuffle: shuffle)
            if sorted.map(\.id) != queue.map(\.id) { try saveQueue(sorted) }
            return LibraryQueueChange(events: [.sorted], episodeIDs: sorted.map(\.id), requestsAutoDownload: false)
        }
    }

    /// The canonical comparators of PROTOCOL §7.6 (server libraries, §7.6): canonical episode and podcast titles (never
    /// a custom title), the server's measured or feed duration (`canonicalSortDuration`), Unicode simple lowercase
    /// then code point, stable; smart-shuffle ties by podcast ID. Random shuffles as on Android.
    func canonicalSortedQueue(_ queue: [LibraryEpisode], order: QueueSortOrder,
                              shuffle: (inout [QueueSortItem]) -> Void = { $0.shuffle() }) throws -> [LibraryEpisode] {
        guard let canonical = CanonicalQueueSort.Order(rawValue: order.rawValue.lowercased()) else {
            return try sortedQueue(queue, order: order, locale: Locale(identifier: "en_US_POSIX"), shuffle: shuffle)
        }
        var headers: [Int64: LibraryFeed] = [:]
        var observations: [String: ContractJSON] = [:]
        let values = try queue.map { episode -> CanonicalQueueSort.Values in
            let feedID = try feedID(forEpisode: episode.id)
            if headers[feedID] == nil { headers[feedID] = try loadFeedHeader(feedID) }
            var podcast = "local:\(feedID)"
            if let row = try database.rows("SELECT podcast_id FROM ntp_podcasts WHERE feed_id = ?", [.integer(feedID)]).first,
               case .text(let id) = row[0] { podcast = id }
            return .init(podcastID: podcast, title: episode.details.title, podcastTitle: headers[feedID]?.metadata.title,
                         publicationTime: try episode.details.publicationDate.map(milliseconds),
                         duration: try canonicalSortDuration(episode, localFolder: headers[feedID]?.source.isLocalFeedSource == true,
                                                             observations: &observations))
        }
        return CanonicalQueueSort.order(values, by: canonical).map { queue[$0] }
    }

    private func sortedQueue(_ queue: [LibraryEpisode], order: QueueSortOrder, locale: Locale,
                             shuffle: (inout [QueueSortItem]) -> Void = { $0.shuffle() }) throws -> [LibraryEpisode] {
        var titles: [Int64: String?] = [:]
        let items = try queue.map { episode -> QueueSortItem in
            let feedID = try feedID(forEpisode: episode.id)
            if titles.index(forKey: feedID) == nil {
                // Feed.getTitle(): the custom title wins when it is not empty.
                let header: LibraryFeed? = try database.rows("SELECT record FROM feeds WHERE id = ?", [.integer(feedID)]).first.map { try decode($0[0]) }
                titles[feedID] = header?.title
            }
            return QueueSortItem(id: episode.id, feedID: feedID, title: episode.details.title, feedTitle: titles[feedID] ?? nil,
                                 publicationMilliseconds: episode.details.publicationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0,
                                 durationMilliseconds: episode.details.media?.durationMilliseconds ?? 0)
        }
        let byID = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0) })
        return QueueSorter.sorted(items, by: order, locale: locale, shuffle: shuffle).compactMap { byID[$0.id] }
    }

    public func enqueue(_ ids: [Int64], location: EnqueueLocation = .back, playing: PlayingItem? = nil,
                        downloadingURLs: Set<String> = [],
                        randomIndex: @Sendable (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) throws -> LibraryQueueChange {
        try Task.checkCancellation()
        return try write(.queueAdd) {
            try addToQueue(ids, location: location, playing: playing, downloadingURLs: downloadingURLs, randomIndex: randomIndex)
        }
    }

    /// Capture the accepted index and remove in one transaction. Publication of
    /// the transient offer happens only after the durable queue/work commit.
    public func removeFromQueueWithUndo(_ id: Int64) throws -> EpisodeQueueRemoval {
        try Task.checkCancellation()
        let result = try write(.queueRemove(.user)) {
            var queue = try loadQueue()
            var receipt: EpisodeQueueRemovalReceipt?
            var events: [LibraryQueueChange.Event] = []
            if let index = queue.firstIndex(where: { $0.id == id }) {
                let episode = queue[index]
                let feedID = try self.feedID(forEpisode: id)
                guard let feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
                receipt = .init(operationID: UUID(), episodeID: id, index: index,
                    storeEpoch: swipeUndoEpoch, feedID: feedID, source: feed.source,
                    identifier: episode.details.identifier, mediaURL: episode.details.media?.url)
                queue.remove(at: index)
                try saveQueue(queue)
                events.append(.removed(episodeID: id))
                if let receipt { activeCapture?.queueRemovalReceipt = (receipt.operationID, id) }
            }
            try requestQueueAutoDownload()
            try Task.checkCancellation()
            return EpisodeQueueRemoval(receipt: receipt, change: .init(events: events,
                episodeIDs: queue.map(\.id), requestsAutoDownload: true))
        }
        if let receipt = result.receipt { queueRemovalOffers[receipt.operationID] = receipt }
        return result
    }

    public func undoQueueRemoval(_ receipt: EpisodeQueueRemovalReceipt) throws -> EpisodeQueueUndoResult {
        try Task.checkCancellation()
        guard receipt.storeEpoch == swipeUndoEpoch, queueRemovalOffers[receipt.operationID] == receipt else {
            return .init(status: .unavailable, change: nil)
        }
        let result = try write(.queueRestore) {
            var queue = try loadQueue()
            var events: [LibraryQueueChange.Event] = []
            let status: EpisodeQueueUndoResult.Status
            if var episode = try loadEpisode(receipt.episodeID) {
                let feedID = try self.feedID(forEpisode: episode.id)
                guard feedID == receipt.feedID, let feed = try loadFeedHeader(feedID),
                      feed.source.utf16.elementsEqual(receipt.source.utf16),
                      exactlyEqual(episode.details.identifier, receipt.identifier),
                      exactlyEqual(episode.details.media?.url, receipt.mediaURL) else {
                    return EpisodeQueueUndoResult(status: .unavailable, change: nil)
                }
                if queue.contains(where: { $0.id == episode.id }) {
                    status = .alreadyQueued
                } else {
                    // Source addQueueItemAt uses the captured numeric index in
                    // the current order, never the old order. When the queue has
                    // shrunk below it, Android's ArrayList.add throws on its DB
                    // thread and Undo silently does nothing (a defect not copied):
                    // the episode goes to the end instead.
                    let index = min(max(0, receipt.index), queue.count)
                    activeCapture?.queueRestore = (episode.id, index, receipt.operationID)
                    activeCapture?.queueInsertions.append(.init(members: [episode.id], before: queue.map(\.id), index: index, end: false))
                    try markQueuedEpisode(&episode)
                    queue.insert(episode, at: index)
                    try saveQueue(queue)
                    events.append(.added(episodeID: episode.id, index: index))
                    status = .restored
                }
            } else { status = .missing }
            try requestQueueAutoDownload()
            try Task.checkCancellation()
            return EpisodeQueueUndoResult(status: status, change: .init(events: events,
                episodeIDs: queue.map(\.id), requestsAutoDownload: true))
        }
        queueRemovalOffers[receipt.operationID] = nil
        queueRemovalKeys[receipt.operationID] = nil
        return result
    }

    public func releaseQueueRemoval(_ receipt: EpisodeQueueRemovalReceipt) {
        guard receipt.storeEpoch == swipeUndoEpoch else { return }
        queueRemovalOffers[receipt.operationID] = nil
        queueRemovalKeys[receipt.operationID] = nil
    }

    /// `RemoveFromHistorySwipeAction` → `DBWriter.deleteFromPlaybackHistory`: clears only the history date
    /// (`playback_completion_date`). Played state, position, played duration, last-played time, queue,
    /// favorites and downloads are kept, and no synchronization action is written. Android also writes
    /// the list row's in-memory `played_duration` back (a stale-value defect); this
    /// reads the stored episode inside the transaction, so newer listening time is never overwritten.
    /// Nil: the episode has no history date (or no media), so there is nothing to remove or undo.
    public func removeFromPlaybackHistoryWithUndo(_ id: Int64) throws -> EpisodeHistoryRemovalReceipt? {
        try Task.checkCancellation()
        let receipt: EpisodeHistoryRemovalReceipt? = try write(.historyRemove) {
            guard var episode = try loadEpisode(id) else { throw FeedLibraryError.missingEpisode(id) }
            guard episode.details.media != nil, let original = episode.userState.lastPlayedHistoryMilliseconds,
                  original > 0 else { return nil }
            let feedID = try self.feedID(forEpisode: id)
            episode.userState.lastPlayedHistoryMilliseconds = nil
            try saveEpisode(episode, feedID: feedID)
            try Task.checkCancellation()
            let receipt = EpisodeHistoryRemovalReceipt(operationID: UUID(), episodeID: id, originalMilliseconds: original,
                                                       storeEpoch: swipeUndoEpoch, mediaURL: episode.details.media?.url)
            activeCapture?.historyRemoval = (receipt.operationID, id)
            return receipt
        }
        if let receipt { historyRemovalOffers[receipt.operationID] = receipt }
        return receipt
    }

    /// Undo of Remove from history (`DBWriter.addItemToPlaybackHistory(media, date)`): writes the exact
    /// original date back, even if the episode was played again meanwhile, so the row returns to its old
    /// place. Only the history date changes.
    public func undoHistoryRemoval(_ receipt: EpisodeHistoryRemovalReceipt) throws -> EpisodeHistoryUndoResult {
        try Task.checkCancellation()
        guard receipt.storeEpoch == swipeUndoEpoch, historyRemovalOffers[receipt.operationID] == receipt else {
            return .init(status: .unavailable)
        }
        let status: EpisodeHistoryUndoResult.Status = try write(.historyRestore) {
            guard var episode = try loadEpisode(receipt.episodeID) else { return .missing }
            guard exactlyEqual(episode.details.media?.url, receipt.mediaURL) else { return .unavailable }
            episode.userState.lastPlayedHistoryMilliseconds = receipt.originalMilliseconds
            activeCapture?.historyRestore = (receipt.operationID, episode.id, receipt.originalMilliseconds)
            try saveEpisode(episode, feedID: try self.feedID(forEpisode: episode.id))
            try Task.checkCancellation()
            return .restored
        }
        historyRemovalOffers[receipt.operationID] = nil
        historyRemovalCuts[receipt.operationID] = nil
        return .init(status: status)
    }

    public func releaseHistoryRemoval(_ receipt: EpisodeHistoryRemovalReceipt) {
        guard receipt.storeEpoch == swipeUndoEpoch else { return }
        historyRemovalOffers[receipt.operationID] = nil
        historyRemovalCuts[receipt.operationID] = nil
    }

    /// Test inspection API: not called by the app.
    func enqueueAt(_ id: Int64, index: Int) throws -> LibraryQueueChange {
        try Task.checkCancellation()
        return try write(.queueAdd) {
            var queue = try loadQueue()
            var events: [LibraryQueueChange.Event] = []
            if !queue.contains(where: { $0.id == id }), var episode = try loadEpisode(id) {
                guard (0...queue.count).contains(index) else { throw FeedLibraryError.invalidMutation }
                activeCapture?.queueInsertions.append(.init(members: [id], before: queue.map(\.id), index: index, end: false))
                try markQueuedEpisode(&episode)
                queue.insert(episode, at: index)
                try saveQueue(queue)
                events.append(.added(episodeID: id, index: index))
            }
            try requestQueueAutoDownload()
            return LibraryQueueChange(events: events, episodeIDs: queue.map(\.id), requestsAutoDownload: true)
        }
    }

    public func removeFromQueue(_ ids: [Int64], performAutoDownload: Bool = true) throws -> LibraryQueueChange {
        try Task.checkCancellation()
        return try write(.queueRemove(.user)) {
            var queue = try loadQueue()
            var events: [LibraryQueueChange.Event] = []
            for id in ids {
                guard let index = queue.firstIndex(where: { $0.id == id }) else { continue }
                queue.remove(at: index)
                events.append(.removed(episodeID: id))
            }
            if !events.isEmpty { try saveQueue(queue) }
            let requested = !ids.isEmpty && performAutoDownload
            if requested { try requestQueueAutoDownload() }
            return LibraryQueueChange(events: events, episodeIDs: queue.map(\.id), requestsAutoDownload: requested)
        }
    }

    /// Test inspection API: not called by the app.
    func moveQueueItem(from: Int, to: Int) throws -> LibraryQueueChange {
        try Task.checkCancellation()
        return try write(.queueMove(boundary: false)) {
            var queue = try loadQueue()
            var events: [LibraryQueueChange.Event] = []
            if queue.indices.contains(from), queue.indices.contains(to) {
                let episode = queue.remove(at: from)
                queue.insert(episode, at: to)
                activeCapture?.movedQueueEpisodes = [episode.id]
                try saveQueue(queue)
                events.append(.moved(episodeID: episode.id, index: to))
            }
            return LibraryQueueChange(events: events, episodeIDs: queue.map(\.id), requestsAutoDownload: false)
        }
    }

    /// Commit against the order and logical identities that the visible interaction captured.
    /// A mutation during a drag/menu await invalidates the whole operation; never reinterpret an old index.
    public func performQueueMove(_ move: QueueManualMove, expected: [QueueEpisodeIdentity]) throws -> QueueManualMoveResult {
        try Task.checkCancellation()
        return try write(.queueMove(boundary: { if case .boundary = move { true } else { false } }())) {
            let queue = try loadQueue(), ids = queue.map(\.id)
            func result(_ status: QueueManualMoveResult.Status, events: [LibraryQueueChange.Event] = []) -> QueueManualMoveResult {
                .init(status: status, change: .init(events: events, episodeIDs: ids, requestsAutoDownload: false))
            }
            guard queue.map(QueueEpisodeIdentity.init) == expected else { return result(.stale) }
            guard let order = move.applying(to: ids), order != ids else { return result(.unchanged) }
            let byID = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0) })
            try Task.checkCancellation()
            let movedIDs: Set<Int64> = switch move { case .item(let id, _): [id]; case .boundary(let selected, _): Set(selected) }
            activeCapture?.movedQueueEpisodes = order.filter(movedIDs.contains)
            try saveQueue(order.compactMap { byID[$0] })
            let events: [LibraryQueueChange.Event] = order.enumerated().compactMap { index, id in
                movedIDs.contains(id) && ids.firstIndex(of: id) != index ? .moved(episodeID: id, index: index) : nil
            }
            try Task.checkCancellation()
            return .init(status: .moved, change: .init(events: events, episodeIDs: order, requestsAutoDownload: false))
        }
    }

    public func clearQueue() throws -> LibraryQueueChange {
        try Task.checkCancellation()
        return try write(.queueClear) {
            try database.execute("DELETE FROM queue")
            return LibraryQueueChange(events: [.cleared], episodeIDs: [], requestsAutoDownload: false)
        }
    }

    /// Test inspection API: not called by the app.
    func queueAutoDownloadRequested() throws -> Bool {
        try database.scalar("SELECT count(*) FROM queue_work WHERE kind = 'autoDownload'") > 0
    }

    /// Durable, coalescing request shared by refresh completion and queue changes.
    /// Completion means accepted, not that selection or transfers have finished.
    public func requestAutomaticDownload(manualRequestID: UUID? = nil) throws {
        try Task.checkCancellation()
        try write(.local) {
            try requireManualRefresh(manualRequestID)
            try requestQueueAutoDownload()
        }
    }

    public func automaticDownloadRequest() throws -> UUID? {
        guard let row = try database.rows("SELECT token FROM queue_work WHERE kind = 'autoDownload'").first else { return nil }
        guard case .text(let value) = row[0], let token = UUID(uuidString: value) else { throw FeedLibraryError.corruptRecord }
        return token
    }

    @discardableResult
    public func finishAutomaticDownloadRequest(_ token: UUID) throws -> Bool {
        try Task.checkCancellation()
        try database.execute("DELETE FROM queue_work WHERE kind = 'autoDownload' AND token = ?", [.text(token.uuidString)])
        return try database.scalar("SELECT changes()") == 1
    }

    /// Hints only: the recipient always rereads committed state. The actor cannot
    /// service that read until the originating transaction commits or rolls back.
    public func automaticDownloadRequests() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            automaticDownloadListeners[id] = continuation
            continuation.yield(())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeAutomaticDownloadListener(id) }
            }
        }
    }

    private func removeAutomaticDownloadListener(_ id: UUID) { automaticDownloadListeners[id] = nil }

    /// Refresh delivery and startup recovery use the same persisted playback and
    /// download context, including when no library screen is visible.
    public func consumeFeedRefreshQueueEffects(location: EnqueueLocation = .back) throws -> [LibraryQueueChange] {
        try Task.checkCancellation()
        // Every library reload calls this; usually there is nothing to queue.
        guard try database.scalar("SELECT EXISTS (SELECT 1 FROM pending_effects WHERE kind IS NULL OR kind = 'queueEpisodes')") == 1 else { return [] }
        return try write(.discoveryQueue) {
            try consumeQueueEffectsInTransaction(location: location,
                playing: playbackSelectionEpisodeID().map(PlayingItem.episode),
                downloadingURLs: Set(downloadJobs().map(\.source)))
        }
    }

    /// Test inspection API: not called by the app.
    func consumeQueueEffects(location: EnqueueLocation = .back, playing: PlayingItem? = nil,
                                    downloadingURLs: Set<String> = []) throws -> [LibraryQueueChange] {
        try Task.checkCancellation()
        return try write(.discoveryQueue) {
            try consumeQueueEffectsInTransaction(location: location, playing: playing, downloadingURLs: downloadingURLs)
        }
    }

    private func consumeQueueEffectsInTransaction(location: EnqueueLocation, playing: PlayingItem?,
                                                  downloadingURLs: Set<String>) throws -> [LibraryQueueChange] {
        var changes: [LibraryQueueChange] = []
        for pending in try pendingEffects(kinds: ["queueEpisodes"]) {
            guard case .queueEpisodes(let ids) = pending.effect.kind else { continue }
            // A server library proposes each release with the bundle this filing resolves (PROTOCOL §9.5).
            activeCapture?.queueReleases += (pending.effect.releases ?? []).filter { ids.contains($0.localID) }
            changes.append(try addToQueue(ids, location: location, playing: playing,
                                          downloadingURLs: downloadingURLs, randomIndex: { Int.random(in: $0) }))
            try acknowledgeEffect(id: pending.id)
        }
        try Task.checkCancellation()
        return changes
    }

    func addToQueue(_ ids: [Int64], location: EnqueueLocation, playing: PlayingItem?,
                            downloadingURLs: Set<String>, randomIndex: (ClosedRange<Int>) -> Int) throws -> LibraryQueueChange {
        var queue = try loadQueue()
        guard !ids.isEmpty else { return LibraryQueueChange(events: [], episodeIDs: queue.map(\.id), requestsAutoDownload: false) }
        let entries = queue.map { QueueEntry(episodeID: $0.id, media: $0.details.media.map { QueueMedia(downloadURL: $0.url) }) }
        var index = QueuePlacement.insertionIndex(location: location, queue: entries, playing: playing,
                                                 isDownloading: { $0.map(downloadingURLs.contains) ?? false }, randomIndex: randomIndex)
        var insertion = QueueInsertion(members: [], before: queue.map(\.id), index: index, end: location == .back)
        var events: [LibraryQueueChange.Event] = []
        var existing = Set(queue.map(\.id))
        // An episode the screens do not show never joins the queue: the player's retained episode of a
        // podcast the server removed plays without being queued again, and a staged one waits for its unit.
        let hidden = try hiddenEpisodeIDs(ids)
        for id in ids {
            guard !existing.contains(id), !hidden.contains(id), var episode = try loadEpisode(id), episode.details.media != nil else { continue }
            try markQueuedEpisode(&episode)
            queue.insert(episode, at: index)
            existing.insert(id)
            insertion.members.append(id)
            events.append(.added(episodeID: id, index: index))
            index += 1
        }
        if !events.isEmpty {
            // The place is where it inserted, before Keep sorted's pass (PROTOCOL §7.6).
            activeCapture?.queueInsertions.append(insertion)
            // applySortOrder (DBW:432–450): Keep sorted re-sorts the whole queue after an addition,
            // except under Random, and replaces the ADDED events by one SORTED event.
            let settings = queueInsertionSettings
            if let order = settings.keepSortedOrder, order != .random {
                // A server library sorts with the canonical comparator (PROTOCOL §7.6, §7.5), never custom titles or locale.
                queue = try serverContext != nil ? canonicalSortedQueue(queue, order: order)
                    : sortedQueue(queue, order: order, locale: settings.locale)
                activeCapture?.keepSortedAdd = true
                activeCapture?.keepSortedOrder = order
                events = [.sorted]
            }
            try saveQueue(queue)
        }
        try requestQueueAutoDownload()
        try Task.checkCancellation()
        return LibraryQueueChange(events: events, episodeIDs: queue.map(\.id), requestsAutoDownload: true)
    }

    private func markQueuedEpisode(_ episode: inout LibraryEpisode) throws {
        guard episode.userState.playState == .new else { return }
        episode.userState.playState = .unplayed
        let feedID = try database.scalar("SELECT feed_id FROM episodes WHERE id = ?", [.integer(episode.id)])
        try saveEpisode(episode, feedID: feedID)
    }

    func loadQueue() throws -> [LibraryEpisode] {
        try database.rows("SELECT episode_id FROM queue ORDER BY position").map {
            guard let id = $0[0].integer, let episode = try loadEpisode(id) else { throw FeedLibraryError.corruptRecord }
            return episode
        }
    }

    func saveQueue(_ episodes: [LibraryEpisode]) throws {
        try captureQueueWrite(episodes.map(\.id))
        // Leave an identical queue (same ids at positions 0..<n) untouched instead of rewriting every row.
        let stored = try database.rows("SELECT position, episode_id FROM queue ORDER BY position").map { $0.map(\.integer) }
        if stored == episodes.enumerated().map({ [Int64($0.offset), $0.element.id] as [Int64?] }) { return }
        try database.execute("DELETE FROM queue")
        for (index, episode) in episodes.enumerated() {
            try database.execute("INSERT INTO queue(position, episode_id) VALUES (?, ?)", [.integer(Int64(index)), .integer(episode.id)])
        }
    }

    func requestQueueAutoDownload() throws {
        try database.execute("INSERT INTO queue_work(kind, token) VALUES ('autoDownload', ?) ON CONFLICT(kind) DO UPDATE SET token = excluded.token", [.text(UUID().uuidString)])
        for listener in automaticDownloadListeners.values { listener.yield(()) }
    }
}

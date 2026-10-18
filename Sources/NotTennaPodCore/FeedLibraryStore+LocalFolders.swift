import Foundation

/// Local folder feeds: folder access, scans, local media and artwork.
extension FeedLibraryStore {
    /// Register a selected directory and its grant in the same transaction as the feed.
    /// Re-selecting the same directory retains the existing feed and episode identities.
    public func registerLocalFolder(title: String, directoryIdentity: String, bookmark: Data) throws -> LocalFolderScanContext {
        try Task.checkCancellation()
        guard !directoryIdentity.isEmpty, !bookmark.isEmpty else { throw FeedLibraryError.invalidMutation }
        return try write(.local) {
            let source = LibraryFeed.localSourcePrefix + directoryIdentity
            var existing: LibraryFeed?
            for row in try database.rows("SELECT record FROM feeds ORDER BY id") {
                let header: LibraryFeed = try decode(row[0])
                guard header.source.utf16.elementsEqual(source.utf16) else { continue }
                existing = try loadFeed(header.id)
                break
            }
            var feed: LibraryFeed
            if let existing { feed = existing }
            else {
                feed = LibraryFeed(id: try database.allocateID("feed"), source: source,
                    metadata: ParsedFeed(format: .rss, title: title), episodes: [])
                feed.autoDownload = .disabled
                feed.episodeSortOrderCode = 3
                try save(feed)
            }
            let link = LocalFolderLink(feedID: feed.id, directoryIdentity: directoryIdentity, bookmark: bookmark, generation: UUID())
            try saveLocalFolder(link)
            // An explicit new grant supersedes offers made under the old one.
            // Ordinary scans and bookmark renewal do not come through this path.
            try database.execute("DELETE FROM episode_swipe_undo WHERE episode_id IN (SELECT id FROM episodes WHERE feed_id = ?)", [.integer(feed.id)])
            try Task.checkCancellation()
            return LocalFolderScanContext(feed: feed, link: link)
        }
    }

    public func localFolder(feedID: Int64) throws -> LocalFolderLink? {
        guard let row = try database.rows("SELECT record FROM local_folder_links WHERE feed_id = ?", [.integer(feedID)]).first else { return nil }
        let link: LocalFolderLink = try decode(row[0])
        guard link.feedID == feedID else { throw FeedLibraryError.corruptRecord }
        return link
    }

    public func reconnectLocalFolder(feedID: Int64, directoryIdentity: String, bookmark: Data) throws -> LocalFolderScanContext {
        try Task.checkCancellation()
        guard !directoryIdentity.isEmpty, !bookmark.isEmpty else { throw FeedLibraryError.invalidMutation }
        return try write(.local) {
            guard var feed = try loadFeed(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            guard feed.source.isLocalFeedSource else { throw FeedLibraryError.invalidMutation }
            feed.source = LibraryFeed.localSourcePrefix + directoryIdentity
            let link = LocalFolderLink(feedID: feedID, directoryIdentity: directoryIdentity, bookmark: bookmark, generation: UUID())
            try saveHeader(feed); try saveLocalFolder(link)
            // Reconnect is a new grant even when the directory string is unchanged.
            try database.execute("DELETE FROM episode_swipe_undo WHERE episode_id IN (SELECT id FROM episodes WHERE feed_id = ?)", [.integer(feedID)])
            try Task.checkCancellation()
            return LocalFolderScanContext(feed: feed, link: link)
        }
    }

    /// Latest-started scan owns the right to apply its result; reconnect also fences old scans.
    public func beginLocalFolderScan(feedID: Int64, manualRequestID: UUID? = nil) throws -> LocalFolderScanContext {
        try Task.checkCancellation()
        return try write(.local) {
            try requireManualRefresh(manualRequestID)
            guard let feed = try loadFeed(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            guard let prior = try localFolder(feedID: feedID),
                  feed.source.utf16.elementsEqual((LibraryFeed.localSourcePrefix + prior.directoryIdentity).utf16) else { throw FeedLibraryError.invalidMutation }
            let link = LocalFolderLink(feedID: feedID, directoryIdentity: prior.directoryIdentity, bookmark: prior.bookmark,
                generation: UUID(), artwork: prior.artwork, registrationID: prior.deletionRegistrationID,
                documentResources: prior.documentResources)
            try saveLocalFolder(link)
            try Task.checkCancellation()
            return LocalFolderScanContext(feed: feed, link: link)
        }
    }

    /// Apply one complete scan atomically. Playback/file-provider effects are owned by
    /// the caller; this operation never treats an external document as a download file.
    public func applyLocalFolderScan(_ snapshot: ParsedFeed, context: LocalFolderScanContext,
                                     refreshedBookmark: Data? = nil,
                                     artworkFilename: String? = nil,
                                     documentResources: [LocalDocumentResourceReceipt]? = nil,
                                     options: FeedRefreshOptions = FeedRefreshOptions(), manualRequestID: UUID? = nil) throws -> FeedRefreshResult {
        try Task.checkCancellation()
        if let name = artworkFilename {
            guard snapshot.imageURL != nil, !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\0") else { throw FeedLibraryError.invalidMutation }
        }
        return try write(.local) {
            try requireManualRefresh(manualRequestID)
            let feedID = context.link.feedID
            guard let current = try loadFeed(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            guard let link = try localFolder(feedID: feedID), link.isSameRegistration(as: context.link),
                  current.source.utf16.elementsEqual((LibraryFeed.localSourcePrefix + link.directoryIdentity).utf16),
                  context.feed.id == feedID else { throw FeedLibraryError.invalidMutation }
            let bookmark = try bookmarkForCommit(refreshedBookmark, observed: context.link, current: link)
            var settings = options; settings.isLocalFeed = true; settings.removeUnlistedItems = true
            var result = try mergeSnapshot(snapshot, into: current, options: settings)
            let previousIDs = Set(current.episodes.map(\.id))
            result.feed.autoDownload = .disabled
            for index in result.feed.episodes.indices where !previousIDs.contains(result.feed.episodes[index].id) {
                result.feed.episodes[index].userState.autoDownloadEnabled = false
            }
            try save(result.feed, previous: current)
            // Foreign-key deletion already removes absent queue/selection/session records.
            // Compact positions while preserving the surviving queue order.
            if !result.removedEpisodes.isEmpty { try saveQueue(loadQueue()) }
            let updated = LocalFolderLink(feedID: feedID, directoryIdentity: link.directoryIdentity,
                bookmark: bookmark, generation: UUID(), artwork: artworkFilename.flatMap { name in
                    snapshot.imageURL.map { LocalFolderArtworkReference(identity: $0, filename: name) }
                }, registrationID: link.deletionRegistrationID, documentResources: documentResources)
            try saveLocalFolder(updated)
            try stageCommittedEpisodeNotification(result.feed, manualRequestID: manualRequestID)
            let lastLog = try database.rows("SELECT record FROM refresh_log WHERE feed_id = ? ORDER BY completed_at DESC, id DESC LIMIT 1", [.integer(feedID)]).first
            let lastStatus: FeedLibraryLog? = try lastLog.map { try decode($0[0]) }
            if lastStatus?.kind.isSuccessful != true {
                try appendLog(.init(feedID: feedID, date: options.now, title: result.feed.title, kind: .success))
            }
            try Task.checkCancellation()
            return result
        }
    }

    public func isCurrentLocalFolderScan(_ context: LocalFolderScanContext) throws -> Bool {
        try database.transaction(write: false) { try currentLocalFolderScan(context) }
    }

    /// A late error must not overwrite success or reconnection from a newer scan.
    /// Failure consumes the context just as success does; no partial snapshot is saved.
    @discardableResult
    public func recordLocalFolderFailure(_ failure: LocalFolderScanFailure, context: LocalFolderScanContext,
                                         date: Date, manualRequestID: UUID? = nil) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            try requireManualRefresh(manualRequestID)
            guard try currentLocalFolderScan(context), var feed = try loadFeedHeader(context.feed.id),
                  let link = try localFolder(feedID: context.feed.id) else { return false }
            feed.lastUpdateFailed = true
            feed.lastRefreshAttempt = date
            try saveHeader(feed)
            try appendLog(.init(feedID: feed.id, date: date, title: feed.title,
                kind: .failure(.io(code: failure.code)), detail: failure.message))
            try saveLocalFolder(LocalFolderLink(feedID: feed.id, directoryIdentity: link.directoryIdentity,
                bookmark: link.bookmark, generation: UUID(), artwork: link.artwork,
                registrationID: link.deletionRegistrationID, documentResources: link.documentResources))
            try Task.checkCancellation()
            return true
        }
    }

    private func currentLocalFolderScan(_ context: LocalFolderScanContext) throws -> Bool {
        guard context.feed.id == context.link.feedID,
              let feed = try loadFeedHeader(context.feed.id), let link = try localFolder(feedID: feed.id) else { return false }
        return link.isSameRegistration(as: context.link) && feed.source.utf16.elementsEqual((LibraryFeed.localSourcePrefix + link.directoryIdentity).utf16)
    }

    /// Preserve a newer persisted renewal instead of letting an old reader or
    /// scan restore its original bytes. Reconnection/scan generations fence ownership.
    private func bookmarkForCommit(_ proposed: Data?, observed: LocalFolderLink, current: LocalFolderLink) throws -> Data {
        if let proposed, proposed.isEmpty { throw FeedLibraryError.invalidMutation }
        guard current.bookmark == observed.bookmark else { return current.bookmark }
        return proposed ?? current.bookmark
    }

    func persistBookmarkRenewal(_ proposed: Data?, observed: LocalFolderLink, current: LocalFolderLink) throws {
        let bookmark = try bookmarkForCommit(proposed, observed: observed, current: current)
        if bookmark != current.bookmark {
            try saveLocalFolder(LocalFolderLink(feedID: current.feedID, directoryIdentity: current.directoryIdentity,
                bookmark: bookmark, generation: current.generation, artwork: current.artwork,
                registrationID: current.deletionRegistrationID, documentResources: current.documentResources))
        }
    }

    public func localDocument(episodeID: Int64) throws -> LocalDocumentReference? {
        try database.transaction(write: false) { try loadLocalDocument(episodeID: episodeID) }
    }

    /// A remote episode returns nil. A local feed without its private grant is
    /// an error, never permission to fall back to an unowned URL from metadata.
    public func localPlaybackContext(for episode: LibraryEpisode) throws -> LocalPlaybackContext? {
        try Task.checkCancellation()
        return try database.transaction(write: false) {
            guard let current = try loadEpisode(episode.id) else { throw FeedLibraryError.missingEpisode(episode.id) }
            let feedID = try feedID(forEpisode: episode.id)
            guard let feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            guard feed.source.isLocalFeedSource else { return nil }
            guard let reference = try loadLocalDocument(episodeID: episode.id) else {
                throw LocalPlaybackAccess.Failure.missingRegistration
            }
            guard let name = episode.details.link, let media = episode.details.media, let identity = media.url,
                  reference.filename.utf16.elementsEqual(name.utf16), reference.identity.utf16.elementsEqual(identity.utf16),
                  reference.size == media.size else { throw CancellationError() }
            try Task.checkCancellation()
            return LocalPlaybackContext(episodeID: episode.id, reference: reference, mimeType: current.details.media?.mimeType)
        }
    }

    /// Validate acquisition and renew only the registration actually observed.
    /// A newer scan/reconnect or document cannot receive an obsolete grant.
    @discardableResult
    public func confirmLocalPlaybackAccess(_ context: LocalPlaybackContext, refreshedBookmark: Data) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard let current = try loadLocalDocument(episodeID: context.episodeID),
                  current.isSameDocument(as: context.reference) else { return false }
            try persistBookmarkRenewal(refreshedBookmark, observed: context.reference.folder, current: current.folder)
            try Task.checkCancellation()
            return true
        }
    }

    /// A confirmed provider deletion must retire the old playback writer before
    /// the full local scan removes its episode. A reconnected folder is fenced.
    public func recordLocalMediaDeletion(episodeID: Int64, reference: LocalDocumentReference,
                                         removeFromQueue: Bool) throws {
        try write(.local) {
            guard let current = try loadLocalDocument(episodeID: episodeID), current.isSameDocument(as: reference),
                  var episode = try loadEpisode(episodeID) else { throw FeedLibraryError.invalidMutation }
            episode.userState.localFileURL = nil
            try saveEpisode(episode, feedID: reference.folder.feedID)
            try database.execute("DELETE FROM playback_session WHERE episode_id = ?", [.integer(episodeID)])
            try database.execute("DELETE FROM playback_selection WHERE episode_id = ?", [.integer(episodeID)])
            if removeFromQueue { try saveQueue(loadQueue().filter { $0.id != episodeID }) }
        }
    }

    func loadLocalDocument(episodeID: Int64) throws -> LocalDocumentReference? {
        guard let episode = try loadEpisode(episodeID), let name = episode.details.link,
              let identity = episode.details.media?.url else { return nil }
        let feedID = try feedID(forEpisode: episodeID)
        guard let link = try localFolder(feedID: feedID), let feed = try loadFeedHeader(feedID),
              feed.source.utf16.elementsEqual((LibraryFeed.localSourcePrefix + link.directoryIdentity).utf16) else { return nil }
        return LocalDocumentReference(folder: link, filename: name, identity: identity,
            size: episode.details.media?.size ?? 0,
            resourceIdentity: link.documentResources?.first { $0.filename.utf16.elementsEqual(name.utf16) }?.identity)
    }

    func recordLocalArtwork(episodeID: Int64, reference: LocalDocumentReference, present: Bool,
                            refreshedBookmark: Data? = nil) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard let current = try loadLocalDocument(episodeID: episodeID), current.isSameDocument(as: reference),
                  var episode = try loadEpisode(episodeID) else { return false }
            if episode.details.media?.hasEmbeddedPicture != present {
                episode.details.media?.hasEmbeddedPicture = present
                try saveEpisode(episode, feedID: reference.folder.feedID, scope: .media)
            }
            try persistBookmarkRenewal(refreshedBookmark, observed: reference.folder, current: current.folder)
            try Task.checkCancellation()
            return true
        }
    }

    /// Chapter metadata/images share the registered document grant, but do not
    /// describe the episode's default embedded artwork presence.
    func recordLocalChapterRead(episodeID: Int64, reference: LocalDocumentReference,
                                refreshedBookmark: Data) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard let current = try loadLocalDocument(episodeID: episodeID),
                  current.isSameDocument(as: reference) else { return false }
            try persistBookmarkRenewal(refreshedBookmark, observed: reference.folder, current: current.folder)
            try Task.checkCancellation()
            return true
        }
    }

    /// Whether the registered document observed by `reference` still awaits its first metadata read.
    func awaitsLocalMetadata(episodeID: Int64, reference: LocalDocumentReference) throws -> Bool {
        try database.transaction(write: false) {
            guard let current = try loadLocalDocument(episodeID: episodeID), current.isSameDocument(as: reference) else { return false }
            return try loadEpisode(episodeID)?.details.media?.metadataPending == true
        }
    }

    /// Fill a cloud-first episode's metadata read after playback opened its document, as the
    /// scan would. A scan, reconnection, replacement or earlier fill since `reference` was
    /// observed wins. User state, the document's identity and size, and a measured duration stay.
    func recordLocalMetadata(_ metadata: LocalFileMetadata, episodeID: Int64, reference: LocalDocumentReference,
                             refreshedBookmark: Data) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard let current = try loadLocalDocument(episodeID: episodeID), current.isSameDocument(as: reference),
                  var episode = try loadEpisode(episodeID), episode.details.media?.metadataPending == true else { return false }
            if let title = metadata.title, !title.isEmpty { episode.details.title = title }
            if let date = metadata.publicationDate { episode.details.publicationDate = date }
            if let duration = metadata.durationMilliseconds, duration > 0,
               (episode.details.media?.durationMilliseconds ?? 0) <= 0 { episode.details.media?.durationMilliseconds = duration }
            episode.details.media?.hasEmbeddedPicture = metadata.embeddedArtwork != nil
            if let description = metadata.description { episode.details.description = description }
            episode.details.media?.metadataPending = nil
            try saveEpisode(episode, feedID: reference.folder.feedID, scope: .metadata)
            try persistBookmarkRenewal(refreshedBookmark, observed: reference.folder, current: current.folder)
            try Task.checkCancellation()
            return true
        }
    }

    func downloadedArtworkReference(episodeID: Int64) throws -> DownloadedArtworkReference? {
        try database.transaction(write: false) { try loadDownloadedArtworkReference(episodeID: episodeID) }
    }

    private func loadDownloadedArtworkReference(episodeID: Int64) throws -> DownloadedArtworkReference? {
        guard let episode = try loadEpisode(episodeID),
              let feed = try loadFeedHeader(feedID(forEpisode: episodeID)),
              !feed.source.isLocalFeedSource else { return nil }
        return DownloadedArtworkReference(episode)
    }

    func recordDownloadedArtwork(episodeID: Int64, reference: DownloadedArtworkReference, present: Bool) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard try loadDownloadedArtworkReference(episodeID: episodeID) == reference,
                  var episode = try loadEpisode(episodeID) else { return false }
            if episode.details.media?.hasEmbeddedPicture != present {
                episode.details.media?.hasEmbeddedPicture = present
                try saveEpisode(episode, feedID: feedID(forEpisode: episodeID), scope: .media)
            }
            return true
        }
    }

    /// A selected folder image is readable only through its registered owner.
    /// The image identity and link also fence delivery after refresh/reconnect.
    public func localFolderArtwork(feedID: Int64, identity: String) throws -> LocalFolderLink? {
        try database.transaction(write: false) { try loadLocalFolderArtwork(feedID: feedID, identity: identity) }
    }

    private func loadLocalFolderArtwork(feedID: Int64, identity: String) throws -> LocalFolderLink? {
        guard let feed = try loadFeedHeader(feedID), let image = feed.metadata.imageURL,
              image.utf16.elementsEqual(identity.utf16),
              let link = try localFolder(feedID: feedID),
              feed.source.utf16.elementsEqual((LibraryFeed.localSourcePrefix + link.directoryIdentity).utf16) else { return nil }
        return link
    }

    func recordFolderArtworkRead(feedID: Int64, identity: String, observed: LocalFolderLink,
                                 refreshedBookmark: Data) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard let current = try loadLocalFolderArtwork(feedID: feedID, identity: identity),
                  current.isSameRegistration(as: observed) else { return false }
            try persistBookmarkRenewal(refreshedBookmark, observed: observed, current: current)
            try Task.checkCancellation()
            return true
        }
    }

    private func saveLocalFolder(_ link: LocalFolderLink) throws {
        try database.execute("INSERT INTO local_folder_links(feed_id, record) VALUES (?, ?) ON CONFLICT(feed_id) DO UPDATE SET record = excluded.record",
            [.integer(link.feedID), .blob(try JSONEncoder().encode(link))])
    }
}

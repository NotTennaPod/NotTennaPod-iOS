import Foundation

/// Reuse of downloads at a first attachment (PROTOCOL §15.4, §5 step 4, PROTOCOL §11.5): an episode the new server library
/// shares with a library kept on this device gets that download as an APFS clone, which takes no extra space and
/// is an independent file, so deleting one library's download never deletes the other's.
public enum LibraryDownloadReuse {
    /// A podcast of the server snapshot.
    public struct Podcast: Sendable {
        public var podcastID: String
        /// Normalized feed URLs (contract URL normalization, userinfo removed).
        public var aliases: Set<String>
        public init(podcastID: String, aliases: Set<String>) { self.podcastID = podcastID; self.aliases = aliases }
    }

    /// A download of a retained library that a server episode may reuse.
    public struct Candidate: Equatable, Sendable {
        public var podcastID: String
        /// The wire episode ID the source episode has under the server podcast.
        public var episodeID: String
        public var file: URL
        public var downloadDate: Date?
        public init(podcastID: String, episodeID: String, file: URL, downloadDate: Date?) {
            self.podcastID = podcastID; self.episodeID = episodeID; self.file = file; self.downloadDate = downloadDate
        }
    }

    public enum Outcome: Equatable, Sendable {
        case cloned(episodeID: Int64, file: URL)
        /// The server library has no such episode, it is downloaded already, or it changed meanwhile.
        case noTarget
        /// The source is not a regular file, or its size differs from the episode's recorded size.
        case fileMismatch
    }

    /// Derives a source episode's wire episode ID under a server podcast; nil when it has none.
    public typealias EpisodeIdentity = @Sendable (_ podcast: Podcast, _ feed: LibraryFeed, _ episode: LibraryEpisode) throws -> String?

    /// The plain derivation (PROTOCOL §3.3 rules 2–4): trimmed GUID, else normalized enclosure URL. A podcast's identity
    /// rules (PROTOCOL §9.7) replace it once they exist.
    public static func plainEpisodeIdentity(namespace: String) -> EpisodeIdentity {
        { podcast, feed, episode in
            try FetchEpisodeIdentity.plainEpisodeID(namespace: namespace, podcastID: podcast.podcastID,
                guid: episode.details.identifier, enclosureURL: episode.details.media?.url, atom: feed.metadata.format == .atom)
        }
    }

    /// The downloads of a retained library's feeds (local folders excluded) whose normalized feed URL is one of a
    /// podcast's aliases, each with its episode ID under that podcast, in feed and episode order.
    public static func candidates(feeds: [LibraryFeed], podcasts: [Podcast], episodeID: EpisodeIdentity) -> [Candidate] {
        var result: [Candidate] = []
        for feed in feeds where !feed.source.isLocalFeedSource {
            let address = ContractURL.normalize(ContractURL.stripUserinfo(feed.source))
            for podcast in podcasts where podcast.aliases.contains(address) {
                for episode in feed.episodes where episode.userState.isDownloaded {
                    guard let path = episode.userState.localFileURL, !path.isEmpty, !path.contains("\0"),
                          let id = try? episodeID(podcast, feed, episode) else { continue }
                    result.append(.init(podcastID: podcast.podcastID, episodeID: id,
                                        file: URL(fileURLWithPath: path), downloadDate: episode.userState.downloadDate))
                }
            }
        }
        return result
    }

    /// The feeds of a closed retained library, each with only its downloaded episodes, read through a read-only
    /// connection. (The open library's feeds come from its store.) Its owned paths are resolved onto the library's
    /// current folder without writing (PROTOCOL §15.4: a Keep moved it, or a device backup was restored under another root).
    public static func downloadedFeeds(database: URL) throws -> [LibraryFeed] {
        let connection = try LibrarySQLite(readingOnly: database)
        defer { try? connection.close() }
        let writtenUnder = try connection.libraryIdentity()?.pathsRoot
        let current = LibraryOwnedPaths.root(of: database.deletingLastPathComponent())
        return try connection.transaction(write: false) {
            var feeds: [Int64: LibraryFeed] = [:]
            var order: [Int64] = []
            for row in try connection.rows("SELECT id, record FROM feeds ORDER BY id") {
                guard let id = row[0].integer, let data = row[1].data else { throw FeedLibraryError.corruptRecord }
                feeds[id] = try JSONDecoder().decode(LibraryFeed.self, from: data)
                order.append(id)
            }
            for row in try connection.rows("SELECT feed_id, record FROM episodes ORDER BY feed_id, pubdate DESC, id") {
                guard let feedID = row[0].integer, let data = row[1].data else { throw FeedLibraryError.corruptRecord }
                var episode = try JSONDecoder().decode(LibraryEpisode.self, from: data)
                if let writtenUnder, let path = episode.userState.localFileURL {
                    episode.userState.localFileURL = LibraryOwnedPaths.resolve(path, writtenUnder: writtenUnder, current: current)
                }
                if episode.userState.isDownloaded { feeds[feedID]?.episodes.append(episode) }
            }
            return order.compactMap { feeds[$0] }
        }
    }

    /// Clones each candidate's file into `media` for the target library's episode with that wire ID
    /// (`target` maps a wire episode ID to the local episode ID), when that episode exists, is not downloaded,
    /// and the file is a regular file whose size equals the episode's recorded size (or, with no recorded size,
    /// is not empty). The episode is then marked downloaded with the clone and the original download date.
    /// The first usable candidate per episode wins. Rerunning after a crash replaces an unrecorded clone.
    public static func clone(_ candidates: [Candidate], into store: FeedLibraryStore, media: URL,
                             target: (String) async throws -> Int64?) async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for candidate in candidates {
            try Task.checkCancellation()
            guard let episodeID = try await target(candidate.episodeID),
                  let episode = try await store.episode(id: episodeID), let recorded = episode.details.media,
                  !episode.userState.isDownloaded else { outcomes.append(.noTarget); continue }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  recorded.size > 0 ? size == recorded.size : size > 0 else { outcomes.append(.fileMismatch); continue }
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let destination = media.appendingPathComponent("episode-\(episodeID)-reused.media")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            // On APFS a copy within one volume is a clone (clonefile): no data is duplicated.
            try FileManager.default.copyItem(at: candidate.file, to: destination)
            let adopted: Bool
            do { adopted = try await store.adoptReusedDownload(episodeID: episodeID, file: destination, downloadDate: candidate.downloadDate) }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
            if adopted { outcomes.append(.cloned(episodeID: episodeID, file: destination)) }
            else { try? FileManager.default.removeItem(at: destination); outcomes.append(.noTarget) }
        }
        return outcomes
    }
}

public extension FeedLibraryStore {
    /// Reuse at a first attachment (PROTOCOL §15.4): marks the episode downloaded with a cloned file, as a completed download
    /// does (file size, download date, automatic download off), keeping its play state, which the server's records
    /// own. Records no effect: the library being attached is not live yet. False when the episode is gone, has no
    /// media, is downloaded or has an active download.
    func adoptReusedDownload(episodeID: Int64, file: URL, downloadDate: Date?, now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        let date = downloadDate ?? now
        _ = try milliseconds(date)
        return try database.transaction {
            guard var episode = try loadEpisode(episodeID), episode.details.media != nil, !episode.userState.isDownloaded,
                  try database.scalar("SELECT count(*) FROM download_jobs WHERE episode_id = ? AND active = 1", [.integer(episodeID)]) == 0
            else { return false }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { throw FeedLibraryError.invalidLocation }
            episode.details.media?.size = size
            episode.userState.localFileURL = file.path
            episode.userState.isDownloaded = true
            episode.userState.downloadDate = date
            episode.userState.autoDownloadEnabled = false
            try saveEpisode(episode, feedID: feedID(forEpisode: episodeID))
            return true
        }
    }
}

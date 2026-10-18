import Foundation

/// Effects outside SQLite in a server library: a download or transcript deletion, a playback-selection
/// change or a stop never runs inside a recording transaction. The transaction commits the rows, the facts
/// and a durable, idempotent work entry (`pending_effects`: `deleteDownloadFile`, `deleteFeed`,
/// `removeEpisodes`); the work runs after COMMIT, is replayed at launch, and here re-checks the current
/// references before it deletes a file. The playback coordinator stops or unloads only after the store call
/// has returned.
extension FeedLibraryStore {
    /// Whether a current row still names `file`: an episode's download (the playback selection's and session's
    /// episode included), or an active download job. Holds the store while it checks, like the removed-episode
    /// cleanup, so no writer can claim the file between the check and the deletion.
    func serverFileReferences(_ file: URL, excludingJobs: Set<Int64> = []) throws -> Bool {
        let path = file.standardizedFileURL.path
        let paths = [path, path + ".transcript"]
        for job in try downloadJobs(activeOnly: true) where !excludingJobs.contains(job.id) {
            if paths.contains(job.destination.standardizedFileURL.path) { return true }
        }
        // Only the episodes whose stored file has this file's name are read; a staged episode no list shows
        // owns nothing yet.
        if keyedReads { return try fileOwners(of: [file]).contains { !$0.hidden } }
        for feed in try loadFeeds() {
            for episode in feed.episodes {
                if let local = episode.userState.localFileURL, paths.contains(URL(fileURLWithPath: local).standardizedFileURL.path) { return true }
            }
        }
        return false
    }

    /// The post-commit deletion of a download in a server library: unlinks `file` (and its transcript) only when
    /// no current row references it, inside one transaction. Standalone libraries never call this; their
    /// deletion path is unchanged. Returns whether the file was deleted.
    @discardableResult
    func deleteServerDownloadIfUnreferenced(_ file: URL, excludingJobs: Set<Int64> = [],
                                            remove: @Sendable (URL) throws -> Void) throws -> Bool {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        return try write(.local) {
            guard try !serverFileReferences(file, excludingJobs: excludingJobs) else { return false }
            try remove(file)
            return true
        }
    }
}

extension FeedLibraryStore {
    nonisolated func adoptCredentialVault(_ vault: any SynchronizationCredentialStore) {
        credentialVault.withLock { $0 = vault }
    }

    /// In a server library, a subscription URL's userinfo (percent-decoded, as `FeedFetcher` reads it) staged as a
    /// library credential before the recording transaction: a cleanup entry is committed first and the
    /// Keychain item written after it, so a transaction that never claims it leaves ordinary cleanup work, as
    /// `FeedAuthentication` stages credentials. Nil without userinfo with a password, and in a standalone library.
    func stageURLCredential(_ source: String) throws -> UUID? {
        guard serverContext != nil, let parts = URLComponents(string: source),
              let user = parts.user, !user.isEmpty || parts.password != nil, let password = parts.password else { return nil }
        guard let vault = credentialVault.withLock({ $0 }) else {
            throw ServerRecordingError.corruptState("no credential store for a subscription URL's credentials")
        }
        let id = UUID()
        try stageFeedCredential(id)
        try vault.insert(String(decoding: try JSONEncoder().encode(FeedCredentials(username: user, password: password)), as: UTF8.self), id: id)
        return id
    }
}

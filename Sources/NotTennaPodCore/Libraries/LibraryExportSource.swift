import Foundation

/// What one library's read transaction holds for an export (PROTOCOL §11.5): feeds with their episodes, the queue, the
/// download log, statistics units and the feeds' credential IDs.
public struct LibraryExportContents: Sendable {
    public var identity: String
    public var serverLibrary: Bool
    public var feeds: [LibraryFeed]
    public var queue: [AndroidDatabaseBackup.Source.QueueEntry]
    public var downloadLog: [DownloadLogEntry]
    public var statisticsUnits: [Int64: [LibraryStatisticsUnit]]
    /// Feed ID → its Keychain credential ID.
    public var credentialIDs: [Int64: UUID]
}

/// One immutable export source (PROTOCOL §11.5): everything the four writers need, collected once
/// under the shared library gate from the chosen library, then encoded and written without the gate.
public struct LibraryExportSource: Sendable {
    public var contents: LibraryExportContents
    /// The library's own per-feed speeds and silence (the device-wide values do not matter to the writers).
    public var speeds: PlaybackSpeedPreferences
    public var credentials: [Int64: FeedCredentials]
    /// Why a credential an included feed names could not be read. Only the database export carries credentials, so
    /// only it refuses; OPML and HTML never need them.
    public var credentialFailure: (any Error)?
    /// A server library's `sync.sqlite`, where a refused export is recorded; nil for a standalone library.
    public var syncLog: URL?

    public init(contents: LibraryExportContents, speeds: PlaybackSpeedPreferences, credentials: [Int64: FeedCredentials],
                credentialFailure: (any Error)? = nil, syncLog: URL? = nil) {
        self.contents = contents; self.speeds = speeds; self.credentials = credentials
        self.credentialFailure = credentialFailure; self.syncLog = syncLog
    }

    public var feeds: [LibraryFeed] { contents.feeds }

    /// The Android database export of this source.
    public var backup: AndroidDatabaseBackup.Source {
        AndroidDatabaseBackup.Source(feeds: contents.feeds, queue: contents.queue, downloadLog: contents.downloadLog,
                                     credentials: credentials, speeds: speeds, statisticsUnits: contents.statisticsUnits,
                                     checksUnitLastPlayed: contents.serverLibrary)
    }

    /// The database file. A server library's file that breaks the last-played promise is refused with the existing
    /// export error; its sync log records the cause and the episode's ID, never a payload (PROTOCOL §11.5).
    public func databaseData(now: Date = Date()) throws -> Data {
        // A backup without a private feed's login would break that subscription when restored: refused instead.
        if let credentialFailure { throw credentialFailure }
        do { return try AndroidDatabaseBackup.data(for: backup) } catch AndroidDatabaseBackup.Failure.unitAfterEpisode(let episode) {
            if let syncLog {
                ServerArchive.append(to: syncLog, kind: "export", now: now,
                                     detail: "the database export was refused: a statistics unit of episode \(episode) was played later than the episode")
            }
            throw AndroidDatabaseBackup.Failure.unitAfterEpisode(episodeID: episode)
        }
    }
    public func opmlData(createdAt: Date = Date(), timeZone: TimeZone = .current) throws -> Data {
        try OPMLExportWriter.data(for: contents.feeds, createdAt: createdAt, timeZone: timeZone)
    }
    public func htmlData(favorites: Bool) -> Data {
        favorites ? HTMLExportWriter.favorites(contents.feeds) : HTMLExportWriter.subscriptions(contents.feeds)
    }
}

public enum LibraryExportError: Error, Equatable, Sendable, LocalizedError {
    /// The chosen library is gone (removed, or replaced by a database import): the existing export error.
    case libraryNotFound
    /// The library is not at schema 20 yet (its migration failed): offered to no export.
    case libraryNotReady

    public var errorDescription: String? {
        switch self {
        case .libraryNotFound: "Library not found"
        case .libraryNotReady: "Library not ready"
        }
    }
}

extension FeedLibraryStore {
    /// One read transaction for an export: every feed library-wide reads show, the visible queue, the download log, the
    /// statistics units and the feeds' credential IDs.
    public func exportContents() throws -> LibraryExportContents {
        try database.transaction(write: false) {
            guard try database.scalar("PRAGMA user_version") >= 20, let identity = try database.libraryIdentity() else {
                throw LibraryExportError.libraryNotReady
            }
            let feeds = try loadFeeds(skippingPinnedRemovals: true)
            let feedOf = Dictionary(feeds.flatMap { feed in feed.episodes.map { ($0.id, feed.id) } }, uniquingKeysWith: { first, _ in first })
            let queue = try loadVisibleQueue().compactMap { episode in
                feedOf[episode.id].map { AndroidDatabaseBackup.Source.QueueEntry(episodeID: episode.id, feedID: $0) }
            }
            // Only the credentials of the feeds the export contains: a podcast it leaves out (a pinned removal) never
            // holds it back.
            let included = Set(feeds.map(\.id))
            var credentials: [Int64: UUID] = [:]
            for row in try database.rows("SELECT feed_id, credential_id FROM feed_credentials") {
                guard let feed = row[0].integer, let text = row[1].text, let id = UUID(uuidString: text) else { throw FeedLibraryError.corruptRecord }
                if included.contains(feed) { credentials[feed] = id }
            }
            return LibraryExportContents(identity: identity.identity, serverLibrary: serverContext != nil, feeds: feeds, queue: queue,
                                         downloadLog: try loadDownloadLog(), statisticsUnits: try loadStatisticsUnits(of: feeds),
                                         credentialIDs: credentials)
        }
    }
}

/// Where each library on the device is, by identity (PROTOCOL §15.4): the open library, the library in the root
/// folder, the server libraries and the previous libraries. A library that no longer exists ends the export with the
/// existing export error.
public enum LibraryExport {
    /// The open library, as its graph holds it: read through its open store, with its live speed values.
    public struct OpenLibrary: Sendable {
        public var store: FeedLibraryStore
        public var identity: String
        /// Its speeds and silence as its preference store holds them, read while the gate is held.
        public var speeds: @Sendable () async -> PlaybackSpeedPreferences
        public init(store: FeedLibraryStore, identity: String, speeds: PlaybackSpeedPreferences) {
            self.store = store; self.identity = identity; self.speeds = { speeds }
        }
        public init(store: FeedLibraryStore, identity: String, readSpeeds: @escaping @Sendable () async -> PlaybackSpeedPreferences) {
            self.store = store; self.identity = identity; speeds = readSpeeds
        }
    }

    /// Collects the source of the library named `identity` (PROTOCOL §11.5–4): the shared gate, the identity resolved to
    /// the library's current folder, one read transaction, its speeds and the credentials its feeds name, then the
    /// gate is released. The caller encodes and writes the document afterwards.
    public static func collect(identity: String, root: URL, open: OpenLibrary?, vault: any SynchronizationCredentialStore,
                               gate: LibraryGate) async throws -> LibraryExportSource {
        try await collect(identity: identity, root: root, current: { open }, vault: vault, gate: gate)
    }

    /// As above, with the open library asked for only once the gate is held: a Keep or a switch made
    /// while the export waited has replaced the graph, so nothing captured before the wait is trusted. When the open
    /// library is another one, or its store has closed meanwhile, the library is found by identity and read through
    /// the read-only reader with that location's own speeds.
    public static func collect(identity: String, root: URL, current: @escaping @MainActor () -> OpenLibrary?,
                               vault: any SynchronizationCredentialStore, gate: LibraryGate) async throws -> LibraryExportSource {
        // An export that background time ends stops waiting, holding nothing .
        try await gate.acquireSharedUnlessCancelled()
        defer { gate.releaseShared() }
        var read: (contents: LibraryExportContents, speeds: PlaybackSpeedPreferences)?
        if let open = await current(), open.identity == identity {
            do { read = (try await open.store.exportContents(), await open.speeds()) }
            catch FeedLibraryError.closed {}
        }
        if read == nil {
            guard let location = try locate(identity: identity, root: root) else { throw LibraryExportError.libraryNotFound }
            let store = try FeedLibraryStore(readingOnly: location.database)
            let contents: LibraryExportContents
            do {
                contents = try await store.exportContents()
                try await store.close()
            } catch {
                try? await store.close()
                throw error
            }
            guard contents.identity == identity else { throw LibraryExportError.libraryNotFound }
            read = (contents, try location.speeds())
        }
        guard let (contents, speeds) = read else { throw LibraryExportError.libraryNotFound }
        // Every credential an included feed names is read. A failed read is kept with the source: the database export
        // fails with it (the existing export error) rather than writing a backup without that
        // feed's login; OPML and HTML, which carry no credentials, are written.
        var credentials: [Int64: FeedCredentials] = [:]
        var failure: (any Error)?
        for (feed, id) in contents.credentialIDs.sorted(by: { $0.key < $1.key }) {
            do {
                let password = try vault.password(id: id)
                credentials[feed] = try JSONDecoder().decode(FeedCredentials.self, from: Data(password.utf8))
            } catch {
                if failure == nil { failure = error }
            }
        }
        let syncLog = contents.serverLibrary ? LibraryLocation(root: root, reference: .server(identity)).syncDatabase : nil
        return LibraryExportSource(contents: contents, speeds: speeds, credentials: credentials, credentialFailure: failure, syncLog: syncLog)
    }

    /// A library's files found by identity, never by a path the caller kept.
    public struct Location: Sendable {
        public enum Kind: Sendable, Equatable { case root, server(String), previous(String) }
        public var kind: Kind
        public var database: URL
        public var root: URL

        /// The library's own per-feed speeds and silence (PROTOCOL §15.4): the root speed file's library-owned values for the
        /// library in the root folder, its `playback-library.json` for any other.
        func speeds() throws -> PlaybackSpeedPreferences {
            var value = PlaybackSpeedPreferences()
            switch kind {
            case .root:
                let file = root.appendingPathComponent("playback-speed-preferences.json")
                if FileManager.default.fileExists(atPath: file.path) {
                    value = try JSONDecoder().decode(PlaybackSpeedPreferences.self, from: Data(contentsOf: file))
                }
            case .server, .previous:
                let file = database.deletingLastPathComponent().appendingPathComponent(LibraryLocation.playbackLibraryName)
                if FileManager.default.fileExists(atPath: file.path) {
                    let data = try JSONDecoder().decode(PlaybackLibraryData.self, from: Data(contentsOf: file))
                    value.feeds = data.speeds.feeds; value.silence.feeds = data.speeds.feedSilence
                }
            }
            return value
        }
    }

    /// The library whose `library_identity` is `identity`: the registry's names first (PROTOCOL §15.4), then each library's own
    /// identity row read through the read-only reader. Nil when no library on the device has it.
    public static func locate(identity: String, root: URL) throws -> Location? {
        var candidates: [Location] = []
        let registry = (try? LibraryRegistryFile(root: root).read()) ?? LibraryRegistry()
        let rootDatabase = root.appendingPathComponent(LibraryLocation.databaseName)
        let server = LibraryLocation(root: root, reference: .server(identity))
        if let previous = registry.previous.first(where: { $0.identity == identity }) {
            candidates.append(Location(kind: .previous(previous.id), database: PreviousLibraryLocation(root: root, id: previous.id).database, root: root))
        }
        candidates.append(Location(kind: .root, database: rootDatabase, root: root))
        if ContractIdentity.isUUID(identity) { candidates.append(Location(kind: .server(identity), database: server.database, root: root)) }
        for location in try PreviousLibraryLocation.all(root: root) {
            candidates.append(Location(kind: .previous(location.id), database: location.database, root: root))
        }
        for candidate in candidates where !LibraryLocation.isAbsent(candidate.database) {
            guard let found = try? LibraryDatabaseInspection.identity(of: candidate.database) else { continue }
            // An archived library is found only where it was archived to, never in the root folder.
            if found.identity == identity, !(candidate.kind == .root && found.keepRole == .archived) { return candidate }
        }
        return nil
    }
}

/// Short read-only looks into a library database another graph owns or nobody has open.
public enum LibraryDatabaseInspection {
    public static func identity(of database: URL) throws -> LibraryIdentity? {
        let connection = try LibrarySQLite(readingOnly: database)
        defer { try? connection.close() }
        return try connection.transaction(write: false) { try connection.libraryIdentity() }
    }

    public static func schemaVersion(of database: URL) throws -> Int64 {
        let connection = try LibrarySQLite(readingOnly: database)
        defer { try? connection.close() }
        return try connection.scalar("PRAGMA user_version")
    }
}

extension AndroidDatabaseBackup {
    /// The file for one source: a unique temporary file, never a shared path.
    public static func data(for source: Source) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("NotTennaPodBackup-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: file) }
        try write(source, to: file)
        return try Data(contentsOf: file)
    }
}

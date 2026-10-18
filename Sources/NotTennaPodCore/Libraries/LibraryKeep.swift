import Foundation
import SQLite3

/// "Keep using this library" at logout (PROTOCOL §15.4):
/// the server library `S` becomes this phone's standalone library, and the library from before signing in is kept
/// aside as a previous library `P`. A durable transaction of seven phases with a backed-up manifest: every step is
/// idempotent, its completion is recorded in the manifest or recognized by content (the databases' `library_identity`
/// marks and the folder markers), and the conversion transaction in `S`'s database is the one commit. Before it a
/// failure leaves both libraries as they were and the Keep is tried again; after it the Keep only goes forward, and the
/// converted library opens where it is until publication finishes.
///
/// The engine is synchronous file and database work. Its caller holds the library gate exclusively and has no graph
/// open on either library: at a launch before anything opens, or at runtime after the graph was stopped under the
/// activation rule (PROTOCOL §15.4).
public struct LibraryKeep {
    public static let conversionsFolderName = "Library Conversions"
    public static let manifestName = "manifest.json"
    public static let markerName = ".nottennapod-library.json"

    /// Every step a crash or a failure can follow ("Keep failure boundaries").
    public enum Step: String, CaseIterable, Sendable {
        case captureCheckpoint = "capture.checkpoint", captureWrite = "capture.write"
        case preparePrevious = "prepare.previous", preparePolicies = "prepare.policies", prepareMarkers = "prepare.markers"
        case prepareWrite = "prepare.write"
        case archiveMark = "archive.mark", archiveWrite = "archive.write"
        case convert = "convert.transaction", convertWrite = "convert.write"
        case publishCheckpoint = "publish.checkpoint"
        case renameOldDatabase = "publish.rename.old-database", renameOldMedia = "publish.rename.old-media"
        case renameOldCache = "publish.rename.old-cache", renameSourceDatabase = "publish.rename.source-database"
        case renameSourceMedia = "publish.rename.source-media", renameSourceCache = "publish.rename.source-cache"
        case publishTransfers = "publish.transfers"
        case settingsSpeeds = "publish.settings.speeds", settingsShownotes = "publish.settings.shownotes"
        case settingsDownload = "publish.settings.download", settingsQueue = "publish.settings.queue"
        case publishRegistry = "publish.registry", publishWrite = "publish.write"
        case cleanupFolder = "cleanup.folder", cleanupTokens = "cleanup.tokens", cleanupMarkers = "cleanup.markers"
        case cleanupManifest = "cleanup.manifest", cleanupRegistry = "cleanup.registry"
    }

    /// How a run ended.
    public enum Outcome: Equatable, Sendable {
        /// Published and cleaned up.
        case finished
        /// Published; cleanup (phase 7) is left for the next graph start (a locked Keychain, a failed deletion).
        case cleanupPending
        /// A failure before the commit (phases 2–4): nothing changed; `S` stays the active library, logged out.
        case notCommitted(KeepFailure)
        /// A failure after the commit (phase 6): the converted library opens where it is until publication is retried.
        case notPublished(KeepFailure)
    }

    public struct Environment {
        public var root: URL
        public var secrets: any ServerSecretStore
        public var clock: @Sendable () -> Date
        /// Test failure and crash injection: called before every step; a thrown error is that step's failure.
        public var beforeStep: (Step) throws -> Void
        /// File operations, replaceable to inject failures (a full disk) at one operation.
        public var files: KeepFiles

        public init(root: URL, secrets: any ServerSecretStore, clock: @escaping @Sendable () -> Date = { Date() },
                    beforeStep: @escaping (Step) throws -> Void = { _ in }, files: KeepFiles = KeepFiles()) {
            self.root = root; self.secrets = secrets; self.clock = clock; self.beforeStep = beforeStep; self.files = files
        }
    }

    /// The file operations the Keep makes, each one a seam for failure tests.
    public struct KeepFiles: Sendable {
        public var write: @Sendable (Data, URL) throws -> Void = { data, url in try DurableFile.replace(url, with: data) }
        public var rename: @Sendable (URL, URL) throws -> Void = { from, to in
            guard Darwin.rename(from.path, to.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        public var remove: @Sendable (URL) throws -> Void = { url in
            if !LibraryLocation.isAbsent(url) { try FileManager.default.removeItem(at: url) }
        }
        public init() {}
    }

    let environment: Environment
    var root: URL { environment.root }
    public init(_ environment: Environment) { self.environment = environment }

    // MARK: - Locations

    public static func conversionsFolder(root: URL) -> URL { root.appendingPathComponent(conversionsFolderName, isDirectory: true) }
    func manifestFolder(_ operation: String) -> URL { Self.conversionsFolder(root: root).appendingPathComponent(operation, isDirectory: true) }
    func manifestFile(_ operation: String) -> URL { manifestFolder(operation).appendingPathComponent(Self.manifestName) }
    func source(_ manifest: LibraryKeepManifest) -> LibraryLocation { LibraryLocation(root: root, reference: .server(manifest.source)) }
    func archive(_ manifest: LibraryKeepManifest) -> PreviousLibraryLocation { PreviousLibraryLocation(root: root, id: manifest.archive) }
    var rootDatabase: URL { root.appendingPathComponent(LibraryLocation.databaseName) }
    var rootMedia: URL { root.appendingPathComponent("media", isDirectory: true) }
    var rootCache: URL { root.appendingPathComponent("streaming-cache", isDirectory: true) }
    var registryFile: LibraryRegistryFile { LibraryRegistryFile(root: root) }

    // MARK: - Phase 1: the request

    /// The logout cut-off's first step for "Keep using this library" (PROTOCOL §15.4): the manifest with its identities, then the
    /// registry marks `S` `keeping` with the operation. From then on the choice survives a crash.
    @discardableResult
    public func request(source id: String) throws -> LibraryKeepManifest {
        let registry = try registryFile.read()
        guard let entry = registry.library(id), [.active, .ready, .keeping].contains(entry.state) else {
            throw LibraryKeepError.notAServerLibrary
        }
        if entry.state == .keeping, let operation = entry.operation, let manifest = try? readManifest(operation) { return manifest }
        let manifest = LibraryKeepManifest(operation: ContractIdentity.randomUUID(), source: id, archive: ContractIdentity.randomUUID(),
                                           keptAt: Int64((environment.clock().timeIntervalSince1970 * 1_000).rounded(.down)))
        try FileManager.default.createDirectory(at: manifestFolder(manifest.operation), withIntermediateDirectories: true)
        try writeManifest(manifest)
        try registryFile.update { registry in
            guard let index = registry.libraries.firstIndex(where: { $0.id == id }) else { throw LibraryKeepError.notAServerLibrary }
            registry.libraries[index].state = .keeping
            registry.libraries[index].operation = manifest.operation
            // A switch recorded earlier (to this library, or a resume) is superseded by the choice.
            registry.pendingSwitch = nil
        }
        return manifest
    }

    // MARK: - Recovery: what is unfinished

    /// At every graph start, before anything else (PROTOCOL §15.4 "Recovery comes first"): the manifests the registry names, a
    /// committed manifest it no longer names written back, an unnamed uncommitted request discarded,
    /// and a `conversions` entry whose manifest is gone removed. Returns the Keep left to run, if any: the Keep not yet
    /// published first, so an earlier Keep's pending cleanup never stands in its way.
    public func unfinished() throws -> LibraryKeepManifest? { try unfinishedKeeps().first }

    /// Every unfinished Keep, the one not yet published first, then the published ones whose cleanup remains. A folder,
    /// manifest or database that cannot be read now (before the first unlock) is thrown: never taken for no Keep,
    /// and never deleted.
    public func unfinishedKeeps() throws -> [LibraryKeepManifest] {
        let registry = try registryFile.read()
        var found: [LibraryKeepManifest] = []
        let folder = Self.conversionsFolder(root: root)
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) }
        catch where SavedState.isAbsent(folder) { names = [] }
        let operations = names.filter(ContractIdentity.isUUID).sorted()
        for operation in operations {
            let named = registry.keeping?.operation == operation || registry.conversions.contains { $0.operation == operation }
            guard let manifest = try recordedManifest(operation) else {
                // A folder without a readable manifest: a request whose manifest write never completed.
                if !named { try environment.files.remove(manifestFolder(operation)) }
                continue
            }
            if !named {
                guard try committed(manifest) else {
                    // A request that was never recorded: only now is it deleted.
                    try environment.files.remove(manifestFolder(operation))
                    continue
                }
                // Committed, but the registry does not name it (a restored registry): its name is written back, as
                // published only when its manifest says so, and the Keep finishes.
                try registryFile.update { registry in
                    registry.conversions.append(.init(operation: manifest.operation, library: manifest.source, previous: manifest.archive,
                        state: manifest.phase == .published ? LibraryRegistry.Conversion.published : LibraryRegistry.Conversion.unpublished))
                }
            }
            found.append(manifest)
        }
        // A conversions entry whose manifest is already gone has only itself left to remove.
        try registryFile.update { registry in
            registry.conversions.removeAll { entry in LibraryLocation.isAbsent(manifestFile(entry.operation)) }
        }
        let published = Set(try found.filter { try self.published($0) }.map(\.operation))
        return found.filter { !published.contains($0.operation) } + found.filter { published.contains($0.operation) }
    }

    /// Runs every unfinished Keep (PROTOCOL §15.4): the one not yet published, then each published Keep's
    /// cleanup on its own, so an earlier Keep's cleanup (a locked Keychain) neither holds back the current Keep nor
    /// decides which library opens. The caller holds the library gate exclusively with no graph open. Returns the
    /// outcome of the Keep not yet published, else of the first cleanup; nil when no Keep is unfinished.
    public func runUnfinished() -> (manifest: LibraryKeepManifest, outcome: Outcome)? {
        guard let keeps = try? unfinishedKeeps(), let first = keeps.first else { return nil }
        let outcome = run(first)
        for manifest in keeps.dropFirst() { _ = run(manifest) }
        return (first, outcome)
    }

    /// Whether the conversion transaction committed: `S`'s database, wherever it is, records the conversion. Only a
    /// database that is absent or positively not a valid database is skipped; one that cannot be inspected now (locked,
    /// unreadable, any other failure) is thrown, never taken for "not committed".
    public func committed(_ manifest: LibraryKeepManifest) throws -> Bool {
        for database in [rootDatabase, source(manifest).database] where !LibraryLocation.isAbsent(database) {
            let identity: LibraryIdentity?
            do { identity = try LibraryDatabaseInspection.identity(of: database) }
            catch where Self.isNotALibrary(error) { continue }
            if let identity, identity.identity == manifest.source,
               identity.keepRole == .converted, identity.keepOperation == manifest.operation { return true }
        }
        return false
    }

    /// Whether the registry already published the Keep (phase 6's last write): `S`'s entry replaced by a published
    /// `conversions` entry. Recorded in that entry, so removing the previous library afterwards never makes a published
    /// Keep look unfinished; a crash before the manifest says `published` changes nothing.
    func published(_ manifest: LibraryKeepManifest) throws -> Bool {
        let registry = try registryFile.read()
        return registry.conversions.contains { $0.operation == manifest.operation && $0.state == LibraryRegistry.Conversion.published }
            && registry.library(manifest.source) == nil
    }

    // MARK: - Running

    /// Phases 2–7 from wherever the Keep is. Before the commit every run starts again at the capture (a retried
    /// capture replaces the earlier one); after it the Keep only goes forward.
    public func run(_ start: LibraryKeepManifest) -> Outcome {
        var manifest = start
        do {
            // Published Keeps only clean up: after a second Keep, the first one's library is no longer where it was.
            if try published(manifest) {
                do { try cleanup(manifest) } catch { return .cleanupPending }
                return .finished
            }
            if try !committed(manifest) {
                do {
                    try capture(&manifest)
                    try prepare(&manifest)
                    try archiveMark(&manifest)
                    try convert(&manifest)
                } catch {
                    // After the COMMIT a lagging manifest is corrected from the database's mark: the Keep goes on.
                    if (try? committed(manifest)) == true {
                        if error is LibraryKeepInterruption { return .notPublished(.interrupted) }
                        manifest.phase = .converted
                    } else {
                        if error is LibraryKeepInterruption { return .notCommitted(.interrupted) }
                        let failure = KeepFailure(error)
                        manifest.failure = failure
                        try? writeManifest(manifest)
                        return .notCommitted(failure)
                    }
                }
            }
            do { try publish(&manifest) }
            catch is LibraryKeepInterruption { return .notPublished(.interrupted) }
            catch {
                let failure = KeepFailure(error)
                manifest.failure = failure
                try? writeManifest(manifest)
                return .notPublished(failure)
            }
            do { try cleanup(manifest) }
            catch { return .cleanupPending }
            return .finished
        } catch {
            return .notCommitted(KeepFailure(error))
        }
    }

    // MARK: - Phase 2: capture

    func capture(_ manifest: inout LibraryKeepManifest) throws {
        let source = source(manifest)
        guard !LibraryLocation.isAbsent(source.database) else { throw LibraryKeepError.sourceMissing }
        try step(.captureCheckpoint)
        // The library from before signing in: an install that never opened it still has its empty root library.
        if LibraryLocation.isAbsent(rootDatabase) { try LibrarySQLite(url: rootDatabase).close() }
        try Self.checkpoint(source.database)
        try Self.checkpoint(rootDatabase)
        guard let sourceIdentity = try LibraryDatabaseInspection.identity(of: source.database), sourceIdentity.identity == manifest.source,
              let oldIdentity = try LibraryDatabaseInspection.identity(of: rootDatabase) else { throw LibraryKeepError.notReady }
        var capture = LibraryKeepManifest.Capture()
        capture.oldIdentity = oldIdentity.identity
        capture.oldCastTag = oldIdentity.castTag
        capture.sourceCastTag = sourceIdentity.castTag
        // S's effective account policies, records plus pending overlays (without a value the action shows as "inbox").
        let policies = ServerAccountPolicyValues.read(database: source.database) ?? ServerAccountPolicyValues()
        capture.sourcePolicies = .init(policies)
        capture.sourcePlayback = try Self.readPlaybackLibrary(source.playbackLibraryFile!)
        // The old library's own values from the root files.
        let speeds = try Self.decode(PlaybackSpeedPreferences.self, root.appendingPathComponent("playback-speed-preferences.json")) ?? .init()
        var old = PlaybackLibraryData()
        old.speeds.feeds = speeds.feeds; old.speeds.feedSilence = speeds.silence.feeds
        old.speeds.currentEpisodeID = speeds.currentEpisodeID
        old.speeds.temporary = speeds.temporary; old.speeds.temporarySilence = speeds.silence.temporary
        if let shownotes = try Self.decode(ShownotesPosition.self, root.appendingPathComponent("shownotes-scroll.json")) {
            old.shownotes = .init(episodeID: shownotes.episodeID, offset: shownotes.offset)
        }
        capture.oldPlayback = old
        let download = try Self.decode(DownloadPreferences.self, root.appendingPathComponent("download-preferences.json")) ?? .init()
        let queue = try Self.decode(QueueInteractionPreferences.self, root.appendingPathComponent("queue-interaction.json")) ?? .init()
        capture.oldPolicies = .init(newEpisodesAction: download.newEpisodesAction, enqueueLocation: download.enqueueLocation,
                                    keepSorted: queue.keepSorted, keepSortedOrderName: queue.keepSortedOrderName)
        // Both libraries' owned files, S's secret-only credentials and pinned removals.
        let reader = try LibrarySQLite(readingOnly: source.database)
        defer { try? reader.close() }
        try reader.transaction(write: false) {
            capture.sourceFiles = try Self.ownedFiles(reader)
            capture.secretOnlyCredentials = try reader.rows("SELECT credential_id FROM ntp_secrets WHERE credential_id NOT IN (SELECT credential_id FROM feed_credentials) ORDER BY credential_id")
                .compactMap { $0[0].text }
            var pinned = Set(try reader.rows("SELECT feed_id FROM ntp_podcasts WHERE pinned_removal = 1 AND feed_id IS NOT NULL").compactMap { $0[0].integer })
            if try reader.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'ntp_hidden_feeds'") == 1 {
                pinned.formUnion(try reader.rows("SELECT feed_id FROM ntp_hidden_feeds WHERE state = 'removing'").compactMap { $0[0].integer })
            }
            capture.pinnedRemovals = pinned.sorted()
        }
        let oldReader = try LibrarySQLite(readingOnly: rootDatabase)
        defer { try? oldReader.close() }
        capture.oldFiles = try oldReader.transaction(write: false) { try Self.ownedFiles(oldReader) }
        manifest.capture = capture
        manifest.phase = .captured
        manifest.failure = nil
        try step(.captureWrite)
        try writeManifest(manifest)
    }

    // MARK: - Phase 3: prepare

    func prepare(_ manifest: inout LibraryKeepManifest) throws {
        guard let capture = manifest.capture else { throw LibraryKeepError.notReady }
        let archive = archive(manifest)
        try step(.preparePrevious)
        try FileManager.default.createDirectory(at: archive.folder, withIntermediateDirectories: true)
        if let existing = try Self.decode(PreviousLibraryDescription.self, archive.descriptionFile), existing.operation != manifest.operation {
            // Never anything of another operation.
            throw LibraryKeepError.foreignLeftovers
        }
        let description = PreviousLibraryDescription(identity: capture.oldIdentity ?? "", keptAt: manifest.keptAt, operation: manifest.operation,
                                                     policies: capture.oldPolicies, castTag: capture.oldCastTag)
        try environment.files.write(try Self.encoder.encode(description), archive.descriptionFile)
        try environment.files.write(try Self.encoder.encode(capture.oldPlayback), archive.playbackLibraryFile)
        try step(.preparePolicies)
        let source = source(manifest)
        try environment.files.write(try Self.encoder.encode(capture.sourcePolicies), source.folder.appendingPathComponent(LibraryLocation.accountPoliciesName))
        try step(.prepareMarkers)
        let operation = manifest.operation
        let marker = { (identity: String) in LibraryFolderMarker(identity: identity, operation: operation) }
        for (folder, identity) in [(rootMedia, capture.oldIdentity ?? ""), (rootCache, capture.oldIdentity ?? ""),
                                   (source.media, manifest.source), (source.streamingCache, manifest.source)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try environment.files.write(try Self.encoder.encode(marker(identity)), folder.appendingPathComponent(Self.markerName))
        }
        manifest.phase = .prepared
        try step(.prepareWrite)
        try writeManifest(manifest)
    }

    // MARK: - Phase 4: archive mark

    func archiveMark(_ manifest: inout LibraryKeepManifest) throws {
        try step(.archiveMark)
        let database = try LibrarySQLite(url: rootDatabase)
        defer { try? database.close() }
        try database.transaction {
            guard let identity = try database.libraryIdentity(), identity.identity == manifest.capture?.oldIdentity else {
                throw LibraryKeepError.notReady
            }
            try database.execute("UPDATE library_identity SET keep_operation = ?, keep_role = 'archived', archive_id = ? WHERE id = 1",
                                 [.text(manifest.operation), .text(manifest.archive)])
        }
        manifest.phase = .archived
        try step(.archiveWrite)
        try writeManifest(manifest)
    }

    // MARK: - Phase 5: the conversion (the Keep's commit)

    func convert(_ manifest: inout LibraryKeepManifest) throws {
        try step(.convert)
        let database = try LibrarySQLite(url: source(manifest).database)
        defer { try? database.close() }
        try database.transaction {
            guard let identity = try database.libraryIdentity(), identity.identity == manifest.source else { throw LibraryKeepError.notReady }
            try Self.convert(database, operation: manifest.operation)
        }
        manifest.phase = .converted
        manifest.failure = nil
        try step(.convertWrite)
        try writeManifest(manifest)
    }

    /// The conversion transaction's body (PROTOCOL §15.4–6), inside the caller's transaction.
    static func convert(_ database: LibrarySQLite, operation: String) throws {
        func has(_ table: String) throws -> Bool {
            try database.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]) == 1
        }
        // 1. Statistics units projected once more, every unretired local reset applied: they belong to local IDs now.
        try database.execute("DELETE FROM statistics_units")
        try ServerStatisticsUnits.backfill(database)
        // 2. A podcast removed elsewhere while its episode is selected stays hidden (PROTOCOL §6.8), and so does a removal whose
        // rows were still being deleted in bounded transactions: the standalone deletion finishes both.
        try database.execute("INSERT OR IGNORE INTO pinned_feed_removals(feed_id) SELECT feed_id FROM ntp_podcasts WHERE pinned_removal = 1 AND feed_id IN (SELECT id FROM feeds)")
        if try has("ntp_hidden_feeds") {
            try database.execute("INSERT OR IGNORE INTO pinned_feed_removals(feed_id) SELECT feed_id FROM ntp_hidden_feeds WHERE state = 'removing' AND feed_id IN (SELECT id FROM feeds)")
            // A staging that never reached its unit was never shown and holds nothing of the person's: taken out.
            if try has("ntp_hidden_episodes") {
                try database.execute("DELETE FROM episodes WHERE id IN (SELECT episode_id FROM ntp_hidden_episodes)")
            }
            try database.execute("DELETE FROM feeds WHERE id IN (SELECT feed_id FROM ntp_hidden_feeds WHERE state = 'staging')")
        }
        // The player's hold of such a podcast's episode ends with the account (PROTOCOL §6.8): its saved selection and
        // session go, so the standalone deletion finishes it at once; nothing else of the player changes.
        let held = "SELECT id FROM episodes WHERE feed_id IN (SELECT feed_id FROM pinned_feed_removals)"
        try database.execute("DELETE FROM playback_session WHERE episode_id IN (\(held))")
        try database.execute("DELETE FROM playback_selection WHERE episode_id IN (\(held))")
        // 3. Secret-only feed credentials go to the existing cleanup; feed_credentials and its items stay.
        try database.execute("INSERT OR IGNORE INTO feed_credential_cleanup(credential_id) SELECT credential_id FROM ntp_secrets WHERE credential_id NOT IN (SELECT credential_id FROM feed_credentials)")
        // 4. Stored paths stay as written; `paths_root` maps them wherever the library is.
        // 5. Server state goes: the ntp_library row and every ntp_* table (remote values waiting for the player too).
        for name in try database.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'ntp\\_%' ESCAPE '\\' ORDER BY name").compactMap({ $0[0].text }) {
            try database.execute("DELETE FROM \"\(name)\"")
        }
        // So does the server library's device-local play time on each episode (`playedHereMilliseconds`, what its
        // rewind after a pause measures from): a standalone library never updates it. Every
        // other field stays exactly as it was, the last-played date included; records are rewritten with the store's own
        // deterministic encoding, so only that key goes.
        for row in try database.rows("SELECT id, record FROM episodes WHERE instr(CAST(record AS TEXT), '\"playedHereMilliseconds\"') > 0") {
            guard let id = row[0].integer, let data = row[1].data else { throw FeedLibraryError.corruptRecord }
            let stored = try JSONDecoder.libraryRecord(LibraryEpisode.self, from: data)
            var episode = stored
            episode.userState.playedHereMilliseconds = nil
            try database.execute("UPDATE episodes SET record = ? WHERE id = ?",
                                 [.blob(try FeedLibraryStore.encodedEpisodeRecord(episode, replacing: stored)), .integer(id)])
        }
        // And each podcast's server refresh status: a library that no longer syncs with a server shows none. This
        // device's own refresh outcome and times stay as they were.
        for row in try database.rows("SELECT id, record FROM feeds WHERE instr(CAST(record AS TEXT), '\"serverRefresh\"') > 0") {
            guard let id = row[0].integer, let data = row[1].data else { throw FeedLibraryError.corruptRecord }
            var feed = try JSONDecoder.libraryRecord(LibraryFeed.self, from: data)
            feed.serverRefresh = nil
            try database.execute("UPDATE feeds SET record = ? WHERE id = ?", [.blob(try FeedLibraryStore.encodedFeedRecord(feed)), .integer(id)])
        }
        // 6. The conversion is recorded; the library's identity and Cast tag stay its server library ID.
        try database.execute("UPDATE library_identity SET keep_operation = ?, keep_role = 'converted', archive_id = NULL WHERE id = 1", [.text(operation)])
    }

    // MARK: - Phase 6: publication

    func publish(_ manifest: inout LibraryKeepManifest) throws {
        let source = source(manifest), archive = archive(manifest)
        guard let oldIdentity = manifest.capture?.oldIdentity ?? (try? Self.decode(PreviousLibraryDescription.self, archive.descriptionFile))?.identity else {
            throw LibraryKeepError.notReady
        }
        try step(.publishCheckpoint)
        for database in [rootDatabase, source.database, archive.database] where !LibraryLocation.isAbsent(database) {
            try Self.checkpoint(database)
        }
        try FileManager.default.createDirectory(at: archive.folder, withIntermediateDirectories: true)
        // The old library into the archive, then S into the root; each recognized by content when done already.
        try step(.renameOldDatabase)
        if try Self.identity(rootDatabase)?.identity == oldIdentity {
            try LibraryMoveLock.withLock { try moveDatabase(from: rootDatabase, to: archive.database) }
        }
        try step(.renameOldMedia)
        try moveFolder(rootMedia, to: archive.media, identity: oldIdentity)
        try step(.renameOldCache)
        try moveFolder(rootCache, to: archive.streamingCache, identity: oldIdentity)
        try step(.renameSourceDatabase)
        if try Self.identity(source.database)?.identity == manifest.source {
            guard LibraryLocation.isAbsent(rootDatabase) else { throw LibraryKeepError.notReady }
            try LibraryMoveLock.withLock { try moveDatabase(from: source.database, to: rootDatabase) }
        }
        try step(.renameSourceMedia)
        try moveFolder(source.media, to: rootMedia, identity: manifest.source)
        try step(.renameSourceCache)
        try moveFolder(source.streamingCache, to: rootCache, identity: manifest.source)
        // Background transfers' records follow their folders.
        try step(.publishTransfers)
        LibraryMoveLock.withLock {
            BackgroundMediaDownloads.normalizeRecords(mediaFolder: archive.media, identity: oldIdentity)
            BackgroundMediaDownloads.normalizeRecords(mediaFolder: rootMedia, identity: manifest.source)
        }
        // The root settings from S's own files as they are now, never the capture.
        try writeSettings(source: source)
        try step(.publishRegistry)
        let previous = LibraryRegistry.PreviousLibrary(id: manifest.archive, identity: oldIdentity, keptAt: manifest.keptAt)
        try registryFile.update { registry in
            registry.libraries.removeAll { $0.id == manifest.source }
            registry.conversions.removeAll { $0.operation == manifest.operation }
            registry.conversions.append(.init(operation: manifest.operation, library: manifest.source, previous: manifest.archive))
            if !registry.previous.contains(where: { $0.id == manifest.archive }) { registry.previous.append(previous) }
            registry.standaloneIdentity = manifest.source
            registry.active = .standalone
            registry.pendingSwitch = nil
        }
        manifest.phase = .published
        manifest.failure = nil
        try step(.publishWrite)
        try writeManifest(manifest)
    }

    /// The root speed file's library-owned values replaced by S's (never merged: local IDs collide), the shownotes
    /// position replaced, and the account policies made the device values. Each write sets values from S's files as
    /// they are at that moment, so repeating it changes nothing.
    func writeSettings(source: LibraryLocation) throws {
        let playback = try Self.readPlaybackLibrary(source.playbackLibraryFile!)
        let policies = try Self.decode(AccountPolicyValuesFile.self, source.folder.appendingPathComponent(LibraryLocation.accountPoliciesName))
            ?? AccountPolicyValuesFile(ServerAccountPolicyValues())
        try step(.settingsSpeeds)
        let speedsFile = root.appendingPathComponent("playback-speed-preferences.json")
        var speeds = try Self.decode(PlaybackSpeedPreferences.self, speedsFile) ?? .init()
        speeds.feeds = playback.speeds.feeds; speeds.silence.feeds = playback.speeds.feedSilence
        speeds.currentEpisodeID = playback.speeds.currentEpisodeID
        speeds.temporary = playback.speeds.temporary; speeds.silence.temporary = playback.speeds.temporarySilence
        try environment.files.write(try JSONEncoder().encode(speeds), speedsFile)
        try step(.settingsShownotes)
        let shownotesFile = root.appendingPathComponent("shownotes-scroll.json")
        if let shownotes = playback.shownotes {
            try environment.files.write(try JSONEncoder().encode(ShownotesPosition(episodeID: shownotes.episodeID, offset: shownotes.offset)), shownotesFile)
        } else { try environment.files.remove(shownotesFile) }
        try step(.settingsDownload)
        let downloadFile = root.appendingPathComponent("download-preferences.json")
        var download = try Self.decode(DownloadPreferences.self, downloadFile) ?? .init()
        download.newEpisodesAction = policies.newEpisodesAction
        download.enqueueLocation = policies.enqueueLocation
        try environment.files.write(try JSONEncoder().encode(download), downloadFile)
        try step(.settingsQueue)
        let queueFile = root.appendingPathComponent("queue-interaction.json")
        var queue = try Self.decode(QueueInteractionPreferences.self, queueFile) ?? .init()
        queue.keepSorted = policies.keepSorted
        queue.keepSortedOrderName = policies.keepSortedOrderName
        try environment.files.write(try JSONEncoder().encode(queue), queueFile)
    }

    /// A database with any `-wal`, `-shm` and `-journal` file still beside it, under the move lock.
    func moveDatabase(from: URL, to: URL) throws {
        guard LibraryLocation.isAbsent(to) else { throw LibraryKeepError.foreignLeftovers }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: from.path + suffix)
            if !LibraryLocation.isAbsent(sidecar) { try environment.files.rename(sidecar, URL(fileURLWithPath: to.path + suffix)) }
        }
        try environment.files.rename(from, to)
    }

    /// A media or cache folder, moved when its marker names `identity`; a folder already moved (its marker at the
    /// target) is left as it is.
    func moveFolder(_ from: URL, to: URL, identity: String) throws {
        if Self.marker(in: to)?.identity == identity { return }
        guard Self.marker(in: from)?.identity == identity else {
            // Neither here nor there: prepare made both folders with their markers, so this is not this Keep's folder.
            if LibraryLocation.isAbsent(from) && LibraryLocation.isAbsent(to) {
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
                return
            }
            throw LibraryKeepError.foreignLeftovers
        }
        guard LibraryLocation.isAbsent(to) else { throw LibraryKeepError.foreignLeftovers }
        try LibraryMoveLock.withLock { try environment.files.rename(from, to) }
    }

    // MARK: - Phase 7: cleanup

    /// Never blocks opening: a locked Keychain or any failure leaves the rest for the next graph start, found through
    /// the `conversions` entry.
    func cleanup(_ manifest: LibraryKeepManifest) throws {
        let source = source(manifest), archive = archive(manifest)
        try step(.cleanupFolder)
        try environment.files.remove(source.folder)
        try step(.cleanupTokens)
        try environment.secrets.removeLibrary(manifest.source)
        try step(.cleanupMarkers)
        // Only this Keep's markers: a later Keep's (whose publication may still need them) stay.
        for folder in [rootMedia, rootCache, archive.media, archive.streamingCache] where Self.marker(in: folder)?.operation == manifest.operation {
            try environment.files.remove(folder.appendingPathComponent(Self.markerName))
        }
        try step(.cleanupManifest)
        try environment.files.remove(manifestFolder(manifest.operation))
        try step(.cleanupRegistry)
        try registryFile.update { registry in registry.conversions.removeAll { $0.operation == manifest.operation } }
    }

    // MARK: - Opening before publication

    /// The converted library of a committed Keep that is not published yet: its database, `media/` and
    /// `streaming-cache/` wherever their markers show them, never on the registry's or the root folder's word. Nil
    /// when no committed Keep waits for publication.
    public func convertedLibrary(_ manifest: LibraryKeepManifest) throws -> LibraryLocation? {
        guard try committed(manifest), try !published(manifest) else { return nil }
        let source = source(manifest)
        let database = try Self.identity(rootDatabase)?.identity == manifest.source ? rootDatabase : source.database
        // A marker that cannot be read now is thrown, never taken for "not moved yet".
        let media = try Self.recordedMarker(in: rootMedia)?.identity == manifest.source ? rootMedia : source.media
        let cache = try Self.recordedMarker(in: rootCache)?.identity == manifest.source ? rootCache : source.streamingCache
        return LibraryLocation(root: root, convertedLibrary: manifest.source,
                               files: .init(database: database, media: media, streamingCache: cache))
    }

    // MARK: - Helpers

    func step(_ step: Step) throws { try environment.beforeStep(step) }

    public func readManifest(_ operation: String) throws -> LibraryKeepManifest {
        try JSONDecoder().decode(LibraryKeepManifest.self, from: Data(contentsOf: manifestFile(operation)))
    }

    /// The operation's manifest: nil when it is missing or damaged (a request whose write never completed); thrown when
    /// it cannot be read now.
    func recordedManifest(_ operation: String) throws -> LibraryKeepManifest? {
        guard let data = try SavedState.contents(of: manifestFile(operation)) else { return nil }
        return try? JSONDecoder().decode(LibraryKeepManifest.self, from: data)
    }

    func writeManifest(_ manifest: LibraryKeepManifest) throws {
        try FileManager.default.createDirectory(at: manifestFolder(manifest.operation), withIntermediateDirectories: true)
        try environment.files.write(try Self.encoder.encode(manifest), manifestFile(manifest.operation))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T? {
        guard !LibraryLocation.isAbsent(url) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func readPlaybackLibrary(_ url: URL) throws -> PlaybackLibraryData {
        try decode(PlaybackLibraryData.self, url) ?? PlaybackLibraryData()
    }

    static func identity(_ database: URL) throws -> LibraryIdentity? {
        guard !LibraryLocation.isAbsent(database) else { return nil }
        return try LibraryDatabaseInspection.identity(of: database)
    }

    public static func marker(in folder: URL) -> LibraryFolderMarker? {
        (try? Data(contentsOf: folder.appendingPathComponent(markerName))).flatMap { try? JSONDecoder().decode(LibraryFolderMarker.self, from: $0) }
    }

    /// Whether inspecting a database failed because the file is positively not a library database (not SQLite or
    /// damaged, another application's, empty): the only inspection failure recovery may skip.
    static func isNotALibrary(_ error: any Error) -> Bool {
        if SavedState.isCorrupt(error) { return true }
        switch error as? FeedLibraryError {
        case .foreignDatabase?, .unsupportedSchema?: return true
        default: return false
        }
    }

    /// A folder's marker: nil when missing or damaged; thrown when it cannot be read now.
    static func recordedMarker(in folder: URL) throws -> LibraryFolderMarker? {
        try SavedState.contents(of: folder.appendingPathComponent(markerName)).flatMap { try? JSONDecoder().decode(LibraryFolderMarker.self, from: $0) }
    }

    /// Closes every connection's work into the main file: `PRAGMA wal_checkpoint(TRUNCATE)`, its result checked.
    static func checkpoint(_ url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw LibraryKeepError.notReady
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 5_000)
        var log: Int32 = 0, done: Int32 = 0
        let status = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, &log, &done)
        guard status == SQLITE_OK else { throw FeedLibraryError.sqlite(code: status, message: "checkpoint") }
    }

    /// A library's owned files, relative to the folder they were written under.
    static func ownedFiles(_ database: LibrarySQLite) throws -> [String] {
        guard let identity = try database.libraryIdentity() else { return [] }
        let prefix = identity.pathsRoot + "/"
        var files = Set<String>()
        for row in try database.rows("SELECT json_extract(CAST(record AS TEXT), '$.userState.localFileURL') FROM episodes WHERE json_extract(CAST(record AS TEXT), '$.userState.localFileURL') IS NOT NULL") {
            if let path = row[0].text, path.hasPrefix(prefix) { files.insert(String(path.dropFirst(prefix.count))) }
        }
        for row in try database.rows("SELECT record FROM download_jobs WHERE active = 1") {
            guard let data = row[0].data, let job = try? JSONDecoder().decode(LibraryDownloadJob.self, from: data) else { continue }
            let path = job.destination.standardizedFileURL.path
            if path.hasPrefix(prefix) { files.insert(String(path.dropFirst(prefix.count))) }
        }
        return files.sorted()
    }
}

public enum LibraryKeepError: Error, Equatable, Sendable {
    case notAServerLibrary
    case sourceMissing
    /// A library is not where or what the manifest says (a migration that has not run, an unreadable database).
    case notReady
    /// A file of another operation or library is in the way; nothing is overwritten.
    case foreignLeftovers
}

/// Thrown by a test to stand for a process death at a step: nothing more is written, as after a crash.
public struct LibraryKeepInterruption: Error, Equatable, Sendable { public init() {} }

/// Why a Keep has not finished (PROTOCOL §15.5 stalled status row names it as a sentence when it is known).
public enum KeepFailure: String, Codable, Equatable, Sendable {
    /// There is not enough storage.
    case storage
    case other
    /// A simulated crash (tests).
    case interrupted

    init(_ error: any Error) {
        if error is LibraryKeepInterruption { self = .interrupted; return }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError { self = .storage; return }
        if let posix = error as? POSIXError, posix.code == .ENOSPC { self = .storage; return }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) { self = .storage; return }
        if case FeedLibraryError.sqlite(let code, _) = error, code & 0xff == SQLITE_FULL { self = .storage; return }
        self = .other
    }
}

/// `Library Conversions/<operation-id>/manifest.json` (PROTOCOL §15.4): the identities, every location relative to the
/// application root, the phase and the capture. Backed up with the libraries.
public struct LibraryKeepManifest: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case requested, captured, prepared, archived, converted, published }

    /// Phase 2's capture, written before anything is deleted or moved.
    public struct Capture: Codable, Equatable, Sendable {
        public var oldIdentity: String?
        public var oldCastTag: String?
        public var sourceCastTag: String?
        public var sourcePolicies = AccountPolicyValuesFile(ServerAccountPolicyValues())
        public var sourcePlayback = PlaybackLibraryData()
        public var oldPlayback = PlaybackLibraryData()
        public var oldPolicies = AccountPolicyValuesFile(ServerAccountPolicyValues())
        /// Owned files relative to the folder they were written under.
        public var sourceFiles: [String] = []
        public var oldFiles: [String] = []
        public var secretOnlyCredentials: [String] = []
        public var pinnedRemovals: [Int64] = []
        public init() {}
    }

    public var version = 1
    public var operation: String
    /// The server library `S`.
    public var source: String
    /// The previous library `P`.
    public var archive: String
    /// Milliseconds since 1970; the previous library's label (never a folder name).
    public var keptAt: Int64
    public var phase: Phase = .requested
    /// Relative to the application root.
    public var locations: [String: String]
    public var capture: Capture?
    /// Why the last attempt stopped, if it did.
    public var failure: KeepFailure?

    public init(operation: String, source: String, archive: String, keptAt: Int64) {
        self.operation = operation; self.source = source; self.archive = archive; self.keptAt = keptAt
        locations = ["source": LibraryLocation.serverLibrariesFolderName + "/" + source,
                     "archive": PreviousLibraryLocation.folderName + "/" + archive, "root": "."]
    }
}

/// The marker a Keep writes into each library's `media/` and `streaming-cache/` (phase 3): which library the folder
/// belongs to, so a rename that succeeded is recognized even when the manifest did not record it.
public struct LibraryFolderMarker: Codable, Equatable, Sendable {
    public var identity: String
    public var operation: String
}

/// `previous-library.json` (PROTOCOL §15.4): the old library's identity, `kept_at`, its account policies and Cast tag.
public struct PreviousLibraryDescription: Codable, Equatable, Sendable {
    public var identity: String
    public var keptAt: Int64
    public var operation: String
    public var policies: AccountPolicyValuesFile
    public var castTag: String?
    private enum CodingKeys: String, CodingKey { case identity, operation, policies, keptAt = "kept_at", castTag = "cast_tag" }
}

/// The account policies as a file holds them: `account-policies.json` of a converted library until its Keep is
/// published, and a previous library's own values.
public struct AccountPolicyValuesFile: Codable, Equatable, Sendable {
    public var newEpisodesAction: NewEpisodesAction?
    public var enqueueLocation: EnqueueLocation
    public var keepSorted: Bool
    /// The Android enum name (`QueueInteractionPreferences.keepSortedOrderName`).
    public var keepSortedOrderName: String?

    public init(newEpisodesAction: NewEpisodesAction?, enqueueLocation: EnqueueLocation, keepSorted: Bool, keepSortedOrderName: String?) {
        self.newEpisodesAction = newEpisodesAction; self.enqueueLocation = enqueueLocation
        self.keepSorted = keepSorted; self.keepSortedOrderName = keepSortedOrderName
    }

    public init(_ values: ServerAccountPolicyValues) {
        self.init(newEpisodesAction: values.newEpisodesAction, enqueueLocation: values.enqueueLocation,
                  keepSorted: values.keepSorted, keepSortedOrderName: values.keepSortedOrder.rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case newEpisodesAction = "new_episodes_action", enqueueLocation = "enqueue_location", keepSorted = "keep_sorted"
        case keepSortedOrderName = "keep_sorted_order"
    }
}

/// `shownotes-scroll.json`'s format (`ShownotesScrollStore`).
struct ShownotesPosition: Codable, Equatable {
    let episodeID: Int64
    let offset: Double
}

/// The move lock (PROTOCOL §15.4 "One resolution function"): the Keep's renames and every use of an owned path by the background
/// transfer callbacks take it, so a callback sees a folder either before or after its move, never during.
public enum LibraryMoveLock {
    private static let lock = NSRecursiveLock()
    public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// A converted library's account policies until its Keep is published (PROTOCOL §15.4 "Opening before publication"): its own
/// `account-policies.json`, read and written through the `AccountPolicy` facade; the person's later changes are saved
/// there, and publication writes them into the device's files.
@MainActor public final class FileAccountPolicy: AccountPolicyBacking {
    private let file: URL
    private var values: AccountPolicyValuesFile

    public init(file: URL) {
        self.file = file
        values = (try? LibraryKeep.decode(AccountPolicyValuesFile.self, file)) ?? AccountPolicyValuesFile(ServerAccountPolicyValues())
    }

    public var newEpisodesAction: NewEpisodesAction? { values.newEpisodesAction }
    public var enqueueLocation: EnqueueLocation { values.enqueueLocation }
    public var keepSorted: Bool { values.keepSorted }
    public var keepSortedOrder: QueueSortOrder { QueueSortOrder(storedValue: values.keepSortedOrderName) }

    public func setNewEpisodesAction(_ action: NewEpisodesAction) throws { try save { $0.newEpisodesAction = action } }
    public func setEnqueueLocation(_ location: EnqueueLocation) throws { try save { $0.enqueueLocation = location } }
    public func setKeepSorted(_ keepSorted: Bool, order: QueueSortOrder) throws {
        try save { $0.keepSorted = keepSorted; $0.keepSortedOrderName = order.rawValue }
    }

    private func save(_ change: (inout AccountPolicyValuesFile) -> Void) throws {
        var next = values
        change(&next)
        try DurableFile.replace(file, with: LibraryKeep.encoder.encode(next))
        values = next
    }
}

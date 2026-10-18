import Foundation

/// First attachment's applier (PROTOCOL §15.4–7), behind
/// `ServerAttachSnapshotApplier`:
/// builds the server library from its verified attach snapshot in its own folder.
///
/// 4. The snapshot's accepted entries and decisions are archived in `sync.sqlite`, its causal nodes become the known
///    nodes, its records the base (`ntp_records`), all streamed from the spooled pages; then, in one transaction, every
///    record is projected onto rows (nothing local exists: no overlays or pins), admissions are marked seen, and the
///    cursor is set to the snapshot's head. A failure before that transaction commits leaves no projected row.
/// 5. Every secret the records name is fetched first and stored as a library credential (PROTOCOL §6.8).
/// 6. Downloads of the libraries kept on this device are reused by APFS clones (PROTOCOL §15.4).
/// 7. Catch-up by pulls from the snapshot head, applied as units.
///
/// Idempotent: a library whose snapshot was applied (it has a cursor) goes straight to steps 6 and 7.
public struct ServerExchangeAttachApplier: ServerAttachSnapshotApplier {
    let vault: @Sendable () -> any SynchronizationCredentialStore
    let transport: (@Sendable (ServerAttachmentTarget) -> any ServerExchangeTransport)?

    public init(vault: @escaping @Sendable () -> any SynchronizationCredentialStore = {
        KeychainSynchronizationCredentials(service: "org.nottennapod.app.feeds")
    }) {
        self.vault = vault; transport = nil
    }

    /// Tests give a transport of their own.
    init(vault: @escaping @Sendable () -> any SynchronizationCredentialStore,
         transport: @escaping @Sendable (ServerAttachmentTarget) -> any ServerExchangeTransport) {
        self.vault = vault; self.transport = transport
    }

    public func apply(_ snapshot: ServerAttachSnapshot, to library: ServerAttachmentTarget) async throws {
        let exchange = transport?(library) ?? ServerClientExchangeTransport(client: library.client, token: library.token)
        var builder = ServerAttachBuilder(location: library.location, transport: exchange, vault: vault())
        builder.disk = library.disk
        try await builder.build(head: snapshot.head, watermark: snapshot.installWatermark, items: snapshot.forEachItem)
    }
}

/// The account client as the exchange's transport, with the installation's token.
public struct ServerClientExchangeTransport: ServerExchangeTransport {
    let client: ServerClient
    let token: String

    public init(client: ServerClient, token: String) { self.client = client; self.token = token }

    public func send(_ method: String, _ path: String, body: ContractJSON?) async throws -> ContractJSON {
        do { return try await client.send(method, path, body: body, token: token) }
        catch let error as ServerClientError {
            switch error {
            case .unreachable: throw ServerExchangeError.unreachable
            case .notAServer, .invalidAddress: throw ServerExchangeError.notAServer
            case .unauthorized, .wrongCredentials: throw ServerExchangeError.server(status: 401, code: "unauthorized", retryAfter: nil)
            case .forbidden: throw ServerExchangeError.server(status: 403, code: "forbidden", retryAfter: nil)
            case .rateLimited(let wait): throw ServerExchangeError.server(status: 429, code: "rate_limited", retryAfter: wait)
            case .busy(let wait): throw ServerExchangeError.server(status: 503, code: "server_busy", retryAfter: wait)
            case .installationConflict: throw ServerExchangeError.server(status: 409, code: "installation_conflict", retryAfter: nil)
            case .installationSuperseded: throw ServerExchangeError.server(status: 409, code: "installation_superseded", retryAfter: nil)
            case .viewExpired: throw ServerExchangeError.server(status: 410, code: "view_expired", retryAfter: nil)
            case .appNeedsUpdate, .serverNeedsUpdate: throw ServerExchangeError.server(status: 400, code: "version_unsupported", retryAfter: nil)
            case .server(let status, let code): throw ServerExchangeError.server(status: status, code: code ?? "", retryAfter: nil)
            }
        }
    }
}

/// The steps of PROTOCOL §15.4 on one library folder.
struct ServerAttachBuilder {
    let location: LibraryLocation
    let transport: any ServerExchangeTransport
    let vault: any SynchronizationCredentialStore
    var batch = 2_000
    /// Each bulk write (archive batch, base batch, the projection through its COMMIT) is armed with the free space
    /// left beyond the reserve, read anew; a refusal rolls it back and stops with `ServerInsufficientSpace`.
    var disk: ServerBulkDiskPolicy?

    private var budget: Int64? { disk?.budget(at: location.folder) }

    /// The work the library-building transaction did, for measurements.
    struct Report: Sendable { var entries = 0; var decisions = 0; var records = 0; var feeds = 0; var episodes = 0 }

    @discardableResult
    func build(head: String, watermark: Int64, items: ((ContractJSON) throws -> Void) throws -> Void) async throws -> Report {
        guard let syncURL = location.syncDatabase, let staging = location.staging else { throw ServerRecordingError.notAServerLibrary }
        try location.prepare()
        var report = Report()
        let headCursor = try SyncCursor(encoded: head)
        if try !(Self.hasCursor(location.database)) {
            report = try stream(items: items, syncURL: syncURL)
            let secrets = try Self.secretIDs(location.database)
            let store = try FeedLibraryStore(url: location.database)
            do {
                let engine = try ServerSyncEngine(store: store, database: location.database, syncDatabase: syncURL, staging: staging,
                                                  transport: transport, vault: vault)
                try await engine.fetchSecrets(secrets)
                await engine.close()
                let projected = try await store.projectAttachSnapshot(head: headCursor, watermark: watermark, budget: budget)
                report.feeds = projected.feeds; report.episodes = projected.episodes
                try await store.close()
            } catch {
                try? await store.close()
                throw error
            }
        }
        try await reuseDownloads()
        try await catchUp(syncURL: syncURL, staging: staging)
        return report
    }

    static func hasCursor(_ database: URL) throws -> Bool {
        let connection = try LibrarySQLite(readingOnly: database)
        defer { try? connection.close() }
        return try connection.rows("SELECT cursor FROM ntp_library WHERE id = 1").first?.first?.text != nil
    }

    /// Step 4's streaming part: entries and decisions into the archive, causal nodes and records into the library's
    /// `ntp_*` tables, in batches. None of it shows: the library has no projected row until the snapshot is projected.
    private func stream(items: ((ContractJSON) throws -> Void) throws -> Void, syncURL: URL) throws -> Report {
        let archive = try ServerArchive(url: syncURL)
        defer { try? archive.close() }
        let database = try LibrarySQLite(url: location.database)
        defer { try? database.close() }
        guard try database.scalar("SELECT count(*) FROM ntp_library") == 1 else { throw ServerRecordingError.notAServerLibrary }
        // An earlier attempt's base is not this snapshot's (a record may have been removed since): start again, under
        // the write budget too (deleting a large base writes pages).
        try database.withWriteBudget(budget) { try database.transaction {
            for table in ["ntp_records", "ntp_nodes", "ntp_episodes", "ntp_podcasts"] { try database.execute("DELETE FROM \(table)") }
        } }
        var report = Report()
        var entries: [ServerAcceptedEntry] = [], decisions: [ServerDecision] = [], records: [ServerRecord] = []
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        func flush() throws {
            if !entries.isEmpty || !decisions.isEmpty { try archive.archive(entries: entries, decisions: decisions, now: now, budget: budget) }
            try database.withWriteBudget(budget) { try database.transaction {
                for entry in entries where entry.isCausalNode { try Self.addNode(entry.opID, entry.dependencies, to: database) }
                for decision in decisions { try Self.addNode(decision.decisionID, decision.dependencies, to: database) }
                for record in records { try FeedLibraryStore.writeRecord(record, to: database) }
            } }
            report.entries += entries.count; report.decisions += decisions.count; report.records += records.count
            entries.removeAll(keepingCapacity: true); decisions.removeAll(keepingCapacity: true); records.removeAll(keepingCapacity: true)
        }
        try items { item in
            if let accepted = item["accepted"] { entries.append(try ServerAcceptedEntry(accepted)) }
            else if let decision = item["decision"] { decisions.append(try ServerDecision(decision)) }
            else if let record = item["record"] { records.append(try ServerRecord(record)) }
            if entries.count + decisions.count + records.count >= batch { try flush() }
        }
        try flush()
        return report
    }

    /// A snapshot node: known at clock 1, on the frontier until something depends on it (snapshot items are in causal
    /// order, so a node always comes before what depends on it).
    static func addNode(_ id: String, _ dependencies: [String], to database: LibrarySQLite) throws {
        for dependency in dependencies {
            try database.execute("UPDATE ntp_nodes SET frontier = 0 WHERE node_id = ? AND frontier = 1", [.text(dependency)])
        }
        try database.execute("INSERT INTO ntp_nodes(node_id, knowledge_clock, publication_seq, frontier, kind) VALUES (?, 1, 0, 1, 'pulled') ON CONFLICT(node_id) DO NOTHING",
                             [.text(id)])
    }

    /// The secrets the snapshot's credential records name (PROTOCOL §6.8).
    static func secretIDs(_ database: URL) throws -> Set<String> {
        let connection = try LibrarySQLite(readingOnly: database)
        defer { try? connection.close() }
        return Set(try connection.rows("SELECT value FROM ntp_records WHERE entity = 'podcast' AND field_group = 'credentials'").compactMap {
            try $0[0].data.flatMap { try ContractJSON.decode($0)["secret_id"]?.stringValue }
        })
    }

    /// Step 6 (PROTOCOL §15.4): each kept library's downloads of the server's podcasts, cloned into this library's `media/`.
    private func reuseDownloads() async throws {
        // The standalone library, inactive server libraries and previous libraries (PROTOCOL §15.4).
        let others = ((try? LibraryLocation.all(root: location.root)) ?? [])
            .filter { $0.folder.standardizedFileURL != location.folder.standardizedFileURL }.map(\.database)
            + ((try? PreviousLibraryLocation.all(root: location.root)) ?? []).map(\.database)
        let store = try FeedLibraryStore(url: location.database)
        do {
            let podcasts = try await store.serverReusePodcasts()
            let state = try await store.serverExchangeState()
            for database in others {
                guard !LibraryLocation.isAbsent(database), let feeds = try? LibraryDownloadReuse.downloadedFeeds(database: database) else { continue }
                let candidates = LibraryDownloadReuse.candidates(feeds: feeds, podcasts: podcasts,
                                                                 episodeID: LibraryDownloadReuse.plainEpisodeIdentity(namespace: state.namespace))
                guard !candidates.isEmpty else { continue }
                _ = try await LibraryDownloadReuse.clone(candidates, into: store, media: location.media) { episode in
                    try await store.serverLocalEpisode(episode)
                }
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    /// Step 7: catch up by pulls from the snapshot head, applied as units.
    private func catchUp(syncURL: URL, staging: URL) async throws {
        let store = try FeedLibraryStore(url: location.database)
        let engine: ServerSyncEngine
        do {
            engine = try ServerSyncEngine(store: store, database: location.database, syncDatabase: syncURL, staging: staging,
                                          transport: transport, vault: vault)
        } catch {
            try? await store.close()
            throw error
        }
        let report = await engine.exchange()
        await engine.close()
        try await store.close()
        if report.cancelled { throw CancellationError() }
        if report.retryAfter != nil || report.pause != nil || report.waiting {
            throw ServerAttachBuilderError.catchUpIncomplete
        }
    }
}

enum ServerAttachBuilderError: Error, Equatable, Sendable {
    /// The catch-up after the snapshot could not finish now; the next attempt continues from the library's cursor.
    case catchUpIncomplete
}

extension FeedLibraryStore {
    /// Projects every record of an attach snapshot onto this new library's rows, in one transaction (PROTOCOL §15.4):
    /// the podcasts with their episodes, then the queue; admissions are seen; the cursor is the snapshot's head.
    func projectAttachSnapshot(head: SyncCursor, watermark: Int64, budget: Int64? = nil) throws -> (feeds: Int, episodes: Int) {
        guard let context = serverContext else { throw ServerRecordingError.notAServerLibrary }
        try ensureServerExchangeTables()
        return try database.withWriteBudget(budget) { try write(.remote, durable: true) {
            guard try database.rows("SELECT cursor FROM ntp_library WHERE id = 1").first?.first?.text == nil else { return (0, 0) }
            let now = try milliseconds(Date())
            let projector = try unitProjector(context: context, now: now)
            projector.admissionsSeen = true
            var scope = ServerProjectionScope()
            for row in try database.rows("SELECT DISTINCT id FROM ntp_records WHERE entity = 'podcast'") {
                if let id = row[0].text { scope.podcasts[id] = .all }
            }
            scope.queue = true
            try projector.project(scope)
            // Episodes whose podcast came without a subscription record keep their records until it arrives.
            let plan = projector.plan
            if !plan.missingSecrets.isEmpty { throw ServerApplyError.missingSecrets(plan.missingSecrets) }
            var result = ServerUnitResult(seq: head.seq)
            try writePlan(plan, now: now, result: &result)
            try database.execute("UPDATE ntp_library SET knowledge_clock = max(knowledge_clock, 1) WHERE id = 1")
            try database.execute("UPDATE ntp_library SET acked_install_seq = ? WHERE id = 1", [.integer(watermark)])
            try setCursor(head, watermark: watermark)
            return (plan.createdFeeds.count, plan.createdEpisodes.count)
        } }
    }

    /// The server's podcasts this library maps, with their normalized aliases (PROTOCOL §15.4 reuse).
    func serverReusePodcasts() throws -> [LibraryDownloadReuse.Podcast] {
        try database.rows("SELECT p.podcast_id, r.value FROM ntp_podcasts p JOIN ntp_records r ON r.entity = 'podcast' AND r.id = p.podcast_id AND r.field_group = 'identity' WHERE p.feed_id IS NOT NULL AND p.live_generation IS NOT NULL").compactMap { row in
            guard let podcast = row[0].text, let data = row[1].data else { return nil }
            let identity = try ContractJSON.decode(data)
            var aliases = Set((identity["aliases"]?.arrayValue ?? []).compactMap { $0["normalized"]?.stringValue })
            if let url = identity["refresh_url"]?.stringValue { aliases.insert(ContractURL.normalize(ContractURL.stripUserinfo(url))) }
            return LibraryDownloadReuse.Podcast(podcastID: podcast, aliases: aliases)
        }
    }

    /// The local episode of a wire episode.
    func serverLocalEpisode(_ episode: String) throws -> Int64? {
        try database.rows("SELECT local_id FROM ntp_episodes WHERE episode_id = ?", [.text(episode)]).first?.first?.integer
    }
}

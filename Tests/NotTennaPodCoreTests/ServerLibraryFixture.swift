import Foundation
import SQLite3
@testable import NotTennaPodCore

/// A server library on disk for recorder tests (PROTOCOL §15.2): a fresh library with an
/// `ntp_library` row, and readers for what the recorder wrote.
struct ServerLibraryFixture {
    let directory: URL
    let url: URL
    let store: FeedLibraryStore
    let identity: ServerLibraryIdentity
    /// The library's feed-credential store (a Keychain stand-in), adopted by the store as the app's is.
    let vault = MemoryCredentialVault()

    static let now = Date(timeIntervalSince1970: 1_760_000_000)

    init(server: Bool = true, accountID: String = ContractIdentity.randomUUID(), namespace: String = ContractIdentity.randomUUID(),
         installID: String = ContractIdentity.randomUUID()) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ServerLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("library.sqlite")
        store = try FeedLibraryStore(url: url)
        identity = ServerLibraryIdentity(libraryID: ContractIdentity.randomUUID(), serverURL: "http://127.0.0.1:1", serverID: nil,
                                         accountID: accountID, namespace: namespace, username: "alice", installID: installID, deviceMarker: nil)
        _ = FeedAuthentication(store: store, vault: vault)
        if server { try await store.initializeServerLibrary(identity) }
    }

    func close() async { try? await store.close(); try? FileManager.default.removeItem(at: directory) }

    // MARK: Feeds

    static func fetched(_ source: String = "https://example.test/feed.xml", title: String = "Show", count: Int = 4,
                        atom: Bool = false, guidPrefix: String = "guid-", medialess: Set<Int> = []) -> FetchedFeed {
        let items = (1...count).map { number in
            ParsedEpisode(identifier: "\(guidPrefix)\(number)", title: "Episode \(number)",
                          publicationDate: now.addingTimeInterval(Double(number) * 86_400),
                          media: medialess.contains(number) ? nil
                            : ParsedMedia(url: "https://media.example.test/\(title)/\(number).mp3", size: 1_000, durationMilliseconds: 600_000))
        }
        return FetchedFeed(feed: ParsedFeed(format: atom ? .atom : .rss, title: title, episodes: items), source: source,
                           responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
    }

    /// Subscribes (`podcast.subscribe`) and applies a `created` resolution derived from the registration's op ID,
    /// as the server's first registration of a URL resolves.
    @discardableResult
    func subscribeRegistered(_ fetched: FetchedFeed = fetched()) async throws -> (feed: LibraryFeed, podcast: String, generation: String) {
        let feed = try await store.insert(fetched)
        let op = try registrationOp(feedID: feed.id)
        let ids = try created(op)
        try await store.resolveRegistration(opID: op, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
        return (feed, ids.podcast, ids.generation)
    }

    func created(_ op: String) throws -> (podcast: String, generation: String) {
        let podcast = try ContractIdentity.podcastID(namespace: identity.namespace, creatingOpID: op)
        return (podcast, try ContractIdentity.generationID(namespace: identity.namespace, podcastID: podcast, creatingOpID: op))
    }

    func registrationOp(feedID: Int64) throws -> String {
        guard let op = try rows("SELECT op_id FROM ntp_registrations WHERE feed_id = \(feedID) ORDER BY created_at DESC, rowid DESC LIMIT 1").first?.first ?? nil else {
            throw ServerRecordingError.unknownRegistration("feed \(feedID)")
        }
        return op
    }

    // MARK: Reading what was recorded

    struct Fact {
        let installSeq: Int64
        let json: ContractJSON
        var type: String { json["type"]?.stringValue ?? "" }
        var opID: String { json["op_id"]?.stringValue ?? "" }
        var payload: ContractJSON { json["payload"] ?? .null }
        var dependencies: [String] { json["dependencies"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        var targets: [ContractJSON] { json["targets"]?.arrayValue ?? [] }
        /// Episode IDs the payload names (single `episode` or a bulk list).
        var episodeIDs: [String] {
            if let one = payload["episode"]?["episode_id"]?.stringValue { return [one] }
            for key in ["episodes", "observed"] { if let list = payload[key]?.arrayValue { return list.compactMap { $0["episode_id"]?.stringValue } } }
            for key in ["members", "moves"] { if let list = payload[key]?.arrayValue { return list.compactMap { $0["episode"]?["episode_id"]?.stringValue } } }
            return []
        }
    }

    func outbox() throws -> [Fact] {
        try rowsData("SELECT install_seq, fact FROM ntp_outbox ORDER BY install_seq").map {
            Fact(installSeq: Int64($0.0)!, json: try ContractJSON.decode($0.1))
        }
    }

    func outboxCount() throws -> Int { Int(try rows("SELECT count(*) FROM ntp_outbox")[0][0]!)! }

    struct Draft {
        let opID: String, author: String, registration: String, type: String, template: ContractJSON
    }

    func drafts() throws -> [Draft] {
        try rowsData("SELECT op_id || char(9) || author_id || char(9) || registration_op || char(9) || kind, template FROM ntp_drafts ORDER BY author_id, author_seq").map {
            let parts = $0.0.split(separator: "\t").map(String.init)
            return Draft(opID: parts[0], author: parts[1], registration: parts[2], type: parts[3], template: try ContractJSON.decode($0.1))
        }
    }

    func overlays(opID: String) throws -> [[String?]] {
        try rows("SELECT entity, id, property, kind, CAST(value AS TEXT) FROM ntp_overlays WHERE op_id = '\(opID)' ORDER BY entity, id, property")
    }

    /// Every `ntp_*` table's rows, to compare before and after a rolled-back write.
    func serverTables() throws -> [String: [[String?]]] {
        var result: [String: [[String?]]] = [:]
        for name in try rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'ntp_%' ORDER BY name").compactMap({ $0[0] }) {
            result[name] = try rows("SELECT * FROM \(name) ORDER BY rowid")
        }
        return result
    }

    /// The library's synced rows (feeds, episodes, queue, credentials), to compare before and after.
    func libraryRows() throws -> [String: [[String?]]] {
        var result: [String: [[String?]]] = [:]
        for name in ["feeds", "episodes", "queue", "feed_credentials", "playback_session", "playback_selection", "pending_effects"] {
            result[name] = try rows("SELECT * FROM \(name) ORDER BY rowid")
        }
        return result
    }

    func rows(_ sql: String) throws -> [[String?]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw FeedLibraryError.invalidLocation }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FeedLibraryError.sqlite(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_NULL: return nil
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return "" }
                    return Data(bytes: bytes, count: count).base64EncodedString()
                default: return sqlite3_column_text(statement, index).map { String(cString: $0) }
                }
            })
        }
        return result
    }

    private func rowsData(_ sql: String) throws -> [(String, Data)] {
        try rows(sql).map { row in (row[0] ?? "", Data(base64Encoded: row[1] ?? "") ?? Data()) }
    }
}

extension ServerLibraryFixture {
    /// Facts recorded after `count` existing ones.
    func newFacts(after count: Int) throws -> [Fact] { Array(try outbox().dropFirst(count)) }

    func wireID(_ localID: Int64) throws -> String? { try rows("SELECT episode_id FROM ntp_episodes WHERE local_id = \(localID)").first?.first ?? nil }

    func expectedEpisodeID(podcast: String, guid: String) throws -> String {
        try ContractIdentity.episodeID(namespace: identity.namespace, podcastID: podcast, kind: .rssGUID, value: guid)
    }

    /// The queue's keys in queue order, and whether local order equals key order.
    func queueKeys() throws -> [(episode: Int64, key: QueueKey, positionID: String)] {
        try rows("SELECT q.episode_id, k.key, k.position_id FROM queue q LEFT JOIN ntp_queue_keys k ON k.episode_id = q.episode_id ORDER BY q.position").map {
            (Int64($0[0]!)!, try QueueKey(wire: $0[1] ?? "missing"), $0[2] ?? "")
        }
    }

    func queueOrderMatchesKeys() throws -> Bool {
        let keys = try queueKeys().map(\.key)
        let stored = Int(try rows("SELECT count(*) FROM ntp_queue_keys")[0][0]!)!
        return zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 } && stored == keys.count
    }
}

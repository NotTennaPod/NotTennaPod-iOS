import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

/// The first-refresh re-send diagnosis against the pinned server: an Android database of three
/// podcasts of 300 episodes is imported into the account through the server's library import, a phone attaches, and
/// each podcast's first refresh on the phone is tallied by field name (`ObservationDifferenceTally`), the line the
/// shareable synchronization log gets. The publisher's server tells the server's fetches (its User-Agent) from the
/// phone's, so the server's own fetch happens only when a case asks for it.
/// (i) the database holds exactly what the feed says; (ii) the database has durations the feed lacks; (iii) the
/// server fetched the feed before a phone's first refresh; (iv) the feed's enclosure addresses carry a query that
/// depends on the client.
@Suite(.serialized) struct ServerFirstRefreshDiagnosisTests {
    typealias Discovery = ServerDiscoveryScenarioTests

    static let count = 300

    static func items(_ prefix: String, duration: String? = nil, query: String = "") -> [Discovery.Item] {
        (1...count).map { Discovery.Item(guid: "\(prefix)-\($0)", title: "\(prefix) \($0)", day: Double($0),
                                         enclosure: "https://media.example/\(prefix)-\($0).mp3\(query)", duration: duration) }
    }

    static func isServer(_ request: LoopbackHTTPServer.Request) -> Bool {
        request.headers.contains { $0.key.lowercased() == "user-agent" && $0.value.hasPrefix("NotTennaPod-Server") }
    }

    /// Serves `phone` to the app and `server` (nil: unavailable) to the server's fetches.
    static func serve(_ world: ExchangeWorld, _ path: String, phone: Data, server: @escaping @Sendable () -> Data?) {
        world.setResponder(path) { request in
            if Self.isServer(request) {
                guard let body = server() else { return .init(status: 503, body: Data()) }
                return .init(headers: ["Content-Type": "application/rss+xml"], body: body)
            }
            return .init(headers: ["Content-Type": "application/rss+xml"], body: phone)
        }
    }

    /// The account's web session (the library import needs one, with the browser registered as an installation).
    final class WebSession: @unchecked Sendable {
        let base: URL
        private var cookie: String?
        init(base: URL, username: String, password: String) async throws {
            self.base = base
            _ = try await send("POST", "v1/auth/web", ["username": .string(username), "password": .string(password)])
            _ = try await send("POST", "v1/installations", ["install_id": .string(ContractIdentity.randomUUID()),
                "instance_nonce": .string(ContractIdentity.randomUUID()), "name": "Firefox", "app_version": "1.0", "capabilities": ["queue"]])
        }
        @discardableResult func send(_ method: String, _ path: String, _ body: ContractJSON?) async throws -> ContractJSON {
            try ContractJSON.decode(try await data(method, path, body))
        }
        func data(_ method: String, _ path: String, _ body: ContractJSON?) async throws -> Data {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = method
            request.httpShouldHandleCookies = false
            request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
            if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try body.canonicalData()
            }
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let http = response as? HTTPURLResponse
            if let set = http?.value(forHTTPHeaderField: "Set-Cookie"), let pair = set.split(separator: ";").first { cookie = String(pair) }
            guard (200..<300).contains(http?.statusCode ?? 0) else { throw HarnessError.http(http?.statusCode ?? 0, String(decoding: data, as: UTF8.self)) }
            return data
        }
        /// The library import (PROTOCOL §11.5) of an Android database file, followed until it is published.
        func importLibrary(_ file: Data) async throws {
            let fingerprint = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
            let reserved = try await send("POST", "v1/import", ["kind": "android_db", "fingerprint": .string(fingerprint),
                                                                 "size": .integer(Int64(file.count)), "file_name": "AntennaPodBackup.db"])
            guard let id = reserved["import_id"]?.stringValue else { throw HarnessError.server("no import: \(reserved)") }
            _ = try await data("PUT", "v1/import/\(id)/chunks/0", ["data": .string(file.base64EncodedString())])
            _ = try await data("POST", "v1/import/\(id)/finish", .object([:]))
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(120))
            while true {
                let state = try JSONSerialization.jsonObject(with: try await data("GET", "v1/import/\(id)", nil)) as? [String: Any]
                switch state?["status"] as? String {
                case "published": return
                case "failed": throw HarnessError.server("the import failed: \(String(describing: state))")
                default:
                    guard clock.now < deadline else { throw HarnessError.server("the import is still \(String(describing: state))") }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    /// The Android database of a standalone library that subscribed to `paths` as the app fetches them now.
    static func androidDatabase(_ world: ExchangeWorld, _ paths: [String]) async throws -> Data {
        let folder = world.root.appendingPathComponent("android-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        for path in paths {
            guard case .updated(let fetched) = try await FeedFetcher().fetch(FeedFetchRequest(source: world.url(path))) else {
                throw HarnessError.server("no feed at \(path)")
            }
            _ = try await store.insert(fetched)
        }
        let feeds = try await store.feeds()
        try await store.close()
        let contents = LibraryExportContents(identity: ContractIdentity.randomUUID(), serverLibrary: false, feeds: feeds, queue: [],
                                             downloadLog: [], statisticsUnits: [:], credentialIDs: [:])
        return try LibraryExportSource(contents: contents, speeds: .init(), credentials: [:]).databaseData()
    }

    /// A first refresh of the podcast at `path` on `phone`, with its observations recorded, and the tally they made.
    static func firstRefresh(_ world: ExchangeWorld, _ phone: ExchangePhone, _ path: String) async throws -> ObservationDifferenceTally {
        let feed = try #require(try await phone.store.feeds().first { $0.source == world.url(path) })
        _ = await phone.store.takeObservationTallyForTesting()
        try await Discovery.refresh(phone, feed.id)
        return await phone.store.takeObservationTallyForTesting()
    }

    /// Exchanges until the phone's canonical episode records of the podcast at `path` all satisfy `pattern` (SQL LIKE).
    static func canonical(_ world: ExchangeWorld, _ phone: ExchangePhone, _ path: String, like pattern: String) async throws {
        let feed = try #require(try await phone.store.feeds().first { $0.source == world.url(path) })
        let podcast = try #require(try await phone.store.podcastOfFeedForTesting(feed.id))
        _ = try await phone.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
        try await Discovery.exchange(until: {
            try phone.rows("SELECT count(*) FROM ntp_records r JOIN ntp_episodes n ON n.episode_id = r.id WHERE n.podcast_id = '\(podcast)' AND r.entity = 'episode' AND r.field_group = 'metadata' AND CAST(r.value AS TEXT) LIKE '\(pattern)'")
                == [["\(Self.count)"]]
        }, [phone], label: "the server's fetch of \(path)", deadline: .seconds(120))
    }

    @Test func eachCauseOfAFirstRefreshReSendIsNamedByField() async throws {
        try await ExchangeWorld.run { world in
            // (i) and (iii): what the feed says; (ii): the database had durations the feed now lacks; (iv): a query
            // that depends on the client.
            let exact = Discovery.document("Exact", Self.items("ex"))
            let withDurations = Discovery.document("Durations", Self.items("du", duration: "01:00:00"))
            let without = Discovery.document("Durations", Self.items("du"))
            let forApp = Discovery.document("Query", Self.items("qu", query: "?client=app"))
            let forServer = Discovery.document("Query", Self.items("qu", query: "?client=server"))
            let fetches = PlayingFlag()
            Self.serve(world, "/ex.xml", phone: exact) { fetches.value ? exact : nil }
            Self.serve(world, "/du.xml", phone: withDurations) { fetches.value ? without : nil }
            Self.serve(world, "/qu.xml", phone: forApp) { fetches.value ? forServer : nil }
            let file = try await Self.androidDatabase(world, ["ex.xml", "du.xml", "qu.xml"])
            Self.serve(world, "/du.xml", phone: without) { fetches.value ? without : nil }
            try await WebSession(base: world.server.base, username: "alice", password: "alice-password-1").importLibrary(file)
            let a = try await world.attach("A")
            #expect(try await a.store.feeds().count == 3)

            // (i) The imported records are what the feed says: nothing differs.
            let exactTally = try await Self.firstRefresh(world, a, "ex.xml")
            #expect(exactTally.differ == 0, "(i) \(exactTally.line)")
            // (ii) Only the durations the database had differ.
            let durations = try await Self.firstRefresh(world, a, "du.xml")
            #expect(durations.line == "items=\(Self.count) differ=\(Self.count) fields=media.duration:\(Self.count)", "(ii)")
            // (iv) The server's own fetch got another query: the phone's refresh after it sends every item again.
            fetches.value = true
            try await Self.canonical(world, a, "qu.xml", like: "%client=server%")
            let query = try await Self.firstRefresh(world, a, "qu.xml")
            #expect(query.line == "items=\(Self.count) differ=\(Self.count) fields=media.url.query:\(Self.count)", "(iv)")
            // (iii) The server fetched the feed before another phone's first refresh: nothing differs.
            try await Self.canonical(world, a, "du.xml", like: "%\"duration\":0%")
            let b = try await world.attach("B")
            let feed = try #require(try await b.store.feeds().first { $0.source == world.url("du.xml") })
            _ = await b.store.takeObservationTallyForTesting()
            try await Discovery.refresh(b, feed.id)
            // The next exchange writes the tally to the synchronization log, field names only.
            await b.exchange()
            let lines = try await b.engine.logEntries().filter { $0.kind == "observe" }.map(\.detail)
            #expect(lines == ["items=\(Self.count) differ=0 fields=none"], "(iii) \(lines)")
        }
    }
}

extension FeedLibraryStore {
    func takeObservationTallyForTesting() -> ObservationDifferenceTally {
        defer { observationTally = ObservationDifferenceTally() }
        return observationTally
    }
}

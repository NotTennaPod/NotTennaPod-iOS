import Foundation
import Testing
import Synchronization
@testable import NotTennaPodCore

/// The Synchronization log (PROTOCOL §15 "Diagnostics"): newest first, bounded, shared as text, and
/// never a password, token, secret or URL userinfo, whichever path wrote it.
@Suite(.serialized) struct ServerSyncLogTests {
    typealias Agreement = ServerExchangeAgreementTests

    private func archive() throws -> (ServerArchive, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ServerSyncLog-\(UUID())")
        let url = folder.appendingPathComponent("sync.sqlite")
        return (try ServerArchive(url: url), folder)
    }

    @Test func entriesAreNewestFirstAndReadingNeverCreatesTheFile() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ServerSyncLog-\(UUID())/sync.sqlite")
        #expect(try ServerSyncLog.entries(syncDatabase: missing).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path), "reading a library without a log creates nothing")
        let (archive, folder) = try self.archive()
        defer { try? archive.close(); try? FileManager.default.removeItem(at: folder) }
        try archive.log("requested", "synchronize now", now: 1_000)
        try archive.log("push", "favorite.set applied", now: 2_000)
        // The same instant keeps the order of writing.
        try archive.log("pull", "1 commits to 7", now: 2_000)
        let entries = try ServerSyncLog.entries(syncDatabase: archive.url)
        #expect(entries.map(\.kind) == ["pull", "push", "requested"])
        #expect(entries.first == ServerSyncLogEntry(time: 2_000, kind: "pull", detail: "1 commits to 7"))
        #expect(entries.last?.date == Date(timeIntervalSince1970: 1))
    }

    /// Bounded at every write: 30 days, and at most the newest 5,000 entries.
    @Test func theLogKeepsThirtyDaysAndAtMostFiveThousandEntries() throws {
        let (archive, folder) = try self.archive()
        defer { try? archive.close(); try? FileManager.default.removeItem(at: folder) }
        let day: Int64 = 86_400_000
        try archive.log("old", "31 days before", now: 0)
        try archive.log("recent", "29 days before", now: 2 * day)
        try archive.log("now", "today", now: 31 * day)
        #expect(try ServerSyncLog.entries(syncDatabase: archive.url).map(\.kind) == ["now", "recent"])
        try archive.database.transaction {
            for index in 0..<5_010 { try archive.log("push", "entry \(index)", now: 31 * day + Int64(index)) }
        }
        let entries = try ServerSyncLog.entries(syncDatabase: archive.url)
        #expect(entries.count == ServerArchive.logLimit)
        #expect(entries.first?.detail == "entry 5009" && entries.last?.detail == "entry 10", "the oldest go first")
    }

    @Test func theSharedTextHasAHeaderAndOneLinePerEntryNewestFirst() {
        let entries = [ServerSyncLogEntry(time: 1_760_000_100_000, kind: "push", detail: "favorite.set rejected invalid"),
                       ServerSyncLogEntry(time: 1_760_000_000_000, kind: "requested", detail: "synchronize now")]
        let labels = ["push": "Sent", "requested": "Requested"]
        let text = ServerSyncLog.shareText(entries, header: ["Synchronization log", "alice on sync.example.test"],
                                           label: { labels[$0] ?? $0 }, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        #expect(text == """
            Synchronization log
            alice on sync.example.test

            2025-10-09 10:55:00 +02:00  Sent  favorite.set rejected invalid
            2025-10-09 10:53:20 +02:00  Requested  synchronize now

            """)
    }

    @Test func redactionTakesOutUserinfoTokensAndSecretMembers() {
        let token = "ntp1_" + String(repeating: "aB3-_", count: 8) + "xyz"
        let cases: [(String, String)] = [
            ("fetching http://feeduser:p%40ss@example.test/feed.xml failed", "fetching http://example.test/feed.xml failed"),
            ("https://user:p@ss@host.test:8080/a?b=c", "https://host.test:8080/a?b=c"),
            ("HTTPS://only-user@host.test/x", "HTTPS://host.test/x"),
            ("token \(token) refused", "token ntp1_… refused"),
            ("Authorization: Bearer \(token)", "Authorization: Bearer …"),
            ("Authorization=Basic YWxpY2U6c2VjcmV0", "Authorization=Basic …"),
            (#"{"username":"alice","password":"s3cr\"et","approved_origins":[]}"#, #"{"username":"alice","password":"…","approved_origins":[]}"#),
            (#"{"token" : "abc"}"#, #"{"token" : "…"}"#),
            ("login?password=hunter2&next=1", "login?password=…&next=1"),
            ("upstream password: hunter2 request", "upstream password: … request"),
        ]
        for (input, expected) in cases { #expect(ServerSyncLog.redacted(input) == expected, "\(input)") }
        // What the log normally says is kept as it is.
        for kept in ["podcast.subscribe not_applied stale_subscribe", "commit 12: 300 row writes, built in a shadow",
                     "write to alice@example.test", "the server is unreachable", "1 secret fetched", "sign_in no usable login on this device"] {
            #expect(ServerSyncLog.redacted(kept) == kept)
        }
    }

    // MARK: - Answers that echo what was sent

    /// How a server's answer echoes a feed password and the push request it refuses.
    enum Echo: String, CaseIterable, Sendable {
        /// An error code: "upstream password: <password> request <the push request>".
        case plainError
        /// An error code holding JSON: `{"password":"<password>","request":<the push request>}`.
        case quotedError
        /// The same JSON escaped once more inside the code: `{\"password\":\"<password>\"} …`.
        case escapedError
        /// Every push result's status holds the echo.
        case resultStatus
        /// Accepted results whose receipts' outcome and reason hold the echo.
        case receipt
        /// A failure (not a server answer) whose description holds the echo.
        case failureDescription
        /// A system error whose domain is the echo.
        case errorDomain
        /// A failure without values whose description is the echo.
        case describedCase

        var failure: (any Error & Sendable)? {
            switch self {
            case .failureDescription: LeakyFailure(text: "")
            case .errorDomain: NSError(domain: "", code: 7)
            case .describedCase: LeakyCase.echoed
            default: nil
            }
        }
    }

    /// A library with a private feed's login, pushing through the real HTTP decoder (or, for a failure, the real engine)
    /// to a server whose answers echo the password and the request: the log and the text Share exports hold neither
    /// the password nor anything of the request (its feed URL, its facts), and the answer is still logged, as a fixed
    /// description.
    @Test(arguments: Echo.allCases)
    func echoedPasswordsAndRequestsNeverEnterTheLog(echo: Echo) async throws {
        let fixture = try await ServerLibraryFixture()
        let password = "feed-pass-\(UUID().uuidString.prefix(8))"
        let marker = "secret-feed-\(UUID().uuidString.prefix(8))"
        let subscribed = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://private.example.test/\(marker).xml"))
        try await FeedAuthentication(store: fixture.store, vault: fixture.vault)
            .save(.init(username: "feed-user", password: password), feedID: subscribed.feed.id)
        try await fixture.store.setCursorForTesting(try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 0,
                                                                   digest: String(repeating: "0", count: 64)))
        let head = try #require(try await fixture.store.serverExchangeState().cursor?.encoded)
        let http = EchoingServer(echo: echo, password: password, head: head)
        let transport: any ServerExchangeTransport = echo.failure != nil
            ? ServerSyncEngineUnitTests.Transport { path, body in
                let text = "password: \(password) \(body?.canonicalText ?? path)"
                switch echo {
                case .errorDomain: throw NSError(domain: text, code: 7)
                case .describedCase: LeakyCase.text.withLock { $0 = text }; throw LeakyCase.echoed
                default: throw LeakyFailure(text: text)
                }
            }
            : HTTPServerExchangeTransport(base: URL(string: "https://sync.example.test")!, transport: http, token: { "ntp1_" + String(repeating: "A", count: 43) })
        let sync = fixture.directory.appendingPathComponent("sync.sqlite")
        let engine = try ServerSyncEngine(store: fixture.store, database: fixture.url, syncDatabase: sync,
                                          staging: fixture.directory.appendingPathComponent("staging"), transport: transport, vault: fixture.vault)
        _ = await engine.exchange()
        _ = await engine.exchange()
        await engine.close()
        if echo.failure == nil { #expect(http.sentPassword, "the request carried the password, so an echo could") }
        let entries = try ServerSyncLog.entries(syncDatabase: sync)
        let text = entries.map { "\($0.kind) \($0.detail)" }.joined(separator: "\n")
            + ServerSyncLog.shareText(entries, header: ["alice on sync.example.test"], label: { $0 })
        for secret in [password, marker, "private.example.test", "\"operations\"", "\"payload\"", "feed-user", "podcast.subscribe\":"] {
            #expect(!text.contains(secret), "\(echo): the log holds \(secret):\n\(text)")
        }
        let logged: Bool = switch echo {
        case .plainError, .quotedError, .escapedError: entries.contains { $0.kind == "retry" && $0.detail == "HTTP 500 an unrecognized error" }
        case .resultStatus: entries.contains { $0.kind == "push" && $0.detail == "an unrecognized result" }
        case .receipt: entries.contains { $0.kind == "push" && $0.detail.hasSuffix(" an unrecognized outcome an unrecognized reason") }
        case .failureDescription: entries.contains { $0.kind == "error" && $0.detail == "a failure (LeakyFailure)" }
        case .errorDomain: entries.contains { $0.kind == "error" && $0.detail == "an unrecognized failure" }
        case .describedCase: entries.contains { $0.kind == "error" && $0.detail.hasPrefix("a failure (LeakyCase ") }
        }
        #expect(logged, "\(echo): the answer is logged as a fixed description:\n\(text)")
        await fixture.close()
    }

    struct LeakyFailure: Error, CustomStringConvertible { let text: String; var description: String { text } }

    /// A failure without values, described by whatever was handled last.
    enum LeakyCase: Error, CustomStringConvertible {
        case echoed
        static let text = Mutex("")
        var description: String { Self.text.withLock { $0 } }
    }

    /// The server behind the real HTTP decoder: pushes are answered with the echo; pulls with nothing new.
    final class EchoingServer: SynchronizationHTTPTransport, @unchecked Sendable {
        let echo: Echo, password: String, head: String
        private let lock = NSLock()
        private var sent = false
        var sentPassword: Bool { lock.withLock { sent } }
        init(echo: Echo, password: String, head: String) { self.echo = echo; self.password = password; self.head = head }

        func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            func json(_ status: Int, _ object: Any) throws -> SynchronizationHTTPResponse {
                .init(status: status, body: try JSONSerialization.data(withJSONObject: object))
            }
            guard request.url?.path.hasSuffix("/v1/push") == true else {
                return try json(200, ["head": head, "has_more": false, "items": [], "install_watermark": 0])
            }
            lock.withLock { sent = sent || body.contains(password) }
            let request = try ContractJSON.decode(Data(body.utf8))
            let operations = request["operations"]?.arrayValue ?? []
            switch echo {
            case .plainError:
                return try json(500, ["error": "upstream password: \(password) request \(body)", "message": "echo"])
            case .quotedError:
                return try json(500, ["error": "upstream {\"password\":\"\(password)\",\"request\":\(body)}", "message": "echo"])
            case .escapedError:
                let escaped = body.replacingOccurrences(of: "\"", with: "\\\"")
                return try json(500, ["error": "upstream {\\\"password\\\":\\\"\(password)\\\"} \(escaped)", "message": "echo"])
            case .resultStatus:
                return try json(200, ["results": operations.map { ["install_seq": $0["install_seq"]?.integerValue ?? 0,
                                                                   "status": "password: \(password) \(body)"] }])
            case .receipt:
                return try json(200, ["results": operations.map { operation -> [String: Any] in
                    ["install_seq": operation["install_seq"]?.integerValue ?? 0, "status": "accepted",
                     "receipt": ["op_id": operation["fact"]?["op_id"]?.stringValue ?? "", "outcome": "password: \(password)",
                                 "reason": body]]
                }])
            case .failureDescription, .errorDomain, .describedCase:
                return try json(500, ["error": "internal", "message": "unused"])
            }
        }
    }

    // MARK: - The shared header

    /// A sign-in whose answer names the account with a feed password and a fact's body, through the real sign-in
    /// decoder and persisted at attachment: the shared text's header holds none of it, only what this app owns.
    @Test @MainActor func theSharedHeaderHoldsNothingAServerAnswered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ServerSyncLogHeader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let password = "feed-pass-\(UUID().uuidString.prefix(8))", marker = "secret-feed-\(UUID().uuidString.prefix(8))"
        let fact = #"{"operations":[{"fact":{"type":"podcast.subscribe","payload":{"feed_url":"https://private.example.test/"# + marker
            + #".xml"}}}],"secrets":[{"password":""# + password + #""}]}"#
        let echo = "\(password) request \(fact)"
        let server = SignInServer(username: echo)
        let accounts = ServerAccounts(.init(root: root, openLibrary: { .standalone }, requestSwitch: { _, _, _ in }, secrets: MemoryServerSecrets(),
            makeClient: { ServerClient(address: $0, transport: server) }, device: ServerDevice(name: "NotTennaPod on iPhone", appVersion: "test")))
        let address = try #require(ServerAddress(entered: "http://127.0.0.1:18999"))
        let pending = try await accounts.signIn(address, info: try await accounts.info(address), username: "alice", password: "account-password")
        #expect(pending.username == echo, "the answer's account name is taken as it is")
        try await accounts.beginAttachment(pending, scene: nil)
        let entry = try #require(try LibraryRegistryFile(root: root).read().libraries.first)
        #expect(entry.username == echo, "and kept with the library")
        let header = ServerSyncLog.shareHeader(title: "Synchronization log", app: "NotTennaPod 1.0 (1)", library: entry,
                                               serverLine: "Server: %1$@", libraryLine: "Library: %1$@")
        #expect(header == ["Synchronization log", "NotTennaPod 1.0 (1)", "Server: http://127.0.0.1:18999", "Library: \(entry.id)"])
        let text = ServerSyncLog.shareText([ServerSyncLogEntry(time: 0, kind: "requested", detail: "synchronize now")], header: header,
                                           label: { $0 })
        for secret in [password, marker, "private.example.test", "\"operations\"", "podcast.subscribe"] {
            #expect(!text.contains(secret), "the shared text holds \(secret):\n\(text)")
        }
        try? await accounts.logout(scene: nil)
    }

    /// A server that answers `/v1/info` and a sign-in naming the account `username`; nothing else.
    final class SignInServer: SynchronizationHTTPTransport, Sendable {
        let username: String
        init(username: String) { self.username = username }
        func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/info") {
                return .init(status: 200, body: Data(#"{"server_id":"s1","protocol":{"min":1,"max":1}}"#.utf8))
            }
            if path.hasSuffix("/v1/auth/device") {
                let install = try ContractJSON.decode(request.httpBody ?? Data())["install_id"]?.stringValue ?? ""
                let answer: [String: Any] = ["token": "ntp1_" + String(repeating: "B", count: 43), "install_id": install,
                                             "account": ["account_id": ContractIdentity.randomUUID(), "namespace": ContractIdentity.randomUUID(),
                                                         "username": username]]
                return .init(status: 200, body: try JSONSerialization.data(withJSONObject: answer))
            }
            return .init(status: 404, body: Data(#"{"error":"not_found","message":"no"}"#.utf8))
        }
    }

    // MARK: - Owed facts recorded late

    /// A play load whose recording failed owes its queue addition; whoever records it later (an ordinary write before
    /// the exchange, the replay at launch, or the push itself), the next exchange logs it once.
    @Test(arguments: ["an ordinary write", "the launch replay", "the push"])
    func owedQueueAdditionsAreLoggedWhoeverRecordsThem(recordedBy: String) async throws {
        let fixture = try await ServerLibraryFixture()
        let ids = try await fixture.subscribeRegistered().feed.episodes.map(\.id).sorted()
        await fixture.store.injectRecorderFailure(after: 1)
        _ = try await fixture.store.beginPlayback(episodeID: ids[0])
        await fixture.store.injectRecorderFailure(after: nil)
        #expect(try fixture.rows("SELECT count(*) FROM ntp_owed WHERE intent = 'queue.add'") == [["1"]])
        switch recordedBy {
        case "an ordinary write": try await fixture.store.setFavorite(episodeID: ids[1], favorite: true)
        case "the launch replay": try await fixture.store.replayOwedFacts()
        default: break
        }
        if recordedBy != "the push" {
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed WHERE intent = 'queue.add'") == [["0"]], "recorded before the exchange")
        }
        let engine = try await ServerSyncEngineUnitTests.engine(fixture, ServerSyncEngineUnitTests.Transport { _, _ in throw ServerExchangeError.unreachable })
        _ = await engine.exchange()
        _ = await engine.exchange()
        let owed = try await engine.logEntries().filter { $0.kind == "owed" }.map(\.detail)
        #expect(owed == ["1 queue additions made while recording failed are recorded now"], "\(recordedBy): \(owed)")
        await engine.close()
        await fixture.close()
    }

    /// Listening a playback write could not record (`export_owed`) is recorded by a later write,
    /// an ordinary one or the flush before the push; the next exchange logs it once, in fixed words.
    @Test(arguments: ["an ordinary write", "the push"])
    func owedListeningIsLoggedWhoeverRecordsIt(recordedBy: String) async throws {
        let (fixture, ids, _, _) = try await ServerPlaybackRecorderTests.library()
        let player = StorePlayer(fixture.store)
        try await player.load(ids[1])
        try await player.play()
        try await player.listen(15)
        await fixture.store.injectRecorderFailure(after: 1)
        try await player.pause()
        await fixture.store.injectRecorderFailure(after: nil)
        #expect(try await fixture.store.serverExportOwedForTesting())
        if recordedBy == "an ordinary write" {
            try await fixture.store.setFavorite(episodeID: ids[2], favorite: true)
            #expect(try await !fixture.store.serverExportOwedForTesting(), "recorded before the exchange")
        }
        let engine = try await ServerSyncEngineUnitTests.engine(fixture, ServerSyncEngineUnitTests.Transport { _, _ in throw ServerExchangeError.unreachable })
        _ = await engine.exchange()
        _ = await engine.exchange()
        #expect(try await !fixture.store.serverExportOwedForTesting())
        let owed = try await engine.logEntries().filter { $0.kind == "owed" }.map(\.detail)
        #expect(owed == ["listening saved while recording failed is recorded now"], "\(recordedBy): \(owed)")
        await engine.close()
        await fixture.close()
    }

    // MARK: - Recovery's log points

    /// Twelve lowercase letters: of an operation type's form, and none of this app's.
    static func lowercaseWord() -> String { String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! }) }

    /// An operation type is logged only when it is one this app records: anything
    /// else of the same form (a lowercase passphrase, a near miss, a server decision's type) is "?".
    @Test func operationTypesAreLoggedOnlyWhenTheyAreThisAppsOwn() {
        let own = [
            "podcast.subscribe", "podcast.register_preview", "podcast.archive", "podcast.restore", "podcast.unsubscribe",
            "podcast.set_policy", "podcast.set_credentials", "podcast.change_url", "episode.mark_played", "episode.mark_unplayed",
            "episode.reset_position", "episode.restore_state", "episode.leave", "inbox.dismiss", "inbox.dismiss_all", "favorite.set",
            "account.set_discovery_policy", "account.set_queue_policy", "session.start", "session.checkpoint", "session.end",
            "session.finalize", "history.remove", "history.restore", "history.clear", "statistics.reset", "queue.add", "queue.restore",
            "queue.remove", "queue.move", "queue.reorder", "queue.clear", "installation.fork", "catalog.observe", "discovery.propose",
        ]
        for type in own { #expect(ServerLogValue.type(type) == type) }
        for odd: String? in [Self.lowercaseWord(), "correcthorsebatterystaple", "favorite.sets", "favorite_set", "queue.layout",
                             "podcast.resolution", "podcast.subscribe.secret", "a.b", "", nil] {
            #expect(ServerLogValue.type(odd) == "?", "\(odd ?? "nil")")
        }
    }

    /// A change a recovery cannot restore is logged by its operation type only when it is one: a retained fact may be
    /// another device's, as the server sent it, and whatever else its type holds stays out of the log.
    @Test func aRecoveryLogsWhatItCouldNotRestoreInTheFixedVocabulary() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await ServerCopiesTests.subscribed(world)
            await a.exchange()
            let backup = try await world.backUp()
            // Pushed, not pulled: retained with its receipt at the recovery's transition. Its type made into a word of an
            // operation type's form that is none of this app's (a lowercase passphrase); the server refuses it (its
            // receipt no longer covers it).
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            _ = await a.engine.run([.push])
            let marker = Self.lowercaseWord()
            try await a.store.executeForTesting("""
                UPDATE ntp_outbox SET fact = CAST(replace(CAST(fact AS TEXT), '"favorite.set"', '"\(marker)"') AS BLOB)
                WHERE type = 'favorite.set' AND receipt IS NOT NULL
                """)
            try await world.restore(backup)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            _ = await a.engine.exchange()
            let lines = try await a.log().filter { $0.detail.contains("not restored") }.map(\.detail)
            #expect(!lines.isEmpty, "the refused change is logged")
            let form = #/fact( \?| [a-z_.]+)? not restored: (conflict|invalid_receipt|invalid|too_large|blocked)/#
            for line in lines {
                #expect(line.wholeMatch(of: form) != nil && !line.contains(marker), "\(line)")
            }
            await a.close()
        }
    }

    /// A failure planning a new installation ("Sign in again" found this one replaced) is logged by its kind, as every
    /// other failure, never by its description.
    @Test func aFailurePlanningANewInstallationIsLoggedByItsKind() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.device("A")
            try await a.store.close()
            #expect(await a.engine.planNewInstallation() == nil)
            let errors = try await a.log().filter { $0.kind == "error" }.map(\.detail)
            #expect(errors == ["planning a new installation: \(ServerLogValue.failure(FeedLibraryError.closed))"], "\(errors)")
            await a.close()
        }
    }

    // MARK: - Every logged path, with a library full of secrets

    /// A library with a password (the account's), its installation token, a feed credential and a feed subscribed by a
    /// URL with userinfo; then every path that writes the log: pushes and their answers, pulls, applied units, refused
    /// facts, a fetched secret, pauses and resumptions, retries, a cancelled exchange, a network sync may not use, an
    /// error, owed queue additions, a queue safeguard, Force full synchronization and the person's requests. Nothing of
    /// those secrets is in either library's log or in the text the Share button exports, even where a server's answer
    /// or an error echoed them.
    @Test func noLoggedPathWritesAPasswordTokenSecretOrUserinfo() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let token = a.token
            let feedPassword = "feed-pass-\(UUID().uuidString.prefix(8))", credentialPassword = "credential-pass-\(UUID().uuidString.prefix(8))"
            let secretURL = world.url("one.xml").replacingOccurrences(of: "http://", with: "http://feeduser:\(feedPassword)@")
            // A subscription by a URL with userinfo (its login becomes a secret pushed beside the facts) and a feed
            // credential saved for another subscription, in the library's credential store (the Keychain in the app).
            let authentication = FeedAuthentication(store: a.store, vault: a.vault)
            let one = try await a.store.insert(Agreement.fetched(secretURL, title: "One", prefix: "one", count: 4))
            try await Agreement.waitForCatalog(a, feedID: one.id)
            let two = try await a.store.insert(Agreement.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await Agreement.waitForCatalog(a, feedID: two.id)
            try await authentication.save(.init(username: "credential-user", password: credentialPassword), feedID: two.id)
            await a.engine.note("requested", "synchronize now")
            await a.exchange()
            let b = try await world.attach("B")
            // A credential B learns from a pull: its engine fetches the secret.
            try await authentication.save(.init(username: "credential-user", password: credentialPassword + "-2"), feedID: one.id)
            await a.exchange(); await b.exchange()

            // A queue safeguard: B removes most of A's queue.
            _ = try await a.store.enqueue(one.episodes.map(\.id).sorted())
            await a.exchange(); await b.exchange()
            try await b.store.clearQueue()
            await b.exchange(); await a.exchange()

            // A refused fact, and an owed queue addition (the queue is empty now) recorded by the next push.
            let episode = try #require(one.episodes.map(\.id).min())
            let ref = try #require(try await a.store.episodeRefForTesting(episode))
            try await a.store.appendFactForTesting(type: "favorite.set", targets: [ref.target], payload: ["episode": ref.ref, "on": "yes"])
            await a.exchange()
            await a.store.injectRecorderFailure(after: 1)
            _ = try await a.store.beginPlayback(episodeID: episode)
            await a.store.injectRecorderFailure(after: nil)
            await a.run([.push])

            // Answers that carry what was sent: an unknown push status and an error code echoing the token and the
            // URL's userinfo, an error whose description names them, and every pause, retry and wait.
            let echoed = "\(token) \(secretURL) Bearer \(token) {\"password\":\"\(feedPassword)\"}"
            let answers: [@Sendable (String, ContractJSON?) throws -> ContractJSON?] = [
                { path, body in
                    guard path == "v1/push" else { return nil }
                    let seqs = body?["operations"]?.arrayValue?.compactMap { $0["install_seq"]?.integerValue } ?? []
                    return ["results": .array(seqs.map { ["install_seq": .integer($0), "status": .string("odd \(echoed)")] })]
                },
                { _, _ in throw ServerExchangeError.server(status: 500, code: "internal \(echoed)", retryAfter: nil) },
                { _, _ in throw ServerExchangeError.server(status: 413, code: "payload_too_large", retryAfter: nil) },
                { _, _ in throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: secretURL, "Authorization": "Bearer \(token)"]) },
                { _, _ in throw ServerExchangeError.unreachable },
                { _, _ in throw ServerExchangeError.notAServer },
                { _, _ in throw ServerExchangeError.networkNotPermitted },
                { _, _ in throw CancellationError() },
                { _, _ in throw ServerExchangeError.server(status: 409, code: "lineage_unknown", retryAfter: nil) },
                { _, _ in throw ServerExchangeError.server(status: 401, code: "unauthorized", retryAfter: nil) },
            ]
            for answer in answers {
                // Something to push each time.
                let favorite = try await a.store.episode(id: episode)?.userState.isFavorite ?? false
                try await a.store.setFavorite(episodeID: episode, favorite: !favorite)
                a.transport.handler = { method, path, body, server in
                    if let value = try answer(path, body) { return value }
                    return try await server.send(method, path, body: body)
                }
                _ = await a.engine.exchange()
                a.transport.handler = nil
                try await a.engine.resume()
            }
            try await a.store.setServerPause(.versionUnsupported)
            try await a.engine.resume()
            await a.engine.note("requested", "force full synchronization")
            _ = await a.engine.forceFullSynchronization()
            await a.exchange()

            let logs = try [a, b].flatMap { try ServerSyncLog.entries(syncDatabase: try #require($0.location.syncDatabase)) }
            let kinds = Set(logs.map(\.kind))
            for kind in ["requested", "push", "pull", "outcome", "secret", "queue_safeguard", "owed", "retry", "error", "cancelled",
                         "waiting", "paused", "resumed", "full"] {
                #expect(kinds.contains(kind), "the \(kind) path ran: \(kinds.sorted())")
            }
            let text = logs.map { "\($0.kind) \($0.detail)" }.joined(separator: "\n")
                + ServerSyncLog.shareText(logs, header: ["alice on 127.0.0.1"], label: { $0 })
            let body = String(token.dropFirst("ntp1_".count))
            for secret in [token, body, b.token, String(b.token.dropFirst("ntp1_".count)), feedPassword, credentialPassword,
                           "alice-password-1", "feeduser:"] {
                #expect(!text.contains(secret), "the log holds \(secret)")
            }
            #expect(text.contains("an unrecognized result") && text.contains("HTTP 500 an unrecognized error"),
                    "the echoes were logged as fixed descriptions")
        }
    }

    /// Every token a phone's Keychain holds now, with and without its prefix.
    private static func tokens(_ phone: DevicePhone) throws -> [String] {
        try phone.secrets.installIDs(of: phone.libraryID)
            .compactMap { try phone.secrets.installation(library: phone.libraryID, install: $0)?.token }
            .flatMap { [$0, String($0.dropFirst("ntp1_".count))] }
    }

    /// The playback and recovery log points (the merges), with a library full of secrets: playback sessions and
    /// listening a failed recording owed, recorded later; a copy restored onto another device and its new installation;
    /// a server restored from a backup, signed in again, and its recovery: a change it cannot restore whose fact holds
    /// a password, and answers echoing the token and the URL's userinfo. Nothing of those secrets is in either
    /// library's log or in the text the Share button exports.
    @Test func noPlaybackCopyOrRecoveryPathWritesAPasswordTokenSecretOrUserinfo() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.device("A")
            // The feed's password a lowercase word, as an operation type could be written.
            let feedPassword = Self.lowercaseWord(), credentialPassword = "credential-pass-\(UUID().uuidString.prefix(8))"
            let secretURL = world.url("one.xml").replacingOccurrences(of: "http://", with: "http://feeduser:\(feedPassword)@")
            // The library's credential store (the Keychain in the app) holds the URL's login and a feed credential.
            let authentication = FeedAuthentication(store: a.store, vault: a.vault)
            let one = try await a.store.insert(Agreement.fetched(secretURL, title: "One", prefix: "one", count: 4))
            try await ServerCopiesTests.waitForCatalog(a, feedID: one.id)
            let two = try await a.store.insert(Agreement.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await ServerCopiesTests.waitForCatalog(a, feedID: two.id)
            try await authentication.save(.init(username: "credential-user", password: credentialPassword), feedID: two.id)
            await a.exchange()
            var tokens = try Self.tokens(a)
            let ids = one.episodes.map(\.id).sorted()

            // A playback session, and listening its pause could not record, recorded by the next
            // write.
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0])
            try await player.play()
            try await player.listen(30, every: 10)
            await a.store.injectRecorderFailure(after: 1)
            try await player.pause()
            await a.store.injectRecorderFailure(after: nil)
            try await a.store.setFavorite(episodeID: ids[1], favorite: true)
            await a.exchange()

            // A copy on another device with this one's tokens (the marker lost) takes a new
            // installation.
            let copy = try await a.copy("A-copy", root: world.root, keychain: .tokens)
            try await copy.store.markEpisodePlayed(episodeID: ids[2], played: true)
            await copy.exchange()
            tokens += try Self.tokens(copy)

            // The server restored from a backup. A change pushed after it (retained at the transition) whose type is now
            // the feed's password: the server refuses it for good.
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[3], favorite: true)
            _ = await a.engine.run([.push])
            try await a.store.executeForTesting("""
                UPDATE ntp_outbox SET fact = CAST(replace(CAST(fact AS TEXT), '"favorite.set"', '"\(feedPassword)"') AS BLOB)
                WHERE type = 'favorite.set' AND receipt IS NOT NULL
                """)
            try await world.restore(backup)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            tokens += try Self.tokens(a)
            // Recovery requests answered with what was sent echoed back, then as the server answers.
            let echoed = tokens.joined(separator: " ") + " \(secretURL) {\"password\":\"\(feedPassword)\"}"
            let answers: [@Sendable (String) throws -> Void] = [
                { if $0 == "v1/snapshot" { throw ServerExchangeError.server(status: 503, code: "busy \(echoed)", retryAfter: nil) } },
                { if $0 == "v1/sync/recovery/inventory" { throw ServerExchangeError.server(status: 500, code: "internal \(echoed)", retryAfter: nil) } },
                { if $0 == "v1/sync/recovery/upload" {
                    throw URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLStringErrorKey: secretURL, "Authorization": "Bearer \(echoed)"])
                } },
            ]
            for answer in answers {
                a.transport.handler = { method, path, body, server in
                    try answer(path)
                    return try await server.send(method, path, body: body)
                }
                _ = await a.engine.exchange()
            }
            a.transport.handler = nil
            for _ in 0..<3 { _ = await a.engine.exchange() }
            let recovery = try #require(try await a.store.serverRecovery())
            #expect(recovery.finished && recovery.complete == false, "\(recovery)")
            tokens += try Self.tokens(a)

            let logs = try [a, copy].flatMap { try ServerSyncLog.entries(syncDatabase: try #require($0.location.syncDatabase)) }
            let kinds = Set(logs.map(\.kind))
            for kind in ["owed", "copy", "transition", "recovery", "paused", "resumed", "retry"] {
                #expect(kinds.contains(kind), "the \(kind) path ran: \(kinds.sorted())")
            }
            #expect(logs.contains { $0.kind == "owed" && $0.detail == "listening saved while recording failed is recorded now" })
            #expect(logs.contains { $0.kind == "recovery" && $0.detail.contains("not restored") })
            let text = logs.map { "\($0.kind) \($0.detail)" }.joined(separator: "\n")
                + ServerSyncLog.shareText(logs, header: ["alice on 127.0.0.1"], label: { $0 })
            #expect(!tokens.isEmpty)
            for secret in tokens + [feedPassword, credentialPassword, "alice-password-1", "feeduser:"] {
                #expect(!text.contains(secret), "the log holds \(secret)")
            }
            await copy.close()
            await a.close()
        }
    }
}

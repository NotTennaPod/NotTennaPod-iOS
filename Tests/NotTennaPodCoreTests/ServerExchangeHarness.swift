import Foundation
import Testing
@testable import NotTennaPodCore

/// The exchange's world for host tests against the pinned server: a server process, a loopback feed server,
/// and phone libraries in the real library layout, each attached by the real attach applier and exchanging
/// through the real engine.
final class ExchangeWorld: @unchecked Sendable {
    typealias Feed = (title: String, prefix: String, count: Int)
    let server: ExchangeServer
    let feeds: LoopbackHTTPServer
    let root: URL
    private let registry: FeedRegistry
    private(set) var phones: [ExchangePhone] = []

    static func start(feeds: [String: Feed] = ExchangeWorld.defaultFeeds) async throws -> ExchangeWorld {
        let server = try await ExchangeServer.start()
        let registry = FeedRegistry(feeds)
        let loopback = try await LoopbackHTTPServer.start { request in
            let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
            if let response = registry.response(path) { return response }
            guard let feed = registry[path] else { return .init(status: 404, body: Data()) }
            return .init(headers: ["Content-Type": "application/rss+xml"],
                         body: Data(ServerAgreementTests.rss(title: feed.title, prefix: feed.prefix, count: feed.count).utf8))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExchangeWorld-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { try await server.setUp() }
        catch { loopback.stop(); server.stop(); throw error }
        return ExchangeWorld(server: server, feeds: loopback, root: root, registry: registry)
    }

    static let defaultFeeds: [String: Feed] = [
        "/one.xml": ("One", "one", 5), "/one-moved.xml": ("One", "one", 5), "/two.xml": ("Two", "two", 3),
        "/three.xml": ("Three", "three", 3),
    ]

    private init(server: ExchangeServer, feeds: LoopbackHTTPServer, root: URL, registry: FeedRegistry) {
        self.server = server; self.feeds = feeds; self.root = root; self.registry = registry
    }

    /// Changes what a loopback feed serves (a publisher adding episodes).
    func setFeed(_ path: String, _ feed: Feed) { registry[path] = feed }

    /// Serves `response` at `path` instead (a feed document of the test's own, a redirect); nil restores the feed.
    func setResponse(_ path: String, _ response: LoopbackHTTPServer.Response?) { registry.setResponse(path, response) }

    func url(_ path: String) -> String { "http://127.0.0.1:\(feeds.url.port!)/\(path)" }

    /// A new phone: an installation signed in, its library provisioned and attached to the account's snapshot.
    func attach(_ name: String) async throws -> ExchangePhone {
        let phone = try await ExchangePhone.attach(self, name: name)
        phones.append(phone)
        return phone
    }

    func stop() async {
        for phone in phones { await phone.close() }
        feeds.stop()
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs `body` in a fresh world and always stops it.
    static func run(feeds: [String: Feed] = ExchangeWorld.defaultFeeds,
                    _ body: (ExchangeWorld) async throws -> Void) async throws {
        let world = try await start(feeds: feeds)
        do { try await body(world) } catch { await world.stop(); throw error }
        await world.stop()
    }
}

final class FeedRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var feeds: [String: ExchangeWorld.Feed]
    private var responses: [String: LoopbackHTTPServer.Response] = [:]
    init(_ feeds: [String: ExchangeWorld.Feed]) { self.feeds = feeds }
    func response(_ path: String) -> LoopbackHTTPServer.Response? { lock.withLock { responses[path] } }
    func setResponse(_ path: String, _ response: LoopbackHTTPServer.Response?) { lock.withLock { responses[path] = response } }
    subscript(path: String) -> ExchangeWorld.Feed? {
        get { lock.withLock { feeds[path] } }
        set { lock.withLock { feeds[path] = newValue } }
    }
}

/// The pinned server for exchange tests: like the recording harness's process, but it can be
/// stopped and started again on the same data directory and port (an outage, a restart), or
/// replaced by an empty server.
final class ExchangeServer: @unchecked Sendable {
    let port: UInt16
    let directory: URL
    private var process: Process?
    private(set) var setupCode = ""

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var data: URL { directory.appendingPathComponent("data") }

    private init(port: UInt16, directory: URL) { self.port = port; self.directory = directory }

    static func start() async throws -> ExchangeServer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ntp-exchange-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = ExchangeServer(port: try NTPServerProcess.freePort(), directory: directory)
        try await server.launch()
        return server
    }

    /// Starts the process on the data directory (kept across `stop(keepingData: true)`).
    func launch() async throws {
        let process = Process()
        process.executableURL = try NTPServerProcess.binary()
        process.arguments = ["--listen", "127.0.0.1:\(port)", "--data-dir", data.path, "--dev-allow-loopback-feeds", "--refresh-interval", "24h"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if let (_, response) = try? await URLSession.shared.data(from: base.appendingPathComponent("healthz")),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                setupCode = (try? String(contentsOf: data.appendingPathComponent("setup-code"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return
            }
            guard process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        throw HarnessError.server("the server did not start")
    }

    /// Stops the process; the data stays unless `keepingData` is false.
    func stop(keepingData: Bool = false) {
        if let process, process.isRunning {
            process.terminate()
            // Wait for the process to end (a condition), but never forever: `waitUntilExit` can miss the exit.
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process = nil
        if !keepingData { try? FileManager.default.removeItem(at: directory) }
    }

    /// Replaces the data directory with an empty one (a server lost without a backup, scenario 21).
    func wipe() throws {
        stop(keepingData: true)
        try FileManager.default.removeItem(at: data)
    }

    /// Runs the server binary's own command with the server stopped (`backup`, `restore`).
    func command(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = try NTPServerProcess.binary()
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw HarnessError.server("\(arguments.first ?? ""): \(text)") }
        return text
    }

    func setUp(username: String = "alice", password: String = "alice-password-1") async throws {
        _ = try await NTPClient(base: base).send("POST", "v1/setup",
            ["username": .string(username), "password": .string(password), "setup_code": .string(setupCode)], origin: true)
    }

    func signIn(username: String = "alice", password: String = "alice-password-1", installID: String = ContractIdentity.randomUUID(),
                nonce: String = ContractIdentity.randomUUID()) async throws -> NTPInstallation {
        let answer = try await NTPClient(base: base).send("POST", "v1/auth/device", [
            "username": .string(username), "password": .string(password), "install_id": .string(installID),
            "instance_nonce": .string(nonce),
            "device": ["name": "NotTennaPod on iPhone", "platform": "ios", "app_version": "test",
                       "capabilities": ["favorites", "history", "inbox", "queue", "statistics"]]])
        guard let token = answer["token"]?.stringValue, let account = answer["account"]?["account_id"]?.stringValue,
              let namespace = answer["account"]?["namespace"]?.stringValue else { throw HarnessError.server("sign-in answer \(answer)") }
        return NTPInstallation(client: NTPClient(base: base, token: token), installID: installID, accountID: account, namespace: namespace)
    }
}

/// One phone library in server mode.
final class ExchangePhone: @unchecked Sendable {
    let name: String
    let location: LibraryLocation
    let installation: NTPInstallation
    /// The library's feed credentials (the Keychain in the app): the engine sends and stores secrets here.
    let vault: MemoryCredentialVault
    /// The engine's transport: the server over HTTP, through a proxy a test can make lose, delay or alter answers.
    let transport: ProxyTransport
    private(set) var store: FeedLibraryStore
    private(set) var engine: ServerSyncEngine
    let token: String
    /// Whether the phone's player is playing (PROTOCOL §6.8 pacing and publication budget).
    let playing = PlayingFlag()
    /// Whether the phone's app is in the foreground (a publication over the budget waits until it is not).
    let foreground = PlayingFlag()

    private init(name: String, location: LibraryLocation, installation: NTPInstallation, token: String, transport: ProxyTransport,
                 vault: MemoryCredentialVault) throws {
        self.name = name; self.location = location; self.installation = installation; self.token = token
        self.transport = transport; self.vault = vault
        store = try FeedLibraryStore(url: location.database)
        let playing = playing, foreground = foreground
        engine = try ServerSyncEngine(store: store, location: location, transport: transport, vault: vault, isPlaying: { playing.value },
                                      isForeground: { foreground.value })
    }

    static func attach(_ world: ExchangeWorld, name: String) async throws -> ExchangePhone {
        let nonce = ContractIdentity.randomUUID()
        let installation = try await world.server.signIn(nonce: nonce)
        let token = installation.client.token ?? ""
        let libraryID = ContractIdentity.randomUUID()
        let location = LibraryLocation(root: world.root, reference: .server(libraryID))
        // Provisioning: the library's database as a server library, its store closed.
        try location.prepare()
        let provisioning = try FeedLibraryStore(url: location.database)
        try await provisioning.initializeServerLibrary(ServerLibraryIdentity(
            libraryID: libraryID, serverURL: world.server.base.absoluteString, serverID: "test", accountID: installation.accountID,
            namespace: installation.namespace, username: "alice", installID: installation.installID, deviceMarker: ContractIdentity.randomUUID()))
        try await provisioning.close()
        let client = ServerClient(address: ServerAddress(entered: world.server.base.absoluteString)!)
        let snapshot = try await ServerAttachSnapshotDownload(client: client, token: token, installID: installation.installID,
                                                              folder: location.staging!.appendingPathComponent("attach")).run()
        let box = TokenBox(token)
        let transport = ProxyTransport(HTTPServerExchangeTransport(base: world.server.base, token: { box.value }))
        let vault = MemoryCredentialVault()
        try await ServerExchangeAttachApplier(vault: { vault }, transport: { _ in transport })
            .apply(snapshot, to: ServerAttachmentTarget(location: location, libraryID: libraryID, installID: installation.installID,
                                                        token: token, client: client))
        let phone = try ExchangePhone(name: name, location: location, installation: installation, token: token, transport: transport, vault: vault)
        phone.tokenBox = box
        phone.nonce = nonce
        return phone
    }

    /// The installation's transport nonce (PROTOCOL §15.4): signing in again with it resumes the installation.
    var nonce = ""

    /// The token the engine sends (signing in again replaces it, PROTOCOL §15.4).
    var tokenBox = TokenBox("")

    /// Signs in again with this library's installation (PROTOCOL §5 "Sign in again"), on `server`.
    func signInAgain(_ server: ExchangeServer) async throws {
        let installation = try await server.signIn(installID: self.installation.installID, nonce: nonce)
        tokenBox.value = installation.client.token ?? ""
        try await engine.resume()
    }

    /// A full exchange; fails the test on a pause or an unexpected error.
    @discardableResult
    func exchange(sourceLocation: SourceLocation = #_sourceLocation) async -> ServerExchangeReport {
        let report = await engine.exchange()
        #expect(report.error == nil, "\(name): \(report.error ?? "")", sourceLocation: sourceLocation)
        #expect(report.pause == nil, "\(name): paused \(String(describing: report.pause))", sourceLocation: sourceLocation)
        return report
    }

    @discardableResult
    func run(_ steps: [ServerSyncEngine.Step], sourceLocation: SourceLocation = #_sourceLocation) async -> ServerExchangeReport {
        let report = await engine.run(steps)
        #expect(report.error == nil, "\(name): \(report.error ?? "")", sourceLocation: sourceLocation)
        return report
    }

    /// Closes and reopens the store and engine (a relaunch).
    func relaunch() async throws {
        await engine.close()
        try await store.close()
        store = try FeedLibraryStore(url: location.database)
        let playing = playing, foreground = foreground
        engine = try ServerSyncEngine(store: store, location: location, transport: transport, vault: vault, isPlaying: { playing.value },
                                      isForeground: { foreground.value })
    }

    func close() async {
        await engine.close()
        try? await store.close()
    }

    func rows(_ sql: String) throws -> [[String?]] {
        try ServerLibraryFixture.read(location.database, sql)
    }

    /// What this phone shows of the account, keyed by wire IDs (the synced fields of PROTOCOL §15.2).
    func view() async throws -> SyncedView { try await store.syncedViewForTesting() }
}

/// A transport in front of the server: `handler` may answer instead, alter an answer, or fail.
final class ProxyTransport: ServerExchangeTransport, @unchecked Sendable {
    typealias Handler = @Sendable (_ method: String, _ path: String, _ body: ContractJSON?, _ server: any ServerExchangeTransport) async throws -> ContractJSON
    let server: any ServerExchangeTransport
    private let lock = NSLock()
    private var current: Handler?
    private var log: [(path: String, body: ContractJSON?)] = []

    init(_ server: any ServerExchangeTransport) { self.server = server }

    var handler: Handler? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// Every request sent, in order.
    var requests: [(path: String, body: ContractJSON?)] { lock.withLock { log } }

    func send(_ method: String, _ path: String, body: ContractJSON?) async throws -> ContractJSON {
        lock.withLock { log.append((path, body)) }
        if let handler { return try await handler(method, path, body, server) }
        return try await server.send(method, path, body: body)
    }
}

final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String
    init(_ token: String) { self.token = token }
    var value: String {
        get { lock.withLock { token } }
        set { lock.withLock { token = newValue } }
    }
}

final class PlayingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

/// A phone's synced state by wire IDs, comparable across phones.
struct SyncedView: Equatable, CustomStringConvertible {
    struct Podcast: Equatable {
        var subscription: FeedSubscriptionState
        var keepUpdated: Bool
        var newEpisodesAction: NewEpisodesAction
        var source: String
        var title: String?
        var credentials: String?
    }
    struct Episode: Equatable {
        var playState: EpisodePlayState
        var favorite: Bool
        var position: Int32
        var lastPlayed: Int64
        var history: Int64?
        var playedTime: Int64
        var title: String?
    }
    var podcasts: [String: Podcast] = [:]
    var episodes: [String: Episode] = [:]
    var queue: [String] = []
    var policies: ServerAccountPolicyValues?

    var description: String {
        var lines: [String] = []
        for (id, podcast) in podcasts.sorted(by: { $0.key < $1.key }) { lines.append("podcast \(id.prefix(10)) \(podcast)") }
        for (id, episode) in episodes.sorted(by: { $0.key < $1.key }) { lines.append("episode \(id.prefix(10)) \(episode)") }
        lines.append("queue \(queue.map { $0.prefix(10) })")
        lines.append("policies \(String(describing: policies))")
        return lines.joined(separator: "\n")
    }

    var withoutTitles: SyncedView {
        var copy = self
        for key in copy.podcasts.keys { copy.podcasts[key]?.title = nil }
        for key in copy.episodes.keys { copy.episodes[key]?.title = nil }
        return copy
    }

    /// The differences, field by field.
    func differences(from other: SyncedView) -> [String] {
        var result: [String] = []
        for id in Set(podcasts.keys).union(other.podcasts.keys).sorted() where podcasts[id] != other.podcasts[id] {
            result.append("podcast \(id.prefix(12)): \(String(describing: podcasts[id])) vs \(String(describing: other.podcasts[id]))")
        }
        for id in Set(episodes.keys).union(other.episodes.keys).sorted() where episodes[id] != other.episodes[id] {
            result.append("episode \(id.prefix(12)): \(String(describing: episodes[id])) vs \(String(describing: other.episodes[id]))")
        }
        if queue != other.queue { result.append("queue \(queue.map { $0.prefix(8) }) vs \(other.queue.map { $0.prefix(8) })") }
        if policies != other.policies { result.append("policies \(String(describing: policies)) vs \(String(describing: other.policies))") }
        return result
    }
}

extension ServerLibraryFixture {
    /// Rows of a library database, read through its own read-only connection.
    static func read(_ url: URL, _ sql: String) throws -> [[String?]] {
        let connection = try LibrarySQLite(readingOnly: url)
        defer { try? connection.close() }
        return try connection.rows(sql).map { row in
            row.map { value in
                switch value {
                case .integer(let number): String(number)
                case .text(let text): text
                case .blob(let data): data.base64EncodedString()
                case .null: nil
                }
            }
        }
    }
}

extension FeedLibraryStore {
    /// The synced view of the account this library shows (wire IDs; local folders and unregistered previews left out).
    func syncedViewForTesting() throws -> SyncedView {
        var view = SyncedView()
        try database.transaction(write: false) {
            var podcastOfFeed: [Int64: String] = [:]
            for row in try database.rows("SELECT podcast_id, feed_id FROM ntp_podcasts WHERE feed_id IS NOT NULL AND pinned_removal = 0") {
                if let podcast = row[0].text, let feed = row[1].integer { podcastOfFeed[feed] = podcast }
            }
            var wireOfEpisode: [Int64: String] = [:]
            for row in try database.rows("SELECT episode_id, local_id FROM ntp_episodes WHERE local_id IS NOT NULL") {
                if let wire = row[0].text, let local = row[1].integer { wireOfEpisode[local] = wire }
            }
            var credentials: [Int64: String] = [:]
            for row in try database.rows("SELECT f.feed_id, s.secret_id FROM feed_credentials f LEFT JOIN ntp_secrets s ON s.credential_id = f.credential_id") {
                // A credential no secret maps is one the server never held: cleared (empty) credentials.
                if let feed = row[0].integer, let secret = row[1].text { credentials[feed] = secret }
            }
            for feed in try loadFeeds() {
                guard let podcast = podcastOfFeed[feed.id] else { continue }
                view.podcasts[podcast] = .init(subscription: feed.subscriptionState, keepUpdated: feed.keepUpdated,
                                               newEpisodesAction: feed.newEpisodesAction,
                                               source: ContractURL.normalize(ContractURL.stripUserinfo(feed.source)),
                                               title: feed.metadata.title, credentials: credentials[feed.id])
                for episode in feed.episodes {
                    guard let wire = wireOfEpisode[episode.id] else { continue }
                    let state = episode.userState
                    view.episodes[wire] = .init(playState: state.playState, favorite: state.isFavorite, position: state.positionMilliseconds,
                                                lastPlayed: state.lastPlayedTimeMilliseconds, history: state.lastPlayedHistoryMilliseconds,
                                                playedTime: state.playedDurationMilliseconds, title: episode.details.title)
                }
            }
            view.queue = try queueEpisodeIDs().compactMap { wireOfEpisode[$0] }
        }
        view.policies = try serverAccountPolicies()
        return view
    }

    /// Appends a fact to the outbox as a device's recorder would, without changing rows (a test stand-in for
    /// another device's recording, or for a fact the server refuses).
    @discardableResult
    func appendFactForTesting(type: String, targets: [ServerFactTarget], payload: ContractObject, dependencies: [String] = [],
                              overlays: [ServerOverlay] = [], now: Date = Date()) throws -> String {
        guard let context = serverContext else { throw ServerRecordingError.notAServerLibrary }
        let time = try milliseconds(now)
        return try database.transaction {
            try ServerOutboxWriter(database: database, context: context, failAfter: nil)
                .appendFact(type: type, targets: targets, payload: payload, dependencies: dependencies, overlays: overlays,
                            clientTime: time, now: time)
        }
    }

    /// An episode reference `{episode_id, podcast_id, generation_id, occurrence}` of a local episode, from its records.
    func episodeRefForTesting(_ localID: Int64) throws -> (ref: ContractJSON, target: ServerFactTarget)? {
        guard let row = try database.rows("SELECT n.episode_id, n.podcast_id, p.live_generation, n.occurrence FROM ntp_episodes n JOIN ntp_podcasts p ON p.podcast_id = n.podcast_id WHERE n.local_id = ?",
                                          [.integer(localID)]).first,
              let episode = row[0].text, let podcast = row[1].text, let generation = row[2].text else { return nil }
        let occurrence = try row[3].data.map { try ContractJSON.decode($0) } ?? ["k": "none", "v": ""]
        return (["episode_id": .string(episode), "podcast_id": .string(podcast), "generation_id": .string(generation), "occurrence": occurrence],
                ServerFactTarget(entity: "episode", id: episode, generation: generation))
    }

    func localEpisodeForTesting(wire: String) throws -> Int64? {
        try database.rows("SELECT local_id FROM ntp_episodes WHERE episode_id = ?", [.text(wire)]).first?.first?.integer
    }

    func wireEpisodeForTesting(_ local: Int64) throws -> String? {
        try database.rows("SELECT episode_id FROM ntp_episodes WHERE local_id = ?", [.integer(local)]).first?.first?.text
    }

    func feedOfPodcastForTesting(_ podcast: String) throws -> Int64? {
        try database.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.integer
    }

    func podcastOfFeedForTesting(_ feed: Int64) throws -> String? {
        try database.rows("SELECT podcast_id FROM ntp_podcasts WHERE feed_id = ?", [.integer(feed)]).first?.first?.text
    }
}

/// Listening facts as a device records them (here they are written to a library's
/// outbox directly, so two phones can be made to listen to the same episode): one session of an episode.
struct RemoteSession {
    let store: FeedLibraryStore
    let episode: Int64
    let session = ContractIdentity.randomUUID()
    let baseline = ContractIdentity.randomUUID()
    var ordinal: Int64 = 0
    /// The op ID of the session's start: its claim.
    private(set) var startOp: String?

    init(store: FeedLibraryStore, episode: Int64) { self.store = store; self.episode = episode }

    private func reference() async throws -> (ref: ContractJSON, target: ServerFactTarget) {
        guard let ref = try await store.episodeRefForTesting(episode) else { throw HarnessError.server("no reference for \(episode)") }
        return ref
    }

    mutating func start(at position: Int64, now: Date = Date(), dependencies: [String] = []) async throws {
        let ref = try await reference()
        startOp = try await store.appendFactForTesting(type: "session.start", targets: [ref.target], payload: [
            "episode": ref.ref, "session_id": .string(session), "start_position": .integer(position), "activity": true,
            "baseline": .string(baseline)], dependencies: dependencies, now: now)
    }

    mutating func checkpoint(position: Int64, contribution: Int64, now: Date = Date()) async throws {
        let ref = try await reference()
        ordinal += 1
        try await store.appendFactForTesting(type: "session.checkpoint", targets: [ref.target], payload: [
            "episode": ref.ref, "session_id": .string(session), "ordinal": .integer(ordinal), "position": .integer(position),
            "contribution": .integer(contribution), "activity": true], now: now)
    }

    /// The session's end; `duration` is the duration the player measured, reported to the server (PROTOCOL §8).
    mutating func end(position: Int64, contribution: Int64, completed: Bool, duration: Int64? = nil, now: Date = Date()) async throws {
        let ref = try await reference()
        ordinal += 1
        var payload: ContractObject = [
            "episode": ref.ref, "session_id": .string(session), "ordinal": .integer(ordinal), "position": .integer(position),
            "contribution": .integer(contribution), "activity": true, "reason": completed ? "ended" : "switched",
            "completed": .bool(completed), "threshold_ms": 30_000, "remove_from_queue": false, "history": true]
        if let duration { payload["duration"] = .integer(duration) }
        try await store.appendFactForTesting(type: "session.end", targets: [ref.target], payload: payload, now: now)
    }

    /// The lazy finalization of a paused session (PROTOCOL §8): completes only if its claim still owns the position.
    func finalize(completed: Bool, now: Date = Date()) async throws {
        let ref = try await reference()
        try await store.appendFactForTesting(type: "session.finalize", targets: [ref.target], payload: [
            "episode": ref.ref, "session_id": .string(session), "ordinal": .integer(ordinal), "claim_id": .string(startOp ?? ""),
            "completed": .bool(completed), "threshold_ms": 30_000, "remove_from_queue": false, "history": true], now: now)
    }
}

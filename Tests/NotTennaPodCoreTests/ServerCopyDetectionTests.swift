import Foundation
import Testing
@testable import NotTennaPodCore

/// Local copy detection and the installation transition's commit (PROTOCOL §6.10): on the library's own data, without a server. The exchange tests run them against the pinned server.
@Suite(.serialized) struct ServerCopyDetectionTests {
    typealias Fact = ServerLibraryFixture.Fact

    /// A library that wrote as its main author, a resolved registration's author and a pending one's (with drafts).
    static func library() async throws -> (fixture: ServerLibraryFixture, registered: [Int64], pending: [Int64], pendingOp: String) {
        let fixture = try await ServerLibraryFixture()
        // Registered after a draft on its registration's author (materialized at the resolution).
        let feed = try await fixture.store.insert(ServerLibraryFixture.fetched())
        try await fixture.store.setFavorite(episodeID: feed.episodes[0].id, favorite: true)
        let op = try fixture.registrationOp(feedID: feed.id), ids = try fixture.created(op)
        try await fixture.store.resolveRegistration(opID: op, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
        try await fixture.store.setFavorite(episodeID: feed.episodes[1].id, favorite: true)
        let registered = (feed: feed, podcast: ids.podcast)
        let pending = try await fixture.store.insert(ServerLibraryFixture.fetched("https://example.test/pending.xml", title: "Pending"))
        try await fixture.store.setFavorite(episodeID: pending.episodes[0].id, favorite: true)
        try await fixture.store.markEpisodePlayed(episodeID: pending.episodes[1].id, played: true)
        return (fixture, registered.feed.episodes.map(\.id), pending.episodes.map(\.id), try fixture.registrationOp(feedID: pending.id))
    }

    static func author(_ fixture: ServerLibraryFixture, _ id: String) throws -> [String?]? {
        try fixture.rows("SELECT role, next_seq, last_op_id, registration_op, forked_from FROM ntp_authors WHERE author_id = '\(id)'").first
    }

    @Test func aLibraryOnItsOwnDeviceIsNotACopy() async throws {
        let (fixture, _, _, _) = try await Self.library()
        defer { Task { await fixture.close() } }
        let marker = ContractIdentity.randomUUID()
        try await fixture.store.executeForTesting("UPDATE ntp_library SET device_marker = ?", [.text(marker)])
        let before = try fixture.serverTables()
        #expect(try await fixture.store.detectServerCopy(deviceMarker: marker, hasWorkingToken: false) == .same)
        #expect(try fixture.serverTables() == before, "nothing is written")
    }

    /// Every author the library would write again forks before anything else is written (PROTOCOL §6.10): the main author to
    /// `T'`, each registration's current author to a fresh one whose fork is a draft while the registration is pending;
    /// the outbox moves to `T'` from slot 1 unchanged, receipted entries are kept aside, drafts and overlays stay.
    @Test func aCopyForksEveryAuthorAndMovesToANewInstallation() async throws {
        let (fixture, _, _, pendingOp) = try await Self.library()
        defer { Task { await fixture.close() } }
        let main = fixture.identity.installID
        let before = try fixture.outbox()
        let mainTip = try #require(try Self.author(fixture, main)?[2] ?? nil)
        let resolvedOp = try #require(try fixture.rows("SELECT op_id, author_id FROM ntp_registrations WHERE state = 'resolved'").first)
        let resolvedAuthor = try #require(resolvedOp[1]), resolvedTip = try #require(try Self.author(fixture, resolvedAuthor)?[2] ?? nil)
        let pendingAuthor = try #require(try fixture.rows("SELECT author_id FROM ntp_registrations WHERE op_id = '\(pendingOp)'").first?.first ?? nil)
        let pendingTip = try #require(try Self.author(fixture, pendingAuthor)?[2] ?? nil)
        let draftsBefore = try fixture.drafts()
        let overlaysBefore = try fixture.rows("SELECT * FROM ntp_overlays ORDER BY op_id, entity, id, property")
        let frontier = try fixture.rows("SELECT node_id FROM ntp_nodes WHERE frontier = 1 AND kind != 'draft'").compactMap { $0[0] }
        // The first entry was acknowledged: it is kept aside with its receipt, not renumbered.
        let receipt: ContractJSON = ["op_id": .string(before[0].opID), "content_hash": "00", "outcome": "applied", "epoch": 1, "seq": 3, "index": 0]
        try await fixture.store.executeForTesting("UPDATE ntp_outbox SET receipt = ? WHERE install_seq = ?", [.blob(try receipt.canonicalData()), .integer(before[0].installSeq)])

        let marker = ContractIdentity.randomUUID()
        let outcome = try await fixture.store.detectServerCopy(deviceMarker: marker, hasWorkingToken: false)
        guard case .forked(let successor, _, true, 3) = outcome else { Issue.record("\(outcome)"); return }
        #expect(try fixture.rows("SELECT install_id, main_author, device_marker, acked_install_seq, transition FROM ntp_library") == [[successor, successor, marker, "0", nil]])
        #expect(try Self.author(fixture, successor) == ["main", "2", try fixture.outbox().first { $0.type == "installation.fork" && $0.json["author_id"]?.stringValue == successor }?.opID, nil, main])
        #expect(try Self.author(fixture, main)?[2] == mainTip, "the copied main author is never written again")

        let after = try fixture.outbox()
        #expect(after.map(\.installSeq) == Array(1...Int64(after.count)), "slots from 1, contiguous")
        #expect(Array(after.prefix(before.count - 1)).map(\.json) == before.dropFirst().map(\.json), "the unreceipted entries, unchanged and in order")
        #expect(try fixture.rows("SELECT op_id, transport, slot FROM ntp_retained") == [[before[0].opID, main, String(before[0].installSeq)]])
        let forks = after.dropFirst(before.count - 1)
        #expect(forks.map(\.type) == ["installation.fork", "installation.fork"])
        let mainFork = try #require(forks.first { $0.json["author_id"]?.stringValue == successor })
        #expect(mainFork.payload == ["author": .string(main), "head": .string(mainTip)])
        #expect(mainFork.json["author_seq"] == 1 && mainFork.json["previous_op_id"] == nil && mainFork.targets.isEmpty)
        #expect(Set(mainFork.dependencies) == Set(frontier + [mainTip]), "the copied frontier and the head")
        let resolvedFork = try #require(forks.first { $0.json["author_id"]?.stringValue != successor })
        let resolvedForkAuthor = try #require(resolvedFork.json["author_id"]?.stringValue)
        #expect(resolvedFork.payload == ["author": .string(resolvedAuthor), "head": .string(resolvedTip)])
        #expect(try Self.author(fixture, resolvedForkAuthor)?[3] == resolvedOp[0] && Self.author(fixture, resolvedForkAuthor)?[4] == resolvedAuthor)

        // The pending registration: its drafts unchanged, its fork a draft on a fresh author that new drafts use.
        let drafts = try fixture.drafts()
        #expect(drafts.filter { $0.author == pendingAuthor }.map(\.opID) == draftsBefore.map(\.opID))
        let forkDraft = try #require(drafts.first { $0.type == "installation.fork" })
        #expect(forkDraft.registration == pendingOp && forkDraft.author != pendingAuthor)
        #expect(forkDraft.template["payload"] == ["author": .string(pendingAuthor), "head": .string(pendingTip)])
        #expect(try fixture.rows("SELECT author_id FROM ntp_registrations WHERE op_id = '\(pendingOp)'") == [[forkDraft.author]])
        #expect(try fixture.rows("SELECT * FROM ntp_overlays ORDER BY op_id, entity, id, property") == overlaysBefore, "overlays are keyed by op ID")
        // Detection ran once: the library now runs on this device.
        #expect(try await fixture.store.detectServerCopy(deviceMarker: marker, hasWorkingToken: false) == .same)
    }

    /// A copy that still holds a working token plans its transition; the exchange issues it with that token (PROTOCOL §6.10).
    @Test func aCopyWithAWorkingTokenPlansItsTransition() async throws {
        let (fixture, _, _, _) = try await Self.library()
        defer { Task { await fixture.close() } }
        let before = try fixture.outbox()
        guard case .forked(let successor, let nonce, false, _) = try await fixture.store.detectServerCopy(deviceMarker: ContractIdentity.randomUUID(), hasWorkingToken: true) else {
            Issue.record("not planned"); return
        }
        #expect(try fixture.rows("SELECT install_id FROM ntp_library") == [[fixture.identity.installID]], "the installation changes only at the commit")
        let plan = try #require(try await fixture.store.serverTransition())
        #expect(plan == ServerInstallationTransition(installID: successor, transportNonce: nonce, reason: .copy, predecessor: fixture.identity.installID))
        #expect(Array(try fixture.outbox().prefix(before.count)).map(\.json) == before.map(\.json))
        let committed = try #require(try await fixture.store.commitServerTransition())
        #expect(committed.successor == successor && committed.renumbered == before.count + 2 && committed.retained == 0)
        #expect(try fixture.rows("SELECT install_id, next_install_seq, transition FROM ntp_library") == [[successor, String(before.count + 3), nil]])
        #expect(try await fixture.store.serverInstallationID() == successor)
    }

    /// After detection, new facts continue the forks: the main author's chain from its fork, the pending registration's
    /// drafts on its fork; when the registration resolves, the copied author's drafts materialize first, then the
    /// fork's, whose first fact names the copied tip (PROTOCOL §6.10).
    @Test func newFactsContinueTheForksAndDraftsMaterializeInChainOrder() async throws {
        let (fixture, registered, pending, pendingOp) = try await Self.library()
        defer { Task { await fixture.close() } }
        let pendingAuthor = try #require(try fixture.rows("SELECT author_id FROM ntp_registrations WHERE op_id = '\(pendingOp)'").first?.first ?? nil)
        let copiedDrafts = try fixture.drafts().filter { $0.author == pendingAuthor }.map(\.opID)
        guard case .forked(let successor, _, _, _) = try await fixture.store.detectServerCopy(deviceMarker: ContractIdentity.randomUUID(), hasWorkingToken: false) else {
            Issue.record("no fork"); return
        }
        let mainFork = try #require(try Self.author(fixture, successor)?[2] ?? nil)
        let count = try fixture.outboxCount()
        try await fixture.store.setFavorite(episodeID: registered[2], favorite: true)
        let favorite = try #require(try fixture.newFacts(after: count).first)
        #expect(favorite.json["author_id"]?.stringValue == successor && favorite.json["author_seq"] == 2)
        #expect(favorite.json["previous_op_id"]?.stringValue == mainFork)
        try await fixture.store.setFavorite(episodeID: pending[2], favorite: true)
        let forkAuthor = try #require(try fixture.rows("SELECT author_id FROM ntp_registrations WHERE op_id = '\(pendingOp)'").first?.first ?? nil)
        let onFork = try fixture.drafts().filter { $0.author == forkAuthor }
        #expect(onFork.map(\.type) == ["installation.fork", "favorite.set"])
        #expect(try fixture.drafts().filter { $0.author == pendingAuthor }.map(\.opID) == copiedDrafts, "the copied chain is never written again")
        // A history clear defers its cut on the registration's current chain only (PROTOCOL §15.2).
        _ = try await fixture.store.clearPlaybackHistory()
        #expect(try fixture.drafts().filter { $0.type == "history.clear" }.map(\.author) == [forkAuthor])

        let materialized = try fixture.outboxCount()
        let ids = try fixture.created(pendingOp)
        try await fixture.store.resolveRegistration(opID: pendingOp, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
        let facts = try fixture.newFacts(after: materialized)
        #expect(facts.map(\.opID).prefix(copiedDrafts.count) == ArraySlice(copiedDrafts), "the copied author's drafts first")
        let fork = facts[copiedDrafts.count]
        #expect(fork.type == "installation.fork" && fork.json["author_id"]?.stringValue == forkAuthor && fork.json["previous_op_id"] == nil)
        #expect(fork.dependencies.contains(copiedDrafts.last!), "the fork depends on the copied tip")
        #expect(facts.dropFirst(copiedDrafts.count + 1).allSatisfy { $0.json["author_id"]?.stringValue == forkAuthor })
        #expect(try fixture.rows("SELECT count(*) FROM ntp_drafts") == [["0"]])
    }

    /// A registration the server refused dropped its drafts: its author's tip names nothing anyone holds, so it is not
    /// forked (a fork naming it could never be admitted).
    @Test func aRefusedRegistrationsAuthorIsNotForked() async throws {
        let (fixture, _, _, pendingOp) = try await Self.library()
        defer { Task { await fixture.close() } }
        try await fixture.store.executeForTesting("DELETE FROM ntp_drafts")
        try await fixture.store.executeForTesting("UPDATE ntp_registrations SET state = 'resolved', mode = 'refused' WHERE op_id = ?", [.text(pendingOp)])
        guard case .forked(_, _, _, let forks) = try await fixture.store.detectServerCopy(deviceMarker: ContractIdentity.randomUUID(), hasWorkingToken: false) else {
            Issue.record("no fork"); return
        }
        #expect(forks == 2, "the main author and the resolved registration's")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_drafts") == [["0"]])
    }

    /// The transition's commit (PROTOCOL §6.11): framing transaction IDs stay, the parts the old slot stored do not count.
    @Test func theCommitKeepsFramingTransactionsAndForgetsStoredParts() async throws {
        let (fixture, _, _, _) = try await Self.library()
        defer { Task { await fixture.close() } }
        let framing = ServerFraming(transactionID: ContractIdentity.randomUUID(), present: [0, 1])
        try await fixture.store.executeForTesting("UPDATE ntp_outbox SET framing = ?, waiting = ? WHERE install_seq = 2",
                                                  [.blob(try JSONEncoder().encode(framing)), .blob(Data("[\"x\"]".utf8))])
        try await fixture.store.planServerTransition(.conflict, nonce: ContractIdentity.randomUUID())
        let committed = try #require(try await fixture.store.commitServerTransition())
        #expect(committed.reason == .conflict)
        let row = try #require(try fixture.rows("SELECT framing, waiting FROM ntp_outbox WHERE install_seq = 2").first)
        let stored = try JSONDecoder().decode(ServerFraming.self, from: Data(base64Encoded: try #require(row[0]))!)
        #expect(stored == ServerFraming(transactionID: framing.transactionID, present: []))
        #expect(row[1] == nil)
        #expect(try await fixture.store.commitServerTransition() == nil, "nothing without a plan")
    }
}

/// Detection at every graph start (PROTOCOL §6.10): before any library opens, every server library on the device that may sync
/// again is checked against this install's device marker; a `keeping` library is left to its Keep, and a Keychain that
/// cannot be read yet (before the first unlock) leaves everything as it is.
@Suite(.serialized) struct ServerCopyDetectionStartTests {
    struct LockedKeychain: ServerSecretStore {
        func deviceMarker() throws -> String { throw ServerSecretStoreError.keychain(-25308) }
        func installation(library: String, install: String) throws -> ServerInstallationCredential? { throw ServerSecretStoreError.keychain(-25308) }
        func saveInstallation(_ credential: ServerInstallationCredential, library: String, install: String) throws {}
        func removeInstallation(library: String, install: String) throws {}
        func removeLibrary(_ library: String) throws {}
        func installIDs(of library: String) throws -> [String] { [] }
    }

    /// Two server libraries restored from another device's backup: one of an account logged out of (it resumes when
    /// the person logs in again) and one being kept at logout.
    static func device() async throws -> (root: URL, active: String, keeping: String, installs: [String: String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CopyStart-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let active = ContractIdentity.randomUUID(), keeping = ContractIdentity.randomUUID()
        var installs: [String: String] = [:]
        for id in [active, keeping] {
            let install = ContractIdentity.randomUUID()
            installs[id] = install
            let location = LibraryLocation(root: root, reference: .server(id))
            try await StoreServerLibraryProvisioning(feedVault: { MemoryCredentialVault() }).provision(location, ServerLibraryProvision(
                libraryID: id, serverURL: "https://sync.example.test", serverID: "s", accountID: ContractIdentity.randomUUID(),
                namespace: ContractIdentity.randomUUID(), username: "alice", installID: install, deviceMarker: ContractIdentity.randomUUID()))
            let store = try FeedLibraryStore(url: location.database)
            _ = try await store.insert(ServerLibraryFixture.fetched("https://example.test/\(id).xml"))
            try await store.close()
        }
        try LibraryRegistryFile(root: root).update { registry in
            registry.libraries = [.init(id: active, serverURL: "https://sync.example.test", serverID: "s", accountID: ContractIdentity.randomUUID(),
                                        username: "alice", state: .inactive, createdAt: 0),
                                  .init(id: keeping, serverURL: "https://other.example.test", serverID: "t", accountID: ContractIdentity.randomUUID(),
                                        username: "bob", state: .keeping, operation: ContractIdentity.randomUUID(), createdAt: 0)]
            registry.active = .server(keeping)
        }
        return (root, active, keeping, installs)
    }

    static func row(_ root: URL, _ id: String) throws -> [String?] {
        try ServerLibraryFixture.read(LibraryLocation(root: root, reference: .server(id)).database,
                                      "SELECT install_id, device_marker, main_author FROM ntp_library").first ?? []
    }

    @Test func aCopiedLibraryForksBeforeItOpensAndAKeepingOneIsLeftToItsKeep() async throws {
        let (root, active, keeping, installs) = try await Self.device()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemoryServerSecrets()
        let before = try Self.row(root, keeping)
        #expect(LibraryGraphStart.detectCopies(root: root, secrets: secrets, gate: LibraryGate()) == [active])
        let row = try Self.row(root, active), marker = try secrets.deviceMarker()
        #expect(row[0] != installs[active] && row[1] == marker && row[2] == row[0], "forked onto T' = F")
        #expect(try secrets.installation(library: active, install: try #require(row[0]))?.token == nil, "T' signs in later, its nonce kept")
        #expect(try Self.row(root, keeping) == before, "a keeping library never syncs again: its Keep finishes locally")
        // The next start finds nothing to do.
        #expect(LibraryGraphStart.detectCopies(root: root, secrets: secrets, gate: LibraryGate()).isEmpty)
    }

    @Test func aLockedKeychainLeavesDetectionToALaterStart() async throws {
        let (root, active, _, installs) = try await Self.device()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Self.row(root, active)
        #expect(LibraryGraphStart.detectCopies(root: root, secrets: LockedKeychain(), gate: LibraryGate()).isEmpty)
        #expect(try Self.row(root, active) == before && before[0] == installs[active])
        // A busy gate (an export collecting its source) waits too.
        let gate = LibraryGate()
        #expect(gate.tryAcquireExclusive())
        #expect(LibraryGraphStart.detectCopies(root: root, secrets: MemoryServerSecrets(), gate: gate).isEmpty)
        gate.releaseExclusive()
        #expect(try Self.row(root, active) == before)
    }
}

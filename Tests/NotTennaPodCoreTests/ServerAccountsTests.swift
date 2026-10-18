import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Accounts against the real server (PROTOCOL §15.4): sign-in, first attachment of an empty account, the switch under
/// the activation rule, logout and resume, sign in again after a password reset, removal of a kept library, transport
/// conflicts and a non-empty account waiting for projection.
@MainActor @Suite(.serialized) struct ServerAccountsTests {
    /// The app graph around the account service: a registry root, the library the graph opened, a real library
    /// switcher whose restart opens what the registry names, and an activation rule driven by `playing`.
    @MainActor final class World {
        let server: NTPServerProcess
        let admin: AdminSession
        let root: URL
        let secrets = MemoryServerSecrets()
        let feedVault = MemoryCredentialVault()
        var open: LibraryReference = .standalone
        var playing = false
        var restarts = 0
        var switchScenes: [String?] = []
        /// Switch requests that have returned (applied, or recorded to wait for the activation rule).
        var switchesDone = 0
        var switcher: LibrarySwitcher!
        var accounts: ServerAccounts!
        /// The logout cut-off's "stop sync" (PROTOCOL §15.4): the app stops its exchange here.
        var stopSync: @MainActor () async -> Void = {}
        /// The exchange's pause from a sign-in (PROTOCOL §6.11 `lineage_unknown`): the app pauses its exchange here.
        var pauseSync: @MainActor (ServerPauseReason) async -> Void = { _ in }
        var address: ServerAddress { ServerAddress(entered: server.base.absoluteString)! }

        init(server: NTPServerProcess, admin: AdminSession, applier: (any ServerAttachSnapshotApplier)? = nil,
             bulkNetwork: (any ServerSyncNetworkGate)? = nil, disk: ServerBulkDiskPolicy? = nil) throws {
            self.server = server; self.admin = admin
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ServerAccounts-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let registry = LibraryRegistryFile(root: root)
            switcher = LibrarySwitcher(registry: registry, activation: { [unowned self] in
                LibraryActivationState(wantsPlayback: playing, phase: playing ? .playing : .paused)
            }, restart: { [unowned self] in
                restarts += 1
                open = (try? registry.openingLibrary()) ?? .standalone
                switcher.opened(open)
            })
            switcher.opened(.standalone)
            let vault = feedVault
            var dependencies = ServerAccounts.Dependencies(root: root, openLibrary: { [unowned self] in open },
                requestSwitch: { [unowned self] target, reason, scene in
                    switchScenes.append(scene)
                    try await switcher.request(target, reason: reason)
                    switchesDone += 1
                }, secrets: secrets, makeClient: { ServerClient(address: $0) },
                provisioning: StoreServerLibraryProvisioning(feedVault: { vault }),
                applier: applier ?? ServerExchangeAttachApplier(vault: { vault }),
                device: ServerDevice(name: "NotTennaPod on iPhone", appVersion: "4a-test"))
            dependencies.stopSync = { [unowned self] in await stopSync() }
            dependencies.pauseSync = { [unowned self] reason in await pauseSync(reason) }
            dependencies.gate = LibraryGate()
            dependencies.bulkNetwork = bulkNetwork
            if let disk { dependencies.disk = disk }
            accounts = ServerAccounts(dependencies)
            accounts.onFailure = { Issue.record("the attachment failed: \($0)") }
        }

        func location(_ id: String) -> LibraryLocation { LibraryLocation(root: root, reference: .server(id)) }
        var registry: LibraryRegistry { (try? LibraryRegistryFile(root: root).read()) ?? LibraryRegistry() }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        func waitFor(_ what: String, _ condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            while !condition() {
                guard ContinuousClock.now < deadline else { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        /// Signs in to an empty account and attaches it; returns the new library's ID once the graph opened it.
        func attachEmpty(username: String, password: String) async throws -> String {
            let switches = switchesDone
            let info = try await accounts.info(address)
            let pending = try await accounts.signIn(address, info: info, username: username, password: password)
            #expect(pending.kind == .firstAttachment)
            try await accounts.beginAttachment(pending, scene: "scene-1")
            try await waitFor("the empty-account question") { accounts.question != nil }
            guard case .emptyAccount(let id) = accounts.question else { throw CancellationError() }
            #expect(registry.library(id)?.state == .attaching)
            #expect(accounts.page(otherProvider: false).mode == .attaching)
            await accounts.confirmEmptyAccount(scene: "scene-1")
            // The switch request has returned: applied, or recorded to wait for a pause.
            try await waitFor("the switch request") { switchesDone > switches }
            return id
        }
    }

    /// The server's administrator, through a web session (setup, accounts, password resets).
    final class AdminSession: @unchecked Sendable {
        let base: URL
        private var cookie: String?
        init(server: NTPServerProcess) async throws {
            base = server.base
            _ = try await send("POST", "v1/setup", ["username": "owner", "password": "owner-password-1", "setup_code": .string(server.setupCode)])
        }
        /// A person's own web session, with the browser registered as its web installation (as the web app does; the
        /// library import needs one).
        init(user username: String, password: String, server: NTPServerProcess) async throws {
            base = server.base
            _ = try await send("POST", "v1/auth/web", ["username": .string(username), "password": .string(password)])
            _ = try await send("POST", "v1/installations", ["install_id": .string(ContractIdentity.randomUUID()),
                "instance_nonce": .string(ContractIdentity.randomUUID()), "name": "Firefox", "app_version": "1.0", "capabilities": ["queue"]])
        }
        /// The session cookie is carried by hand: the server marks it Secure, which a cookie store keeps off plain HTTP.
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
            let status = http?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw HarnessError.http(status, String(decoding: data, as: UTF8.self)) }
            return data
        }
        /// The library import (PROTOCOL §11.5) of an Android database file into this session's empty account, followed
        /// until it is published.
        func importLibrary(_ file: Data) async throws {
            let fingerprint = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
            let reserved = try await send("POST", "v1/import", ["kind": "android_db", "fingerprint": .string(fingerprint),
                                                                 "size": .integer(Int64(file.count)), "file_name": "AntennaPodBackup.db"])
            guard let id = reserved["import_id"]?.stringValue else { throw HarnessError.server("no import: \(reserved)") }
            _ = try await data("PUT", "v1/import/\(id)/chunks/0", ["data": .string(file.base64EncodedString())])
            _ = try await data("POST", "v1/import/\(id)/finish", .object([:]))
            let deadline = ContinuousClock.now + .seconds(30)
            while true {
                let state = try JSONSerialization.jsonObject(with: try await data("GET", "v1/import/\(id)", nil)) as? [String: Any]
                switch state?["status"] as? String {
                case "published": return
                case "failed": throw HarnessError.server("the import failed: \(String(describing: state))")
                default:
                    guard ContinuousClock.now < deadline else { throw HarnessError.server("the import is still \(String(describing: state))") }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        /// A fresh account; returns its ID.
        func account(_ username: String, password: String) async throws -> String {
            let answer = try await send("POST", "v1/admin/accounts", ["username": .string(username), "password": .string(password), "is_admin": false])
            return answer["account"]?["account_id"]?.stringValue ?? ""
        }
        func resetPassword(_ accountID: String, to password: String) async throws {
            try await send("POST", "v1/admin/accounts/\(accountID)/password", ["password": .string(password)])
        }
    }

    private func world(applier: (any ServerAttachSnapshotApplier)? = nil, bulkNetwork: (any ServerSyncNetworkGate)? = nil,
                       disk: ServerBulkDiskPolicy? = nil, _ body: (World) async throws -> Void) async throws {
        let server = try await NTPServerProcess.start()
        let world: World
        do {
            world = try World(server: server, admin: try await AdminSession(server: server), applier: applier, bulkNetwork: bulkNetwork,
                              disk: disk)
        }
        catch { server.stop(); throw error }
        do { try await body(world) } catch { world.cleanUp(); server.stop(); throw error }
        world.cleanUp(); server.stop()
    }

    @Test func emptyAccountAttachesLogsOutResumesAndIsRemoved() async throws {
        try await world { world in
            _ = try await world.admin.account("alice", password: "alice-password-1")
            let id = try await world.attachEmpty(username: "alice", password: "alice-password-1")
            #expect(world.open == .server(id) && world.registry.active == .server(id))
            #expect(world.registry.library(id)?.state == .active)
            #expect(world.switchScenes == ["scene-1"], "the switch followed the page's tap")
            await world.accounts.refresh()
            var page = world.accounts.page(otherProvider: false)
            #expect(page.mode == .server && page.condition == nil)
            #expect(page.rows == [.provider, .changeLogin, .synchronize, .fullSynchronization, .log, .logout])
            if case .report(let status)? = page.subtitle { #expect(status.successful) } else { Issue.record("no report subtitle") }
            // The library is a server library with its installation; its token and nonce are in the Keychain.
            let install = try #require(try StoreServerLibraryProvisioning().installID(of: world.location(id)))
            let credential = try #require(try world.secrets.installation(library: id, install: install))
            let token = try #require(credential.token)
            #expect(credential.device?.appVersion == "4a-test")
            #expect(FileManager.default.fileExists(atPath: world.location(id).folder.appendingPathComponent("server-status.json").path))
            #expect(!FileManager.default.fileExists(atPath: world.location(id).staging!.appendingPathComponent("attach").path))

            // Logout: signed out on the server, token forgotten, nonce kept, the library kept and inactive.
            try await world.accounts.logout(scene: "scene-1")
            #expect(world.open == .standalone && world.registry.library(id)?.state == .inactive)
            let kept = try #require(try world.secrets.installation(library: id, install: install))
            #expect(kept.token == nil && kept.transportNonce == credential.transportNonce)
            // The sign-out runs in the background after the token was removed here (PROTOCOL §15.4).
            for signOut in world.accounts.signOuts { await signOut.value }
            await #expect(throws: ServerClientError.unauthorized) {
                _ = try await ServerClient(address: world.address).installations(token: token)
            }
            page = world.accounts.page(otherProvider: false)
            #expect(page.mode == .none && page.keptLibraries.map(\.entry.id) == [id] && page.rows == [.keptLibraries])
            #expect(world.accounts.page(otherProvider: true).keptLibraries.isEmpty, "one provider at a time")

            // Logging in again resumes the same library and installation.
            let info = try await world.accounts.info(world.address)
            let again = try await world.accounts.signIn(world.address, info: info, username: "ALICE", password: "alice-password-1")
            #expect(again.kind == .resume(libraryID: id) && again.installID == install)
            try await world.accounts.confirmResume(again, scene: nil)
            #expect(world.open == .server(id) && world.registry.library(id)?.state == .active)
            #expect(try world.secrets.installation(library: id, install: install)?.token != nil)

            // Removal of the kept library: its folder, tokens and feed credentials (also one only `ntp_secrets` keeps).
            try await world.accounts.logout(scene: nil)
            let store = try FeedLibraryStore(url: world.location(id).database)
            let feed = try await store.insert(ServerLibraryFixture.fetched("https://example.test/private.xml"))
            try await FeedAuthentication(store: store, vault: world.feedVault).save(.init(username: "u", password: "p"), feedID: feed.id)
            let credentialID = try #require(try await store.feedCredentialID(feedID: feed.id))
            try await store.close()
            #expect(world.feedVault.contains(credentialID))
            await world.accounts.refresh()
            let unsent = try #require(world.accounts.page(otherProvider: false).keptLibraries.first?.unsentChanges)
            #expect(unsent >= 2, "the subscription and its credentials have not reached the server")
            try await world.accounts.removeKeptLibrary(id)
            #expect(world.registry.libraries.isEmpty)
            #expect(LibraryLocation.isAbsent(world.location(id).folder))
            #expect(try world.secrets.installIDs(of: id).isEmpty)
            #expect(!world.feedVault.contains(credentialID))
            #expect(world.accounts.page(otherProvider: false).rows.isEmpty)
        }
    }

    @Test func aSwitchWaitsForThePauseAndLogoutCancelsAReadyLibrary() async throws {
        try await world { world in
            _ = try await world.admin.account("bob", password: "bob-password-1")
            world.playing = true
            let id = try await world.attachEmpty(username: "bob", password: "bob-password-1")
            #expect(world.open == .standalone && world.registry.library(id)?.state == .ready)
            #expect(world.registry.pendingSwitch?.to == .server(id) && world.restarts == 0)
            var page = world.accounts.page(otherProvider: false)
            #expect(page.mode == .ready && page.condition == .ready && page.subtitle == .ready)
            #expect(page.rows == [.provider, .status, .logout])
            // Paused: the switch runs.
            world.playing = false
            await world.switcher.attempt()
            #expect(world.open == .server(id) && world.restarts == 1)
            // Logout while playing: the server library stays open until the pause, and the page says so.
            world.playing = true
            try await world.accounts.logout(scene: nil)
            #expect(world.open == .server(id) && world.registry.library(id)?.state == .inactive)
            page = world.accounts.page(otherProvider: false)
            #expect(page.mode == .none && page.condition == .loggedOut && page.subtitle == nil)
            #expect(page.rows == [.status, .keptLibraries])
            world.playing = false
            await world.switcher.attempt()
            #expect(world.open == .standalone)
            // A ready library that never opened: logout keeps it, inactive, and cancels its switch.
            world.playing = true
            let info = try await world.accounts.info(world.address)
            let resume = try await world.accounts.signIn(world.address, info: info, username: "bob", password: "bob-password-1")
            try await world.accounts.confirmResume(resume, scene: nil)
            #expect(world.registry.library(id)?.state == .ready && world.registry.pendingSwitch != nil)
            try await world.accounts.logout(scene: nil)
            #expect(world.registry.library(id)?.state == .inactive && world.registry.pendingSwitch == nil)
            world.playing = false
            await world.switcher.attempt()
            #expect(world.open == .standalone)
        }
    }

    @Test func signInAgainAfterAPasswordReset() async throws {
        try await world { world in
            let account = try await world.admin.account("carol", password: "carol-password-1")
            let id = try await world.attachEmpty(username: "carol", password: "carol-password-1")
            let install = try #require(try StoreServerLibraryProvisioning().installID(of: world.location(id)))
            await world.accounts.checkAccount(force: true)
            #expect(world.accounts.page(otherProvider: false).condition == nil, "\(String(describing: world.accounts.page(otherProvider: false)))")
            // A password change elsewhere revokes the token: the page asks to sign in again (PROTOCOL §5).
            try await world.admin.resetPassword(account, to: "carol-password-2")
            await world.accounts.checkAccount()
            #expect(world.accounts.page(otherProvider: false).condition == nil, "checks are rate-limited")
            await world.accounts.checkAccount(force: true)
            var page = world.accounts.page(otherProvider: false)
            #expect(page.condition == .needsSignIn && page.subtitle == .signInAgain)
            #expect(page.rows == [.provider, .status, .changeLogin, .synchronize, .fullSynchronization, .log, .logout])
            await #expect(throws: ServerClientError.wrongCredentials) { try await world.accounts.signInAgain(password: "carol-password-1") }
            try await world.accounts.signInAgain(password: "carol-password-2")
            page = world.accounts.page(otherProvider: false)
            #expect(page.condition == nil)
            #expect(try StoreServerLibraryProvisioning().installID(of: world.location(id)) == install, "the same installation resumes")
            await world.accounts.checkAccount(force: true)
            #expect(world.accounts.page(otherProvider: false).condition == nil)
        }
    }

    @Test func anInstallationHeldByAnotherInstallTakesAFreshOne() async throws {
        try await world { world in
            _ = try await world.admin.account("dave", password: "dave-password-1")
            let id = try await world.attachEmpty(username: "dave", password: "dave-password-1")
            let install = try #require(try StoreServerLibraryProvisioning().installID(of: world.location(id)))
            try await world.accounts.logout(scene: nil)
            // The nonce is gone (a restore onto another device): the kept installation answers `installation_conflict`.
            try world.secrets.removeLibrary(id)
            let info = try await world.accounts.info(world.address)
            let pending = try await world.accounts.signIn(world.address, info: info, username: "dave", password: "dave-password-1")
            #expect(pending.kind == .firstAttachment && pending.installID != install)
            await world.accounts.discard(pending)
            await #expect(throws: ServerClientError.unauthorized) {
                _ = try await ServerClient(address: world.address).installations(token: pending.token)
            }
            #expect(world.registry.library(id)?.state == .inactive, "Cancel creates nothing")
        }
    }

    @Test func wrongPasswordThenTooManyAttempts() async throws {
        try await world { world in
            _ = try await world.admin.account("erin", password: "erin-password-1")
            let info = try await world.accounts.info(world.address)
            #expect(info.protocolVersion == 1)
            var outcomes: [ServerClientError] = []
            for _ in 0..<20 {
                do { _ = try await world.accounts.signIn(world.address, info: info, username: "erin", password: "wrong-password") }
                catch let error as ServerClientError { outcomes.append(error); if case .rateLimited = error { break } }
            }
            #expect(outcomes.first == .wrongCredentials)
            guard case .rateLimited(let wait)? = outcomes.last else { Issue.record("no rate limit: \(outcomes)"); return }
            #expect((wait ?? 0) > 0)
        }
    }

    /// Another phone of the account subscribes to a podcast and pushes it.
    private func subscribeElsewhere(_ world: World, username: String, password: String) async throws {
        let other = try await NTPInstallation.signIn(world.server, username: username, password: password)
        let fixture = try await ServerLibraryFixture(accountID: other.accountID, namespace: other.namespace, installID: other.installID)
        let phone = AgreementPhone(fixture: fixture, installation: other, cursor: try await other.attachSnapshot().head, vault: MemoryCredentialVault())
        _ = try await fixture.store.insert(ServerLibraryFixture.fetched("http://127.0.0.1:1/feed.xml", title: "Elsewhere"))
        try await phone.push()
        await fixture.close()
    }

    @Test func anAccountWithPodcastsAttachesWithoutAskingAndShowsThem() async throws {
        try await world { world in
            _ = try await world.admin.account("frank", password: "frank-password-1")
            try await subscribeElsewhere(world, username: "frank", password: "frank-password-1")
            let info = try await world.accounts.info(world.address)
            let pending = try await world.accounts.signIn(world.address, info: info, username: "frank", password: "frank-password-1")
            try await world.accounts.beginAttachment(pending, scene: "scene-1")
            let id = try #require(world.registry.libraries.first?.id)
            try await world.waitFor("the switch") { world.open == .server(id) }
            #expect(world.accounts.question == nil, "an account with podcasts is not asked about")
            #expect(world.switchScenes == ["scene-1"], "the switch follows the page's Confirm")
            #expect(world.registry.library(id)?.state == .active)
            let store = try FeedLibraryStore(url: world.location(id).database)
            // The server never fetched this feed: the podcast arrives with its address, its metadata with the server's fetch.
            let sources = try await store.feeds().map(\.source)
            try await store.close()
            #expect(sources == ["http://127.0.0.1:1/feed.xml"], "\(sources)")
        }
    }

    /// Free space as the test sets it for the new library's writes; the attach download (its own folder) always fits.
    final class LibrarySpace: @unchecked Sendable {
        private let lock = NSLock()
        /// Arms of the library's writes allowed before space runs out; nil: plenty.
        private var allowed: Int?
        private var arms = 0
        init(allowed: Int?) { self.allowed = allowed }
        func plenty() { lock.withLock { allowed = nil } }
        func available(_ url: URL) -> Int64? {
            if url.lastPathComponent == "attach" { return 1 << 40 }
            return lock.withLock {
                guard let limit = allowed else { return Int64(1) << 40 }
                arms += 1
                return arms <= limit ? Int64(1) << 40 : ServerBulkDiskPolicy().reserve + (1 << 20)
            }
        }
    }

    /// The new library's own writes never use the reserved space: refused at the reset of an earlier attempt's base, at
    /// the base batch after the archive was written, or at the projection's COMMIT after the archive and base were written, the attachment waits for space with nothing of it
    /// active (no cursor, the device's library still open) and its download kept; with space it finishes without
    /// downloading again.
    @Test(arguments: [0, 2, 3])
    func anAttachmentStopsBeforeTheReservedSpaceAndFinishesLater(allowed: Int) async throws {
        let space = LibrarySpace(allowed: allowed)
        var disk = ServerBulkDiskPolicy(available: { space.available($0) })
        disk.unknownAdmission = 1 << 20
        try await world(disk: disk) { world in
            _ = try await world.admin.account("ivy", password: "ivy-password-1")
            try await subscribeElsewhere(world, username: "ivy", password: "ivy-password-1")
            world.accounts.onFailure = nil
            let info = try await world.accounts.info(world.address)
            let pending = try await world.accounts.signIn(world.address, info: info, username: "ivy", password: "ivy-password-1")
            // The page opens (space was freed) at the moment the refused attempt has said it waits for space but has not
            // ended yet: that request is not lost.
            let accounts = world.accounts!, location = world.location
            var waited = false
            accounts.afterAttachSpaceWaitForTesting = { [world] in
                guard !waited, let id = world.registry.libraries.first?.id else { return }
                waited = true
                #expect(accounts.page(otherProvider: false).condition == accounts.attachWaits[id].map(ServerSynchronizationPage.Condition.attachingWaits))
                if case .space? = accounts.attachWaits[id] {} else { Issue.record("no space wait") }
                #expect(world.registry.library(id)?.state == .attaching && world.open == .standalone, "nothing activated")
                #expect((try? ServerAttachBuilder.hasCursor(location(id).database)) == false, "no partial projection")
                let attach = location(id).staging?.appendingPathComponent("attach")
                #expect(attach.flatMap { ServerSnapshotSpool.manifest(in: $0)?.complete } == true, "the verified download is kept")
                space.plenty()
                let before = accounts.startAttachmentRequests
                accounts.pageOpened()
                while accounts.startAttachmentRequests == before { await Task.yield() }
            }
            try await world.accounts.beginAttachment(pending, scene: nil)
            let id = try #require(world.registry.libraries.first?.id)
            try await world.waitFor("the space wait") { waited }
            try await world.waitFor("the switch") { world.open == .server(id) }
            #expect(world.accounts.attachWaits[id] == nil)
            let store = try FeedLibraryStore(url: world.location(id).database)
            #expect(try await store.feeds().count == 1)
            try await store.close()
        }
    }

    /// An applier that cannot build the library: the attachment stays, resumable, until it can.
    struct UnfinishedApplier: ServerAttachSnapshotApplier {
        func apply(_ snapshot: ServerAttachSnapshot, to library: ServerAttachmentTarget) async throws {
            throw ServerAttachmentError.projectionUnavailable
        }
    }

    @Test func anUnfinishedAttachmentStaysAttachingAndLogoutRemovesIt() async throws {
        try await world(applier: UnfinishedApplier()) { world in
            _ = try await world.admin.account("hank", password: "hank-password-1")
            try await subscribeElsewhere(world, username: "hank", password: "hank-password-1")
            let info = try await world.accounts.info(world.address)
            let pending = try await world.accounts.signIn(world.address, info: info, username: "hank", password: "hank-password-1")
            try await world.accounts.beginAttachment(pending, scene: "scene-1")
            let id = try #require(world.registry.libraries.first?.id)
            try await world.waitFor("the projection wait") { world.accounts.waitingForProjection.contains(id) }
            #expect(world.accounts.question == nil && world.registry.library(id)?.state == .attaching && world.open == .standalone)
            let page = world.accounts.page(otherProvider: false)
            guard case .attaching(let items)? = page.condition else { Issue.record("not attaching"); return }
            #expect(items > 0 && page.subtitle == .preparing && page.rows == [.provider, .status, .logout])
            // Logout cancels and removes the unfinished library, and signs its installation out.
            try await world.accounts.logout(scene: nil)
            #expect(world.registry.libraries.isEmpty && LibraryLocation.isAbsent(world.location(id).folder))
            await #expect(throws: ServerClientError.unauthorized) {
                _ = try await ServerClient(address: world.address).installations(token: pending.token)
            }
        }
    }

    @Test func anInterruptedAttachmentResumesAtTheNextGraphStart() async throws {
        try await world { world in
            _ = try await world.admin.account("gina", password: "gina-password-1")
            let info = try await world.accounts.info(world.address)
            let pending = try await world.accounts.signIn(world.address, info: info, username: "gina", password: "gina-password-1")
            try await world.accounts.beginAttachment(pending, scene: nil)
            try await world.waitFor("the question") { world.accounts.question != nil }
            // A new process: a fresh service over the same registry and secrets asks again at the graph start.
            let vault = world.feedVault
            let restarted = ServerAccounts(.init(root: world.root, openLibrary: { world.open },
                requestSwitch: { target, reason, _ in try await world.switcher.request(target, reason: reason) },
                secrets: world.secrets, makeClient: { ServerClient(address: $0) },
                provisioning: StoreServerLibraryProvisioning(feedVault: { vault }), applier: ServerExchangeAttachApplier(vault: { vault }),
                device: ServerDevice(name: "NotTennaPod on iPhone", appVersion: "4a-test")))
            restarted.graphStarted()
            try await world.waitFor("the question again") { restarted.question != nil }
            await restarted.confirmEmptyAccount(scene: nil)
            try await world.waitFor("the switch") { world.open != .standalone }
            #expect(world.registry.libraries.map(\.state) == [.active])
        }
    }

    /// What the open library's exchange reports reaches the page (PROTOCOL §15.5): "Successful (…)" after an
    /// exchange that completed, "Sign in again" when the server refused the token (the token is marked refused),
    /// "Waiting for the server" while it is unreachable, "This server needs updating" for an operation it does not
    /// know, and the unsent changes the "Synchronize now" row mentions.
    @Test func theExchangesReportsReachThePage() async throws {
        try await world { world in
            let account = try await world.admin.account("hana", password: "hana-password-1")
            let id = try await world.attachEmpty(username: "hana", password: "hana-password-1")
            #expect(world.open == .server(id))
            let location = world.location(id)
            let install = try #require(try StoreServerLibraryProvisioning().installID(of: location))
            let secrets = world.secrets
            let store = try FeedLibraryStore(url: location.database)
            let engine = try ServerSyncEngine(store: store, location: location, transport: HTTPServerExchangeTransport(base: world.server.base, token: {
                try secrets.installation(library: id, install: install)?.usableToken
            }), vault: world.feedVault)
            let completed = await engine.exchange()
            #expect(completed.completed)
            world.accounts.exchangeReported(completed)
            var page = world.accounts.page(otherProvider: false)
            guard case .report(let status)? = page.subtitle else { Issue.record("no report: \(String(describing: page.subtitle))"); return }
            #expect(status.successful && page.condition == nil)
            // The network goes and comes back with nothing to send: the page says why meanwhile, then shows the same last
            // result again; the network never stands for an exchange's result.
            world.accounts.networkWaitChanged(.offline)
            page = world.accounts.page(otherProvider: false)
            #expect(page.condition == .waitingForNetwork(.offline) && page.subtitle == .waitingForNetwork(.offline))
            world.accounts.networkWaitChanged(nil)
            page = world.accounts.page(otherProvider: false)
            #expect(page.condition == nil && page.subtitle == .report(status), "no success or failure was made up")
            // Unsent changes: the row mentions them.
            try await store.setServerAccountPolicy(.enqueueLocation(.front))
            var unsent = ServerExchangeReport()
            unsent.unsentChanges = try await store.serverUnsentChanges()
            unsent.unreachable = true
            unsent.retryAfter = 2
            world.accounts.exchangeReported(unsent)
            page = world.accounts.page(otherProvider: false)
            #expect(page.unsentChanges == 1)
            #expect(page.condition == .unreachable && page.subtitle == .waitingForServer && page.rows.contains(.synchronize))
            // An exchange stopped before it finished (background time ran out) tells nothing new: the page stays.
            var stopped = ServerExchangeReport()
            stopped.cancelled = true
            stopped.unsentChanges = 1
            world.accounts.exchangeReported(stopped)
            page = world.accounts.page(otherProvider: false)
            #expect(page.condition == .unreachable && page.subtitle == .waitingForServer, "a cancellation is not news")
            // A password change elsewhere revokes the token: the exchange pauses and the page asks to sign in again.
            try await world.admin.resetPassword(account, to: "hana-password-2")
            let refused = await engine.exchange()
            #expect(refused.pause == .signIn)
            world.accounts.exchangeReported(refused)
            page = world.accounts.page(otherProvider: false)
            #expect(page.condition == .needsSignIn && page.subtitle == .signInAgain)
            world.accounts.networkWaitChanged(.mobileDataOff)
            page = world.accounts.page(otherProvider: false)
            #expect(page.condition == .needsSignIn && page.unsentChanges == refused.unsentChanges, "the network never hides a pause or the unsent changes")
            world.accounts.networkWaitChanged(nil)
            #expect(try secrets.installation(library: id, install: install)?.rejected == true, "the refused token is not sent again")
            try await world.accounts.signInAgain(password: "hana-password-2")
            try await engine.resume()
            let again = await engine.exchange()
            #expect(again.completed && again.unsentChanges == 0, "signed in again, the change is sent")
            world.accounts.exchangeReported(again)
            #expect(world.accounts.page(otherProvider: false).condition == nil)
            // Large changes wait for the app to leave the foreground: the status row says so until they are applied.
            var waiting = ServerExchangeReport()
            waiting.waitingForBackground = true
            world.accounts.exchangeReported(waiting)
            #expect(world.accounts.page(otherProvider: false).condition == .waitingForBackground)
            world.accounts.exchangeReported(again)
            #expect(world.accounts.page(otherProvider: false).condition == nil, "applied: the row goes")
            var update = ServerExchangeReport()
            update.pause = .versionUnsupported
            world.accounts.exchangeReported(update)
            page = world.accounts.page(otherProvider: false)
            #expect(page.condition == .serverNeedsUpdate && page.subtitle == .paused)
            await engine.close()
            try await store.close()
        }
    }

    /// The pauses the recovery resolves (lineage mismatch, transport conflict, lost dependency) say "Paused" and why on
    /// the page, and the synchronization log names the cause; the last "Successful (…)" is not shown as if all were well.
    @Test func pausesTheRecoveryResolvesSayPausedAndWhy() async throws {
        try await world { world in
            _ = try await world.admin.account("ines", password: "ines-password-1")
            let id = try await world.attachEmpty(username: "ines", password: "ines-password-1")
            let location = world.location(id)
            let install = try #require(try StoreServerLibraryProvisioning().installID(of: location))
            let secrets = world.secrets
            let store = try FeedLibraryStore(url: location.database)
            let transport = ProxyTransport(HTTPServerExchangeTransport(base: world.server.base, token: {
                try secrets.installation(library: id, install: install)?.usableToken
            }))
            let engine = try ServerSyncEngine(store: store, location: location, transport: transport, vault: world.feedVault)
            let completed = await engine.exchange()
            world.accounts.exchangeReported(completed)
            guard case .report? = world.accounts.page(otherProvider: false).subtitle else { Issue.record("no report"); return }
            // The server was restored: the cursor names a history it no longer has.
            let cursor = try SyncCursor(encoded: try #require(try ServerLibraryFixture.read(location.database, "SELECT cursor FROM ntp_library").first?.first ?? nil))
            // (An empty account's head digest is the all-zero genesis digest: another one is forged.)
            let forged = try SyncCursor(logID: cursor.logID, epoch: cursor.epoch, seq: cursor.seq, digest: String(repeating: "f", count: 64))
            transport.handler = { method, path, body, server in
                guard case .object(var object) = body, object["cursor"] != nil else { return try await server.send(method, path, body: body) }
                object["cursor"] = .string(forged.encoded)
                return try await server.send(method, path, body: .object(object))
            }
            try await store.setServerAccountPolicy(.enqueueLocation(.front))
            let restored = await engine.exchange()
            #expect(restored.pause == .lineageMismatch)
            world.accounts.exchangeReported(restored)
            var page = world.accounts.page(otherProvider: false)
            #expect(page.condition == .serverRestored && page.subtitle == .paused && page.rows.contains(.status))
            #expect(page.unsentChanges == 1, "the change is kept")
            #expect(try await engine.logEntries().contains { $0.kind == "paused" && $0.detail == "lineage_mismatch" }, "the cause is logged")
            // Synchronize now while paused: still paused, still saying so (nothing is sent, nothing claims success).
            transport.handler = nil
            let again = await engine.exchange()
            #expect(again.pause == .lineageMismatch && again.unsentChanges == 1)
            world.accounts.exchangeReported(again)
            page = world.accounts.page(otherProvider: false)
            #expect(page.condition == .serverRestored && page.subtitle == .paused)
            // After a relaunch the stored pause shows at once, even when no exchange can run (no permitted network).
            await engine.close()
            let vault = world.feedVault
            let relaunched = ServerAccounts(.init(root: world.root, openLibrary: { world.open },
                requestSwitch: { target, reason, _ in try await world.switcher.request(target, reason: reason) },
                secrets: world.secrets, makeClient: { ServerClient(address: $0) },
                provisioning: StoreServerLibraryProvisioning(feedVault: { vault }), applier: ServerExchangeAttachApplier(vault: { vault }),
                device: ServerDevice(name: "NotTennaPod on iPhone", appVersion: "4a-test")))
            await relaunched.refresh()
            guard case .report? = relaunched.page(otherProvider: false).subtitle else { Issue.record("no stored report"); return }
            let reopened = try ServerSyncEngine(store: store, location: location, transport: transport, vault: world.feedVault)
            let scheduler = ServerSyncScheduler(engine: reopened, hints: nil, outbox: nil, network: NoNetwork())
            scheduler.callbacks.reported = { relaunched.exchangeReported($0) }
            scheduler.start()
            try await world.waitFor("the stored pause") { relaunched.page(otherProvider: false).condition == .serverRestored }
            #expect(relaunched.page(otherProvider: false).subtitle == .paused && scheduler.exchangesRun == 0)
            await scheduler.close()
            for (reason, condition) in [(ServerPauseReason.transportConflict, ServerSynchronizationPage.Condition.sharedInstallation),
                                        (.dependencyLost, .serverLostChanges)] {
                var report = ServerExchangeReport()
                report.pause = reason
                world.accounts.exchangeReported(report)
                page = world.accounts.page(otherProvider: false)
                #expect(page.condition == condition && page.subtitle == .paused, "\(reason)")
            }
            try await store.close()
        }
    }

    /// An applier that waits until it is cancelled (or 20 s), and says which happened.
    final class BlockingApplier: ServerAttachSnapshotApplier, @unchecked Sendable {
        private let lock = NSLock()
        private var state = (entered: false, cancelled: false)
        var entered: Bool { lock.withLock { state.entered } }
        var cancelled: Bool { lock.withLock { state.cancelled } }
        func apply(_ snapshot: ServerAttachSnapshot, to library: ServerAttachmentTarget) async throws {
            lock.withLock { state.entered = true }
            do { try await Task.sleep(for: .seconds(20)) } catch { lock.withLock { state.cancelled = true }; throw error }
        }
    }

    /// When a processing task's time expires, the attachment work it started is cancelled with it;
    /// the library stays attaching and continues later.
    @Test func attachmentWorkStartedByABackgroundTaskEndsWithIt() async throws {
        try await world(applier: UnfinishedApplier()) { world in
            _ = try await world.admin.account("kai", password: "kai-password-1")
            try await subscribeElsewhere(world, username: "kai", password: "kai-password-1")
            let info = try await world.accounts.info(world.address)
            let pending = try await world.accounts.signIn(world.address, info: info, username: "kai", password: "kai-password-1")
            try await world.accounts.beginAttachment(pending, scene: nil)
            try await world.waitFor("the attachment to wait") { !world.accounts.waitingForProjection.isEmpty }
            // A later process: its background task continues the attachment.
            let blocking = BlockingApplier(), vault = world.feedVault
            let later = ServerAccounts(.init(root: world.root, openLibrary: { world.open },
                requestSwitch: { target, reason, _ in try await world.switcher.request(target, reason: reason) },
                secrets: world.secrets, makeClient: { ServerClient(address: $0) },
                provisioning: StoreServerLibraryProvisioning(feedVault: { vault }), applier: blocking,
                device: ServerDevice(name: "NotTennaPod on iPhone", appVersion: "4a-test")))
            let task = Task { await later.continueAttachments() }
            try await world.waitFor("the applier") { blocking.entered }
            task.cancel()
            let started = ContinuousClock.now
            #expect(await task.value == false, "not finished")
            try await world.waitFor("the attachment's cancellation") { blocking.cancelled }
            #expect(started.duration(to: .now) < .seconds(10), "the expiry stopped the work at once")
            #expect(world.registry.libraries.map(\.state) == [.attaching], "kept, to continue later")
        }
    }

    /// The attach download's network: mobile data (or Low Data Mode) with the mobile-data preference off, until the test
    /// moves to Wi-Fi.
    final class BulkGate: ServerSyncNetworkGate, @unchecked Sendable {
        private let lock = NSLock()
        private var wait: ServerNetworkWait? = .mobileDataOff
        private var asked = 0
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        func permitted() async -> Bool { true }
        func changes() -> AsyncStream<Void> { stream }
        func allowsMobile() async -> Bool { false }
        func bulkWaitReason() async -> ServerNetworkWait? { lock.withLock { asked += 1; return wait } }
        var questions: Int { lock.withLock { asked } }
        func set(_ value: ServerNetworkWait?) {
            lock.withLock { wait = value }
            continuation.yield(())
        }
    }

    /// The account's library is not downloaded on mobile data or in Low Data Mode while the mobile-data preference does
    /// not allow sync: nothing is asked of the server, the page says it waits for Wi-Fi, and it continues on Wi-Fi.
    @Test func anAttachmentWaitsForANetworkItMayUseAndContinuesThere() async throws {
        let gate = BulkGate()
        try await world(bulkNetwork: gate) { world in
            _ = try await world.admin.account("noa", password: "noa-password-1")
            let info = try await world.accounts.info(world.address)
            let pending = try await world.accounts.signIn(world.address, info: info, username: "noa", password: "noa-password-1")
            try await world.accounts.beginAttachment(pending, scene: nil)
            let id = try #require(world.registry.libraries.first?.id)
            try await world.waitFor("the wait") { world.accounts.attachWaits[id] == .network(.mobileDataOff) }
            let page = world.accounts.page(otherProvider: false)
            #expect(page.mode == .attaching && page.condition == .attachingWaits(.network(.mobileDataOff)))
            #expect(page.subtitle == .waitingForNetwork(.mobileDataOff))
            let attach = try #require(world.location(id).staging).appendingPathComponent("attach")
            #expect(ServerSnapshotSpool.manifest(in: attach)?.pages.isEmpty ?? true, "nothing downloaded")
            gate.set(nil)
            try await world.waitFor("the empty-account question") { world.accounts.question != nil }
            #expect(world.accounts.attachWaits[id] == nil)
            #expect(world.accounts.page(otherProvider: false).condition == .attaching(items: 0) || world.accounts.question != nil)
        }
    }

    struct NoNetwork: ServerSyncNetworkGate {
        func permitted() async -> Bool { false }
        func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
    }

    // MARK: - Logout, Keep and logging in again (PROTOCOL §15.4 "Accounts and copies")

    /// Keep, then log in to the same account: a first attachment with a fresh library ID, installation ID and transport
    /// nonce (PROTOCOL §11.5). The account is still empty, so nothing of the kept library (its subscription the server never
    /// received included) was uploaded, and the kept library's file is unchanged.
    @Test func loggingInAgainAfterAKeepIsAFirstAttachmentThatUploadsNothing() async throws {
        try await world { world in
            _ = try await world.admin.account("mia", password: "mia-password-1")
            let kept = try await world.attachEmpty(username: "mia", password: "mia-password-1")
            let install = try #require(try StoreServerLibraryProvisioning().installID(of: world.location(kept)))
            let nonce = try #require(try world.secrets.installation(library: kept, install: install)?.transportNonce)
            let store = try FeedLibraryStore(url: world.location(kept).database)
            _ = FeedAuthentication(store: store, vault: world.feedVault)
            _ = try await store.insert(ServerLibraryFixture.fetched("http://127.0.0.1:1/kept.xml", title: "Kept"))
            try await store.close()
            try await world.accounts.logout(.keep, scene: nil)
            for task in world.accounts.signOuts { await task.value }
            // The Keep runs at the next graph start (here at once), and the graph reopens this phone's library.
            let keep = LibraryKeep(.init(root: world.root, secrets: world.secrets))
            let outcome = try LibraryGraphStart.finishKeep(keep, gate: LibraryGate())?.outcome
            #expect(outcome == .finished, "\(String(describing: outcome))")
            world.open = .standalone
            world.switcher.opened(.standalone)
            let rootDatabase = world.root.appendingPathComponent(LibraryLocation.databaseName)
            let file = try Data(contentsOf: rootDatabase)
            let reader = try FeedLibraryStore(readingOnly: rootDatabase)
            #expect(try await reader.feeds().map(\.title) == ["Kept"])
            #expect(try await reader.libraryIdentity().identity == kept)
            try await reader.close()
            #expect(world.registry.libraries.isEmpty && world.registry.standaloneIdentity == kept)

            let info = try await world.accounts.info(world.address)
            let pending = try await world.accounts.signIn(world.address, info: info, username: "mia", password: "mia-password-1")
            #expect(pending.kind == .firstAttachment && pending.installID != install)
            try await world.accounts.beginAttachment(pending, scene: nil)
            try await world.waitFor("the empty-account question") { world.accounts.question != nil }
            guard case .emptyAccount(let id) = world.accounts.question else { Issue.record("not asked about an empty account"); return }
            #expect(id != kept, "a fresh library ID")
            await world.accounts.confirmEmptyAccount(scene: nil)
            try await world.waitFor("the new library") { world.open == .server(id) }
            let newInstall = try #require(try StoreServerLibraryProvisioning().installID(of: world.location(id)))
            #expect(newInstall == pending.installID && newInstall != install)
            let credential = try #require(try world.secrets.installation(library: id, install: newInstall))
            #expect(credential.transportNonce != nonce && credential.token != nil)
            let attached = try FeedLibraryStore(url: world.location(id).database)
            #expect(try await attached.feeds().isEmpty)
            try await attached.close()
            #expect(try Data(contentsOf: rootDatabase) == file, "the kept library is unchanged")
        }
    }

    /// The server answers a push only when the test lets it: every request reaches the real server, and a push's
    /// answer (the server has applied it) is held.
    final class HeldPushes: SynchronizationHTTPTransport, @unchecked Sendable {
        private let inner = URLSessionSynchronizationTransport()
        private let state = Mutex<(paths: [String], held: CheckedContinuation<Void, Never>?, waiter: CheckedContinuation<Void, Never>?,
                                   answered: Bool, released: Bool)>(([], nil, nil, false, false))
        var paths: [String] { state.withLock { $0.paths } }
        func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
            let path = request.url?.path ?? ""
            state.withLock { $0.paths.append(path) }
            let response = try await inner.send(request)
            guard path.hasSuffix("/v1/push") else { return response }
            await withCheckedContinuation { continuation in
                let (waiter, released) = state.withLock { state -> (CheckedContinuation<Void, Never>?, Bool) in
                    state.answered = true
                    if !state.released { state.held = continuation }
                    defer { state.waiter = nil }
                    return (state.waiter, state.released)
                }
                waiter?.resume()
                if released { continuation.resume() }
            }
            return response
        }
        func waitForAnsweredPush() async {
            await withCheckedContinuation { continuation in
                let answered = state.withLock { state -> Bool in
                    if !state.answered { state.waiter = continuation }
                    return state.answered
                }
                if answered { continuation.resume() }
            }
        }
        func release() {
            state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.released = true
                defer { state.held = nil }
                return state.held
            }?.resume()
        }
    }

    /// The logout cut-off end to end against the server (PROTOCOL §15.4): the server applied a push whose answer is
    /// still on its way when the person logs out. The answer is discarded without a receipt, so the change still counts
    /// as unconfirmed, and nothing more is sent; the server does have it.
    @Test func aLogoutWithAPushInFlightDiscardsTheAnswerAndSendsNothingMore() async throws {
        try await world { world in
            _ = try await world.admin.account("noa", password: "noa-password-1")
            let id = try await world.attachEmpty(username: "noa", password: "noa-password-1")
            let location = world.location(id)
            let install = try #require(try StoreServerLibraryProvisioning().installID(of: location))
            let secrets = world.secrets, held = HeldPushes()
            let store = try FeedLibraryStore(url: location.database)
            _ = FeedAuthentication(store: store, vault: world.feedVault)
            let engine = try ServerSyncEngine(store: store, location: location, transport: HTTPServerExchangeTransport(
                base: world.server.base, transport: held, token: { try secrets.installation(library: id, install: install)?.usableToken }),
                vault: world.feedVault)
            _ = try await store.insert(ServerLibraryFixture.fetched("http://127.0.0.1:1/in-flight.xml", title: "In flight"))
            let unconfirmed = try await store.serverUnsentChanges()
            #expect(unconfirmed > 0)
            let exchange = Task { await engine.exchange() }
            await held.waitForAnsweredPush()
            let sent = held.paths
            world.stopSync = {
                exchange.cancel()
                held.release()
                _ = await exchange.value
            }
            try await world.accounts.logout(.goBack, scene: nil)
            #expect(await exchange.value.cancelled)
            #expect(try await store.serverUnsentChanges() == unconfirmed, "no receipt: the change is still unconfirmed")
            #expect(held.paths == sent, "nothing was sent after the stop")
            for task in world.accounts.signOuts { await task.value }
            // The server applied it: another installation of the account sees the podcast.
            let other = try await NTPInstallation.signIn(world.server, username: "noa", password: "noa-password-1")
            #expect(try await other.attachSnapshot().records.keys.contains { $0.hasPrefix("podcast/") })
            await engine.close()
            try await store.close()
        }
    }

    /// "Interoperability": the database export of a library kept at logout, with a statistics unit, imported into an
    /// empty account through the server's import, then attached to this phone: every statistic of the attached
    /// library matches the kept library's, with "include marked as played" off and on, month by month.
    @Test func aKeptLibrarysExportReimportedThroughTheServerHasTheSameStatistics() async throws {
        let device = LibraryKeepTests()
        let keptDevice = try await device.device()
        defer { device.remove(keptDevice) }
        #expect(keptDevice.keep().run(try keptDevice.keep().request(source: LibraryKeepTests.source)) == .finished)
        let reader = try FeedLibraryStore(readingOnly: keptDevice.root.appendingPathComponent(LibraryLocation.databaseName))
        let kept = try await reader.statisticsLibrary()
        try await reader.close()
        #expect(kept.units.values.flatMap { $0 }.count == 1)
        let file = try await LibraryExport.collect(identity: LibraryKeepTests.source, root: keptDevice.root, open: nil,
                                                   vault: MemoryCredentialVault(), gate: LibraryGate()).databaseData()
        try await world { world in
            _ = try await world.admin.account("oli", password: "oli-password-1")
            try await AdminSession(user: "oli", password: "oli-password-1", server: world.server).importLibrary(file)
            let info = try await world.accounts.info(world.address)
            let pending = try await world.accounts.signIn(world.address, info: info, username: "oli", password: "oli-password-1")
            try await world.accounts.beginAttachment(pending, scene: nil)
            let id = try #require(world.registry.libraries.first?.id)
            try await world.waitFor("the attached library") { world.open == .server(id) }
            let store = try FeedLibraryStore(url: world.location(id).database)
            let attached = try await store.statisticsLibrary()
            try await store.close()
            #expect(attached.units.values.flatMap { $0 }.count == 1)
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            func values(_ input: LibraryStatisticsInput, marked: Bool) throws -> [String: [Int64]] {
                let statistics = try LibraryStatistics(feeds: input.feeds, units: input.units, includeMarkedAsPlayed: marked, now: now)
                let sources = Dictionary(uniqueKeysWithValues: input.feeds.map { ($0.id, $0.source) })
                return Dictionary(uniqueKeysWithValues: statistics.feeds.map { feed in
                    (sources[feed.feedID] ?? "?", [feed.episodes, feed.episodesStarted, feed.playedSeconds, feed.totalSeconds, feed.hasRecentUnplayed ? 1 : 0])
                })
            }
            for marked in [false, true] {
                let expected = try values(kept, marked: marked)
                #expect(expected.count == 1)
                #expect(try values(attached, marked: marked) == expected, "include marked as played: \(marked)")
            }
            func months(_ input: LibraryStatisticsInput) -> [[Int64]] {
                YearsStatisticsSnapshot(feeds: input.feeds, units: input.units).monthly.map { [Int64($0.year), Int64($0.month), $0.playedMilliseconds] }
            }
            #expect(months(attached) == months(kept))
        }
    }
}

import Foundation

/// A sign-in the person has not yet confirmed (PROTOCOL §15.4): the token lives only in memory until the
/// attachment or resume is confirmed; Cancel signs out and forgets it.
public struct ServerPendingSignIn: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The kept library for this account and installation continues (PROTOCOL §15.4, §5).
        case resume(libraryID: String)
        case firstAttachment
    }
    public let kind: Kind
    public let address: ServerAddress
    public let serverID: String
    /// As the server spells it.
    public let username: String
    public let accountID: String
    public let namespace: String
    public let installID: String
    let transportNonce: String
    let token: String
    let device: ServerDevice
}

/// What the person chose at logout (PROTOCOL §15.4).
public enum ServerLogoutChoice: Equatable, Sendable {
    /// "Keep using this library": the Keep transaction makes it this phone's own library.
    case keep
    /// "Go back to the library from before you signed in": today's behaviour.
    case goBack
}

public enum ServerAccountError: Error, Equatable, Sendable {
    /// The action needs a server library in that state.
    case noServerLibrary
    /// Signing in again reached another account than the library's.
    case differentAccount
    /// Only a kept (inactive) library can be removed or logged in from the list.
    case libraryInUse
}

/// A question the Synchronization page asks once it is visible.
public enum ServerAccountQuestion: Equatable, Sendable {
    /// The account has no podcasts yet (PROTOCOL §15.5, "Attachment, empty account").
    case emptyAccount(libraryID: String)
}

/// The NotTennaPod server accounts on this device (PROTOCOL §15.4): sign-in, first attachment up to
/// the applier, resume of a kept library, sign in again, logout, removal of kept libraries, and the
/// account check. It never touches the live library: switches go only through the library switcher's activation
/// rule, and a new library is built in its own folder.
@MainActor public final class ServerAccounts {
    public struct Dependencies {
        /// Application Support (or a DEBUG test library's folder): `libraries.json` and `Server Libraries/`.
        public var root: URL
        /// The library the current graph opened.
        public var openLibrary: @MainActor () -> LibraryReference
        /// `LibrarySwitcher.request`; `scene` names the scene whose page asked, when the switch follows a tap there.
        public var requestSwitch: @MainActor (LibraryReference, LibraryRegistry.SwitchReason, _ scene: String?) async throws -> Void
        public var secrets: any ServerSecretStore
        public var makeClient: @MainActor (ServerAddress) -> ServerClient
        public var provisioning: any ServerLibraryProvisioning
        public var applier: any ServerAttachSnapshotApplier
        public var device: ServerDevice
        public var clock: @Sendable () -> Date
        /// The logout cut-off's step 2 (PROTOCOL §15.4): the open library's exchange stops, and a response in flight is discarded.
        public var stopSync: @MainActor () async -> Void = {}
        /// The open library's exchange pauses for `reason` until it is resumed (PROTOCOL §6.11 `lineage_unknown`: signing in again
        /// reached an account that no longer has this library's history).
        public var pauseSync: @MainActor (ServerPauseReason) async -> Void = { _ in }
        /// "Sign in again" found the installation replaced and no transition planned (PROTOCOL §6.10): the exchange plans one and
        /// names the installation to sign in with.
        public var newInstallation: @MainActor () async -> ServerSignInInstallation? = { nil }
        /// A Keep at logout was recorded: it runs when the activation rule holds (PROTOCOL §15.4). The app's runs whichever
        /// waits, a Keep or a switch (`LibrarySwitcher.attempt`).
        public var attemptKeep: @MainActor () async -> Void = {}
        /// A Cast session is connecting or has media loaded on the receiver (PROTOCOL §15.4): the page names it as the wait.
        public var castBlocks: @MainActor () -> Bool = { false }
        /// Why the last attempt to keep the library stopped, when it did (PROTOCOL §15.5 stalled status row).
        public var keepFailure: @MainActor () -> KeepFailure? = { nil }
        /// What of the player holds a waiting switch or Keep (`LibraryActivationState.playbackHold`): the page names it.
        public var playbackHold: @MainActor () -> LibraryPlaybackHold? = { nil }
        /// "Stop playback and continue": the open library's player stops, a resumption an interruption holds included.
        public var stopPlayback: @MainActor () async -> Void = {}
        /// The feed-credential Keychain store, for removing a previous library's credentials.
        public var feedVault: @Sendable () -> any SynchronizationCredentialStore = {
            KeychainSynchronizationCredentials(service: "org.nottennapod.app.feeds")
        }
        public var gate: LibraryGate = .shared

        public init(root: URL, openLibrary: @escaping @MainActor () -> LibraryReference,
                    requestSwitch: @escaping @MainActor (LibraryReference, LibraryRegistry.SwitchReason, String?) async throws -> Void,
                    secrets: any ServerSecretStore, makeClient: @escaping @MainActor (ServerAddress) -> ServerClient,
                    provisioning: any ServerLibraryProvisioning = StoreServerLibraryProvisioning(),
                    applier: any ServerAttachSnapshotApplier = ServerExchangeAttachApplier(), device: ServerDevice,
                    clock: @escaping @Sendable () -> Date = { Date() }) {
            self.root = root; self.openLibrary = openLibrary; self.requestSwitch = requestSwitch; self.secrets = secrets
            self.makeClient = makeClient; self.provisioning = provisioning; self.applier = applier; self.device = device
            self.clock = clock
        }
    }

    /// The account check runs at most this often.
    public static let checkInterval: TimeInterval = 30

    private let dependencies: Dependencies
    private let registryFile: LibraryRegistryFile
    public private(set) var registry = LibraryRegistry()
    public private(set) var summaries: [String: ServerLibrarySummary] = [:]
    /// Items of the attach snapshot received so far, per attaching library.
    public private(set) var attachProgress: [String: Int] = [:]
    /// Attaching libraries whose snapshot needs projection.
    public private(set) var waitingForProjection: Set<String> = []
    public private(set) var question: ServerAccountQuestion?
    /// What the page knows about the open library's exchange.
    public private(set) var exchange = ServerSynchronizationSignals()
    /// The switch a page tap started, while it is being applied: the restarted graph reopens the Synchronization
    /// page in that scene. Never persisted, so a switch applied later (at a pause, or at launch) opens nothing.
    public private(set) var interactiveSwitch: (scene: String, reason: LibraryRegistry.SwitchReason)?
    /// That switch or Keep only continues one requested earlier ("Stop playback and continue"): the reopened page
    /// announces nothing again (the logout was announced when it was made).
    public private(set) var interactiveSwitchContinues = false
    /// An attachment that failed while the page that started it was waiting.
    public var onFailure: (@MainActor (any Error) -> Void)?
    /// The person signed in again: the app's exchange continues.
    public var onSignedInAgain: (@MainActor () -> Void)?

    /// Tokens the logout cut-off could not remove from their Keychain item (PROTOCOL §15.4), recorded on
    /// disk by digest: a later retry, at the latest at the next launch, removes each only while the item still holds
    /// that same token, so it never deletes a later login.
    private let tokenRemovals: ServerTokenRemovals
    private var pendingTokenRemovals: [ServerTokenRemovals.Removal]
    /// Whether `pendingTokenRemovals` includes the journal on disk. Until it could be read (before the first unlock)
    /// the journal is never written, so a later write cannot forget a removal it holds.
    private var tokenRemovalsLoaded: Bool
    /// Whether `pendingTokenRemovals` holds changes the journal on disk does not have yet (a removal recorded while it
    /// could not be read or written): saved at the next chance, whether or not a Keychain removal succeeds then.
    private var tokenRemovalsUnsaved = false
    /// Background sign-outs started by logouts (tests wait for them).
    public private(set) var signOuts: [Task<Void, Never>] = []

    private var attachTasks: [String: Task<Void, Never>] = [:]
    /// Libraries `beginAttachment` is still creating: a graph start must not take them for interrupted ones.
    private var preparing: Set<String> = []
    private var pendingSnapshots: [String: ServerAttachSnapshot] = [:]
    private var emptyConfirmed: Set<String> = []
    private var lastCheck: Date?
    private var observers: [UUID: @MainActor () -> Void] = [:]

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        registryFile = LibraryRegistryFile(root: dependencies.root)
        registry = (try? registryFile.read()) ?? LibraryRegistry()
        tokenRemovals = ServerTokenRemovals(root: dependencies.root)
        let saved = try? tokenRemovals.read()
        pendingTokenRemovals = saved ?? []
        tokenRemovalsLoaded = saved != nil
    }

    /// Reads the token-removal journal if it could not be read before, keeping the removals recorded meanwhile. Returns
    /// whether the journal may be written.
    private func loadTokenRemovals() -> Bool {
        guard !tokenRemovalsLoaded else { return true }
        guard let saved = try? tokenRemovals.read() else { return false }
        let merged = saved + pendingTokenRemovals.filter { !saved.contains($0) }
        if merged != saved { tokenRemovalsUnsaved = true }
        pendingTokenRemovals = merged
        tokenRemovalsLoaded = true
        return true
    }

    /// Writes the journal when it holds unsaved changes and could be read; a failed write keeps them unsaved.
    private func saveTokenRemovals() {
        guard loadTokenRemovals(), tokenRemovalsUnsaved else { return }
        if (try? tokenRemovals.write(pendingTokenRemovals)) != nil { tokenRemovalsUnsaved = false }
    }

    public var root: URL { dependencies.root }

    // MARK: - Observation

    @MainActor public final class Observation {
        fileprivate var cancel: (@MainActor () -> Void)?
        isolated deinit { cancel?() }
    }

    /// Calls `handler` after every change; observation ends when the returned object is released.
    public func observe(_ handler: @escaping @MainActor () -> Void) -> Observation {
        let id = UUID()
        observers[id] = handler
        let observation = Observation()
        observation.cancel = { [weak self] in _ = self?.observers.removeValue(forKey: id) }
        return observation
    }

    private func changed() { for handler in observers.values { handler() } }

    // MARK: - The page

    /// The Synchronization page's server-mode state. `otherProvider`: gpodder.net or Nextcloud is chosen.
    public func page(otherProvider: Bool) -> ServerSynchronizationPage {
        ServerSynchronizationPage.make(registry: registry, open: dependencies.openLibrary(), otherProvider: otherProvider,
                                       summaries: summaries, attachProgress: attachProgress, exchange: exchange,
                                       castBlocks: dependencies.castBlocks(), keepFailure: dependencies.keepFailure(),
                                       playbackHold: dependencies.playbackHold())
    }

    /// "Stop playback and continue": a switch or Keep waiting for playback, a resumption after an interruption
    /// included, goes ahead. Playback stops as Stop stops it (a pending resumption is given up, so a late end of the
    /// interruption plays nothing); the waiting operation then runs as soon as the activation rule's other conditions
    /// hold (`attemptKeep` runs whichever waits), checked and applied in one step against a newly admitted Play. A
    /// switch or Keep that runs at once follows this tap: the page reopens in `scene` after the restart.
    public func stopPlaybackAndContinue(scene: String?) async {
        if let saved = try? registryFile.read() { registry = saved }
        // A Keep follows a logout.
        let reason = registry.pendingSwitch?.reason ?? .logout
        interactiveSwitch = scene.map { ($0, reason) }
        interactiveSwitchContinues = true
        defer { interactiveSwitch = nil; interactiveSwitchContinues = false }
        await dependencies.stopPlayback()
        await dependencies.attemptKeep()
        changed()
    }

    /// Something outside the account service changed what the page shows (Cast, a Keep's outcome).
    public func pageChanged() { changed() }

    /// Reads the registry and every library's summary again (unsent changes, last synchronization, token).
    public func refresh() async {
        if let saved = try? registryFile.read() { registry = saved }
        let root = dependencies.root, provisioning = dependencies.provisioning, secrets = dependencies.secrets
        let entries = registry.libraries
        summaries = await Task.detached(priority: .utility) {
            var result: [String: ServerLibrarySummary] = [:]
            for entry in entries {
                let location = LibraryLocation(root: root, reference: .server(entry.id))
                let install = (try? provisioning.installID(of: location)) ?? (try? secrets.installIDs(of: entry.id))?.first
                let credential = install.flatMap { try? secrets.installation(library: entry.id, install: $0) }
                result[entry.id] = ServerLibrarySummary(entry: entry, unsentChanges: (try? provisioning.unsentChanges(of: location)) ?? 0,
                    lastSynchronization: ServerLibraryStatusFile(location: location).read(),
                    hasUsableToken: credential?.usableToken != nil)
            }
            return result
        }.value
        changed()
    }

    // MARK: - Sign-in (PROTOCOL §15.4–4)

    /// Step 1: `GET /v1/info` at the entered address.
    public func info(_ address: ServerAddress) async throws -> ServerInfo {
        try await dependencies.makeClient(address).info()
    }

    /// Steps 2–4. A kept library of this address and username lends its installation and transport nonce; signing in
    /// with them resumes it. Otherwise a fresh installation; one `installation_conflict` takes another fresh one.
    /// Several kept libraries may share the address and username (Start over keeps the older lineage, PROTOCOL §6.11): the one
    /// `library` names (its own "Log in"), else the newest, signs in first; the one that resumes is the kept library of
    /// the authenticated server and account, under its own installation, signing in again with it when another
    /// candidate's authenticated. An older lineage stays inactive.
    public func signIn(_ address: ServerAddress, info: ServerInfo, username: String, password: String,
                       library: String? = nil) async throws -> ServerPendingSignIn {
        await refresh()
        let client = dependencies.makeClient(address)
        let candidates = registry.libraries.filter {
            $0.state == .inactive && $0.serverURL == address.string && $0.username.lowercased() == username.lowercased()
                && (library == nil || $0.id == library)
        }.sorted { $0.createdAt > $1.createdAt }
        func installation(_ kept: LibraryRegistry.ServerLibrary?) -> (install: String, nonce: String) {
            var installID = ContractIdentity.randomUUID(), nonce = ContractIdentity.randomUUID()
            if let kept, let install = try? dependencies.provisioning.installID(of: LibraryLocation(root: dependencies.root, reference: .server(kept.id))) {
                installID = install
                if let saved = try? dependencies.secrets.installation(library: kept.id, install: install) { nonce = saved.transportNonce }
            }
            return (installID, nonce)
        }
        func signIn(_ install: (install: String, nonce: String)) async throws -> (ServerSignIn, String) {
            do {
                return (try await client.signIn(username: username, password: password, installID: install.install,
                                                transportNonce: install.nonce, device: dependencies.device), install.nonce)
            } catch ServerClientError.installationConflict {
                // The ID is held by another physical install (a copy): a fresh installation, once (PROTOCOL §5).
                let fresh = ContractIdentity.randomUUID()
                return (try await client.signIn(username: username, password: password, installID: ContractIdentity.randomUUID(),
                                                transportNonce: fresh, device: dependencies.device), fresh)
            }
        }
        var (answer, nonce) = try await signIn(installation(candidates.first))
        // The kept library of the server and account that signed in, if any.
        let kept = candidates.first { $0.serverID == info.serverID && $0.accountID == answer.accountID }
        let own = kept.map(installation)
        if let kept, let own, kept.id != candidates.first?.id, own.install != answer.installID {
            // Another candidate's installation authenticated: that sign-in goes, the matching library signs in with its own.
            await signOutQuietly(client, token: answer.token)
            (answer, nonce) = try await signIn(own)
        }
        let resume = kept.flatMap { kept in answer.installID == own?.install ? kept.id : nil }
        return ServerPendingSignIn(kind: resume.map { .resume(libraryID: $0) } ?? .firstAttachment, address: address,
                                   serverID: info.serverID, username: answer.username, accountID: answer.accountID,
                                   namespace: answer.namespace, installID: answer.installID, transportNonce: nonce,
                                   token: answer.token, device: dependencies.device)
    }

    /// Cancel on a confirmation: sign out (best effort) and forget the token.
    public func discard(_ pending: ServerPendingSignIn) async {
        await signOutQuietly(dependencies.makeClient(pending.address), token: pending.token)
    }

    /// Resume: store the token, mark the kept library `ready` and switch to it under the activation rule.
    public func confirmResume(_ pending: ServerPendingSignIn, scene: String?) async throws {
        guard case .resume(let id) = pending.kind else { throw ServerAccountError.noServerLibrary }
        try dependencies.secrets.saveInstallation(.init(transportNonce: pending.transportNonce, token: pending.token,
                                                        device: pending.device), library: id, install: pending.installID)
        try updateRegistry { registry in
            guard let index = registry.libraries.firstIndex(where: { $0.id == id }), registry.libraries[index].state == .inactive else {
                throw ServerAccountError.libraryInUse
            }
            registry.libraries[index].state = .ready
            registry.libraries[index].username = pending.username
        }
        await refresh()
        try await requestSwitch(.server(id), reason: .resume, scene: scene)
    }

    // MARK: - First attachment (PROTOCOL §15.4)

    /// Confirm on "Use the server's library": the library is registered `attaching`, its token stored and its
    /// database created in its own folder; the snapshot follows in the background.
    public func beginAttachment(_ pending: ServerPendingSignIn, scene: String?) async throws {
        guard pending.kind == .firstAttachment else { throw ServerAccountError.noServerLibrary }
        let id = ContractIdentity.randomUUID()
        preparing.insert(id)
        defer { preparing.remove(id) }
        let created = Int64((dependencies.clock().timeIntervalSince1970 * 1_000).rounded(.down))
        try updateRegistry { registry in
            registry.libraries.append(.init(id: id, serverURL: pending.address.string, serverID: pending.serverID,
                                            accountID: pending.accountID, username: pending.username, state: .attaching,
                                            createdAt: created))
        }
        do {
            try dependencies.secrets.saveInstallation(.init(transportNonce: pending.transportNonce, token: pending.token,
                                                            device: pending.device), library: id, install: pending.installID)
            let location = LibraryLocation(root: dependencies.root, reference: .server(id))
            try await dependencies.provisioning.provision(location, ServerLibraryProvision(
                libraryID: id, serverURL: pending.address.string, serverID: pending.serverID, accountID: pending.accountID,
                namespace: pending.namespace, username: pending.username, installID: pending.installID,
                deviceMarker: try dependencies.secrets.deviceMarker()))
        } catch {
            await signOutQuietly(dependencies.makeClient(pending.address), token: pending.token)
            try? await removeLibrary(id)
            throw error
        }
        preparing.remove(id)
        await refresh()
        startAttachment(id, scene: scene)
    }

    /// "Use empty library".
    public func confirmEmptyAccount(scene: String?) async {
        guard case .emptyAccount(let id) = question else { return }
        question = nil
        emptyConfirmed.insert(id)
        changed()
        guard let snapshot = pendingSnapshots.removeValue(forKey: id) else { startAttachment(id, scene: scene); return }
        attachTasks[id] = Task { [weak self] in
            await self?.finishAttachment(id, snapshot: snapshot, scene: scene)
            self?.attachTasks[id] = nil
        }
    }

    /// Runs (or resumes) a library's attachment unless it is already running.
    private func startAttachment(_ id: String, scene: String?) {
        guard attachTasks[id] == nil, !preparing.contains(id) else { return }
        attachTasks[id] = Task { [weak self] in
            await self?.attach(id, scene: scene)
            self?.attachTasks[id] = nil
        }
    }

    private func attach(_ id: String, scene: String?) async {
        guard let entry = registry.library(id), entry.state == .attaching, let address = ServerAddress(stored: entry.serverURL) else { return }
        let location = LibraryLocation(root: dependencies.root, reference: .server(id))
        let install: String?, credential: ServerInstallationCredential?
        do {
            install = try dependencies.provisioning.installID(of: location)
            credential = try install.flatMap { try dependencies.secrets.installation(library: id, install: $0) }
        } catch {
            // Unreadable now (the Keychain before the first unlock, a busy database): kept for the next attempt.
            if scene != nil { onFailure?(error) }
            return
        }
        // Interrupted before its database or token existed: nothing to resume, nothing to keep.
        guard let install, let credential else {
            try? await removeLibrary(id)
            return
        }
        do {
            guard let token = credential.usableToken, let staging = location.staging else { throw ServerClientError.unauthorized }
            let snapshot = try await ServerAttachSnapshotDownload(client: dependencies.makeClient(address), token: token,
                installID: install, folder: staging.appendingPathComponent("attach", isDirectory: true)).run { items in
                    await MainActor.run { [weak self] in self?.attachProgress[id] = items; self?.changed() }
                }
            try Task.checkCancellation()
            if snapshot.isEmptyAccount, !emptyConfirmed.contains(id) {
                pendingSnapshots[id] = snapshot
                question = .emptyAccount(libraryID: id)
                changed()
                return
            }
            // Started by the page's Confirm, the switch follows that tap: the page reopens after it.
            await finishAttachment(id, snapshot: snapshot, scene: scene)
        } catch is CancellationError {
        } catch {
            if (error as? ServerClientError)?.rejectsCredentials == true { markRejected(id, install: install) }
            if scene != nil { onFailure?(error) }
            await refresh()
        }
    }

    /// Steps 4–8: the applier builds the library from the snapshot, then it is `ready` and the
    /// switch follows.
    private func finishAttachment(_ id: String, snapshot: ServerAttachSnapshot, scene: String?) async {
        guard let entry = registry.library(id), entry.state == .attaching, let address = ServerAddress(stored: entry.serverURL) else { return }
        let location = LibraryLocation(root: dependencies.root, reference: .server(id))
        do {
            guard let install = try dependencies.provisioning.installID(of: location),
                  let token = try dependencies.secrets.installation(library: id, install: install)?.usableToken else {
                throw ServerClientError.unauthorized
            }
            do {
                try await dependencies.applier.apply(snapshot, to: ServerAttachmentTarget(
                    location: location, libraryID: id, installID: install, token: token, client: dependencies.makeClient(address)))
            } catch ServerAttachmentError.projectionUnavailable {
                waitingForProjection.insert(id)
                await refresh()
                return
            }
            try Task.checkCancellation()
            try ServerLibraryStatusFile(location: location).record(at: dependencies.clock(), successful: true)
            if let staging = location.staging { try? FileManager.default.removeItem(at: staging.appendingPathComponent("attach")) }
            attachProgress[id] = nil
            try updateRegistry { registry in
                guard let index = registry.libraries.firstIndex(where: { $0.id == id && $0.state == .attaching }) else {
                    throw CancellationError()
                }
                registry.libraries[index].state = .ready
            }
            await refresh()
            try await requestSwitch(.server(id), reason: .attach, scene: scene)
        } catch is CancellationError {
        } catch {
            if scene != nil { onFailure?(error) }
            await refresh()
        }
    }

    // MARK: - Logout (PROTOCOL §15.4) and sign in again

    /// The changes the server has not confirmed (PROTOCOL §15.4, the logout dialog's count): the open library's unreceipted
    /// outbox entries plus its drafts. Some may have reached the server with the answer lost.
    public func unconfirmedChanges() async -> Int {
        guard let entry = currentLibrary() else { return 0 }
        let location = LibraryLocation(root: dependencies.root, reference: .server(entry.id))
        let provisioning = dependencies.provisioning
        return await Task.detached(priority: .userInitiated) { (try? provisioning.unsentChanges(of: location)) ?? 0 }.value
    }

    /// The page's Logout in server mode. An unfinished attachment is cancelled and its library
    /// removed. Otherwise the logout cut-off (PROTOCOL §15.4), with no step waiting for the network: the choice is
    /// recorded; sync stops; the installation's token is removed here; a background task signs out with that token
    /// only. Go back: this device's library follows under the activation rule, the server library's database,
    /// outbox and installation kept for logging in again. Keep: the Keep transaction runs under the same rule.
    public func logout(_ choice: ServerLogoutChoice = .goBack, scene: String?) async throws {
        await refresh()
        if let entry = registry.libraries.first(where: { $0.state == .attaching }), !opened(entry.id) {
            question = nil
            if let task = attachTasks.removeValue(forKey: entry.id) { task.cancel(); await task.value }
            if let address = ServerAddress(stored: entry.serverURL) {
                for install in (try? dependencies.secrets.installIDs(of: entry.id)) ?? [] {
                    if let token = try? dependencies.secrets.installation(library: entry.id, install: install)?.usableToken {
                        await signOutQuietly(dependencies.makeClient(address), token: token)
                    }
                }
            }
            try await removeLibrary(entry.id)
            return
        }
        guard let entry = currentLibrary() else { throw ServerAccountError.noServerLibrary }
        // Keep needs a library this device has used; a library still waiting to be switched to goes back.
        let choice: ServerLogoutChoice = entry.state == .active && opened(entry.id) ? choice : .goBack
        let location = LibraryLocation(root: dependencies.root, reference: .server(entry.id))
        // 1. Record the choice: from here on it survives a crash.
        switch choice {
        case .goBack:
            let time = Int64((dependencies.clock().timeIntervalSince1970 * 1_000).rounded(.down))
            try updateRegistry { registry in
                guard let index = registry.libraries.firstIndex(where: { $0.id == entry.id }) else { return }
                registry.libraries[index].state = .inactive
                try registry.recordSwitch(to: .standalone, reason: .logout, at: time)
            }
        case .keep:
            try LibraryKeep(.init(root: dependencies.root, secrets: dependencies.secrets, clock: dependencies.clock)).request(source: entry.id)
            if let saved = try? registryFile.read() { registry = saved }
        }
        // 2. Stop sync: nothing more is sent, and a response in flight is discarded.
        await dependencies.stopSync()
        // 3. Invalidate the token here, before anything could store a new one; the transport nonce stays.
        let token = invalidateToken(library: entry.id, location: location)
        // 4. Sign out, best effort, in the background, with that token and no other.
        if let token, let address = ServerAddress(stored: entry.serverURL) {
            let client = dependencies.makeClient(address)
            signOuts.append(Task { try? await client.signOut(token: token) })
        }
        exchange = ServerSynchronizationSignals()
        await refresh()
        // 5. Until the activation rule holds, the library stays the open one; what is done meanwhile is kept.
        switch choice {
        case .goBack: try await requestSwitch(.standalone, reason: .logout, scene: scene)
        case .keep:
            changed()
            // A Keep that runs at once follows this tap: the page reopens after the restart, as after a switch.
            interactiveSwitch = scene.map { ($0, .logout) }
            defer { interactiveSwitch = nil }
            await dependencies.attemptKeep()
        }
    }

    /// Reads and removes the installation's token from its Keychain item in one step (PROTOCOL §15.4). A failed removal is
    /// retried later only while the item still holds that same token.
    private func invalidateToken(library id: String, location: LibraryLocation) -> String? {
        guard let install = (try? dependencies.provisioning.installID(of: location)) ?? (try? dependencies.secrets.installIDs(of: id))?.first,
              var credential = try? dependencies.secrets.installation(library: id, install: install), let token = credential.token else { return nil }
        credential.token = nil; credential.device = nil; credential.rejected = false
        do { try dependencies.secrets.saveInstallation(credential, library: id, install: install) }
        catch {
            pendingTokenRemovals.append(.init(library: id, install: install, token: ServerTokenRemovals.digest(token)))
            tokenRemovalsUnsaved = true
            // Kept in memory for this run even if the record cannot be written; saved at the next chance.
            saveTokenRemovals()
        }
        return token
    }

    /// Retries the token removals the cut-off could not finish (at every graph start, so at launch), each only while
    /// its item still holds that token. An item that is gone or holds another token (a later login) ends the record
    /// untouched; an item that cannot be read or written keeps it for the next attempt.
    func retryTokenRemovals() {
        // A journal that cannot be read yet is retried at the next graph start, never rewritten without its removals.
        guard loadTokenRemovals() else { return }
        let before = pendingTokenRemovals
        pendingTokenRemovals.removeAll { pending in
            let stored: ServerInstallationCredential?
            do { stored = try dependencies.secrets.installation(library: pending.library, install: pending.install) } catch { return false }
            guard var credential = stored, let token = credential.token, ServerTokenRemovals.digest(token) == pending.token else { return true }
            credential.token = nil; credential.device = nil; credential.rejected = false
            return (try? dependencies.secrets.saveInstallation(credential, library: pending.library, install: pending.install)) != nil
        }
        if pendingTokenRemovals != before { tokenRemovalsUnsaved = true }
        saveTokenRemovals()
    }

    /// "Change login information" and "Sign in again": the library's own installation and transport nonce resume it,
    /// its unsent operations included (PROTOCOL §15.4). While an installation transition is planned (PROTOCOL §6.11) and the
    /// predecessor was replaced, the planned successor `T'` signs in with its own nonce instead, and the transition
    /// commits. An account that no longer has this library's history (the server replaced, the account made again
    /// under the same name: PROTOCOL §11) pauses the library with `lineage_unknown`; its token is not kept.
    public func signInAgain(password: String) async throws {
        guard let entry = currentLibrary(), entry.state == .active, opened(entry.id),
              let address = ServerAddress(stored: entry.serverURL) else { throw ServerAccountError.noServerLibrary }
        let location = LibraryLocation(root: dependencies.root, reference: .server(entry.id))
        var targets = try dependencies.provisioning.signInInstallations(of: location)
        guard !targets.isEmpty else { throw ServerAccountError.noServerLibrary }
        let client = dependencies.makeClient(address)
        var signedIn: (answer: ServerSignIn, install: String, nonce: String)?
        var index = 0
        while signedIn == nil, index < targets.count {
            let target = targets[index]
            index += 1
            let nonce = target.transportNonce ?? (try? dependencies.secrets.installation(library: entry.id, install: target.installID))?.transportNonce
                ?? ContractIdentity.randomUUID()
            do {
                let answer = try await client.signIn(username: entry.username, password: password, installID: target.installID,
                                                     transportNonce: nonce, device: dependencies.device)
                signedIn = (answer, target.installID, nonce)
            } catch let error as ServerClientError where error == .installationSuperseded || error == .installationConflict {
                // The installation was replaced (an already-superseded predecessor, PROTOCOL §6.10): its planned successor, or a
                // new installation the exchange plans now, continues.
                if index == targets.count, let fresh = await dependencies.newInstallation(), !targets.contains(fresh) { targets.append(fresh) }
                if index == targets.count { throw error }
            }
        }
        guard let signedIn else { throw ServerAccountError.noServerLibrary }
        let (answer, install, nonce) = signedIn
        guard answer.accountID == entry.accountID else {
            await signOutQuietly(client, token: answer.token)
            await dependencies.pauseSync(.lineageUnknown)
            exchange.pause = .lineageUnknown
            await refresh()
            return
        }
        try dependencies.secrets.saveInstallation(.init(transportNonce: nonce, token: answer.token, device: dependencies.device),
                                                  library: entry.id, install: install)
        exchange.unreachable = false
        lastCheck = dependencies.clock()
        await refresh()
        onSignedInAgain?()
    }

    /// "Start over with the server's library" (PROTOCOL §6.11 `lineage_unknown`), after the person signed in to the server's new
    /// lineage: this library becomes `inactive`, kept with its unsent changes (never discarded, PROTOCOL §5), and a first
    /// attachment begins (PROTOCOL §15.4), reusing downloads; nothing of the old lineage is replayed. The switch to the new
    /// library follows under the activation rule once it is ready.
    public func startOver(_ pending: ServerPendingSignIn, scene: String?) async throws {
        guard pending.kind == .firstAttachment, let entry = currentLibrary(), entry.state == .active, opened(entry.id) else {
            throw ServerAccountError.noServerLibrary
        }
        try updateRegistry { registry in
            guard let index = registry.libraries.firstIndex(where: { $0.id == entry.id }) else { return }
            registry.libraries[index].state = .inactive
        }
        await dependencies.stopSync()
        exchange = ServerSynchronizationSignals()
        try await beginAttachment(pending, scene: scene)
    }

    // MARK: - The account check

    /// For the open server library: `PUT /v1/installations/self` when the app version or capabilities differ from what
    /// the token was registered with (PROTOCOL §15.4), otherwise `GET /v1/installations`. A 401 or 403 pauses sync until the person
    /// signs in again; no answer shows "Waiting for the server". At most every 30 seconds unless `force`.
    public func checkAccount(force: Bool = false) async {
        guard case .server(let id) = dependencies.openLibrary(), let entry = registry.library(id), entry.state == .active,
              let address = ServerAddress(stored: entry.serverURL) else { return }
        let now = dependencies.clock()
        if !force, let lastCheck, now.timeIntervalSince(lastCheck) < Self.checkInterval { return }
        lastCheck = now
        let location = LibraryLocation(root: dependencies.root, reference: .server(id))
        guard let install = try? dependencies.provisioning.installID(of: location),
              var credential = try? dependencies.secrets.installation(library: id, install: install),
              let token = credential.usableToken else { await refresh(); return }
        let client = dependencies.makeClient(address)
        do {
            if credential.device != dependencies.device {
                try await client.updateInstallation(token: token, device: dependencies.device)
                credential.device = dependencies.device
                try dependencies.secrets.saveInstallation(credential, library: id, install: install)
            } else {
                _ = try await client.installations(token: token)
            }
            exchange.unreachable = false
        } catch let error as ServerClientError {
            if error.rejectsCredentials { markRejected(id, install: install) }
            exchange.unreachable = error == .unreachable
        } catch {}
        await refresh()
    }

    /// Later stages (the exchange, recovery, the log) report what the page explains: pauses, recovery, reachability
    /// and the "needs attention" items.
    public func update(signals: ServerSynchronizationSignals) {
        guard signals != exchange else { return }
        exchange = signals
        changed()
    }

    /// What the open library's exchange reported: the page's status (PROTOCOL §15.5), its last synchronization, its
    /// unsent changes, and "Sign in again" when the server refused the token. Updates only the page's state.
    public func exchangeReported(_ report: ServerExchangeReport) {
        guard case .server(let id) = dependencies.openLibrary(), let entry = registry.library(id), entry.state == .active else { return }
        let location = LibraryLocation(root: dependencies.root, reference: .server(id))
        // A cancelled exchange, or one whose network sync may not use, tells nothing about the server: only what is
        // unsent may have changed.
        if report.cancelled || report.networkNotPermitted {
            if var summary = summaries[id] { summary.unsentChanges = report.unsentChanges; summaries[id] = summary; changed() }
            return
        }
        var signals = exchange
        // A stored state says nothing about reachability; an exchange does.
        if !report.stateOnly {
            signals.unreachable = report.unreachable
            signals.waitingForBackground = report.waitingForBackground
        }
        signals.attentionItems = report.attentionItems
        signals.recovery = switch report.recovery {
        case .running?: .running
        case .waiting?: .waiting
        case .incomplete?: .incomplete
        case nil: nil
        }
        switch report.pause {
        case .versionUnsupported?: signals.pause = report.appNeedsUpdate ? .appNeedsUpdate : .serverNeedsUpdate
        case .lineageUnknown?: signals.pause = .lineageUnknown
        case .lineageMismatch?: signals.pause = .serverRestored
        case .transportConflict?: signals.pause = .sharedInstallation
        case .dependencyLost?: signals.pause = .serverLostChanges
        case .signIn?, nil: signals.pause = nil
        }
        var summary = summaries[id] ?? ServerLibrarySummary(entry: entry)
        summary.unsentChanges = report.unsentChanges
        if report.pause == .signIn {
            if let install = try? dependencies.provisioning.installID(of: location) { markRejected(id, install: install) }
            summary.hasUsableToken = false
        }
        // "Successful (…)" after an exchange that completed, "Failed (…)" after one the server or the phone failed;
        // an unreachable server says "Waiting for the server" instead, and a pause explains itself.
        let failed = report.error != nil || (report.retryAfter != nil && !report.unreachable && report.pause == nil)
        if report.completed || failed {
            let file = ServerLibraryStatusFile(location: location)
            try? file.record(at: dependencies.clock(), successful: report.completed)
            summary.lastSynchronization = file.read()
        }
        summaries[id] = summary
        exchange = signals
        changed()
    }

    /// Background processing time: an unfinished first attachment continues. Returns whether none is left.
    /// Attachment work this call starts belongs to its background time: when the caller is cancelled (the time
    /// expired) that work is cancelled too, and resumes from its durable state later. An attachment already running
    /// for the page is not this call's and is left alone.
    public func continueAttachments() async -> Bool {
        await refresh()
        var owned: [Task<Void, Never>] = []
        for entry in registry.libraries where entry.state == .attaching && !waitingForProjection.contains(entry.id) && question == nil
            && attachTasks[entry.id] == nil {
            startAttachment(entry.id, scene: nil)
            if let task = attachTasks[entry.id] { owned.append(task) }
        }
        await withTaskCancellationHandler {
            for task in owned { await task.value }
        } onCancel: {
            for task in owned { task.cancel() }
        }
        return !hasUnfinishedAttachment
    }

    /// A first attachment is not finished (processing background tasks are scheduled for it).
    public var hasUnfinishedAttachment: Bool { registry.libraries.contains { $0.state == .attaching } }

    private func markRejected(_ id: String, install: String) {
        guard var credential = try? dependencies.secrets.installation(library: id, install: install) else { return }
        credential.rejected = true
        try? dependencies.secrets.saveInstallation(credential, library: id, install: install)
    }

    // MARK: - Kept libraries (PROTOCOL §15.5)

    /// "Remove library": its folder (database, downloads), tokens and Keychain feed credentials. Only a kept
    /// (inactive) library; an interrupted removal finishes at the next graph start.
    public func removeKeptLibrary(_ id: String) async throws {
        guard let entry = registry.library(id), entry.state == .inactive || entry.state == .removing, !opened(id) else {
            throw ServerAccountError.libraryInUse
        }
        try await removeLibrary(id)
    }

    private func removeLibrary(_ id: String) async throws {
        // Under the library gate (PROTOCOL §11.5): no export reads it while it goes.
        let gate = dependencies.gate
        await gate.acquireExclusive()
        defer { gate.releaseExclusive() }
        try updateRegistry { registry in
            guard let index = registry.libraries.firstIndex(where: { $0.id == id }) else { return }
            registry.libraries[index].state = .removing
        }
        let location = LibraryLocation(root: dependencies.root, reference: .server(id))
        try await dependencies.provisioning.discardFeedCredentials(of: location)
        try dependencies.secrets.removeLibrary(id)
        if !LibraryLocation.isAbsent(location.folder) { try FileManager.default.removeItem(at: location.folder) }
        try updateRegistry { registry in registry.libraries.removeAll { $0.id == id } }
        attachProgress[id] = nil; waitingForProjection.remove(id); emptyConfirmed.remove(id); pendingSnapshots[id] = nil
        if question == .emptyAccount(libraryID: id) { question = nil }
        await refresh()
    }

    // MARK: - Previous libraries (PROTOCOL §15.4)

    /// "Remove library" of a previous library: under the library gate, marked `removing` in the registry, its
    /// Keychain feed credentials deleted (their IDs read through the read-only reader), then its folder. It never
    /// follows a path a row names outside its own folder. An interrupted removal finishes at the next graph start.
    public func removePreviousLibrary(_ id: String) async throws {
        let gate = dependencies.gate
        await gate.acquireExclusive()
        defer { gate.releaseExclusive() }
        guard registry.previousLibrary(id) != nil || (try? registryFile.read())?.previousLibrary(id) != nil else { return }
        try updateRegistry { registry in
            guard let index = registry.previous.firstIndex(where: { $0.id == id }) else { return }
            registry.previous[index].state = .removing
        }
        let location = PreviousLibraryLocation(root: dependencies.root, id: id)
        let vault = dependencies.feedVault()
        try await Task.detached(priority: .userInitiated) {
            if !LibraryLocation.isAbsent(location.database) {
                let reader = try LibrarySQLite(readingOnly: location.database)
                let ids = try reader.transaction(write: false) {
                    try reader.rows("SELECT credential_id FROM feed_credentials UNION SELECT credential_id FROM feed_credential_cleanup").compactMap {
                        $0[0].text.flatMap(UUID.init(uuidString:))
                    }
                }
                try? reader.close()
                for credential in ids { try vault.remove(id: credential) }
            }
            if !LibraryLocation.isAbsent(location.folder) { try FileManager.default.removeItem(at: location.folder) }
        }.value
        try updateRegistry { registry in registry.previous.removeAll { $0.id == id } }
        changed()
    }

    // MARK: - Graph start

    /// At every graph start: finishes an interrupted removal, resumes an interrupted attachment, and checks the open
    /// server library's account.
    public func graphStarted() {
        Task { [weak self] in
            guard let self else { return }
            await refresh()
            retryTokenRemovals()
            for previous in registry.previous where previous.state == .removing {
                try? await removePreviousLibrary(previous.id)
            }
            for entry in registry.libraries where entry.state == .removing && !opened(entry.id) && !preparing.contains(entry.id) {
                try? await removeLibrary(entry.id)
            }
            for entry in registry.libraries where entry.state == .attaching && !waitingForProjection.contains(entry.id) {
                startAttachment(entry.id, scene: nil)
            }
            await checkAccount(force: true)
        }
    }

    /// The page opened: resume a stalled attachment and check the account (rate-limited).
    public func pageOpened() {
        Task { [weak self] in
            guard let self else { return }
            await refresh()
            for entry in registry.libraries where entry.state == .attaching && !waitingForProjection.contains(entry.id) && question == nil {
                startAttachment(entry.id, scene: nil)
            }
            await checkAccount()
        }
    }

    // MARK: - Helpers

    /// The attaching, ready or active library (at most one, PROTOCOL §11.5).
    func currentLibrary() -> LibraryRegistry.ServerLibrary? {
        if case .server(let id) = dependencies.openLibrary(), let entry = registry.library(id), entry.state == .active { return entry }
        return registry.libraries.first { $0.state == .ready || $0.state == .active }
    }

    private func opened(_ id: String) -> Bool { dependencies.openLibrary() == .server(id) }

    private func updateRegistry(_ change: (inout LibraryRegistry) throws -> Void) throws {
        registry = try registryFile.update(change)
    }

    private func requestSwitch(_ target: LibraryReference, reason: LibraryRegistry.SwitchReason, scene: String?) async throws {
        interactiveSwitch = scene.map { ($0, reason) }
        defer { interactiveSwitch = nil }
        try await dependencies.requestSwitch(target, reason, scene)
        if let saved = try? registryFile.read() { registry = saved }
        changed()
    }

    /// Best effort, bounded: the token is forgotten whatever the server answers.
    private func signOutQuietly(_ client: ServerClient, token: String) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await client.signOut(token: token) }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            await group.next()
            group.cancelAll()
        }
    }
}

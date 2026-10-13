import UIKit
import OSLog
import BackgroundTasks
import NotTennaPodCore

extension AppDelegate {
    /// At every graph start: the NotTennaPod server accounts (PROTOCOL §15.4) are created once for the
    /// library root, then resume an interrupted attachment or removal and check the open server library's account.
    /// Switches go only through the library switcher's activation rule.
    func startServerAccounts(root: URL) {
        // Compared by path: the root's URL gains a trailing slash once its folder exists.
        if serverAccounts?.root.standardizedFileURL.path != root.standardizedFileURL.path {
            let model = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            var dependencies = ServerAccounts.Dependencies(root: root,
                openLibrary: { [weak self] in self?.libraryLocation?.reference ?? .standalone },
                requestSwitch: { [weak self] target, reason, _ in
                    guard let switcher = self?.librarySwitch else { throw ServerAccountError.noServerLibrary }
                    try await switcher.request(target, reason: reason)
                    Logger(subsystem: "org.nottennapod.app", category: "Libraries").notice(
                        "Switch to \(target.name, privacy: .public) (\(reason.rawValue, privacy: .public)) \(switcher.isPending ? "waits for the activation rule" : "applied", privacy: .public)")
                },
                secrets: KeychainServerSecrets(markerAccount: Self.serverMarkerAccount(root)),
                makeClient: { [weak self] address in
                    ServerClient(address: address, transport: self?.serverTransport() ?? URLSessionSynchronizationTransport(),
                                 userAgent: HTTPUserAgent.current)
                },
                // The one place the attach applier is chosen: it builds the library from the
                // snapshot.
                applier: ServerExchangeAttachApplier(),
                device: .current(model: model))
            // The logout cut-off (PROTOCOL §15.4): sync stops at once; a recorded Keep runs under the activation rule.
            dependencies.stopSync = { [weak self] in
                await self?.stopServerSync()
                self?.scheduleServerSyncBackgroundTasks(refresh: false)
            }
            dependencies.attemptKeep = { [weak self] in await self?.librarySwitch?.attempt() }
            // Signing in again reached an account without this library's history (PROTOCOL §6.11 `lineage_unknown`), or found its
            // installation replaced by another library's successor (PROTOCOL §6.10): the exchange pauses, or plans a new one.
            dependencies.pauseSync = { [weak self] reason in await self?.serverSync?.pause(reason) }
            dependencies.newInstallation = { [weak self] in await self?.serverSync?.planNewInstallation() }
            dependencies.castBlocks = { [weak self] in self?.castRuntime?.blocksLibrarySwitch ?? false }
            dependencies.keepFailure = { [weak self] in self?.keepFailure }
            // What a waiting switch or Keep waits for on the player, and "Stop playback and continue".
            dependencies.playbackHold = { [weak self] in
                guard let self, librarySwitch?.isPending == true || keepIsPending else { return nil }
                return LibraryActivationState(playback, castBlocks: false).playbackHold
            }
            dependencies.stopPlayback = { [weak self] in try? await self?.playback?.stop() }
            serverAccounts = ServerAccounts(dependencies)
            // Signed in again: the open library's exchange continues (PROTOCOL §15.4).
            serverAccounts?.onSignedInAgain = { [weak self] in
                guard let scheduler = self?.serverSync else { return }
                Task { await scheduler.resume() }
            }
        }
        serverAccounts?.graphStarted()
    }

    /// A DEBUG test library keeps its own device marker and installation items (PROTOCOL §15.4).
    static func serverMarkerAccount(_ root: URL) -> String {
        root.lastPathComponent.hasPrefix("UITests-") ? root.lastPathComponent : "default"
    }

    /// Proxy settings apply as for gpodder.net; a proxy that cannot be used never falls back to a direct
    /// connection.
    func serverTransport() -> any SynchronizationHTTPTransport {
        guard let proxy = proxyNetwork?.sharedConfiguration(), proxy.isConfigured else { return URLSessionSynchronizationTransport() }
        return (try? ProxySynchronizationTransport(proxy: proxy)) ?? UnusableProxyTransport()
    }
}

// MARK: - The exchange (PROTOCOL §6.8)

/// The server sync background tasks: new identifiers, listed in `BGTaskSchedulerPermittedIdentifiers`.
enum ServerSyncBackgroundTasks {
    static let refresh = "org.nottennapod.app.server-sync"
    static let processing = "org.nottennapod.app.server-sync-processing"
    /// The refresh task's earliest start after a successful synchronization.
    static let refreshInterval: TimeInterval = 30 * 60
}

extension AppDelegate {
    /// The open server library's exchange, owned by the app core whether or not the Synchronization page is open:
    /// the engine with the installation's token from the Keychain (read at every request, so signing in again takes
    /// effect at once), the server's change hints, the "Synchronization" mobile-data preference, and the player's
    /// state for the budgets of PROTOCOL §6.8. Nothing starts for the standalone library, or for a server library that is not
    /// `active` (logged out while playing).
    func startServerSync(store: FeedLibraryStore, location: LibraryLocation) {
        guard case .server(let id) = location.reference, let root = libraryDirectory,
              let entry = (try? LibraryRegistryFile(root: root).read())?.library(id), entry.state == .active,
              let address = ServerAddress(stored: entry.serverURL), let base = URL(string: address.string) else { return }
        let secrets = KeychainServerSecrets(markerAccount: Self.serverMarkerAccount(root))
        let model = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        // Copies, transport conflicts and recovery after a restore take new installations with these items (PROTOCOL §6.10).
        let installations = ServerInstallationKeychain(libraryID: id, secrets: secrets, device: .current(model: model))
        let token: @Sendable () async throws -> String? = {
            guard let install = try await store.serverInstallationID() else { return nil }
            return try secrets.installation(library: id, install: install)?.usableToken
        }
        let mobile = mobileNetworkPreferences
        let allowsMobile: @Sendable () async -> Bool = { await MainActor.run { mobile?.allows(.sync) ?? false } }
        let network = DownloadNetworkSyncGate(allowMobile: allowsMobile)
        let transport = HTTPServerExchangeTransport(base: base, transport: serverTransport(), userAgent: HTTPUserAgent.current,
                                                    network: network, token: token)
        let engine: ServerSyncEngine
        // Moved on at every foreground and playback transition: a large publication queued behind other store work
        // never starts once someone uses the app.
        let eligibility = ServerPublicationEligibility()
        serverPublicationEligibility = eligibility
        do {
            engine = try ServerSyncEngine(store: store, location: location, transport: transport, isPlaying: { [weak self] in
                await MainActor.run { self?.serverSyncSeesPlayback ?? false }
            }, isForeground: {
                // As the scene delegate decides the app left the foreground: no scene active or inactive.
                await MainActor.run {
                    UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
                }
            }, eligibility: eligibility, installations: installations)
        } catch {
            Logger(subsystem: "org.nottennapod.app", category: "Synchronization").error("Server sync could not open its files")
            return
        }
        let proxy = proxyNetwork?.sharedConfiguration()
        let hints = ServerEventStream(base: base, proxy: proxy?.isConfigured == true ? proxy : nil, userAgent: HTTPUserAgent.current,
                                      allowsMobile: allowsMobile, token: token)
        let scheduler = ServerSyncScheduler(engine: engine, hints: hints, outbox: { await store.serverOutboxChanges() }, network: network,
                                            eligibility: eligibility)
        scheduler.callbacks.reported = { [weak self] report in
            self?.serverAccounts?.exchangeReported(report)
            self?.scheduleServerSyncBackgroundTasks(refresh: report.completed)
        }
        // A remote position waiting for the player's paused episode is adopted after each catch-up and at each pause
        // (PROTOCOL §8.6); sync never moves playing audio.
        let adoption = playback.map { ServerPlaybackAdoption(store: store, playback: $0) }
        // At most once a second during catch-up (PROTOCOL §6.8); each screen coalesces its own reloads.
        scheduler.callbacks.libraryChanged = {
            for controller in Self.libraryControllers { _ = controller.reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true) }
            adoption?.attempt()
        }
        scheduler.callbacks.feedsDeleted = { [weak self] in self?.feedDeletion?.resume() }
        scheduler.callbacks.accountPoliciesChanged = { [weak self] in self?.reloadServerAccountPolicy() }
        // Releases another device or the server found notify this phone too, once each (PROTOCOL §9.9); what is still owed is
        // delivered at launch, in the foreground and after every exchange.
        // One owner per library: wakes coalesce, and stopping the sync stops every delivery.
        let releases = episodeNotifications.map { notifications in
            ServerReleaseDeliveryOwner(delivery: notifications, failed: { _ in
                Logger(subsystem: "org.nottennapod.app", category: "Synchronization").error("New-episode notifications kept for later")
            })
        }
        serverReleaseDelivery = releases
        scheduler.callbacks.releasesArrived = { [weak releases] in releases?.wake() }
        // A podcast merge's per-feed speed and skip silence go to the survivor (PROTOCOL §9.7), also what an earlier run left.
        scheduler.callbacks.feedsMerged = { [weak self] in self?.carryServerFeedMerges(store: store) }
        carryServerFeedMerges(store: store)
        serverSync = scheduler
        if let playback {
            scheduler.playbackChanged(playing: serverSyncSeesPlayback)
            let events = playback.events()
            serverSyncPlayback = Task { [weak self, weak scheduler, weak playback] in
                var episode = playback?.episode?.id
                for await event in events {
                    guard case .stateChanged = event, let self, let scheduler, let playback else { continue }
                    scheduler.playbackChanged(playing: self.serverSyncSeesPlayback)
                    if !self.serverSyncSeesPlayback { adoption?.attempt() }
                    // The player left an episode: what waited for it applies now (PROTOCOL §6.8).
                    if playback.episode?.id != episode {
                        episode = playback.episode?.id
                        scheduler.playerLeftEpisode()
                    }
                }
            }
        }
        scheduler.start()
        adoption?.attempt()
        if UIApplication.shared.applicationState == .active { scheduler.setForeground(true) }
        scheduleServerSyncBackgroundTasks(refresh: true)
    }

    /// Per-feed speed and skip silence of merged podcasts (PROTOCOL §9.7), kept in the library's playback file.
    func carryServerFeedMerges(store: FeedLibraryStore) {
        guard let speeds = speedPreferences else { return }
        Task {
            do { try await speeds.carryServerFeedMerges(from: store) }
            catch { Logger(subsystem: "org.nottennapod.app", category: "Synchronization").error("Merged podcasts' playback speeds kept for later") }
        }
    }

    /// The graph stops: the running exchange ends cleanly (everything is resumable) and the engine's files close
    /// before the store does.
    func stopServerSync() async {
        serverSyncPlayback?.cancel(); serverSyncPlayback = nil
        // No new wakes; every delivery stopped and settled before the sync and its library go.
        serverSync?.callbacks.releasesArrived = {}
        let releases = serverReleaseDelivery
        serverReleaseDelivery = nil
        await releases?.stop()
        let scheduler = serverSync
        serverSync = nil
        await scheduler?.close()
    }

    /// Playing, as the exchange's budgets mean it (PROTOCOL §6.8): only actual playback (`playsForSynchronization`); an item
    /// paused, or held silent by an interruption, is not, and its resumption moves the publication eligibility on.
    var serverSyncSeesPlayback: Bool { playback?.playsForSynchronization ?? false }

    /// The account's policies changed (another device, or a repair): the facade reads them again and the queue's
    /// insertion settings follow (PROTOCOL §15.4).
    private func reloadServerAccountPolicy() {
        guard let policy = accountPolicy, let backing = policy.backing as? ServerAccountPolicyBacking, let store = library else { return }
        Task {
            await backing.reload()
            store.setQueueInsertionSettings(policy.queueInsertionSettings())
        }
    }

    // MARK: - Background tasks

    /// Registered once at launch, before the first graph start.
    func registerServerSyncBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: ServerSyncBackgroundTasks.refresh, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else { task.setTaskCompleted(success: false); return }
                self.runServerSyncInBackground(NativeServerSyncBackgroundLease(task, kind: "server-sync-refresh"), work: .refresh)
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: ServerSyncBackgroundTasks.processing, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else { task.setTaskCompleted(success: false); return }
                self.runServerSyncInBackground(NativeServerSyncBackgroundLease(task, kind: "server-sync-processing"), work: .processing)
            }
        }
    }

    /// `server-sync`: push, then one incremental pull and its units. `server-sync-processing`: an unfinished first
    /// attachment, a publication or Force full synchronization waiting for a pause or for the app to leave the
    /// foreground. Both stop at expiration; all of it is resumable. Background work never starts a library switch (the
    /// switcher only applies in the foreground). The handler of both tasks; in DEBUG also run by the hub bridge's
    /// `run_server_sync`, with a lease standing in for the `BGTask`.
    func runServerSyncInBackground(_ lease: any ServerSyncBackgroundLeasing, work: ServerSyncScheduler.BackgroundWork) {
        let scheduler = serverSync, accounts = serverAccounts
        // While this task's window lasts, the shared background grant neither covers nor parks the exchange.
        let window = UUID()
        serverSyncWindows.insert(window)
        let closeWindow: @MainActor () -> Void = { [weak self] in _ = self?.serverSyncWindows.remove(window) }
        let run = Task { @MainActor [weak self] in
            var done = true
            if work == .processing, let accounts, accounts.hasUnfinishedAttachment { done = await accounts.continueAttachments() }
            if let scheduler { done = await scheduler.runInBackground(work) && done }
            closeWindow()
            lease.complete(success: done && !Task.isCancelled)
            // The next refresh in 30 minutes, whether this one completed or not: everything left is resumable.
            self?.scheduleServerSyncBackgroundTasks(refresh: true)
        }
        lease.expiration = {
            closeWindow()
            run.cancel()
            scheduler?.suspendForBackground()
            lease.complete(success: false)
        }
    }

    /// The refresh task while a server library is open, 30 minutes after the last successful synchronization
    /// (`refresh`: one just ended); the processing task only while heavy work is unfinished. Also when the app leaves
    /// the foreground, for an attachment that continues while the standalone library is open.
    func scheduleServerSyncBackgroundTasks(refresh: Bool) {
        let log = Logger(subsystem: "org.nottennapod.app", category: "Synchronization")
        if serverSync == nil {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: ServerSyncBackgroundTasks.refresh)
        } else if refresh {
            let request = BGAppRefreshTaskRequest(identifier: ServerSyncBackgroundTasks.refresh)
            // Never before the retry deadline (the backoff, or the server's Retry-After).
            request.earliestBeginDate = max(Date().addingTimeInterval(ServerSyncBackgroundTasks.refreshInterval),
                                            serverSync?.retryNotBeforeDate ?? .distantPast)
            do { try BGTaskScheduler.shared.submit(request) } catch { log.notice("Background sync request not accepted; foreground triggers continue") }
        }
        if serverSync?.needsProcessingTime == true || serverAccounts?.hasUnfinishedAttachment == true {
            let request = BGProcessingTaskRequest(identifier: ServerSyncBackgroundTasks.processing)
            request.earliestBeginDate = serverSync?.retryNotBeforeDate
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            do { try BGTaskScheduler.shared.submit(request) } catch { log.notice("Background sync processing request not accepted") }
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: ServerSyncBackgroundTasks.processing)
        }
    }
}

/// A server-sync background task's time: its expiration handler and its completion, exactly once.
@MainActor protocol ServerSyncBackgroundLeasing: AnyObject {
    /// The production expiration handler the task's work sets.
    var expiration: (@MainActor () -> Void)? { get set }
    func complete(success: Bool)
}

/// The `BGTask` of a server-sync background task, completed exactly once, whichever of its work or its expiration
/// ends first. In DEBUG the hub bridge is told of it and may call its expiration handler, as iOS would.
@MainActor final class NativeServerSyncBackgroundLease: ServerSyncBackgroundLeasing {
    private var task: BGTask?
    var expiration: (@MainActor () -> Void)?
#if DEBUG
    private var hubLease: String?
#endif
    init(_ task: BGTask, kind: String) {
        self.task = task
        task.expirationHandler = { [weak self] in Task { @MainActor in self?.expiration?() } }
#if DEBUG
        hubLease = HubBridge.shared?.leaseTaken(kind: kind) { [weak task] in task?.expirationHandler?() }
#endif
    }
    func complete(success: Bool) {
        guard let task else { return }
        self.task = nil
        expiration = nil
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
#if DEBUG
        if let hubLease { HubBridge.shared?.leaseEnded(hubLease, state: "released", success: success) }
#endif
    }
}

private struct UnusableProxyTransport: SynchronizationHTTPTransport {
    func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse { throw URLError(.cannotConnectToHost) }
}

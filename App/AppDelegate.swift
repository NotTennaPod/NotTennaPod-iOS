import UIKit
import NotTennaPodCore
import OSLog
import UserNotifications
import BackgroundTasks
import Synchronization

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var library: FeedLibraryStore?
    var startupError: Error?
    /// The one owner of the graph's start (`AppDelegate+Startup.swift`): launch, retries after protected data was
    /// unavailable, and restarts after a switch, an import or a Keep.
    lazy var libraryStartup = makeLibraryStartup()
    var startupHandoff = LibraryStartupHandoff()
    var feedDeletion: FeedDeletionCoordinator?
    var downloads: DownloadCoordinator?
    var statisticsPreferences: StatisticsPreferenceStore?
    /// Discover Hide and country (the source's CountryRegionPrefs).
    var discoveryPreferences: DiscoveryPreferenceStore?
    var downloadPreferences: DownloadPreferenceStore?
    var inboxSwipePreferences: SwipePreferenceStore?
    var allEpisodesFilterPreferences: AllEpisodesFilterPreferenceStore?
    var intervalPreferences: PlaybackIntervalPreferenceStore?
    var sleepTimerPreferences: SleepTimerPreferenceStore?
    var queueInteractionPreferences: QueueInteractionPreferenceStore?
    var playbackQueuePreferences: PlaybackQueuePreferenceStore?
    var playbackHardwarePreferences: PlaybackHardwarePreferenceStore?
    /// "Set notification buttons" (User interface → External elements).
    var notificationButtonPreferences: NotificationButtonPreferenceStore?
    /// Settings search history (Android keeps it in its own "preferenceSearch" preferences file).
    var settingsSearchHistory: SettingsSearchHistoryStore?
    var proxyPreferences: ProxyPreferenceStore?
    var proxyNetwork: ProxyNetworkEnvironment?
    var transcriptLoader: TranscriptLoader?
    var chapterAccess: EpisodeChapterAccess?
    var playback: PlaybackCoordinator?
    var playbackRoutes: RoutedPlaybackEngine?
    var castRuntime: CastApplicationRuntime?
    private var sleepTimerFeedback: SleepTimerFeedbackRuntime?
    private(set) var playbackSystemControls: PlaybackSystemControlsRuntime?
    /// The Home Screen widget's and the Control Center control's App Group snapshot.
    private(set) var playerWidget: PlayerWidgetRuntime?
    var timeDisplayPreferences: TimeDisplayPreferenceStore?
    /// Theme, Full black and Use episode cover.
    var interfacePreferences: InterfacePreferenceStore?
    var shownotesScroll: ShownotesScrollStore?
    var speedPreferences: PlaybackSpeedPreferenceStore?
    var navigationPreferences: NavigationPreferenceStore?
    var mobileNetworkPreferences: MobileNetworkPreferenceStore?
    /// Remote transcripts, chapter lists and the Cast relay, by the Mobile updates options and the current network.
    var auxiliaryAdmission: AuxiliaryNetworkAdmission?
    /// What show notes may load by themselves: pictures, styles and fonts by "Cover images", media and frames by "Streaming".
    var shownotesNetwork: ShownotesNetworkPolicy?
    var usage: StreamDownloadUsageStore?
    var automaticDownloads: AutomaticDownloadCoordinator?
    var automaticDownloadPreferences: AutomaticDownloadPreferenceStore?
    var episodeNotifications: EpisodeNotificationDelivery?
    var synchronizationDelivery: SynchronizationDelivery?
    var synchronizationAccounts: SynchronizationAccounts?
    /// Settings → Notifications and the download-failure message/notification owner.
    var notificationPreferences: NotificationPreferenceStore?
    var downloadErrors: DownloadErrorDelivery?
    var downloadErrorEvents: Task<Void, Never>?
    /// A tapped "Episode download failed" notification waiting for a visible main screen.
    var pendingDownloadLog = false
    var nextcloudRestorationNamespace = "default"
    /// Application Support (or the UUID-isolated test library): device settings, `libraries.json`, and the standalone
    /// library's files.
    private(set) var libraryDirectory: URL?
    /// Whether a Keep waits, read from `libraries.json` only when the file changed (`keepIsPending`).
    var keepPendingProbe: KeepPendingProbe?
    /// The open library's files: the standalone library in `libraryDirectory`, a server library in its own folder.
    private(set) var libraryLocation: LibraryLocation?
    /// The account-level policies of the open library (PROTOCOL §15.4).
    var accountPolicy: AccountPolicy?
    /// Library switching (PROTOCOL §15.4): created at the first graph start, kept across graphs.
    private(set) var librarySwitch: LibrarySwitcher?
    /// The NotTennaPod server accounts (PROTOCOL §15.4): created at the first graph start, kept across graphs.
    var serverAccounts: ServerAccounts?
    /// The open server library's exchange (PROTOCOL §6.8): made at graph start, closed at graph stop.
    var serverSync: ServerSyncScheduler?
    /// The open server library's publication eligibility: moved on at every foreground transition.
    var serverPublicationEligibility: ServerPublicationEligibility?
    var serverSyncPlayback: Task<Void, Never>?
    /// The one owner of the open server library's deliveries of owed new-episode notifications (PROTOCOL §9.9).
    var serverReleaseDelivery: ServerReleaseDeliveryOwner?
    /// Server-sync background tasks running now: their exchange has time of its own.
    var serverSyncWindows: Set<UUID> = []
    /// When the app may be suspended, streaming relays close; the next demand reopens them.
    let streamingRelayEligibility = StreamingRelayEligibility()
    private var streamingRelayPlayback: Task<Void, Never>?
    private var librarySwitchEvents: Task<Void, Never>?
    /// Keep at logout (PROTOCOL §15.4): the last outcome a graph start or a runtime attempt reported, for the page's
    /// status row; and whether a runtime attempt just ran, so the restart that follows does not retry it at once.
    var keepOutcome: LibraryKeep.Outcome?
    var keepJustAttempted = false
    /// The chosen server library could not be found on this device, so this device's library opened:
    /// said once per occurrence, by the first screen of a started graph that a person can see.
    var missingLibraryNotice = MissingLibraryNotice()
    /// What interrupted database imports and exports became, kept until a person has seen it: shown by the
    /// first screen a person sees, after the missing-library message, and acknowledged once on screen.
    var pendingNotices: PendingNotices?
    /// Notices a screen of this process took (or the import's own dialog will show): not offered to another screen.
    private var noticesTaken: Set<UUID> = []
    /// The running or last database import's outcome, acknowledged when its result dialog appears.
    private var importOutcomeNotice: UUID?
    /// Manual exports' records, in this device's root folder.
    private(set) var exportAttempts: ExportAttemptJournal?
    /// A kept library's pinned removals finish when the player leaves their episode (PROTOCOL §15.4).
    var pinnedRemovalObservation: Task<Void, Never>?
    private var castSwitchObservation: CastChooserCancellation?
    var feedAuthentication: FeedAuthentication?
    var synchronization: SynchronizationCoordinator?
    var manualRefresh: ManualFeedRefreshCoordinator?
    var periodicRefresh: PeriodicFeedRefreshRuntime?
    var automaticBackup: AutomaticDatabaseExportRuntime?
    /// Download-log retention (source DatabaseMaintenanceWorker) and the background transfer router.
    var databaseMaintenance: DatabaseMaintenance?
    var downloadRouter: MediaDownloadRouter?
    /// Work that must finish before maintenance may run (a DEBUG journey's seeded history).
    private var maintenanceGate: Task<Void, Never>?
    /// Whether this library graph's background transfers were reconciled with its downloads.
    private var backgroundTransfersReconciled = false
    /// The app's one grant of background time and the work that holds it (`App/BackgroundWorkGrant.swift`).
    lazy var backgroundWork = makeBackgroundWorkGrant()
    var automaticBackupPreferences: AutomaticDatabaseExportPreferenceStore?
    var homePreferences: HomeSectionPreferenceStore?
    var episodeListPreferences: EpisodeListPreferenceStore?
    var subscriptionPreferences: SubscriptionDisplayPreferenceStore?
    var refreshDelivery: ManualFeedRefreshDelivery?
    private var refreshRecovery: Task<Void, Never>?
    private var restoreJournal: Task<Void, Never>?
    private var mobilePreferenceDelivery: Task<Void, Never>?
    var pendingNotification: EpisodeNotificationDestination?
    var pendingExternalRoute: ExternalEntry.Route?
#if DEBUG
    var removedEpisodeRefreshFixtureTask: Task<Void, Never>?
    /// The library switching journey's request when playback first plays.
    private var librarySwitchFixture: Task<Void, Never>?
#endif

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        for session in sceneSessions {
            try? NextcloudAuthenticationRestoration(sceneID: session.persistentIdentifier,
                namespace: nextcloudRestorationNamespace).clear()
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Streaming temp files left by a kill mid-playback; nothing in this process owns one yet.
        PlaybackTemporaryFiles.removeOrphaned()
#if DEBUG
        HubBridge.start(arguments: ProcessInfo.processInfo.arguments, app: self)
#endif
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: NativePeriodicRefreshScheduler.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else { task.setTaskCompleted(success: false); return }
                self.launchPeriodicRefresh(NativePeriodicRefreshLease(task))
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: NativeAutomaticBackupScheduler.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let runtime = self?.automaticBackup else { task.setTaskCompleted(success: false); return }
                runtime.launch(NativePeriodicRefreshLease(task))
            }
        }
        registerServerSyncBackgroundTasks()
        libraryStartup.start()
        // Reattach the background download session so transfers that finished or were interrupted while
        // the app was not running report to their jobs; their records name their libraries' current folders (PROTOCOL §15.4).
        BackgroundMediaDownloads.shared.activate()
        Task { await BackgroundMediaDownloads.shared.normalizeLiveTasks() }
        return true
    }

    /// The BGAppRefresh task's handler: granted time runs due maintenance (one small DELETE) and the periodic refresh.
    func launchPeriodicRefresh(_ lease: any PeriodicRefreshBackgroundLease) {
        guard let runtime = periodicRefresh else { lease.complete(success: false); return }
        runDatabaseMaintenance()
        runtime.launch(lease)
    }

    /// The system launched or woke the app because background downloads finished or need attention.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundMediaDownloads.shared.sessionIdentifier else { completionHandler(); return }
        let completion = UncheckedCompletion(completionHandler)
        BackgroundMediaDownloads.shared.handleEvents { completion.call() }
        if let downloads { Task { try? await downloads.start() } } else { startupHandoff.backgroundEvents = true }
        // The system woke the app with new time: a grant that ran out earlier no longer counts.
        if application.applicationState == .background { backgroundWork.enterBackground(freshTime: true) }
    }

    /// Source `DatabaseMaintenanceWorker.enqueueIfNeeded` from every `MainActivity.onCreate`, and its
    /// periodic run: here whenever the app starts, becomes active or gets background time.
    func runDatabaseMaintenance() {
        guard let databaseMaintenance else { return }
        let gate = maintenanceGate
        Task {
            await gate?.value
            do { try await databaseMaintenance.runIfDue() }
            catch { Logger(subsystem: "org.nottennapod.app", category: "Maintenance").error("Download log maintenance retained for retry") }
        }
    }

    /// Cancels background transfers that belong to no download of any library on this device (left
    /// from an earlier run, or from the library a database import replaced), so they cannot hold the
    /// per-host connections that new downloads need. Transfers of inactive libraries are kept (PROTOCOL §15.4).
    /// Runs once per library graph while the app is active: a system background launch carries no test library,
    /// and in the foreground the active downloads' own tasks are kept for their jobs to adopt.
    func reconcileBackgroundTransfers() {
        guard !backgroundTransfersReconciled, let library, let root = libraryDirectory, let active = libraryLocation?.reference else { return }
        backgroundTransfersReconciled = true
        Task { [weak self] in
            let log = Logger(subsystem: "org.nottennapod.app", category: "Downloads")
            do {
                // Not while a Keep at logout moves libraries (PROTOCOL §15.4): the gate is held exclusively then.
                await LibraryGate.shared.acquireShared()
                defer { LibraryGate.shared.releaseShared() }
                let cancelled = try await BackgroundMediaDownloads.shared.reconcile(ownership: {
                    try await Self.transferOwnership(library: library, root: root, active: active)
                })
                if cancelled > 0 { log.notice("Cancelled \(cancelled) background transfers that belong to no download") }
            } catch {
                log.error("Background transfer reconciliation retained for retry")
                if self?.library === library { self?.backgroundTransfersReconciled = false }
            }
        }
    }

    /// The active library's download destinations and every other library's, read off the main actor.
    nonisolated private static func transferOwnership(library: FeedLibraryStore, root: URL,
                                                      active: LibraryReference) async throws -> BackgroundTransferOwnership {
        let destinations = try await library.downloadJobs(activeOnly: true).map(\.destination)
        return LibraryTransferOwnership.collect(root: root, active: active, activeDestinations: destinations)
    }

    /// The library this graph start opens: a recorded switch is applied first (nothing can be playing before a
    /// library opens). Without a registry, or if its content is damaged, the standalone library opens; a registry or
    /// library folder that cannot be read now (before the first unlock) is thrown, so the start waits for it.
    private func openingLibrary(root: URL) throws -> LibraryGraphStart.Opening {
        let registry = LibraryRegistryFile(root: root)
        if librarySwitch == nil {
            // The activation rule (PROTOCOL §15.4), only in the foreground: background work never starts a switch.
            librarySwitch = LibrarySwitcher(registry: registry, activation: { [weak self] in
                LibraryActivationState(self?.playback, castBlocks: self?.castRuntime?.blocksLibrarySwitch ?? false)
            }, allowed: { UIApplication.shared.applicationState != .background },
               settle: { [weak self] in await self?.playback?.settle() },
               retire: { [weak self] in self?.retireLibraryGraph() },
               restart: { [weak self] in await self?.switchLibraryGraph() })
            // A Keep at logout waits for the same rule (PROTOCOL §15.4).
            librarySwitch?.keepPending = { [weak self] in self?.keepIsPending ?? false }
            librarySwitch?.runKeep = { [weak self] in await self?.runPendingKeep() }
            // The page names the playback a waiting switch or Keep waits for.
            librarySwitch?.onPlaybackHoldChange = { [weak self] in self?.serverAccounts?.pageChanged() }
        }
        let log = Logger(subsystem: "org.nottennapod.app", category: "Libraries")
        // What cannot be read now is thrown (`LibraryGraphStart.openingLibrary`), so the start waits for it.
        let opening = try LibraryGraphStart.openingLibrary(root: root, keep: libraryKeep(root: root))
        if opening.location.converted != nil {
            // A committed Keep that could not publish yet: its converted library opens where it is.
            log.notice("Keeping this library has not finished; the converted library opens where it is")
        }
        switch opening.fallback {
        case .registryDamaged?: log.error("Library registry unreadable; the standalone library opens")
        case .folderMissing?: log.error("Active library folder missing; the standalone library opens")
        case .databaseMissing?: log.error("Active library database missing; the standalone library opens")
        case nil: break
        }
        librarySwitch?.opened(opening.location.reference)
        return opening
    }

    /// A recorded switch whose activation rule holds: the database import's commit, minus the file replacement.
    private func switchLibraryGraph() async {
        // Leaving a server library ends the player's hold of an episode cut loose from the account (PROTOCOL §6.8): once
        // the player is retired, its rows and files go, nothing recorded.
        retireLibraryGraph()
        await playback?.retire().value
        if let library, (try? await library.releaseDetachedEpisodes()) == true {
            try? await feedDeletion?.resume().value
        }
        await stopLibraryGraph()
        restartLibraryGraph()
    }

    /// Builds every library-bound owner. Runs at launch, after a database import in place of Android's process
    /// restart (iOS cannot relaunch itself), and for a library switch, always through `libraryStartup`, which retires
    /// and discards what a failed start built and tries it again.
    func startLibraryGraph(restart: Bool) throws {
        startupError = nil
        backgroundTransfersReconciled = false
        var unreadablePreferences: Error?
        do {
            var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var mutedPlayback = false
#if DEBUG
            let arguments = OPMLJourneyFixture.arguments(ProcessInfo.processInfo.arguments)
            var preparesRemovedEpisodeFixture = false
            var startRemovedEpisodePeriodicRefresh: (() -> Void)?
            var testMissingMediaURL: URL?
            var testRestrictedStreaming = false
            mutedPlayback = arguments.contains("-test-muted-playback")
            if let index = arguments.firstIndex(of: "-test-library-id"), index + 1 < arguments.count,
               let identifier = UUID(uuidString: arguments[index + 1]) {
                directory.appendPathComponent("UITests-" + identifier.uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                preparesRemovedEpisodeFixture = !restart && arguments.contains("-test-removed-episode-refresh")
                testRestrictedStreaming = arguments.contains("-test-restricted-streaming")
                if arguments.contains("-test-missing-local-media") {
                    // Exercise a real AVPlayer file error without deleting fixture/user media.
                    testMissingMediaURL = directory.appendingPathComponent("missing-\(UUID().uuidString).media")
                }
            }
#endif
            libraryDirectory = directory
#if DEBUG
            if !restart {
                try SeededLibraryFixtures.prepare(root: directory, arguments: arguments)
                try LibrarySwitchJourneyFixture.prepare(root: directory, arguments: arguments)
            }
#endif
            // Before any library is migrated, moved by a Keep or opened: an import the system ended is completed or
            // rolled back, and its outcome kept until a person sees it. Evidence that cannot be read now makes the start
            // wait, so nothing moves the imported library before its import is decided.
            let notices = PendingNotices(root: directory)
            pendingNotices = notices
            try DatabaseImportRecovery.recover(root: directory, vault: KeychainSynchronizationCredentials(service: "org.nottennapod.app.feeds"),
                                               notices: notices)
            // An export the system ended, or whose failure nobody saw.
            let exports = ExportAttemptJournal(root: directory)
            exportAttempts = exports
            exports.recover(notices: notices)
            // Before any library opens (PROTOCOL §15.4 "Recovery comes first"): every library at schema 20, then an unfinished
            // Keep at logout finished as far as it can be (not again right after a runtime attempt that just failed).
            LibraryGraphStart.migrateLibraries(root: directory, gate: LibraryGate.shared)
            if !keepJustAttempted, let result = try LibraryGraphStart.finishKeep(libraryKeep(root: directory), gate: LibraryGate.shared) {
                keepOutcome = result.outcome
                Logger(subsystem: "org.nottennapod.app", category: "Libraries").notice("Keep at logout: \(String(describing: result.outcome), privacy: .public)")
            }
            keepJustAttempted = false
            LibraryGraphStart.recordStandaloneIdentity(root: directory)
            // A server library restored onto this device from another's backup is a copy: before it opens, it forks its
            // authors and takes a new installation (PROTOCOL §6.10). A locked Keychain leaves it to the exchange.
            LibraryGraphStart.detectCopies(root: directory, secrets: KeychainServerSecrets(markerAccount: Self.serverMarkerAccount(directory)),
                                           gate: LibraryGate.shared)
            let opening = try openingLibrary(root: directory), location = opening.location
            libraryLocation = location
            // A damaged settings file is set aside and its group starts from the defaults; the error is still shown once.
            // One that cannot be read now (before the first unlock) is thrown and the start waits for it.
            func settingsFile<Store>(_ name: String, _ open: (URL) throws -> Store) throws -> Store {
                try UnreadableSettingsFile.open(directory.appendingPathComponent(name), open) { error in
                    Logger(subsystem: "org.nottennapod.app", category: "Preferences").error("Set aside unreadable \(name, privacy: .public)")
                    if unreadablePreferences == nil { unreadablePreferences = error }
                }
            }
            let proxyPreferences = try ProxyPreferenceStore(persistence: KeychainProxyPreferences(account:
                directory.lastPathComponent.hasPrefix("UITests-") ? directory.lastPathComponent : "default"))
            let proxyNetwork = ProxyNetworkEnvironment(configuration: proxyPreferences.value)
            proxyPreferences.onChange = { [weak proxyNetwork] value, reinitialize in
                proxyNetwork?.update(value, reinitializeShared: reinitialize)
            }
            self.proxyPreferences = proxyPreferences; self.proxyNetwork = proxyNetwork
            nextcloudRestorationNamespace = directory.lastPathComponent.hasPrefix("UITests-") ? directory.lastPathComponent : "default"
            statisticsPreferences = try settingsFile("statistics-preferences.json") { try StatisticsPreferenceStore(file: $0) }
            discoveryPreferences = try settingsFile("discovery-preferences.json") { try DiscoveryPreferenceStore(file: $0) }
            // An interrupted import's library returns first; when it cannot yet, the start waits and its database is
            // never created empty in its place.
            try LibraryReplacement.recoverInterrupted(live: location.database)
#if DEBUG
            // UI tests: a UUID test library may start as a given Android database (through the database import),
            // installed once before the library opens. The path is supplied by the test runner.
            if !restart, directory.lastPathComponent.hasPrefix("UITests-"),
               let index = arguments.firstIndex(of: "-test-seed-android-database"), index + 1 < arguments.count {
                try Self.seedAndroidDatabase(URL(fileURLWithPath: arguments[index + 1]), library: location.database)
                if arguments.contains("-test-seed-android-downloads") {
                    try StatisticsTabsJourneyFixture.markDownloads(from: URL(fileURLWithPath: arguments[index + 1]), directory: location.folder)
                }
            }
#endif
            let store = try FeedLibraryStore(url: location.database, ownedRoot: location.ownedRoot)
            library = store
            // A library migrated to schema 21 with episodes fills its derived list keys in short background batches, once.
            if !store.derivedReady {
                Task.detached(priority: .utility) {
                    try? await store.fillDerivedData(onFailure: { error in
                        Logger(subsystem: "org.nottennapod.app", category: "Library").error("List data fill failed, retrying: \(String(describing: error), privacy: .public)")
                    })
                }
            }
            // Once the library's own files could be read: accounts created while protected data was unavailable would
            // keep an empty registry and token-removal list for the process.
            startServerAccounts(root: directory)
            Task { try? await store.replayOwedFacts() } // A server library's owed facts; nothing in standalone.
            let feedAuthentication = FeedAuthentication(store: store, gate: LibraryGate.shared)
            // Background transfers name this library and resolve every owned path onto its current folder (PROTOCOL §15.4).
            let identity = store.identityAtOpen
            BackgroundMediaDownloads.shared.setLibrary(identity: identity?.identity, media: location.media)
            let routingRoot = directory
            BackgroundMediaDownloads.shared.setResolver { destination, library in
                LibraryTransferRouting.resolve(destination, library: library, root: routingRoot)
            }
            self.feedAuthentication = feedAuthentication
            let notificationPreferences = try settingsFile("notification-preferences.json") { try NotificationPreferenceStore(file: $0) }
            self.notificationPreferences = notificationPreferences
            synchronizationDelivery = SynchronizationDelivery(store: store, publisher: NativeSynchronizationNotifications(),
                text: .init(errorTitle: Appearance.text("gpodnetsync_error_title"), errorPrefix: Appearance.text("gpodnetsync_error_descr")),
                foreground: { message in
                    for scene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
                        guard let windowScene = scene as? UIWindowScene else { continue }
                        for window in windowScene.windows where window.isKeyWindow {
                            if let controller = window.rootViewController as? LibraryViewController,
                               controller.showSnackbar(message) { return true }
                        }
                    }
                    return false
                }, notificationsEnabled: { [weak notificationPreferences] account in
                    notificationPreferences?.value.synchronizationFailedEnabled(account: account) ?? true
                }, episodesChanged: { _ in
                    for scene in UIApplication.shared.connectedScenes {
                        guard let windowScene = scene as? UIWindowScene else { continue }
                        for window in windowScene.windows {
                            // A screen kept by change sets follows these changes by itself.
                            if let controller = window.rootViewController as? LibraryViewController, controller.screenUpdater == nil {
                                await controller.reloadLibrary(preservingEpisodeDetails: true)?.value
                            }
                        }
                    }
                })
            episodeNotifications = EpisodeNotificationDelivery(store: store, publisher: NativeEpisodeNotifications(),
                text: NewEpisodeNotificationContent.text,
                artwork: { try await NewEpisodeNotificationContent.artwork($0, store: store) })
            navigationPreferences = try settingsFile("navigation-preferences.json") { try NavigationPreferenceStore(file: $0) }
            do { usage = try StreamDownloadUsageStore(file: directory.appendingPathComponent("stream-download-usage.json")) }
            catch { Logger(subsystem: "org.nottennapod.app", category: "Usage").error("Unable to load local usage history") }
#if DEBUG
            // Seed only an explicitly UUID-isolated test library, once. The eighth
            // action and all suggestion handling still run through visible controls.
            if directory.lastPathComponent.hasPrefix("UITests-"), let usage,
               usage.value.streamExecutions == 0, usage.value.downloadExecutions == 0,
               let index = arguments.firstIndex(of: "-test-usage-history"), index + 1 < arguments.count,
               ["stream", "download"].contains(arguments[index + 1]) {
                let download = arguments[index + 1] == "download"
                for _ in 0..<7 { try usage.log(download ? .download : .stream) }
                if download, let navigationPreferences {
                    var preferences = navigationPreferences.value
                    preferences.streamOverDownload = true
                    try navigationPreferences.update(preferences)
                }
            }
#endif
            intervalPreferences = try settingsFile("playback-intervals.json") { try PlaybackIntervalPreferenceStore(file: $0) }
            playbackHardwarePreferences = try settingsFile("playback-hardware.json") { try PlaybackHardwarePreferenceStore(file: $0) }
            notificationButtonPreferences = try settingsFile("notification-buttons.json") { try NotificationButtonPreferenceStore(file: $0) }
            settingsSearchHistory = try SettingsSearchHistoryStore(file: directory.appendingPathComponent("settings-search-history.json"))
            let sleepTimerPreferences = try settingsFile("sleep-timer.json") { try SleepTimerPreferenceStore(file: $0) }
            self.sleepTimerPreferences = sleepTimerPreferences
            let playbackQueuePreferences = try settingsFile("playback-queue.json") { try PlaybackQueuePreferenceStore(file: $0) }
            self.playbackQueuePreferences = playbackQueuePreferences
            queueInteractionPreferences = try settingsFile("queue-interaction.json") { try QueueInteractionPreferenceStore(file: $0) }
            timeDisplayPreferences = try settingsFile("time-display-preferences.json") { try TimeDisplayPreferenceStore(file: $0) }
            interfacePreferences = try settingsFile("interface-preferences.json") { try InterfacePreferenceStore(file: $0) }
            // Speeds and the shownotes position keyed by this library's IDs (PROTOCOL §15.4): the standalone library keeps
            // today's files; a server library its own playback-library.json beside its database.
            let playbackLibrary = try location.playbackLibraryFile.map { file in
                try UnreadableSettingsFile.open(file, { try PlaybackLibraryFile(url: $0) }) { error in
                    Logger(subsystem: "org.nottennapod.app", category: "Preferences").error("Set aside unreadable playback-library.json")
                    if unreadablePreferences == nil { unreadablePreferences = error }
                }
            }
            if let playbackLibrary { shownotesScroll = ShownotesScrollStore(library: playbackLibrary) }
            else { shownotesScroll = try settingsFile("shownotes-scroll.json") { try ShownotesScrollStore(file: $0) } }
            let speedPreferences = try settingsFile("playback-speed-preferences.json") {
                try PlaybackSpeedPreferenceStore(file: $0, library: playbackLibrary)
            }
            self.speedPreferences = speedPreferences
            restoreJournal = Task { [weak self] in await self?.applyRestoreJournal(store: store) }
            // Preferences outside the library (survive a database import, like SharedPreferences).
            let backupPreferences = try settingsFile("automatic-database-export.json") { try AutomaticDatabaseExportPreferenceStore(file: $0) }
            automaticBackupPreferences = backupPreferences
            homePreferences = try settingsFile("home-preferences.json") { try HomeSectionPreferenceStore(file: $0) }
            subscriptionPreferences = try SubscriptionDisplayPreferenceStore(file: directory.appendingPathComponent("subscription-display-preferences.json"))
            episodeListPreferences = try EpisodeListPreferenceStore(file: directory.appendingPathComponent("episode-list-preferences.json"))
            var backupClock: () -> Date = { Date() }
#if DEBUG
            // UI tests shift only the backup runtime's clock to reach a due backup; no system setting changes.
            if directory.lastPathComponent.hasPrefix("UITests-"), let index = arguments.firstIndex(of: "-test-auto-backup-now-offset-days"),
               index + 1 < arguments.count, let days = Double(arguments[index + 1]) {
                backupClock = { Date().addingTimeInterval(days * 86_400) }
            }
            // The removed-folder journey deletes the chosen export folder, as a user would in Files.
            if directory.lastPathComponent.hasPrefix("UITests-"), arguments.contains("-test-auto-backup-remove-folder"),
               let bookmark = backupPreferences.value.bookmark {
                var stale = false
                if let folder = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    let scoped = folder.startAccessingSecurityScopedResource()
                    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                    try? FileManager.default.removeItem(at: folder)
                }
            }
#endif
            let backupVault = feedAuthentication.credentialStore, backupRoot = directory
            automaticBackup = AutomaticDatabaseExportRuntime(preferences: backupPreferences, clock: backupClock, grant: backgroundWork, payload: { [weak self] in
                // The active library, through the same source and gate as the manual exports (PROTOCOL §11.5); unattended,
                // so it never asks which library.
                guard let identity = store.identityAtOpen?.identity else { throw LibraryExportError.libraryNotFound }
                let source = try await LibraryExport.collect(identity: identity, root: backupRoot,
                    current: { self?.exportOpenLibrary() }, vault: backupVault, gate: .shared)
                return try source.databaseData()
            }, report: { [weak self] message in self?.reportAutomaticBackupError(message) })
#if DEBUG
            if directory.lastPathComponent.hasPrefix("UITests-") {
                automaticBackup?.onOutcome = { outcome in
                    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                        // Cumulative so a later "scheduled" never hides an earlier result.
                        for window in scene.windows {
                            window.accessibilityLabel = (window.accessibilityLabel.map { $0 + " | " } ?? "automaticBackup: ") + outcome
                        }
                    }
                }
            }
#endif
            let mobilePreferences = try settingsFile("mobile-network-preferences.json") { try MobileNetworkPreferenceStore(file: $0) }
            mobileNetworkPreferences = mobilePreferences
            let auxiliaryAdmission = AuxiliaryNetworkAdmission(preferences: mobilePreferences,
                onceAdmittedEpisodeID: { [weak self] in self?.playback?.onceAdmittedEpisodeID })
            self.auxiliaryAdmission = auxiliaryAdmission
            let shownotesNetwork = ShownotesNetworkPolicy(preferences: mobilePreferences)
            self.shownotesNetwork = shownotesNetwork
            let imageAccess = MobileImageAccess(preferences: mobilePreferences, proxyConfiguration: { proxyNetwork.newClientConfiguration() })
            EpisodeArtworkView.remoteLoader = { try await imageAccess.load($0) }
            ArtworkImageCache.fetchAllowance = { try await imageAccess.fetchAllowance() }
            ArtworkImageCache.unrestrictedNetwork = { try await imageAccess.waitUntilUnrestricted() }
            mobilePreferences.onChange = { [weak self, weak mobilePreferences] in
                guard let self, let mobilePreferences else { return }
                auxiliaryAdmission.preferencesChanged()
                shownotesNetwork.preferencesChanged()
                self.restartPeriodicRefresh(replace: true)
                // A server library's sync follows the "Synchronization" mobile-data choice at once.
                self.serverSync?.networkPolicyChanged()
                let previous = mobilePreferenceDelivery, allowSync = mobilePreferences.allows(.sync)
                mobilePreferenceDelivery = Task {
                    await previous?.value
                    do { try await store.setSynchronizationMobileAllowed(allowSync) }
                    catch { Logger(subsystem: "org.nottennapod.app", category: "Preferences").error("Mobile sync preference delivery failed") }
                }
            }
            mobilePreferences.onChange?()
            let streaming = StreamingAccessProvider(preferences: mobilePreferences)
            let preferences = try settingsFile("download-preferences.json") { try DownloadPreferenceStore(file: $0) }
            downloadPreferences = preferences
            // The global new-episodes action, enqueue location and Keep sorted: the standalone library's are today's
            // preference values; a server library's are its account's (PROTOCOL §15.4).
            let accountPolicy: AccountPolicy
            if location.reference == .standalone {
                accountPolicy = .standalone(download: preferences, queue: queueInteractionPreferences)
            } else if let file = location.accountPoliciesFile {
                // A converted library before its Keep is published keeps its policies in its own file (PROTOCOL §15.4).
                accountPolicy = AccountPolicy(backing: FileAccountPolicy(file: file))
            } else if let values = ServerAccountPolicyValues.read(database: location.database) {
                // The account's records with this library's pending changes; changes are recorded as facts.
                accountPolicy = AccountPolicy(backing: ServerAccountPolicyBacking(store: store, values: values))
            } else {
                accountPolicy = .awaitingAccountRecords()
            }
            self.accountPolicy = accountPolicy
            // Enqueue location and Keep sorted apply to every addition, from launch on.
            store.setQueueInsertionSettings(accountPolicy.queueInsertionSettings())
            inboxSwipePreferences = try settingsFile("inbox-swipe-preferences.json") { try SwipePreferenceStore(file: $0) }
            allEpisodesFilterPreferences = try settingsFile("all-episodes-filter.json") { try AllEpisodesFilterPreferenceStore(file: $0) }
            preferences.onRefreshIntervalChange = { [weak self] in self?.restartPeriodicRefresh(replace: true) }
            let routes = RoutedPlaybackEngine(local: ApplicationPlaybackEngine(muted: mutedPlayback, source: { episode in
                let url = try AVPlayerPlaybackEngine.mediaURL(episode)
#if DEBUG
                if url.isFileURL, let testMissingMediaURL { return testMissingMediaURL }
#endif
                return url
            }, localAccess: LocalPlaybackAccess(store: store), credentials: { episode in
                try await feedAuthentication.credentials(feedID: store.feedID(forEpisode: episode.id))
            }, urlResolver: PlaybackURLResolver(transport: proxyNetwork, userAgent: HTTPUserAgent.current),
                proxyClient: { proxyNetwork.sharedClient() }, userAgent: HTTPUserAgent.current,
                cacheDirectory: location.streamingCache,
                pauseOnDisconnect: { [weak hardware = playbackHardwarePreferences] in hardware?.value.pauseOnDisconnect ?? true }))
            playbackRoutes = routes
            playback = PlaybackCoordinator(store: store, engine: routes, preferences: { _ in
                var value = PlaybackApplicationPreferences.resolve(download: preferences.value, queue: playbackQueuePreferences.value)
                value.enqueueLocation = accountPolicy.enqueueLocation
                return value
            }, speedPreferences: speedPreferences, sleepTimerPreferences: sleepTimerPreferences, skipPreferences: { episode in
                try await store.skipPreferences(forEpisode: episode.id)
            }, streamingAccess: { episode in
#if DEBUG
                // Supply cellular facts only for a UUID-isolated UI-test library.
                // The real policy, preferences, coordinator and HTTP player still run.
                if testRestrictedStreaming, StreamingAccessProvider.needsStreaming(episode) {
                    return .init(needsStreaming: true, streamingAllowed: mobilePreferences.allows(.streaming), isCasting: routes.isRemote)
                }
#endif
                var access = try await streaming.access(for: episode)
                access.isCasting = routes.isRemote
                return access
            }, completionEffects: { [weak self] in
                try await self?.downloads?.completePlaybackFileEffects()
            })
            var enablesCast = true
#if DEBUG
            // Native/UI test libraries opt in explicitly to SDK session state.
            enablesCast = !directory.lastPathComponent.hasPrefix("UITests-") || arguments.contains("-test-cast-enabled")
#endif
            if enablesCast, let playback {
                // The library's Cast tag (PROTOCOL §15.4 "Cast"): a server library's ID, which a library kept from it keeps.
                let castIdentity = identity?.castLibrary ?? .standalone
                // A public enclosure is cast by its own URL; a relay through the phone needs the streaming admission.
                let access = CastMediaAccessOwner(store: store, authentication: feedAuthentication,
                    network: proxyNetwork, userAgent: HTTPUserAgent.current, library: castIdentity,
                    admission: auxiliaryAdmission)
                let castSession: any CastApplicationSession
                #if DEBUG
                if directory.lastPathComponent.hasPrefix("UITests-"), arguments.contains("-test-cast-group") {
                    castSession = CastGroupTestSession()
                } else {
                    let google = GoogleCastApplicationSession()
                    google.testingEmptyDiscovery = directory.lastPathComponent.hasPrefix("UITests-") && arguments.contains("-test-cast-empty-discovery")
                    castSession = google
                }
                #else
                castSession = GoogleCastApplicationSession()
                #endif
                // The Google Cast SDK starts at the first Cast tap, or at launch to resume a session.
                let runtime = CastApplicationRuntime(session: castSession, player: playback,
                    routes: routes, media: access, memory: castSession is GoogleCastApplicationSession ? .defaults() : .init())
                castRuntime = runtime; runtime.start()
            }
            let feedback = SleepTimerFeedbackRuntime { [weak playback] in try await playback?.resetSleepTimerAfterShake() }
            sleepTimerFeedback = feedback
            playback?.onSleepTimerFeedback = { [weak feedback] event in feedback?.receive(event) }
            // A large sync publication is not admitted against a Play, from the step the Play is admitted (PROTOCOL §6.8).
            playback?.onPlaybackRequested = { [weak self] in self?.serverPublicationEligibility?.changed() }
            if let playback, let intervalPreferences, let playbackHardwarePreferences {
                let controls = PlaybackSystemControlsRuntime(playback: playback, library: store,
                    intervals: intervalPreferences, hardware: playbackHardwarePreferences, remote: { [weak routes] in routes?.isRemote == true },
                    buttons: notificationButtonPreferences,
                    presets: { [weak speedPreferences] in speedPreferences?.value.presets ?? PlaybackSpeedPreferences().presets })
                playbackSystemControls = controls
                controls.start()
            }
            // What the widget and the control show, and their buttons on this player.
            if let playback, let widgetStore = PlayerWidgetStore.appGroup() {
                let widget = PlayerWidgetRuntime(playback: playback, library: store, store: widgetStore,
                    timeDisplay: { [weak self] in self?.timeDisplayPreferences?.value ?? .init() })
                playerWidget = widget
                // After a database import's restored feed speeds are in place, so the restored episode's speed is right.
                let journal = restoreJournal
                Task { [weak widget] in await journal?.value; widget?.start() }
            }
            // Run in order through the startup owner's dispatcher (`orderedWidgetRouter`).
            startupHandoff.widgetCommands = PlayerWidgetIntentRouter.bound(playback: { [weak self] in self?.playback },
                                          intervals: { [weak self] in self?.intervalPreferences?.value ?? .init() },
                                          widget: { [weak self] in self?.playerWidget })
            let transcriptLoader = TranscriptLoader(transport: proxyNetwork,
                cache: URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 40 * 1024 * 1024,
                    diskPath: directory.appendingPathComponent("transcript-cache").path), userAgent: HTTPUserAgent.current,
                admission: auxiliaryAdmission)
            self.transcriptLoader = transcriptLoader
            chapterAccess = EpisodeChapterAccess(store: store,
                loader: EpisodeChapterLoader(transport: proxyNetwork,
                    cache: URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 40 * 1024 * 1024,
                        diskPath: directory.appendingPathComponent("chapter-cache").path), userAgent: HTTPUserAgent.current,
                    admission: auxiliaryAdmission),
                proxy: { proxyNetwork.sharedConfiguration() },
                credentials: { try await feedAuthentication.credentials(feedID: $0) }, userAgent: HTTPUserAgent.current)
            let router = MediaDownloadRouter(
                foreground: MediaDownloadTransfer(userAgent: HTTPUserAgent.current, proxyClient: { proxyNetwork.sharedClient() }),
                background: BackgroundMediaDownloads.shared, userAgent: HTTPUserAgent.current,
                proxyConfigured: { proxyNetwork.sharedConfiguration().isConfigured })
            downloadRouter = router
            downloads = DownloadCoordinator(store: store, directory: location.media,
                                             transfer: router,
                                             transcriptLoader: transcriptLoader, preferences: {
                                                 var value = preferences.value; value.allowMobile = mobilePreferences.allows(.episodeDownload)
                                                 value.enqueueLocation = accountPolicy.enqueueLocation
                                                 return value
                                             }, credentials: { episodeID in
                                                 try await feedAuthentication.credentials(feedID: store.feedID(forEpisode: episodeID))
                                             })
            if let downloads { startDownloadErrorDelivery(downloads, directory: directory) }
            let automaticPreferences = try settingsFile("automatic-download-preferences.json") { try AutomaticDownloadPreferenceStore(file: $0) }
            automaticDownloadPreferences = automaticPreferences
            if let playback, let downloads {
                automaticDownloads = AutomaticDownloadCoordinator(store: store, preferences: { automaticPreferences.value },
                    environment: {
                        let network = try await DownloadNetworkMonitor.shared.observedState()
                        UIDevice.current.isBatteryMonitoringEnabled = true
                        let battery = UIDevice.current.batteryState
                        return .init(connection: network.automaticDownloadConnection,
                            allowMobile: mobilePreferences.allows(.autoDownload), charging: battery == .charging || battery == .full)
                    }, cleanup: { episode in try await downloads.deleteDownloadedMedia(episodeID: episode.id, playback: playback) },
                    download: { try await downloads.requestAutomatic(episodeID: $0) })
                automaticDownloads?.onChange = { state in
                    if case .failed = state {
                        Logger(subsystem: "org.nottennapod.app", category: "AutomaticDownload").error("Automatic download selection failed; request retained for retry")
                    }
                }
                automaticDownloads?.resume()
                feedDeletion = FeedDeletionCoordinator(store: store,
                    retirePlayback: { try await playback.retireDeletedEpisodes($0) },
                    retireDownloads: { try await downloads.retireDeletedJobs($0) }, cleanupCredentials: {
                        do { try await feedAuthentication.recoverCredentialCleanup() }
                        catch { Logger(subsystem: "org.nottennapod.app", category: "Feeds").error("Credential cleanup retained for retry") }
                    })
                feedDeletion?.onChange = {
                    for controller in Self.libraryControllers {
                        _ = controller.reloadLibrary(preservingEpisodeDetails: true)
                    }
                }
            }
            if let feedDeletion, let automaticDownloads, let episodeNotifications, let synchronizationDelivery {
                // Screens kept by change sets patch the refresh's commits themselves: the refresh never waits for them.
                let reloads = LibraryReloadCoalescer {
                    for controller in Self.libraryControllers where controller.screenUpdater == nil {
                        await controller.reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true)?.value
                    }
                }
                let delivery = ManualFeedRefreshDelivery(store: store, deletion: feedDeletion,
                    notifications: episodeNotifications, automaticDownloads: automaticDownloads,
                    allowMobileSync: { mobilePreferences.allows(.sync) },
                    libraryChanged: { await reloads.requestAndWait() }, feedRefreshed: { reloads.request() },
                    consumeQueueEffects: {
                        try await feedDeletion.resume().value
                        _ = try await store.consumeFeedRefreshQueueEffects(location: accountPolicy.enqueueLocation)
                    })
                refreshDelivery = delivery
                let worker = FeedRefreshWorker(store: store,
                    remote: FeedRefreshService(store: store, fetcher: FeedFetcher(transport: proxyNetwork, userAgent: HTTPUserAgent.current)),
                    local: LocalFeedRefreshService(store: store),
                    localDescription: Appearance.text("local_feed_description"), localAuthor: Appearance.text("local_folder"),
                    credentials: { try await feedAuthentication.credentials(feedID: $0) }, options: { _ in
                        await MainActor.run {
                            var options = FeedRefreshOptions()
                            options.globalAutoDownload = automaticPreferences.value.global
                            options.globalNewEpisodesAction = accountPolicy.newEpisodesAction
                            return options
                        }
                    }, effects: delivery)
                let refresh = ManualFeedRefreshCoordinator(store: store, worker: worker)
                manualRefresh = refresh
                let scheduled = PeriodicFeedRefreshCoordinator(store: store, worker: worker)
                scheduled.onEnd = { [weak delivery] in delivery?.clear(requestID: $0) }
                let runtime = PeriodicFeedRefreshRuntime(owner: scheduled)
                runtime.onFailure = { error in
                    let failure = error as NSError
                    Logger(subsystem: "org.nottennapod.app", category: "Refresh").error("Periodic refresh retained for retry: \(failure.domain, privacy: .public) code \(failure.code)")
                }
#if DEBUG
                if preparesRemovedEpisodeFixture {
                    // The opt-in fixture must commit its scan/queue/manifest before
                    // the real startup scheduler may supersede that initial scan.
                    startRemovedEpisodePeriodicRefresh = { [weak self] in
                        guard let self else { return }
                        periodicRefresh = runtime
                        restartPeriodicRefresh(replace: false)
                        runtime.setForeground(UIApplication.shared.connectedScenes.contains {
                            $0.activationState == .foregroundActive
                        })
                    }
                } else {
                    periodicRefresh = runtime
                    restartPeriodicRefresh(replace: false)
                }
#else
                periodicRefresh = runtime
                restartPeriodicRefresh(replace: false)
#endif
                delivery.onChange = { _ in
                    for controller in Self.libraryControllers { controller.refreshProgressChanged() }
                }
                var previousManualID: UUID?
                refresh.onChange = { [weak self, weak delivery] state in
                    if let delivery, let progress = delivery.progress, progress.requestID == previousManualID {
                        if case .active(let request) = state, request.id == progress.requestID { }
                        else { delivery.clear(requestID: progress.requestID) }
                    }
                    if case .active(let request) = state { previousManualID = request.id } else { previousManualID = nil }
                    for controller in Self.libraryControllers { controller.refreshStateChanged(state) }
                    // A refresh that starts in the background joins the grant, or parks when there is no time.
                    if case .active = state { self?.backgroundWork.workStarted() }
                }
                let accounts = SynchronizationAccounts(store: store, userAgent: HTTPUserAgent.current, makeTransport: {
                    let proxy = proxyNetwork.sharedConfiguration()
                    return proxy.isConfigured ? try ProxySynchronizationTransport(proxy: proxy) : URLSessionSynchronizationTransport()
                })
                synchronizationAccounts = accounts
                synchronization = SynchronizationCoordinator(store: store, worker: SynchronizationWorker(store: store,
                    subscriptions: SynchronizationSubscriptions(store: store, deletion: feedDeletion,
                        redirects: SynchronizationRedirectChecker(transport: proxyNetwork, userAgent: HTTPUserAgent.current)),
                    refresh: refresh,
                    provider: { try await accounts.provider(accountID: $0) }, effects: synchronizationDelivery,
                    smartMarkAsPlayedSeconds: { await preferences.value.smartMarkAsPlayedSeconds ?? 30 }), delivery: synchronizationDelivery)
                resumeRefreshServices()
            }
            automaticBackup?.resume()
            var maintenanceClock: @Sendable () -> Date = { Date() }
#if DEBUG
            if directory.lastPathComponent.hasPrefix("UITests-") {
                if let index = arguments.firstIndex(of: "-test-maintenance-clock-offset-hours"), index + 1 < arguments.count,
                   let hours = Double(arguments[index + 1]) {
                    maintenanceClock = { Date().addingTimeInterval(hours * 3600) }
                }
            }
#endif
            let maintenance = DatabaseMaintenance(store: store, file: directory.appendingPathComponent("database-maintenance.json"),
                                                  clock: maintenanceClock)
            databaseMaintenance = maintenance
#if DEBUG
            if !restart, directory.lastPathComponent.hasPrefix("UITests-"), arguments.contains("-test-download-log-history") {
                // The seeded history must exist before any maintenance looks at it.
                maintenanceGate = Task {
                    do { try await BackgroundWorkFixture.seedDownloadLog(store: store, directory: location.folder) }
                    catch {
                        Logger(subsystem: "org.nottennapod.app", category: "TestFixture")
                            .error("Download log fixture failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
#endif
            runDatabaseMaintenance()
            // A recorded switch is re-checked after every player state change and Cast connection change.
            if let playback { librarySwitchEvents = librarySwitch?.observe(playback) }
            observeStreamingRelayEligibility()
            // A server library's exchange runs whether or not the Synchronization page is open.
            startServerSync(store: store, location: location)
            finishPinnedRemovals(store: store)
            castSwitchObservation = castRuntime?.observe({ [weak self] _ in
                self?.librarySwitch?.attemptSoon()
                // The page names Cast as what the switch or the Keep waits for (PROTOCOL §15.5).
                self?.serverAccounts?.pageChanged()
            }, problem: { _ in })
#if DEBUG
            // Library switching journey: once playback plays, a switch to the kept server library is requested; it
            // waits for the activation rule. Windows carry the request for the runner.
            if !restart, directory.lastPathComponent.hasPrefix("UITests-"), arguments.contains("-test-switch-library-when-playing"),
               location.reference == .standalone, let playback {
                let events = playback.events()
                librarySwitchFixture = Task { [weak self, weak playback] in
                    for await _ in events where playback?.phase == .playing {
                        try? await self?.librarySwitch?.request(.server(LibrarySwitchJourneyFixture.libraryID), reason: .attach)
                        for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
                            window.accessibilityLabel = "librarySwitch: requested"
                        }
                        return
                    }
                }
            }
#endif
            // After an import the app is active and the replaced library's transfers go at once;
            // at launch the first activation does it (SceneDelegate).
            if UIApplication.shared.applicationState == .active { reconcileBackgroundTransfers() }
#if DEBUG
            if !restart {
                startLaunchFixtures(arguments: arguments, directory: directory, store: store, downloads: preferences,
                                    startRemovedEpisodePeriodicRefresh: startRemovedEpisodePeriodicRefresh)
            }
#endif
            // The start succeeded: a missing server library is said once, on the first screen a person sees.
            missingLibraryNotice.started(opening)
        } catch { throw error } // `libraryStartup` waits, retries or shows it.
        startupError = unreadablePreferences
    }

    /// NotTennaPod's first-launch statement: due until it has been shown once on this install.
    /// UI and view tests (UUID libraries) skip it unless a journey asks for it with `-test-first-launch-notice`.
    var firstLaunchNoticeDue: Bool {
        guard let libraryDirectory else { return false }
#if DEBUG
        if libraryDirectory.lastPathComponent.hasPrefix("UITests-"),
           !ProcessInfo.processInfo.arguments.contains("-test-first-launch-notice") { return false }
#endif
        return !FileManager.default.fileExists(atPath: libraryDirectory.appendingPathComponent(Self.firstLaunchNoticeMarker).path)
    }
    func recordFirstLaunchNoticeShown() {
        guard let libraryDirectory else { return }
        FileManager.default.createFile(atPath: libraryDirectory.appendingPathComponent(Self.firstLaunchNoticeMarker).path, contents: Data())
    }
    private static let firstLaunchNoticeMarker = "first-launch-notice-shown"

    /// The first, synchronous step of tearing the graph down: from here on the old player admits no command (from its
    /// screens, the system controls, the widget, intents or Cast) and stops after the commands already admitted.
    /// A library switch runs it in the same main-actor step as its final activation check.
    func retireLibraryGraph() {
#if DEBUG
        librarySwitchFixture?.cancel(); librarySwitchFixture = nil
#endif
        librarySwitchEvents?.cancel(); librarySwitchEvents = nil
        streamingRelayPlayback?.cancel(); streamingRelayPlayback = nil
        streamingRelayEligibility.setPlaybackActive(false)
        pinnedRemovalObservation?.cancel(); pinnedRemovalObservation = nil
        castSwitchObservation?.cancel(); castSwitchObservation = nil
        refreshRecovery?.cancel(); refreshRecovery = nil
        mobilePreferenceDelivery?.cancel(); mobilePreferenceDelivery = nil
        playbackSystemControls?.stop(); playbackSystemControls = nil
        playerWidget?.stop(); playerWidget = nil
        castRuntime?.retire()
        playback?.retire()
    }

    /// Stops every library-bound owner and closes the live store, like the source's process exit,
    /// so no late playback, download, refresh or sync write can reach a replaced library. A failed start's discarding
    /// keeps the routes waiting for a screen: they belong to the start that succeeds, not to the failed graph.
    func stopLibraryGraph(keepingPendingRoutes: Bool = false) async {
        retireLibraryGraph()
        await playback?.retire().value
        await stopServerSync()
        sleepTimerFeedback?.receive(.shakeListening(false)); sleepTimerFeedback = nil
        automaticDownloads?.suspend(); manualRefresh?.suspend(); synchronization?.suspend()
        periodicRefresh?.stop()
        automaticBackup?.stop(); automaticBackup = nil
        databaseMaintenance = nil; maintenanceGate = nil
        downloadErrorEvents?.cancel(); downloadErrorEvents = nil; downloadErrors = nil
        await downloads?.stop()
        downloadRouter = nil
        await library?.closeReaders()
        try? await library?.close()
        library = nil; feedDeletion = nil; downloads = nil; playback = nil; playbackRoutes = nil; castRuntime = nil
        transcriptLoader = nil; chapterAccess = nil; automaticDownloads = nil; episodeNotifications = nil
        synchronizationDelivery = nil; synchronizationAccounts = nil; feedAuthentication = nil; synchronization = nil
        manualRefresh = nil; periodicRefresh = nil; refreshDelivery = nil
        if !keepingPendingRoutes { pendingNotification = nil; pendingDownloadLog = false }
        accountPolicy = nil
    }

    /// Source `DatabaseExporter.importBackup` without its data-loss paths: the backup
    /// is validated and converted into a complete staged library while the app keeps running; only then
    /// are all library writers stopped and the library files swapped with rollback. Throws before the
    /// commit leave the live library, credentials and preferences untouched.
    /// The import is journaled before anything is staged and holds the background grant while it runs. Staging and
    /// the wait for the library gate stop when background time ends (`DatabaseImportInterrupted`, rolled back); the
    /// commit, once begun, is not interrupted. A rollback removes only what the import created, never a credential the
    /// live library reaches; an import ended by the system is completed or rolled back at the next launch.
    func importDatabase(from url: URL) async throws {
        guard let location = libraryLocation, let live = library, let root = libraryDirectory,
              let liveIdentity = live.identityAtOpen?.identity else { throw FeedLibraryError.closed }
        // A converted library's own folder goes at its Keep's cleanup, which may run before the replacement (below).
        let directory = location.converted == nil ? location.folder : location.root
        let vault = feedAuthentication?.credentialStore ?? KeychainSynchronizationCredentials(service: "org.nottennapod.app.feeds")
        importOutcomeNotice = nil
        let attempt = try DatabaseImportAttempt(root: root, folder: directory, live: location.database, liveIdentity: liveIdentity, vault: vault,
                                                notices: pendingNotices ?? PendingNotices(root: root))
        // Its outcome is shown by its own dialog (which acknowledges it); only a later launch shows it otherwise.
        importOutcomeNotice = attempt.attempt
        noticesTaken.insert(attempt.attempt)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Commit: nothing may write to the replaced library any more, and no export reads it (the library gate, PROTOCOL §11.5).
        let preparing = Task { try await attempt.prepareCommit(backup: url, live: live, gate: .shared) }
        let state = ImportGrantState()
        let membership = backgroundWork.join(.init(hasWork: { true }, park: {
            guard !state.committing else { return }
            state.parked = true
            preparing.cancel()
        }))
        defer { membership.leave() }
        do { try await preparing.value }
        catch {
            await attempt.rollBack()
            throw state.parked ? DatabaseImportInterrupted() : error
        }
        // The library is checked again holding the gate: a Keep or a switch while the import was staged replaced it.
        guard !state.parked, library === live, let current = libraryLocation, let identity = live.identityAtOpen?.identity else {
            LibraryGate.shared.releaseExclusive()
            await attempt.rollBack()
            throw state.parked ? DatabaseImportInterrupted() : FeedLibraryError.closed
        }
        state.committing = true
        await stopLibraryGraph()
        let target: LibraryLocation
        do {
            // A Keep at logout that has not published is published first.
            let decided = try LibraryGraphStart.importTarget(current: current, identity: identity, keep: libraryKeep(root: current.root))
            if let outcome = decided.keep { keepOutcome = outcome }
            target = decided.location
            try await attempt.commit(target: target.database, replacedFolders: [target.media, target.streamingCache])
        } catch {
            // Rolled back: the secrets the import created go, and the unchanged library is used again.
            await attempt.rollBack()
            LibraryGate.shared.releaseExclusive()
            restartLibraryGraph()
            throw error
        }
        LibraryGate.shared.releaseExclusive()
        // The replaced library's downloaded files and stream cache can never be reached again; then the staging folder
        // and the journal go.
        await attempt.finish()
    }

    /// Per-feed speed/silence from a committed import, applied before anything plays (the import also clears
    /// the current-episode speed and shownotes position of the replaced library).
    private func applyRestoreJournal(store: FeedLibraryStore) async {
        do {
            guard let journal = try await store.pendingRestoreJournal() else { return }
            try speedPreferences?.restore(feeds: journal.feedSpeeds, silence: journal.feedSilence)
            try shownotesScroll?.reset()
            try await store.clearRestoreJournal()
        } catch {
            Logger(subsystem: "org.nottennapod.app", category: "Restore").error("Restored feed preferences retained for retry")
        }
    }

    /// The open library for an export, as the graph holds it now (PROTOCOL §11.5; read once the export holds the gate).
    func exportOpenLibrary() -> LibraryExport.OpenLibrary? {
        guard let store = library, let identity = store.identityAtOpen?.identity else { return nil }
        let speeds = speedPreferences
        return LibraryExport.OpenLibrary(store: store, identity: identity, readSpeeds: { await MainActor.run { speeds?.value ?? .init() } })
    }

    /// Source `showErrorNotification`: while the app is visible, the snackbar text; otherwise a
    /// notification when allowed. Without permission (Android: Toast) the text waits for the next
    /// activation.
    func reportAutomaticBackupError(_ message: String) {
        // A failure with no detail of its own (a refused server-library file, PROTOCOL §11.5) shows the label alone.
        let text = Appearance.text("automatic_database_export_error") + (message.isEmpty ? "" : " " + message)
        if UIApplication.shared.applicationState == .active, let controller = Self.activeLibraryController {
            controller.showAutomaticBackupError(text); return
        }
        let preferences = automaticBackupPreferences
        // Launching or returning to the foreground: the activation that follows shows it (synchronous,
        // so it cannot miss that activation).
        if UIApplication.shared.applicationState != .background {
            try? preferences?.update { $0.pendingError = text }
            if let controller = Self.activeLibraryController { automaticBackupBecameActive(in: controller) }
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in
                // Android 8+ posts backup failures on the "Synchronization failed" channel: turning that
                // switch off drops them too. The no-permission path is unchanged.
                switch await self?.backupFailureDelivery(authorized: allowed) ?? (allowed ? .notification : .pendingMessage) {
                case .notification:
                    let content = UNMutableNotificationContent()
                    content.title = Appearance.text("automatic_database_export_error"); content.body = message
                    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
                        identifier: "org.nottennapod.app.database-backup-error", content: content, trigger: nil))
                case .pendingMessage:
                    try? preferences?.update { $0.pendingError = text }
                case .nothing: break
                }
            }
        }
    }

    /// Every main screen a scene installs asks for the one-time missing-library message: the first one
    /// a person sees takes it.
    func connectMissingLibraryNotice(_ controller: LibraryViewController) {
        controller.takeMissingLibraryNotice = { [weak self] in self?.missingLibraryNotice.take() ?? false }
        controller.takeRecoveryNotices = { [weak self] in self?.takeRecoveryNotices() ?? [] }
    }

    /// The pending notices no screen of this process took yet, each acknowledged once it is on screen.
    func takeRecoveryNotices() -> [LibraryViewController.LaunchNotice] {
        guard let notices = pendingNotices, let pending = try? notices.all() else { return [] }
        return pending.filter { noticesTaken.insert($0.id).inserted }.map { notice in
            .init(message: Self.message(notice), shown: { try? notices.acknowledge(notice.id) },
                  release: { [weak self] in _ = self?.noticesTaken.remove(notice.id) })
        }
    }

    static func message(_ notice: PendingNotice) -> String {
        switch notice.kind {
        case .importCompleted: Appearance.text("database_import_interrupted_completed")
        case .importRolledBack: Appearance.text("database_import_interrupted")
        case .exportLocationUnknown: Appearance.text("export_interrupted_location_unknown")
        case .exportMayBeIncomplete: String(format: Appearance.text("export_interrupted"), notice.name ?? "")
        }
    }

    /// The import's result dialog is on screen: its outcome needs no message at a later launch.
    func acknowledgeImportOutcome() {
        guard let id = importOutcomeNotice else { return }
        importOutcomeNotice = nil
        try? pendingNotices?.acknowledge(id)
    }

    /// Activation: a pending report is shown once, then the due check runs.
    func automaticBackupBecameActive(in controller: LibraryViewController) {
        if let pending = automaticBackupPreferences?.value.pendingError {
            try? automaticBackupPreferences?.update { $0.pendingError = nil }
            controller.showAutomaticBackupError(pending)
        }
        automaticBackup?.resume()
    }

    private static var activeLibraryController: LibraryViewController? {
        UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
            .flatMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController as? LibraryViewController }
    }

    /// Playback counts while it wants to play or prepares for playback the person asked for, whatever its
    /// instantaneous rate; a pause, stop, interruption or the end makes the app eligible once no scene is in the
    /// foreground, including a pause that starts while it is already in the background.
    private func observeStreamingRelayEligibility() {
        streamingRelayPlayback?.cancel(); streamingRelayPlayback = nil
        streamingRelayScenesChanged()
        guard let playback else { streamingRelayEligibility.setPlaybackActive(false); return }
        let events = playback.events()
        streamingRelayPlayback = Task { [weak self, weak playback] in
            for await _ in events {
                guard let self, let playback else { return }
                streamingRelayEligibility.setPlaybackActive(playback.wantsPlayback || playback.isBuffering)
            }
        }
    }

    /// Any connected scene in the foreground (active or inactive), as the scene delegate decides the app left it.
    func streamingRelayScenesChanged(enteringForeground: Bool = false) {
        streamingRelayEligibility.setForeground(enteringForeground || UIApplication.shared.connectedScenes.contains {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        })
    }

    /// After a committed import, OK recreates the fresh application state: a new library graph and new
    /// root screens for every connected scene (source `forceRestart`). The startup owner installs the roots.
    func restartLibraryGraph() {
        libraryStartup.start()
    }

    static var libraryControllers: [LibraryViewController] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).compactMap { $0.rootViewController as? LibraryViewController }
    }

    func restartPeriodicRefresh(replace: Bool) {
        guard let downloadPreferences, let mobileNetworkPreferences else { return }
        periodicRefresh?.configure(intervalMinutes: downloadPreferences.value.refreshIntervalMinutes ?? PeriodicFeedRefreshSchedule.defaultInterval,
            allowMobile: mobileNetworkPreferences.allows(.feedRefresh), replace: replace)
    }

    func resumeRefreshServices() {
        guard refreshRecovery == nil, let synchronizationAccounts, let manualRefresh, let synchronization else { return }
        refreshRecovery = Task { [weak self] in
            defer { self?.refreshRecovery = nil }
            do { try await synchronizationAccounts.recoverCredentialCleanup() }
            catch { Logger(subsystem: "org.nottennapod.app", category: "Synchronization").error("Credential cleanup retained for retry") }
            do { try await self?.feedAuthentication?.recoverCredentialCleanup() }
            catch { Logger(subsystem: "org.nottennapod.app", category: "Feeds").error("Credential cleanup retained for retry") }
            do { try await manualRefresh.resume().value }
            catch { Logger(subsystem: "org.nottennapod.app", category: "Refresh").error("Saved refresh could not resume") }
            synchronization.resume()
        }
    }

    /// App Intents: the active scene's main screen runs the route; before a scene is active
    /// (the intent launched the app) it waits for the first activation.
    func routeExternal(_ route: ExternalEntry.Route) {
        // Only a started library's screen takes it; until then it waits, never the error screen of a failed start.
        if libraryStartup.isStarted, let controller = Self.activeLibraryController { controller.openExternal(route) }
        else { pendingExternalRoute = route }
    }

    func routeNotification(_ destination: EpisodeNotificationDestination, in preferredController: LibraryViewController? = nil) {
        Logger(subsystem: "org.nottennapod.app", category: "Notifications").notice("Notification route queued")
        pendingNotification = destination
        // Only a started library's screen takes it; until then it waits, never the error screen of a failed start.
        guard libraryStartup.isStarted else { return }
        if let preferredController { consumeNotification(in: preferredController); return }
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController as? LibraryViewController {
            consumeNotification(in: controller)
        }
    }
    func consumeNotification(in controller: LibraryViewController) {
        if pendingDownloadLog {
            pendingDownloadLog = false
            controller.openDownloadLogFromNotification()
        }
        guard let destination = pendingNotification else { return }
        Logger(subsystem: "org.nottennapod.app", category: "Notifications").notice("Notification route consumed")
        pendingNotification = nil
        Task { await controller.openNotification(destination) }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        Logger(subsystem: "org.nottennapod.app", category: "Notifications").notice("Notification response received")
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           DownloadErrorDelivery.opensDownloadLog(identifier: response.notification.request.identifier,
                                                  category: response.notification.request.content.categoryIdentifier) {
            await routeDownloadLog()
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let destination = NativeEpisodeNotifications.destination(identifier: response.notification.request.identifier,
                category: response.notification.request.content.categoryIdentifier,
                userInfo: response.notification.request.content.userInfo) else { return }
        await routeNotification(destination)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if NativeSynchronizationNotifications.opensApplication(identifier: notification.request.identifier,
            category: notification.request.content.categoryIdentifier) { return [.list, .banner, .sound] }
        if DownloadErrorDelivery.opensDownloadLog(identifier: notification.request.identifier,
            category: notification.request.content.categoryIdentifier) { return [.list, .banner, .sound] }
        guard notification.request.content.categoryIdentifier == NativeEpisodeNotifications.category else { return [] }
        return notification.request.content.interruptionLevel == .passive ? [.list] : [.list, .banner, .sound]
    }
}

/// A database import's standing with the background grant: parked before its commit, or committing (not interrupted).
@MainActor private final class ImportGrantState {
    var committing = false
    var parked = false
}

/// The UIKit completion handler for background session events, called once on the main queue.
private final class UncheckedCompletion: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler() }
}

import UIKit
import NotTennaPodCore
import OSLog

@MainActor
final class LibraryViewController: UIViewController, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    enum Screen {
        case destination(NavigationDestination)
        /// SubscriptionFragment(STATE_ARCHIVED), pushed from the Subscriptions overflow.
        case archive
        case feed(Int64)
        case feedInformation(Int64)
        case feedSettings(Int64)
        case episode(Int64, Int64)
        case settings(SettingsPage)
        case search(LibrarySearchView)
        case onlineSearch(OnlineSearchView)
        /// DiscoveryFragment: loaded as a root screen by "Discover more »".
        case discover(DiscoverView)
        /// SearchPreferenceFragment, opened from the Settings root's search card.
        case settingsSearch(SettingsSearchView)
    }
    /// Discover's Hide and country (`CountryRegionPrefs`), and the Add screen's suggestions.
    var discoveryPreferences: DiscoveryPreferenceStore?
    let addPodcastScreen = AddPodcastScreenState()
    /// The Synchronization log and Needs attention screens (PROTOCOL §15.5).
    let serverSyncScreens = ServerSyncScreensState()
    private let previewFeedID: Int64?
    var onPreviewClose: (() -> Void)?
    var onPreviewSubscribe: ((Int64) async throws -> Void)?
    var subscriptionPending = false
    var requestedPreviewAttempts: [Int64: Date] = [:]
    var isPreview: Bool { previewFeedID != nil }
    let podcastSearch: PodcastSearchClient
    let library: FeedLibraryStore?
    let loadSnapshot: (@Sendable () async throws -> FeedLibrarySnapshot)?
    private var libraryReload: Task<Void, Never>?
    private var pendingLibraryReload: LibraryReloadRequest?
    private var libraryReloadRequests: UInt64 = 0
    private var libraryReloadsApplied: UInt64 = 0
    /// Library changes received in the background, read once when the app becomes active.
    private var backgroundReload: LibraryReloadRequest?
    var applicationInBackground: @MainActor () -> Bool = { UIApplication.shared.applicationState == .background }
    private let startupError: Error?
    fileprivate(set) lazy var messages = ModalMessagePresenter(owner: self)
    let feedDeletion: FeedDeletionCoordinator?
    let manualRefresh: ManualFeedRefreshCoordinator?
    /// OPML import; the OPML export flow is below. Shell order is export/import.
    lazy var opmlImportFlow: OPMLImportFlow? = {
        guard let library, let manualRefresh else { return nil }
        return OPMLImportFlow(host: self, makeSession: {
            let refresh: @MainActor () async throws -> Void = { _ = try await manualRefresh.runOnce(feedID: nil).value }
#if DEBUG
            if let fixture = OPMLJourneyFixture.session(store: library, refresh: refresh) { return fixture }
#endif
            return OPMLImportSession(store: library, read: { try await OPMLDocumentReader().read($0) }, refresh: refresh)
        }, finished: { [weak self] in
            guard let self else { return }
            self.path = Array(self.path.prefix { screen in
                if case .settings = screen { return false }
                return true
            })
            self.reloadLibrary()
        }, notice: { [weak self] in self?.showNotice($0) })
    }()
    func openOPMLDocument(_ url: URL) { opmlImportFlow?.open(url) }
    /// Source `DatabaseExporter` backup through the same picker/progress/success/Share/error flow as OPML.
    /// The library the export attempt being made reads, by identity (PROTOCOL §11.5); nil: the open library.
    var exportTarget: String?
    /// Where manual exports record their attempts and the background grant they hold while they write. Set by the
    /// scene; nil in screens made without the app (tests), which record nothing.
    var exportEnvironment: (journal: ExportAttemptJournal, grant: BackgroundWorkGrant)?
    private var databaseExportFlowStorage: DocumentExportFlow?
    var databaseExportFlow: DocumentExportFlow? {
        if let databaseExportFlowStorage { return databaseExportFlowStorage }
        guard library != nil else { return nil }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("database-export", isDirectory: true)
        let flow = DocumentExportFlow(host: self, makeOperation: { [weak self] in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
            // Bound to the chosen library's identity now; read after the destination is chosen, like the source exporter,
            // from one source collected under the library gate (PROTOCOL §11.5).
            guard let payload = try self?.exportPayload(.database) else { throw LibraryExportError.libraryNotFound }
            return try DocumentExportOperation(stagingRoot: staging, name: "NotTennaPodBackup-\(formatter.string(from: Date())).db",
                                               payload: payload, write: DocumentExportOperation.sizeVerifiedWrite,
                                               journal: self?.exportEnvironment?.journal, grant: self?.exportEnvironment?.grant)
        })
        databaseExportFlowStorage = flow
        return flow
    }
    /// Source `Export.HTML` / `Export.FAVORITES` through the same picker/progress/success/Share/error
    /// flow; the library is read after the destination is chosen.
    private var htmlExportFlows: [String: DocumentExportFlow] = [:]
    func htmlExportFlow(favorites: Bool) -> DocumentExportFlow? {
        let key = favorites ? "favorites" : "feeds"
        if let flow = htmlExportFlows[key] { return flow }
        guard library != nil else { return nil }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("html-export", isDirectory: true)
        let flow = DocumentExportFlow(host: self, makeOperation: { [weak self] in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
            guard let payload = try self?.exportPayload(favorites ? .favorites : .html) else { throw LibraryExportError.libraryNotFound }
            return try DocumentExportOperation(stagingRoot: staging, name: "nottennapod-\(key)-\(formatter.string(from: Date())).html", payload: payload,
                                               journal: self?.exportEnvironment?.journal, grant: self?.exportEnvironment?.grant)
        })
        htmlExportFlows[key] = flow
        return flow
    }
    /// Created on first export; route changes only consult an existing flow.
    private var opmlExportFlowStorage: DocumentExportFlow?
    var opmlExportFlow: DocumentExportFlow? {
        if let opmlExportFlowStorage { return opmlExportFlowStorage }
        guard library != nil else { return nil }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("opml-export", isDirectory: true)
        var write: DocumentExportOperation.Writer = DocumentExportOperation.coordinatedWrite
#if DEBUG
        if let injected = OPMLExportJourneyFixture.writer() { write = injected }
#endif
        let flow = DocumentExportFlow(host: self, makeOperation: { [weak self] in
            // Fresh transactional read after destination selection; original-title order.
            guard let payload = try self?.exportPayload(.opml) else { throw LibraryExportError.libraryNotFound }
            return try DocumentExportOperation(stagingRoot: staging, payload: payload, write: write,
                                               journal: self?.exportEnvironment?.journal, grant: self?.exportEnvironment?.grant)
        })
        opmlExportFlowStorage = flow
        return flow
    }

    let refreshNetwork: @Sendable () async throws -> DownloadNetworkState
    var feedURLEdit: FeedURLEditFlow?
    var feedCredentialEdit: FeedCredentialEditFlow?
    let refreshIndicator = FeedRefreshIndicator()
    private var notificationRouteID = UUID()
    let downloads: DownloadCoordinator?
    let downloadPreferences: DownloadPreferenceStore?
    let inboxSwipePreferences: SwipePreferenceStore?
    let allEpisodesFilterPreferences: AllEpisodesFilterPreferenceStore?
    var inboxSwipeCoordinator: EpisodeSwipeCoordinator?
    var inboxSwipeOffers: SwipeOfferPresenter?
    var lastInboxSwipe: Task<Void, Never>?
    let proxyPreferences: ProxyPreferenceStore?
    let proxyTransport: any FeedHTTPTransport
    let transcriptLoader: TranscriptLoader
    let chapterAccess: EpisodeChapterAccess?
    let playback: PlaybackCoordinator?
    let timeDisplayPreferences: TimeDisplayPreferenceStore?
    private let shownotesScroll: ShownotesScrollStore?
    let speedPreferences: PlaybackSpeedPreferenceStore?
    let intervalPreferences: PlaybackIntervalPreferenceStore?
    let sleepTimerPreferences: SleepTimerPreferenceStore?
    let playbackQueuePreferences: PlaybackQueuePreferenceStore?
    let playbackHardwarePreferences: PlaybackHardwarePreferenceStore?
    let mobileNetworkPreferences: MobileNetworkPreferenceStore?
    let automaticDownloadPreferences: AutomaticDownloadPreferenceStore?
    let usage: StreamDownloadUsageStore?
    let localFolders: LocalFolderCoordinator?
    let localFolderPicker = LocalFolderPicker()
    let allEpisodesFilterLabel = Appearance.label(nil, size: 12)
    var allEpisodesVisible: Bool { if case .destination(.episodes) = path.last { true } else { false } }
    var allEpisodesFilter: AllEpisodesFilter { allEpisodesFilterPreferences?.value ?? .init() }
    let queueInformationLabel = Appearance.label(nil, size: 12)
    var lastInformationEpisode: Int64?
    var lastInformationStatus: LibraryPlaybackSession.Status?
    var lastInformationSpeed: Float?
    let queueInteractionPreferences: QueueInteractionPreferenceStore?
    /// The global new-episodes action, enqueue location and Keep sorted (PROTOCOL §15.4).
    let accountPolicy: AccountPolicy
    var queueDragController: QueueDragController?
    var queueMoveTask: Task<Void, Never>?
    var queuePresentationID = UUID()
    var queuePolicy: QueueInteractionPolicy {
        .init(locked: queueInteractionPreferences?.value.locked ?? false,
              keepSorted: accountPolicy.keepSorted,
              selecting: currentSelectionScope == .queue && feedSelection.active)
    }
    var queueVisible: Bool { if case .destination(.queue) = path.last { true } else { false } }
    private var playbackEvents: Task<Void, Never>?
    private let castRuntime: CastApplicationRuntime?
    private var castObservation: CastChooserCancellation?
    var playerView: PlayerView?
    /// A single screen may attach the shared session layer across application scenes.
    static weak var videoScreenOwner: LibraryViewController?
    var videoController: PlaybackVideoViewController?
    var lastAutomaticVideoEpisodeID: Int64?
    var requestedVideoEpisodeID: Int64?
    private var downloadEvents: Task<Void, Never>?
    /// The episode rows that exist as views (in a long list, only those near the visible area).
    var episodeRows: [Int64: (LibraryEpisode, EpisodeRowView)] = [:]
    /// The long list on screen: every loaded row has a frame, but rows are built only near the visible area
    ///. The Subscriptions grid works the same way.
    var episodeList: LazyContentList?
    var subscriptionGrid: LazyContentList?
    /// The episode list's loaded items, from which a row is built when it comes near the screen.
    var displayedEpisodeValues: [Int64: (feed: LibraryFeed, episode: LibraryEpisode)] = [:]
    var episodePagerList: [EpisodePagerItem] = []
    struct EpisodeRowHeightKey: Hashable {
        let title: String, progressLine: Bool, draggable: Bool, action: Bool, queue: Bool
        let width: CGFloat, scale: CGFloat, category: UIContentSizeCategory
    }
    /// Measured row heights, so a reload does not measure every loaded title again.
    var episodeRowHeights: [EpisodeRowHeightKey: CGFloat] = [:]
    /// What the rows last showed of playback (the playing episode's Pause button), and the player's shell state.
    var playerRowState: (episode: Int64?, playing: Bool) = (nil, false)
    var playerShellState: (episode: Int64?, visible: Bool) = (nil, false)
    /// Playback changed while the app was in the background; the screen catches up when it returns.
    var backgroundUpdatePending = false
    /// The sleep timer as last seen, and the dialog starts already accounted for.
    var sleepTimerWasActive = false
    var personalSleepTimerStarts: UInt64 = 0
    /// Home: cards for live download/playing updates and the source screen each Home row belongs to
    /// (See what's new rows act like Inbox rows, Manage downloads rows like Downloads rows).
    var homeCards: [(LibraryEpisode, HomeEpisodeCard, localFeed: Bool)] = []
    var homeRowScopes: [Int64: EpisodeSelectionScope] = [:]
    /// Source `EpisodesSurpriseSection.seed`: process-wide, drawn once and by Shuffle only.
    static var homeSurpriseSeed: Int32 = 0
    /// `HomePreferences` (installed per scene).
    var homePreferences: HomeSectionPreferenceStore?
    /// Inbox and Episodes sorts (Favorites follows Episodes) and the Remove-all prompt choice.
    var episodeListPreferences: EpisodeListPreferenceStore?
    /// Settings → Notifications switches (installed per scene).
    var notificationPreferences: NotificationPreferenceStore?
    /// Theme, Full black and Use episode cover (installed per scene; `LibraryViewController+Interface.swift`).
    var interfacePreferences: InterfacePreferenceStore? { didSet { observeInterfacePreferences() } }
    /// Settings search history (installed per scene; kept in memory when absent).
    var settingsSearchHistory: SettingsSearchHistoryStore?
    lazy var settingsSearchHistoryFallback = SettingsSearchHistoryStore()
    /// The Download log sheet on screen or waiting to be shown, so a notification tap never adds a second one.
    weak var downloadLogSheet: DownloadLogController?
    var episodeListFallback = EpisodeListPreferences()
    var episodeLists: EpisodeListPreferences { episodeListPreferences?.value ?? episodeListFallback }
    /// Subscriptions/Archive/drawer order, counter, filter, titles and columns (installed per scene).
    var subscriptionPreferences: SubscriptionDisplayPreferenceStore? { didSet { if isViewLoaded { rebuildDrawer() } } }
    var subscriptionFallback = SubscriptionDisplayPreferences()
    /// Subscriptions/Archive multi-select (feed ids), its screen and its floating actions.
    var subscriptionSelection = EpisodeListSelection()
    var subscriptionSelectionArchive = false
    var subscriptionSelectionIDs: [Int64] = []
    var subscriptionSelectionActions: [FeedBulkAction] = []
    let subscriptionSelectionBar = EpisodeSelectionBar()
    /// The Archive screen's tag chip: it starts at All on every visit and is not stored.
    var archiveTag = FeedTags.root
    struct ActionBinding {
        let model: EpisodeActionModel
        let feedID: Int64
        let source: String
        let positionRevision: UInt64
        let deletionTarget: EpisodeMediaDeletionTarget?
    }
    struct CapturedAction {
        let model: EpisodeActionModel
        let feedID: Int64
        let source: String
        let presentation: UUID
        let search: LibrarySearchSession?
        let searchRevision: UInt64?
        let deletionTarget: EpisodeMediaDeletionTarget?
    }
    // These models belong only to the current data presentation, never a global ID cache.
    var actionBindings: [Int64: ActionBinding] = [:]
    private(set) var deletionTargets: [Int64: EpisodeMediaDeletionTarget] = [:]
    var actionPresentation = UUID()
    var actionMutationRevision: UInt64 = 0
    var searchResultRevision: UInt64?
    var searchNeedsReload = false
    var lastEpisodeActionDeletion: Task<Void, Never>?
    var lastEpisodeActionReconciliation: Task<Void, Never>?
    var episodeActionDeletionWait: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }
    // A persistence boundary lets mounted tests suspend an action while real data reloads.
    var beforeEpisodeActionCommit: (@MainActor () async throws -> Void)?

    func retireActionPresentation() {
        actionPresentation = UUID(); actionBindings.removeAll(); searchResultRevision = nil
    }

    func actionModel(feed: LibraryFeed, episode: LibraryEpisode, deletionTarget: EpisodeMediaDeletionTarget? = nil) -> EpisodeActionModel {
        if let binding = actionBindings[episode.id] { return binding.model }
        let model = EpisodeActionModel(item: .init(episode: episode,
            local: feed.source.isLocalFeedSource, subscription: feed.subscriptionState,
            queued: queuedEpisodes.contains { $0.id == episode.id },
            downloading: downloads?.activeJob(source: episode.details.media?.url) != nil))
        let target: EpisodeMediaDeletionTarget?
        if case .search = path.last { target = deletionTarget }
        else if let captured = deletionTargets[episode.id] { target = captured }
        else if let media = episode.details.media, !feed.source.isLocalFeedSource {
            target = .init(episodeID: episode.id, feedID: feed.id, source: feed.source,
                media: .remote(mediaURL: media.url, originalFile: episode.userState.localFileURL))
        } else { target = nil }
        actionBindings[episode.id] = .init(model: model, feedID: feed.id, source: feed.source,
            positionRevision: playback?.positionRevision ?? 0, deletionTarget: target)
        return model
    }

    func contextItem(_ model: EpisodeActionModel) -> EpisodeListItem {
        let item = model.snapshot()
        return .init(episode: item.episode, local: item.local, subscription: item.subscription,
            queued: queuedEpisodes.contains { $0.id == model.episodeID },
            downloading: downloads?.activeJob(source: item.episode.details.media?.url) != nil)
    }

    func captureAction(_ id: Int64) -> CapturedAction? {
        guard let binding = actionBindings[id], episodeRows[id]?.1.actionModel === binding.model else { return nil }
        let search: LibrarySearchSession?
        if case .search(let view) = path.last { search = view.session } else { search = nil }
        return .init(model: binding.model, feedID: binding.feedID, source: binding.source, presentation: actionPresentation, search: search, searchRevision: search?.resultRevision, deletionTarget: binding.deletionTarget)
    }

    private(set) var episodeActionPositionRevision: UInt64 = 0
    private func receivePosition(_ update: PlaybackPositionUpdate) {
        // A preview does not observe playback itself; its rows follow the shared player through this screen.
        if let preview = presentedViewController as? FeedPreviewController,
           let child = preview.contentController as? LibraryViewController { child.receivePosition(update) }
        episodeActionPositionRevision = update.revision
        guard let playback, let binding = actionBindings[update.episodeID],
              playback.isCurrent(update, after: binding.positionRevision), view.window != nil else { return }
        guard let row = episodeRows[update.episodeID]?.1, row.actionModel === binding.model,
              row.window != nil, row.isDescendant(of: content) else {
            // A long list's row released away from the screen is built again from its model.
            if episodeList?.frame(of: update.episodeID) != nil, episodeRows[update.episodeID] == nil {
                binding.model.receivePlaybackPosition(positionMilliseconds: update.positionMilliseconds,
                    durationMilliseconds: update.durationMilliseconds)
            }
            return
        }
        binding.model.receivePlaybackPosition(positionMilliseconds: update.positionMilliseconds,
            durationMilliseconds: update.durationMilliseconds)
        // Nothing is drawn while the app is in the background; the next update after its return shows the position.
        guard UIApplication.shared.applicationState != .background else { return }
        row.updatePlaybackPosition(position: update.positionMilliseconds, duration: update.durationMilliseconds,
            showRemainingTime: timeDisplayPreferences?.value.showRemainingTime == true)
    }

    func reconcileCommittedAction(_ captured: CapturedAction, delta: EpisodeActionStateDelta) {
        captured.model.applyCommittedState(delta)
        let id = captured.model.episodeID
        guard actionPresentation == captured.presentation, actionBindings[id]?.model === captured.model else {
            // Read the current presentation after persistence. Never patch a
            // replacement model with the older action's cached row or state.
            lastEpisodeActionReconciliation = reloadLibrary(preservingEpisodeDetails: true, reconcilingPresentation: actionPresentation)
            return
        }
        for feedIndex in feeds.indices {
            if let index = feeds[feedIndex].episodes.firstIndex(where: { $0.id == id }) {
                delta.apply(to: &feeds[feedIndex].episodes[index])
            }
        }
        if let index = queuedEpisodes.firstIndex(where: { $0.id == id }) { delta.apply(to: &queuedEpisodes[index]) }
        if let search = captured.search, let revision = captured.searchRevision {
            _ = search.applyCommittedState(delta, episodeID: id, expectedResultRevision: revision)
            // The search keeps its results; the bottom bar and drawer still count at once (FeedItemEvent).
            refreshNavigationCounters()
        } else { render() }
        updateQueueInformation()
    }
    var episodeHeader: EpisodeHeaderView?
    var episodeHeaderScroll = UIScrollView()
    var episodeNotes: ShownotesWebView?
    var episodeDetailsID: Int64?
    struct EpisodePage {
        let feedID: Int64
        let episodeID: Int64
        /// The page's own area inside the pager; header and shownotes belong to this page only.
        let container: UIView
        let header: EpisodeHeaderView
        let headerScroll: UIScrollView
        let notes: ShownotesWebView
    }
    // MainActivity hides parent fragments on child navigation. Keep each stack
    // entry's reading state independent, including repeated visits to one episode.
    // Each episode entry is a pager (ItemPagerFragment) with its resident pages.
    var episodePagers: [Int: EpisodePagerState] = [:]
    /// The expanded player covers the screen's content (episode notes behind it cannot be seen).
    var episodeContentCovered = false
    /// The scene is in the background: nobody can swipe to a pager's neighbours.
    var episodeSceneBackgrounded = false
    /// Episode pages built so far (each with its own WebKit view).
    var episodePagesBuilt = 0
    /// Whether a library snapshot has been applied (a missing visible episode then closes its pager).
    private(set) var libraryLoaded = false
    var feedInformation: FeedInformationScreenView?
    var feedPreferenceWrite: Task<Void, Never>?
    var feedPreferenceWriteID = UUID()
    var visibleSnackbar: Snackbar?
    let synchronizationSettings: SynchronizationSettingsPresentation?
    var nextcloudRestoration: NextcloudAuthenticationRestoration?
    /// The application owns library replacement and the graph restart (installed per scene).
    var importDatabase: (@MainActor (URL) async throws -> Void)?
    var restartApplication: (() -> Void)?
    /// Automatic database export owner (installed per scene).
    var automaticBackup: AutomaticDatabaseExportRuntime? {
        didSet { automaticBackup?.onChange = { [weak self] in self?.automaticBackupChanged() } }
    }
    private func automaticBackupChanged() {
        if case .settings(.importExport)? = path.last { render() }
    }
    func showAutomaticBackupError(_ text: String) { showNotice(text) }
    /// Source switch listener: ON opens the writable folder picker (switch stays off until a folder is
    /// chosen; cancel keeps it off); OFF clears the folder and cancels the schedule.
    func toggleAutomaticBackup() {
        guard let runtime = automaticBackup else { return }
        if runtime.isEnabled { do { try runtime.disable() } catch { showError(error) }; return }
        let picker = localFolderPicker.makeController { [weak self, weak runtime] directory in
            guard let self, let runtime else { return }
            do { try runtime.enable(bookmark: try LocalFolderDocuments.makeBookmark(directory: directory)) }
            catch { showError(error) }
        }
        present(picker, animated: true)
    }
    private(set) lazy var databaseImportFlow = DatabaseImportFlow(host: self, presentMessage: { [weak self] dialog in
        // A rolled-back import rebuilt the screens; its error belongs on the current one.
        let current = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController as? LibraryViewController }.first
        ((self?.view.window != nil ? self : nil) ?? current)?.messages.present(dialog)
    }, perform: { [weak self] url in
        guard let importDatabase = self?.importDatabase else { return }
        try await importDatabase(url)
    }, restart: { [weak self] in self?.restartApplication?() }, outcomeShown: { [weak self] in self?.importOutcomeShown?() })
    var recoveredNextcloudAuthorization = false
    private var synchronizationVisible: Bool {
        if case .settings(.synchronization) = path.last { true } else { false }
    }
    private var notice: UILabel?
    private var noticeTask: Task<Void, Never>?
    /// The shown notice is not replaced; later notices wait in `waitingNotices` (`showNotice(_:holds:)`).
    private var noticeHolds = false
    private var waitingNotices: [WaitingNotice] = []
    /// A notice waiting its turn. `shown`: it is a durable launch notice, acknowledged once it is on screen in a scene a
    /// person sees; `release` gives it back for another visible screen when this one cannot show it.
    private struct WaitingNotice {
        let message: String
        let shown: (() -> Void)?
        let release: (() -> Void)?
    }
    var feeds: [LibraryFeed] = [] { didSet { episodeLocations = nil; libraryRevision &+= 1 } }
    /// The statistics units of the loaded library (schema 20): Home's classics count them as rows, as Android does.
    var statisticsUnits: [Int64: [LibraryStatisticsUnit]] = [:]
    /// Changes whenever `feeds` is replaced or edited.
    private(set) var libraryRevision: UInt64 = 0
    /// The download jobs and library the Downloads list was last checked against.
    private var downloadsRowsCheck: (jobs: [LibraryDownloadJob], library: UInt64)?
    var queuedEpisodes: [LibraryEpisode] = []
    /// Episode id → its feed and position in `feeds`, rebuilt after the library changes (lookups
    /// by id were linear scans of every episode, which a large library turns into multi-second stalls).
    private var episodeLocations: [Int64: (feed: Int, episode: Int)]?
    func libraryEpisode(_ id: Int64) -> (feed: LibraryFeed, episode: LibraryEpisode)? {
        if episodeLocations == nil {
            var locations: [Int64: (feed: Int, episode: Int)] = [:]
            locations.reserveCapacity(feeds.reduce(0) { $0 + $1.episodes.count })
            for (feedIndex, feed) in feeds.enumerated() {
                for (episodeIndex, episode) in feed.episodes.enumerated() where locations[episode.id] == nil {
                    locations[episode.id] = (feedIndex, episodeIndex)
                }
            }
            episodeLocations = locations
        }
        guard let location = episodeLocations?[id] else { return nil }
        return (feeds[location.feed], feeds[location.feed].episodes[location.episode])
    }
    /// Android `EpisodesListFragment` / `FeedItemlistFragment.EPISODES_PER_PAGE`: Inbox, Episodes, Favorites,
    /// History and a podcast's episode list show 150 episodes and add the next 150 when scrolled to the
    /// bottom; a reload keeps the pages already shown (`loadItems` reads `page * EPISODES_PER_PAGE`).
    static let episodesPerPage = 150
    var episodePaging: (screen: String, pages: Int) = ("", 1)
    /// The list's items beyond the loaded pages.
    var remainingEpisodeRows: ArraySlice<(LibraryFeed, LibraryEpisode)>?
    /// Rows a restored reading position needs before the list can scroll back to it.
    private var minimumEpisodeRowCount = 0
    /// The drawer content last applied; nil forces the next render to rebuild it.
    var drawerSignature: [String]?
    private var renderCount = 0
    private(set) var rootDestination = NavigationDestination.home
    private(set) var rootNavigationTag = NavigationDestination.home.rawValue
    private var recordedStartup = false
    let statisticsPreferences: StatisticsPreferenceStore?
    let subscriptionStatistics: SubscriptionStatisticsLoader?
    // The Years and Downloads pages and the screen's current tab (never stored).
    let yearStatistics: StatisticsPageLoader<YearsStatisticsSnapshot>?
    let downloadStatistics: StatisticsPageLoader<DownloadStatisticsSnapshot>?
    var statisticsTab = StatisticsTab.subscriptions
    var statisticsPagerStorage: StatisticsPagerView?
    private var statisticsEvents: Task<Void, Never>?
    var statisticsActive = false
    var statisticsVisible: Bool { if case .destination(.statistics) = path.last { true } else { false } }
    var feedSettingsTagDraft: (feedID: Int64, saved: [[UInt16]], draft: FeedTags)?
    /// Changes of `path` since this screen was created, other than restoring its scene's place.
    private(set) var navigationChanges: UInt64 = 0
    /// The stack changes for the screen itself (a restored place, or a start page that is gone), not for the person.
    private var restoringNavigation = false
    /// A restored stack is checked against the first library read.
    private(set) var restoredNavigationNeedsCheck = false
    /// A remembered podcast as the start page is checked against the first library read.
    private var startPageNeedsCheck = false
    /// The restored player expands once the restored episode is loaded. A route, the person's navigation or the person
    /// moving the player first gives it up; until then the scene saves it as expanded.
    var restoredPlayerExpansion = false
    /// Restored screens that read the library (a search, Discover's list): started at the first library read.
    var restoredStarts: [(view: UIView, start: () -> Void)] = []
    /// Restored settings searches whose index waits for the synchronization account to be read.
    var settingsSearchesAwaitingAccount: [SettingsSearchView] = []
    var path: [Screen] = [.destination(.home)] {
        didSet {
            if !restoringNavigation { navigationChanges &+= 1; restoredPlayerExpansion = false }
            retireActionPresentation()
            if case .settings(.importExport) = path.last {} else {
                opmlExportFlowStorage?.detachInterface(); databaseExportFlowStorage?.detachInterface()
                htmlExportFlows.values.forEach { $0.detachInterface() }
            }
            if !statisticsVisible {
                statisticsActive = false
                subscriptionStatistics?.cancel()
                leaveStatisticsTabs()
                if let selector = presentedViewController as? StatisticsFilterController { selector.dismiss(animated: false) }
            }
            if case .search = path.last { searchNeedsReload = true }
            episodePagers = episodePagers.filter { index, pager in
                guard path.indices.contains(index), case .episode(let feedID, let episodeID) = path[index] else { return false }
                return pager.model.visible == EpisodePagerItem(feedID: feedID, episodeID: episodeID)
            }
            if case .feedSettings(let id) = path.last, feedSettingsTagDraft?.feedID == id { return }
            feedSettingsTagDraft = nil
        }
    }
    private enum ReadingPosition {
        case offset(CGFloat)
        // Android retains adapter position and the first row's top offset.
        // An index intentionally survives filtering independently of episode ID.
        case episode(index: Int, top: CGFloat)
    }
    private var parentReadingPositions: [ReadingPosition] = []
    private var pendingReadingPosition: ReadingPosition?
    // Keep interactive shell content inside each horizontal safe-area edge.
    // Top/bottom placement remains owned by the source-derived shell layouts.
    let surface = UIView()
    let toolbar = UIView()
    let content = UIScrollView()
    var feedAppBar: FeedAppBarView?
    let feedPageFooter = FeedPageFooter()
    let feedSelectionBar = EpisodeSelectionBar()
    var feedSelection = EpisodeListSelection()
    enum EpisodeSelectionScope: Equatable {
        case feed(Int64), downloads, inbox, episodes, favorites, history, queue
        var bulkInbox: EpisodeListMenu.BulkInboxPolicy {
            switch self {
            case .feed, .inbox, .episodes, .downloads, .favorites, .history: .allowed
            case .queue: .excluded
            }
        }
        var contextIdentifier: String {
            switch self {
            case .feed: "feedEpisodeContextMenu"
            case .downloads: "downloadsEpisodeContextMenu"
            case .inbox: "inboxEpisodeContextMenu"
            case .episodes: "allEpisodeContextMenu"
            case .favorites: "favoritesEpisodeContextMenu"
            case .history: "historyEpisodeContextMenu"
            case .queue: "queueEpisodeContextMenu"
            }
        }
    }
    var selectionScope: EpisodeSelectionScope?
    var currentSelectionScope: EpisodeSelectionScope? {
        switch path.last {
        case .feed(let id): .feed(id)
        case .destination(.downloads): .downloads
        case .destination(.inbox): .inbox
        case .destination(.episodes): .episodes
        case .destination(.favorites): .favorites
        case .destination(.history): .history
        case .destination(.queue): .queue
        default: nil
        }
    }
    var feedSelectionIDs: [Int64] = []
    var feedContentHeight: CGFloat = 0
    var pageRequestPending = false
    var renderingContent = false
    var feedPull = FeedPullRefresh()
    enum RefreshScope: Equatable { case feed(Int64), downloads, home, subscriptions, archive, list(NavigationDestination) }
    var currentRefreshScope: RefreshScope? {
        switch path.last {
        case .feed(let id): .feed(id)
        case .destination(.downloads): .downloads
        // Source HomeFragment: pull-to-refresh exists only while sections (not welcome) are shown.
        case .destination(.home): HomeSectionQueries.showsWelcome(feeds) ? nil : .home
        // SubscriptionFragment: pull-to-refresh on both the subscribed and the archive screen.
        case .destination(.subscriptions), .destination(.subscriptionList): .subscriptions
        case .archive: .archive
        // EpisodesListFragment (Inbox, Episodes, Favorites, Playback history) and QueueFragment: pull-to-refresh
        // refreshes every podcast (runOnceOrAsk) and the spinner stays while the update runs.
        case .destination(let list) where [.inbox, .episodes, .favorites, .history, .queue].contains(list): .list(list)
        default: nil
        }
    }
    var pullScope: RefreshScope?
    var pullWaiting = false
    var pullSettling = false
    var pullReturning = false
    var pullAnimation: UIViewPropertyAnimator?
    let feedScrollMask = CAShapeLayer()
    var feedToolbarCollapsed = false
    var feedScrimAnimator: UIViewPropertyAnimator?
    private let navigation = UIView()
    private let bottomInset = UIView()
    /// An entry route delivered before this screen was in a window (cold launch).
    var pendingExternalRoute: ExternalEntry.Route?
    var popup: UIControl? {
        didSet { if popup == nil { layoutPopup = nil } }
    }
    var layoutPopup: (() -> Void)?
    var fetchTask: Task<Void, Never>?
    let feedAuthentication: FeedAuthentication?
    private var renderedSize = CGSize.zero
    let navigationPreferences: NavigationPreferenceStore?
    private var configuration: NavigationConfiguration { navigationPreferences?.value.configuration ?? .init() }
    var bottomNavigationEnabled: Bool { !isPreview && (navigationPreferences?.value.bottomNavigation ?? true) }
    private var navigationEvents: Task<Void, Never>?
    private let drawer = NavigationDrawerView()
    private var drawerFraction: CGFloat = 0
    private var drawerPanStart: CGFloat = 0
    private let drawerAnimator = DrawerAnimator()
    private var initialWindowSize: CGSize?
    private var afterConfigurationChange = false
    var settingsVisible: Bool {
        path.contains {
            guard case .settings(let page) = $0 else { return false }
            // Playback settings can be opened directly by the timer, just as
            // PreferenceActivity.OPEN_PLAYBACK_SETTINGS bypasses its root.
            return page == .main || page == .playback
        }
    }
    private var persistentDrawer: Bool { !isPreview && !bottomNavigationEnabled && min(view.bounds.width, view.bounds.height) >= 720 }


    init(library: FeedLibraryStore?, startupError: Error?, downloads: DownloadCoordinator?, playback: PlaybackCoordinator?, timeDisplayPreferences: TimeDisplayPreferenceStore?, navigationPreferences: NavigationPreferenceStore?, speedPreferences: PlaybackSpeedPreferenceStore?, mobileNetworkPreferences: MobileNetworkPreferenceStore?, usage: StreamDownloadUsageStore?, loadSnapshot: (@Sendable () async throws -> FeedLibrarySnapshot)? = nil, feedDeletion: FeedDeletionCoordinator? = nil, manualRefresh: ManualFeedRefreshCoordinator? = nil, podcastSearch: PodcastSearchClient = .init(), previewFeedID: Int64? = nil, feedAuthentication: FeedAuthentication? = nil, automaticDownloadPreferences: AutomaticDownloadPreferenceStore? = nil, downloadPreferences: DownloadPreferenceStore? = nil, inboxSwipePreferences: SwipePreferenceStore? = nil, allEpisodesFilterPreferences: AllEpisodesFilterPreferenceStore? = nil, proxyPreferences: ProxyPreferenceStore? = nil, proxyTransport: (any FeedHTTPTransport)? = nil, transcriptLoader: TranscriptLoader? = nil, chapterAccess: EpisodeChapterAccess? = nil, intervalPreferences: PlaybackIntervalPreferenceStore? = nil, sleepTimerPreferences: SleepTimerPreferenceStore? = nil, shownotesScroll: ShownotesScrollStore? = nil, playbackQueuePreferences: PlaybackQueuePreferenceStore? = nil, playbackHardwarePreferences: PlaybackHardwarePreferenceStore? = nil, queueInteractionPreferences: QueueInteractionPreferenceStore? = nil, queueEffects: (@MainActor @Sendable () async throws -> Void)? = nil, castRuntime: CastApplicationRuntime? = nil, synchronizationAccounts: SynchronizationAccounts? = nil, synchronization: SynchronizationCoordinator? = nil, synchronizationDelivery: SynchronizationDelivery? = nil, statisticsPreferences: StatisticsPreferenceStore? = nil, accountPolicy: AccountPolicy? = nil, refreshNetwork: @escaping @Sendable () async throws -> DownloadNetworkState = { try await DownloadNetworkMonitor.shared.observedState() }, serverAccounts: ServerAccounts? = (UIApplication.shared.delegate as? AppDelegate)?.serverAccounts) {
        if let library, let synchronizationAccounts, let synchronization, let synchronizationDelivery {
            synchronizationSettings = SynchronizationSettingsPresentation(store: library, accounts: synchronizationAccounts, coordinator: synchronization, delivery: synchronizationDelivery,
                                                                          server: serverAccounts)
        } else { synchronizationSettings = nil }
        self.chapterAccess = chapterAccess
        self.automaticDownloadPreferences = automaticDownloadPreferences
        self.feedAuthentication = feedAuthentication ?? library.map { FeedAuthentication(store: $0) }
        self.previewFeedID = previewFeedID
        self.podcastSearch = podcastSearch
        self.library = library
        self.statisticsPreferences = statisticsPreferences
        if let library { subscriptionStatistics = SubscriptionStatisticsLoader(store: library) }
        else if let loadSnapshot {
            subscriptionStatistics = SubscriptionStatisticsLoader(readStatistics: {
                let snapshot = try await loadSnapshot()
                return LibraryStatisticsInput(feeds: snapshot.feeds, units: snapshot.statisticsUnits)
            })
        }
        else { subscriptionStatistics = nil }
        let statisticsFeeds: StatisticsPageLoader<YearsStatisticsSnapshot>.Read? = if let library { { try await library.feeds() } }
            else if let loadSnapshot { { try await loadSnapshot().feeds } } else { nil }
        // Years counts the library's statistics units as rows (schema 20); Downloads reads episodes only.
        let statisticsRows: (@Sendable () async throws -> LibraryStatisticsInput)? = if let library { { try await library.statisticsLibrary() } }
            else if let loadSnapshot { { let snapshot = try await loadSnapshot(); return LibraryStatisticsInput(feeds: snapshot.feeds, units: snapshot.statisticsUnits) } }
            else { nil }
        yearStatistics = statisticsRows.map { StatisticsPageLoader(readStatistics: $0, make: { YearsStatisticsSnapshot(feeds: $0.feeds, units: $0.units) }) }
        downloadStatistics = statisticsFeeds.map { StatisticsPageLoader(read: $0, make: DownloadStatisticsSnapshot.init(feeds:)) }
        self.loadSnapshot = loadSnapshot ?? library.map { library in
            { @Sendable in
                if let queueEffects { try await queueEffects() }
                else { _ = try await library.consumeFeedRefreshQueueEffects() }
                return try await library.snapshot()
            }
        }
        self.startupError = startupError
        self.downloads = downloads
        self.downloadPreferences = downloadPreferences
        self.inboxSwipePreferences = inboxSwipePreferences
        self.allEpisodesFilterPreferences = allEpisodesFilterPreferences
        self.proxyPreferences = proxyPreferences; self.proxyTransport = proxyTransport ?? URLSessionFeedTransport()
        self.transcriptLoader = transcriptLoader ?? TranscriptLoader(transport: proxyTransport ?? URLSessionFeedTransport(),
            cache: URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0),
            userAgent: HTTPUserAgent.current)
        self.feedDeletion = feedDeletion
        self.manualRefresh = manualRefresh
        self.refreshNetwork = refreshNetwork
        self.playback = playback
        self.timeDisplayPreferences = timeDisplayPreferences
        self.shownotesScroll = shownotesScroll
        self.speedPreferences = speedPreferences
        self.intervalPreferences = intervalPreferences
        self.queueInteractionPreferences = queueInteractionPreferences
        let accountPolicy = accountPolicy ?? .standalone(download: downloadPreferences, queue: queueInteractionPreferences)
        self.accountPolicy = accountPolicy
        self.sleepTimerPreferences = sleepTimerPreferences; self.playbackQueuePreferences = playbackQueuePreferences
        self.playbackHardwarePreferences = playbackHardwarePreferences
        self.mobileNetworkPreferences = mobileNetworkPreferences
        self.navigationPreferences = navigationPreferences
        self.usage = usage
        localFolders = library.map { LocalFolderCoordinator(store: $0,
            description: Appearance.text("local_feed_description"), author: Appearance.text("local_folder"), options: {
                await MainActor.run {
                    var options = FeedRefreshOptions()
                    options.globalNewEpisodesAction = accountPolicy.newEpisodesAction
                    return options
                }
            }) }
        self.castRuntime = castRuntime
        super.init(nibName: nil, bundle: nil)
        applyQueueInsertionSettings()
        if let library, let downloads, let playback, inboxSwipePreferences != nil {
            let localFolders = self.localFolders
            let coordinator = EpisodeSwipeCoordinator(store: library, downloads: downloads) { target in
                switch target.media {
                case .local:
                    guard let localFolders else { throw FeedLibraryError.invalidMutation }
                    return try await localFolders.deleteMedia(target: target, playback: playback,
                        removeFromQueue: downloads.deletionRemovesFromQueue)
                case .remote:
                    return try await downloads.deleteDownloadedMedia(target: target, playback: playback)
                }
            }
            coordinator.onEvent = { [weak self] event in self?.receiveInboxSwipe(event) }
            inboxSwipeCoordinator = coordinator
        }
        let start = startPage(existing: nil)
        rootNavigationTag = start.tag; rootDestination = start.destination; path = [start.screen]
        // A remembered podcast is checked at the first library read.
        if case .feed = start.screen { startPageNeedsCheck = true }
        if let previewFeedID { path = [.feed(previewFeedID)]; startPageNeedsCheck = false }
        navigationChanges = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        subscriptionStatistics?.onChange = { [weak self] state in
            guard let self, statisticsActive, statisticsVisible else { return }
            switch state {
            case .loaded: statisticsPagesChanged()
            case .failed(_, let message):
                Logger(subsystem: "org.nottennapod.app", category: "Statistics").error("Statistics read failed: \(message, privacy: .public)")
                statisticsPagesChanged()
            case .idle, .loading: break
            }
        }
        observeStatisticsPages()
        if let statisticsPreferences {
            let events = statisticsPreferences.events()
            statisticsEvents = Task { [weak self] in
                // The stream first replays the stored value; the screen already requested that load.
                // Every later successful commit refreshes, including an unchanged confirmation
                // (source posts StatisticsEvent on each OK), so totals stay current and a failed
                // read can recover.
                var initial = true
                for await _ in events {
                    guard let self, !Task.isCancelled else { return }
                    if initial { initial = false; continue }
                    guard statisticsActive, statisticsVisible else { continue }
                    refreshSubscriptionStatistics()
                }
            }
        }
        synchronizationSettings?.onChange = { [weak self] in
            guard let self else { return }
            refreshRestoredSettingsSearchIndex()
            // The server rows come and go with the page (PROTOCOL §15.5): open and kept settings searches find what it shows now.
            refreshSettingsSearchIndexes()
            guard synchronizationVisible || serverSyncScreenVisible else { return }
            render()
        }
        // The account may have been read before this screen listened.
        refreshRestoredSettingsSearchIndex()
        synchronizationSettings?.onFailure = { [weak self] in self?.showError($0) }
        if let feedDeletion {
            Task { [weak self] in
                do { try await feedDeletion.resume().value } catch { self?.showError(error) }
            }
        }
        localFolders?.onEvent = { [weak self] event in
            switch event {
            case .stateChanged: break // Original refresh indicator integration remains open.
            case .libraryChanged: self?.reloadLibrary(preservingEpisodeDetails: true)
            case .storageFailed(let message): self?.showNotice(message)
            }
        }
        view.backgroundColor = Appearance.background
        surface.accessibilityIdentifier = "shellSurface"
        surface.clipsToBounds = true
        view.addSubview(surface)
        surface.addSubview(refreshIndicator); refreshIndicator.setRunning(false)
        surface.addSubview(feedPageFooter); feedPageFooter.isHidden = true
        surface.addSubview(feedSelectionBar); feedSelectionBar.isHidden = true
        setUpSubscriptionSelection()
        feedSelectionBar.perform = { [weak self] action in
            guard let self else { return }
            let ids = feedSelection.selected(displayed: feedSelectionIDs)
            guard !feedSelection.ids.isEmpty else { showEpisodeActionMessage(Appearance.text("no_items_selected_message")); return }
            endFeedSelection()
            performEpisodeListAction(action, ids: ids, selection: true)
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLayoutDirection.self]) { (controller: LibraryViewController, _: UITraitCollection) in
            guard controller.queueVisible else { return }
            controller.queueDragController?.cancel()
            controller.renderedSize = .zero
            controller.view.setNeedsLayout()
        }
        feedSelectionBar.moveQueue = { [weak self] boundary in
            guard let self else { return }
            moveQueue(to: boundary, ids: feedSelection.selected(displayed: feedSelectionIDs), bulk: true)
        }
        navigation.backgroundColor = Appearance.navigation
        bottomInset.backgroundColor = Appearance.navigation
        bottomInset.accessibilityIdentifier = "shellBottomStrip"
        content.contentInsetAdjustmentBehavior = .never
        content.delegate = self
        content.panGestureRecognizer.addTarget(self, action: #selector(feedPullChanged(_:)))
        content.accessibilityIdentifier = "libraryContent"
        queueInformationLabel.accessibilityIdentifier = "queueInformation"
        toolbar.accessibilityIdentifier = "mainToolbar"
        queueInformationLabel.textColor = Appearance.secondary
        [content, toolbar, queueInformationLabel, allEpisodesFilterLabel, navigation, bottomInset].forEach(surface.addSubview)
        let toolbarHold = UILongPressGestureRecognizer(target: self, action: #selector(toolbarHeld(_:)))
        toolbarHold.cancelsTouchesInView = false; toolbar.addGestureRecognizer(toolbarHold)
        allEpisodesFilterLabel.text = Appearance.text("filtered_label")
        allEpisodesFilterLabel.textColor = Appearance.secondary
        allEpisodesFilterLabel.accessibilityIdentifier = "allEpisodesFiltered"
        allEpisodesFilterLabel.accessibilityTraits = .button
        allEpisodesFilterLabel.isUserInteractionEnabled = true
        allEpisodesFilterLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showAllEpisodesFilter)))
        if !isPreview, let playback, let timeDisplayPreferences {
            let player = PlayerView(playback: playback, timeDisplayPreferences: timeDisplayPreferences, library: library, intervalPreferences: intervalPreferences, chapterAccess: chapterAccess, shownotesScroll: shownotesScroll ?? .init())
            player.expansionChanged = { [weak self, weak player] in
                guard let self else { return }
                // The person opened the player before a restored expansion: theirs stands.
                if (player?.expansion ?? 0) > 0 { restoredPlayerExpansion = false }
                view.setNeedsLayout()
                view.layoutIfNeeded()
            }
            player.failure = { [weak self] error in self?.showError(error) }
            player.showVideo = { [weak self] in self?.requestVideo() }
            player.favoriteChanged = { [weak self] in
                await self?.reloadLibrary(preservingEpisodeDetails: true)?.value
            }
            player.showShare = { [weak self] feed, episode, anchor in
                self?.presentEpisodeShare(feed: feed, episode: episode, anchor: anchor)
            }
            player.showOverflow = { [weak self] feed, episode, anchor in
                self?.presentPlayerOverflow(feed: feed, episode: episode, anchor: anchor)
            }
            player.showShownotesLinkMenu = { [weak self] link, source in self?.presentShownotesLinkMenu(link, source: source) }
            player.shareShownotesSelection = { [weak self] text, source in self?.presentShownotesSelectionShare(text, source: source) }
            player.openLink = { [weak self] link in self?.openWebsite(link) }
            player.showChapters = { [weak self] in
                guard let self, let library, let chapterAccess, presentedViewController == nil else { return }
                present(ChaptersController(playback: playback, library: library, access: chapterAccess,
                    notice: { [weak self] in self?.showNotice($0) }, failure: { [weak self] in self?.showError($0) },
                    openLink: { [weak self] in self?.openWebsite($0) }), animated: true)
            }
            player.showSpeedDialog = { [weak self] in
                guard let self, let speedPreferences else { return }
                present(PlaybackSpeedController(playback: playback, preferences: speedPreferences), animated: true)
            }
            player.showIntervalDialog = { [weak self] direction in
                guard let self, let intervalPreferences else { return }
                present(PlaybackIntervalController(direction: direction, preferences: intervalPreferences), animated: true)
            }
            player.showSleepTimer = { [weak self] in
                guard let self, let sleepTimerPreferences, let playbackQueuePreferences,
                      presentedViewController == nil else { return }
                present(SleepTimerController(playback: playback, preferences: sleepTimerPreferences,
                    queuePreferences: playbackQueuePreferences, library: library, openPlaybackSettings: { [weak self] in
                        self?.push(.settings(.playback))
                    }), animated: true)
            }
            player.showCast = { [weak self] in
                guard let self, let castRuntime, presentedViewController == nil else { return }
                if let identity = castRuntime.state.identity, castRuntime.state.phase == .connected {
                    present(CastConnectedController(runtime: castRuntime, identity: identity), animated: true)
                } else {
                    present(CastDeviceChooserController(chooser: castRuntime.makeChooser(),
                        tabletDescription: traitCollection.userInterfaceIdiom == .pad,
                        openHelp: { [weak self] in self?.openWebsite($0.absoluteString) }), animated: true)
                }
            }
            castObservation = castRuntime?.observe({ [weak player] in player?.updateCast($0) }, problem: { [weak self] in self?.showPlaybackError($0) })
            player.isHidden = true
            surface.insertSubview(player, belowSubview: navigation)
            playerView = player
            player.useEpisodeCover = usesEpisodeCover
            let events = playback.events()
            sleepTimerWasActive = playback.sleepTimerValue != nil
            personalSleepTimerStarts = SleepTimerController.personalStarts
            playbackEvents = Task { [weak self] in
                do { try await playback.restore() } catch { self?.showError(error) }
                for await event in events {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .stateChanged: noticeSleepTimerAutoEnable(); updatePlayer()
                    // Android's statistics refresh on their own events, not on position saves.
                    case .positionSaved: updatePlayer()
                    case .positionChanged(let update): receivePosition(update)
                    case .libraryChanged: reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true)
                    case .engineFailed(let message): showPlaybackError(message)
                    case .storageFailed: showError(FeedLibraryError.invalidMutation)
                    case .streamingConfirmationRequired: showStreamingConfirmation()
                    case .introSkipped(let seconds):
                        showEpisodeActionMessage(String(format: Appearance.text("pref_feed_skip_intro_toast"), seconds))
                    case .endingSkipped(let seconds):
                        showEpisodeActionMessage(String(format: Appearance.text("pref_feed_skip_ending_toast"), seconds))
                    case .noFollowingEpisode: break
                    }
                }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(episodeSceneDidEnterBackground(_:)),
                                               name: UIScene.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(episodeSceneWillEnterForeground(_:)),
                                               name: UIScene.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(noticeSceneWillDeactivate(_:)),
                                               name: UIScene.willDeactivateNotification, object: nil)
        drawer.onDismiss = { [weak self] in self?.setDrawerOpen(false) }
        drawer.onAction = { [weak self] action in self?.drawerAction(action) }
        drawer.isHidden = true
        surface.addSubview(drawer)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragDrawer(_:)))
        pan.delegate = self
        surface.addGestureRecognizer(pan)
        if let navigationPreferences {
            navigationEvents = Task { [weak self] in
                var previous: NavigationPreferences?
                for await value in navigationPreferences.events() {
                    guard let self, !Task.isCancelled else { return }
                    let layoutChanged = previous == nil || previous?.bottomNavigation != value.bottomNavigation
                        || previous?.configuration != value.configuration
                        || previous?.backButtonOpensDrawer != value.backButtonOpensDrawer
                    let actionChanged = previous?.streamOverDownload != value.streamOverDownload
                    previous = value
                    if actionChanged { updateDownloadRows() }
                    guard layoutChanged else { continue }
                    self.setDrawerOpen(false, animated: false)
                    self.renderedSize = .zero
                    self.view.setNeedsLayout()
                }
            }
        }
        reloadLibrary()
        if let downloads {
            let events = downloads.events()
            downloadEvents = Task { [weak self] in
                do { if self?.isPreview != true { try await downloads.start() } }
                catch { self?.showError(error) }
                for await event in events {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .stateChanged: downloadsChanged()
                    case .libraryChanged: reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true)
                    // The application's DownloadErrorDelivery shows it once, in the visible scene or as a notification.
                    case .attemptFailed: break
                    case .storageError: showError(FeedLibraryError.invalidMutation)
                    }
                }
            }
        }
    }

    isolated deinit { statisticsEvents?.cancel(); subscriptionStatistics?.cancel(); queueDragController?.cancel(); queueMoveTask?.cancel(); inboxSwipeCoordinator?.invalidateLibrary(); inboxSwipeOffers?.dismiss(); navigationEvents?.cancel(); downloadEvents?.cancel(); playbackEvents?.cancel(); noticeTask?.cancel(); notice?.removeFromSuperview(); fetchTask?.cancel(); libraryReload?.cancel() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
#if DEBUG
        QueueGestureFixture.recordControllerEvent("view-did-appear", controller: self)
#endif
        if !recordedStartup {
            recordedStartup = true
            if !isPreview { rememberNavigation(rootNavigationTag) }
            if let startupError { showError(startupError) }
            else if showsFirstLaunchNotice { showFirstLaunchNotice() }
        }
        showMissingLibraryNoticeIfDue()
        messages.resume()
        opmlImportFlow?.presentPendingDocument()
        consumePendingExternalRoute()
    }

    /// Android PlaybackService posts "Sleep timer enabled" with Undo when it auto-enables the timer as playback
    /// starts; MainActivity shows it as a long snackbar while visible (a stopped activity misses it).
    func noticeSleepTimerAutoEnable() {
        guard let playback else { return }
        let active = playback.sleepTimerValue != nil
        defer { sleepTimerWasActive = active }
        guard active, !sleepTimerWasActive else { return }
        if SleepTimerController.personalStarts != personalSleepTimerStarts {
            personalSleepTimerStarts = SleepTimerController.personalStarts; return
        }
        guard UIApplication.shared.applicationState == .active, view.window != nil,
              Self.lastSleepTimerNotice.map({ Date().timeIntervalSince($0) > 1 }) ?? true else { return }
        Self.lastSleepTimerNotice = Date()
        showSnackbar(Appearance.text("sleep_timer_enabled_label"), action: .init(title: Appearance.text("undo"),
            identifier: "sleepTimerEnabledUndo") { [weak self, weak playback] in
                Task { do { try await playback?.disableSleepTimer() } catch { self?.showError(error) } }
            })
    }
    private static var lastSleepTimerNotice: Date?

    /// Playback and download changes received in the background were not drawn; show the current state once.
    @objc func applicationDidBecomeActive() {
        if let request = backgroundReload {
            backgroundReload = nil
            reloadLibrary(preservingEpisodeDetails: request.preservingEpisodeDetails,
                          keepsUnchangedScreen: request.keepsUnchangedScreen)
        }
        guard backgroundUpdatePending else { return }
        backgroundUpdatePending = false
        updatePlayer()
        downloadsChanged()
    }

    /// A download started, progressed or ended: the Downloads list gains or loses rows, other rows update their button.
    private func downloadsChanged() {
        guard UIApplication.shared.applicationState != .background else { backgroundUpdatePending = true; return }
        // Progress alone never changes which rows Downloads lists: the list is checked only when the jobs or
        // the library changed since the last check.
        if case .destination(.downloads) = path.last {
            let check = (jobs: downloads?.jobs ?? [], library: libraryRevision)
            if check.jobs != downloadsRowsCheck?.jobs || check.library != downloadsRowsCheck?.library {
                downloadsRowsCheck = check
                if downloadsRows().map({ $0.1.id }) != displayedEpisodeIDs {
                    reloadLibrary(preservingEpisodeDetails: true); return
                }
            }
        }
        updateDownloadRows()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let readingPosition = pendingReadingPosition ?? captureReadingPosition()
        let horizontalSafeArea = view.safeAreaLayoutGuide.layoutFrame
        surface.frame = CGRect(x: horizontalSafeArea.minX, y: view.bounds.minY,
                               width: horizontalSafeArea.width, height: view.bounds.height)
        if let initialWindowSize, initialWindowSize != view.bounds.size { afterConfigurationChange = true }
        else if initialWindowSize == nil && view.bounds.width > 0 { initialWindowSize = view.bounds.size }
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let drawerLayout = DrawerLayout(size: surface.bounds.size, topInset: view.safeAreaInsets.top,
            bottomInset: view.safeAreaInsets.bottom, persistent: persistentDrawer,
            rightToLeft: rtl, afterConfigurationChange: afterConfigurationChange)
        let sidebarWidth = persistentDrawer && !settingsVisible ? min(surface.bounds.width, drawerLayout.panel.width + 1) : 0
        let origin = sidebarWidth > 0 && !rtl ? sidebarWidth : 0
        let width = max(0, surface.bounds.width - sidebarWidth)
        let layout = ShellLayout(size: CGSize(width: width, height: surface.bounds.height), topInset: view.safeAreaInsets.top,
            bottomInset: view.safeAreaInsets.bottom, playerVisible: !isPreview && playback?.episode != nil && !settingsVisible,
            bottomNavigation: bottomNavigationEnabled && !settingsVisible,
            informationHeight: queueVisible ? max(16.4, queueInformationLabel.sizeThatFits(CGSize(width: max(1, width - (path.count > 1 || !bottomNavigationEnabled ? 120 : 32)), height: .greatestFiniteMagnitude)).height) : 0)
        toolbar.frame = layout.toolbar.offsetBy(dx: origin, dy: 0)
        let infoPadding: CGFloat = path.count > 1 || !bottomNavigationEnabled ? 60 : 16
        queueInformationLabel.frame = layout.information.offsetBy(dx: origin, dy: 0).insetBy(dx: min(infoPadding, width / 2), dy: 0)
        queueInformationLabel.isHidden = !queueVisible || !queuePolicy.showsInformation
        content.frame = layout.content.offsetBy(dx: origin, dy: 0)
        // episodes_list_fragment.xml: -16 top margin and four points of vertical padding.
        // Selection makes the information invisible but keeps its occupied space.
        let filtered = allEpisodesVisible && allEpisodesFilter.effective.isActive
        if filtered {
            let textHeight = allEpisodesFilterLabel.sizeThatFits(CGSize(width: max(1, width - infoPadding * 2), height: .greatestFiniteMagnitude)).height
            let y = max(toolbar.frame.minY, toolbar.frame.maxY - 16)
            let height = min(textHeight + 8, max(0, layout.miniPlayer.minY - y))
            allEpisodesFilterLabel.frame = CGRect(x: origin + infoPadding, y: y + 4, width: max(0, width - infoPadding * 2), height: max(0, height - 8))
            let top = max(toolbar.frame.maxY, y + height)
            content.frame = CGRect(x: origin, y: top, width: width, height: max(0, layout.miniPlayer.minY - top))
        }
        allEpisodesFilterLabel.isHidden = !filtered || feedSelection.active
        navigation.frame = layout.navigation.offsetBy(dx: origin, dy: 0)
        navigation.isHidden = !bottomNavigationEnabled || settingsVisible
        bottomInset.frame = CGRect(x: 0, y: layout.bottomInset.minY, width: surface.bounds.width, height: layout.bottomInset.height)
        let modalDrawer = !persistentDrawer && drawerFraction > 0 && !settingsVisible
        if let playerView {
            let y = layout.miniPlayer.minY * (1 - playerView.expansion)
            playerView.expandedSize = CGSize(width: width, height: layout.navigation.minY)
            playerView.topInset = view.safeAreaInsets.top
            playerView.frame = CGRect(x: origin, y: y, width: width, height: max(0, layout.navigation.minY - y))
            playerView.isHidden = settingsVisible || playback?.episode == nil
            playerView.accessibilityElementsHidden = modalDrawer
            playerView.setNeedsLayout()
        }
        let playerCoversContent = playerView?.isHidden == false && (playerView?.expansion ?? 0) > 0
        content.accessibilityElementsHidden = modalDrawer || playerCoversContent
        toolbar.accessibilityElementsHidden = content.accessibilityElementsHidden
        queueInformationLabel.accessibilityElementsHidden = content.accessibilityElementsHidden
        allEpisodesFilterLabel.accessibilityElementsHidden = content.accessibilityElementsHidden
        layoutNotice()
        refreshProgressChanged()
        layoutSynchronizationSnackbar()
        layoutInboxSwipeSnackbar()
        drawer.frame = surface.bounds
        drawer.layout = drawerLayout
        drawer.fraction = persistentDrawer ? 1 : drawerFraction
        drawer.isHidden = bottomNavigationEnabled || settingsVisible || (!persistentDrawer && drawerFraction == 0)
        if renderedSize != content.bounds.size {
            popup?.removeFromSuperview()
            popup = nil
            renderedSize = content.bounds.size
            pendingReadingPosition = readingPosition
            render()
        }
        layoutPopup?()
        for (index, button) in navigation.subviews.enumerated() {
            if let frame = layout.navigationItem(at: index, count: configuration.bottomBarActions.count,
                                                 rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft) {
                button.frame = frame.offsetBy(dx: 0, dy: -layout.navigation.minY)
            }
        }
        updateEpisodeDetailsCover()
    }

    /// One library reload request; requests made while a reload runs merge into one follow-up.
    struct LibraryReloadRequest {
        var preservingEpisodeDetails: Bool
        var reconcilingPresentation: UUID?
        var mutationRevision: UInt64
        /// An event-driven reload (playback or download change) may keep a list screen whose data did not change.
        var keepsUnchangedScreen: Bool

        /// The merged request does what both would: render unless both preserve the episode page, apply
        /// unconditionally unless both are guarded reconciliations (the later guard wins).
        func merged(with later: Self) -> Self {
            let guarded = reconcilingPresentation != nil && later.reconcilingPresentation != nil
            return .init(preservingEpisodeDetails: preservingEpisodeDetails && later.preservingEpisodeDetails,
                         reconcilingPresentation: guarded ? later.reconcilingPresentation : nil,
                         mutationRevision: later.mutationRevision,
                         keepsUnchangedScreen: keepsUnchangedScreen && later.keepsUnchangedScreen)
        }
    }

    /// Reads the library and redraws the visible screen.
    /// - A request made while a reload runs does not restart it: the requests merge into one follow-up reload
    ///   that starts after them, and a superseded result is not drawn. A play tap's several change events
    ///   therefore cost one or two reads and one redraw.
    /// - Nothing is read or drawn while the app is in the background; one reload runs when it becomes active.
    /// - The returned task finishes after a reload that started after this call has been applied.
    @discardableResult
    func reloadLibrary(preservingEpisodeDetails: Bool = false, reconcilingPresentation: UUID? = nil,
                       keepsUnchangedScreen: Bool = false) -> Task<Void, Never>? {
        guard let loadSnapshot else { return nil }
        let request = LibraryReloadRequest(preservingEpisodeDetails: preservingEpisodeDetails,
            reconcilingPresentation: reconcilingPresentation, mutationRevision: actionMutationRevision,
            keepsUnchangedScreen: keepsUnchangedScreen)
        if applicationInBackground() {
            backgroundReload = backgroundReload.map { $0.merged(with: request) } ?? request
            return nil
        }
        pendingLibraryReload = pendingLibraryReload.map { $0.merged(with: request) } ?? request
        libraryReloadRequests &+= 1
        let target = libraryReloadRequests
        if libraryReload == nil { startLibraryReload(loadSnapshot) }
        return Task { [weak self] in await self?.waitForLibraryReload(target) }
    }

    private func waitForLibraryReload(_ target: UInt64) async {
        while libraryReloadsApplied < target, let running = libraryReload { await running.value }
    }

    /// Runs reloads until no request is pending. A result read while a newer request waits is not drawn;
    /// its request merges into the newer one, so nothing it should have shown is lost.
    private func startLibraryReload(_ loadSnapshot: @escaping @Sendable () async throws -> FeedLibrarySnapshot) {
        libraryReload = Task { [weak self] in
            while let next = self?.takePendingLibraryReload() {
                let (request, covered) = next
                let result: Result<FeedLibrarySnapshot, any Error>
                do { result = .success(try await loadSnapshot()) } catch { result = .failure(error) }
                guard let self, !Task.isCancelled else { return }
                if let newer = pendingLibraryReload { pendingLibraryReload = request.merged(with: newer); continue }
                applyLibraryReload(result, request: request)
                libraryReloadsApplied = covered
            }
            self?.libraryReload = nil
        }
    }

    private func takePendingLibraryReload() -> (LibraryReloadRequest, UInt64)? {
        guard let request = pendingLibraryReload else { return nil }
        pendingLibraryReload = nil
        return (request, libraryReloadRequests)
    }

    private func applyLibraryReload(_ result: Result<FeedLibrarySnapshot, any Error>, request: LibraryReloadRequest) {
        if let reconcilingPresentation = request.reconcilingPresentation {
            guard actionPresentation == reconcilingPresentation,
                  actionMutationRevision == request.mutationRevision else { return }
        }
        let snapshot: FeedLibrarySnapshot
        switch result {
        case .success(let value): snapshot = value
        case .failure(let error): showError(error); return
        }
        // D-shell 5: a playback or download event that changed nothing this list shows keeps the list as it is.
        if request.keepsUnchangedScreen, request.reconcilingPresentation == nil, libraryLoaded, showsOnlyLibraryData,
           snapshot.feeds == feeds, snapshot.queue == queuedEpisodes, snapshot.deletionTargets == deletionTargets {
            updateDownloadRows()
            updatePlayer()
            forwardReloadToPreview(preservingEpisodeDetails: request.preservingEpisodeDetails, keepsUnchangedScreen: true)
            return
        }
        if case .search(let search) = path.last {
            if request.reconcilingPresentation != nil {
                searchNeedsReload = false; search.session.reconcileCurrentData()
            } else if !libraryLoaded || snapshot.feeds != feeds || snapshot.deletionTargets != deletionTargets {
                // Results can change only with the library.
                searchNeedsReload = true
            }
        } else { retireActionPresentation() }
        feeds = snapshot.feeds; libraryLoaded = true
        statisticsUnits = snapshot.statisticsUnits
        deletionTargets = snapshot.deletionTargets
        queuedEpisodes = snapshot.queue
        // A restored stack drops what the library no longer has before anything is drawn from it, and a remembered
        // start page that is gone gives way.
        let restoredStackChanged = checkRestoredNavigation() || checkStartPage()
        feedInformation?.refreshStatistics()
        if statisticsActive, statisticsVisible { refreshSubscriptionStatistics() }
        if !restoredStackChanged, request.preservingEpisodeDetails, case .episode(_, let id) = path.last,
           episodeDetailsID == id, libraryEpisode(id) != nil {
            updateDownloadRows(); refreshNavigationCounters()
        }
        else { render() }
        updatePlayer()
        forwardReloadToPreview(preservingEpisodeDetails: request.preservingEpisodeDetails, keepsUnchangedScreen: request.keepsUnchangedScreen)
    }

    private func forwardReloadToPreview(preservingEpisodeDetails: Bool, keepsUnchangedScreen: Bool) {
        if let preview = presentedViewController as? FeedPreviewController,
           let child = preview.contentController as? LibraryViewController {
            child.reloadLibrary(preservingEpisodeDetails: preservingEpisodeDetails, keepsUnchangedScreen: keepsUnchangedScreen)
        }
    }

    /// Screens drawn only from the library, the queue and settings (not from download jobs, search results,
    /// statistics or an open episode), which an unchanged library leaves exactly as they are.
    private var showsOnlyLibraryData: Bool {
        switch path.last {
        case .destination(.home), .destination(.subscriptions), .destination(.subscriptionList), .destination(.queue),
             .destination(.inbox), .destination(.favorites), .destination(.history), .destination(.episodes),
             .archive, .feed: true
        default: false
        }
    }

    func select(_ destination: NavigationDestination) { selectTag(destination.rawValue) }

    /// Notification PendingIntent clears the source activity stack and opens a
    /// feed root or Inbox. Shared playback remains application-owned.
    func openNotification(_ destination: EpisodeNotificationDestination) async {
        let route = UUID(); notificationRouteID = route
        // The notification decides what shows: a restored player does not expand after it.
        restoredPlayerExpansion = false
        loadViewIfNeeded()
        dismiss(animated: false)
        popup?.removeFromSuperview(); popup = nil
        await reloadLibrary()?.value
        guard notificationRouteID == route else { return }
        switch destination {
        case .inbox: drawerAction(.destination(.inbox))
        case .feed(let id): drawerAction(.feed(id))
        }
    }

    func selectTag(_ tag: String) {
        let destination = NavigationDestination(rawValue: tag).flatMap { $0 == .subscriptionList ? nil : $0 } ?? .home
        rootNavigationTag = tag
        playerView?.setExpanded(false, animated: false)
        fetchTask?.cancel()
        rootDestination = destination
        cancelSearches()
        path = [.destination(destination)]
        episodePaging = ("", 1)
        parentReadingPositions.removeAll()
        pendingReadingPosition = .offset(0)
        rememberNavigation(tag)
        leaveLazyContent()
        content.setContentOffset(.zero, animated: false)
        renderAfterLayout()
    }

    /// MainActivity.loadFragment for a screen without a navigation item (Discover): clears the
    /// stack, replaces the root and saves the tag as the last page.
    func loadRootScreen(_ screen: Screen, tag: String) {
        rootNavigationTag = tag
        playerView?.setExpanded(false, animated: false)
        fetchTask?.cancel()
        cancelSearches()
        path = [screen]
        episodePaging = ("", 1)
        parentReadingPositions.removeAll()
        pendingReadingPosition = .offset(0)
        rememberNavigation(tag)
        leaveLazyContent()
        content.setContentOffset(.zero, animated: false)
        renderAfterLayout()
    }
    /// What system Back does on a root screen (NavigationBackPolicy); the Discover arrow
    /// uses it instead of the source's inert popBackStack. Where Android would leave the app,
    /// the arrow opens Home, the page a relaunch shows.
    func performRootBack() {
        let action = NavigationBackPolicy.action(preferences: navigationPreferences?.value ?? .init(),
            rootTag: rootNavigationTag, childDepth: 0, playerExpanded: false, drawerOpen: false,
            persistentDrawer: persistentDrawer)
        switch action {
        case .openDefault(let tag): selectTag(tag)
        case .openDrawer: setDrawerOpen(true)
        default: selectTag(NavigationDestination.home.rawValue)
        }
    }

    func push(_ screen: Screen) {
        view.endEditing(true)
        parentReadingPositions.append(pendingReadingPosition ?? captureReadingPosition())
        pendingReadingPosition = .offset(0)
        path.append(screen)
        leaveLazyContent()
        content.setContentOffset(.zero, animated: false)
        renderAfterLayout()
    }

    /// Draws the screen now in `path` after the shell has laid it out, so a screen whose content area differs
    /// (the Queue information line) is drawn once instead of drawn and then redrawn at its new size.
    private func renderAfterLayout() {
        let rendered = renderCount
        view.setNeedsLayout(); view.layoutIfNeeded()
        if renderCount == rendered { render() }
    }

    /// Removes the top screen as Back does and restores the parent's reading position; used while rendering.
    func popToParent() {
        guard path.count > 1 else { return }
        path.removeLast()
        pendingReadingPosition = parentReadingPositions.popLast() ?? .offset(0)
    }

    /// Shows a restored stack, root first, as if the person had opened each screen: every parent at its top, the
    /// root's tag and destination as they were (the last page is not saved again). It is checked against the library
    /// at its first read, or now if the library is already read.
    func applyRestoredStack(_ screens: [Screen], rootTag: String, rootDestination: NavigationDestination,
                            pagers: [Int: EpisodePagerState]) {
        guard !screens.isEmpty else { return }
        restoringNavigation = true
        rootNavigationTag = rootTag
        self.rootDestination = rootDestination
        path = screens
        // After `path`, whose observer keeps only the pagers of the screens it had.
        episodePagers = pagers
        parentReadingPositions = Array(repeating: .offset(0), count: screens.count - 1)
        pendingReadingPosition = .offset(0)
        episodePaging = ("", 1)
        restoringNavigation = false
        restoredNavigationNeedsCheck = true
        startPageNeedsCheck = false
        if libraryLoaded { checkRestoredNavigation() }
        guard isViewLoaded else { return }
        leaveLazyContent()
        content.setContentOffset(.zero, animated: false)
        renderAfterLayout()
    }

    /// The first library read after a restoration: a screen whose podcast or episode no longer exists is left out,
    /// so the nearest screen that still exists shows; a root podcast that is gone gives way to the start page, as a new
    /// window opens. Returns whether the stack changed. The restored player then expands.
    @discardableResult private func checkRestoredNavigation() -> Bool {
        guard restoredNavigationNeedsCheck else { return false }
        restoredNavigationNeedsCheck = false
        // Then the restored screens that read the library start, and the player expands.
        defer { startRestoredScreens(); expandRestoredPlayer() }
        func exists(_ screen: Screen) -> Bool {
            switch screen {
            case .feed(let id), .feedInformation(let id), .feedSettings(let id): feeds.contains { $0.id == id }
            case .episode(let feedID, let id): feeds.first { $0.id == feedID }?.episodes.contains { $0.id == id } == true
            case .search(let search): search.session.feedID.map { id in feeds.contains { $0.id == id } } ?? true
            default: true
            }
        }
        let kept = path.indices.filter { exists(path[$0]) }
        guard kept.count < path.count else { return false }
        restoringNavigation = true
        defer { restoringNavigation = false }
        for index in path.indices where !kept.contains(index) {
            if case .search(let search) = path[index] { search.session.cancel() }
        }
        guard kept.first == 0 else {
            // The start page, chosen as a new window chooses it.
            let start = startPage(existing: feeds)
            rootNavigationTag = start.tag; rootDestination = start.destination; path = [start.screen]
            if !isPreview { rememberNavigation(start.tag) }
            episodePagers = [:]
            parentReadingPositions = []
            pendingReadingPosition = .offset(0)
            return true
        }
        let pagers = Dictionary(uniqueKeysWithValues: kept.enumerated().compactMap { position, index in
            episodePagers[index].map { (position, $0) }
        })
        let positions = kept.dropLast().map { parentReadingPositions.indices.contains($0) ? parentReadingPositions[$0] : .offset(0) }
        if kept.last != path.count - 1 {
            pendingReadingPosition = parentReadingPositions.indices.contains(kept.last!) ? parentReadingPositions[kept.last!] : .offset(0)
        }
        path = kept.map { path[$0] }
        episodePagers = pagers
        parentReadingPositions = positions
        return true
    }

    /// The page a new window opens (`MainActivity.onCreate`): the default page, or the remembered one. A remembered
    /// podcast that no longer exists in `feeds` (when they are known) gives way to Home, as a remembered page that is
    /// not a page does, instead of an empty page.
    private func startPage(existing feeds: [LibraryFeed]?) -> (tag: String, destination: NavigationDestination, screen: Screen) {
        let preferences = navigationPreferences?.value ?? .init()
        switch preferences.startupRoute {
        case .feed(let feed) where feeds?.contains(where: { $0.id == feed }) == false:
            return (NavigationDestination.home.rawValue, .home, .destination(.home))
        case .feed(let feed): return (preferences.startupTag, .subscriptions, .feed(feed))
        case .destination(let destination): return (preferences.startupTag, destination, .destination(destination))
        }
    }

    /// The first library read of a window that opened on a remembered podcast: if the podcast is gone and the window
    /// still shows it, Home opens and is remembered. Returns whether the stack changed.
    private func checkStartPage() -> Bool {
        guard startPageNeedsCheck else { return false }
        startPageNeedsCheck = false
        guard path.count == 1, case .feed(let id) = path[0], rootNavigationTag == String(id),
              !feeds.contains(where: { $0.id == id }) else { return false }
        let start = startPage(existing: feeds)
        restoringNavigation = true
        rootNavigationTag = start.tag; rootDestination = start.destination; path = [start.screen]
        restoringNavigation = false
        pendingReadingPosition = .offset(0)
        if !isPreview { rememberNavigation(start.tag) }
        return true
    }

    func render() {
        guard isViewLoaded, content.bounds.width > 0 else { return }
        renderCount &+= 1
        // Before any pager is attached: notes behind the expanded player must not count as shown (Back from Settings).
        syncEpisodeContentCover()
        queueDragController?.cancel(); queueDragController = nil; queuePresentationID = UUID()
        renderingContent = true
        defer { renderingContent = false; updateFeedSelection(); updateSubscriptionSelection() }
        closeMissingEpisodePager()
        let readingPosition = pendingReadingPosition ?? captureReadingPosition()
        pendingReadingPosition = nil
        if case .episode(let index, _) = readingPosition { minimumEpisodeRowCount = index + 1 } else { minimumEpisodeRowCount = 0 }
        remainingEpisodeRows = nil
        feedScrimAnimator?.stopAnimation(true); feedScrimAnimator = nil
        feedAppBar = nil
        feedPageFooter.isHidden = true
        feedPageFooter.onLoad = nil
        content.layer.mask = nil; content.clipsToBounds = true; content.bounces = true
        toolbar.backgroundColor = .clear
        toolbar.accessibilityElements = nil
        let retainedQuery: UITextField?
        switch path.last { case .search(let search): retainedQuery = search.field
        case .onlineSearch(let search): retainedQuery = search.field
        default: retainedQuery = nil }
        toolbar.subviews.filter { $0 !== retainedQuery }.forEach { $0.removeFromSuperview() }
        // A pager being swiped stays in place so the swipe is not cancelled.
        let retainedPager = visibleEpisodePager?.view
        // The visible Settings search page keeps its field (and keyboard) across re-renders.
        let retainedSettingsSearch: UIView? = if case .settingsSearch(let search) = path.last { search } else { nil }
        content.subviews.filter { $0 !== retainedPager && $0 !== retainedSettingsSearch }.forEach { $0.removeFromSuperview() }
        episodeRows.removeAll(); homeCards.removeAll(); homeRowScopes.removeAll()
        episodeList = nil; subscriptionGrid = nil; displayedEpisodeValues.removeAll()
        navigation.subviews.forEach { $0.removeFromSuperview() }
        content.contentSize = content.bounds.size
        content.isScrollEnabled = true
        content.alwaysBounceVertical = currentRefreshScope != nil
        let current = path.last!
        let discoverRoot: Bool = if case .discover = current { true } else { false }
        if case .destination(.addPodcast) = current {} else { addPodcastScreen.left() }
        if case .episode = current, let pager = visibleEpisodePager, let page = pager.pages[pager.model.index] {
            episodeHeader = page.header; episodeHeaderScroll = page.headerScroll
            episodeNotes = page.notes; episodeDetailsID = page.episodeID
        } else {
            episodeHeader = nil; episodeNotes = nil; episodeDetailsID = nil
            episodeHeaderScroll = UIScrollView()
        }
        releaseHiddenEpisodeNeighbours()
        updateQueueInformation()
        var title = Appearance.title(for: rootDestination)
        switch current {
        case .destination(let destination): title = Appearance.title(for: destination)
        case .feed, .feedInformation, .episode, .search, .onlineSearch: title = ""
        case .discover: title = Appearance.text("discover")
        case .feedSettings: title = Appearance.text("feed_settings_label")
        case .settings(let page): title = Appearance.text(page.titleKey)
        case .archive: title = Appearance.text("archive_feed_label_noun")
        // The search page is added over the Settings screen; the toolbar keeps "Settings".
        case .settingsSearch: title = Appearance.text("settings_label")
        }
        let heading = Appearance.label(title, size: 24)
        heading.accessibilityIdentifier = "screenTitle"
        heading.numberOfLines = 1
        heading.lineBreakMode = .byTruncatingTail
        heading.textAlignment = .natural
        let toolbarLayout = toolbarLayout(hasOverflow: false)
        heading.frame = toolbarLayout.title
        toolbar.addSubview(heading)
        if synchronizationVisible, let text = synchronizationSettings?.subtitle {
            let subtitle = Appearance.label(text, size: 12)
            subtitle.accessibilityIdentifier = "synchronizationStatus"
            subtitle.numberOfLines = 1; subtitle.lineBreakMode = .byTruncatingTail
            subtitle.frame = CGRect(x: heading.frame.minX, y: heading.frame.maxY - 20, width: heading.frame.width, height: 20)
            heading.frame.size.height = max(0, heading.frame.height - 20)
            toolbar.addSubview(subtitle)
        }
        if (path.count > 1 || isPreview) && !discoverRoot {
            let backIcon = isPreview && path.count == 1 ? "ic_close" : "abc_ic_ab_back_material"
            let back = Appearance.icon(backIcon, label: Appearance.text("toolbar_back_button_content_description")) { [weak self] in self?.goBack() }
            back.configuration?.image = UIImage(named: backIcon)?.imageFlippedForRightToLeftLayoutDirection()
            back.accessibilityIdentifier = "toolbarBack"
            back.frame = toolbarLayout.navigation
            toolbar.addSubview(back)
        }
        if !isPreview && path.count == 1 && !bottomNavigationEnabled && !persistentDrawer && !discoverRoot {
            let menu = DrawerMenuButton(type: .custom)
            menu.accessibilityLabel = Appearance.text("drawer_open")
            menu.accessibilityIdentifier = "openDrawer"
            menu.frame = toolbarLayout.navigation
            menu.addAction(UIAction { [weak self] _ in self?.setDrawerOpen(true) }, for: .touchUpInside)
            toolbar.addSubview(menu)
        }
        // BottomNavigation.updateSelectedItem selects More for a screen without a bottom item.
        let selected = discoverRoot ? .more : configuration.selectedBottomAction(for: rootDestination)
        for action in configuration.bottomBarActions {
            let destination: NavigationDestination? = if case .destination(let value) = action { value } else { nil }
            let title = destination.map(Appearance.title) ?? Appearance.text("overflow_more")
            let button = NavigationButton(title: title, image: destination.map(Appearance.icon) ?? "dots_vertical", selected: selected == action) { [weak self] in
                if let destination { self?.select(destination) } else { self?.showMore() }
            }
            button.accessibilityIdentifier = destination?.rawValue ?? "navigationMore"
            if destination == .inbox { button.badgeCount = NavigationCounters.inbox(feeds) }
            navigation.addSubview(button)
        }
        switch current {
        case .destination(.home): renderHome(heading: heading)
        case .destination(.addPodcast): addPodcast()
        case .destination(.subscriptions), .destination(.subscriptionList): renderSubscriptions(heading: heading, archived: false)
        case .archive: renderSubscriptions(heading: heading, archived: true)
        case .destination(.queue):
            renderQueueToolbar(heading: heading)
            feedSelectionIDs = queuedEpisodes.map(\.id)
            if queuedEpisodes.isEmpty { feedSelection.end(); selectionScope = nil }
            if queuedEpisodes.isEmpty { empty(title: "no_items_header_label", message: "no_items_label") }
            else {
                episodes(queuedEpisodes.compactMap { episode in libraryEpisode(episode.id).map { ($0.feed, episode) } })
            }
        case .destination(.inbox): renderInbox(heading: heading)
        case .destination(.favorites): renderFavorites(heading: heading)
        case .destination(.downloads): renderDownloads(heading: heading)
        case .destination(.history): renderHistory(heading: heading)
        case .destination(.episodes): renderAllEpisodes(heading: heading)
        case .destination(.statistics): renderStatistics(heading: heading)
        case .settings(let page): renderPreferences(page)
        case .search(let search): renderSearch(search)
        case .onlineSearch(let search): renderOnlineSearch(search)
        case .discover(let discover): renderDiscover(discover, heading: heading)
        case .settingsSearch(let search): renderSettingsSearch(search)
        case .feed(let id): if let feed = feeds.first(where: { $0.id == id }) { feedScreen(feed) }
        case .feedInformation(let id):
            if let feed = feeds.first(where: { $0.id == id }) { informationScreen(feed) }
        case .feedSettings(let id):
            if let feed = feeds.first(where: { $0.id == id }) { feedSettingsScreen(feed) }
        case .episode(let feedID, let id):
            if let feed = feeds.first(where: { $0.id == feedID }), let episode = feed.episodes.first(where: { $0.id == id }) { episodeScreen(feed, episode) }
        }
        rebuildDrawer()
        if let feedAppBar { content.contentSize.height = max(content.contentSize.height, content.bounds.height + feedAppBar.fullHeaderHeight) }
        feedContentHeight = content.contentSize.height
        restoreReadingPosition(readingPosition)
        loadNextEpisodePageIfNeeded()
        updateFeedAppBar(animated: false)
        updateVisibleContent()
        let layout = ShellLayout(size: CGSize(width: toolbar.bounds.width, height: surface.bounds.height), topInset: view.safeAreaInsets.top,
            bottomInset: view.safeAreaInsets.bottom, bottomNavigation: bottomNavigationEnabled && !settingsVisible)
        for (index, button) in navigation.subviews.enumerated() {
            button.frame = layout.navigationItem(at: index, count: configuration.bottomBarActions.count,
                                                  rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)!.offsetBy(dx: 0, dy: -layout.navigation.minY)
        }
    }

    /// Source drawer and bottom navigation reload their counters on every FeedItemEvent,
    /// FeedListUpdateEvent and QueueEvent, also while a screen keeps its own content (episode details).
    func refreshNavigationCounters() {
        rebuildDrawer()
        let inbox = NavigationCounters.inbox(feeds)
        navigation.subviews.lazy.compactMap { $0 as? NavigationButton }
            .first { $0.accessibilityIdentifier == NavigationDestination.inbox.rawValue }?.badgeCount = inbox
    }

    private func rebuildDrawer() {
        // With bottom navigation the drawer is never shown; it is built when the drawer layout returns (that
        // change re-renders the screen). Building it anyway cost every render a row per subscription.
        guard !bottomNavigationEnabled else { drawerSignature = nil; return }
        let destinations = configuration.visibleDrawerItems.filter { $0 != .subscriptionList }
        // The drawer uses the Subscriptions order, counter and filter (NavDrawerFragment.getNavDrawerData).
        let preferences = subscriptionDisplay
        let data = SubscriptionListQueries.load(feeds, preferences: preferences, state: .subscribed, globalAutoDownload: globalAutoDownload)
        // Queue, Inbox (subscribed feeds only) and Subscriptions counters, as NavDrawerData counts them.
        let counters = NavigationCounters(feeds: feeds, queueLength: queuedEpisodes.count, feedCounters: data.counters)
        let items = destinations.map { destination -> NavigationDrawerView.Item in
            var count = 0
            if destination == .queue { count = counters.queue }
            if destination == .inbox { count = counters.inbox }
            // Subscriptions entry: the sum of every subscribed feed's counter (unfiltered).
            if destination == .subscriptions { count = counters.subscriptions }
            let selected = rootNavigationTag == destination.rawValue
            return .init(action: .destination(destination), title: Appearance.title(for: destination), image: Appearance.icon(for: destination),
                         count: count, selected: selected, identifier: "drawer-" + destination.rawValue)
        }
        var subscriptionItems: [NavigationDrawerView.Item] = []
        let showsList = configuration.visibleDrawerItems.contains(.subscriptionList)
        if showsList {
            func feedItem(_ feed: LibraryFeed, layer: Int) -> NavigationDrawerView.Item {
                .init(action: .feed(feed.id), title: feed.title ?? "", image: nil, count: data.counters[feed.id, default: 0],
                      selected: rootNavigationTag == String(feed.id), artwork: feed.metadata.imageURL,
                      identifier: layer == 0 ? "drawer-feed-\(feed.id)" : "drawer-folder-feed-\(feed.id)", layer: layer,
                      contextMenu: { [weak self] anchor in
                          self?.showFeedContextMenu(feed.id, origin: .drawer, anchor: anchor, fraction: CGPoint(x: 0.5, y: 0.5))
                      })
            }
            subscriptionItems = data.rootFeeds.map { feedItem($0, layer: 0) }
            // makeFlatDrawerData: one folder row per tag except #root/#untagged; open folders list their feeds.
            let open = Set(preferences.openFolders.map { Array($0.utf16) })
            for folder in data.folders where !FeedTags.equal(folder.title, FeedTags.root) && !FeedTags.equal(folder.title, FeedTags.untagged) {
                let isOpen = open.contains(Array(folder.title.utf16))
                let total = folder.feeds.reduce(0) { $0 + data.counters[$1.id, default: 0] }
                subscriptionItems.append(.init(action: .folder(folder.title), title: folder.title, image: "ic_tag", count: isOpen ? 0 : total,
                                               identifier: "drawer-folder-" + folder.title,
                                               contextMenu: { [weak self] anchor in self?.showTagMenu(folder.title, state: .subscribed, anchor: anchor) }))
                if isOpen { subscriptionItems += folder.feeds.map { feedItem($0, layer: 1) } }
            }
        }
        // Every screen render rebuilt one drawer row per subscription; with hundreds of subscriptions that cost
        // a noticeable part of each list opening. Unchanged rows are kept.
        let filtered = showsList && preferences.filter.isEnabled
        let signature = (items + subscriptionItems).map { item in
            [item.identifier, item.title, item.image ?? "", String(item.count), String(item.selected), item.artwork ?? "",
             String(item.layer), String(item.contextMenu != nil)].joined(separator: "\u{1F}")
        } + [String(filtered), traitCollection.preferredContentSizeCategory.rawValue,
             String(view.effectiveUserInterfaceLayoutDirection.rawValue)]
        guard signature != drawerSignature else { return }
        drawerSignature = signature
        drawer.update(items: items, subscriptionItems: subscriptionItems, showSeparator: !items.isEmpty,
                      filtered: filtered, library: library)
    }

    func drawerAction(_ action: NavigationDrawerView.Action) {
        if case .customize = action { showNavigationCustomization(fromDrawer: true); return }
        // NavDrawerFragment starts PreferenceActivity without closing its drawer.
        // Hide the retained drawer behind Settings and restore it when returning.
        if case .settings = action { push(.settings(.main)); return }
        if case .folder(let title) = action {
            updateSubscriptionDisplay(rerender: false) { value in
                if let index = value.openFolders.firstIndex(where: { FeedTags.equal($0, title) }) { value.openFolders.remove(at: index) }
                else { value.openFolders.append(title) }
            }
            rebuildDrawer(); return
        }
        if case .filter = action { showSubscriptionsFilter(); return }
        setDrawerOpen(false, animated: false)
        switch action {
        case .destination(let destination): select(destination)
        case .feed(let id):
            playerView?.setExpanded(false, animated: false)
            fetchTask?.cancel()
            rootDestination = .subscriptions
            rootNavigationTag = String(id)
            cancelSearches()
            path = [.feed(id)]
            episodePaging = ("", 1)
            parentReadingPositions.removeAll()
            pendingReadingPosition = .offset(0)
            rememberNavigation(String(id))
            leaveLazyContent()
            content.setContentOffset(.zero, animated: false)
            render()
        case .settings, .customize, .folder, .filter: break
        }
        view.setNeedsLayout()
    }

    private func setDrawerOpen(_ open: Bool, animated: Bool = true, velocity: CGFloat = 0) {
        drawerAnimator.cancel()
        guard !persistentDrawer else { drawerFraction = 0; view.setNeedsLayout(); return }
        let initial = drawerFraction
        let target: CGFloat = open ? 1 : 0
        let width = drawer.layout?.panel.width ?? surface.bounds.width
        let duration = animated && !UIAccessibility.isReduceMotionEnabled
            ? DrawerLayout.settleDuration(distance: (target - initial) * width, parentWidth: surface.bounds.width,
                                          dragRange: width, velocity: velocity) : 0
        drawerAnimator.run(duration: duration) { [weak self] progress in
            guard let self else { return }
            self.drawerFraction = initial + (target - initial) * progress
            self.view.setNeedsLayout(); self.view.layoutIfNeeded()
            if progress == 1 && open { UIAccessibility.post(notification: .screenChanged, argument: self.drawer) }
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              !isPreview, !bottomNavigationEnabled, !persistentDrawer, !settingsVisible else { return false }
        let velocity = pan.velocity(in: surface)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        let location = pan.location(in: surface)
        let translation = pan.translation(in: surface)
        let point = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        return drawerFraction > 0 || (rtl ? point.x >= surface.bounds.width - 20 : point.x <= 20)
    }

    // Like DrawerLayout's edge tracking, an edge swipe opens the drawer even over an episode row's swipe
    // actions: row swipes wait for the drawer pan, which declines at once away from the edge.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The episode pager's swipe also waits: an edge swipe is the drawer's, as system gestures are on Android.
        otherGestureRecognizer.delegate is EpisodeRowSwipe || otherGestureRecognizer.view is EpisodePagerView.PagingScrollView
    }

    @objc private func dragDrawer(_ gesture: UIPanGestureRecognizer) {
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let width = max(1, drawer.layout?.panel.width ?? surface.bounds.width)
        switch gesture.state {
        case .began:
            drawerAnimator.cancel()
            drawerPanStart = drawerFraction
            drawer.isHidden = false
        case .changed:
            drawerFraction = min(1, max(0, drawerPanStart + gesture.translation(in: surface).x * (rtl ? -1 : 1) / width))
            view.setNeedsLayout(); view.layoutIfNeeded()
        case .ended:
            setDrawerOpen(DrawerLayout.shouldOpen(fraction: drawerFraction, velocity: gesture.velocity(in: surface).x, rightToLeft: rtl), velocity: gesture.velocity(in: surface).x)
        case .cancelled: setDrawerOpen(drawerPanStart > 0.5)
        default: break
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        if currentSelectionScope != nil, feedSelection.active { endFeedSelection(); return true }
        if subscriptionSelectionVisible { endSubscriptionSelection(); return true }
        if isPreview { goBack(); return true }
        if let suggestion = popup as? UsageSuggestionView { suggestion.dismiss?(); return true }
        let action = NavigationBackPolicy.action(preferences: navigationPreferences?.value ?? .init(),
            rootTag: rootNavigationTag, childDepth: max(0, path.count - 1), playerExpanded: (playerView?.expansion ?? 0) >= 1,
            drawerOpen: drawerFraction > 0, persistentDrawer: persistentDrawer, settingsVisible: settingsVisible)
        switch action {
        case .closeDrawer: setDrawerOpen(false)
        case .collapsePlayer: playerView?.setExpanded(false, animated: true)
        case .popChild: goBack()
        case .openDefault(let tag): selectTag(tag)
        case .openDrawer: setDrawerOpen(true)
        case .system: return false
        }
        return true
    }

    private func rememberNavigation(_ tag: String) {
        guard let navigationPreferences, navigationPreferences.value.lastPage != tag else { return }
        var value = navigationPreferences.value; value.lastPage = tag
        do { try navigationPreferences.update(value) } catch { showError(error) }
    }
    private func cancelSearches() {
        for screen in path {
            switch screen { case .search(let search): search.session.cancel()
            case .onlineSearch(let search): search.session.cancel()
            default: break }
        }
    }

    /// `MainActivity` is `singleTask`: when a notification or a message's Details opens it, the Settings
    /// screens above it close. The page under Settings and its back stack stay.
    func closeSettings() {
        var remaining = path.count
        while settingsVisible, path.count > 1 {
            goBack()
            guard path.count < remaining else { return }
            remaining = path.count
        }
    }

    private func goBack() {
        if currentSelectionScope != nil, feedSelection.active { endFeedSelection(); return }
        if subscriptionSelectionVisible { endSubscriptionSelection(); return }
        if case .search(let search) = path.last, search.endSelection() { return }
        guard path.count > 1 else { if isPreview { onPreviewClose?() }; return }
        let wasSettings = settingsVisible
        view.endEditing(true)
        if case .search(let search) = path.last { search.session.cancel() }
        if case .onlineSearch(let search) = path.last { search.session.cancel() }
        fetchTask?.cancel()
        path.removeLast()
        pendingReadingPosition = parentReadingPositions.popLast() ?? .offset(0)
        if wasSettings && !settingsVisible && configuration.hiddenTags.contains(rootNavigationTag) {
            let tag = navigationPreferences?.value.defaultPage ?? NavigationDestination.home.rawValue
            selectTag(tag)
        }
        renderedSize = .zero; view.setNeedsLayout()
    }

    func showNavigationCustomization(fromDrawer: Bool = false) {
        guard let navigationPreferences else { return }
        let dialog = NavigationCustomizationController(preferences: navigationPreferences)
        dialog.onSaved = { [weak self] in
            guard let self else { return }
            if fromDrawer {
                if self.configuration.hiddenTags.contains(self.rootNavigationTag) {
                    let tag = navigationPreferences.value.defaultPage
                    self.selectTag(tag)
                }
                self.setDrawerOpen(true, animated: false)
            }
        }
        present(dialog, animated: true)
    }

    private func empty(title: String, message: String) {
        let heading = Appearance.label(Appearance.text(title), size: 16, bold: true)
        heading.textAlignment = .center
        heading.frame = CGRect(x: 40, y: max(0, content.bounds.midY - 40), width: content.bounds.width - 80, height: 28)
        let detail = Appearance.label(Appearance.text(message), size: 14)
        detail.textAlignment = .center
        detail.frame = CGRect(x: 40, y: heading.frame.maxY, width: content.bounds.width - 80, height: 72)
        content.addSubview(heading)
        content.addSubview(detail)
    }

    private var orderedEpisodeRows: [EpisodeRowView] {
        episodeRows.values.map(\.1).sorted { $0.frame.minY < $1.frame.minY }
    }
    /// Frames of the episode rows in list order: the whole loaded list, built or not (Home's few rows otherwise).
    private var episodeRowFrames: [CGRect] { episodeList?.frames ?? orderedEpisodeRows.map(\.frame) }
    /// Episode ids of the list on screen, top to bottom, including rows not built yet.
    var displayedEpisodeIDs: [Int64] {
        episodeList?.ids ?? episodeRows.values.sorted { $0.1.frame.minY < $1.1.frame.minY }.map(\.0.id)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === content, currentRefreshScope != nil, pullScope == currentRefreshScope,
           feedPull.distance > 0, !pullWaiting, content.contentOffset.y != 0 {
            content.contentOffset.y = 0
        }
        if scrollView === content { updateFeedAppBar(animated: true); refreshProgressChanged() }
        if scrollView === content, !renderingContent { loadNextEpisodePageIfNeeded(); updateVisibleContent() }
    }

    /// The screen is about to be replaced: scrolling the old list to the top must not build its rows.
    private func leaveLazyContent() { episodeList = nil; subscriptionGrid = nil }

    /// Builds the rows (or Subscriptions tiles) coming near the visible area and releases those far from it.
    func updateVisibleContent() {
        episodeList?.update(in: content)
        subscriptionGrid?.update(in: content)
    }

    private func captureReadingPosition() -> ReadingPosition {
        let y = max(0, content.contentOffset.y)
        let frames = episodeRowFrames
        if let first = frames.first, y >= first.minY,
           let index = frames.firstIndex(where: { $0.maxY > y }) {
            return .episode(index: index, top: frames[index].minY - y)
        }
        return .offset(y)
    }

    private func restoreReadingPosition(_ position: ReadingPosition) {
        let y: CGFloat
        switch position {
        case .offset(let offset): y = offset
        case .episode(let index, let top):
            let frames = episodeRowFrames
            // Translate only the episode-list coordinates. Header space must
            // never count as an adapter row or change the retained row index.
            let listOffset = EpisodeListScrollPosition(firstVisibleIndex: index, topOffset: top)
                .contentOffset(rowHeights: frames.map(\.height), viewportHeight: content.bounds.height)
            y = (frames.first?.minY ?? 0) + listOffset
        }
        content.setContentOffset(CGPoint(x: 0, y: min(max(0, y), max(0, content.contentSize.height - content.bounds.height))), animated: false)
    }

    /// `paged`: the list shows `episodesPerPage` rows per loaded page (see `episodesPerPage`). Every loaded row
    /// is measured and placed, but built only when it comes near the screen (`LazyContentList`).
    func episodes(_ values: [(LibraryFeed, LibraryEpisode)], top: CGFloat = 0, paged: Bool = false) {
        if currentSelectionScope != nil { feedSelectionIDs = values.map { $0.1.id } }
        remainingEpisodeRows = nil
        var count = values.count
        if paged {
            let screen = "\(String(describing: currentSelectionScope))#\(path.count)"
            if episodePaging.screen != screen { episodePaging = (screen, 1) }
            let needed = (minimumEpisodeRowCount + Self.episodesPerPage - 1) / Self.episodesPerPage
            episodePaging.pages = max(episodePaging.pages, needed)
            count = min(count, episodePaging.pages * Self.episodesPerPage)
        }
        let list = LazyContentList(top: top) { [weak self] id in self?.makeListEpisodeRow(id) ?? UIView() }
        list.released = { [weak self] id in self?.episodeRows[id] = nil }
        list.pinned = { [weak self] id in self?.queueDragController?.holds(id) == true }
        list.ceiling = { [weak self] in self?.feedAppBar }
        list.fittedHeight = { view, width in view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height }
        list.resized = { [weak self] in self?.episodeListResized() }
        episodeList = list
        // A tap opens the pager over exactly these displayed rows, in this order.
        episodePagerList = values.map { EpisodePagerItem(feedID: $0.0.id, episodeID: $0.1.id) }
        appendEpisodeRows(values[..<count])
        if count < values.count { remainingEpisodeRows = values[count...] }
        content.contentSize.height = max(content.bounds.height, list.bottom)
        if queueVisible { attachQueueDrag() }
    }

    /// `EpisodesListFragment.setupLoadMoreScrollListener`: the next page joins the list as its end comes into
    /// view (here one screen early, so scrolling does not stop at the page boundary).
    func loadNextEpisodePageIfNeeded() {
        guard let remaining = remainingEpisodeRows, let list = episodeList, content.bounds.height > 0,
              content.contentOffset.y + 2 * content.bounds.height >= list.bottom else { return }
        remainingEpisodeRows = nil
        let next = remaining.prefix(Self.episodesPerPage)
        appendEpisodeRows(next)
        episodePaging.pages += 1
        if next.count < remaining.count { remainingEpisodeRows = remaining.dropFirst(next.count) }
        episodeListResized()
        guard !renderingContent else { return }
        updateFeedSelection()
    }

    /// The content height after the list grew (a page was added, a row's height changed).
    private func episodeListResized() {
        guard let list = episodeList else { return }
        var height = max(content.bounds.height, list.bottom)
        if let feedAppBar { height = max(height, content.bounds.height + feedAppBar.fullHeaderHeight) }
        feedContentHeight = height
        content.contentSize.height = height
        if !renderingContent { updateFeedPageFooter() }
    }

    /// Measures and places rows without building them; a row's height depends only on its title and layout.
    private func appendEpisodeRows(_ values: ArraySlice<(LibraryFeed, LibraryEpisode)>) {
        guard let list = episodeList else { return }
        let onQueue = queueVisible
        let onFeedScreen: Bool = if case .feed = path.last { true } else { false }
        let draggable = onQueue && queuePolicy.showsHandle
        let width = content.bounds.width
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        let category = traitCollection.preferredContentSizeCategory
        let playingID = playback?.wantsPlayback == true ? playback?.episode?.id : nil
        var metrics: EpisodeRowMetrics?
        var ids: [Int64] = [], heights: [CGFloat] = []
        ids.reserveCapacity(values.count); heights.reserveCapacity(values.count)
        for (feed, stored) in values {
            displayedEpisodeValues[stored.id] = (feed, stored)
            let episode = actionBindings[stored.id]?.model.snapshot().episode ?? stored
            let key = EpisodeRowHeightKey(title: episode.details.title ?? "",
                progressLine: EpisodeRowView.showsProgressLine(episode, activelyPlaying: playingID == episode.id),
                draggable: draggable, action: onFeedScreen ? feed.subscriptionState == .subscribed : true, queue: onQueue,
                width: width, scale: scale, category: category)
            if let height = episodeRowHeights[key] { heights.append(height) }
            else {
                if metrics == nil { metrics = EpisodeRowMetrics(queueTraits: onQueue ? traitCollection : nil, scale: scale) }
                let height = metrics!.height(title: key.title, progressLine: key.progressLine, width: width,
                                             draggable: draggable, showAction: key.action)
                if episodeRowHeights.count >= 20_000 { episodeRowHeights.removeAll() }
                episodeRowHeights[key] = height
                heights.append(height)
            }
            ids.append(stored.id)
        }
        list.append(ids, heights: heights, width: width)
    }

    /// A long list's row, built as it comes near the screen, in the list's current selection and queue state.
    private func makeListEpisodeRow(_ id: Int64) -> UIView {
        guard let (feed, stored) = displayedEpisodeValues[id] else { return UIView() }
        let row = makeEpisodeRow(feed: feed, storedEpisode: stored, pagerList: episodePagerList)
        if currentSelectionScope != nil, feedSelection.active {
            row.setSelected(feedSelection.ids.contains(id), selectionMode: true)
        }
        if queueVisible { queueDragController?.attach(row, id: id) }
        return row
    }

    /// Home's few rows inside its sections, built at once; returns their bottom.
    func addEpisodeRows(_ values: [(LibraryFeed, LibraryEpisode)], top: CGFloat) -> CGFloat {
        let pagerList = values.map { EpisodePagerItem(feedID: $0.0.id, episodeID: $0.1.id) }
        var y = top
        for (feed, storedEpisode) in values {
            let row = makeEpisodeRow(feed: feed, storedEpisode: storedEpisode, pagerList: pagerList)
            let size = row.sizeThatFits(CGSize(width: content.bounds.width, height: .greatestFiniteMagnitude))
            row.frame = CGRect(origin: CGPoint(x: 0, y: y), size: size)
            if let feedAppBar, feedAppBar.superview === content { content.insertSubview(row, belowSubview: feedAppBar) }
            else { content.addSubview(row) }
            y += size.height
        }
        return y
    }

    private func makeEpisodeRow(feed: LibraryFeed, storedEpisode: LibraryEpisode, pagerList: [EpisodePagerItem]) -> EpisodeRowView {
        let model = actionModel(feed: feed, episode: storedEpisode)
        let episode = model.snapshot().episode
        let onQueue: Bool = if case .destination(.queue) = path.last { true } else { false }
        let showsSecondary: Bool = if case .feed = path.last { feed.subscriptionState == .subscribed } else { true }
        // A podcast's own list ignores "Use episode cover" (`FeedItemlistFragment.java:746–758`).
        let onFeedScreen: Bool = if case .feed = path.last { true } else { false }
        let row = EpisodeRowView(feed: feed, episode: episode, queued: queuedEpisodes.contains { $0.id == episode.id },
                                 queueScreen: onQueue, showRemainingTime: timeDisplayPreferences?.value.showRemainingTime == true,
                                 activelyPlaying: playback?.episode?.id == episode.id && playback?.wantsPlayback == true,
                                 showsSecondaryAction: showsSecondary, prefersDelete: downloadsDeleteButton, library: library,
                                 episodeCover: onFeedScreen || usesEpisodeCover,
                                 downloadAction: { [weak self] in
                                     if self?.toggleFeedSelection(episode.id) != true {
                                         if self?.downloadsDeleteButton == true && episode.userState.isDownloaded {
                                             self?.performEpisodeListAction(.delete, ids: [episode.id])
                                         } else { self?.downloadAction(episode.id) }
                                     }
                                 }) { [weak self] in
            if self?.toggleFeedSelection(episode.id) != true { self?.openEpisode(feedID: feed.id, episodeID: episode.id, list: pagerList) }
        }
        if currentSelectionScope != nil || homeRowScopes[episode.id] != nil {
            row.contextMenu = { [weak self] anchor, fraction in self?.showListEpisodeMenu(episode.id, feedID: feed.id, anchor: anchor, fraction: fraction) }
        }
        if isDownloadsRow(episode.id) {
            row.swipe = EpisodeRowSwipe(row: row, configuration: { [weak self] direction in
                self?.downloadsSwipeConfiguration(direction, episodeID: episode.id)
            }, perform: { [weak self] direction in self?.performDownloadsSwipe(direction, episodeID: episode.id) })
        } else if swipeScreen(for: episode.id) != nil {
            row.swipe = EpisodeRowSwipe(row: row, configuration: { [weak self] direction in
                guard self?.actionBindings[episode.id]?.model === model else { return nil }
                return self?.inboxSwipeConfiguration(direction, episodeID: episode.id)
            }, perform: { [weak self] direction in self?.performInboxSwipe(direction, episodeID: episode.id, expectedModel: model) })
        }
        row.actionModel = model
        if onQueue {
            row.configureQueueLayout(traits: traitCollection,
                rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            row.setQueueInteraction(queuePolicy)
        }
        episodeRows[episode.id] = (episode, row)
        let job = downloads?.activeJob(source: episode.details.media?.url)
        row.updateDownload(job: job, progress: job.flatMap { downloads?.progress[$0.id] },
                           playing: playback?.episode?.id == episode.id && playback?.wantsPlayback == true,
                           streamOverDownload: navigationPreferences?.value.streamOverDownload == true)
        return row
    }

    override var keyCommands: [UIKeyCommand]? {
        guard queueVisible, presentedViewController == nil else { return super.keyCommands }
        return (super.keyCommands ?? []) + [UIKeyCommand(input: "t", modifierFlags: [], action: #selector(queueKeyScroll(_:))),
            UIKeyCommand(input: "b", modifierFlags: [], action: #selector(queueKeyScroll(_:)))]
    }

    @discardableResult
    func showSnackbar(_ message: String, action: Snackbar.Action? = nil, animated: Bool = true) -> Bool {
        guard isViewLoaded, view.window != nil else { return false }
        inboxSwipeOffers?.dismiss()
        visibleSnackbar?.dismiss(animated: false)
        let snackbar = Snackbar(message: message, action: action)
        visibleSnackbar = snackbar
        snackbar.onDismiss = { [weak self, weak snackbar] in
            if self?.visibleSnackbar === snackbar { self?.visibleSnackbar = nil }
        }
        snackbar.onNeedsLayout = { [weak self] in self?.view.setNeedsLayout() }
        surface.addSubview(snackbar)
        layoutSynchronizationSnackbar()
        snackbar.appear(animated: animated)
        return true
    }

    var snackbarRegion: CGRect {
        let expanded = (playerView?.expansion ?? 0) >= 1
        let player = playerView.flatMap { $0.isHidden ? nil : $0 }
        let bottom = !expanded && player != nil ? player!.frame.minY : (navigation.isHidden ? bottomInset.frame.minY : navigation.frame.minY)
        let region = expanded ? surface.bounds : CGRect(x: content.frame.minX, y: 0, width: content.frame.width, height: surface.bounds.height)
        return CGRect(x: region.minX, y: 0, width: region.width, height: max(0, bottom))
    }
    private func layoutSynchronizationSnackbar() {
        guard let snackbar = visibleSnackbar else { return }
        snackbar.swipeEnabled = (playerView?.expansion ?? 0) < 1
        snackbar.place(in: snackbarRegion, wide: min(view.bounds.width, view.bounds.height) >= 600)
        surface.bringSubviewToFront(snackbar)
    }
    private func layoutInboxSwipeSnackbar() {
        guard let offers = inboxSwipeOffers, let snackbar = offers.snackbar else { return }
        snackbar.swipeEnabled = (playerView?.expansion ?? 0) < 1
        offers.relayout(); surface.bringSubviewToFront(snackbar)
    }

    /// The first launch states that NotTennaPod is not AntennaPod. Set by the scene
    /// when it is due; reported once shown, so it appears a single time.
    var showsFirstLaunchNotice = false
    var onFirstLaunchNoticeShown: (() -> Void)?

    private func showFirstLaunchNotice() {
        guard presentedViewController == nil else { return }
        let notice = SourceMessageController(title: Appearance.text("about_nottennapod_title"),
                                             message: Appearance.text("about_nottennapod_message"))
        notice.view.accessibilityIdentifier = "firstLaunchNotice"
        present(notice, animated: true)
        showsFirstLaunchNotice = false
        onFirstLaunchNoticeShown?()
    }

    /// The chosen server library could not be found on this device, so this device's library opened.
    /// Set by the scene; true once per occurrence, for the first screen that shows it.
    var takeMissingLibraryNotice: (() -> Bool)?

    /// A message about work the system ended, and what to do once a person has seen it.
    struct LaunchNotice {
        let message: String
        let shown: () -> Void
        /// Not shown here after all: another visible screen may take it.
        var release: () -> Void = {}
    }
    /// What an interrupted database import or export became, until a person has seen it. Set by the scene.
    var takeRecoveryNotices: (() -> [LaunchNotice])?
    /// The database import's result dialog appeared. Set by the scene.
    var importOutcomeShown: (() -> Void)?

    /// Says so once this screen is in a scene a person sees (foreground and active): as it appears, or as its scene
    /// becomes active (at launch the screen may appear just before). It is shown for its whole time: a notice that
    /// follows (what an interrupted import or export became, a pending backup report at the same activation) waits its turn.
    /// VoiceOver reads it after what it is reading.
    func showMissingLibraryNoticeIfDue() {
        guard isViewLoaded, view.window?.windowScene?.activationState == .foregroundActive else { return }
        if let take = takeMissingLibraryNotice, take() {
            showNotice(Appearance.text("ntp_server_library_missing"), queuesAnnouncement: true, holds: true)
        }
        // Each is acknowledged only once it is actually on screen, not while it waits behind another.
        for notice in takeRecoveryNotices?() ?? [] {
            showNotice(notice.message, queuesAnnouncement: true, holds: true, shown: notice.shown, release: notice.release)
        }
        if notice == nil { showNextWaitingNotice() }
    }

    /// Whether this screen is in a scene a person sees now (attached, foreground and active): only then is a durable
    /// launch notice presented and acknowledged. Tests stand in for the scene's state (`sceneIsSeen`).
    var sceneIsSeen: (@MainActor () -> Bool)?
    private var seesNotices: Bool {
        guard isViewLoaded, let window = view.window else { return false }
        return sceneIsSeen?() ?? (window.windowScene?.activationState == .foregroundActive)
    }

    /// The scene leaves the foreground, or the screen leaves its window: durable notices still waiting are given back,
    /// for this screen when it is seen again or for another visible one; nothing is acknowledged meanwhile.
    func releaseWaitingLaunchNotices() {
        let released = waitingNotices.filter { $0.release != nil }
        waitingNotices.removeAll { $0.release != nil }
        for notice in released { notice.release?() }
    }

    @objc func noticeSceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === view.window?.windowScene else { return }
        releaseWaitingLaunchNotices()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        releaseWaitingLaunchNotices()
    }

    /// A newer notice replaces the one showing, unless that one `holds`: then notices wait their turn, in order, each
    /// shown for its whole time and read by VoiceOver after the one before, as Android queues toasts.
    /// `queuesAnnouncement`: VoiceOver reads the notice after what it is reading (a screen that just appeared),
    /// instead of either cutting the other off.
    func showNotice(_ message: String, queuesAnnouncement: Bool = false, holds: Bool = false, shown: (() -> Void)? = nil,
                    release: (() -> Void)? = nil) {
        // A durable launch notice is never presented where nobody sees it: it is given back.
        if shown != nil, !seesNotices { release?(); return }
        if notice != nil, noticeHolds {
            if !waitingNotices.contains(where: { $0.message == message }) {
                waitingNotices.append(WaitingNotice(message: message, shown: shown, release: release))
            }
            return
        }
        noticeTask?.cancel()
        notice?.removeFromSuperview()
        noticeHolds = holds
        let label = Appearance.label(message, size: 14)
        label.textAlignment = .center
        label.backgroundColor = Appearance.navigation
        label.layer.cornerRadius = 20
        label.clipsToBounds = true
        label.accessibilityIdentifier = "applicationNotice"
        label.isAccessibilityElement = true; label.accessibilityLabel = message; label.accessibilityTraits = .staticText
        notice = label
        layoutNotice()
        shown?()
        UIAccessibility.post(notification: .announcement, argument: queuesAnnouncement
            ? NSAttributedString(string: message, attributes: [.accessibilitySpeechQueueAnnouncement: true]) : label.text)
        noticeTask = Task { [weak self, weak label] in
            do { try await Task.sleep(for: .milliseconds(3500)) } catch { return }
            label?.removeFromSuperview()
            self?.noticeEnded()
        }
    }

    /// The shown notice's time is over: the next waiting notice gets its own whole turn.
    private func noticeEnded() {
        notice = nil
        noticeHolds = false
        showNextWaitingNotice()
    }

    /// The next waiting notice, if this screen may show it now. A durable launch notice is shown (and acknowledged) only
    /// while the scene is seen; otherwise it is given back.
    private func showNextWaitingNotice() {
        guard notice == nil, let next = waitingNotices.first else { return }
        if next.shown != nil, !seesNotices {
            // Gives back every durable one; any other notice still waiting gets its turn.
            releaseWaitingLaunchNotices()
            showNextWaitingNotice()
            return
        }
        waitingNotices.removeFirst()
        showNotice(next.message, queuesAnnouncement: true, holds: true, shown: next.shown, release: next.release)
    }

    private func layoutNotice() {
        guard let notice else { return }
        let margin = min(24, surface.bounds.width / 2)
        let width = max(0, surface.bounds.width - 2 * margin)
        let height = notice.sizeThatFits(CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude)).height + 24
        let host: UIView = surface.window ?? surface
        if notice.superview !== host { host.addSubview(notice) }
        else { host.bringSubviewToFront(notice) }
        // MainActivity's MessageEvent Snackbar is anchored above the mini player when it shows, otherwise above
        // the bottom navigation, and stays clear of the system bars (here: inside the safe area).
        var anchor = navigation.isHidden ? surface.bounds.maxY : navigation.frame.minY
        if let playerView, !playerView.isHidden, playerView.expansion == 0 { anchor = min(anchor, playerView.frame.minY) }
        anchor = min(anchor, surface.convert(view.safeAreaLayoutGuide.layoutFrame, from: view).maxY)
        let frame = CGRect(x: margin, y: anchor - height - 24, width: width, height: height)
        notice.frame = surface.convert(frame, to: host)
    }

    func openWebsite(_ destination: String) {
        guard let url = URL(string: destination) else {
            showNotice(Appearance.text("pref_no_browser_found"))
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            if !opened { self?.showNotice(Appearance.text("pref_no_browser_found")) }
        }
    }

    func toolbarLayout(hasOverflow: Bool, hasPrimaryAction: Bool = false, hasSecondaryAction: Bool = false, forceNavigation: Bool = false) -> ToolbarLayout {
        ToolbarLayout(size: toolbar.bounds.size,
            hasNavigation: forceNavigation || isPreview || path.count > 1 || (!bottomNavigationEnabled && !persistentDrawer), hasOverflow: hasOverflow,
            density: view.window?.screen.scale ?? traitCollection.displayScale,
            rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft,
            hasPrimaryAction: hasPrimaryAction, hasSecondaryAction: hasSecondaryAction)
    }

    func textButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = Appearance.font(16)
        button.titleLabel?.numberOfLines = 0
        button.tintColor = Appearance.foreground
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func showMore() {
        popup?.removeFromSuperview()
        let overlay = UIControl(frame: surface.bounds)
        overlay.accessibilityIdentifier = "morePopup"
        overlay.addAction(UIAction { [weak self] _ in self?.popup?.removeFromSuperview(); self?.popup = nil }, for: .touchUpInside)
        let actions = configuration.moreActions
        let panel = UIScrollView()
        let height = min(CGFloat(actions.count) * 48 + 16, navigation.frame.minY - view.safeAreaInsets.top)
        let width = min(250, surface.bounds.width)
        panel.frame = CGRect(x: view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? 0 : surface.bounds.width - width, y: navigation.frame.minY - height, width: width, height: height)
        panel.backgroundColor = Appearance.navigation
        panel.layer.cornerRadius = 4
        for (index, action) in actions.enumerated() {
            let title: String
            let image: String
            switch action {
            case .destination(let destination): title = Appearance.title(for: destination); image = Appearance.icon(for: destination)
            case .customize: title = Appearance.text("pref_nav_drawer_items_title"); image = "ic_settings"
            default: title = Appearance.text("settings_label"); image = "ic_settings"
            }
            let button = textButton(title) { [weak self] in
                guard let self else { return }
                popup?.removeFromSuperview(); popup = nil
                if case .destination(let destination) = action { select(destination) }
                else if case .customize = action { showNavigationCustomization() }
                else { push(.settings(.main)); view.setNeedsLayout() }
            }
            button.contentHorizontalAlignment = .leading
            button.frame = CGRect(x: 64, y: 8 + CGFloat(index) * 48, width: width - 72, height: 48)
            let icon = UIImageView(image: UIImage(named: image))
            icon.tintColor = Appearance.secondary
            icon.frame = CGRect(x: 16, y: button.frame.minY + 12, width: 24, height: 24)
            panel.addSubview(icon)
            panel.addSubview(button)
        }
        panel.contentSize = CGSize(width: width, height: CGFloat(actions.count) * 48 + 16)
        overlay.addSubview(panel)
        surface.addSubview(overlay)
        popup = overlay
        layoutPopup = { [weak self, weak overlay, weak panel] in
            guard let self, let overlay, let panel else { return }
            overlay.frame = surface.bounds
            let height = min(CGFloat(actions.count) * 48 + 16, navigation.frame.minY - view.safeAreaInsets.top)
            let width = min(250, surface.bounds.width)
            panel.frame = CGRect(x: view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? 0 : surface.bounds.width - width,
                                 y: navigation.frame.minY - height, width: width, height: height)
        }
    }

    func showError(_ error: Error) {
        // A superseded or refused command (the player of a library being closed) is not a failure to report.
        guard !(error is CancellationError) else { return }
        let dialog = UIAlertController(title: Appearance.text("error_label"), message: error.localizedDescription, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: Appearance.text("confirm_label"), style: .default))
        messages.present(dialog)
    }
}

extension LibraryViewController: DocumentExportHost {
    func presentExportMessage(_ message: UIViewController) { messages.present(message) }

    /// Source LENGTH_LONG snackbar with a Share action, in the shared snackbar slot/region.
    func showExportSuccess(share: @escaping (_ anchor: CGRect) -> Void, dismissed: @escaping () -> Void) -> Bool {
        guard isViewLoaded, view.window != nil else { return false }
        inboxSwipeOffers?.dismiss()
        visibleSnackbar?.dismiss(animated: false)
        weak var placed: Snackbar?
        let snackbar = Snackbar(message: Appearance.text("export_success_title"),
            action: .init(title: Appearance.text("share_label"), identifier: "opmlExportShare") { [weak self] in
                guard let self, let placed else { return }
                share(placed.convert(placed.bounds, to: view))
            })
        placed = snackbar
        snackbar.accessibilityIdentifier = "opmlExportSnackbar"
        visibleSnackbar = snackbar
        snackbar.onDismiss = { [weak self, weak snackbar] in
            if self?.visibleSnackbar === snackbar { self?.visibleSnackbar = nil }
            dismissed()
        }
        snackbar.onNeedsLayout = { [weak self] in self?.view.setNeedsLayout() }
        surface.addSubview(snackbar)
        layoutSynchronizationSnackbar()
        snackbar.appear(animated: true)
        return true
    }

    func presentExportShare(_ activity: UIActivityViewController, anchor: CGRect) {
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = anchor
        guard presentedViewController == nil else { activity.completionWithItemsHandler?(nil, false, nil, nil); return }
        presentShareActivity(activity)
    }
}

import UIKit
import NotTennaPodCore

// List (Queue, Inbox, Episodes, History, Favorites, a podcast) and Downloads swipe actions.
extension LibraryViewController {
    private var inboxSwipeScreen: SwipeScreen? {
        guard !isPreview else { return nil }
        return switch path.last {
        case .destination(.queue): .queue
        case .destination(.history): .history
        case .destination(.inbox): .inbox
        case .destination(.episodes): .episodes
        case .destination(.favorites): .favorites
        case .feed: .feed
        default: nil
        }
    }
    private var inboxSwipeFilter: FeedEpisodeFilter {
        if let fixed = inboxSwipeScreen?.fixedSwipeFilter { return fixed }
        return switch path.last {
        case .destination(.favorites): .init(values: ["is_favorite"])
        case .destination(.episodes): allEpisodesFilter.effective
        case .feed(let id): feeds.first { $0.id == id }?.episodeFilter ?? .init()
        default: .init()
        }
    }
    func showInboxSwipeSettings(_ screen: SwipeScreen) {
        guard let inboxSwipePreferences, presentedViewController == nil else { return }
        present(SwipeSettingsController.make(screen: screen, store: inboxSwipePreferences,
            saved: { [weak self] in self?.render() }, failed: { [weak self] in self?.showError($0) }), animated: true)
    }
    private func swipeRecipient(for screen: SwipeScreen) -> SwipeRecipient? {
        guard let library, let inboxSwipePreferences, let coordinator = inboxSwipeCoordinator else { return nil }
        if inboxSwipeOffers == nil {
            let offers = SwipeOfferPresenter(host: surface, store: library, coordinator: coordinator,
                actionTimeout: { .milliseconds(2_750) }, region: { [weak self] in self?.snackbarRegion ?? .zero },
                wide: { [weak self] in guard let self else { return false }; return min(view.bounds.width, view.bounds.height) >= 600 })
            offers.onWillShow = { [weak self] in self?.visibleSnackbar?.dismiss(animated: false) }
            offers.onError = { [weak self] in self?.showError($0) }
            offers.onQueueChange = { [weak self] _ in self?.reloadLibrary() }
            offers.onHistoryChange = { [weak self] in self?.reloadLibrary() }
            inboxSwipeOffers = offers
        }
        guard let offers = inboxSwipeOffers else { return nil }
        return SwipeRecipient(preferences: inboxSwipePreferences, screen: screen, coordinator: coordinator,
            offers: offers, configure: { [weak self] in self?.showInboxSwipeSettings(screen) },
            ordinary: { [weak self] decision, model, target in
                self?.performOrdinaryInboxSwipe(decision, model: model, target: target)
            })
    }
    /// The screen whose swipe configuration a row uses; Home's See what's new rows use the Inbox's (source
    /// `SwipeActions(this, InboxFragment.TAG)`).
    func swipeScreen(for episodeID: Int64) -> SwipeScreen? {
        inboxSwipeScreen ?? (homeRowScopes[episodeID] == .inbox ? .inbox : nil)
    }
    private func swipeFilter(for episodeID: Int64) -> FeedEpisodeFilter {
        inboxSwipeScreen == nil && homeRowScopes[episodeID] == .inbox ? .init(values: ["new"]) : inboxSwipeFilter
    }
    func isDownloadsRow(_ episodeID: Int64) -> Bool {
        if case .destination(.downloads) = path.last { return true }
        return homeRowScopes[episodeID] == .downloads
    }
    /// A podcast's list and the Queue detach swiping during selection (`FeedItemlistFragment`, `QueueFragment:560`);
    /// the other lists keep it (`EpisodesListFragment`).
    private func swipeDetached(_ screen: SwipeScreen) -> Bool {
        (screen == .feed || screen == .queue) && feedSelection.active
    }
    func inboxSwipeConfiguration(_ direction: EpisodeSwipeDirection, episodeID: Int64) -> EpisodeRowSwipe.Configuration? {
        guard presentedViewController == nil, let screen = swipeScreen(for: episodeID), !swipeDetached(screen),
              let captured = captureAction(episodeID), let recipient = swipeRecipient(for: screen) else { return nil }
        return recipient.configuration(direction: direction, item: contextItem(captured.model), filter: swipeFilter(for: episodeID))
    }
    func performInboxSwipe(_ direction: EpisodeSwipeDirection, episodeID: Int64, expectedModel: EpisodeActionModel? = nil) {
        guard presentedViewController == nil, let screen = swipeScreen(for: episodeID), !swipeDetached(screen),
              let captured = captureAction(episodeID), expectedModel == nil || captured.model === expectedModel,
              let recipient = swipeRecipient(for: screen) else { return }
        let filter = swipeFilter(for: episodeID), item = contextItem(captured.model)
        lastInboxSwipe = Task {
            await recipient.perform(direction: direction, model: captured.model, filter: filter, target: captured.deletionTarget,
                item: item)
        }
    }
    /// The screen's swipe owner: its results reach the models through the screen's action fence.
    func connectInboxSwipe(_ coordinator: EpisodeSwipeCoordinator) {
        coordinator.onEvent = { [weak self] event in self?.receiveInboxSwipe(event) }
        coordinator.superseded = { [weak self] model, receipt in self?.actionResultSuperseded(model, receipt: receipt) ?? false }
        inboxSwipeCoordinator = coordinator
    }
    func receiveInboxSwipe(_ event: EpisodeSwipeCoordinator.Event) {
        switch event {
        case .committed(let commit):
            reconcileInboxSwipe(modelIdentity: commit.modelIdentity, delta: commit.delta, receipt: commit.sequence)
        case .undone(_, let identity, _, let delta, let receipt):
            if let delta { reconcileInboxSwipe(modelIdentity: identity, delta: delta, receipt: receipt) }
        case .cleanupFinished: break // The guarded owner already publishes its library change.
        case .failed: break // The presenter routes the actual error, including unavailable capture.
        }
        inboxSwipeOffers?.receive(event)
    }
    private func reconcileInboxSwipe(modelIdentity: UUID, delta: EpisodeActionStateDelta, receipt: Int64) {
        actionMutationRevision &+= 1
        if let id = actionBindings.first(where: { $0.value.model.identity == modelIdentity })?.key,
           let captured = captureAction(id) { reconcileCommittedAction(captured, delta: delta, receipt: receipt) }
        else { lastEpisodeActionReconciliation = reloadLibrary(preservingEpisodeDetails: true, reconcilingPresentation: actionPresentation) }
    }
    private func performOrdinaryInboxSwipe(_ decision: SwipeDecision, model: EpisodeActionModel, target: EpisodeMediaDeletionTarget?) {
        switch decision.recipient {
        case .notice(let key): showEpisodeActionMessage(Appearance.text(key))
        case .download: downloadAction(model.episodeID)
        case .list(let action):
            let captured = CapturedAction(model: model, feedID: target?.feedID ?? actionBindings[model.episodeID]?.feedID ?? 0,
                source: target?.source ?? actionBindings[model.episodeID]?.source ?? "", presentation: actionPresentation,
                search: nil, searchRevision: nil, deletionTarget: target)
            performEpisodeListAction(action, ids: [model.episodeID], captured: captured, guardedSwipe: true)
        case .none, .markWithUndo, .removeHistory: break
        }
    }

    func showDownloadsSwipeSettings() {
        guard let downloadPreferences else { return }
        present(DownloadsSwipeSettingsController.make(value: downloadPreferences.value.swipe) { [weak self] draft in
            do { var value = downloadPreferences.value; value.swipe = draft; try downloadPreferences.update(value) }
            catch { self?.showError(error) }
        }, animated: true)
    }
    func downloadsSwipeConfiguration(_ direction: EpisodeSwipeDirection, episodeID: Int64) -> EpisodeRowSwipe.Configuration? {
        guard isDownloadsRow(episodeID), !feedSelection.active, presentedViewController == nil,
              let preferences = downloadPreferences, preferences.value.swipe?.enabled != false,
              let item = episodeListItems([episodeID]).first else { return nil }
        let action = preferences.value.swipe?.action(direction)
        return .init(action: action, removes: action?.removesFromDownloads(item) ?? false)
    }
    func performDownloadsSwipe(_ direction: EpisodeSwipeDirection, episodeID: Int64) {
        guard downloadsSwipeConfiguration(direction, episodeID: episodeID) != nil else { return }
        guard let action = downloadPreferences?.value.swipe?.action(direction) else { showDownloadsSwipeSettings(); return }
        // Resolve the fresh stored item when the gesture commits; selection/queue changes may have arrived during dragging.
        Task { [weak self] in
            guard let self, let library else { return }
            do {
                guard let episode = try await library.episode(id: episodeID),
                      let feed = try await library.listedFeedHeader(id: library.feedID(forEpisode: episodeID)) else { return }
                let item = EpisodeListItem(episode: episode, local: feed.source.isLocalFeedSource, subscription: feed.subscriptionState,
                    queued: try await library.queue().contains { $0.id == episodeID }, downloading: downloads?.activeJob(source: episode.details.media?.url) != nil)
                if let operation = action.action(for: item) { performEpisodeListAction(operation, ids: [episodeID], resetPosition: action != .played) }
            } catch { showError(error) }
        }
    }
}

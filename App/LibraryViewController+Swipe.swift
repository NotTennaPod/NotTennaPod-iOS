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
                await self?.performOrdinaryInboxSwipe(decision, model: model, target: target)?.value
            })
    }
    /// The screen whose swipe configuration a row uses; Home's See what's new rows use the Inbox's (source
    /// `SwipeActions(this, InboxFragment.TAG)`). `home`: the Home section the row is in (an episode can have a row in
    /// New and one in Downloads, each with its section's settings).
    func swipeScreen(for episodeID: Int64, home: EpisodeSelectionScope? = nil) -> SwipeScreen? {
        inboxSwipeScreen ?? (home == .inbox ? .inbox : nil)
    }
    private func swipeFilter(for episodeID: Int64, home: EpisodeSelectionScope?) -> FeedEpisodeFilter {
        inboxSwipeScreen == nil && home == .inbox ? .init(values: ["new"]) : inboxSwipeFilter
    }
    func isDownloadsRow(_ episodeID: Int64, home: EpisodeSelectionScope? = nil) -> Bool {
        if case .destination(.downloads) = path.last { return true }
        return home == .downloads
    }
    /// A podcast's list and the Queue detach swiping during selection (`FeedItemlistFragment`, `QueueFragment:560`);
    /// the other lists keep it (`EpisodesListFragment`).
    private func swipeDetached(_ screen: SwipeScreen) -> Bool {
        (screen == .feed || screen == .queue) && feedSelection.active
    }
    func inboxSwipeConfiguration(_ direction: EpisodeSwipeDirection, episodeID: Int64,
                                 home: EpisodeSelectionScope? = nil) -> EpisodeRowSwipe.Configuration? {
        guard presentedViewController == nil, let screen = swipeScreen(for: episodeID, home: home), !swipeDetached(screen),
              let captured = captureAction(episodeID), let recipient = swipeRecipient(for: screen) else { return nil }
        return recipient.configuration(direction: direction, item: contextItem(captured.model),
                                       filter: swipeFilter(for: episodeID, home: home))
    }
    func performInboxSwipe(_ direction: EpisodeSwipeDirection, episodeID: Int64, expectedModel: EpisodeActionModel? = nil,
                           home: EpisodeSelectionScope? = nil) {
        _ = acceptInboxSwipe(direction, episodeID: episodeID, expectedModel: expectedModel, home: home)?()
    }
    /// A swipe's action settled as the finger lifts, with the episode's current model, deletion target, filter and this
    /// screen's library recipient: it runs later whatever happens to the row meanwhile (rebuilt, removed, off screen),
    /// and not once this screen and its library are gone. `home`: the row's Home section.
    func acceptInboxSwipe(_ direction: EpisodeSwipeDirection, episodeID: Int64, expectedModel: EpisodeActionModel? = nil,
                          home: EpisodeSelectionScope? = nil) -> EpisodeRowSwipe.Accepted? {
        guard presentedViewController == nil, let screen = swipeScreen(for: episodeID, home: home), !swipeDetached(screen),
              let captured = captureAction(episodeID), expectedModel == nil || captured.model === expectedModel,
              let recipient = swipeRecipient(for: screen),
              let action = recipient.accept(direction: direction, model: captured.model, filter: swipeFilter(for: episodeID, home: home),
                  target: captured.deletionTarget, item: contextItem(captured.model)) else { return nil }
        return { [weak self] in
            guard let self else { return nil }
            let performed = Task { await action() }
            lastInboxSwipe = performed
            return Task { [weak self] in
                await performed.value
                await self?.settleLibraryChanges()
            }
        }
    }
    /// A row being swiped, sliding or held out until its removal lands: a patch neither builds it again nor retires its
    /// action binding; the row catches up when its swipe ends (`swipeCaughtUp`).
    /// Every row of the episode counts (Home can show it in two sections): the one being swiped is held.
    func holdForSwipe(_ id: Int64) -> Bool {
        let active = episodeRowViews(id).compactMap(\.swipe).filter(\.isActive)
        for swipe in active { swipe.heldBack = true }
        return !active.isEmpty
    }
    /// The swipe on a row a patch held back ended (completed, cancelled or failed): the row shows the episode as it is
    /// now, as a patch of that episode would show it.
    func swipeCaughtUp(_ id: Int64) {
        guard !episodeRowViews(id).isEmpty, let value = libraryEpisode(id) else { return }
        var delta = LibraryMirrorDelta()
        delta.episodes[id] = (value, value)
        screenPatched(delta)
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
    /// The task of a list action, which ends when it is over.
    private func performOrdinaryInboxSwipe(_ decision: SwipeDecision, model: EpisodeActionModel, target: EpisodeMediaDeletionTarget?) -> Task<Void, Never>? {
        switch decision.recipient {
        case .notice(let key): showEpisodeActionMessage(Appearance.text(key))
        case .download: downloadAction(model.episodeID)
        case .list(let action):
            let captured = CapturedAction(model: model, feedID: target?.feedID ?? actionBindings[model.episodeID]?.feedID ?? 0,
                source: target?.source ?? actionBindings[model.episodeID]?.source ?? "", presentation: actionPresentation,
                search: nil, searchRevision: nil, deletionTarget: target)
            return performEpisodeListAction(action, ids: [model.episodeID], captured: captured, guardedSwipe: true)
        case .none, .markWithUndo, .removeHistory: break
        }
        return nil
    }

    func showDownloadsSwipeSettings() {
        guard let downloadPreferences else { return }
        present(DownloadsSwipeSettingsController.make(value: downloadPreferences.value.swipe) { [weak self] draft in
            do { var value = downloadPreferences.value; value.swipe = draft; try downloadPreferences.update(value) }
            catch { self?.showError(error) }
        }, animated: true)
    }
    func downloadsSwipeConfiguration(_ direction: EpisodeSwipeDirection, episodeID: Int64,
                                     home: EpisodeSelectionScope? = nil) -> EpisodeRowSwipe.Configuration? {
        guard isDownloadsRow(episodeID, home: home), !feedSelection.active, presentedViewController == nil,
              let preferences = downloadPreferences, preferences.value.swipe?.enabled != false,
              let item = episodeListItems([episodeID]).first else { return nil }
        let action = preferences.value.swipe?.action(direction)
        return .init(action: action, removes: action?.removesFromDownloads(item) ?? false)
    }
    func performDownloadsSwipe(_ direction: EpisodeSwipeDirection, episodeID: Int64, home: EpisodeSelectionScope? = nil) {
        _ = acceptDownloadsSwipe(direction, episodeID: episodeID, home: home)?()
    }
    /// A Downloads swipe settled as the finger lifts (`acceptInboxSwipe`).
    func acceptDownloadsSwipe(_ direction: EpisodeSwipeDirection, episodeID: Int64,
                              home: EpisodeSelectionScope? = nil) -> EpisodeRowSwipe.Accepted? {
        guard downloadsSwipeConfiguration(direction, episodeID: episodeID, home: home) != nil else { return nil }
        guard let action = downloadPreferences?.value.swipe?.action(direction) else {
            return { [weak self] in self?.showDownloadsSwipeSettings(); return nil }
        }
        // The row's model, its deletion target and the operation are settled now, as on the other lists: a later change
        // to the episode (a sync, replaced media) neither reverses the operation nor redirects a deletion.
        guard let captured = captureAction(episodeID) else { return nil }
        let item = contextItem(captured.model)
        // Toggle played is the lists' swipe mark (`TogglePlaybackStateSwipeAction`): it keeps the position, sends no
        // manual sync action and offers no Undo on Downloads, whose filter it never leaves.
        if action == .played {
            guard let coordinator = inboxSwipeCoordinator else { return nil }
            let mark: EpisodeSwipeMark = item.episode.userState.playState == .unplayed ? .markPlayed : .markUnplayed
            return { [weak self] in
                guard let self else { return nil }
                return Task { [weak self] in
                    _ = await coordinator.perform(model: captured.model, action: mark, target: captured.deletionTarget, offersUndo: false)
                    await self?.settleLibraryChanges()
                }
            }
        }
        let operation = action.action(for: item)
        return { [weak self] in
            guard let self, let operation else { return nil }
            // Delete removes only the captured file, also after a local folder's warning.
            let performed = performEpisodeListAction(operation, ids: [episodeID], captured: captured, guardedSwipe: true)
            return Task { [weak self] in
                await performed?.value
                await self?.settleLibraryChanges()
            }
        }
    }
}

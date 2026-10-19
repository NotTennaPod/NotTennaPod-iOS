import UIKit
import NotTennaPodCore

// Queue toolbar, lock, drag and information.
extension LibraryViewController {
    @objc func queueKeyScroll(_ command: UIKeyCommand) {
#if DEBUG
        QueueGestureFixture.recordControllerEvent("key-handler-entry", controller: self, input: command.input)
#endif
        guard queueVisible else { return }
        let top = -content.adjustedContentInset.top
        let bottom = max(top, content.contentSize.height - content.bounds.height + content.adjustedContentInset.bottom)
        content.setContentOffset(CGPoint(x: content.contentOffset.x, y: command.input == "t" ? top : bottom), animated: true)
#if DEBUG
        QueueGestureFixture.recordControllerEvent("key-handler-scroll-requested", controller: self, input: command.input)
#endif
    }

    func renderQueueToolbar(heading: UILabel) {
        let layout = toolbarLayout(hasOverflow: true, hasPrimaryAction: true)
        heading.frame = layout.title
        let search = Appearance.icon("ic_search", label: Appearance.text("search_label")) { [weak self] in self?.openSearch() }
        search.accessibilityIdentifier = "queueSearch"; search.frame = layout.primaryAction
        let menu = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in
            guard let self else { return }
            // `queue.xml`: items without a menu category come before `container` ones, in XML order
            // within each group: Sort, Clear queue, Refresh, Lock queue.
            var entries: [(String, String, () -> Void)] = []
            if queueInteractionPreferences != nil {
                entries.append((Appearance.text("sort"), "queueSort", { [weak self] in self?.showQueueSort() }))
            }
            if library != nil {
                entries.append((Appearance.text("clear_queue_label"), "queueClear", { [weak self] in self?.confirmClearQueue() }))
            }
            entries.append((Appearance.text("refresh_label"), "queueRefresh", { [weak self] in self?.requestFeedRefresh(nil) }))
            if queueInteractionPreferences != nil && queuePolicy.showsLockEntry {
                entries.append((Appearance.text("lock_queue"), "queueLock", { [weak self] in self?.toggleQueueLock() }))
            }
            showFeedMenu(entries, identifier: "queueMenu", checked: queuePolicy.locked ? ["queueLock"] : [])
        }
        menu.accessibilityIdentifier = "queueMore"; menu.frame = layout.overflow
        toolbar.addSubview(search); toolbar.addSubview(menu)
    }
    /// The library places additions with the stored Enqueue location and Keep sorted.
    func applyQueueInsertionSettings() {
        library?.setQueueInsertionSettings(accountPolicy.queueInsertionSettings())
    }

    /// `QueueFragment.QueueSortDialog`: every tap is saved and re-sorts the whole queue once.
    func showQueueSort() {
        guard queueVisible, presentedViewController == nil, queueInteractionPreferences != nil else { return }
        queueDragController?.cancel()
        let policy = accountPolicy
        let sheet = QueueSortController(state: .init(keepSorted: policy.keepSorted, storedOrder: policy.keepSortedOrder))
        var previous: Task<Void, Never>?
        sheet.onChange = { [weak self] state in
            guard let self, let order = state.order else { return }
            do { try policy.setKeepSorted(state.keepSorted, order: order) } catch { showError(error); return }
            applyQueueInsertionSettings()
            queueKeepSortedChanged()
            guard let library else { return }
            // Taps re-sort in the order they were made.
            let prior = previous
            previous = Task { [weak self] in
                await prior?.value
                do { _ = try await library.reorderQueue(order) } catch { self?.showError(error); return }
                await self?.reloadLibrary()?.value
            }
        }
        present(sheet, animated: true)
    }
    /// Lock and drag handles follow Keep sorted at once (`refreshToolbarState` on every QueueEvent).
    private func queueKeepSortedChanged() {
        for (_, row) in episodeRows.values { row.setQueueInteraction(queuePolicy); row.layoutIfNeeded() }
        fitQueueRowsToHandles()
        updateFeedSelection()
    }
    /// The handles' change of the text width moves some titles between one and two lines: every loaded row takes the
    /// height it needs now (the rows below move), as Android's rows rebind (`updateDragDropEnabled`).
    private func fitQueueRowsToHandles() {
        guard let list = episodeList else { return }
        var measure = rowMeasure()
        for id in list.ids {
            guard let value = displayedEpisodeValues[id] else { continue }
            list.setHeight(measure.height(feed: value.feed, stored: value.episode), of: id, in: content)
        }
        list.restoreViewOrder(in: content)
        episodeListResized()
        updateVisibleContent()
    }

    /// `QueueFragment`'s empty view (`EmptyViewHandler`): `ic_playlist_play`, its title and message, and while the Inbox
    /// has new episodes their invitation with Go to inbox (`loadItems`).
    func queueEmpty() {
        queueEmptyOffersInbox = mirror.inboxCount > 0
        listEmpty(icon: "ic_playlist_play", title: "no_items_header_label",
                  message: queueEmptyOffersInbox ? "no_queue_items_inbox_has_items_label" : "no_items_label", identifier: "queue",
                  button: queueEmptyOffersInbox ? ("no_queue_items_inbox_has_items_button_label", { [weak self] in self?.select(.inbox) }) : nil)
    }

    /// `QueueFragment` Clear queue: confirmation, then `DBWriter.clearQueue` (no Undo, no snackbar).
    func confirmClearQueue() {
        guard queueVisible, presentedViewController == nil, let library else { return }
        queueDragController?.cancel()
        present(SourceMessageController(title: Appearance.text("clear_queue_label"), message: Appearance.text("clear_queue_confirmation_msg"),
            positive: .init(title: Appearance.text("confirm_label"), identifier: "queueClearConfirm", perform: { [weak self] in
                Task { [weak self] in
                    do { _ = try await library.clearQueue() } catch { self?.showError(error); return }
                    // Every list reloads, so no "in queue" indicator stays stale (Android defect not copied).
                    await self?.reloadLibrary(preservingEpisodeDetails: true)?.value
                }
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "queueClearCancel")), animated: true)
    }

    func toggleQueueLock() {
        guard queueVisible, let preferences = queueInteractionPreferences else { return }
        queueDragController?.cancel()
        if !preferences.value.locked && preferences.value.showLockWarning {
            present(QueueLockWarningController.make { [weak self] suppress in
                guard let self, queueVisible, !preferences.value.locked else { return }
                do { try preferences.confirmLock(doNotShowAgain: suppress); queueLockChanged() }
                catch { showError(error) }
            }, animated: true)
        } else {
            do { try preferences.toggleWithoutWarning(); queueLockChanged() }
            catch { showError(error) }
        }
    }
    private func queueLockChanged() {
        for (_, row) in episodeRows.values { row.setQueueInteraction(queuePolicy); row.layoutIfNeeded() }
        fitQueueRowsToHandles()
        updateFeedSelection()
        if queuedEpisodes.isEmpty { showEpisodeActionMessage(Appearance.text(queuePolicy.locked ? "queue_locked" : "queue_unlocked")) }
    }
    func attachQueueDrag() {
        guard let episodeList else { queueDragController = nil; return }
        let controller = QueueDragController(episodes: queuedEpisodes, list: episodeList, scroll: content,
            policy: { [weak self] in
                guard let self, queueVisible, queueMoveTask == nil, presentedViewController == nil else { return .init(locked: true) }
                return queuePolicy
            }, commit: { [weak self] move, captured in self?.commitQueueMove(move, captured: captured) })
        controller.released = { [weak self] id in
            guard let self, let list = self.episodeList, let value = libraryEpisode(id) else { return }
            repaintRow(id, value: value, in: list)
            list.restoreViewOrder(in: content)
        }
        // Rows built later (as they come near the screen) are attached when they are built.
        for (id, (_, row)) in episodeRows { controller.attach(row, id: id) }
        queueDragController = controller
    }
    /// Move to top or bottom: the episodes move in the queue as it is at the tap.
    func moveQueue(to boundary: QueueBoundary, ids: [Int64], bulk: Bool) {
        guard queueVisible, queueMoveTask == nil, queuePolicy.canMove(ids, in: queuedEpisodes.map(\.id), to: boundary, bulk: bulk) else { return }
        let snapshot = queuedEpisodes.map(QueueEpisodeIdentity.init)
        if bulk { endFeedSelection() }
        commitQueueMove(.boundary(ids, boundary), captured: snapshot)
    }
    private func commitQueueMove(_ move: QueueManualMove, captured: [QueueEpisodeIdentity]) {
        guard let library, queueVisible, queueMoveTask == nil else { return }
        let presentation = queuePresentationID
        queueMoveTask = Task { [weak self] in
            guard let self else { return }
            defer { queueMoveTask = nil }
            do {
                var result = try await library.performQueueMove(move, expected: captured)
                // Move to top or bottom moves the episodes by id in the queue as stored (`DBWriter.moveQueueItemToTop`):
                // a change the screen has not shown yet does not drop it (the screen then reads it). A drag keeps the
                // order it was made over.
                var behind = false
                if result.status == .stale, case .boundary = move {
                    behind = true
                    result = try await library.performQueueMove(move, expected: library.queue().map(QueueEpisodeIdentity.init))
                }
                guard queueVisible, queuePresentationID == presentation else {
                    // The accepted move may finish after resize/navigation rebuilt
                    // the rows. Reconcile from storage instead of leaving that
                    // newer presentation with its pre-commit cached order.
                    reloadLibrary(preservingEpisodeDetails: true)
                    return
                }
                if behind || result.status == .stale || queuedEpisodes.map(QueueEpisodeIdentity.init) != captured { reloadLibrary(); return }
                mirror.reorderQueue(result.change.episodeIDs)
                episodeList?.reorder(queuedEpisodes.map(\.id))
                if let screen = listScreen, case .queue = screen.source { listScreen?.source = .queue(queuedEpisodes.map(\.id)) }
                else { feedSelectionIDs = queuedEpisodes.map(\.id) }
                attachQueueDrag(); updateQueueInformation()
            } catch {
                guard queueVisible, queuePresentationID == presentation else { return }
                queueDragController?.cancel(); showError(error)
            }
        }
    }

    func updateQueueInformation() {
        let info = QueueInformation(items: queuedEpisodes.map {
            .init(episodeID: $0.id, feedID: libraryEpisode($0.id)?.feed.id ?? 0, position: $0.userState.positionMilliseconds,
                  duration: $0.details.media?.durationMilliseconds)
        }, speeds: speedPreferences?.value ?? .init(), respectsSpeed: timeDisplayPreferences?.value.timeRespectsSpeed == true)
        let count = Appearance.quantity("num_episodes", count: Int64(info.count))
        let duration = info.durationText { key, count in String.localizedStringWithFormat(Appearance.text(key), count) }
        queueInformationLabel.text = String(format: Appearance.text("queue_time_left_label"), count, duration)
        view.setNeedsLayout()
    }
}

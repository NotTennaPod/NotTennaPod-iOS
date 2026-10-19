import UIKit
import NotTennaPodCore

// Downloads screen, download log and download actions.
extension LibraryViewController {
    var downloadsDeleteButton: Bool {
        if case .destination(.downloads) = path.last { return downloadPreferences?.value.buttonActionPlay != true }
        return false
    }
    /// DownloadsList lists downloaded episodes and those of active jobs: read from the kept downloaded set and the
    /// active jobs' addresses, proportional to the downloads, never to the library.
    func downloadsRows() -> [(LibraryFeed, LibraryEpisode)] {
        mirror.downloads(jobs: downloads?.jobs ?? [], order: downloadPreferences?.value.listSortOrder).compactMap { libraryEpisode($0) }
    }
    func renderDownloads(heading: UILabel) {
        let rows = openCollectionList(.downloads)
        if rows.isEmpty { downloadsEmpty() } else { episodes(rows) }
        let layout = toolbarLayout(hasOverflow: true, hasPrimaryAction: true, hasSecondaryAction: true)
        heading.frame = layout.title
        let history = Appearance.icon("ic_history", label: Appearance.text("downloads_log_label")) { [weak self] in self?.showDownloadLog() }
        history.accessibilityIdentifier = "openDownloadLog"; history.frame = layout.primaryAction
        let search = Appearance.icon("ic_search", label: Appearance.text("search_label")) { [weak self] in self?.openSearch() }
        search.accessibilityIdentifier = "downloadsSearch"; search.frame = layout.secondaryAction
        let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in self?.showDownloadsMenu() }
        more.accessibilityIdentifier = "downloadsMore"; more.frame = layout.overflow
        [search, history, more].forEach(toolbar.addSubview)
    }
    private func downloadsEmpty() {
        let icon = UIImageView(image: UIImage(named: "ic_download")); icon.tintColor = Appearance.foreground
        let title = Appearance.label(Appearance.text("no_comp_downloads_head_label"), size: 16)
        let message = Appearance.label(Appearance.text("no_comp_downloads_label"), size: 14)
        message.textColor = Appearance.secondary
        title.textAlignment = .center; message.textAlignment = .center
        let width = max(0, content.bounds.width - 80)
        let titleHeight = title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 3
        let messageHeight = message.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 3
        let y = max(0, (content.bounds.height - 32 - titleHeight - messageHeight) / 2)
        icon.frame = CGRect(x: (content.bounds.width - 32) / 2, y: y, width: 32, height: 32)
        title.frame = CGRect(x: 40, y: icon.frame.maxY, width: width, height: titleHeight)
        message.frame = CGRect(x: 40, y: title.frame.maxY, width: width, height: messageHeight)
        [icon, title, message].forEach(content.addSubview)
    }
    private func showDownloadsMenu() {
        showFeedMenu([
            (Appearance.text("delete_downloads_played"), "downloadsDeletePlayed", { [weak self] in self?.confirmDeletePlayedDownloads() }),
            (Appearance.text("refresh_label"), "downloadsRefresh", { [weak self] in self?.requestFeedRefresh(nil) }),
            (Appearance.text("sort"), "downloadsSort", { [weak self] in self?.showDownloadsSort() })
        ], identifier: "downloadsMenu")
    }
    private func showDownloadsSort() {
        guard let downloadPreferences else { return }
        let editor = FeedSortEditor(selection: DownloadsList.order(downloadPreferences.value.listSortOrder), local: false,
            includesGlobal: false, fields: DownloadsList.sortFields, save: { [weak self] order in
                var value = downloadPreferences.value; value.listSortOrder = order
                try downloadPreferences.update(value)
                // A preference, not a library change: the open list is sorted again here, as the Inbox sort sheet does.
                self?.render()
            })
        presentFeedSort(editor)
    }
    private func confirmDeletePlayedDownloads() {
        guard library != nil else { return }
        present(SourceMessageController(title: Appearance.text("delete_downloads_played"), message: Appearance.text("delete_downloads_played_confirmation"),
            positive: .init(title: Appearance.text("confirm_label"), identifier: "downloadsDeletePlayedConfirm", perform: { [weak self] in
                Task {
                    // The downloaded episodes the screens keep, current to every commit (proportional to the downloads,
                    // not the library).
                    guard let self else { return }
                    await self.settleLibraryChanges()
                    let ids = DownloadsList.playedDownloadIDs(self.mirror.downloadedIDs.sorted().compactMap { self.mirror.episode($0)?.episode })
                    guard !ids.isEmpty else { return }
                    self.performEpisodeListAction(.delete, ids: ids, selection: true)
                }
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "downloadsDeletePlayedCancel")), animated: true)
    }

    func showDownloadLog() {
        guard let library else { return }
        let controller = DownloadLogController(library: library, retry: { [weak self] entry in
            guard let self else { return }
            if let episodeID = entry.episodeID {
                guard try await library.episode(id: episodeID) != nil, let downloads else { return }
                let decision = try await downloads.request(episodeID: episodeID)
                handleDownloadDecision(decision, episodeID: episodeID)
            } else if let feed = try await library.listedFeedHeader(id: entry.feedID), let manualRefresh {
                let accepted = manualRefresh.runOnce(feedID: feed.id, isLocalFeed: feed.source.isLocalFeedSource)
                _ = try await accepted.value
            }
        }, openFeed: { [weak self] id in
            Task { [weak self] in
                do {
                    guard let self, let feed = try await library.listedFeedHeader(id: id) else { return }
                    if feed.subscriptionState == .subscribed { await openNotification(.feed(id)) }
                    else { showPreview(id, recoveredBySearch: false) }
                } catch { self?.showError(error) }
            }
        }, failed: { [weak self] in self?.showError($0) })
        downloadLogSheet = controller
        messages.present(controller)
    }

    /// Every episode button on screen (rows, Home's rows in each section and its cards) shows the download and playback
    /// state, and the playing episode's row and card their background.
    func updateDownloadRows() {
        for (episode, card, localFeed) in homeCards {
            let job = downloads?.activeJob(source: episode.details.media?.url)
            let playing = playback?.episode?.id == episode.id && playback?.wantsPlayback == true
            card.actionButton.update(episode: episode, job: job, progress: job.flatMap { downloads?.progress[$0.id] },
                                     playing: playing,
                                     localFeed: localFeed, streamOverDownload: navigationPreferences?.value.streamOverDownload == true)
            card.setPlaying(playing)
        }
        let twins = homeRows.filter { episodeRows[$0.episode.id]?.1 !== $0.row }.map { ($0.episode, $0.row) }
        for (episode, row) in Array(episodeRows.values) + twins {
            let job = downloads?.activeJob(source: episode.details.media?.url)
            row.updateDownload(job: job, progress: job.flatMap { downloads?.progress[$0.id] },
                               playing: playback?.episode?.id == episode.id && playback?.wantsPlayback == true,
                               streamOverDownload: navigationPreferences?.value.streamOverDownload == true)
        }
        updateEpisodeHeader()
        if case .search(let search) = path.last, search.selection.active { search.updateSelection() }
        if currentSelectionScope != nil, feedSelection.active { updateFeedSelection() }
    }

    func downloadAction(_ episodeID: Int64) {
        guard let library else { return }
        Task { [weak self] in
            do {
                let feedID = try await library.feedID(forEpisode: episodeID)
                guard let feed = try await library.listedFeedHeader(id: feedID), try await library.feedID(forEpisode: episodeID) == feedID,
                      let episode = try await library.episode(id: episodeID), episode.details.media != nil else { return }
                let currentlyPlaying = self?.playback?.episode?.id == episodeID && self?.playback?.wantsPlayback == true
                if currentlyPlaying {
                    try await self?.playback?.toggle(episodeID: episodeID)
                    return
                }
                // Local documents are not owned downloads. Like PlayLocalActionButton,
                // select/resume through playback before download repair or transfer rules.
                if feed.source.isLocalFeedSource {
                    self?.preferVideoInThisScene()
                    try await self?.playback?.select(episodeID: episodeID)
                    return
                }
                if episode.userState.isDownloaded,
                   try await library.repairMissingDownloadedMedia(episodeID: episodeID) {
                    self?.showNotice(Appearance.text("error_file_not_found"))
                    self?.reloadLibrary(preservingEpisodeDetails: true)
                    return
                }
                if episode.userState.isDownloaded {
                    self?.preferVideoInThisScene()
                    try await self?.playback?.toggle(episodeID: episodeID)
                    return
                }
                guard let downloads = self?.downloads else { return }
                try await downloads.refresh()
                if downloads.activeJob(source: episode.details.media?.url) != nil { try await downloads.cancel(episodeID: episodeID) }
                else if self?.navigationPreferences?.value.streamOverDownload == true {
                    self?.logUsage(.stream)
                    self?.preferVideoInThisScene()
                    try await self?.playback?.select(episodeID: episodeID)
                }
                else {
                    self?.logUsage(.download)
                    let decision = try await downloads.request(episodeID: episodeID)
                    self?.handleDownloadDecision(decision, episodeID: episodeID)
                }
            } catch is CancellationError { }
            catch { self?.showError(error) }
        }
    }

    func handleDownloadDecision(_ decision: DownloadActionPolicy.Decision, episodeID: Int64) {
        switch decision {
        case .ignored: break
        case .request(_, let showNotice): if showNotice { showMobileDownloadNotice() }
        case .confirmation:
            let dialog = UIAlertController(title: Appearance.text("confirm_mobile_download_dialog_title"),
                                           message: Appearance.text("confirm_mobile_download_dialog_message"), preferredStyle: .alert)
            for (key, choice) in [("confirm_mobile_download_dialog_download_later", DownloadActionPolicy.Choice.later),
                                  ("confirm_mobile_download_dialog_allow_this_time", .now)] {
                dialog.addAction(UIAlertAction(title: Appearance.text(key), style: .default) { [weak self] _ in
                    guard let self, let downloads else { return }
                    Task {
                        do {
                            let decision = try await downloads.confirm(episodeID: episodeID, choice: choice)
                            handleDownloadDecision(decision, episodeID: episodeID)
                        } catch is CancellationError { }
                        catch { showError(error) }
                    }
                })
            }
            dialog.addAction(UIAlertAction(title: Appearance.text("cancel_label"), style: .cancel))
            messages.present(dialog)
        }
    }

    private func showMobileDownloadNotice() {
        showNotice(String(format: Appearance.text("mobile_download_notice"), 5))
    }
}

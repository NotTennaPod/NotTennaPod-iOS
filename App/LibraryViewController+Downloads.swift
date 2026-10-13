import UIKit
import NotTennaPodCore

// Downloads screen, download log and download actions.
extension LibraryViewController {
    var downloadsDeleteButton: Bool {
        if case .destination(.downloads) = path.last { return downloadPreferences?.value.buttonActionPlay != true }
        return false
    }
    func downloadsRows() -> [(LibraryFeed, LibraryEpisode)] {
        // DownloadsList lists downloaded episodes and those of active jobs; only those are gathered, so a large
        // library is not copied on every download update.
        let jobs = downloads?.jobs ?? []
        let active = jobs.filter { $0.state.isActive }.map(\.source)
        // A string set finds candidates without copying every address; equal code units always hash equal, and
        // the code-unit comparison keeps the exact source match.
        let sources = Set(active)
        func activeSource(_ url: String?) -> Bool {
            guard !active.isEmpty, let url, sources.contains(url) else { return false }
            return active.contains { $0.utf16.elementsEqual(url.utf16) }
        }
        let candidates = feeds.flatMap { feed in
            feed.episodes.filter { episode in
                episode.userState.isDownloaded || activeSource(episode.details.media?.url)
            }
        }
        return DownloadsList.episodes(candidates, jobs: jobs, order: downloadPreferences?.value.listSortOrder)
            .compactMap { episode in libraryEpisode(episode.id).map { ($0.feed, episode) } }
    }
    func renderDownloads(heading: UILabel) {
        let rows = downloadsRows()
        feedSelectionIDs = rows.map { $0.1.id }
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
            includesGlobal: false, fields: DownloadsList.sortFields, save: { order in
                var value = downloadPreferences.value; value.listSortOrder = order
                try downloadPreferences.update(value)
            })
        presentFeedSort(editor)
    }
    private func confirmDeletePlayedDownloads() {
        guard let library else { return }
        present(SourceMessageController(title: Appearance.text("delete_downloads_played"), message: Appearance.text("delete_downloads_played_confirmation"),
            positive: .init(title: Appearance.text("confirm_label"), identifier: "downloadsDeletePlayedConfirm", perform: { [weak self] in
                Task {
                    do {
                        let snapshot = try await library.snapshot()
                        let ids = DownloadsList.playedDownloadIDs(snapshot.feeds.flatMap(\.episodes))
                        guard !ids.isEmpty else { return }
                        self?.performEpisodeListAction(.delete, ids: ids, selection: true)
                    } catch { self?.showError(error) }
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
            } else if let feed = try await library.feed(id: entry.feedID), let manualRefresh {
                let accepted = manualRefresh.runOnce(feedID: feed.id, isLocalFeed: feed.source.isLocalFeedSource)
                _ = try await accepted.value
            }
        }, openFeed: { [weak self] id in
            Task { [weak self] in
                do {
                    guard let self, let feed = try await library.feed(id: id) else { return }
                    if feed.subscriptionState == .subscribed { await openNotification(.feed(id)) }
                    else { showPreview(id, recoveredBySearch: false) }
                } catch { self?.showError(error) }
            }
        }, failed: { [weak self] in self?.showError($0) })
        downloadLogSheet = controller
        messages.present(controller)
    }

    func updateDownloadRows() {
        for (episode, card, localFeed) in homeCards {
            let job = downloads?.activeJob(source: episode.details.media?.url)
            card.actionButton.update(episode: episode, job: job, progress: job.flatMap { downloads?.progress[$0.id] },
                                     playing: playback?.episode?.id == episode.id && playback?.wantsPlayback == true,
                                     localFeed: localFeed, streamOverDownload: navigationPreferences?.value.streamOverDownload == true)
        }
        for (episode, row) in episodeRows.values {
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
                guard let feed = try await library.feed(id: feedID),
                      let episode = feed.episodes.first(where: { $0.id == episodeID }), episode.details.media != nil else { return }
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

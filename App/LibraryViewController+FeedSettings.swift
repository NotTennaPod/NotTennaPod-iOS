import UIKit
import NotTennaPodCore

// Per-feed settings screen and its editors.
extension LibraryViewController {
    func feedSettingsScreen(_ feed: LibraryFeed) {
        if let heading = toolbar.subviews.compactMap({ $0 as? UILabel }).first {
            let frame = heading.frame
            heading.font = Appearance.font(20)
            heading.frame = CGRect(x: frame.minX, y: 4, width: frame.width, height: 28)
            let subtitle = Appearance.label(feed.title, size: 14)
            subtitle.accessibilityIdentifier = "feedSettingsSubtitle"
            subtitle.numberOfLines = 1; subtitle.lineBreakMode = .byTruncatingTail
            subtitle.frame = CGRect(x: frame.minX, y: 32, width: frame.width, height: 20)
            toolbar.addSubview(subtitle)
        }
        let settings = FeedSettingsView(feed: feed, deletionPreferences: downloadPreferences?.value.playbackEnd ?? .init(),
            globalNewEpisodesAction: accountPolicy.newEpisodesAction, globalAutoDownload: automaticDownloadPreferences?.value.global ?? false,
            serverLibrary: library?.isServerLibraryAtOpen ?? false)
        settings.onAction = { [weak self] action in
            guard let self, library != nil else { return }
            switch action {
            case .rename:
                let input = FeedURLEditInputView(value: feed.title ?? "")
                input.textView.accessibilityIdentifier = "feedRenameInput"
                input.textView.accessibilityLabel = Appearance.text("rename_feed_label")
                let dialog = SourceMessageController(title: Appearance.text("rename_feed_label"), message: "",
                    positive: .init(title: Appearance.text("ok"), identifier: "feedRenameConfirm", perform: { [weak self] in
                        let value = input.value
                        self?.writeFeedPreference(feedID: feed.id) { $0.customTitle = value == feed.metadata.title ? nil : value }
                    }), negative: .init(title: Appearance.text("cancel_label"), identifier: "feedRenameCancel"),
                    neutral: .init(title: Appearance.text("reset"), identifier: "feedRenameReset", perform: {
                        input.textView.text = feed.title ?? ""; input.textViewDidChange(input.textView)
                    }, dismisses: false), customBody: input)
                dialog.avoidsKeyboard = true
                input.onSizeChange = { [weak dialog] in dialog?.viewIfLoaded?.setNeedsLayout() }
                present(dialog, animated: true)
            case .tags:
                editFeedTags(feed.id)
            case .playbackSpeed:
                guard let speedPreferences else { return }
                present(FeedPlaybackSpeedController.make(feedID: feed.id, preferences: speedPreferences) { [weak self] draft in
                    do { try speedPreferences.setFeed(feed.id, speed: draft.savedSpeed, skipSilence: draft.savedSilence) }
                    catch { self?.showError(error) }
                }, animated: true)
            case .authentication: editFeedCredentials(feed)
            case .autoSkip: editFeedSkip(feed.id)
            case .volumeAdaptation: editFeedVolume(feed.id)
            case .autoDelete: editFeedAutoDelete(feed.id)
            case .newEpisodes: editFeedNewEpisodes(feed.id)
            case .autoDownload: editFeedAutoDownload(feed.id)
            case .downloadFilter: editFeedDownloadFilter(feed.id)
            case .keepUpdated(let value): writeFeedPreference(feedID: feed.id) { $0.keepUpdated = value }
            case .notification(let value): writeFeedPreference(feedID: feed.id) { $0.showEpisodeNotification = value }
            }
        }
        content.addSubview(settings)
        settings.frame = CGRect(origin: .zero, size: settings.sizeThatFits(content.bounds.size))
        content.contentSize.height = max(content.bounds.height, settings.frame.height)
    }

    private func editFeedCredentials(_ feed: LibraryFeed) {
        guard let feedAuthentication, let manualRefresh, feedCredentialEdit?.isBusy != true else { return }
        let flow = FeedCredentialEditFlow(authentication: feedAuthentication, feedID: feed.id,
            requestRefresh: { try await manualRefresh.runOnce(feedID: feed.id).value },
            failed: { [weak self] in self?.showError($0) })
        feedCredentialEdit = flow
        flow.show(from: self) { [weak self] in
            guard case .feedSettings(let id) = self?.path.last else { return false }
            return id == feed.id
        }
    }

    private func editFeedAutoDownload(_ feedID: Int64) {
        guard let library else { return }
        Task { [weak self] in
            await self?.feedPreferenceWrite?.value
            do {
                guard let feed = try await library.feed(id: feedID), let self,
                      case .feedSettings(let currentID) = path.last, currentID == feedID,
                      !feed.source.isLocalFeedSource, presentedViewController == nil else { return }
                let values = FeedAutoDownload.displayOrder
                present(SourceSingleChoiceController(title: Appearance.text("auto_download_label"),
                    identifier: "feedAutoDownload", choices: values.map { (String($0.rawValue), Appearance.text($0.titleKey)) },
                    selectedIndex: values.firstIndex(of: feed.autoDownload)) { [weak self] index in
                        self?.writeFeedPreference(feedID: feedID) { $0.autoDownload = values[index] }
                    }, animated: true)
            } catch { self?.showError(error) }
        }
    }

    private func editFeedDownloadFilter(_ feedID: Int64) {
        guard let library else { return }
        Task { [weak self] in
            await self?.feedPreferenceWrite?.value
            do {
                guard let feed = try await library.feed(id: feedID), let self,
                      case .feedSettings(let currentID) = path.last, currentID == feedID,
                      feed.newEpisodeActionIsAutomatic(globalAutoDownload: automaticDownloadPreferences?.value.global ?? false),
                      presentedViewController == nil else { return }
                present(AutomaticDownloadFilterController.make(value: feed.automaticDownloadFilter) { [weak self] value in
                    self?.writeFeedPreference(feedID: feedID) { $0.automaticDownloadFilter = value }
                }, animated: true)
            } catch { self?.showError(error) }
        }
    }

    private func editFeedNewEpisodes(_ feedID: Int64) {
        guard let library else { return }
        Task { [weak self] in
            await self?.feedPreferenceWrite?.value
            do {
                guard let feed = try await library.feed(id: feedID), let self,
                      case .feedSettings(let currentID) = path.last, currentID == feedID,
                      presentedViewController == nil else { return }
                // In a server library automatic download never forces the Inbox (PROTOCOL §9.10): the action stays the person's.
                if !library.isServerLibraryAtOpen, feed.newEpisodeActionIsAutomatic(globalAutoDownload: automaticDownloadPreferences?.value.global ?? false) {
                    if showSnackbar(Appearance.text("feed_new_episodes_action_snackbar")) {
                        visibleSnackbar?.accessibilityIdentifier = "feedNewEpisodesSnackbar"
                    }
                    return
                }
                let values = NewEpisodesAction.displayOrder
                present(SourceSingleChoiceController(title: Appearance.text("pref_new_episodes_action_title"),
                    identifier: "feedNewEpisodes", choices: values.map { (String($0.rawValue), Appearance.text($0.titleKey)) },
                    selectedIndex: values.firstIndex(of: feed.newEpisodesAction)) { [weak self] index in
                        self?.writeFeedPreference(feedID: feedID) { $0.newEpisodesAction = values[index] }
                    }, animated: true)
            } catch { self?.showError(error) }
        }
    }

    private func editFeedAutoDelete(_ feedID: Int64) {
        guard let library else { return }
        Task { [weak self] in
            await self?.feedPreferenceWrite?.value
            do {
                guard let feed = try await library.feed(id: feedID), let self,
                      case .feedSettings(let currentID) = path.last, currentID == feedID,
                      presentedViewController == nil else { return }
                let values = FeedAutoDelete.allCases
                present(SourceSingleChoiceController(title: Appearance.text("pref_auto_delete_playback_title"),
                    identifier: "feedAutoDelete", choices: values.map { (String($0.rawValue), Appearance.text($0.titleKey)) },
                    selectedIndex: values.firstIndex(of: feed.autoDelete)) { [weak self] index in
                        self?.writeFeedPreference(feedID: feedID) { $0.autoDelete = values[index] }
                    }, animated: true)
            } catch { self?.showError(error) }
        }
    }

    private func editFeedVolume(_ feedID: Int64) {
        guard let library else { return }
        Task { [weak self] in
            await self?.feedPreferenceWrite?.value
            do {
                guard let feed = try await library.feed(id: feedID), let self,
                      case .feedSettings(let currentID) = path.last, currentID == feedID,
                      presentedViewController == nil else { return }
                let values = FeedVolumeAdaptation.displayOrder
                let dialog = SourceSingleChoiceController(title: Appearance.text("feed_volume_adapdation"),
                    identifier: "feedVolume", choices: values.map { (String($0.rawValue), Appearance.text($0.titleKey)) },
                    selectedIndex: values.firstIndex(of: feed.volumeAdaptation) ?? 2) { [weak self] index in
                        self?.writeFeedPreference(feedID: feedID, afterSave: { [weak self] in
                            try await self?.playback?.refreshVolumeAdaptation(feedID: feedID)
                        }) { $0.volumeAdaptation = values[index] }
                    }
                present(dialog, animated: true)
            } catch { self?.showError(error) }
        }
    }

    private func editFeedSkip(_ feedID: Int64) {
        guard let library else { return }
        Task { [weak self] in
            await self?.feedPreferenceWrite?.value
            do {
                guard let feed = try await library.feed(id: feedID), let self,
                      case .feedSettings(let currentID) = path.last, currentID == feedID,
                      presentedViewController == nil else { return }
                present(FeedAutoSkipController.make(value: feed.skipPreferences) { [weak self] value in
                    self?.writeFeedPreference(feedID: feedID) { $0.skip = value }
                }, animated: true)
            } catch { self?.showError(error) }
        }
    }

    private func editFeedTags(_ feedID: Int64) {
        guard let library else { return }
        Task { [weak self] in
            // A quick reopen must see the completed preceding Save.
            await self?.feedPreferenceWrite?.value
            do {
                guard let feed = try await library.feed(id: feedID), let self,
                      case .feedSettings(let currentID) = path.last, currentID == feedID,
                      presentedViewController == nil else { return }
                let stored = feed.tags.map { Array($0.utf16) }
                let draft = feedSettingsTagDraft.flatMap {
                    $0.feedID == feedID && $0.saved == stored ? $0.draft : nil
                } ?? FeedTags(tags: feed.tags)
                present(FeedTagsController.make(draft: draft, suggestions: FeedTags.suggestions(in: feeds),
                    bottomNavigation: bottomNavigationEnabled) { [weak self] edited in
                        guard let self else { return }
                        let tags = edited.saved, units = tags.map { Array($0.utf16) }
                        feedSettingsTagDraft = (feedID, units, edited.reopeningSaved())
                        writeFeedPreference(feedID: feedID, completion: { [weak self] succeeded in
                            if !succeeded, self?.feedSettingsTagDraft?.saved == units { self?.feedSettingsTagDraft = nil }
                        }) { $0.tags = tags }
                    }, animated: true)
            } catch { self?.showError(error) }
        }
    }

    private func writeFeedPreference(feedID: Int64, completion: ((Bool) -> Void)? = nil,
                                     afterSave: (() async throws -> Void)? = nil, change: @escaping @Sendable (inout FeedLibraryPreferences) -> Void) {
        guard let library else { return }
        let previous = feedPreferenceWrite
        let request = UUID(); feedPreferenceWriteID = request
        feedPreferenceWrite = Task { [weak self] in
            await previous?.value
            do {
                try await library.updatePreferences(feedID: feedID, change: change)
                try await afterSave?()
                completion?(true)
                if self?.feedPreferenceWriteID == request { await self?.reloadLibrary(preservingEpisodeDetails: true)?.value }
            } catch {
                completion?(false)
                self?.showError(error)
                if self?.feedPreferenceWriteID == request { await self?.reloadLibrary(preservingEpisodeDetails: true)?.value }
            }
        }
    }
}

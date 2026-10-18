import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
@Suite(.serialized)
struct FeedInformationFlowTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition())
    }
    private func tap(_ id: String, in controller: UIViewController) throws {
        let button: UIControl = try #require(element(id, in: controller.view))
        button.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
    }
    private func run(local: Bool = false, server: Bool = false, defaultAfterOpening: String? = nil, speedPreferences: PlaybackSpeedPreferenceStore? = nil,
                     automaticDownloadPreferences: AutomaticDownloadPreferenceStore? = nil,
                     downloadPreferences: DownloadPreferenceStore? = nil,
                     _ body: @MainActor (LibraryViewController, FeedLibraryStore, LibraryFeed, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedInformationFlow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if server {
            // A server library (PROTOCOL §15.4), provisioned and reopened as the graph opens it; the subscription below
            // waits for its registration.
            let provisioning = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            let id = { ContractIdentity.randomUUID() }
            try await provisioning.initializeServerLibrary(ServerLibraryIdentity(libraryID: id(), serverURL: "http://127.0.0.1:1", serverID: nil,
                                                                                 accountID: id(), namespace: id(), username: "alice", installID: id(),
                                                                                 deviceMarker: nil))
            try await provisioning.close()
        }
        let library = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feed: LibraryFeed
        if local {
            let folder = root.appendingPathComponent("Original folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let selection = try await LocalFolderSelection.prepare(directory: folder)
            feed = try await library.registerLocalFolder(title: "Local podcast", directoryIdentity: selection.identity, bookmark: selection.bookmark).feed
        } else {
            feed = try await library.insert(FetchedFeed(feed: .init(format: .rss, title: "Information podcast",
                description: "<p>First paragraph.</p><p>Second paragraph.</p>", author: "Publisher", link: "https://example.org/podcast",
                episodes: (1...30).map { index in
                    ParsedEpisode(identifier: "episode-\(index)", title: "Episode \(index)",
                        media: ParsedMedia(url: "https://example.org/\(index).mp3", size: 1000, durationMilliseconds: 3_600_000))
                }), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        }
        let preferences = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        var value = preferences.value; value.defaultPage = NavigationDestination.subscriptions.rawValue
        try preferences.update(value)
        let controller = LibraryViewController(library: library, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: preferences, speedPreferences: speedPreferences, mobileNetworkPreferences: nil, usage: nil, feedDeletion: FeedDeletionCoordinator(store: library, retirePlayback: { _ in }, retireDownloads: { _ in }), automaticDownloadPreferences: automaticDownloadPreferences, downloadPreferences: downloadPreferences)
        try await wait { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer {
                controller.dismiss(animated: false)
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
            }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.reloadLibrary()?.value
            try tap("subscriptionFeed-\(feed.id)", in: controller)
            if let defaultAfterOpening {
                var updated = preferences.value; updated.defaultPage = defaultAfterOpening
                try preferences.update(updated)
            }
            try await body(controller, library, feed, root)
        }
        try await library.close()
    }

    @Test func episodeQueueActionStartsOwnedAutomaticDownloadAfterNavigatingBack() async throws {
        try await run { controller, library, feed, root in
            let episode = try #require(feed.episodes.first)
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: false, metered: true, cellular: false))
            let downloads = DownloadCoordinator(store: library, directory: root.appendingPathComponent("downloads"), network: network)
            var preferences = AutomaticDownloadPreferences(); preferences.queue = true
            let selected = preferences
            var gate: CheckedContinuation<Void, Never>?
            let owner = AutomaticDownloadCoordinator(store: library, preferences: { selected },
                environment: { .init(connection: .ethernet, allowMobile: false, charging: true) },
                cleanup: { _ in Issue.record("No cached media to clean") }, download: { id in
                    await withCheckedContinuation { gate = $0 }
                    try await downloads.requestAutomatic(episodeID: id)
                })
            defer { owner.suspend(); gate?.resume() }
            owner.resume()
            do {
                try tap("episode-\(episode.id)", in: controller)
                try tap("episodeMore", in: controller)
                try await wait { element("addToQueue", in: controller.view, as: UIButton.self) != nil }
                try tap("addToQueue", in: controller)
                try await wait { gate != nil }
                #expect(try await library.queue().map(\.id) == [episode.id])
                try tap("toolbarBack", in: controller)
                #expect(element("subscribedFeedHeader", in: controller.view, as: UIView.self) != nil)
                gate?.resume(); gate = nil
                try await wait { owner.state == .idle }
                let jobs = try await library.downloadJobs()
                #expect(jobs.count == 1 && jobs.first?.episodeID == episode.id)
                #expect(jobs.first?.networkConstraint == .unmetered)
                #expect(try await library.automaticDownloadRequest() == nil)
                #expect(element("subscribedFeedHeader", in: controller.view, as: UIView.self) != nil)
                owner.suspend()
                await downloads.stop()
            } catch {
                owner.suspend(); gate?.resume(); gate = nil
                await downloads.stop()
                throw error
            }
        }
    }

    @Test func headerOpensRetainedInformationCopiesCurrentURLAndReturnsToFeed() async throws {
        try await run { controller, library, feed, _ in
            try tap("feedInformation", in: controller)
            let information: UIView = try #require(element("feedInformationScreen", in: controller.view))
            let title: UILabel = try #require(element("feedTitle", in: information))
            #expect(title.text == feed.title && title.numberOfLines == 6)
            let filter: UIButton = try #require(element("feedFilter", in: information))
            #expect(filter.isHidden, "Information screen hides the episode filter")
            let previous = UIPasteboard.general.string
            defer { UIPasteboard.general.string = previous }
            try tap("urlLabel", in: controller)
            #expect(UIPasteboard.general.string == feed.source)
            for width in [800.0, 320, 402] {
                controller.view.frame.size.width = width
                controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 13, bottom: 0, right: 31)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                #expect(element("feedInformationScreen", in: controller.view, as: UIView.self) === information)
            }
            try await library.updatePreferences(feedID: feed.id) { $0.subscriptionState = .notSubscribed }
            await controller.reloadLibrary()?.value
            #expect(element("feedInformationScreen", in: controller.view, as: UIView.self) === information)
            let statistics: UIControl = try #require(element("statisticsButton", in: information))
            #expect(statistics.isHidden)
            try await library.updatePreferences(feedID: feed.id) { $0.subscriptionState = .subscribed }
            await controller.reloadLibrary()?.value
            try tap("toolbarBack", in: controller)
            #expect(element("subscribedFeedHeader", in: controller.view, as: UIView.self) != nil)
            #expect(element("episode-\(feed.episodes[0].id)", in: controller.view, as: UIButton.self) != nil)
        }
    }

    @Test func appBarParallaxPinsToolbarAndRestoresItsOffsetAfterInformation() async throws {
        try await run { controller, _, feed, _ in
            let scroll: UIScrollView = try #require(element("libraryContent", in: controller.view))
            let toolbar: UIView = try #require(element("mainToolbar", in: controller.view))
            let appBar: UIView = try #require(element("feedAppBar", in: controller.view))
            let header: UIView = try #require(element("subscribedFeedHeader", in: controller.view))
            let background: UIImageView = try #require(element("feedBackground", in: appBar))
            let title = try #require(toolbar.subviews.compactMap { $0 as? UILabel }.first)
            let pinned = toolbar.frame
            let originalHeader = header.convert(header.bounds, to: controller.view).minY
            let originalBackground = background.convert(background.bounds, to: controller.view).minY
            scroll.setContentOffset(CGPoint(x: 0, y: 80), animated: false)
            #expect(toolbar.frame == pinned && title.text == "")
            // Parallax: header and background move slower than the 80 pt scroll (source rates ±1 pt).
            #expect(abs(header.convert(header.bounds, to: controller.view).minY - originalHeader + 40) < 1)
            #expect(abs(background.convert(background.bounds, to: controller.view).minY - originalBackground + 32) < 1)
            #expect(abs(appBar.frame.height - (toolbar.bounds.height + 156 - 80)) < 1)
            try tap("feedInformation", in: controller)
            let share: UIButton = try #require(element("feedShare", in: controller.view))
            #expect(share.tintColor == .white)
            let informationScroll: UIScrollView = try #require(element("libraryContent", in: controller.view))
            #expect(informationScroll.contentSize.height - informationScroll.bounds.height >= 156)
            informationScroll.setContentOffset(CGPoint(x: 0, y: 156), animated: false)
            #expect(share.tintColor.resolvedColor(with: share.traitCollection)
                == Appearance.foreground.resolvedColor(with: share.traitCollection))
            try tap("toolbarBack", in: controller)
            #expect(abs(scroll.contentOffset.y - 80) < 1, "Returning from information restores the scroll position")
            scroll.setContentOffset(CGPoint(x: 0, y: 156), animated: false)
            let collapsedTitle = try #require(toolbar.subviews.compactMap { $0 as? UILabel }.first)
            #expect(collapsedTitle.text == feed.title)
            scroll.setContentOffset(.zero, animated: false)
            #expect(collapsedTitle.text == "")
        }
    }

    @Test(arguments: [NavigationDestination.subscriptions.rawValue, "remember", "unknown"])
    func removalRequiresSecondPressAndReturnsToDefaultBeforeDeleting(defaultPage: String) async throws {
        try await run(defaultAfterOpening: defaultPage) { controller, library, feed, root in
            try tap("feedListMore", in: controller); try tap("removeArchiveFeed", in: controller)
            let sheet = try #require(controller.presentedViewController as? RemoveFeedController)
            try await wait { sheet.view.window != nil && !sheet.isBeingPresented }
            try tap("removeFeedNext", in: sheet)
            #expect(try await library.feed(id: feed.id) != nil)
            #expect(element("removeFeedConfirm", in: sheet.view, as: UIButton.self) != nil)
            try tap("removeFeedCancel", in: sheet)
            try await wait { controller.presentedViewController == nil }
            #expect(try await library.feed(id: feed.id) != nil)
            try tap("feedListMore", in: controller); try tap("removeArchiveFeed", in: controller)
            let confirmed = try #require(controller.presentedViewController as? RemoveFeedController)
            try await wait { confirmed.view.window != nil && !confirmed.isBeingPresented }
            try tap("removeFeedNext", in: confirmed); try tap("removeFeedConfirm", in: confirmed)
            try await wait { try await library.feed(id: feed.id) == nil }
            try await wait { controller.presentedViewController == nil }
            #expect(element("feedAppBar", in: controller.view, as: UIView.self) == nil)
            if defaultPage == NavigationDestination.subscriptions.rawValue {
                #expect(element("subscriptionsAdd", in: controller.view, as: UIButton.self) != nil)
            } else {
                #expect(element("welcomeTitle", in: controller.view, as: UILabel.self) != nil)
            }
            let preferences = try JSONDecoder().decode(NavigationPreferences.self, from: Data(contentsOf: root.appendingPathComponent("navigation.json")))
            #expect(preferences.lastPage == defaultPage)
        }
    }

    @Test func archiveAndRestorePreserveEpisodesAndPreferences() async throws {
        try await run { controller, library, feed, _ in
            try tap("feedListMore", in: controller); try tap("removeArchiveFeed", in: controller)
            let sheet = try #require(controller.presentedViewController as? RemoveFeedController)
            try await wait { sheet.view.window != nil && !sheet.isBeingPresented }
            try tap("archiveFeed", in: sheet)
            try await wait { controller.presentedViewController == nil }
            #expect(try await library.feed(id: feed.id)?.subscriptionState == .archived)
            #expect(try await library.feed(id: feed.id)?.episodes == feed.episodes)
            try tap("feedListMore", in: controller); try tap("removeArchiveFeed", in: controller)
            let restore = try #require(controller.presentedViewController as? RemoveFeedController)
            try await wait { restore.view.window != nil && !restore.isBeingPresented }
            let action: UIButton = try #require(element("archiveFeed", in: restore.view))
            #expect(action.title(for: .normal) == Appearance.text("restore_archive_label"))
            try tap("archiveFeed", in: restore)
            try await wait { controller.presentedViewController == nil }
            let restored = try #require(try await library.feed(id: feed.id))
            #expect(restored.subscriptionState == .subscribed && restored.episodes == feed.episodes && restored.keepUpdated == feed.keepUpdated)
            #expect(element("subscribedFeedHeader", in: controller.view, as: UIView.self) != nil)
        }
    }

    @Test func dismissingProgressDoesNotCancelAcceptedRemoval() async throws {
        try await run { controller, library, feed, _ in
            var started = false, finished = false
            var release: CheckedContinuation<Void, Never>?
            defer { release?.resume() }
            let sheet = RemoveFeedController(feed: feed, remove: {
                started = true
                await withCheckedContinuation { release = $0 }
                _ = try await library.requestFeedDeletion(feedID: feed.id)
                finished = true
            }, archive: { _ in Issue.record("Unexpected archive") }, failed: { Issue.record($0) })
            controller.present(sheet, animated: false)
            try await wait { sheet.view.window != nil && !sheet.isBeingPresented }
            try tap("removeFeedNext", in: sheet); try tap("removeFeedConfirm", in: sheet)
            try await wait { started && release != nil }
            #expect(sheet.accessibilityPerformEscape())
            try await wait { controller.presentedViewController == nil }
            #expect(try await library.feed(id: feed.id) != nil)
            release?.resume(); release = nil
            try await wait { finished }
            #expect(try await library.feed(id: feed.id) == nil)
        }
    }

    @Test func notificationTapClearsChildNavigationAndOpensFeedOrInboxRoot() async throws {
        try await run { controller, _, feed, root in
            try tap("feedInformation", in: controller)
            #expect(element("statisticsButton", in: controller.view, as: UIButton.self) != nil)
            await controller.openNotification(.feed(feed.id))
            #expect(element("feedInformation", in: controller.view, as: UIButton.self) != nil)
            #expect(element("toolbarBack", in: controller.view, as: UIButton.self) == nil)
            let feedPreferences = try JSONDecoder().decode(NavigationPreferences.self, from: Data(contentsOf: root.appendingPathComponent("navigation.json")))
            #expect(feedPreferences.lastPage == String(feed.id))
            try tap("feedFilter", in: controller)
            try await wait { controller.presentedViewController?.view.window != nil }
            await controller.openNotification(.inbox)
            try await wait { controller.presentedViewController == nil }
            #expect(element("subscribedFeedHeader", in: controller.view, as: UIView.self) == nil)
            let heading: UILabel = try #require(element("screenTitle", in: controller.view))
            #expect(heading.text == Appearance.title(for: .inbox))
            let inboxPreferences = try JSONDecoder().decode(NavigationPreferences.self, from: Data(contentsOf: root.appendingPathComponent("navigation.json")))
            #expect(inboxPreferences.lastPage == NavigationDestination.inbox.rawValue)
        }
    }

    @Test func filterWritesThroughActualHeaderAndUpdatesRowsBeforeDismissal() async throws {
        try await run { controller, library, feed, _ in
            try tap("feedFilter", in: controller)
            let dialog = try #require(controller.presentedViewController as? FeedFilterController)
            try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
            try tap("feedFilter_is_favorite", in: dialog)
            try await wait { try await library.feed(id: feed.id)?.episodeFilter.isActive == true }
            try await wait { element("episode-\(feed.episodes[0].id)", in: controller.view, as: UIButton.self) == nil }
            try tap("feedFilterConfirm", in: dialog)
            try await wait { controller.presentedViewController == nil }
            let banner: UIControl = try #require(element("feedFiltered", in: controller.view))
            #expect(!banner.isHidden)
            banner.sendActions(for: .touchUpInside)
            let reopened = try #require(controller.presentedViewController as? FeedFilterController)
            try await wait { reopened.view.window != nil && !reopened.isBeingPresented }
            try tap("feedFilterReset", in: reopened)
            try await wait { try await library.feed(id: feed.id)?.episodeFilter.isActive == false }
            try tap("feedFilterConfirm", in: reopened)
            try await wait { controller.presentedViewController == nil }
            try await wait { element("episode-\(feed.episodes[0].id)", in: controller.view, as: UIButton.self) != nil }
        }
    }

    @Test func informationStatisticsRoutesShowStoredTotalsAndOpenPodcast() async throws {
        try await run { controller, _, feed, _ in
            try tap("feedInformation", in: controller)
            try tap("statisticsFragmentContainer", in: controller)
            let dialog = try #require(controller.presentedViewController as? SourceMessageController)
            try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
            try await wait {
                guard let card: UIView = element("statistics.durationTotal", in: dialog.view),
                      let value: UILabel = element("statisticsValue", in: card) else { return false }
                return value.text == "30.0 hours"
            }
            try tap("statisticsOK", in: dialog)
            try await wait { controller.presentedViewController == nil }
            try tap("statisticsButton", in: controller)
            // The screen loads its totals asynchronously (spinner first, as the source's progress bar).
            try await wait { element("subscriptionStatistics", in: controller.view, as: UIView.self) != nil }
            try tap("statisticsFeed-\(feed.id)", in: controller)
            let details = try #require(controller.presentedViewController as? SourceMessageController)
            try await wait { details.view.window != nil && !details.isBeingPresented }
            try tap("statisticsOpenPodcast", in: details)
            try await wait { controller.presentedViewController == nil }
            try await wait { element("subscribedFeedHeader", in: controller.view, as: UIView.self) != nil }
            #expect(element("toolbarBack", in: controller.view, as: UIControl.self) == nil)
        }
    }

    @Test(arguments: [false, true]) func feedSettingsTagsPersistCancelAndPreserveLocalAndRemoteState(local: Bool) async throws {
        try await run(local: local) { controller, library, feed, _ in
            try await library.updatePreferences(feedID: feed.id) { $0.tags = ["Existing", "#root"] }
            await controller.reloadLibrary()?.value
            let before = try #require(try await library.feed(id: feed.id))
            let effects = try await library.pendingEffects()
            try tap("feedSettings", in: controller)
            let rename: UIControl = try #require(element("feedRename", in: controller.view))
            let tags: UIControl = try #require(element("feedSettingsTags", in: controller.view))
            let updates: UIControl = try #require(element("feedKeepUpdated", in: controller.view))
            #expect(rename.frame.maxY <= tags.frame.minY && tags.frame.maxY < updates.frame.minY)
            #expect(tags.accessibilityLabel == "Tags" && tags.accessibilityHint == "Change the tags of this podcast to help organize your subscriptions")
            try tap("feedSettingsTags", in: controller)
            try await wait { controller.presentedViewController != nil }
            var dialog = try #require(controller.presentedViewController)
            try await wait { !dialog.isBeingPresented && dialog.view.window != nil }
            let field: UITextField = try #require(element("feedTagInput", in: dialog.view))
            let root: UIButton = try #require(element("feedTagsRoot", in: dialog.view))
            #expect(root.isHidden)
            field.text = "  Science  "; try tap("feedTagAdd", in: dialog)
            field.text = "Listening"; try tap("feedTagsSave", in: dialog)
            try await wait { controller.presentedViewController == nil }
            try await wait { Set(try await library.feed(id: feed.id)?.tags ?? []) == Set(["Existing", "Listening", "Science", "#root"]) }
            await controller.reloadLibrary()?.value
            try tap("feedSettingsTags", in: controller)
            try await wait { controller.presentedViewController != nil }
            dialog = try #require(controller.presentedViewController)
            try await wait { !dialog.isBeingPresented && dialog.view.window != nil }
            try tap("feedTagRemove-0", in: dialog)
            try tap("feedTagsCancel", in: dialog)
            try await wait { controller.presentedViewController == nil }
            let saved = try #require(try await library.feed(id: feed.id))
            #expect(Set(saved.tags) == Set(["Existing", "Listening", "Science", "#root"]))
            #expect(saved.episodes == before.episodes && saved.source == before.source && saved.subscriptionState == before.subscriptionState && saved.keepUpdated == before.keepUpdated)
            #expect(try await library.pendingEffects() == effects)
            try tap("toolbarBack", in: controller); try tap("feedSettings", in: controller)
            try tap("feedSettingsTags", in: controller)
            try await wait { controller.presentedViewController != nil }
            dialog = try #require(controller.presentedViewController)
            try await wait { !dialog.isBeingPresented && dialog.view.window != nil }
            #expect(element("feedTagRemove-2", in: dialog.view, as: UIButton.self) != nil)
            try tap("feedTagsCancel", in: dialog)
            try await wait { controller.presentedViewController == nil }
        }
    }

    @Test(arguments: [false, true]) func feedNewEpisodeSummaryReadsCurrentGlobalChoice(local: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("FeedGlobalNew-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let preferences = try DownloadPreferenceStore(file: file)
        var value = preferences.value; value.newEpisodesAction = .queue; try preferences.update(value)
        try await run(local: local, downloadPreferences: preferences) { controller, library, feed, _ in
            try tap("feedSettings", in: controller)
            let row: UIControl = try #require(element("feedSettingsNewEpisodes", in: controller.view))
            #expect(row.accessibilityHint == "Global default (Add to queue)")
            try tap("toolbarBack", in: controller)
            var changed = preferences.value; changed.newEpisodesAction = .nothing; try preferences.update(changed)
            try tap("feedSettings", in: controller)
            let reopened: UIControl = try #require(element("feedSettingsNewEpisodes", in: controller.view))
            #expect(reopened.accessibilityHint == "Global default (Nothing)")
            #expect(try await library.feed(id: feed.id)?.newEpisodesAction == .global)
        }
    }

    @Test(arguments: [false, true]) func feedDeletionSummaryReadsCurrentGlobalPreferences(local: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("FeedGlobalDeletion-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let preferences = try DownloadPreferenceStore(file: file)
        var value = preferences.value; value.autoDelete = !local; value.autoDeleteLocal = local
        try preferences.update(value)
        try await run(local: local, downloadPreferences: preferences) { controller, _, _, _ in
            try tap("feedSettings", in: controller)
            let row: UIControl = try #require(element("feedSettingsAutoDelete", in: controller.view))
            #expect(row.accessibilityHint == "Global default (Always)")
            try tap("toolbarBack", in: controller)
            var changed = preferences.value; changed.autoDelete = local; changed.autoDeleteLocal = !local
            try preferences.update(changed)
            try tap("feedSettings", in: controller)
            let reopened: UIControl = try #require(element("feedSettingsAutoDelete", in: controller.view))
            #expect(reopened.accessibilityHint == "Global default (Never)")
        }
    }

    @Test(arguments: [false, true]) func feedAutoDeletePersistsChoicesCancelAndSourceOrder(local: Bool) async throws {
        try await run(local: local) { controller, library, feed, root in
            try tap("feedSettings", in: controller)
            let row: UIControl = try #require(element("feedSettingsAutoDelete", in: controller.view))
            let notifications: UIControl = try #require(element("feedNotification", in: controller.view))
            #expect(row.frame.minY >= notifications.frame.maxY - 0.5 && row.frame.minY - notifications.frame.maxY < 1, "Directly after Notifications")
            #expect(row.accessibilityLabel == "Delete after playing")
            #expect(row.accessibilityHint == "Global default (Never)")
            @MainActor func open() async throws -> UIViewController {
                try tap("feedSettingsAutoDelete", in: controller)
                try await wait { controller.presentedViewController != nil }
                let dialog = try #require(controller.presentedViewController)
                try await wait { !dialog.isBeingPresented && dialog.view.window != nil }
                return dialog
            }
            for value in [FeedAutoDelete.always, .never, .global] {
                let dialog = try await open()
                let labels = FeedAutoDelete.allCases.compactMap { value in
                    (element("feedAutoDelete-\(value.rawValue)", in: dialog.view) as UIControl?)?.accessibilityLabel
                }
                #expect(labels == ["Global default", "Always", "Never"])
                try tap("feedAutoDelete-\(value.rawValue)", in: dialog)
                try await wait { controller.presentedViewController == nil }
                let reopened = try await open()
                #expect((element("feedAutoDelete-\(value.rawValue)", in: reopened.view) as UIControl?)?.accessibilityTraits.contains(.selected) == true)
                try tap("feedAutoDeleteCancel", in: reopened)
                try await wait { controller.presentedViewController == nil }
                #expect(try await library.feed(id: feed.id)?.autoDelete == value)
                let database = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
                #expect(try await database.feed(id: feed.id)?.autoDelete == value)
                try await database.close()
            }
            let saved = try #require(try await library.feed(id: feed.id))
            #expect(saved.episodes == feed.episodes && saved.keepUpdated == feed.keepUpdated)
            #expect(saved.tags == feed.tags && saved.volumeAdaptation == feed.volumeAdaptation)
        }
    }

    @Test(arguments: [false, true]) func newEpisodeChoicesPersistCancelAndPreserveExistingEpisodes(local: Bool) async throws {
        try await run(local: local) { controller, library, feed, root in
            try tap("feedSettings", in: controller)
            let row: UIControl = try #require(element("feedSettingsNewEpisodes", in: controller.view))
            let previous: UIControl = try #require(element("feedSettingsAutoDelete", in: controller.view))
            #expect(row.frame.minY >= previous.frame.maxY - 0.5 && row.frame.minY - previous.frame.maxY < 1, "Directly after Delete after playing")
            #expect(row.accessibilityLabel == "New episodes action")
            #expect(row.accessibilityHint == "Global default (Add to inbox)")
            @MainActor func open() async throws -> UIViewController {
                try tap("feedSettingsNewEpisodes", in: controller)
                try await wait { controller.presentedViewController != nil }
                let dialog = try #require(controller.presentedViewController)
                try await wait { !dialog.isBeingPresented && dialog.view.window != nil }
                return dialog
            }
            // This order is independent of enum/raw-value declaration order.
            for rawValue in [3, 2, 1, 0] {
                let dialog = try await open()
                let choices: [UIControl] = try [0, 1, 3, 2].map {
                    try #require(element("feedNewEpisodes-\($0)", in: dialog.view))
                }
                #expect(choices.map(\.accessibilityLabel) == ["Global default", "Add to inbox", "Add to queue", "Nothing"])
                #expect(zip(choices, choices.dropFirst()).allSatisfy { $0.frame.minY < $1.frame.minY })
                try tap("feedNewEpisodes-\(rawValue)", in: dialog)
                try await wait { controller.presentedViewController == nil }
                let reopened = try await open()
                #expect((element("feedNewEpisodes-\(rawValue)", in: reopened.view) as UIControl?)?.accessibilityTraits.contains(.selected) == true)
                try tap("feedNewEpisodesCancel", in: reopened)
                try await wait { controller.presentedViewController == nil }
                let database = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
                #expect(try await database.feed(id: feed.id)?.newEpisodesAction.rawValue == rawValue)
                try await database.close()
            }
            let saved = try #require(try await library.feed(id: feed.id))
            #expect(saved.episodes == feed.episodes && saved.autoDelete == feed.autoDelete)
            #expect(saved.keepUpdated == feed.keepUpdated && saved.tags == feed.tags)
            #expect(try await library.queue().isEmpty)
        }
    }

    @Test(arguments: [false, true]) func automaticDownloadsBlockRemoteChoiceButLocalFeedsRemainEditable(local: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("NewEpisodesAutomatic-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let automatic = try AutomaticDownloadPreferenceStore(file: file)
        var preferences = automatic.value; preferences.global = true
        try automatic.update(preferences)
        try await run(local: local, automaticDownloadPreferences: automatic) { controller, library, feed, _ in
            try await library.updatePreferences(feedID: feed.id) { $0.newEpisodesAction = .nothing }
            await controller.reloadLibrary()?.value
            try tap("feedSettings", in: controller)
            let row: UIControl = try #require(element("feedSettingsNewEpisodes", in: controller.view))
            #expect(row.accessibilityHint == (local ? "Nothing" : "Automatic download enabled. Episodes are added to the inbox and then moved to the queue once downloaded."))
            try tap("feedSettingsNewEpisodes", in: controller)
            if local {
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                try tap("feedNewEpisodesCancel", in: try #require(controller.presentedViewController))
                try await wait { controller.presentedViewController == nil }
            } else {
                try await wait { self.element("feedNewEpisodesSnackbar", in: controller.view, as: UIView.self) != nil }
                #expect(controller.presentedViewController == nil)
                #expect((element("feedNewEpisodesSnackbar", in: controller.view) as UIView?)?.accessibilityLabel == "Cannot be changed when automatic download is enabled.")
            }
            #expect(try await library.feed(id: feed.id)?.newEpisodesAction == .nothing)
        }
    }

    /// PROTOCOL §9.10: in a server library automatic download never forces the Inbox, so the "New episodes"
    /// row shows the podcast's own action, with the string it shows when automatic download is off, and opens its choices.
    @Test func aServerLibraryShowsTheRealNewEpisodesActionWithAutomaticDownload() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("NewEpisodesServer-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let automatic = try AutomaticDownloadPreferenceStore(file: file)
        var preferences = automatic.value; preferences.global = true
        try automatic.update(preferences)
        try await run(server: true, automaticDownloadPreferences: automatic) { controller, library, feed, _ in
            #expect(library.isServerLibraryAtOpen)
            try await library.updatePreferences(feedID: feed.id) { $0.newEpisodesAction = .nothing }
            await controller.reloadLibrary()?.value
            try tap("feedSettings", in: controller)
            let row: UIControl = try #require(element("feedSettingsNewEpisodes", in: controller.view))
            #expect(row.accessibilityHint == "Nothing")
            try tap("feedSettingsNewEpisodes", in: controller)
            try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
            #expect(element("feedNewEpisodesSnackbar", in: controller.view, as: UIView.self) == nil)
            try tap("feedNewEpisodesCancel", in: try #require(controller.presentedViewController))
            try await wait { controller.presentedViewController == nil }
            #expect(try await library.feed(id: feed.id)?.newEpisodesAction == .nothing)
        }
    }

    @Test(arguments: [false, true]) func autoDownloadChoicesControlFilterAndNewEpisodeSummary(local: Bool) async throws {
        try await run(local: local) { controller, library, feed, root in
            try tap("feedSettings", in: controller)
            if local {
                #expect(element("feedSettingsAutoDownload", in: controller.view, as: UIControl.self) == nil)
                #expect(element("feedSettingsDownloadFilter", in: controller.view, as: UIControl.self) == nil)
                return
            }
            let previous: UIControl = try #require(element("feedSettingsNewEpisodes", in: controller.view))
            let row: UIControl = try #require(element("feedSettingsAutoDownload", in: controller.view))
            #expect(row.frame.minY >= previous.frame.maxY - 0.5 && row.frame.minY - previous.frame.maxY < 1, "Directly after New episodes action")
            #expect(row.accessibilityHint == "Global default (Disabled)")
            for raw in [2, 0, 1] {
                try tap("feedSettingsAutoDownload", in: controller)
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController)
                let choices: [UIControl] = try [1, 2, 0].map { try #require(element("feedAutoDownload-\($0)", in: dialog.view)) }
                #expect(choices.map(\.accessibilityLabel) == ["Global default", "Enabled", "Disabled"])
                #expect(zip(choices, choices.dropFirst()).allSatisfy { $0.frame.minY < $1.frame.minY })
                try tap("feedAutoDownload-\(raw)", in: dialog)
                try await wait {
                    guard controller.presentedViewController == nil else { return false }
                    return try await library.feed(id: feed.id)?.autoDownload.rawValue == raw
                }
                await controller.reloadLibrary()?.value
                #expect(((element("feedSettingsDownloadFilter", in: controller.view) as UIControl?) != nil) == (raw == 2))
                if raw == 2 {
                    let filter: UIControl = try #require(element("feedSettingsDownloadFilter", in: controller.view))
                    controller.view.layoutIfNeeded()
                    let heading = try #require(filter.subviews.compactMap { $0 as? UILabel }.first { $0.text == "Episode filter" })
                    #expect(heading.frame.minX > 0 && filter.bounds.contains(heading.frame), "Episode filter heading is inset inside its row: \(heading.frame) in \(filter.bounds)")
                }
                let next: UIControl = try #require(element("feedSettingsNewEpisodes", in: controller.view))
                #expect(next.accessibilityHint == (raw == 2 ? "Automatic download enabled. Episodes are added to the inbox and then moved to the queue once downloaded." : "Global default (Add to inbox)"))
                try tap("feedSettingsAutoDownload", in: controller)
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                let reopened = try #require(controller.presentedViewController)
                #expect((element("feedAutoDownload-\(raw)", in: reopened.view) as UIControl?)?.accessibilityTraits.contains(.selected) == true)
                try tap("feedAutoDownloadCancel", in: reopened)
                try await wait { controller.presentedViewController == nil }
                let database = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
                #expect(try await database.feed(id: feed.id)?.autoDownload.rawValue == raw)
                try await database.close()
            }
        }
    }

    @Test func filterConfirmCancelReopenAndOwnedAutomaticDownloadUseSavedTerms() async throws {
        try await run { controller, library, feed, root in
            try await library.updatePreferences(feedID: feed.id) { $0.autoDownload = .enabled }
            await controller.reloadLibrary()?.value
            try tap("feedSettings", in: controller)
            @MainActor func open() async throws -> UIViewController {
                try tap("feedSettingsDownloadFilter", in: controller)
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                return try #require(controller.presentedViewController)
            }
            var dialog = try await open()
            var field: UITextField = try #require(element("downloadFilterTerm", in: dialog.view))
            field.text = "Discarded"; try tap("downloadFilterAdd", in: dialog)
            try tap("downloadFilterCancel", in: dialog)
            try await wait { controller.presentedViewController == nil }
            #expect(try await library.feed(id: feed.id)?.automaticDownloadFilter == .init())
            dialog = try await open()
            field = try #require(element("downloadFilterTerm", in: dialog.view))
            field.text = "\"Episode 1\""; try tap("downloadFilterAdd", in: dialog)
            field.text = "Episode 1"; try tap("downloadFilterAdd", in: dialog)
            #expect(element("downloadFilterRemove-1", in: dialog.view, as: UIButton.self) == nil)
            field.text = "Unsubmitted input"
            try tap("downloadFilterExclude", in: dialog)
            let minutes: UITextField = try #require(element("downloadFilterMinutes", in: dialog.view))
            #expect(!minutes.isEnabled)
            try tap("downloadFilterDuration", in: dialog); minutes.text = "30"
            try tap("downloadFilterConfirm", in: dialog)
            try await wait {
                guard controller.presentedViewController == nil else { return false }
                return try await library.feed(id: feed.id)?.automaticDownloadFilter.exclude == "\"Episode 1\" "
            }
            let expected = AutomaticDownloadFilter(exclude: "\"Episode 1\" ", minimumDurationSeconds: 1800)
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            #expect(try await reopened.feed(id: feed.id)?.automaticDownloadFilter == expected)
            try await reopened.close()
            dialog = try await open()
            #expect((element("downloadFilterExclude", in: dialog.view) as UIControl?)?.accessibilityTraits.contains(.selected) == true)
            #expect((element("downloadFilterMinutes", in: dialog.view) as UITextField?)?.text == "30")
            try tap("downloadFilterRemove-0", in: dialog)
            try tap("downloadFilterCancel", in: dialog)
            try await wait { controller.presentedViewController == nil }
            #expect(try await library.feed(id: feed.id)?.automaticDownloadFilter == expected)
            let first = try #require(feed.episodes.first { $0.details.title == "Episode 1" })
            let second = try #require(feed.episodes.first { $0.details.title == "Episode 2" })
            for id in [first.id, second.id] { try await library.updateEpisode(id: id) { $0.userState.playState = .new } }
            var requested: [Int64] = []
            let automatic = AutomaticDownloadCoordinator(store: library, preferences: { .init() },
                environment: { .init(connection: .wifi(metered: false), allowMobile: false, charging: true) },
                cleanup: { _ in Issue.record("No cleanup expected") }, download: { requested.append($0) })
            #expect(requested.isEmpty)
            try await automatic.run()
            #expect(requested == [second.id])
        }
    }

    @Test func localAutoDeleteSummaryUsesLocalGlobalFlagIndependentlyOfMaster() throws {
        var preferences = PlaybackEndPreferences(); preferences.autoDeleteLocal = true
        let feed = LibraryFeed(id: 1, source: "antennapod_local:fixture", metadata: .init(format: .rss), episodes: [])
        let view = FeedSettingsView(feed: feed, deletionPreferences: preferences)
        #expect((element("feedSettingsAutoDelete", in: view) as UIControl?)?.accessibilityHint == "Global default (Always)")
        #expect(!feed.autoDelete.enabled(global: preferences.autoDelete, local: preferences.autoDeleteLocal, isLocalFeed: true))
    }

    @Test(arguments: [false, true]) func feedVolumeSelectsImmediatelyPersistsAndCancels(local: Bool) async throws {
        try await run(local: local) { controller, library, feed, _ in
            try tap("feedSettings", in: controller)
            let row: UIControl = try #require(element("feedSettingsVolume", in: controller.view))
            let skip: UIControl = try #require(element("feedSettingsAutoSkip", in: controller.view))
            #expect(row.frame.minY >= skip.frame.maxY)
            #expect(row.accessibilityHint == "Turn volume for episodes of this podcast up or down: No adaption")
            @MainActor func open() async throws -> UIViewController {
                try tap("feedSettingsVolume", in: controller)
                try await wait { controller.presentedViewController != nil }
                let dialog = try #require(controller.presentedViewController)
                try await wait { !dialog.isBeingPresented && dialog.view.window != nil }
                return dialog
            }
            var dialog = try await open()
            let selected: UIControl = try #require(element("feedVolume-0", in: dialog.view))
            #expect(selected.accessibilityTraits.contains(.selected))
            var previous: CGFloat = -.infinity
            for setting in FeedVolumeAdaptation.displayOrder {
                let choice: UIControl = try #require(element("feedVolume-\(setting.rawValue)", in: dialog.view))
                #expect(choice.frame.minY >= previous)
                #expect(choice.accessibilityLabel == Appearance.text(setting.titleKey))
                previous = choice.frame.maxY
            }
            try tap("feedVolumeCancel", in: dialog)
            try await wait { controller.presentedViewController == nil }
            #expect(try await library.feed(id: feed.id)?.volumeAdaptation == .off)
            dialog = try await open(); try tap("feedVolume-5", in: dialog)
            try await wait { controller.presentedViewController == nil }
            dialog = try await open() // Opening waits for the serialized save.
            let heavy: UIControl = try #require(element("feedVolume-5", in: dialog.view))
            #expect(heavy.accessibilityTraits.contains(.selected))
            #expect(try await library.feed(id: feed.id)?.volumeAdaptation == .heavyBoost)
            try tap("feedVolume-1", in: dialog)
            try await wait { controller.presentedViewController == nil }
            dialog = try await open()
            let light: UIControl = try #require(element("feedVolume-1", in: dialog.view))
            #expect(light.accessibilityTraits.contains(.selected))
            try tap("feedVolumeCancel", in: dialog)
            try await wait { controller.presentedViewController == nil }
            let saved = try #require(try await library.feed(id: feed.id))
            #expect(saved.volumeAdaptation == .lightReduction && saved.episodes == feed.episodes)
            #expect(saved.keepUpdated == feed.keepUpdated && saved.tags == feed.tags && saved.skipPreferences == feed.skipPreferences)
            try tap("toolbarBack", in: controller); try tap("feedSettings", in: controller)
            dialog = try await open()
            #expect(((element("feedVolume-1", in: dialog.view) as UIControl?)?.accessibilityTraits.contains(.selected) == true))
            try tap("feedVolume-0", in: dialog)
            try await wait { controller.presentedViewController == nil }
        }
    }

    @Test(arguments: [false, true]) func feedAutoSkipPersistsPairCancelAndConstrainedEditing(local: Bool) async throws {
        try await run(local: local) { controller, library, feed, _ in
            try await library.updatePreferences(feedID: feed.id) { $0.skip = .init(introSeconds: 10, endingSeconds: 5) }
            try tap("feedSettings", in: controller)
            let row: UIControl = try #require(element("feedSettingsAutoSkip", in: controller.view))
            let speed: UIControl = try #require(element("feedSettingsPlaybackSpeed", in: controller.view))
            #expect(row.frame.minY >= speed.frame.maxY)
            #expect(row.accessibilityHint == "Skip introductions and ending credits")
            @MainActor func open() async throws -> UIViewController {
                try tap("feedSettingsAutoSkip", in: controller)
                try await wait { controller.presentedViewController != nil }
                let dialog = try #require(controller.presentedViewController)
                try await wait { !dialog.isBeingPresented && dialog.view.window != nil }; return dialog
            }
            var dialog = try await open()
            var intro: UITextField = try #require(element("feedSkipIntro", in: dialog.view))
            var ending: UITextField = try #require(element("feedSkipEnding", in: dialog.view))
            #expect(intro.text == "10" && ending.text == "5")
            #expect(intro.keyboardType == .numberPad && intro.frame.maxY <= ending.frame.minY)
            let underline: UIView = try #require(element("feedSkipIntroUnderline", in: dialog.view))
            #expect(abs(underline.frame.midX - intro.frame.midX) < 1 && underline.frame.width > 0 && underline.frame.width <= intro.frame.width, "Underline sits under the intro field")
            let body: FeedAutoSkipBody = try #require(element("feedAutoSkipBody", in: dialog.view))
            _ = body.textField(intro, shouldChangeCharactersIn: NSRange(location: 0, length: 2), replacementString: "123456")
            #expect(intro.text == "12345")
            ending.text = "7"
            dialog.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            dialog.view.semanticContentAttribute = .forceRightToLeft
            dialog.additionalSafeAreaInsets = .init(top: 0, left: 19, bottom: 8, right: 47)
            dialog.view.frame.size = CGSize(width: 420, height: 480)
            intro.becomeFirstResponder(); dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
            #expect(body.draft.confirmed == .init(introSeconds: 12345, endingSeconds: 7))
            #expect(body.bounds.contains(intro.frame) && body.bounds.contains(ending.frame))
            try tap("feedSkipCancel", in: dialog); try await wait { controller.presentedViewController == nil }
            #expect(try await library.feed(id: feed.id)?.skipPreferences == .init(introSeconds: 10, endingSeconds: 5))
            dialog = try await open()
            intro = try #require(element("feedSkipIntro", in: dialog.view)); ending = try #require(element("feedSkipEnding", in: dialog.view))
            intro.text = "12"; ending.text = "7"
            try tap("feedSkipConfirm", in: dialog); try await wait { controller.presentedViewController == nil }
            dialog = try await open() // A rapid reopen waits for the preceding serialized save.
            intro = try #require(element("feedSkipIntro", in: dialog.view)); ending = try #require(element("feedSkipEnding", in: dialog.view))
            #expect(intro.text == "12" && ending.text == "7")
            let saved = try #require(await library.feed(id: feed.id))
            #expect(saved.episodes == feed.episodes && saved.tags == feed.tags && saved.keepUpdated == feed.keepUpdated)
            intro.text = ""; ending.text = ""
            try tap("feedSkipConfirm", in: dialog)
            try await wait { try await library.feed(id: feed.id)?.skipPreferences == .init() }
        }
    }

    @Test(arguments: [false, true]) func feedSpeedDisabledRenderingPreservesSourceStates(dark: Bool) async throws {
        try await withViewTestWindow { host, _ in
            let body = FeedPlaybackSpeedBody(draft: .init(speed: -1, skipSilence: .global))
            body.overrideUserInterfaceStyle = dark ? .dark : .light
            host.view.addSubview(body)
            defer { body.removeFromSuperview() }
            body.frame = CGRect(origin: .zero, size: body.sizeThatFits(CGSize(width: 310, height: 500)))
            body.layoutIfNeeded()
            let slider: SpeedSlider = try #require(element("feedSpeedSlider", in: body))
            let silence: SpeedCheckbox = try #require(element("feedSpeedSkipSilence", in: body))
            let caption = try #require(silence.subviews.compactMap { $0 as? UILabel }.first)
            // "Use global default" greys out the speed controls and the skip-silence checkbox.
            let alpha = caption.textColor.resolvedColor(with: body.traitCollection).cgColor.alpha
            #expect(!slider.isEnabled && !silence.isEnabled)
            #expect(alpha < 1 && silence.alpha < 1, "Disabled skip-silence looks disabled")
            let global: UIControl = try #require(element("feedSpeedUseGlobal", in: body))
            global.sendActions(for: .touchUpInside); body.layoutIfNeeded()
            #expect(slider.isEnabled && silence.isEnabled && silence.alpha == 1)
            silence.sendActions(for: .touchUpInside); body.layoutIfNeeded()
            #expect(body.draft.skipsSilence)
            global.sendActions(for: .touchUpInside); body.layoutIfNeeded()
            // Returning to the global default keeps the checked draft but disables and dims it.
            #expect(body.draft.skipsSilence && !silence.isEnabled && !slider.isEnabled && silence.alpha < 1)
        }
    }

    @Test(arguments: [false, true]) func feedPlaybackSpeedConfirmsPairAndPreservesGlobalCurrentAndCancel(local: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("FeedSpeedView-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let speeds = try PlaybackSpeedPreferenceStore(file: file)
        try speeds.setGlobal(1.5); try speeds.activate(episodeID: 42, resolvedSpeed: 0.75)
        try await run(local: local, speedPreferences: speeds) { controller, library, feed, _ in
            let before = speeds.value
            try tap("feedSettings", in: controller)
            let tags: UIControl = try #require(element("feedSettingsTags", in: controller.view))
            let row: UIControl = try #require(element("feedSettingsPlaybackSpeed", in: controller.view))
            let updates: UIControl = try #require(element("feedKeepUpdated", in: controller.view))
            #expect(tags.frame.maxY < row.frame.minY && row.frame.maxY < updates.frame.minY)
            #expect(row.accessibilityHint == "The speed to use when starting audio playback for episodes in this podcast")
            @MainActor func open() async throws -> UIViewController {
                try tap("feedSettingsPlaybackSpeed", in: controller)
                let dialog = try #require(controller.presentedViewController)
                try await wait { !dialog.isBeingPresented && dialog.view.window != nil }
                return dialog
            }
            var dialog = try await open()
            var slider: UIControl = try #require(element("feedSpeedSlider", in: dialog.view))
            let value: UILabel = try #require(element("feedSpeedValue", in: dialog.view))
            #expect(!slider.isEnabled && slider.accessibilityValue == "1.00" && value.text == nil)
            #expect(slider.accessibilityTraits.contains(.notEnabled))
            try tap("feedSpeedUseGlobal", in: dialog); try tap("feedSpeedIncrease", in: dialog)
            try tap("feedSpeedSkipSilence", in: dialog)
            #expect(slider.isEnabled && value.text == "1.05x")
            #expect(!slider.accessibilityTraits.contains(.notEnabled))
            dialog.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            dialog.view.semanticContentAttribute = .forceRightToLeft
            dialog.additionalSafeAreaInsets = .init(top: 0, left: 19, bottom: 8, right: 47)
            dialog.view.frame.size = CGSize(width: 420, height: 480)
            dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
            let body: FeedPlaybackSpeedBody = try #require(element("feedPlaybackSpeedDraft", in: dialog.view))
            #expect(body.draft.savedSpeed == 1.05 && body.draft.savedSilence == .aggressive)
            #expect(value.bounds.height >= value.sizeThatFits(CGSize(width: value.bounds.width, height: .greatestFiniteMagnitude)).height)
            for id in ["feedSpeedUseGlobal", "feedSpeedDecrease", "feedSpeedSlider", "feedSpeedIncrease", "feedSpeedValue", "feedSpeedSkipSilence"] {
                let view: UIView = try #require(element(id, in: body))
                #expect(body.bounds.contains(view.convert(view.bounds, to: body)))
            }
            #expect(speeds.value == before)
            try tap("feedSpeedCancel", in: dialog); try await wait { controller.presentedViewController == nil }
            #expect(speeds.value == before)
            dialog = try await open()
            try tap("feedSpeedUseGlobal", in: dialog); try tap("feedSpeedIncrease", in: dialog)
            try tap("feedSpeedSkipSilence", in: dialog); try tap("feedSpeedSave", in: dialog)
            try await wait { controller.presentedViewController == nil }
            let saved = try PlaybackSpeedPreferenceStore(file: file).value
            #expect(saved.feeds[feed.id] == 1.05 && saved.silence.feeds[feed.id] == .aggressive)
            #expect(saved.global == before.global && saved.presets == before.presets && saved.temporary == before.temporary)
            #expect(saved.currentEpisodeID == before.currentEpisodeID && saved.silence.temporary == before.silence.temporary)
            #expect(try await library.feed(id: feed.id)?.episodes == feed.episodes)
            dialog = try await open()
            slider = try #require(element("feedSpeedSlider", in: dialog.view))
            #expect(slider.isEnabled && slider.accessibilityValue == "1.05")
            try tap("feedSpeedUseGlobal", in: dialog)
            #expect(!slider.isEnabled)
            try tap("feedSpeedSave", in: dialog); try await wait { controller.presentedViewController == nil }
            #expect(speeds.value.feeds[feed.id] == nil && speeds.value.silence.feeds[feed.id] == nil)
            #expect(speeds.value.global == 1.5 && speeds.value.temporary == 0.75)
        }
    }

    @Test func tagOrderRetainsSettingsSessionAndResetsOnFreshNavigation() async throws {
        struct Case: Decodable {
            let `case`: String
            let stored, displayed, edited, saved, reopened, coldReopened: [String]
        }
        let bundle = Bundle(for: FeedTagOrderTestBundle.self)
        let url = try #require(bundle.url(forResource: "feed-tag-order", withExtension: "json"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        let sample = try #require(cases.first { $0.case == "tree-root-24" })
        #expect(sample.reopened != sample.coldReopened)
        try await run { controller, library, feed, _ in
            try await library.updatePreferences(feedID: feed.id) { $0.tags = sample.stored }
            await controller.reloadLibrary()?.value
            try tap("feedSettings", in: controller)
            @MainActor func open() async throws -> (UIViewController, FeedTagsBody) {
                try tap("feedSettingsTags", in: controller)
                try await wait { controller.presentedViewController != nil }
                let dialog = try #require(controller.presentedViewController)
                try await wait { !dialog.isBeingPresented && dialog.view.window != nil }
                return (dialog, try #require(element("feedTagsBody", in: dialog.view)))
            }
            var (dialog, body) = try await open()
            #expect(body.draft.displayed == sample.displayed)
            while !body.draft.displayed.isEmpty { try tap("feedTagRemove-0", in: dialog) }
            let field: UITextField = try #require(element("feedTagInput", in: dialog.view))
            for name in sample.edited where name != "#root" {
                field.text = name; try tap("feedTagAdd", in: dialog)
            }
            try tap("feedTagsSave", in: dialog)
            try await wait { controller.presentedViewController == nil }
            // Reopen directly; the app must await the preceding preference write.
            (dialog, body) = try await open()
            #expect(body.draft.displayed == sample.reopened)
            #expect(try await library.feed(id: feed.id)?.tags == sample.saved)
            try tap("feedTagsCancel", in: dialog)
            try await wait { controller.presentedViewController == nil }
            try tap("toolbarBack", in: controller); try tap("feedSettings", in: controller)
            (dialog, body) = try await open()
            #expect(body.draft.displayed == sample.coldReopened)
            #expect(try await library.feed(id: feed.id)?.episodes == feed.episodes)
            try tap("feedTagsCancel", in: dialog)
            try await wait { controller.presentedViewController == nil }
        }
    }

    @Test func feedSettingsPersistAndReturnToUpdatedHeader() async throws {
        try await run { controller, library, feed, _ in
            try tap("feedSettings", in: controller)
            // Source switches change immediately, even before the first save
            // finishes. A pair of rapid taps must persist the original value.
            try tap("feedNotification", in: controller)
            try tap("feedNotification", in: controller)
            // The following save is the barrier for both preceding writes;
            // the initial stored false value alone cannot prove completion.
            try tap("feedKeepUpdated", in: controller)
            try await wait { try await library.feed(id: feed.id)?.keepUpdated == false }
            #expect(try await library.feed(id: feed.id)?.showEpisodeNotification == false)
            try await wait { element("feedNotification", in: controller.view, as: UIControl.self)?.isEnabled == false }
            try tap("feedRename", in: controller)
            let dialog = try #require(controller.presentedViewController as? SourceMessageController)
            try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
            let input: UITextView = try #require(element("feedRenameInput", in: dialog.view))
            input.text = "Discarded draft"
            try tap("feedRenameReset", in: dialog)
            #expect(controller.presentedViewController === dialog && input.text == feed.title)
            input.text = "Renamed podcast"
            try tap("feedRenameConfirm", in: dialog)
            try await wait { controller.presentedViewController == nil }
            try await wait { try await library.feed(id: feed.id)?.title == "Renamed podcast" }
            await controller.reloadLibrary()?.value
            try tap("toolbarBack", in: controller)
            let title: UILabel = try #require(element("feedTitle", in: controller.view))
            #expect(title.text == "Renamed podcast")
            let banner: UIControl = try #require(element("feedUpdatesDisabled", in: controller.view))
            #expect(!banner.isHidden)
        }
    }

    @Test func localReconnectRequiresWarningAndPickerThenPreservesFeedIdentity() async throws {
        try await run(local: true) { controller, library, feed, root in
            try tap("feedInformation", in: controller)
            try tap("feedInformationMore", in: controller)
            try tap("reconnectLocalFolder", in: controller)
            let warning = try #require(controller.presentedViewController as? SourceMessageController)
            try await wait { warning.view.window != nil && !warning.isBeingPresented }
            try tap("reconnectFolderCancel", in: warning)
            try await wait { controller.presentedViewController == nil }
            #expect(try await library.feed(id: feed.id)?.source == feed.source)
            try tap("feedInformationMore", in: controller)
            try tap("reconnectLocalFolder", in: controller)
            let confirmed = try #require(controller.presentedViewController as? SourceMessageController)
            try await wait { confirmed.view.window != nil && !confirmed.isBeingPresented }
            try tap("reconnectFolderConfirm", in: confirmed)
            try await wait { controller.presentedViewController is UIDocumentPickerViewController }
            let picker = try #require(controller.presentedViewController as? UIDocumentPickerViewController)
            try await wait { picker.view.window != nil && !picker.isBeingPresented }
            let folder = root.appendingPathComponent("Reconnected folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [folder])
            picker.dismiss(animated: false)
            try await wait { controller.presentedViewController == nil }
            try await wait { try await library.feed(id: feed.id)?.source != feed.source }
            let stored = try #require(try await library.feed(id: feed.id))
            #expect(stored.id == feed.id && stored.title == feed.title && stored.episodes == feed.episodes)
            #expect(try await library.logs(feedID: feed.id).isEmpty)
            await controller.reloadLibrary()?.value
            let previous = UIPasteboard.general.string
            defer { UIPasteboard.general.string = previous }
            try tap("urlLabel", in: controller)
            #expect(UIPasteboard.general.string == stored.source)
        }
    }

    @Test func networkInformationPresentsAnchoredNativeShareSheet() async throws {
        try await run { controller, _, _, _ in
            try tap("feedInformation", in: controller)
            try tap("feedShare", in: controller)
            try await wait { controller.presentedViewController is UIActivityViewController }
            let sheet = try #require(controller.presentedViewController as? UIActivityViewController)
            try await wait { sheet.view.window != nil && !sheet.isBeingPresented }
            #expect(sheet.popoverPresentationController?.sourceView?.accessibilityIdentifier == "feedShare")
            sheet.dismiss(animated: false)
            try await wait { controller.presentedViewController == nil }
            #expect(element("feedInformationScreen", in: controller.view, as: UIView.self) != nil)
        }
    }
}

private final class FeedTagOrderTestBundle: NSObject {}

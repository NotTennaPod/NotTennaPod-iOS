import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Source expectations: ItemActionButton.forItem, PlayLocalActionButton and
/// CompletedDownloadsFragment.afterBindViewHolder in pinned Android 3.12.1.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct LocalEpisodeRowPlaybackViewTests {
    enum Transfer: CaseIterable { case none, waiting, active }

    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try #require(find(id, in: view), "Missing button \(id)")
    }
    private func wait(_ condition: @MainActor () async throws -> Bool, _ message: @autoclosure () -> String = "",
                      sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), Comment(rawValue: message()), sourceLocation: sourceLocation)
    }
    private func tap(_ id: String, in controller: UIViewController) throws {
        let control: UIControl = try #require(find(id, in: controller.view), "Missing control \(id)")
        control.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
    }
    private func job(_ transfer: Transfer) -> LibraryDownloadJob? {
        guard transfer != .none else { return nil }
        return .init(id: 9, episodeID: 2, source: "file:///local-row.wav",
            destination: URL(fileURLWithPath: "/unused/row-test.wav"), enqueuedByDownload: false,
            createdAt: Date(timeIntervalSince1970: 0), state: transfer == .waiting ? .waiting : .transferring,
            attempts: 0, updatedAt: Date(timeIntervalSince1970: 0))
    }
    private func row(downloaded: Bool, local: Bool = true, prefersDelete: Bool = false,
                     action: @escaping () -> Void = {}) -> EpisodeRowView {
        var state = EpisodeUserState(); state.isDownloaded = downloaded
        let episode = LibraryEpisode(id: 2, details: .init(title: "Local row",
            media: .init(url: "file:///local-row.wav", size: 960_044, mimeType: "audio/wav", durationMilliseconds: 60_000)),
            userState: state)
        let feed = LibraryFeed(id: 1, source: local ? "antennapod_local:row" : "https://example.invalid/feed",
            metadata: .init(format: .rss, title: "Folder"), episodes: [episode])
        return EpisodeRowView(feed: feed, episode: episode, queued: true, queueScreen: false,
            showRemainingTime: false, activelyPlaying: false, prefersDelete: prefersDelete,
            downloadAction: action, open: {})
    }
    private func expectAction(_ action: UIButton, label: String, image: String) throws {
        #expect(!action.isHidden && action.isEnabled)
        #expect(action.accessibilityLabel == Appearance.text(label))
        let icon = try #require(action.subviews.compactMap { $0 as? UIImageView }.first)
        let expectedImage = try #require(UIImage(named: image))
        #expect(icon.image == expectedImage)
        #expect(icon.bounds.width > 0 && icon.bounds.height > 0 && action.bounds.contains(icon.frame), "Icon visible inside its button")
        #expect(abs(icon.frame.midX - action.bounds.midX) < 0.5 && abs(icon.frame.midY - action.bounds.midY) < 0.5)
    }

    @Test(arguments: [false, true], Transfer.allCases)
    func localPlayWinsOverDownloadAndTransferSignals(downloaded: Bool, transfer: Transfer) async throws {
        // Downloaded local/active-transfer combinations are defensive overlaps,
        // not assertions that the ordinary local scanner creates download jobs.
        try await withViewTestWindow { host, _ in
            var taps = 0
            let row = row(downloaded: downloaded) { taps += 1 }
            host.view.addSubview(row)
            defer { row.removeFromSuperview() }
            let action = try button("episode-action-2", in: row)
            for rtl in [false, true] {
                row.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                row.frame = CGRect(origin: .zero, size: row.sizeThatFits(CGSize(width: 402, height: 1_000)))
                row.setNeedsLayout(); row.layoutIfNeeded(); action.layoutIfNeeded()
                #expect(row.effectiveUserInterfaceLayoutDirection == (rtl ? .rightToLeft : .leftToRight))
                #expect(action.bounds.width >= 44 && action.bounds.height >= 44, "Full-size touch target")
                let margin = rtl ? action.frame.minX : row.bounds.maxX - action.frame.maxX
                #expect(margin >= 0 && margin <= 24, "Action sits at the trailing edge (left in RTL)")
                let anchor = action.frame
                for preferredStream in [false, true] {
                    row.updateDownload(job: job(transfer), progress: .init(received: 42, expected: 100),
                        streamOverDownload: preferredStream)
                    try expectAction(action, label: "play_label", image: "ic_play_24dp")
                    #expect(action.accessibilityValue == nil)
                    action.sendActions(for: .touchUpInside)
                    row.updateDownload(job: job(transfer), progress: .init(received: 42, expected: 100),
                        playing: true, streamOverDownload: preferredStream)
                    try expectAction(action, label: "pause_label", image: "ic_pause")
                    row.updateDownload(job: job(transfer), progress: nil, playing: false,
                        streamOverDownload: preferredStream)
                    try expectAction(action, label: "play_label", image: "ic_play_24dp")
                    #expect(action.frame == anchor)
                }
            }
            #expect(taps == 4)
        }
    }

    @Test(arguments: [false, true])
    func downloadsDeleteOverrideAndSelectionRestoreGenericAction(local: Bool) async throws {
        try await withViewTestWindow { host, _ in
            let row = row(downloaded: true, local: local, prefersDelete: true)
            host.view.addSubview(row); defer { row.removeFromSuperview() }
            row.frame.size = row.sizeThatFits(CGSize(width: 402, height: 1_000))
            row.layoutIfNeeded()
            let action = try button("episode-action-2", in: row); action.layoutIfNeeded()
            row.updateDownload(job: job(.active), progress: .init(received: 42, expected: 100), playing: true)
            try expectAction(action, label: "delete_label", image: "ic_delete")
            row.setSelected(true, selectionMode: true)
            try expectAction(action, label: "pause_label", image: "ic_pause")
            row.updateDownload(job: job(.waiting), progress: nil, playing: false)
            try expectAction(action, label: "play_label", image: "ic_play_24dp")
            row.setSelected(false, selectionMode: false)
            try expectAction(action, label: "delete_label", image: "ic_delete")
        }
    }

    private func withSelectedApplication(_ body: @MainActor (AppDelegate, LibraryViewController,
        FeedLibraryStore, PlaybackCoordinator, RemovedEpisodeRefreshFixture, URL) async throws -> Void) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        let index = try #require(arguments.firstIndex(of: "-test-library-id"))
        try #require(index + 1 < arguments.count)
        let identifier = try #require(UUID(uuidString: arguments[index + 1]))
        try #require(arguments.contains("-test-muted-playback"))
        let app = try #require(UIApplication.shared.delegate as? AppDelegate)
        try #require(app.startupError == nil)
        let store = try #require(app.library), playback = try #require(app.playback)
        let deletion = try #require(app.feedDeletion)
        try #require(playback.episode == nil, "Use an isolated selected-app host with no existing media")
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("UITests-" + identifier.uuidString)
        let root = directory.appendingPathComponent("local-row-component-" + UUID().uuidString)
        let fixture = try await RemovedEpisodeRefreshFixture.prepare(root: root, store: store)
        let originalNavigation = app.navigationPreferences?.value
        do {
            try await wait {
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                    .contains { !$0.isHidden && $0.rootViewController is LibraryViewController }
            }
            let controller = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).filter { !$0.isHidden }.compactMap { $0.rootViewController as? LibraryViewController }.first)
            await controller.openNotification(.feed(fixture.feedID)); controller.view.layoutIfNeeded()
            try await body(app, controller, store, playback, fixture, directory)
        } catch {
            if let originalNavigation { try? app.navigationPreferences?.update(originalNavigation) }
            try? await deletion.delete(feedID: fixture.feedID).value
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        if let originalNavigation { try app.navigationPreferences?.update(originalNavigation) }
        try await deletion.delete(feedID: fixture.feedID).value
        try FileManager.default.removeItem(at: root)
    }

    @Test func selectedApplicationUsesLocalRowsInFeedQueueAndSearchWithoutDownloadEffects() async throws {
        try await withSelectedApplication { app, controller, store, playback, fixture, directory in
            let initial = try #require(try await store.episode(id: fixture.survivorID))
            try #require(!initial.userState.isDownloaded && initial.userState.localFileURL == nil)
            let link = try #require(try await store.localDocument(episodeID: fixture.survivorID))
            let bytes = try Data(contentsOf: fixture.survivor)
            let usage = try #require(app.usage).value
            let jobs = try await store.downloadJobs(activeOnly: false)
            if let navigation = app.navigationPreferences {
                var value = navigation.value; value.streamOverDownload = true; try navigation.update(value)
            }
            await controller.reloadLibrary()?.value
            let actionID = "episode-action-\(fixture.survivorID)"
            #expect(try button(actionID, in: controller.view).accessibilityLabel == Appearance.text("play_label"))
            try tap(actionID, in: controller)
            try await wait({ playback.episode?.id == fixture.survivorID && playback.phase == .playing },
                           "episode \(String(describing: playback.episode?.id)) phase \(playback.phase) wants \(playback.wantsPlayback) sample \(String(describing: playback.sample))")
            let first = playback.sample?.positionMilliseconds ?? 0
            try await wait { (playback.sample?.positionMilliseconds ?? 0) > first + 500 }
            try await wait { try self.button(actionID, in: controller.view).accessibilityLabel == Appearance.text("pause_label") }
            try tap(actionID, in: controller); try await wait { playback.phase == .paused }
            let saved = try #require(try await store.episode(id: fixture.survivorID))
            #expect(saved.userState.positionMilliseconds > 0)

            try tap(NavigationDestination.queue.rawValue, in: controller)
            try await wait { self.find(actionID, in: controller.view) as UIButton? != nil }
            #expect(try button(actionID, in: controller.view).accessibilityLabel == Appearance.text("play_label"))
            controller.startFeedSelection(fixture.removedID)
            try tap(actionID, in: controller)
            #expect(controller.feedSelection.ids == [fixture.removedID, fixture.survivorID])
            #expect(playback.phase == .paused)
            try tap("endEpisodeSelection", in: controller)
            try tap("episode-action-\(fixture.removedID)", in: controller)
            try await wait { playback.episode?.id == fixture.removedID && playback.phase == .playing }
            #expect(try button(actionID, in: controller.view).accessibilityLabel == Appearance.text("play_label"))
            try tap(actionID, in: controller)
            try await wait { playback.episode?.id == fixture.survivorID && playback.phase == .playing }
            try tap(actionID, in: controller); try await wait { playback.phase == .paused }

            await controller.openNotification(.feed(fixture.feedID))
            try tap("feedSearch", in: controller)
            let field: UITextField = try #require(find("librarySearchQuery", in: controller.view))
            field.text = RemovedEpisodeRefreshFixture.survivorTitle; field.sendActions(for: .editingChanged)
            field.resignFirstResponder()
            try await wait { self.find(actionID, in: controller.view) as UIButton? != nil }
            #expect(try button(actionID, in: controller.view).accessibilityLabel == Appearance.text("play_label"))
            try tap(actionID, in: controller); try await wait { playback.phase == .playing }
            let searchStart = playback.sample?.positionMilliseconds ?? 0
            try await wait { (playback.sample?.positionMilliseconds ?? 0) > searchStart + 500 }
            try tap(actionID, in: controller); try await wait { playback.phase == .paused }

            // Home card: stays Play/Pause (never Download) across playback-driven refreshes.
            try tap(NavigationDestination.home.rawValue, in: controller)
            @MainActor func cards(in view: UIView) -> [HomeEpisodeCard] {
                ((view as? HomeEpisodeCard).map { $0.episodeID == fixture.survivorID ? [$0] : [] } ?? [])
                    + view.subviews.flatMap { cards(in: $0) }
            }
            let card = { () throws -> UIButton in try #require(cards(in: controller.view).first).actionButton }
            let labels = { Set(cards(in: controller.view).map { $0.actionButton.accessibilityLabel }) }
            try await wait { (try? card()) != nil }
            #expect(labels() == [Appearance.text("play_label")])
            try card().sendActions(for: .touchUpInside)
            try await wait { playback.episode?.id == fixture.survivorID && playback.phase == .playing }
            try await wait { labels() == [Appearance.text("pause_label")] }
            // Resume rewinds 800 ms like Android (RewindAfterPauseUtils.MINIMUM_REWIND); play past that before
            // pausing so the persisted-position check below does not depend on how far earlier steps got.
            try await wait { (playback.sample?.positionMilliseconds ?? 0) > 1_000 }
            try card().sendActions(for: .touchUpInside); try await wait { playback.phase == .paused }
            try await wait { labels() == [Appearance.text("play_label")] }
            // A download-state refresh (here via the stream preference) must keep the local Play action.
            if let navigation = app.navigationPreferences {
                var value = navigation.value; value.streamOverDownload = false; try navigation.update(value)
                let until = ContinuousClock.now + .seconds(1)
                while ContinuousClock.now < until {
                    try #require(labels() == [Appearance.text("play_label")], "Local Home card switched away from Play: \(labels())")
                    try await Task.sleep(for: .milliseconds(20))
                }
                value.streamOverDownload = true; try navigation.update(value)
            }
            #expect(app.usage?.value == usage)
            #expect(try await store.downloadJobs(activeOnly: false) == jobs)
            #expect(try await store.localDocument(episodeID: fixture.survivorID) == link)
            #expect(try Data(contentsOf: fixture.survivor) == bytes)
            #expect(try await store.queue().map(\.id) == [fixture.removedID, fixture.survivorID])
            let reopened = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            do {
                #expect(try await reopened.playbackSelectionEpisodeID() == fixture.survivorID)
                let persisted = try #require(try await reopened.episode(id: fixture.survivorID))
                #expect(persisted.userState.positionMilliseconds > 0 && !persisted.userState.isDownloaded)
                #expect(persisted.details.media?.url == initial.details.media?.url)
                #expect(try await reopened.localDocument(episodeID: fixture.survivorID) == link)
            } catch { try? await reopened.close(); throw error }
            try await reopened.close()
        }
    }

    @Test func missingLocalRowShowsPlaybackFailureWithoutDownloadRepairAndValidSelectionRecovers() async throws {
        try await withSelectedApplication { app, controller, store, playback, fixture, _ in
            let original = try #require(try await store.episode(id: fixture.removedID))
            let link = try await store.localDocument(episodeID: fixture.removedID)
            let jobs = try await store.downloadJobs(activeOnly: false), usage = app.usage?.value
            let bytes = try Data(contentsOf: fixture.original)
            try fixture.moveTarget()
            let actionID = "episode-action-\(fixture.removedID)"
            #expect(try button(actionID, in: controller.view).accessibilityLabel == Appearance.text("play_label"))
            try tap(actionID, in: controller)
            try await wait {
                playback.phase == .failed && controller.presentedViewController is SourceMessageController
                    && controller.presentedViewController?.isBeingPresented == false
            }
            #expect(!playback.wantsPlayback && app.playbackRoutes?.reading == nil)
            let after = try #require(try await store.episode(id: fixture.removedID))
            #expect(after.details == original.details)
            #expect(after.userState.isDownloaded == original.userState.isDownloaded)
            #expect(after.userState.localFileURL == original.userState.localFileURL)
            #expect(try await store.localDocument(episodeID: fixture.removedID) == link)
            #expect(try await store.queue().map(\.id) == [fixture.removedID, fixture.survivorID])
            #expect(try await store.downloadJobs(activeOnly: false) == jobs)
            #expect(app.usage?.value == usage)
            #expect(try Data(contentsOf: fixture.retained) == bytes)
            #expect(try Data(contentsOf: fixture.survivor) == bytes)
            let error = try #require(controller.presentedViewController)
            let message: UILabel = try #require(find("sourceMessage", in: error.view))
            #expect(message.attributedText?.string.hasPrefix(Appearance.text("playback_error_generic")) == true)
            try tap("sourceMessageOK", in: error)
            try await wait { controller.presentedViewController == nil }
            try FileManager.default.moveItem(at: fixture.retained, to: fixture.original)
            try tap(actionID, in: controller)
            try await wait { playback.episode?.id == fixture.removedID && playback.phase == .playing }
            let first = playback.sample?.positionMilliseconds ?? 0
            try await wait { (playback.sample?.positionMilliseconds ?? 0) > first + 500 }
            try tap(actionID, in: controller); try await wait { playback.phase == .paused }
            #expect(try Data(contentsOf: fixture.original) == bytes)
        }
    }
}

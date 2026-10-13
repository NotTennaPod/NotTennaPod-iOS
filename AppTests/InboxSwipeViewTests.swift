import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct InboxSwipeViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let value = view as? T { return value }
        for child in view.subviews { if let value: T = find(id, in: child) { return value } }
        return nil
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while try await !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await predicate())
    }
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InboxSwipeView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    @Test(arguments: SwipeScreen.allCases, [CGSize(width: 393, height: 852), CGSize(width: 834, height: 1194), CGSize(width: 720, height: 420)])
    func settingsKeepPhysicalSidesSourceOrderCancelAndDurableConfirm(screen: SwipeScreen, size: CGSize) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json"), store = try SwipePreferenceStore(file: url)
        var saves = 0, errors = 0
        try await withViewTestWindow { host, _ in
            let dialog = SwipeSettingsController.make(screen: screen, store: store, saved: { saves += 1 }, failed: { _ in errors += 1 })
            host.present(dialog, animated: false)
            defer { host.dismiss(animated: false) }
            try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
            dialog.view.frame.size = size; dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
            let body: SwipeSettingsBody = try #require(find("inboxSwipeSettings", in: dialog.view))
            // Dialog defaults and picker order: `SwipeActions.getPrefsWithDefaults`, `SwipeActionsDialog`.
            let defaults: [SwipeScreen: (left: SwipeAction, right: SwipeAction, keys: [String])] = [
                .queue: (.removeQueue, .removeQueue, ["REMOVE_FROM_QUEUE", "START_DOWNLOAD", "DELETE", "MARK_FAV", "MARK_PLAYED"]),
                .inbox: (.removeInbox, .queue, ["ADD_TO_QUEUE", "START_DOWNLOAD", "REMOVE_FROM_INBOX", "MARK_FAV"]),
                .episodes: (.download, .favorite, ["ADD_TO_QUEUE", "START_DOWNLOAD", "REMOVE_FROM_INBOX", "DELETE", "MARK_FAV", "MARK_PLAYED"]),
                .history: (.removeHistory, .removeHistory, ["ADD_TO_QUEUE", "START_DOWNLOAD", "DELETE", "MARK_FAV", "REMOVE_FROM_HISTORY", "MARK_PLAYED"]),
                .favorites: (.removeFavorite, .removeFavorite, ["ADD_TO_QUEUE", "START_DOWNLOAD", "REMOVE_FROM_INBOX", "DELETE", "REMOVE_FROM_FAVORITES", "MARK_PLAYED"]),
                .feed: (.download, .favorite, ["ADD_TO_QUEUE", "START_DOWNLOAD", "REMOVE_FROM_INBOX", "DELETE", "MARK_FAV", "MARK_PLAYED"])
            ]
            let expected = try #require(defaults[screen])
            let expectedLeft = expected.left, expectedRight = expected.right
            #expect(body.draft.configuration.left == expectedLeft && body.draft.configuration.right == expectedRight)
            #expect(store.value.configuration(for: screen) == nil)
            let preview: UIControl = try #require(find("inboxSwipePreview-left", in: dialog.view))
            #expect(preview.accessibilityLabel == "Swipe left" && preview.accessibilityValue == Appearance.text(expectedLeft.titleKey))
            preview.sendActions(for: .touchUpInside)
            try await wait { dialog.presentedViewController?.isBeingPresented == false }
            let picker = try #require(dialog.presentedViewController)
            let keys = expected.keys
            var buttons: [UIButton] = []
            for key in keys { buttons.append(try #require(find("inboxSwipeChoice-" + key, in: picker.view))) }
            for (index, button) in buttons.enumerated() {
                #expect(button.subviews.compactMap { $0 as? UIImageView }.first?.image != nil)
                if index > 0 && index % 2 == 0 {
                    // Compare the rendered pixel edges: division at 3x scale can
                    // put the same boundary one floating-point ULP apart.
                    let scale = button.traitCollection.displayScale
                    #expect(scale > 0)
                    #expect((button.frame.minY * scale).rounded() >= (buttons[index-1].frame.maxY * scale).rounded())
                }
            }
            buttons[0].sendActions(for: .touchUpInside)
            try await wait { dialog.presentedViewController == nil }
            #expect(body.draft.configuration.left == SwipeAction(rawValue: keys[0]) && body.draft.configuration.right == expectedRight)
            let toggle: UIControl = try #require(find("inboxSwipeEnabled", in: dialog.view)); toggle.sendActions(for: .touchUpInside)
            let cancel: UIButton = try #require(find("inboxSwipeCancel", in: dialog.view)); cancel.sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil }
            #expect(store.value.configuration(for: screen) == nil && saves == 0 && errors == 0)
            let confirmDialog = SwipeSettingsController.make(screen: screen, store: store, saved: { saves += 1 }, failed: { _ in errors += 1 })
            host.present(confirmDialog, animated: false)
            try await wait { confirmDialog.view.window != nil }
            let confirm: UIButton = try #require(find("inboxSwipeConfirm", in: confirmDialog.view)); confirm.sendActions(for: .touchUpInside)
            try await wait { saves == 1 }
            #expect(try SwipePreferenceStore(file: url).value.configuration(for: screen) == .init(left: expectedLeft, right: expectedRight))
            #expect(errors == 0)
        }
    }
    @Test func failedConfirmPreservesDraftAndKeepsDialogForCorrection() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SwipePreferenceStore(file: root.appendingPathComponent("missing/preferences.json"))
        var failures = 0, saves = 0
        try await withViewTestWindow { host, _ in
            let dialog = SwipeSettingsController.make(screen: .inbox, store: store, saved: { saves += 1 }, failed: { _ in failures += 1 })
            host.present(dialog, animated: false); defer { host.dismiss(animated: false) }
            try await wait { dialog.view.window != nil }
            let body: SwipeSettingsBody = try #require(find("inboxSwipeSettings", in: dialog.view))
            let toggle: UIControl = try #require(find("inboxSwipeEnabled", in: dialog.view)); toggle.sendActions(for: .touchUpInside)
            let confirm: UIButton = try #require(find("inboxSwipeConfirm", in: dialog.view)); confirm.sendActions(for: .touchUpInside)
            #expect(failures == 1 && saves == 0 && !body.draft.configuration.enabled)
            #expect(host.presentedViewController === dialog && store.value.configuration(for: .inbox) == nil)
        }
    }

    @MainActor private final class Clock {
        var now = ContinuousClock.now
        var pending: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, any Error>)] = [:]
        func sleep(until deadline: ContinuousClock.Instant) async throws {
            try Task.checkCancellation(); guard now < deadline else { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending[id] = (deadline, $0) }
            } onCancel: { Task { @MainActor in self.pending.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) } }
        }
        func advance() {
            now = now.advanced(by: .seconds(2))
            for (id, value) in pending where value.0 <= now { pending.removeValue(forKey: id)?.1.resume() }
        }
    }
    private func library(_ body: (FeedLibraryStore, DownloadCoordinator, EpisodeSwipeCoordinator, Clock, [EpisodeActionModel], [EpisodeMediaDeletionTarget]) async throws -> Void) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(.init(feed: .init(format: .rss, episodes: (1...3).map {
            .init(identifier: "\($0)", media: .init(url: "https://example.test/\($0).mp3", size: 42, durationMilliseconds: 120_000))
        }), source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        var models: [EpisodeActionModel] = [], targets: [EpisodeMediaDeletionTarget] = []
        for id in feed.episodes.map(\.id).sorted() {
            try await store.updateEpisode(id: id) { $0.userState.playState = .new; $0.userState.positionMilliseconds = 90_000 }
            let episode = try #require(try await store.episode(id: id))
            models.append(.init(item: .init(episode: episode, local: false)))
            targets.append(.init(episodeID: id, feedID: feed.id, source: feed.source, media: .remote(mediaURL: episode.details.media?.url, originalFile: nil)))
        }
        var preferences = DownloadPreferences(); preferences.autoDelete = true
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("downloads"), network: DownloadNetworkMonitor(startMonitoring: false), preferences: { preferences })
        let clock = Clock()
        let coordinator = EpisodeSwipeCoordinator(persistence: .init(store: store), downloads: downloads,
            clock: .init(now: { clock.now }, sleep: { try await clock.sleep(until: $0) }), delete: { _ in .deleted })
        do { try await body(store, downloads, coordinator, clock, models, targets) }
        catch { coordinator.invalidateLibrary(); await downloads.stop(); try? await store.close(); throw error }
        coordinator.invalidateLibrary(); await downloads.stop(); try await store.close()
    }
    @Test func mountedOfferReplacementUndoButtonCancelsOnlyItsOperation() async throws {
        try await library { store, _, coordinator, clock, models, targets in
            try await withViewTestWindow { host, _ in
                let presenter = SwipeOfferPresenter(host: host.view, store: store, coordinator: coordinator, actionTimeout: { nil }, region: { host.view.bounds }, wide: { false })
                var events: [EpisodeSwipeCoordinator.Event] = []
                coordinator.onEvent = { events.append($0); presenter.receive($0) }
                defer { coordinator.onEvent = nil; presenter.dismiss() }
                guard case .committed(let a) = await coordinator.perform(model: models[0], action: .removeInbox, target: targets[0], offersUndo: true) else { throw FeedLibraryError.invalidMutation }
                let old = try #require(presenter.snackbar)
                old.dismiss(animated: true) // Replacement may race the old dismissal completion.
                guard case .committed(let b) = await coordinator.perform(model: models[1], action: .removeInbox, target: targets[1], offersUndo: true) else { throw FeedLibraryError.invalidMutation }
                try await wait { old.superview == nil }
                let bar = try #require(presenter.snackbar)
                try await wait { bar.alpha == 1 && bar.transform == .identity }
                #expect(bar.message == "Removed from inbox" && !bar.isAccessibilityElement)
                let button: UIButton = try #require(find("inboxSwipeUndo", in: bar))
                #expect(button.accessibilityLabel == "Undo" || button.title(for: .normal) == "Undo")
                bar.layoutIfNeeded()
                // Pinned Material snackbar places message at start and action at end.
                let rtl = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft
                #expect(rtl ? button.frame.minX < bar.label.frame.minX : button.frame.minX > bar.label.frame.minX)
                #expect(button.frame.intersection(bar.label.frame).width == 0)
                button.sendActions(for: .touchUpInside)
                #expect(events.contains { if case .cleanupFinished(b.operationID, .cancelled) = $0 { true } else { false } })
                button.sendActions(for: .touchUpInside)
                try await wait { try await store.episode(id: models[1].episodeID)?.userState.playState == .new }
                clock.advance()
                try await wait { events.contains { if case .cleanupFinished(a.operationID, .deleted) = $0 { true } else { false } } }
                #expect(try await store.episode(id: models[0].episodeID)?.userState.playState == .unplayed)
            }
        }
    }
    @Test func queueOfferReinsertsIntoCurrentOrderAndFirstUseOnlyConfigures() async throws {
        try await library { store, _, coordinator, _, models, _ in
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let preferences = try SwipePreferenceStore(file: root.appendingPathComponent("preferences.json"))
            try await withViewTestWindow { host, _ in
                let presenter = SwipeOfferPresenter(host: host.view, store: store, coordinator: coordinator, actionTimeout: { nil }, region: { host.view.bounds }, wide: { true })
                defer { presenter.dismiss() }
                var configured = 0, ordinary = 0
                let recipient = SwipeRecipient(preferences: preferences, screen: .inbox, coordinator: coordinator, offers: presenter, configure: { configured += 1 }, ordinary: { _, _, _ in ordinary += 1 })
                #expect(recipient.configuration(direction: .left, item: models[0].snapshot(), filter: .init(values: ["new"]))?.icon == "ic_settings")
                await recipient.perform(direction: .left, model: models[0], filter: .init(values: ["new"]), target: nil)
                #expect(configured == 1 && ordinary == 0)
                #expect(try await store.episode(id: models[0].episodeID)?.userState.playState == .new)
                _ = try await store.enqueue(models.map(\.episodeID))
                await presenter.removeQueue(episodeID: models[1].episodeID, offersUndo: true)
                #expect(presenter.snackbar?.message == "1 episode removed from queue.")
                _ = try await store.moveQueueItem(from: 1, to: 0)
                let bar = try #require(presenter.snackbar), button: UIButton = try #require(find("inboxSwipeUndo", in: bar))
                button.sendActions(for: .touchUpInside)
                try await wait { try await store.queue().map(\.id) == [models[2].episodeID, models[1].episodeID, models[0].episodeID] }
            }
        }
    }
    @Test(arguments: [SwipeAction.queue, .download, .delete, .favorite])
    func ordinaryRecipientReceivesExactCapturedContext(action: SwipeAction) async throws {
        try await library { store, _, coordinator, _, models, targets in
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let preferences = try SwipePreferenceStore(file: root.appendingPathComponent("preferences.json"))
            try preferences.confirm(.init(screen: .feed, configuration: .init(left: action, right: .favorite)))
            var episode = models[0].snapshot().episode
            episode.userState.isDownloaded = action == .delete
            let item = EpisodeListItem(episode: episode, local: false)
            let model = EpisodeActionModel(item: item)
            try await withViewTestWindow { host, _ in
                let presenter = SwipeOfferPresenter(host: host.view, store: store, coordinator: coordinator, actionTimeout: { nil }, region: { host.view.bounds }, wide: { false })
                var received: (SwipeDecision, EpisodeActionModel, EpisodeMediaDeletionTarget?)?
                let recipient = SwipeRecipient(preferences: preferences, screen: .feed, coordinator: coordinator, offers: presenter,
                    configure: { Issue.record("Already configured") }, ordinary: { received = ($0, $1, $2) })
                let visual = try #require(recipient.configuration(direction: .left, item: item, filter: .init()))
                #expect(visual.icon == action.icon)
                await recipient.perform(direction: .left, model: model, filter: .init(), target: targets[0])
                let captured = try #require(received)
                let expected: SwipeDecision.Recipient = action == .queue ? .list(.addQueue) : action == .download ? .download : action == .delete ? .list(.delete) : .list(.addFavorite)
                #expect(captured.0.recipient == expected && captured.1 === model && captured.2 == targets[0])
                #expect(presenter.snackbar == nil)
            }
        }
    }

    @Test func actionLifetimeCanPauseResumeOrRemainOpenAndTapIsOnceOnly() async throws {
        try await withViewTestWindow { host, _ in
            var calls = 0
            let bar = Snackbar(message: "Removed from inbox", action: .init(title: "Undo", identifier: "testUndo", perform: { calls += 1 }), actionTimeout: .milliseconds(30))
            host.view.addSubview(bar); bar.place(in: host.view.bounds, wide: false); bar.appear(animated: false); bar.pauseTimeout()
            try await Task.sleep(for: .milliseconds(80)); #expect(bar.superview != nil)
            bar.resumeTimeout(); try await wait { bar.superview == nil }
            #expect(calls == 0)
            let retained = Snackbar(message: "Removed from inbox", action: .init(title: "Undo", identifier: "testUndo", perform: { calls += 1 }), actionTimeout: nil)
            host.view.addSubview(retained); retained.place(in: host.view.bounds, wide: false); retained.appear(animated: false)
            let button: UIButton = try #require(find("testUndo", in: retained))
            button.sendActions(for: .touchUpInside); button.sendActions(for: .touchUpInside)
            #expect(calls == 1)
            retained.dismiss(animated: false)
        }
    }
    @Test func assistiveFocusTransferAndTouchHoldOwnIndependentTimeoutPauses() async throws {
        try await withViewTestWindow { host, _ in
            var dismissals = 0
            let bar = Snackbar(message: "Removed from inbox",
                action: .init(title: "Undo", identifier: "focusUndo", perform: {}), actionTimeout: .milliseconds(30))
            bar.onDismiss = { dismissals += 1 }
            host.view.addSubview(bar); bar.place(in: host.view.bounds, wide: false); bar.appear(animated: false)
            defer { bar.dismiss(animated: false) }
            let undo: UIButton = try #require(find("focusUndo", in: bar))
            // These exercise supported UIKit callback handling, not delivered VoiceOver input.
            bar.label.accessibilityElementDidBecomeFocused()
            try await Task.sleep(for: .milliseconds(60)); #expect(dismissals == 0)
            bar.pauseTimeout()
            bar.label.accessibilityElementDidLoseFocus(); undo.accessibilityElementDidBecomeFocused()
            bar.resumeTimeout()
            try await Task.sleep(for: .milliseconds(60)); #expect(dismissals == 0)
            bar.pauseTimeout(); undo.accessibilityElementDidLoseFocus()
            try await Task.sleep(for: .milliseconds(60)); #expect(dismissals == 0)
            bar.resumeTimeout()
            try await wait { dismissals == 1 }
        }
    }
    @Test func replacingFocusedOfferCannotCancelOrExtendReplacementTimeout() async throws {
        try await withViewTestWindow { host, _ in
            let old = Snackbar(message: "Old", action: .init(title: "Undo", identifier: "oldFocusUndo", perform: {}), actionTimeout: .milliseconds(30))
            host.view.addSubview(old); old.appear(animated: false); old.label.accessibilityElementDidBecomeFocused()
            old.dismiss(animated: false)
            let replacement = Snackbar(message: "New", action: .init(title: "Undo", identifier: "newFocusUndo", perform: {}), actionTimeout: .milliseconds(30))
            var dismissed = false; replacement.onDismiss = { dismissed = true }
            host.view.addSubview(replacement); replacement.appear(animated: false)
            defer { replacement.dismiss(animated: false) }
            old.label.accessibilityElementDidLoseFocus(); old.resumeTimeout()
            try await wait { dismissed }
            #expect(old.superview == nil && replacement.superview == nil)
        }
    }

    // These inject service state and invoke UIKit
    // callbacks to test policy mechanics. Actual VoiceOver has a separate journey.
    @Test(arguments: ["ordinaryUndo", "noAction", "unrelatedAction"])
    func ordinaryDurationAndUnrelatedNoticesDoNotAcquireUnvisitedRetention(kind: String) async throws {
        try await withViewTestWindow { host, _ in
            let action: Snackbar.Action? = kind == "noAction" ? nil : .init(title: "Undo", identifier: "ordinaryUndo", perform: {})
            let bar = Snackbar(message: "Notice", action: action,
                retainUnvisitedForVoiceOver: kind != "unrelatedAction", voiceOverRunning: { kind != "ordinaryUndo" })
            host.view.addSubview(bar)
            var ended: ContinuousClock.Instant?
            bar.onDismiss = { ended = .now }
            let began = ContinuousClock.now
            bar.appear(animated: false)
            defer { bar.dismiss(animated: false) }
            try await wait { bar.alpha == 0 || bar.superview == nil }
            #expect(began.duration(to: .now) >= .milliseconds(2_750))
            try await wait { ended != nil }
            #expect(bar.superview == nil)
        }
    }
    @Test func voiceOverUnvisitedFocusTransferAndTouchResumeFullGrace() async throws {
        try await withViewTestWindow { host, _ in
            var running = false
            let bar = Snackbar(message: "Removed from inbox",
                action: .init(title: "Undo", identifier: "policyUndo", perform: {}), actionTimeout: .milliseconds(100),
                retainUnvisitedForVoiceOver: true, voiceOverRunning: { running })
            host.view.addSubview(bar); bar.place(in: host.view.bounds, wide: false)
            running = true // Capture at appearance, not initialization.
            bar.appear(animated: false)
            defer { bar.dismiss(animated: false) }
            let undo: UIButton = try #require(find("policyUndo", in: bar))
            try await Task.sleep(for: .milliseconds(250)); #expect(bar.superview != nil && bar.alpha == 1)
            bar.label.accessibilityElementDidBecomeFocused()
            try await Task.sleep(for: .milliseconds(150)); #expect(bar.superview != nil && bar.alpha == 1)
            bar.pauseTimeout(); bar.label.accessibilityElementDidLoseFocus()
            undo.accessibilityElementDidBecomeFocused(); bar.resumeTimeout()
            try await Task.sleep(for: .milliseconds(150)); #expect(bar.superview != nil && bar.alpha == 1)
            bar.pauseTimeout(); undo.accessibilityElementDidLoseFocus()
            try await Task.sleep(for: .milliseconds(150)); #expect(bar.superview != nil && bar.alpha == 1)
            var ended: ContinuousClock.Instant?
            bar.onDismiss = { ended = .now }
            let resumed = ContinuousClock.now
            bar.resumeTimeout()
            try await wait { bar.alpha == 0 || bar.superview == nil }
            #expect(resumed.duration(to: .now) >= .milliseconds(100))
            try await wait { ended != nil }
        }
    }
    @Test(arguments: [false, true])
    func voiceOverOffStartsFullGraceDespiteStaleFocusAndReenable(visited: Bool) async throws {
        try await withViewTestWindow { host, _ in
            var running = true
            let bar = Snackbar(message: "Removed from inbox",
                action: .init(title: "Undo", identifier: "offUndo", perform: {}), actionTimeout: .milliseconds(100),
                retainUnvisitedForVoiceOver: true, voiceOverRunning: { running })
            host.view.addSubview(bar); bar.appear(animated: false)
            defer { bar.dismiss(animated: false) }
            let undo: UIButton = try #require(find("offUndo", in: bar))
            if visited { undo.accessibilityElementDidBecomeFocused() }
            try await Task.sleep(for: .milliseconds(150)); #expect(bar.superview != nil && bar.alpha == 1)
            var ended: ContinuousClock.Instant?
            bar.onDismiss = { ended = .now }
            let disabled = ContinuousClock.now
            running = false
            NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
            // No lose-focus callback: this is the stale-focus regression boundary.
            undo.accessibilityElementDidBecomeFocused()
            running = true
            NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
            try await wait { bar.alpha == 0 || bar.superview == nil }
            #expect(disabled.duration(to: .now) >= .milliseconds(100))
            try await wait { ended != nil }
            undo.accessibilityElementDidBecomeFocused(); bar.resumeTimeout(); bar.appear(animated: false)
            NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
            #expect(bar.superview == nil)
        }
    }
    @Test func enablingVoiceOverAfterPresentationDoesNotInventUnvisitedHold() async throws {
        try await withViewTestWindow { host, _ in
            var running = false
            let bar = Snackbar(message: "Removed from inbox",
                action: .init(title: "Undo", identifier: "lateUndo", perform: {}), actionTimeout: .milliseconds(100),
                retainUnvisitedForVoiceOver: true, voiceOverRunning: { running })
            host.view.addSubview(bar); bar.appear(animated: false)
            defer { bar.dismiss(animated: false) }
            running = true
            NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
            try await wait { bar.superview == nil }
        }
    }
    @Test func explicitAccessibilityDismissEndsUnvisitedOfferExactlyOnce() async throws {
        try await withViewTestWindow { host, _ in
            var dismissals = 0, actions = 0
            let bar = Snackbar(message: "Removed from inbox",
                action: .init(title: "Undo", identifier: "dismissUndo", perform: { actions += 1 }),
                retainUnvisitedForVoiceOver: true, voiceOverRunning: { true })
            bar.onDismiss = { dismissals += 1 }
            host.view.addSubview(bar); bar.appear(animated: false)
            let dismiss = try #require(bar.accessibilityCustomActions?.first)
            #expect(dismiss.name == Appearance.text("dismiss_label"))
            // Invoke the registered UIKit action, not a synthetic focus pass.
            let selector = dismiss.selector
            _ = (try #require(dismiss.target as? NSObject)).perform(selector)
            try await wait { bar.superview == nil }
            let undo: UIButton = try #require(find("dismissUndo", in: bar))
            undo.sendActions(for: .touchUpInside); bar.label.accessibilityElementDidBecomeFocused()
            bar.resumeTimeout(); bar.appear(animated: false)
            NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
            #expect(dismissals == 1 && actions == 0 && bar.superview == nil)
        }
    }
    @Test(arguments: ["retained", "replaced", "dismissed", "disposed"])
    func retainedOfferLifetimeNeverOwnsIndependentTwoSecondCleanup(ending: String) async throws {
        try await library { store, _, coordinator, clock, models, targets in
            try await withViewTestWindow { host, _ in
                var presenter: SwipeOfferPresenter? = SwipeOfferPresenter(host: host.view, store: store,
                    coordinator: coordinator, actionTimeout: { .milliseconds(2_750) },
                    region: { host.view.bounds }, wide: { false }, voiceOverRunning: { true })
                var events: [EpisodeSwipeCoordinator.Event] = []
                coordinator.onEvent = { [weak presenter] event in events.append(event); presenter?.receive(event) }
                defer { coordinator.onEvent = nil; presenter?.dismiss() }
                guard case .committed(let first) = await coordinator.perform(model: models[0], action: .removeInbox,
                    target: targets[0], offersUndo: true) else { throw FeedLibraryError.invalidMutation }
                let old = try #require(presenter?.snackbar)
                try await wait { !clock.pending.isEmpty }
                if ending == "replaced" {
                    guard case .committed = await coordinator.perform(model: models[1], action: .removeInbox,
                        target: targets[1], offersUndo: true) else { throw FeedLibraryError.invalidMutation }
                } else if ending == "dismissed" { presenter?.dismiss() }
                else if ending == "disposed" { presenter = nil }
                // Advance the independent source cleanup clock by exactly2s.
                clock.advance()
                try await wait { events.contains { if case .cleanupFinished(first.operationID, .deleted) = $0 { true } else { false } } }
                #expect(try await store.episode(id: models[0].episodeID)?.userState.playState == .unplayed)
                if ending == "retained" {
                    #expect(presenter?.snackbar === old && old.superview != nil)
                    let undo: UIButton = try #require(find("inboxSwipeUndo", in: old))
                    undo.sendActions(for: .touchUpInside)
                    try await wait { try await store.episode(id: models[0].episodeID)?.userState.playState == .new }
                } else {
                    let replacement = presenter?.snackbar
                    let undo: UIButton = try #require(find("inboxSwipeUndo", in: old))
                    old.label.accessibilityElementDidBecomeFocused(); old.label.accessibilityElementDidLoseFocus()
                    old.resumeTimeout(); old.appear(animated: false); undo.sendActions(for: .touchUpInside)
                    NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
                    #expect(old.superview == nil && presenter?.snackbar === replacement)
                    #expect(try await store.episode(id: models[0].episodeID)?.userState.playState == .unplayed)
                }
            }
        }
    }

}

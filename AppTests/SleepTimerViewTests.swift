import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor private final class SleepViewEngine: PlaybackVolumeControlling {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    private var generation: UUID?
    private var command: UUID?
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) { self.generation = generation; command = generation }
    func play(commandID: UUID) { command = commandID }
    func pause(commandID: UUID) { command = commandID }
    func seek(to positionMilliseconds: Int64, commandID: UUID) { command = commandID }
    func setSpeed(_ speed: Float, commandID: UUID) throws { command = commandID }
    func setVolumeAdaptation(_ adaptation: FeedVolumeAdaptation) throws {}
    func setSleepTimerVolume(_ volume: Float) throws {}
    func tick() { if let reading { onEvent?(.position(reading)) } }
    func unload() { reading = nil }
    func ready() {
        guard let generation, let command else { return }
        let value = PlaybackEngineReading(generation: generation, commandID: command,
            sample: .init(positionMilliseconds: 0, durationMilliseconds: 60_000, status: .playing))
        reading = value; onEvent?(.ready(value))
    }
}

@MainActor @Suite(.serialized)
struct SleepTimerViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) throws -> T {
        func search(_ view: UIView) -> T? {
            if view.accessibilityIdentifier == id { return view as? T }
            return view.subviews.lazy.compactMap { search($0) }.first
        }
        return try #require(search(view), "Missing \(id)")
    }
    private func tap(_ id: String, in view: UIView) throws { let button: UIButton = try find(id, in: view); button.sendActions(for: .touchUpInside) }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    private func fixture(_ body: (FeedLibraryStore, LibraryFeed, PlaybackCoordinator, SleepTimerPreferenceStore, PlaybackQueuePreferenceStore, URL, SleepViewEngine) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SleepView-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let source = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Podcast", episodes: [
                .init(identifier: "episode", title: "Episode", media: .init(url: "https://example.invalid/audio.mp3", size: 0, durationMilliseconds: 60_000))
            ]), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            let settings = try SleepTimerPreferenceStore(file: directory.appendingPathComponent("sleep.json"))
            let queue = try PlaybackQueuePreferenceStore(file: directory.appendingPathComponent("queue.json"))
            let engine = SleepViewEngine()
            let playback = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
                var value = PlaybackPreferences(); value.followQueue = queue.value.followQueue; return value
            }, sleepTimerPreferences: settings, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
            try await playback.select(episodeID: feed.episodes[0].id); engine.ready()
            try await wait { playback.phase == .playing }
            try await body(store, feed, playback, settings, queue, directory, engine)
            try await playback.stop(); try await store.close()
        } catch { try? await store.close(); throw error }
    }

    /// Android PlaybackService: an auto-enabled timer posts "Sleep timer enabled" with Undo; a timer the person
    /// starts in the dialog does not.
    @Test func autoEnabledTimerShowsSleepTimerEnabledWithUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SleepAuto-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let source = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Podcast", episodes: [
                .init(identifier: "episode", title: "Episode", media: .init(url: "https://example.invalid/audio.mp3", size: 0, durationMilliseconds: 60_000))
            ]), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            let settings = try SleepTimerPreferenceStore(file: directory.appendingPathComponent("sleep.json"))
            // From = to: any hour (Android's default range is 22–6).
            var value = settings.value; value.autoEnable = true; value.autoFromHour = 0; value.autoToHour = 0; try settings.update(value)
            let queue = try PlaybackQueuePreferenceStore(file: directory.appendingPathComponent("queue.json"))
            let engine = SleepViewEngine()
            let playback = PlaybackCoordinator(store: store, engine: engine, sleepTimerPreferences: settings,
                                               clock: { Date(timeIntervalSince1970: 1_700_000_000) })
            let time = try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json"))
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil,
                usage: nil, sleepTimerPreferences: settings, playbackQueuePreferences: queue)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds; controller.view.layoutIfNeeded()
                await controller.reloadLibrary()?.value
                try await playback.select(episodeID: feed.episodes[0].id); engine.ready()
                try await wait { playback.sleepTimerValue != nil }
                @MainActor func undo() -> UIButton? {
                    func search(_ view: UIView) -> UIButton? {
                        if view.accessibilityIdentifier == "sleepTimerEnabledUndo" { return view as? UIButton }
                        return view.subviews.lazy.compactMap(search).first
                    }
                    return search(controller.view)
                }
                try await wait { undo() != nil }
                let snackbar = try #require(undo()?.superview)
                #expect(snackbar.subviews.compactMap { $0 as? UILabel }.contains { $0.text == "Sleep timer enabled" })
                #expect(undo()?.title(for: .normal)?.localizedCaseInsensitiveCompare("Undo") == .orderedSame)
                undo()?.sendActions(for: .touchUpInside)
                try await wait { playback.sleepTimerValue == nil }
                try await wait { undo() == nil }
                // The person's own timer from the dialog is not announced.
                let dialog = SleepTimerController(playback: playback, preferences: settings, queuePreferences: queue, library: store, openPlaybackSettings: {})
                controller.present(dialog, animated: false)
                try await wait { dialog.viewIfLoaded?.window != nil && !dialog.isBeingPresented }
                try tap("sleepTimerSet", in: dialog.view)
                try await wait { playback.sleepTimerValue != nil }
                engine.tick()
                for _ in 0..<20 { await Task.yield() }
                #expect(undo() == nil)
            }
            try await playback.stop(); try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test(arguments: [false, true])
    func toolbarAndDialogStartExtendDisableRetainStateAcrossResize(rtl: Bool) async throws {
        try await fixture { store, feed, playback, settings, queue, directory, engine in
            let time = try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json"))
            let player = PlayerView(playback: playback, timeDisplayPreferences: time, library: store)
            player.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            player.frame = CGRect(x: 0, y: 0, width: 402, height: 800); player.expandedSize = player.bounds.size
            player.update(feed: feed, stored: feed.episodes.first); player.setExpanded(true, animated: false); player.layoutIfNeeded()
            let timer: UIButton = try find("playerSleepTimer", in: player)
            #expect(timer.accessibilityLabel == "Set sleep timer" && timer.currentImage === UIImage(named: "ic_sleep"))
            // Toolbar slot as on Android (favorite, sleep timer, share, overflow: `mediaplayer.xml`), to within a point.
            #expect(abs(timer.frame.minX - (rtl ? 136 : 218)) <= 1 && abs(timer.frame.minY - 8) <= 1)
            #expect(abs(timer.frame.width - 48) <= 1 && abs(timer.frame.height - 48) <= 1)
            var opened = 0; player.showSleepTimer = { opened += 1 }; timer.sendActions(for: .touchUpInside); #expect(opened == 1)
            let controller = SleepTimerController(playback: playback, preferences: settings, queuePreferences: queue, library: store, openPlaybackSettings: {})
            try await withViewTestWindow { host, window in
                host.present(controller, animated: false)
                try await wait { controller.viewIfLoaded?.window != nil && !controller.isBeingPresented }
                controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                let input: UITextField = try find("sleepTimerInput", in: controller.view)
                #expect(input.text == "15")
                let shake: UIButton = try find("sleepTimerShake", in: controller.view)
                #expect(shake.accessibilityValue == "On")
                input.text = "2"; input.sendActions(for: .editingChanged)
                try tap("sleepTimerSet", in: controller.view)
                try await wait { playback.sleepTimerValue?.display == 120_000 }
                #expect(settings.value.lastValue == "2" && playback.wantsPlayback)
                player.update(feed: feed, stored: feed.episodes.first)
                #expect(timer.accessibilityLabel == "Sleep timer" && timer.currentImage === UIImage(named: "ic_sleep_off"))
                timer.sendActions(for: .touchUpInside); #expect(opened == 2)
                let remaining: UILabel = try find("sleepTimerRemaining", in: controller.view)
                let extend: UIButton = try find("sleepTimerExtend0", in: controller.view)
                try await wait { remaining.text == "00:02:00" && input.isHidden && extend.isEnabled }
                try tap("sleepTimerExtend0", in: controller.view)
                try await wait { playback.sleepTimer?.value.display == 420_000 }
                engine.tick()
                try await wait { playback.sleepTimerValue?.display == 420_000 }
                try await wait { remaining.text == "00:07:00" }
                for insets in [UIEdgeInsets(top: 0, left: 31, bottom: 0, right: 7), .init(top: 0, left: 7, bottom: 0, right: 31)] {
                    controller.additionalSafeAreaInsets = insets; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                    let panel: UIView = try find("sleepTimerSheet", in: controller.view)
                    let frame = panel.convert(panel.bounds, to: controller.view), safe = controller.view.safeAreaLayoutGuide.layoutFrame
                    #expect(frame.minX >= safe.minX && frame.maxX <= safe.maxX)
                    let baseline = panel.frame
                    panel.transform = CGAffineTransform(translationX: 0, y: 60)
                    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                    #expect(abs(panel.frame.minY - baseline.minY - 60) <= 1)
                    panel.transform = .identity
                    #expect(abs(panel.frame.minY - baseline.minY) <= 1)
                    let disable: UIButton = try find("sleepTimerDisable", in: controller.view)
                    // Android time_dialog.xml places Disable directly after
                    // the extension row; button drawings supply their own insets.
                    #expect(abs(extend.convert(extend.bounds, to: controller.view).maxY - disable.convert(disable.bounds, to: controller.view).minY) <= 1)
                    #expect(window.hitTest(disable.convert(CGPoint(x: disable.bounds.midX, y: disable.bounds.midY), to: window), with: nil) === disable)
                    #expect(playback.sleepTimerValue?.display == 420_000)
                }
                try tap("sleepTimerDisable", in: controller.view); try await wait { playback.sleepTimerValue == nil && !input.isHidden }
                #expect(playback.wantsPlayback && input.text == "2")
                #expect(controller.accessibilityPerformEscape()); try await wait { host.presentedViewController == nil }
            }
            var local = feed; local.source = "antennapod_local:fixture"; player.update(feed: local, stored: local.episodes.first); player.layoutIfNeeded()
            #expect(abs(timer.frame.minX - (rtl ? 88 : 266)) <= 1)
        }
    }

    @Test func inputModePersistenceHintsAndContinuousPlaybackBinding() async throws {
        try await fixture { store, _, playback, settings, queue, directory, engine in
            let controller = SleepTimerController(playback: playback, preferences: settings, queuePreferences: queue, library: store, openPlaybackSettings: {})
            try await withViewTestWindow { host, _ in
                host.present(controller, animated: false)
                try await wait { controller.viewIfLoaded?.window != nil && !controller.isBeingPresented }
                let input: UITextField = try find("sleepTimerInput", in: controller.view)
                #expect(!controller.textField(input, shouldChangeCharactersIn: NSRange(location: 0, length: 2), replacementString: "1234"))
                #expect(!controller.textField(input, shouldChangeCharactersIn: NSRange(location: 0, length: 2), replacementString: "-2"))
                input.text = "0"; try tap("sleepTimerSet", in: controller.view)
                let message: UILabel = try find("sleepTimerMessage", in: controller.view)
                #expect(message.text?.contains("Invalid input") == true && playback.sleepTimerValue == nil)
                input.text = "007"
                try tap("sleepTimerMode", in: controller.view); try tap("sleepTimerModeEpisodes", in: controller.view)
                #expect(settings.value.mode == .episodes && input.text == "1")
                let shake: UIButton = try find("sleepTimerShake", in: controller.view); #expect(shake.isHidden && settings.value.shakeToReset)
                input.text = "3"; input.sendActions(for: .editingChanged)
                let hint: UILabel = try find("sleepTimerHint", in: controller.view)
                try await wait { hint.text?.contains("episode") == true }
                try tap("sleepTimerMode", in: controller.view); try tap("sleepTimerModeMinutes", in: controller.view)
                #expect(input.text == "7")
                try tap("sleepTimerMode", in: controller.view); try tap("sleepTimerModeEpisodes", in: controller.view)
                #expect(input.text == "3")
                var queueValue = queue.value; queueValue.followQueue = false; try queue.update(queueValue)
                input.sendActions(for: .editingChanged)
                let set: UIButton = try find("sleepTimerSet", in: controller.view)
                #expect(!set.isEnabled && !input.isEnabled)
                #expect(hint.text == Appearance.text("multiple_sleep_episodes_while_continuous_playback_disabled"))
                let automatic: UIButton = try find("sleepTimerAutomatic", in: controller.view); #expect(automatic.isHidden)
                try tap("sleepTimerMode", in: controller.view); try tap("sleepTimerModeMinutes", in: controller.view)
                #expect(set.isEnabled && input.isEnabled)
                try await wait { hint.text?.contains("minute") == true }
                try await playback.pause(); try tap("sleepTimerSet", in: controller.view)
                #expect(message.text?.contains("No media playing") == true && playback.sleepTimerValue == nil)
                controller.dismiss(animated: false); try await wait { host.presentedViewController == nil }
            }
            let saved = try SleepTimerPreferenceStore(file: directory.appendingPathComponent("sleep.json"))
            #expect(saved.value.mode == .minutes && saved.value.lastValue == "7")
            let restored = try PlaybackQueuePreferenceStore(file: directory.appendingPathComponent("queue.json"))
            #expect(!restored.value.followQueue)
            let preferences = NavigationSettingsView(navigation: nil, timeDisplay: nil, page: .playback, width: 402, playbackQueue: restored)
            let row: UIControl = try find("prefFollowQueue", in: preferences)
            row.sendActions(for: .touchUpInside)
            #expect(restored.value.followQueue)
            #expect(try PlaybackQueuePreferenceStore(file: directory.appendingPathComponent("queue.json")).value.followQueue)
        }
    }

    @Test func blockedSettingsReturnRetainsExpandedPlayerAndAppliesPreference() async throws {
        try await fixture { store, feed, playback, settings, queue, directory, engine in
            var sleep = settings.value; sleep.mode = .episodes; try settings.update(sleep)
            var continuous = queue.value; continuous.followQueue = false; try queue.update(continuous)
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json")),
                navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil,
                sleepTimerPreferences: settings, playbackQueuePreferences: queue)
            try await withViewTestWindow { host, window in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                await controller.reloadLibrary()?.value
                func locatePlayer(_ view: UIView) -> PlayerView? { (view as? PlayerView) ?? view.subviews.lazy.compactMap(locatePlayer).first }
                let player = try #require(locatePlayer(controller.view))
                player.setExpanded(true, animated: false); controller.view.layoutIfNeeded()
                try tap("playerSleepTimer", in: controller.view)
                try await wait { controller.presentedViewController is SleepTimerController && controller.presentedViewController?.isBeingPresented == false }
                try tap("sleepTimerPlaybackSettings", in: controller.presentedViewController!.view)
                try await wait { controller.presentedViewController == nil }
                controller.view.layoutIfNeeded()
                let row: UIControl = try find("prefFollowQueue", in: controller.view)
                var ancestor = row.superview
                while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
                let list = try #require(ancestor as? UIScrollView)
                list.scrollRectToVisible(row.convert(row.bounds, to: list), animated: false)
                let point = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: window)
                #expect(window.hitTest(point, with: nil)?.isDescendant(of: row) == true)
                #expect(player.isHidden && player.expansion == 1)
                let toolbar: UIView = try find("mainToolbar", in: controller.view)
                let content: UIView = try find("libraryContent", in: controller.view)
                #expect(!toolbar.accessibilityElementsHidden && !content.accessibilityElementsHidden)
                try await playback.pause(); controller.view.layoutIfNeeded()
                #expect(player.isHidden && playback.episode?.id == feed.episodes[0].id)
                try await playback.play()
                // Playback updates can rebuild the settings rows; resolve the
                // currently mounted control after those awaited state changes.
                let currentRow: UIControl = try find("prefFollowQueue", in: controller.view)
                currentRow.sendActions(for: .touchUpInside); #expect(queue.value.followQueue)
                #expect(controller.accessibilityPerformEscape()); controller.view.layoutIfNeeded()
                #expect(!player.isHidden && player.expansion == 1 && playback.wantsPlayback)
                try tap("playerSleepTimer", in: controller.view)
                try await wait { controller.presentedViewController is SleepTimerController && controller.presentedViewController?.isBeingPresented == false }
                let set: UIButton = try find("sleepTimerSet", in: controller.presentedViewController!.view)
                #expect(set.isEnabled)
                controller.dismiss(animated: false); try await wait { controller.presentedViewController == nil }
            }
        }
    }

    @Test(arguments: [false, true])
    func wholeDayEpisodeConfirmationCancelsOrDisablesContinuousPlayback(disable: Bool) async throws {
        try await fixture { store, _, playback, settings, queue, _, _ in
            var value = settings.value; value.mode = .episodes; value.autoFromHour = 0; value.autoToHour = 0; try settings.update(value)
            let controller = SleepTimerController(playback: playback, preferences: settings, queuePreferences: queue, library: store, openPlaybackSettings: {})
            try await withViewTestWindow { host, _ in
                host.present(controller, animated: false)
                try await wait { controller.viewIfLoaded?.window != nil && !controller.isBeingPresented }
                try tap("sleepTimerAutomatic", in: controller.view)
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                let confirmation = try #require(controller.presentedViewController)
                if disable { try tap("sleepTimerDisableContinuous", in: confirmation.view) }
                else { #expect(confirmation.accessibilityPerformEscape()) }
                try await wait { controller.presentedViewController == nil }
                #expect(!settings.value.autoEnable && queue.value.followQueue == !disable)
                controller.dismiss(animated: false); try await wait { host.presentedViewController == nil }
            }
        }
    }

    /// The sheet refreshes on every playback tick; unchanged checkboxes must not repaint, while a toggled one does.
    @Test func refreshRepaintsOnlyChangedCheckboxes() async throws {
        try await fixture { store, _, playback, settings, queue, _, _ in
            let controller = SleepTimerController(playback: playback, preferences: settings, queuePreferences: queue, library: store, openPlaybackSettings: {})
            try await withViewTestWindow { host, _ in
                host.present(controller, animated: false)
                try await wait { controller.viewIfLoaded?.window != nil && !controller.isBeingPresented }
                let input: UITextField = try find("sleepTimerInput", in: controller.view)
                let boxes: [UIButton] = try ["sleepTimerShake", "sleepTimerVibrate", "sleepTimerAutomatic"].map { try find($0, in: controller.view) }
                controller.view.layoutIfNeeded(); boxes.forEach { $0.layer.displayIfNeeded() }
                input.sendActions(for: .editingChanged)
                #expect(boxes.allSatisfy { !$0.layer.needsDisplay() })
                try tap("sleepTimerShake", in: controller.view)
                #expect(boxes[0].accessibilityValue == "Off" && boxes[0].layer.needsDisplay())
                controller.dismiss(animated: false); try await wait { host.presentedViewController == nil }
            }
        }
    }
}

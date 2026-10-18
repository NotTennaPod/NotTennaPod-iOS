import UIKit
import MediaPlayer
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// The "Set notification buttons" row and dialog, and the Now Playing commands the
/// choice offers, checked on the real MPRemoteCommandCenter with the app's command handler.
@MainActor @Suite(.serialized)
struct NowPlayingViewTests {
    private func find<T: UIView>(_ id: String, _ view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let found = view as? T { return found }
        for child in view.subviews { if let result: T = find(id, child) { return result } }; return nil
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NowPlayingView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func userInterfaceRowOpensTheChoice() throws {
        let view = NavigationSettingsView(navigation: nil, timeDisplay: nil, page: .userInterface, width: 390)
        let row: UIControl = try #require(find("prefFullNotificationButtons", view))
        #expect(row.accessibilityLabel == "Set notification buttons")
        #expect(row.accessibilityHint == "Change the buttons on the playback notification")
        #expect(row.isEnabled && row.accessibilityTraits.contains(.button))
        // It sits in "External elements", before the Behavior rows.
        let behaviour: UIControl = try #require(find("prefDefaultPage", view))
        #expect(row.frame.maxY <= behaviour.frame.minY)
        var opened: [String] = []
        view.onPreferenceAction = { opened.append($0) }
        row.sendActions(for: .touchUpInside)
        #expect(opened == ["prefFullNotificationButtons"])
    }

    @Test func dialogShowsTheOfferedButtonsAndOnlyConfirmSaves() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notification-buttons.json")
        let store = try NotificationButtonPreferenceStore(file: file)
        try await withViewTestWindow { host, _ in
            @MainActor func open() async throws -> SourceSingleChoiceController {
                let dialog = NotificationButtonsDialog.make(store: store)
                host.present(dialog, animated: false)
                try await wait { host.presentedViewController === dialog && !dialog.isBeingPresented }
                dialog.view.layoutIfNeeded()
                return dialog
            }
            @MainActor func control(_ id: String, _ dialog: UIViewController) throws -> UIControl { try #require(find(id, dialog.view)) }
            @MainActor func checked(_ dialog: UIViewController) throws -> [Bool] {
                try ["2", "4"].map { try control("prefFullNotificationButtons-" + $0, dialog).accessibilityTraits.contains(.selected) }
            }
            var dialog = try await open()
            let title: UIView = try #require(find("prefFullNotificationButtonsTitle", dialog.view))
            #expect(title.accessibilityLabel == "Set notification buttons")
            #expect(title.frame.height > 0 && !title.isHidden)
            let rows = [try control("prefFullNotificationButtons-2", dialog), try control("prefFullNotificationButtons-4", dialog)]
            #expect(rows.map(\.accessibilityLabel) == ["Skip episode", "Playback speed"])
            #expect(rows[0].frame.minY < rows[1].frame.minY)
            #expect(find("prefFullNotificationButtons-3", dialog.view) as UIView? == nil)
            #expect(find("prefFullNotificationButtons-5", dialog.view) as UIView? == nil)
            let confirm: UIButton = try #require(find("prefFullNotificationButtonsConfirm", dialog.view))
            let cancel: UIButton = try #require(find("prefFullNotificationButtonsCancel", dialog.view))
            #expect(confirm.title(for: .normal) == "Confirm" && cancel.title(for: .normal) == "Cancel")
            #expect(try checked(dialog) == [true, true])

            // Ticking edits only the draft; Cancel keeps the saved choice.
            rows[1].sendActions(for: .touchUpInside)
            #expect(try checked(dialog) == [true, false])
            #expect(store.value.buttons == [.skipEpisode, .playbackSpeed])
            cancel.sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil }
            #expect(store.value.buttons == [.skipEpisode, .playbackSpeed])

            dialog = try await open()
            try control("prefFullNotificationButtons-4", dialog).sendActions(for: .touchUpInside)
            try control("prefFullNotificationButtonsConfirm", dialog).sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil }
            #expect(store.value.buttons == [.skipEpisode])
            #expect(try NotificationButtonPreferenceStore(file: file).value.buttons == [.skipEpisode])

            // Reopening shows the saved choice; clearing everything is also saved.
            dialog = try await open()
            #expect(try checked(dialog) == [true, false])
            try control("prefFullNotificationButtons-2", dialog).sendActions(for: .touchUpInside)
            try control("prefFullNotificationButtonsConfirm", dialog).sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil }
            #expect(try NotificationButtonPreferenceStore(file: file).value.buttons == [])
        }
    }

    /// Each offered button chosen/not chosen: the MPRemoteCommandCenter command is enabled only when chosen,
    /// changes at once during playback, and a delivered command does what Android's button does.
    @Test func chosenButtonsDriveTheSystemCommandsAndTheirActions() async throws {
        let app = UIApplication.shared.delegate as? AppDelegate
        // The host app's own runtime shares the process-wide command center; pause it for isolation.
        app?.playbackSystemControls?.stop()
        defer { app?.playbackSystemControls?.start() }
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let intervals = try PlaybackIntervalPreferenceStore(file: root.appendingPathComponent("intervals.json"))
        let hardware = try PlaybackHardwarePreferenceStore(file: root.appendingPathComponent("hardware.json"))
        let buttons = try NotificationButtonPreferenceStore(file: root.appendingPathComponent("buttons.json"))
        let center = MPRemoteCommandCenter.shared()
        try await PCPlaybackFixture.withFixture { f in
            let runtime = PlaybackSystemControlsRuntime(playback: f.player, library: f.store, intervals: intervals,
                hardware: hardware, remote: { false }, buttons: buttons, presets: { [1, 1.25, 1.5] })
            runtime.start(); defer { runtime.stop() }
            _ = try await f.store.enqueue([1, 2])
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            try await wait { center.pauseCommand.isEnabled }

            // Default: Skip episode and Playback speed.
            #expect(center.nextTrackCommand.isEnabled && center.changePlaybackRateCommand.isEnabled)
            #expect(center.changePlaybackRateCommand.supportedPlaybackRates.map(\.floatValue) == [1, 1.25, 1.5])
            for (indices, skip, speed) in [(Set([1]), false, true), (Set([0]), true, false), (Set<Int>(), false, false), (Set([0, 1]), true, true)] {
                try buttons.select(indices)
                try await wait { center.nextTrackCommand.isEnabled == skip && center.changePlaybackRateCommand.isEnabled == speed }
                // Rewind, fast forward, seeking and play/pause are always there, as on Android.
                #expect(center.skipForwardCommand.isEnabled && center.skipBackwardCommand.isEnabled)
                #expect(center.changePlaybackPositionCommand.isEnabled && center.togglePlayPauseCommand.isEnabled)
            }

            // Playback speed chosen: a rate command changes this episode's speed only.
            #expect(runtime.receive(.rate(1.5)) == .success)
            try await wait { f.player.speed == 1.5 }
            try buttons.select([0])
            #expect(runtime.receive(.rate(1.25)) == .commandFailed)
            try await f.player.awaitPendingOperations()
            #expect(f.player.speed == 1.5)

            // Skip episode not chosen: next-track does nothing.
            try buttons.select([1])
            #expect(runtime.receive(.next) == .commandFailed)
            try await f.player.awaitPendingOperations()
            #expect(f.player.episode?.id == 1)
            // Chosen: next-track does the "Forward button" action (default fast-forward 30 s) ...
            try buttons.select([0, 1])
            f.engine.position(10_000); try await f.player.awaitPendingOperations()
            #expect(runtime.receive(.next) == .success)
            try await wait { f.engine.seeks.last.map { abs($0 - 40_000) <= 250 } == true }
            // ... and with "Forward button" set to Skip episode it moves to the next queued episode.
            var choice = hardware.value; choice.forward = .next; try hardware.update(choice)
            #expect(runtime.receive(.next) == .success)
            try await wait { f.player.episode?.id == 2 }
        }
    }

    /// Lock-screen time: iOS advances it from the published position and rate, so a playback tick on track
    /// does not republish (that re-encodes the artwork), while seeks, speed changes and pause do, at once.
    @Test func lockScreenPositionFollowsSeeksAndSpeedWithoutRepublishingEveryTick() async throws {
        let app = UIApplication.shared.delegate as? AppDelegate
        app?.playbackSystemControls?.stop()
        defer { app?.playbackSystemControls?.start() }
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let intervals = try PlaybackIntervalPreferenceStore(file: root.appendingPathComponent("intervals.json"))
        let hardware = try PlaybackHardwarePreferenceStore(file: root.appendingPathComponent("hardware.json"))
        final class Clock { var now: TimeInterval = 1_000 }
        let clock = Clock()
        let center = MPNowPlayingInfoCenter.default()
        func elapsed() -> Double? { center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double }
        func rate() -> Float? { center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Float }
        try await PCPlaybackFixture.withFixture { f in
            let runtime = PlaybackSystemControlsRuntime(playback: f.player, library: f.store, intervals: intervals,
                hardware: hardware, remote: { false }, uptime: { clock.now })
            runtime.start(); defer { runtime.stop() }
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            try await f.player.play()
            f.engine.position(10_000); try await f.player.awaitPendingOperations()
            try await wait { elapsed() == 10 && rate() == 1 }
            #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Episode 1")

            // Ticks that follow the extrapolated clock (within half a second) keep what was published.
            for second in 1...3 {
                clock.now += 1
                let before = runtime.refreshes
                f.engine.position(Int32(10_000 + second * 1_000 + 200)); try await f.player.awaitPendingOperations()
                try await wait { runtime.refreshes > before }
                #expect(elapsed() == 10)
            }
            // A seek (also a stall) leaves that track: published at once.
            clock.now += 1
            f.engine.position(60_000); try await f.player.awaitPendingOperations()
            try await wait { elapsed() == 60 }
            // A speed change republishes the rate with the current position.
            clock.now += 1
            f.engine.position(61_000); try await f.player.awaitPendingOperations()
            try await f.player.setSpeed(2); try await f.player.awaitPendingOperations()
            try await wait { rate() == 2 && elapsed() == 61 }
            // Pause: rate 0 at the paused position.
            try await f.player.pause()
            try await wait { rate() == 0 }
            #expect(elapsed() == 61)
        }
        #expect(center.nowPlayingInfo == nil)
    }
}

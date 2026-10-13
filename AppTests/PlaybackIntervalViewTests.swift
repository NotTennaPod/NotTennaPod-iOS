import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackIntervalViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func controls(_ view: UIView) -> [UIControl] {
        (view as? UIControl).map { [$0] } ?? view.subviews.flatMap(controls)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    @Test func settingsRoutesCommitEachDirectionAndCancelPreservesSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IntervalRoutes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let prefs = try PlaybackIntervalPreferenceStore(file: directory.appendingPathComponent("intervals.json"))
            let controller = LibraryViewController(library: library, startupError: nil, downloads: nil, playback: nil,
                timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil, intervalPreferences: prefs)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value
                @MainActor func tap(_ id: String, in view: UIView) throws {
                    view.layoutIfNeeded()
                    let control: UIControl = try #require(find(id, in: view)); control.sendActions(for: .touchUpInside)
                }
                try tap("navigationMore", in: controller.view)
                let settingsControl = controls(controller.view).first { $0.accessibilityLabel == "Settings" }
                let settings = try #require(settingsControl)
                settings.sendActions(for: .touchUpInside)
                try tap("prefScreenPlayback", in: controller.view)
                let reconnect: UIControl? = find("prefUnpauseOnHeadsetReconnect", in: controller.view)
                let bluetooth: UIControl? = find("prefUnpauseOnBluetoothReconnect", in: controller.view)
                #expect(reconnect == nil && bluetooth == nil)
                for direction in PlaybackIntervalDirection.allCases {
                    let key = direction.preferenceKey
                    try tap(key, in: controller.view)
                    try await wait { controller.presentedViewController?.isBeingPresented == false }
                    let dialog = try #require(controller.presentedViewController)
                    let choices = controls(dialog.view).filter { $0.accessibilityIdentifier?.hasPrefix(key + "-") == true }
                    #expect(choices.map(\.accessibilityLabel) == ["5 seconds", "10 seconds", "15 seconds", "20 seconds", "30 seconds", "45 seconds", "60 seconds"])
                    let selectedLabels = choices.filter { $0.accessibilityTraits.contains(.selected) }.map(\.accessibilityLabel)
                    #expect(selectedLabels == [direction == .rewind ? "10 seconds" : "30 seconds"])
                    try tap(key + "Cancel", in: dialog.view)
                    try await wait { controller.presentedViewController == nil }
                    #expect(prefs.value.seconds(for: direction) == (direction == .rewind ? 10 : 30))
                    try tap(key, in: controller.view)
                    try await wait { controller.presentedViewController?.isBeingPresented == false }
                    try tap(key + "-45", in: controller.presentedViewController!.view)
                    try await wait { controller.presentedViewController == nil }
                    #expect(prefs.value.seconds(for: direction) == 45)
                    try tap(key, in: controller.view)
                    try await wait { controller.presentedViewController?.isBeingPresented == false }
                    let selected: UIControl = try #require(find(key + "-45", in: controller.presentedViewController!.view))
                    #expect(selected.accessibilityTraits.contains(.selected))
                    #expect(controller.presentedViewController!.accessibilityPerformEscape())
                    try await wait { controller.presentedViewController == nil }
                }
                #expect(try PlaybackIntervalPreferenceStore(file: directory.appendingPathComponent("intervals.json")).value == prefs.value)
            }
            try await library.close()
        } catch { try? await library.close(); throw error }
    }

    @Test func playerLabelsAndAccessibleEditingRemainCurrentAcrossDialogResize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IntervalPlayer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let prefs = try PlaybackIntervalPreferenceStore(file: directory.appendingPathComponent("intervals.json"))
            var value = prefs.value; value.forwardSeconds = 60; try prefs.update(value)
            let player = PlayerView(playback: PlaybackCoordinator(store: library, engine: AVPlayerPlaybackEngine(muted: true)),
                timeDisplayPreferences: try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json")), intervalPreferences: prefs)
            var opened: [PlaybackIntervalDirection] = []
            player.showIntervalDialog = { opened.append($0) }
            let forward: UIButton = try #require(find("playerForward", in: player))
            #expect(forward.accessibilityValue == "60 seconds")
            let action = try #require(forward.accessibilityCustomActions?.first)
            #expect(action.actionHandler?(action) == true && opened == [.forward])
            let dialog = PlaybackIntervalController(direction: .forward, preferences: prefs)
            try await withViewTestWindow { host, _ in
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.additionalSafeAreaInsets = .init(top: 5, left: 29, bottom: 7, right: 3)
                for (size, category) in [(CGSize(width: 402, height: 800), UIContentSizeCategory.large),
                                         (CGSize(width: 270, height: 320), .accessibilityExtraExtraExtraLarge),
                                         (CGSize(width: 750, height: 520), .large)] {
                    dialog.view.frame = CGRect(origin: .zero, size: size)
                    dialog.traitOverrides.preferredContentSizeCategory = category
                    dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                    let list: UIScrollView = try #require(find(PlaybackIntervalDirection.forward.preferenceKey + "Choices", in: dialog.view))
                    let last: UIControl = try #require(find(PlaybackIntervalDirection.forward.preferenceKey + "-60", in: dialog.view))
                    #expect(last.accessibilityTraits.contains(.selected))
                    list.scrollRectToVisible(last.frame, animated: false)
                    #expect(list.bounds.intersects(last.frame))
                    let cancel: UIButton = try #require(find(PlaybackIntervalDirection.forward.preferenceKey + "Cancel", in: dialog.view))
                    #expect(cancel.bounds.width > 0 && cancel.bounds.height > 0)
                    #expect(prefs.value.forwardSeconds == 60)
                }
                let row: UIControl = try #require(find(PlaybackIntervalDirection.forward.preferenceKey + "-20", in: dialog.view))
                row.sendActions(for: .touchUpInside)
                try await wait { forward.accessibilityValue == "20 seconds" }
                let label: UILabel = try #require(find("playerForwardValue", in: player))
                #expect(label.text == "20" && prefs.value.rewindSeconds == 10)
            }
            try await library.close()
        } catch { try? await library.close(); throw error }
    }
}

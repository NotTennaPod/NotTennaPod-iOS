import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct GlobalDownloadSettingsViewTests {
    private func find<T: UIView>(_ id: String, _ view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let found = view as? T { return found }
        for child in view.subviews { if let result: T = find(id, child) { return result } }; return nil
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    @Test func globalSettingsRoutesChoicesConfirmationAndDependencyStatePersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GlobalSettingsView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let downloads = try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json"))
        let automatic = try AutomaticDownloadPreferenceStore(file: root.appendingPathComponent("automatic.json"))
        let mobile = try MobileNetworkPreferenceStore(file: root.appendingPathComponent("mobile.json"))
        let nav = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nav, speedPreferences: nil, mobileNetworkPreferences: mobile, usage: nil,
            automaticDownloadPreferences: automatic, downloadPreferences: downloads)
        do {
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                @MainActor func control(_ id: String, modal: Bool = false) throws -> UIControl {
                    controller.view.layoutIfNeeded()
                    return try #require(find(id, modal ? controller.presentedViewController!.view : controller.view))
                }
                @MainActor func tap(_ id: String, modal: Bool = false) throws { try control(id, modal: modal).sendActions(for: .touchUpInside) }
                try tap("navigationMore")
                // More's source popup identifies Settings by its localized action label.
                let settings = try #require(controller.view.subviews.flatMap { allControls($0) }.first { $0.accessibilityLabel == "Settings" })
                settings.sendActions(for: .touchUpInside)
                try tap("prefScreenInterface"); try tap("prefDownloadsButtonAction")
                #expect(downloads.value.buttonActionPlay == true)
                try tap("toolbarBack"); try tap("prefScreenDownloads"); try tap("prefDeleteRemovesFromQueue")
                #expect(downloads.value.deleteRemovesFromQueue)
                #expect(mobile.allowed == ["images", "sync"])
                var intervalChanges = 0
                downloads.onRefreshIntervalChange = { intervalChanges += 1 }
                try tap("prefAutoUpdateIntervall")
                try await wait { controller.presentedViewController?.isBeingPresented == false }
                #expect(try control("prefAutoUpdateIntervall-720", modal: true).accessibilityTraits.contains(.selected))
                try tap("prefAutoUpdateIntervallCancel", modal: true); try await wait { controller.presentedViewController == nil }
                #expect(downloads.value.refreshIntervalMinutes == nil && intervalChanges == 0)
                for interval in PeriodicFeedRefreshSchedule.intervals {
                    try tap("prefAutoUpdateIntervall")
                    try await wait { controller.presentedViewController?.isBeingPresented == false }
                    try tap("prefAutoUpdateIntervall-\(interval)", modal: true)
                    try await wait { controller.presentedViewController == nil }
                    #expect(downloads.value.refreshIntervalMinutes == interval)
                    #expect(try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json")).value.refreshIntervalMinutes == interval)
                }
                #expect(intervalChanges == 8)

                try tap("prefMobileUpdateTypes")
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                let mobileChoices = ["feed_refresh", "episode_download", "auto_download", "streaming", "images", "sync"]
                for key in mobileChoices { _ = try control("prefMobileUpdateTypes-" + key, modal: true) }
                try tap("prefMobileUpdateTypes-streaming", modal: true)
                #expect(!mobile.allows(.streaming))
                try tap("prefMobileUpdateTypesCancel", modal: true); try await wait { controller.presentedViewController == nil }
                #expect(mobile.allowed == ["images", "sync"])
                try tap("prefMobileUpdateTypes")
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                try tap("prefMobileUpdateTypes-streaming", modal: true); try tap("prefMobileUpdateTypes-images", modal: true)
                try tap("prefMobileUpdateTypesConfirm", modal: true); try await wait { controller.presentedViewController == nil }
                #expect(mobile.allowed == ["streaming", "sync"])
                #expect(try MobileNetworkPreferenceStore(file: root.appendingPathComponent("mobile.json")).allowed == mobile.allowed)
                for raw in [3, 2, 1] {
                    try tap("prefNewEpisodesAction")
                    try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                    let choices = allControls(controller.presentedViewController!.view).filter { $0.accessibilityIdentifier?.hasPrefix("prefNewEpisodesAction-") == true }
                    #expect(choices.map(\.accessibilityLabel) == ["Add to inbox", "Add to queue", "Nothing"])
                    try tap("prefNewEpisodesAction-\(raw)", modal: true)
                    try await wait { controller.presentedViewController == nil }
                    #expect(downloads.value.newEpisodesAction?.rawValue == raw)
                    try tap("prefNewEpisodesAction")
                    try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                    #expect(try control("prefNewEpisodesAction-\(raw)", modal: true).accessibilityTraits.contains(.selected))
                    try tap("prefNewEpisodesActionCancel", modal: true)
                    try await wait { controller.presentedViewController == nil }
                    #expect(downloads.value.newEpisodesAction?.rawValue == raw)
                }
                try tap("prefAutoDownloadSettings")
                #expect(automatic.value.cacheSize == 25)
                for key in ["prefEnableAutoDl", "prefEnableAutoDlQueue", "prefEnableAutoDownloadOnBattery"] { try tap(key) }
                #expect(automatic.value.global && automatic.value.queue && !automatic.value.onBattery)
                try tap("prefEpisodeCacheSize")
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                try tap("prefEpisodeCacheSize--1", modal: true)
                try await wait { controller.presentedViewController == nil }
                #expect(automatic.value.cacheSize == -1)
                try tap("toolbarBack"); try tap("prefAutoDeleteScreen")
                #expect(try !control("prefAutoDeleteLocal").isEnabled)
                #expect(try control("prefAutoDeleteLocal").accessibilityTraits.contains(.notEnabled))
                #expect(try !control("prefFavoriteKeepsEpisode").isEnabled)
                try tap("prefAutoDelete"); try tap("prefAutoDeleteLocal")
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                #expect(downloads.value.autoDeleteLocal != true)
                try tap("cancelAutoDeleteLocal", modal: true); try await wait { controller.presentedViewController == nil }
                #expect(downloads.value.autoDeleteLocal != true)
                try tap("prefAutoDeleteLocal")
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                try tap("confirmAutoDeleteLocal", modal: true); try await wait { controller.presentedViewController == nil }
                #expect(downloads.value.autoDeleteLocal == true)
                try tap("prefFavoriteKeepsEpisode"); try tap("prefAutoDelete")
                #expect(downloads.value.favoriteKeepsEpisode == false && downloads.value.autoDelete == false && downloads.value.autoDeleteLocal == true)
                #expect(try !control("prefAutoDeleteLocal").isEnabled) // Retain its saved value while disabled.
                try tap("prefEpisodeCleanup")
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                for value in [-3,-1,0,12,24,72,120,168,-2] { _ = try control("prefEpisodeCleanup-\(value)", modal: true) }
                try tap("prefEpisodeCleanup-12", modal: true); try await wait { controller.presentedViewController == nil }
                #expect(automatic.value.cleanup == 12)
                try tap("toolbarBack"); try tap("toolbarBack"); try tap("prefScreenPlayback"); try tap("prefSmartMarkAsPlayedSecs")
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                try tap("prefSmartMarkAsPlayedSecs-120", modal: true); try await wait { controller.presentedViewController == nil }
                #expect(downloads.value.playbackEnd.smartMarkAsPlayedSeconds == 120)
                #expect(try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json")).value == downloads.value)
                #expect(try AutomaticDownloadPreferenceStore(file: root.appendingPathComponent("automatic.json")).value == automatic.value)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
    @Test func preferenceSwitchStatesAreDistinguishableAndDisabledTextRemainsReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreferencePixels-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = try DownloadPreferenceStore(file: root.appendingPathComponent("download.json"))
        let view = NavigationSettingsView(navigation: nil, timeDisplay: nil, page: .autoDeletion, width: 402, downloads: prefs)
        view.overrideUserInterfaceStyle = .light
        let row: UIControl = try #require(find("prefAutoDeleteLocal", view))
        #expect(row.alpha == 1 && !row.isEnabled)
        let title = try #require(row.subviews.compactMap { $0 as? UILabel }.first)
        #expect(title.alpha == 1 && title.font.fontName == "Roboto-Medium", "Disabled row text stays readable")
        // On/off and enabled/disabled switches must look different from each other.
        func rendering(enabled: Bool, on: Bool) throws -> Data {
            let holder = UIView(frame: CGRect(x: 0, y: 0, width: 52, height: 32)); holder.overrideUserInterfaceStyle = .light
            holder.backgroundColor = Appearance.background
            let control = PreferenceSwitchView(frame: holder.bounds); control.preferenceEnabled = enabled; control.isOn = on; holder.addSubview(control)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: holder.bounds.size, format: format).image { holder.layer.render(in: $0.cgContext) }
            return try #require(image.pngData())
        }
        let states = try [(true, false), (true, true), (false, false), (false, true)].map { try rendering(enabled: $0.0, on: $0.1) }
        #expect(Set(states).count == states.count)
    }
    @Test func sourcePreferenceRowsKeepTextAndSwitchAnchorsAtPhoneWidth() throws {
        let view = NavigationSettingsView(navigation: nil, timeDisplay: nil,
            page: .autoDeletion, width: 1080 / 2.625)
        var heights: [String: CGFloat] = [:]
        for key in ["prefAutoDelete", "prefAutoDeleteLocal", "prefFavoriteKeepsEpisode", "prefEpisodeCleanup"] {
            let row: UIControl = try #require(find(key, view))
            heights[key] = row.bounds.height
            #expect(row.bounds.height >= 48)
            let labels = row.subviews.compactMap { $0 as? UILabel }
            #expect(labels.count == 2)
            // Title above summary, both leading-inset, neither clipped.
            #expect(labels[0].frame.minX > 0 && labels[0].frame.minY > 0)
            #expect(abs(labels[1].frame.minX - labels[0].frame.minX) < 0.5 && labels[1].frame.minY >= labels[0].frame.maxY - 0.5)
            #expect(labels[1].frame.maxY <= row.bounds.height + 0.5)
            if let control = row.subviews.compactMap({ $0 as? PreferenceSwitchView }).first {
                #expect(abs(control.frame.midY - row.bounds.midY) < 1, "Switch is vertically centred")
                #expect(control.frame.maxX < row.bounds.maxX && control.frame.maxX > row.bounds.maxX - 32, "Switch sits at the trailing edge")
                #expect(labels.allSatisfy { $0.frame.maxX <= control.frame.minX + 0.5 }, "Text never runs under the switch")
            }
        }
        // The long three-line summary makes its row taller than a one-line row, as in the source.
        #expect((heights["prefAutoDeleteLocal"] ?? 0) > (heights["prefAutoDelete"] ?? 0))
    }

    @Test(arguments: [false, true]) func mobileDraftRetainsSelectionAndReachableActionsAcrossResize(rtl: Bool) async throws {
        var committed: Set<Int>?
        let controller = SourceSingleChoiceController(title: "Mobile updates", identifier: "mobileResize",
            choices: ["Podcast refresh", "Episode download", "Automatic download", "Streaming", "Cover images", "Synchronization"].enumerated().map { (String($0.offset), $0.element) },
            selectedIndex: nil, selectedIndices: [4,5], onConfirm: { committed = $0 }, onSelect: { _ in Issue.record("Multiple choice must wait for confirmation") })
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            controller.view.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
            controller.view.layoutIfNeeded()
            let stream: UIControl = try #require(find("mobileResize-3", controller.view)); stream.sendActions(for: .touchUpInside)
            #expect(committed == nil)
            for size in [CGSize(width: 250,height: 330), CGSize(width: 720,height: 540)] {
                controller.view.frame.size = size; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                #expect(stream.accessibilityTraits.contains(.selected))
                let list: UIScrollView = try #require(find("mobileResizeChoices", controller.view))
                #expect(list.contentSize.height >= list.bounds.height)
                for key in ["mobileResizeCancel", "mobileResizeConfirm"] {
                    let button: UIButton = try #require(find(key, controller.view))
                    #expect(button.bounds.width > 0 && button.bounds.height > 0 && !button.isHidden)
                }
            }
            let confirm: UIControl = try #require(find("mobileResizeConfirm", controller.view)); confirm.sendActions(for: .touchUpInside)
            #expect(committed == [3,4,5])
        }
    }

    private func allControls(_ view: UIView) -> [UIControl] {
        (view as? UIControl).map { [$0] } ?? view.subviews.flatMap(allControls)
    }
}

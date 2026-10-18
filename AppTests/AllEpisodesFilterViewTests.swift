import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct AllEpisodesFilterViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    @Test(arguments: [false, true])
    func sharedSheetKeepsBothRecipientsIndependentAndPreservesSourcePairs(all: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AllFilterView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feed = try await library.insert(.init(feed: .init(format: .rss, title: "Filter"), source: "https://example.invalid/filter",
            responseURL: URL(string: "https://example.invalid/filter")!, validator: nil, permanentRedirectURL: nil))
        let preferences = try AllEpisodesFilterPreferenceStore(file: root.appendingPathComponent("filter.json"))
        let feedEditor = FeedFilterEditor(feed: feed, store: library)
        var saves = 0
        let dialog = all ? FeedFilterController(allEpisodes: AllEpisodesFilterEditor(store: preferences), onSaved: { saves += 1 })
            : FeedFilterController(editor: feedEditor, onSaved: { _ in saves += 1 })
        try await withViewTestWindow { host, _ in
            host.present(dialog, animated: false); dialog.view.layoutIfNeeded()
            defer { host.dismiss(animated: false) }
            let expected = [["Played", "Not played"], ["Paused", "Not paused"], ["Is favorite", "Not favorite"],
                ["Has media", "No media"], ["Queued", "Not queued"], ["Downloaded", "Not downloaded"]]
            var previous: CGFloat = -1
            for group in FeedFilterGroup.allCases {
                let pair: [UIControl] = try group.values.map { try #require(find("feedFilter_" + $0, in: dialog.view)) }
                #expect(pair[0].frame.minY == pair[1].frame.minY && pair[0].frame.minY > previous)
                previous = pair[0].frame.minY
                for index in 0...1 { #expect(pair[index].accessibilityLabel == expected[group.rawValue][index]) }
            }
            let played: UIControl = try #require(find("feedFilter_played", in: dialog.view)); played.sendActions(for: .touchUpInside)
            await feedEditor.waitForPendingChanges()
            let savedFeed = try #require(try await library.feed(id: feed.id))
            #expect(savedFeed.episodeFilter.values == (all ? [] : ["played"]))
            #expect(preferences.value.stored.values == (all ? ["played"] : []))
            #expect(saves == 1 && played.isSelected)
            let confirm: UIButton = try #require(find("feedFilterConfirm", in: dialog.view)); confirm.sendActions(for: .touchUpInside)
            await feedEditor.waitForPendingChanges()
            #expect(saves == 1)
        }
        try await library.close()
    }
    @Test(arguments: [false, true])
    func actualAllToolbarRetainsFilterAndRowsAcrossDeliveredSceneResize(rtl: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AllFilterResize-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let feed = try await library.insert(.init(feed: .init(format: .rss, title: "Resize", episodes: (1...2).map {
                .init(identifier: "\($0)", title: "Resize episode \($0)")
            }), source: "https://example.invalid/resize", responseURL: URL(string: "https://example.invalid/resize")!, validator: nil, permanentRedirectURL: nil))
            for episode in feed.episodes { try await library.updateEpisode(id: episode.id) { $0.userState.playState = .new } }
            let before = try #require(try await library.feed(id: feed.id))
            let effectsBefore = try await library.pendingEffects()
            let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
            var value = navigation.value; value.defaultPage = NavigationDestination.episodes.rawValue
            try navigation.update(value)
            let preferences = try AllEpisodesFilterPreferenceStore(file: root.appendingPathComponent("filter.json"))
            try preferences.update(.init(values: ["new"]))
            let controller = LibraryViewController(library: library, startupError: nil, downloads: nil, playback: nil,
                timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil, allEpisodesFilterPreferences: preferences)
            @MainActor @Sendable func wait(_ predicate: @MainActor () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(6)
                while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                try #require(predicate())
            }
            try await withViewTestWindow { host, window in
                controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value; window.layoutIfNeeded(); controller.view.layoutIfNeeded()
                let scene = try #require(window.windowScene)
                let scroll: UIScrollView = try #require(find("libraryContent", in: controller.view))
                let originalScene = scene.effectiveGeometry.coordinateSpace.bounds.size, originalContent = scroll.bounds.size
                let originalOrientation = scene.effectiveGeometry.interfaceOrientation
                let restore: UIInterfaceOrientationMask
                switch originalOrientation {
                case .portrait: restore = .portrait
                case .portraitUpsideDown: restore = .portraitUpsideDown
                case .landscapeLeft: restore = .landscapeLeft
                case .landscapeRight: restore = .landscapeRight
                default: throw NSError(domain: "AllEpisodesResizeSetup", code: 1)
                }
                @MainActor func assertComposition() async throws {
                    let search: UIButton = try #require(find("allEpisodesSearch", in: controller.view))
                    let filter: UIButton = try #require(find("allEpisodesFilter", in: controller.view))
                    let more: UIButton = try #require(find("allEpisodesMore", in: controller.view))
                    let rows: [UIButton] = try before.episodes.map { try #require(find("episode-\($0.id)", in: controller.view)) }
                    @MainActor func reachable(_ control: UIButton) -> Bool {
                        let rect = control.convert(control.bounds, to: window)
                        let hit = window.hitTest(CGPoint(x: rect.midX, y: rect.midY), with: nil)
                        return window.bounds.contains(rect) && !control.isHidden && control.isEnabled && (hit === control || hit?.isDescendant(of: control) == true)
                    }
                    try await wait { ([search, filter, more] + rows).allSatisfy(reachable) }
                    #expect(controller.view.effectiveUserInterfaceLayoutDirection == (rtl ? .rightToLeft : .leftToRight))
                    #expect(rtl ? search.frame.midX > filter.frame.midX : search.frame.midX < filter.frame.midX)
                    #expect(rtl ? filter.frame.midX > more.frame.midX : filter.frame.midX < more.frame.midX)
                    #expect(!search.frame.intersects(filter.frame) && !filter.frame.intersects(more.frame))
                    #expect(filter.configuration?.image != nil, "Source All Episodes filter has a visible action icon")
                    let headerBottom = [search, filter, more].map { $0.convert($0.bounds, to: window).maxY }.max()!
                    #expect(rows.allSatisfy { $0.convert($0.bounds, to: window).minY >= headerBottom })
                    let filtered: UILabel = try #require(find("allEpisodesFiltered", in: controller.view))
                    #expect(!filtered.isHidden && preferences.value.stored.values == ["new"])
                    #expect(try await library.feed(id: feed.id) == before)
                    #expect(try await library.queue().isEmpty)
                    #expect(try await library.pendingEffects() == effectsBefore)
                    #expect(try await library.synchronizationQueue().isEmpty)
                }
                try await assertComposition()
                var requestError: String?, failure: (any Error)?
                do {
                    // Request real OS scene geometry; the child follows its actual window.
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: originalOrientation.isPortrait ? .landscapeLeft : .portrait)) { requestError = String(describing: $0) }
                    try await wait { requestError != nil || (scene.effectiveGeometry.coordinateSpace.bounds.size != originalScene && scroll.bounds.size != originalContent) }
                    try #require(requestError == nil || windowingRefusesRotation(requestError), "\(requestError ?? "")")
                    window.layoutIfNeeded(); controller.view.layoutIfNeeded()
                    print("All Episodes scene resize: rtl=\(rtl); sceneBefore=\(originalScene); sceneAfter=\(scene.effectiveGeometry.coordinateSpace.bounds.size); contentBefore=\(originalContent); contentAfter=\(scroll.bounds.size); safeArea=\(controller.view.safeAreaInsets)")
                    try await assertComposition()
                    let filter: UIButton = try #require(find("allEpisodesFilter", in: controller.view)); filter.sendActions(for: .touchUpInside)
                    try await wait { controller.presentedViewController?.isBeingPresented == false }
                    let dialog = try #require(controller.presentedViewController)
                    let confirm: UIButton = try #require(find("feedFilterConfirm", in: dialog.view))
                    #expect(confirm.isEnabled && !confirm.isHidden); confirm.sendActions(for: .touchUpInside)
                    try await wait { controller.presentedViewController == nil }
                    try await assertComposition()
                } catch { failure = error }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: restore)) { print("All Episodes scene restore error: \($0)") }
                try await wait { scene.effectiveGeometry.coordinateSpace.bounds.size == originalScene && scroll.bounds.size == originalContent }
                print("All Episodes scene restored: rtl=\(rtl); scene=\(scene.effectiveGeometry.coordinateSpace.bounds.size); content=\(scroll.bounds.size)")
                try await assertComposition()
                if let failure { throw failure }
            }
            try await library.close()
        } catch { try? await library.close(); throw error }
    }

}

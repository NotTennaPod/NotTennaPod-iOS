import UIKit
import WebKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ShownotesLifetimeViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func player(in view: UIView) -> PlayerView? {
        (view as? PlayerView) ?? view.subviews.lazy.compactMap { player(in: $0) }.first
    }
    private func wait(details: () -> String = { "" }, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Expected shownotes state: \(details())")
    }
    private func fixture(_ body: (FeedLibraryStore, LibraryFeed, PlaybackCoordinator, TimeDisplayPreferenceStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShownotesLifetime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: file)
        do {
            let source = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Podcast", episodes: [
                ParsedEpisode(identifier: "episode", title: "Episode", description: "<p>Selectableword</p>" + (0..<80).map { "<p>Paragraph \($0) retained position and selection.</p>" }.joined(),
                    media: ParsedMedia(url: "https://example.invalid/media", size: 0, durationMilliseconds: 60_000))
            ]), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            _ = try await store.beginPlayback(episodeID: feed.episodes[0].id)
            let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
            try await playback.restore()
            try await body(store, feed, playback, TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json")), file)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }


    @Test func nestedEpisodeNavigationRetainsIndependentReadingPositionsAndReopenStartsFresh() async throws {
        try await fixture { store, feed, _, _, _ in
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
                timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer {
                    controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
                }
                controller.view.frame = host.view.bounds; controller.view.layoutIfNeeded()
                await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
                @MainActor func tap(_ id: String) throws {
                    let button: UIButton = try #require(find(id, in: controller.view))
                    button.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
                }
                @MainActor func notes() throws -> ShownotesWebView { try #require(find("episodeShownotes", in: controller.view)) }
                try tap("episode-\(feed.episodes[0].id)")
                let first = try notes()
                try await wait { !first.isLoading && first.scrollView.contentSize.height > 1600 }
                first.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
                try tap("episodePodcast")
                #expect(find("episodeShownotes", in: controller.view) as ShownotesWebView? == nil)
                try tap("episode-\(feed.episodes[0].id)")
                let nested = try notes()
                try await wait { !nested.isLoading && nested.scrollView.contentSize.height > 1600 }
                #expect(nested.scrollView.contentOffset.y == 0)
                nested.scrollView.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
                try tap("toolbarBack"); try tap("toolbarBack")
                let returned = try notes()
                try await wait { !returned.isLoading && returned.scrollView.contentSize.height > 1600 }
                #expect(returned.scrollView.contentOffset.y == 300)
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                #expect(try notes().scrollView.contentOffset.y == 300)
                controller.additionalSafeAreaInsets = .init(top: 0, left: 19, bottom: 0, right: 47)
                controller.view.frame.size.height -= 80
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                #expect(try notes().scrollView.contentOffset.y == 300)
                try tap("toolbarBack"); try tap("episode-\(feed.episodes[0].id)")
                let reopened = try notes()
                try await wait { !reopened.isLoading && reopened.scrollView.contentSize.height > 1600 }
                #expect(reopened.scrollView.contentOffset.y == 0)
            }
        }
    }

    @Test func sharingSavesPlayerPositionAtSystemHandoffButNotAtLinkMenu() async throws {
        try await fixture { store, feed, playback, time, file in
            let saved = try ShownotesScrollStore(file: file.deletingLastPathComponent().appendingPathComponent("share-scroll.json"))
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: nil, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil, shownotesScroll: saved)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds; controller.view.layoutIfNeeded()
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                let player = try #require(player(in: controller.view))
                player.setExpanded(true, animated: false)
                let notes: ShownotesWebView = try #require(find("playerShownotesContent", in: player))
                let pager = try #require(notes.superview as? UIScrollView)
                try await wait(details: { "notes ready height=\(notes.scrollView.contentSize.height) loading=\(notes.isLoading)" }) { !notes.isLoading && notes.scrollView.contentSize.height > 1600 }
                pager.setContentOffset(CGPoint(x: 0, y: pager.bounds.height), animated: false)
                player.scrollViewDidEndScrollingAnimation(pager)
                try saved.save(episodeID: feed.episodes[0].id, offset: 0)
                notes.scrollView.contentOffset.y = 300
                notes.shareSelection?("First selected text", notes)
                try await wait(details: { "direct share=\(String(describing: controller.presentedViewController))" }) { controller.presentedViewController is UIActivityViewController }
                #expect(saved.offset(for: feed.episodes[0].id) == 300)
                controller.dismiss(animated: false)
                try await wait { controller.presentedViewController == nil }
                notes.scrollView.contentOffset.y = 600
                notes.showLinkMenu?("https://example.invalid/share", notes)
                try await wait(details: { "link menu=\(String(describing: controller.presentedViewController)), host=\(String(describing: host.presentedViewController))" }) { controller.presentedViewController is ShownotesLinkMenuController && controller.presentedViewController?.isBeingPresented == false && controller.presentedViewController?.view.window != nil && controller.presentedViewController?.transitionCoordinator == nil }
                #expect(saved.offset(for: feed.episodes[0].id) == 300)
                let dialog = try #require(controller.presentedViewController)
                let share: UIButton = try #require(find("shownotesLink-share_url_label", in: dialog.view))
                share.sendActions(for: .touchUpInside)
                try await wait(details: { "share=\(String(describing: controller.presentedViewController)), host=\(String(describing: host.presentedViewController))" }) { controller.presentedViewController is UIActivityViewController && controller.presentedViewController?.isBeingPresented == false && controller.presentedViewController?.view.window != nil && controller.presentedViewController?.transitionCoordinator == nil }
                #expect(saved.offset(for: feed.episodes[0].id) == 600)
                controller.dismiss(animated: false)
                try await wait { controller.presentedViewController == nil }
                #expect(notes.scrollView.contentOffset.y == 600)
                notes.scrollView.contentOffset.y = 900
                notes.shareSelection?("Selected text", notes)
                try await wait(details: { "share=\(String(describing: controller.presentedViewController)), host=\(String(describing: host.presentedViewController))" }) { controller.presentedViewController is UIActivityViewController && controller.presentedViewController?.isBeingPresented == false && controller.presentedViewController?.view.window != nil && controller.presentedViewController?.transitionCoordinator == nil }
                #expect(saved.offset(for: feed.episodes[0].id) == 900)
                controller.dismiss(animated: false)
                try await wait { controller.presentedViewController == nil }
                #expect(notes.scrollView.contentOffset.y == 900)
                #expect(!playback.wantsPlayback)
            }
        }
    }

    @Test func explicitPageEntryAndCollapseResetButUpdatesPreserveScroll() async throws {
        try await fixture { store, feed, playback, time, _ in
            try await withViewTestWindow { host, _ in
                let player = PlayerView(playback: playback, timeDisplayPreferences: time, library: store)
                host.view.addSubview(player)
                defer { player.removeFromSuperview() }
                player.frame = host.view.bounds; player.expandedSize = host.view.bounds.size
                player.update(feed: feed); player.setExpanded(true, animated: false); player.layoutIfNeeded()
                let notes: ShownotesWebView = try #require(find("playerShownotesContent", in: player))
                let open: UIButton = try #require(find("playerShownotes", in: player))
                try await wait { !notes.isLoading && notes.scrollView.contentSize.height > 1600 }
                notes.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
                player.update(feed: feed)
                #expect(notes.scrollView.contentOffset.y == 300)
                open.sendActions(for: .touchUpInside)
                #expect(notes.scrollView.contentOffset.y == 0)
                notes.scrollView.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
                player.setExpanded(false, animated: false)
                #expect(notes.scrollView.contentOffset.y == 0)
                player.setExpanded(true, animated: false)
                open.sendActions(for: .touchUpInside)
                let reopened: ShownotesWebView = try #require(find("playerShownotesContent", in: player))
                #expect(reopened.scrollView.contentOffset.y == 0)
                #expect(!playback.wantsPlayback)
            }
        }
    }
    @Test func showNotesUseTheBundledFont() async throws {
        try await withViewTestWindow { host, _ in
            let web = ShownotesWebView()
            host.view.addSubview(web); web.frame = host.view.bounds
            defer { web.removeFromSuperview() }
            let sample = "Hamburgefonstiv quick brown fox"
            web.show(LibraryEpisode(id: 1, details: .init(title: "Font", description: "<p>\(sample)</p>")))
            try await wait { !web.isLoading }
            let state = try await web.callAsyncJavaScript("""
                await document.fonts.ready;
                const range = document.createRange(); range.selectNodeContents(document.querySelector('p').firstChild);
                return [document.fonts.check('16px AntennaPodShownotes') ? 1 : 0, range.getBoundingClientRect().width];
                """, in: nil, contentWorld: .defaultClient) as? [Double]
            let values = try #require(state)
            #expect(values[0] == 1)
            // The text is set in the bundled Roboto, as wide as UIKit draws it in that font.
            let font = try #require(UIFont(name: "Roboto-Regular", size: 16))
            let expected = (sample as NSString).size(withAttributes: [.font: font]).width
            #expect(abs(values[1] - expected) < 1, "text width \(values[1]) vs Roboto \(expected)")
        }
    }

    @Test func collapsedPlayerBuildsNoShowNotesUntilItOpens() async throws {
        try await fixture { store, feed, playback, time, _ in
            try await withViewTestWindow { host, _ in
                let player = PlayerView(playback: playback, timeDisplayPreferences: time, library: store)
                host.view.addSubview(player)
                defer { player.removeFromSuperview() }
                player.frame = host.view.bounds; player.expandedSize = host.view.bounds.size
                player.update(feed: feed); player.layoutIfNeeded()
                #expect(find("playerShownotesContent", in: player) as ShownotesWebView? == nil)
                // A position tick with nothing else changed updates only the position.
                let updates = player.fullUpdates
                player.update(feed: feed); player.update(feed: feed)
                #expect(player.fullUpdates == updates)
                player.setExpanded(true, animated: false); player.layoutIfNeeded()
                let notes: ShownotesWebView = try #require(find("playerShownotesContent", in: player))
                try await wait { !notes.isLoading && notes.scrollView.contentSize.height > 1600 }
                // Collapsed again, the player keeps no WebKit process for iOS to reclaim.
                player.setExpanded(false, animated: false)
                player.update(feed: feed)
                #expect(find("playerShownotesContent", in: player) as ShownotesWebView? == nil)
                #expect(notes.superview == nil)
                // Opening builds them again, at their top as after every collapse.
                player.setExpanded(true, animated: false); player.layoutIfNeeded()
                let reopened: ShownotesWebView = try #require(find("playerShownotesContent", in: player))
                #expect(reopened !== notes)
                try await wait { reopened.isDocumentReady && !reopened.isLoading && reopened.scrollView.contentSize.height > 1600 }
                #expect(reopened.scrollView.contentOffset.y == 0)
                // An animated collapse releases them when it ends.
                player.setExpanded(false, animated: true)
                try await wait { (find("playerShownotesContent", in: player) as ShownotesWebView?) == nil }
            }
        }
    }

    @Test func appearanceSnapshotsPreserveDocumentScrollAndSelection() async throws {
        try await withViewTestWindow { host, _ in
            let web = ShownotesWebView()
            host.view.addSubview(web); web.frame = host.view.bounds
            defer { web.removeFromSuperview() }
            web.overrideUserInterfaceStyle = .light
            web.show(LibraryEpisode(id: 1, details: .init(title: "Appearance", description:
                "<p>Selectableword</p><a href='https://example.invalid'>Link</a>" + (0..<80).map { "<p>Paragraph \($0)</p>" }.joined())))
            try await wait { !web.isLoading && web.scrollView.contentSize.height > 1600 }
            _ = try await web.callAsyncJavaScript("""
                globalThis.apLifetimeToken = 'retained';
                const range = document.createRange(); range.selectNodeContents(document.querySelector('p'));
                getSelection().removeAllRanges(); getSelection().addRange(range);
                """, in: nil, contentWorld: .defaultClient)
            // Wait for WebKit's selection rendering before establishing the scroll baseline.
            _ = try await web.callAsyncJavaScript("await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));", in: nil, contentWorld: .defaultClient)
            web.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
            _ = try await web.callAsyncJavaScript("await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));", in: nil, contentWorld: .defaultClient)
            try #require(web.scrollView.contentOffset.y == 300, "Scrolled selection must be established before appearance changes")
            for (style, foreground, accent) in [(UIUserInterfaceStyle.dark, "rgb(255, 255, 255)", "rgb(61, 139, 255)"), (.light, "rgb(0, 0, 0)", "rgb(0, 120, 194)")] {
                web.overrideUserInterfaceStyle = style
                let deadline = ContinuousClock.now + .seconds(5)
                var actual = ""
                repeat {
                    actual = try await web.callAsyncJavaScript("return getComputedStyle(document.querySelector('p')).color;", in: nil, contentWorld: .defaultClient) as? String ?? ""
                    if actual != foreground { try await Task.sleep(for: .milliseconds(10)) }
                } while actual != foreground && ContinuousClock.now < deadline
                #expect(actual == foreground)
                let link = try await web.callAsyncJavaScript("return getComputedStyle(document.querySelector('a')).color;", in: nil, contentWorld: .defaultClient) as? String
                #expect(link == accent)
                #expect(web.scrollView.contentOffset.y == 300)
                let state = try await web.callAsyncJavaScript("return [globalThis.apLifetimeToken, getSelection().toString()];", in: nil, contentWorld: .defaultClient) as? [String]
                #expect(state == ["retained", "Selectableword"])
                #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
            }
            web.scrollToTopForPageNavigation()
            let retirementDeadline = ContinuousClock.now + .seconds(5)
            var selection: String?
            repeat {
                selection = try await web.callAsyncJavaScript("return getSelection().toString();", in: nil, contentWorld: .defaultClient) as? String
                if selection != "" { try await Task.sleep(for: .milliseconds(10)) }
            } while selection != "" && ContinuousClock.now < retirementDeadline
            #expect(selection == "")
            #expect(web.scrollView.contentOffset.y == 0)
        }
    }

    @Test func equivalentFormattedContentPreservesScrollAndRangeButNewTimecodeReloads() async throws {
        try await withViewTestWindow { host, _ in
            let web = ShownotesWebView()
            host.view.addSubview(web); web.frame = host.view.bounds
            defer { web.removeFromSuperview() }
            web.overrideUserInterfaceStyle = .light
            var episode = LibraryEpisode(id: 1, details: .init(title: "Content", description:
                "<p>Selectableword</p>" + (0..<80).map { "<p>Paragraph \($0)</p>" }.joined() + "<p>Timestamp 02:00</p>",
                media: .init(url: "https://example.invalid/media", size: 0, durationMilliseconds: 30_000)))
            web.show(episode)
            try await wait { !web.isLoading && web.scrollView.contentSize.height > 1600 }
            _ = try await web.callAsyncJavaScript("""
                globalThis.apContentToken = 'retained';
                const range = document.createRange(); range.selectNodeContents(document.querySelector('p'));
                getSelection().removeAllRanges(); getSelection().addRange(range);
                await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                """, in: nil, contentWorld: .defaultClient)
            web.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
            _ = try await web.callAsyncJavaScript("await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));", in: nil, contentWorld: .defaultClient)
            try #require(web.scrollView.contentOffset.y == 300)
            // Include a resolved-appearance change: owned colors must not become
            // a reason to replace otherwise identical notes on the next update.
            web.overrideUserInterfaceStyle = .dark
            for duration: Int32 in [60_000, 90_000] {
                episode.details.media?.durationMilliseconds = duration
                web.show(episode)
                try await wait { !web.isLoading }
                let state = try await web.callAsyncJavaScript("return [globalThis.apContentToken || '', getSelection().toString()];", in: nil, contentWorld: .defaultClient) as? [String]
                #expect(state == ["retained", "Selectableword"])
                #expect(web.scrollView.contentOffset.y == 300)
                let count = try await web.callAsyncJavaScript("return document.querySelectorAll('a.timecode').length;", in: nil, contentWorld: .defaultClient) as? Int
                #expect(count == 0)
            }
            episode.details.media?.durationMilliseconds = 180_000
            web.show(episode)
            try await wait { !web.isLoading }
            let state = try await web.callAsyncJavaScript("return [globalThis.apContentToken || '', getSelection().toString(), document.querySelector('a.timecode')?.getAttribute('href') || ''];", in: nil, contentWorld: .defaultClient) as? [String]
            #expect(state == ["", "", "antennapod://timecode/120000"])
            #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        }
    }

    @Test func savedOffsetIsSinglePersistentRecordAndSurvivesUnmatchedMedia() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShownotesScroll-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scroll.json")
        let store = try ShownotesScrollStore(file: file)
        #expect(store.offset(for: 1) == nil)
        try store.save(episodeID: 1, offset: 300)
        let reopened = try ShownotesScrollStore(file: file)
        #expect(reopened.offset(for: 1) == 300)
        #expect(reopened.offset(for: 2) == nil)
        try reopened.save(episodeID: 2, offset: 0)
        let replaced = try ShownotesScrollStore(file: file)
        #expect(replaced.offset(for: 1) == nil)
        #expect(replaced.offset(for: 2) == 0)
        try replaced.save(episodeID: 2, offset: -20)
        #expect(replaced.offset(for: 2) == 0)
    }

    @Test func reloadRestoresSavedOffsetWithoutReplacingItWithDisplayedOrClampedOffset() async throws {
        try await withViewTestWindow { host, _ in
            let web = ShownotesWebView(), saved = ShownotesScrollStore()
            var currentID: Int64 = 1
            var restorationGeometry: [String] = []
            web.restoreScrollOffset = { [weak web] in
                restorationGeometry.append("\(web?.scrollView.contentSize.height ?? -1)/\(web?.scrollView.bounds.height ?? -1) target=\(saved.offset(for: currentID) ?? 0)")
                return CGFloat(saved.offset(for: currentID) ?? 0)
            }
            host.view.addSubview(web); web.frame = host.view.bounds
            defer { web.removeFromSuperview() }
            let html = "<p>Selectableword</p>" + (0..<80).map { "<p>Paragraph \($0)</p>" }.joined()
            var first = LibraryEpisode(id: 1, details: .init(title: "First", description: html))
            web.show(first)
            try await wait(details: { "stage 1 offset=\(web.scrollView.contentOffset.y) content=\(web.scrollView.contentSize.height) viewport=\(web.scrollView.bounds.height) loading=\(web.isLoading) restorations=\(restorationGeometry)" }) { !web.isLoading && web.scrollView.contentSize.height > 1600 }
            try saved.save(episodeID: 1, offset: 300)
            web.scrollView.contentOffset.y = 600
            first.details.description = html + "<p>Revision one</p>"
            web.show(first)
            try await wait(details: { "stage 2 offset=\(web.scrollView.contentOffset.y) content=\(web.scrollView.contentSize.height) viewport=\(web.scrollView.bounds.height) loading=\(web.isLoading) restorations=\(restorationGeometry)" }) { !web.isLoading && web.scrollView.contentOffset.y == 300 }
            web.scrollView.contentOffset.y = 600
            currentID = 2
            var second = LibraryEpisode(id: 2, details: first.details)
            web.show(second)
            #expect(web.scrollView.contentOffset.y == 600)
            #expect(saved.offset(for: 1) == 300)
            #expect(saved.offset(for: 2) == nil)
            second.details.description = html + "<p>Different media content</p>"
            web.show(second)
            try await wait(details: { "stage 3 offset=\(web.scrollView.contentOffset.y) content=\(web.scrollView.contentSize.height) viewport=\(web.scrollView.bounds.height) loading=\(web.isLoading) restorations=\(restorationGeometry)" }) { !web.isLoading && web.scrollView.contentOffset.y == 0 }
            currentID = 1
            web.show(first)
            try await wait(details: { "stage 4 offset=\(web.scrollView.contentOffset.y) content=\(web.scrollView.contentSize.height) viewport=\(web.scrollView.bounds.height) loading=\(web.isLoading) restorations=\(restorationGeometry)" }) { !web.isLoading && web.scrollView.contentOffset.y == 300 }
            first.details.description = "<p>Shortened notes</p>"
            web.show(first)
            try await wait(details: { "stage 5 offset=\(web.scrollView.contentOffset.y) content=\(web.scrollView.contentSize.height) viewport=\(web.scrollView.bounds.height) loading=\(web.isLoading) restorations=\(restorationGeometry)" }) { !web.isLoading && web.scrollView.contentOffset.y == 0 }
            #expect(saved.offset(for: 1) == 300)
            first.details.description = html
            web.show(first)
            try await wait(details: { "stage 6 offset=\(web.scrollView.contentOffset.y) content=\(web.scrollView.contentSize.height) viewport=\(web.scrollView.bounds.height) loading=\(web.isLoading) restorations=\(restorationGeometry)" }) { !web.isLoading && web.scrollView.contentOffset.y == 300 }
        }
    }


    @Test func playerPageAndScenePauseSaveButExplicitNavigationReplacesSavedOffset() async throws {
        try await fixture { store, feed, playback, time, file in
            let saved = try ShownotesScrollStore(file: file.deletingLastPathComponent().appendingPathComponent("scroll.json"))
            try await withViewTestWindow { host, window in
                let player = PlayerView(playback: playback, timeDisplayPreferences: time, library: store, shownotesScroll: saved)
                host.view.addSubview(player)
                defer { player.removeFromSuperview() }
                player.frame = host.view.bounds; player.expandedSize = host.view.bounds.size
                player.update(feed: feed); player.setExpanded(true, animated: false); player.layoutIfNeeded()
                let notes: ShownotesWebView = try #require(find("playerShownotesContent", in: player))
                let pager = try #require(notes.superview as? UIScrollView)
                let id = feed.episodes[0].id
                try await wait { !notes.isLoading && notes.scrollView.contentSize.height > 1600 }
                pager.setContentOffset(CGPoint(x: 0, y: pager.bounds.height), animated: false)
                player.scrollViewDidEndScrollingAnimation(pager)
                notes.scrollView.contentOffset.y = 300
                // Component dispatch verifies the scene-scoped binding; actual
                // Settings switching is covered by the separate app journey.
                NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: window.windowScene)
                #expect(saved.offset(for: id) == 300)
                notes.scrollView.contentOffset.y = 450
                notes.willPerformTextService?()
                #expect(saved.offset(for: id) == 450)
                notes.scrollView.contentOffset.y = 600
                pager.setContentOffset(.zero, animated: false)
                player.scrollViewDidEndScrollingAnimation(pager)
                #expect(saved.offset(for: id) == 600)
                notes.scrollView.contentOffset.y = 100
                notes.willPerformTextService?()
                #expect(saved.offset(for: id) == 600)
                NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: window.windowScene)
                #expect(saved.offset(for: id) == 600)
                let open: UIButton = try #require(find("playerShownotes", in: player))
                open.sendActions(for: .touchUpInside)
                #expect(saved.offset(for: id) == 0)
                notes.scrollView.contentOffset.y = 300
                player.setExpanded(false, animated: false)
                #expect(saved.offset(for: id) == 0)
                #expect(!playback.wantsPlayback)
            }
        }
    }

}

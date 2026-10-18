import UIKit
import WebKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// iOS ends WebKit's content process when it reclaims memory, mostly while the app is in the background. The notes
/// come back on their own, in the current colours and at the position they were read at, and never raise an alert.
/// The process is ended with WebKit's private diagnostic, from this test target only.
@MainActor @Suite(.serialized)
struct ShownotesRecoveryViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func player(in view: UIView) -> PlayerView? {
        (view as? PlayerView) ?? view.subviews.lazy.compactMap { player(in: $0) }.first
    }
    private func wait(_ message: String = "", sourceLocation: SourceLocation = #_sourceLocation,
                      _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), "\(message)", sourceLocation: sourceLocation)
    }

    private func episode(_ id: Int64 = 1, marker: String = "Recoverable") -> LibraryEpisode {
        LibraryEpisode(id: id, details: .init(title: "Recovery \(id)", description:
            "<p>\(marker)</p><p><a href='https://example.invalid/link'>Link</a></p>"
            + (0..<100).map { "<p>\(marker) paragraph \($0) retained reading state.</p>" }.joined(),
            media: .init(url: "https://example.invalid/media/\(id)", size: 0, durationMilliseconds: 30_000)))
    }

    private struct Document: Equatable { let id, text, colour, link: String }
    private func document(_ web: ShownotesWebView) async throws -> Document {
        let values = try #require(try await web.callAsyncJavaScript("""
            return [globalThis.apShownotesDocument || '', document.querySelector('p')?.textContent || '',
                getComputedStyle(document.querySelector('p')).color, getComputedStyle(document.querySelector('a')).color];
            """, in: nil, contentWorld: .defaultClient) as? [String])
        return Document(id: values[0], text: values[1], colour: values[2], link: values[3])
    }
    /// Several main-queue turns pass, so the reading position of the last scroll is recorded.
    private func settleFrames(_ web: ShownotesWebView) async throws {
        _ = try await web.callAsyncJavaScript("""
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            """, in: nil, contentWorld: .defaultClient)
    }
    private func ready(_ web: ShownotesWebView, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await wait(message, sourceLocation: sourceLocation) {
            web.isDocumentReady && !web.isLoading && web.scrollView.contentSize.height > 2000
        }
    }
    private func end(_ web: ShownotesWebView, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let count = web.processTerminations
        try web.killWebContentProcess()
        try await wait("WebKit reports the ended process", sourceLocation: sourceLocation) { web.processTerminations == count + 1 }
    }
    private func selectVisibleParagraph(_ web: ShownotesWebView, window: UIWindow, toolbar: Bool = true) async throws -> String {
        let text = try #require(try await web.callAsyncJavaScript("""
            const paragraph = Array.from(document.querySelectorAll('p')).find(p => {
                const bounds = p.getBoundingClientRect();
                return p.textContent.includes('paragraph') && bounds.top >= 0 && bounds.bottom < innerHeight;
            });
            if (!paragraph) throw new Error('No visible paragraph');
            const range = document.createRange(); range.selectNodeContents(paragraph);
            getSelection().removeAllRanges(); getSelection().addRange(range);
            return getSelection().toString();
            """, in: nil, contentWorld: .defaultClient) as? String)
        try #require(!text.isEmpty)
        if toolbar { try await wait("selection toolbar") { (find("shownotesSelection-share", in: window) as UIButton?) != nil } }
        return text
    }

    @Test func endedProcessRebuildsTheNotesInTheirColoursAndPositionWithoutAlert() async throws {
        try await withViewTestWindow { host, _ in
            let web = ShownotesWebView()
            var failures: [Error] = []
            web.failure = { failures.append($0) }
            host.view.addSubview(web); web.frame = host.view.bounds
            defer { web.removeFromSuperview() }
            web.overrideUserInterfaceStyle = .dark
            web.show(episode())
            try await ready(web, "first document")
            let original = try await document(web)
            web.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
            try await settleFrames(web)

            try await end(web)
            try await ready(web, "notes rebuilt while shown")
            let rebuilt = try await document(web)
            #expect(rebuilt.id != original.id, "a new document, not WebKit's blank reload")
            #expect(rebuilt == Document(id: rebuilt.id, text: "Recoverable", colour: "rgb(255, 255, 255)", link: "rgb(61, 139, 255)"))
            #expect(web.scrollView.contentOffset.y == 300)
            // Housekeeping works in the rebuilt document, without replacing it.
            web.overrideUserInterfaceStyle = .light
            try await wait("recoloured") { (try? await document(web)) == Document(id: rebuilt.id, text: "Recoverable", colour: "rgb(0, 0, 0)", link: "rgb(0, 120, 194)") }
            #expect(web.scrollView.contentOffset.y == 300)
            #expect(failures.isEmpty, "\(failures)")
            #expect(host.presentedViewController == nil)
        }
    }

    @Test func repeatedEndsStopAtTheBudgetWithANotesLevelRetryAndANewVisitTriesAgain() async throws {
        try await withViewTestWindow { host, _ in
            let web = ShownotesWebView()
            var failures: [Error] = []
            web.failure = { failures.append($0) }
            host.view.addSubview(web); web.frame = host.view.bounds
            defer { web.removeFromSuperview() }
            web.show(episode())
            try await ready(web, "first document")
            web.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
            try await settleFrames(web)
            // Each rebuild finishes and its process ends right afterwards: finishing does not refill the budget.
            for round in 1...ShownotesWebView.recoveryLimit {
                try await end(web)
                try await ready(web, "rebuild \(round)")
                #expect(web.scrollView.contentOffset.y == 300)
            }
            try await end(web)
            #expect(web.showsUnavailableState && !web.isAwaitingLoad && !web.isLoading, "no further automatic rebuild")
            let message: UILabel = try #require(find("shownotesUnavailable", in: web))
            let retry: UIButton = try #require(find("shownotesRetry", in: web))
            #expect(message.text == "The shownotes could not be displayed." && message.isAccessibilityElement)
            #expect(retry.accessibilityLabel == "Retry" && retry.accessibilityTraits.contains(.button))
            #expect(web.scrollView.accessibilityElementsHidden, "VoiceOver reads the state, not the blank document")
            #expect(message.frame.minY >= 0 && retry.frame.maxY <= max(web.bounds.height, (message.superview as? UIScrollView)?.contentSize.height ?? 0))
            #expect(failures.isEmpty, "\(failures)")
            #expect(host.presentedViewController == nil)

            retry.sendActions(for: .touchUpInside)
            try await ready(web, "Retry rebuilds")
            #expect(!web.showsUnavailableState && !web.scrollView.accessibilityElementsHidden)
            #expect(try await document(web).text == "Recoverable")
            #expect(web.scrollView.contentOffset.y == 300)

            // Exhausted again, then a new visit: the notes leave the screen and are shown again.
            var ends = 0
            while !web.showsUnavailableState, ends <= ShownotesWebView.recoveryLimit {
                try await end(web); ends += 1
                if !web.showsUnavailableState { try await ready(web, "rebuild after Retry") }
            }
            try #require(web.showsUnavailableState)
            web.frame.origin.x = host.view.bounds.width; web.visibilityMayHaveChanged()
            #expect(web.showsUnavailableState, "nothing is loaded while not shown")
            web.frame.origin.x = 0; web.visibilityMayHaveChanged()
            try await ready(web, "a new visit rebuilds")
            #expect(!web.showsUnavailableState)
            #expect(web.scrollView.contentOffset.y == 300)
            #expect(failures.isEmpty, "\(failures)")
        }
    }

    @Test func hiddenNotesWaitForTheirVisitThroughAppearanceChangesAndPageNavigation() async throws {
        try await withViewTestWindow { host, _ in
            // Like a pager neighbour: in the window, clipped out of sight.
            let clip = UIView(frame: host.view.bounds); clip.clipsToBounds = true
            host.view.addSubview(clip)
            defer { clip.removeFromSuperview() }
            let web = ShownotesWebView()
            var failures: [Error] = [], shared: String?
            web.failure = { failures.append($0) }
            web.shareSelection = { text, _ in shared = text }
            clip.addSubview(web); web.frame = clip.bounds
            web.overrideUserInterfaceStyle = .light
            web.show(episode())
            try await ready(web, "first document")
            web.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
            try await settleFrames(web)
            web.frame.origin.x = clip.bounds.width
            #expect(!web.isShownInActiveScene)

            try await end(web)
            #expect(web.isAwaitingLoad && !web.isLoading, "not rebuilt while nobody can see it")
            // Background snapshots flip the appearance; none of it may reach a person as an error.
            for style in [UIUserInterfaceStyle.dark, .light, .dark] {
                web.overrideUserInterfaceStyle = style
                web.layoutIfNeeded()
            }
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: host.view.window?.windowScene)
            #expect(web.isAwaitingLoad)
            #expect(failures.isEmpty, "\(failures)")
            // An explicit Share of a selection that ended with its process says so plainly.
            await web.performSelectionAction(.share)
            #expect(shared == nil)
            #expect(failures.map(\.localizedDescription) == ["The selected text is no longer available."])
            failures.removeAll()

            web.frame.origin.x = 0; web.visibilityMayHaveChanged()
            try await ready(web, "rebuilt on its visit")
            let rebuilt = try await document(web)
            #expect(rebuilt.text == "Recoverable" && rebuilt.colour == "rgb(255, 255, 255)" && rebuilt.link == "rgb(61, 139, 255)")
            #expect(web.scrollView.contentOffset.y == 300)

            // Page navigation while a rebuild waits still opens the notes at their top.
            web.frame.origin.x = clip.bounds.width
            try await end(web)
            web.scrollToTopForPageNavigation()
            web.frame.origin.x = 0; web.visibilityMayHaveChanged()
            try await ready(web, "rebuilt after page navigation")
            #expect(web.scrollView.contentOffset.y == 0)
            #expect(failures.isEmpty, "\(failures)")
        }
    }

    @Test func replacedEpisodeWhileARebuildWaitsShowsTheNewNotesAtTheirOwnPosition() async throws {
        try await withViewTestWindow { host, _ in
            let clip = UIView(frame: host.view.bounds); clip.clipsToBounds = true
            host.view.addSubview(clip)
            defer { clip.removeFromSuperview() }
            let web = ShownotesWebView()
            var failures: [Error] = [], currentID: Int64 = 1
            web.failure = { failures.append($0) }
            web.restoreScrollOffset = { currentID == 2 ? 450 : 0 }
            clip.addSubview(web); web.frame = clip.bounds
            web.show(episode(1, marker: "FirstEpisode"))
            try await ready(web, "first episode")
            web.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
            try await settleFrames(web)
            web.frame.origin.x = clip.bounds.width
            try await end(web)
            #expect(web.isAwaitingLoad)

            currentID = 2
            web.show(episode(2, marker: "SecondEpisode"))
            #expect(web.isAwaitingLoad && !web.isLoading, "the new notes also wait until they can be seen")
            web.frame.origin.x = 0; web.visibilityMayHaveChanged()
            try await ready(web, "second episode")
            #expect(try await document(web).text == "SecondEpisode")
            #expect(web.scrollView.contentOffset.y == 450, "the second episode's own position, not the first one's")
            #expect(failures.isEmpty, "\(failures)")
        }
    }

    @Test func shareAndWebSearchWorkAfterARebuild() async throws {
        try await withViewTestWindow { host, window in
            let web = ShownotesWebView()
            var failures: [Error] = [], shared: String?, opened: String?
            web.failure = { failures.append($0) }
            web.shareSelection = { text, _ in shared = text }
            web.openLink = { opened = $0 }
            host.view.addSubview(web); web.frame = host.view.bounds
            defer { web.removeFromSuperview() }
            web.show(episode())
            try await ready(web, "first document")
            _ = try await selectVisibleParagraph(web, window: window)
            try await end(web)
            #expect((find("shownotesSelection-share", in: window) as UIButton?) == nil, "the old selection's toolbar is gone")
            try await ready(web, "rebuilt")

            let selected = try await selectVisibleParagraph(web, window: window)
            let share: UIButton = try #require(find("shownotesSelection-share", in: window))
            share.sendActions(for: .touchUpInside)
            try await wait("shared") { shared != nil }
            #expect(shared == selected)
            // A handled toolbar action retires the toolbar until the next touch; the range itself still works.
            let searched = try await selectVisibleParagraph(web, window: window, toolbar: false)
            await web.performSelectionAction(.webSearch)
            #expect(opened == ShownotesWebView.webSearchURL(for: searched).absoluteString)
            #expect(failures.isEmpty, "\(failures)")
        }
    }

    @Test func playerNotesComeBackOnTheNotesPageWithoutAlert() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShownotesRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let source = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Podcast", episodes: [
                ParsedEpisode(identifier: "episode", title: "Episode", description: episode().details.description,
                    media: ParsedMedia(url: "https://example.invalid/media", size: 0, durationMilliseconds: 60_000))
            ]), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            _ = try await store.beginPlayback(episodeID: feed.episodes[0].id)
            let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
            try await playback.restore()
            let saved = ShownotesScrollStore()
            let time = try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json"))
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time,
                navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil, shownotesScroll: saved)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds; controller.view.layoutIfNeeded()
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                let player = try #require(player(in: controller.view))
                player.setExpanded(true, animated: false); player.layoutIfNeeded()
                let notes: ShownotesWebView = try #require(find("playerShownotesContent", in: player))
                let pager = try #require(notes.superview as? UIScrollView)
                try await ready(notes, "player notes")
                #expect(!notes.isShownInActiveScene, "behind the cover page")
                pager.setContentOffset(CGPoint(x: 0, y: pager.bounds.height), animated: false)
                player.scrollViewDidEndScrollingAnimation(pager)
                #expect(notes.isShownInActiveScene)
                notes.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
                try await settleFrames(notes)

                try await end(notes)
                try await ready(notes, "player notes rebuilt")
                #expect(notes.scrollView.contentOffset.y == 300)
                #expect(try await document(notes).text == "Recoverable")
                // Ended behind the cover page: rebuilt when the page turn shows them.
                pager.setContentOffset(.zero, animated: false)
                player.scrollViewDidEndScrollingAnimation(pager)
                try await end(notes)
                #expect(notes.isAwaitingLoad)
                pager.setContentOffset(CGPoint(x: 0, y: pager.bounds.height), animated: false)
                try await ready(notes, "rebuilt on the notes page")
                #expect(notes.scrollView.contentOffset.y == 300)
                #expect(controller.presentedViewController == nil, "no alert: \(String(describing: controller.presentedViewController))")
                #expect(!playback.wantsPlayback)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    /// A duration change that formats to the same notes keeps their document, so it also keeps their reading
    /// position for a rebuild: waiting, or under way before its rendered readiness.
    @Test func equivalentUpdatesKeepTheReadingPositionForARebuild() async throws {
        try await withViewTestWindow { host, _ in
            let clip = UIView(frame: host.view.bounds); clip.clipsToBounds = true
            host.view.addSubview(clip)
            defer { clip.removeFromSuperview() }
            let web = ShownotesWebView()
            var failures: [Error] = []
            web.failure = { failures.append($0) }
            // The owner's saved position differs from the reading position, so falling back to it is visible.
            web.restoreScrollOffset = { 50 }
            clip.addSubview(web); web.frame = clip.bounds
            // The 02:00 timestamp becomes a link only for media longer than two minutes.
            @MainActor func notes(_ duration: Int32) -> LibraryEpisode {
                var notes = episode()
                notes.details.description = (notes.details.description ?? "") + "<p>Timestamp 02:00</p>"
                notes.details.media?.durationMilliseconds = duration
                return notes
            }
            web.show(notes(30_000))
            try await ready(web, "first document")
            #expect(web.scrollView.contentOffset.y == 50)
            web.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
            try await settleFrames(web)
            let retained = try await document(web).id
            web.show(notes(60_000))
            #expect(!web.isLoading)
            #expect(try await document(web).id == retained, "equivalent notes keep their document")

            // Shown: the process ends without another scroll after the equivalent update.
            try await end(web)
            try await ready(web, "rebuilt")
            #expect(web.scrollView.contentOffset.y == 300)

            // Hidden: an equivalent update while the rebuild waits, and another while it is under way.
            web.frame.origin.x = clip.bounds.width
            try await end(web)
            web.show(notes(90_000))
            #expect(web.isAwaitingLoad && !web.isLoading)
            web.frame.origin.x = 0; web.visibilityMayHaveChanged()
            #expect(!web.isAwaitingLoad && !web.isDocumentReady, "the rebuild is under way")
            web.show(notes(45_000))
            try await ready(web, "rebuilt after equivalent updates")
            #expect(web.scrollView.contentOffset.y == 300)
            #expect(try await document(web).text == "Recoverable")
            // Notes that really change still take the owner's position.
            web.show(notes(180_000))
            try await wait("new notes") {
                guard web.isDocumentReady else { return false }
                return (try? await document(web).id) != retained
            }
            try await wait("owner's position") { web.scrollView.contentOffset.y == 50 }
            #expect(failures.isEmpty, "\(failures)")
        }
    }

    /// Recolouring and clearing a range fail inside WebKit (here through the production
    /// evaluator, with WebKit's own "unsupported type" error). Nothing reaches a person; both changes are applied at the
    /// next scene activation, in the same document at the same position.
    @Test func failedHousekeepingNeverAlertsAndIsAppliedAtTheNextActivation() async throws {
        try await withViewTestWindow { host, window in
            let web = ShownotesWebView()
            var failures: [Error] = []
            web.failure = { failures.append($0) }
            host.view.addSubview(web); web.frame = host.view.bounds
            defer { web.removeFromSuperview() }
            web.overrideUserInterfaceStyle = .light
            web.show(episode())
            try await ready(web, "first document")
            web.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
            try await settleFrames(web)
            let selected = try await selectVisibleParagraph(web, window: window, toolbar: false)
            let original = try await document(web)
            let faults = Box<[ShownotesWebView.Script]>([])
            web.evaluateScriptForTesting = { web, script, body, arguments in
                guard script != .readSelection else { return try await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient) }
                faults.value.append(script)
                if faults.value.count.isMultiple(of: 2) { throw NSError(domain: WKError.errorDomain, code: WKError.javaScriptExceptionOccurred.rawValue) }
                throw WKError(.javaScriptResultTypeIsUnsupported)
            }

            web.overrideUserInterfaceStyle = .dark
            web.layoutIfNeeded()
            try await wait("recolouring failed") { faults.value.contains(.appearance) }
            try await settleFrames(web)
            #expect(web.isAppearancePending)
            #expect(try await document(web) == original, "still the light colours of the same document")
            #expect(web.scrollView.contentOffset.y == 300)
            // The selection range is cleared for page navigation, which also returns to the top.
            web.scrollToTopForPageNavigation()
            try await wait("clearing failed") { faults.value.contains(.clearSelection) }
            try await settleFrames(web)
            #expect(web.isSelectionClearPending)
            let range = try await web.callAsyncJavaScript("return getSelection().toString();", in: nil, contentWorld: .defaultClient) as? String
            #expect(range == selected)
            // Another activation while still failing changes nothing and still shows nothing.
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: window.windowScene)
            try await wait("replayed into the fault") { faults.value.count >= 4 }
            try await settleFrames(web)
            #expect(failures.isEmpty, "\(failures)")
            #expect(host.presentedViewController == nil)

            web.evaluateScriptForTesting = nil
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: window.windowScene)
            try await wait("applied at the next activation") { !web.isAppearancePending && !web.isSelectionClearPending }
            let applied = try await document(web)
            #expect(applied == Document(id: original.id, text: original.text, colour: "rgb(255, 255, 255)", link: "rgb(61, 139, 255)"))
            let cleared = try await web.callAsyncJavaScript("return getSelection().toString();", in: nil, contentWorld: .defaultClient) as? String
            #expect(cleared == "")
            #expect(web.scrollView.contentOffset.y == 0, "page navigation's top, not a reload")
            #expect(!web.isLoading && web.processTerminations == 0)
            #expect(failures.isEmpty, "\(failures)")
        }
    }

    /// A Share or Web search whose selection read is still outstanding when the notes are rebuilt says the selection
    /// is gone; one for notes another episode replaced, or that left the screen, ends silently.
    @Test func selectionActionsRacingARebuildOrAReplacement() async throws {
        try await withViewTestWindow { host, _ in
            let web = ShownotesWebView()
            var failures: [Error] = [], shared: String?, opened: String?
            web.failure = { failures.append($0) }
            web.shareSelection = { text, _ in shared = text }
            web.openLink = { opened = $0 }
            host.view.addSubview(web); web.frame = host.view.bounds
            defer { web.removeFromSuperview() }
            web.show(episode())
            try await ready(web, "first document")
            let outstanding = Box<CheckedContinuation<Any?, Error>?>(nil)
            web.evaluateScriptForTesting = { web, script, body, arguments in
                guard script == .readSelection else { return try await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient) }
                return try await withCheckedThrowingContinuation { outstanding.value = $0 }
            }
            @MainActor func act(_ action: ShownotesWebView.SelectionAction, result: String, during change: () async throws -> Void) async throws {
                let task = Task { await web.performSelectionAction(action) }
                try await wait("selection read outstanding") { outstanding.value != nil }
                try await change()
                outstanding.value?.resume(returning: result); outstanding.value = nil
                await task.value
            }
            let unavailable = "The selected text is no longer available."

            // The process ends and the notes are rebuilt while the read is outstanding: the old range is gone.
            try await act(.share, result: "Selected text") { try await end(web); try await ready(web, "rebuilt") }
            #expect(shared == nil && failures.map(\.localizedDescription) == [unavailable])
            failures.removeAll()
            // The read succeeds on the same notes but nothing is selected any more.
            try await act(.webSearch, result: "") {}
            #expect(opened == nil && failures.map(\.localizedDescription) == [unavailable])
            failures.removeAll()
            // Another episode's notes took their place: silent.
            try await act(.share, result: "Selected text") { web.show(episode(2, marker: "Replacement")) }
            #expect(shared == nil && failures.isEmpty, "\(failures)")
            try await ready(web, "replacement")
            // The notes left the screen: silent.
            try await act(.webSearch, result: "Selected text") { web.removeFromSuperview() }
            #expect(opened == nil && failures.isEmpty, "\(failures)")
            host.view.addSubview(web)
            // A read that completes on the current document still acts.
            try await act(.share, result: "Selected text") {}
            #expect(shared == "Selected text" && failures.isEmpty, "\(failures)")
        }
    }

    // MARK: Episode details

    /// A mounted library with one podcast of three episodes with long notes, its list open; optionally playing the first.
    private func library(playing: Bool, _ body: @MainActor (LibraryViewController, PlaybackCoordinator?, UIWindow) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShownotesRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let source = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Podcast", episodes: (1...3).map { number in
                ParsedEpisode(identifier: "episode-\(number)", title: "Episode \(number)",
                    description: episode(Int64(number), marker: "Episode\(number)Notes").details.description,
                    publicationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(number) * 86_400),
                    media: ParsedMedia(url: "https://example.invalid/media/\(number)", size: 0, durationMilliseconds: 60_000))
            }), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            var playback: PlaybackCoordinator?
            if playing {
                _ = try await store.beginPlayback(episodeID: feed.episodes[0].id)
                playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
                try await playback?.restore()
            }
            let time = try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json"))
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: playing ? time : nil, navigationPreferences: nil, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil, shownotesScroll: ShownotesScrollStore())
            try await withViewTestWindow { host, window in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds; controller.view.layoutIfNeeded()
                await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
                try await body(controller, playback, window)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
    private func openMiddleEpisode(_ controller: LibraryViewController) throws -> EpisodePagerState {
        let rows = controller.displayedEpisodeIDs
        try #require(rows.count == 3, "three episode rows: \(rows)")
        let row: UIButton = try #require(find("episode-\(rows[1])", in: controller.view))
        row.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
        let state = try #require(controller.visibleEpisodePager)
        try #require(state.model.index == 1 && Set(state.pages.keys) == [0, 1, 2])
        return state
    }
    private func swipe(_ controller: LibraryViewController, _ direction: UIAccessibilityScrollDirection) throws {
        let scroll: EpisodePagerView.PagingScrollView = try #require(find("episodePagerScroll", in: controller.view))
        try #require(scroll.accessibilityScroll(direction))
        controller.view.layoutIfNeeded()
    }

    /// Episode notes behind the expanded player are not shown: their process may end there without a rebuild, and
    /// the pager keeps only its shown page. Collapsing the player is a new visit: the notes come back even after the
    /// automatic budget was spent, and the neighbours are built again.
    @Test func episodeNotesCoveredByThePlayerWaitForItToCollapse() async throws {
        try await library(playing: true) { controller, playback, _ in
            let state = try openMiddleEpisode(controller)
            let notes = try #require(state.pages[1]?.notes)
            try await ready(notes, "episode notes")
            #expect(notes.isShownInActiveScene)
            for round in 1...ShownotesWebView.recoveryLimit {
                try await end(notes)
                try await ready(notes, "rebuild \(round)")
            }
            let player = try #require(player(in: controller.view))
            player.setExpanded(true, animated: false); controller.view.layoutIfNeeded()
            #expect(notes.isCovered && !notes.isShownInActiveScene, "behind the expanded player")
            #expect(Set(state.pages.keys) == [1], "nobody can swipe to the neighbours")

            try await end(notes)
            #expect(notes.isAwaitingLoad && !notes.isLoading && !notes.showsUnavailableState, "no rebuild behind the player")
            await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            #expect(Set(try #require(controller.visibleEpisodePager).pages.keys) == [1])
            #expect(notes.isAwaitingLoad, "a library update behind the player rebuilds nothing")

            player.setExpanded(false, animated: false); controller.view.layoutIfNeeded()
            #expect(!notes.isCovered)
            #expect(Set(try #require(controller.visibleEpisodePager).pages.keys) == [0, 1, 2])
            try await ready(notes, "rebuilt when the player collapses")
            #expect(!notes.showsUnavailableState, "a new visit's budget")
            let text = try await document(notes).text
            #expect(text.hasPrefix("Episode") && text.hasSuffix("Notes"), "\(text)")
            #expect(controller.presentedViewController == nil)
            #expect(playback?.wantsPlayback == false)
        }
    }

    /// Settings hides the expanded player without collapsing it, and Back returns to episode details that are still
    /// covered: notes whose process ended behind the player, and the pager's neighbours, wait for the actual collapse.
    @Test func backFromSettingsUnderTheExpandedPlayerKeepsTheNotesCovered() async throws {
        try await library(playing: true) { controller, playback, _ in
            let state = try openMiddleEpisode(controller)
            let notes = try #require(state.pages[1]?.notes)
            try await ready(notes, "episode notes")
            for round in 1...ShownotesWebView.recoveryLimit {
                try await end(notes)
                try await ready(notes, "rebuild \(round)")
            }
            let player = try #require(player(in: controller.view))
            player.setExpanded(true, animated: false); controller.view.layoutIfNeeded()
            try await end(notes)
            let ended = notes.processTerminations, built = controller.episodePagesBuilt
            #expect(notes.isCovered && notes.isAwaitingLoad && Set(state.pages.keys) == [1])

            // The playback settings the sleep timer opens.
            controller.push(.settings(.playback)); controller.view.layoutIfNeeded()
            #expect(player.isHidden && player.expansion == 1, "Settings hides the player without collapsing it")
            #expect(notes.window == nil && notes.isCovered && notes.isAwaitingLoad)
            let back: UIButton = try #require(find("toolbarBack", in: controller.view))
            back.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            #expect(controller.visibleEpisodePager === state && !player.isHidden && player.expansion == 1)
            #expect(notes.window != nil, "episode details are back, behind the player")
            #expect(notes.isCovered && notes.isAwaitingLoad && !notes.isLoading && !notes.showsUnavailableState,
                    "no rebuild behind the player")
            #expect(Set(state.pages.keys) == [1] && controller.episodePagesBuilt == built, "no neighbour built behind the player")

            player.setExpanded(false, animated: false); controller.view.layoutIfNeeded()
            #expect(!notes.isCovered && Set(state.pages.keys) == [0, 1, 2] && controller.episodePagesBuilt == built + 2)
            try await ready(notes, "rebuilt when the player collapses")
            #expect(!notes.showsUnavailableState && notes.processTerminations == ended, "a new visit's budget")
            #expect(controller.presentedViewController == nil)
            #expect(playback?.wantsPlayback == false)
        }
    }

    /// In a short window the header scrolls on its own. A neighbour released while the pager was in the background
    /// reopens with both its header and its notes where they were read.
    @Test func releasedNeighbourReopensWithItsHeaderAndNotesWhereTheyWereRead() async throws {
        try await library(playing: false) { controller, _, window in
            controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 420)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let state = try openMiddleEpisode(controller)
            let page = try #require(state.pages[1])
            // The safe area and shell differ by device, so no one height makes the header scroll everywhere: the
            // window shrinks until the header scrolls on its own with the notes still shown below it.
            var height: CGFloat = 420, maximum: CGFloat = 0, measured: [String] = []
            while height >= 120 {
                controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: height)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                maximum = page.headerScroll.contentSize.height - page.headerScroll.bounds.height
                measured.append("\(Int(height)): header \(Int(page.headerScroll.bounds.height))/\(Int(page.headerScroll.contentSize.height)) notes \(Int(page.notes.bounds.height))")
                if page.headerScroll.isScrollEnabled && maximum > 20 && page.notes.bounds.height >= page.notes.defaultLineHeight { break }
                height -= 10
            }
            try #require(state.pages[1]?.container === page.container, "resizing keeps the page")
            try #require(page.headerScroll.isScrollEnabled && maximum > 20 && page.notes.bounds.height >= page.notes.defaultLineHeight,
                         "a short window scrolls the header with notes below it: \(measured)")
            try await ready(page.notes, "page notes")
            try #require(page.notes.scrollView.contentSize.height - page.notes.bounds.height > 300, "the notes scroll past 300")
            let header = (maximum / 2).rounded()
            page.headerScroll.setContentOffset(CGPoint(x: 0, y: header), animated: false)
            page.notes.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
            try await settleFrames(page.notes)

            try swipe(controller, .left)
            #expect(state.model.index == 2 && state.pages[1]?.container === page.container, "a resident neighbour")
            let scene = try #require(window.windowScene)
            NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
            #expect(Set(state.pages.keys) == [2])
            NotificationCenter.default.post(name: UIScene.willEnterForegroundNotification, object: scene)
            let rebuilt = try #require(state.pages[1])
            #expect(rebuilt.container !== page.container)
            try await ready(rebuilt.notes, "rebuilt neighbour")
            #expect(rebuilt.headerScroll.contentOffset.y == header)
            #expect(rebuilt.notes.scrollView.contentOffset.y == 300)
            try swipe(controller, .right)
            #expect(state.model.index == 1 && state.pages[1]?.container === rebuilt.container)
            #expect(rebuilt.headerScroll.contentOffset.y == header)
            #expect(rebuilt.notes.scrollView.contentOffset.y == 300)
        }
    }
}

@MainActor private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension WKWebView {
    /// Test only: ends this view's own WebContent process, as iOS does when it reclaims it. In the Simulator the
    /// process (its pid from WebKit's private diagnostics) is killed directly: WebKit's own kill goes through
    /// RunningBoard, which can refuse it to an app. WebKit's terminate-and-reset diagnostic is the fallback.
    func killWebContentProcess() throws {
        let pidSelector = NSSelectorFromString("_webProcessIdentifier")
        if responds(to: pidSelector) {
            typealias Identifier = @convention(c) (AnyObject, Selector) -> pid_t
            let pid = unsafeBitCast(method(for: pidSelector), to: Identifier.self)(self, pidSelector)
            if pid > 0, kill(pid, SIGKILL) == 0 { return }
        }
        let selector = NSSelectorFromString("_killWebContentProcessAndResetState")
        try #require(responds(to: selector), "WebKit offers no content-process kill on this runtime")
        typealias Kill = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method(for: selector), to: Kill.self)(self, selector)
    }
}

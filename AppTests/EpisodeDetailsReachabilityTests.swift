import UIKit
import WebKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
@Suite(.serialized)
struct EpisodeDetailsReachabilityTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }

    /// A bounded script evaluation: a web content process that never answers fails the test
    /// instead of hanging the whole run (the suite time limit cannot interrupt WebKit's await).
    private func evaluate<T: Sendable>(_ web: WKWebView, _ script: String,
                                       _ convert: @escaping @Sendable (Any?) -> T) async throws -> T {
        let once = EvaluationOnce()
        return try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script) { value, error in
                guard !once.done else { return }
                once.done = true
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: convert(value)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !once.done else { return }
                once.done = true
                continuation.resume(throwing: URLError(.timedOut))
            }
        }
    }

    private func metrics(_ web: WKWebView) async throws -> [String: Double] {
        let value = try await evaluate(web, """
            (() => {
                const marker = document.getElementById('end') || document.getElementById('apNoShownotes');
                const rect = marker?.getBoundingClientRect();
                return {ready: marker && document.fonts.status === 'loaded' ? 1 : 0,
                        top: rect?.top || 0, bottom: rect?.bottom || 0,
                        width: innerWidth, height: innerHeight, scroll: scrollY,
                        visualHeight: visualViewport.height,
                        documentHeight: document.scrollingElement.scrollHeight};
            })()
            """) { ($0 as? [String: NSNumber])?.mapValues(\.doubleValue) }
        return try #require(value)
    }

    private func wait(_ web: WKWebView, until condition: ([String: Double]) -> Bool) async throws -> [String: Double] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var value = try await metrics(web)
        while !condition(value), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            value = try await metrics(web)
        }
        try #require(condition(value), "Unsettled web viewport: \(value)")
        return value
    }

    @Test(arguments: ["empty", "short", "long"], [false, true])
    func constrainedHeaderAndNotesRemainReachableAndRetained(kind: String, rtl: Bool) async throws {
        try await exercise(kind: kind, rtl: rtl, largeText: false)
    }

    @Test(arguments: ["empty", "long"])
    func accessibilityTextKeepsNotesReadableWhileNoticeScrolls(kind: String) async throws {
        try await exercise(kind: kind, rtl: false, largeText: true)
    }

    private func exercise(kind: String, rtl: Bool, largeText: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EpisodeReachability-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try NavigationPreferenceStore(file: directory.appendingPathComponent("navigation.json"))
        var configuration = preferences.value; configuration.bottomNavigation = false
        // Start on the (preview) feed itself: the source Home lists no preview-feed episodes.
        configuration.defaultPage = "remember"; configuration.lastPage = "1"
        try preferences.update(configuration)
        let description: String? = switch kind {
        case "empty": nil
        case "short": "<p id='end'>End</p>"
        default: String(repeating: "<p>Long notes for independent scrolling.</p>", count: 80) + "<p id='end'>End</p>"
        }
        let episode = LibraryEpisode(id: 1, details: .init(title: String(repeating: "A long episode title ", count: 20),
            description: description, media: .init(url: "https://example.invalid/media.mp3", size: 0, mimeType: "audio/mpeg")))
        var feed = LibraryFeed(id: 1, source: "fixture://episode", metadata: .init(format: .rss, title: "Header lab"),
            episodes: [episode])
        feed.subscriptionState = .notSubscribed
        let snapshot = FeedLibrarySnapshot(feeds: [feed], queue: [])
        let controller = LibraryViewController(library: nil, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: preferences, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, loadSnapshot: { snapshot })
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            if largeText { controller.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
            @MainActor func resize(_ height: CGFloat) {
                controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: height)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            }
            resize(700)
            await controller.reloadLibrary()?.value
            let row: UIButton = try #require(element("episode-1", in: controller.view))
            row.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            let cover: UIButton = try #require(element("episodeCover", in: controller.view))
            let header = try #require(cover.superview as? EpisodeHeaderView)
            let notes: ShownotesWebView = try #require(element("episodeShownotes", in: controller.view))
            let scroll: UIScrollView = try #require(element("episodeHeaderScroll", in: controller.view))
            // The screen's content area below the toolbar (the page sits in the episode pager inside it).
            let outer: UIScrollView = try #require(element("libraryContent", in: controller.view))
            #expect(scroll.isDescendant(of: outer))
            let normalHeight = header.sizeThatFits(CGSize(width: scroll.bounds.width, height: CGFloat.greatestFiniteMagnitude)).height
            let normalFits = normalHeight + notes.readableViewportHeight(width: notes.bounds.width) <= outer.bounds.height
            if normalFits {
                #expect(abs(scroll.bounds.height - normalHeight) < 1)
                #expect(abs(notes.frame.minY - normalHeight) < 1)
                #expect(!scroll.isScrollEnabled)
            }
            #expect(!outer.isScrollEnabled)
            if largeText {
                let label: UILabel = try #require(element("episodeTitle", in: header))
                #expect(label.font.pointSize > 30, "The fixture must actually exercise scaled text")
            }
            let initial = try await wait(notes) {
                $0["ready"] == 1 && abs(($0["width"] ?? -1) - notes.bounds.width) < 1
                    && abs(($0["height"] ?? -1) - notes.bounds.height) < 1
                    && abs(notes.scrollView.contentSize.width - notes.bounds.width) < 1
            }
            #expect(initial["scroll"] == 0)
            // A document-local marker detects accidental reloads during layout/refresh.
            _ = try await evaluate(notes, "window.retainedLayoutMarker = 'retained'") { _ in true }
            resize(310)
            #expect(scroll.isScrollEnabled)
            #expect(scroll.bounds.height >= 56)
            #expect(notes.bounds.height >= notes.readableViewportHeight(width: notes.bounds.width))
            #expect(abs(header.bounds.height - normalHeight) < 1)
            #expect(abs(notes.frame.minY - scroll.frame.maxY) < 1)
            #expect(abs(notes.frame.maxY - outer.bounds.height) < 1)
            let primary: UIButton = try #require(element("episodePrimaryAction", in: header))
            let target = primary.convert(primary.bounds, to: header)
            scroll.setContentOffset(CGPoint(x: 0, y: min(target.minY, scroll.contentSize.height - scroll.bounds.height)), animated: false)
            let actionFrame = primary.convert(primary.bounds, to: window)
            #expect(scroll.convert(scroll.bounds, to: window).contains(actionFrame))
            let hit = window.hitTest(CGPoint(x: actionFrame.midX, y: actionFrame.midY), with: nil)
            #expect(hit === primary || hit?.isDescendant(of: primary) == true)
            let headerOffset = scroll.contentOffset
            _ = try await wait(notes) {
                $0["ready"] == 1 && abs(($0["height"] ?? -1) - notes.bounds.height) < 1
                    && abs(($0["width"] ?? -1) - notes.bounds.width) < 1
                    && abs(($0["visualHeight"] ?? -1) - notes.bounds.height) < 1
                    && abs(notes.scrollView.contentSize.width - notes.bounds.width) < 1
                    && abs(notes.scrollView.contentSize.height - ($0["documentHeight"] ?? -1)) < 1
            }
            if kind == "empty" {
                _ = try await wait(notes) { $0["top", default: -1] >= 0 && $0["bottom", default: .infinity] <= notes.bounds.height }
            } else {
                notes.scrollView.setContentOffset(CGPoint(x: 0, y: max(0, notes.scrollView.contentSize.height - notes.bounds.height)), animated: false)
                _ = try await wait(notes) { $0["top", default: -1] >= 0 && $0["bottom", default: .infinity] <= notes.bounds.height }
            }
            #expect(scroll.contentOffset == headerOffset)
            let notesOffset = notes.scrollView.contentOffset
            await controller.reloadLibrary()?.value
            controller.view.layoutIfNeeded()
            #expect(element("episodeCover", in: controller.view, as: UIButton.self) === cover)
            #expect(element("episodeShownotes", in: controller.view, as: ShownotesWebView.self) === notes)
            #expect(scroll.contentOffset == headerOffset)
            #expect(notes.scrollView.contentOffset == notesOffset)
            let notice: UIControl = try #require(element("episodeSubscriptionNotice", in: header))
            let noticeContent = notice.convert(notice.bounds, to: header)
            if largeText {
                #expect(noticeContent.height > scroll.bounds.height)
                for y in [noticeContent.minY, noticeContent.maxY - 30] {
                    let strip = CGRect(x: noticeContent.minX, y: y, width: noticeContent.width, height: 30)
                    scroll.scrollRectToVisible(strip, animated: false)
                    #expect(scroll.convert(scroll.bounds, to: window).insetBy(dx: -1, dy: -1)
                        .contains(header.convert(strip, to: window)))
                }
            } else { scroll.scrollRectToVisible(noticeContent, animated: false) }
            let noticeFrame = notice.convert(notice.bounds, to: window)
            let visibleNotice = noticeFrame.intersection(scroll.convert(scroll.bounds, to: window))
            if !largeText { #expect(scroll.convert(scroll.bounds, to: window).contains(noticeFrame)) }
            #expect(visibleNotice.height >= 30)
            let noticeHit = window.hitTest(CGPoint(x: visibleNotice.midX, y: visibleNotice.midY), with: nil)
            #expect(noticeHit === notice || noticeHit?.isDescendant(of: notice) == true)
            #expect(notes.scrollView.contentOffset == notesOffset)
            scroll.setContentOffset(.zero, animated: false)
            #expect(notes.scrollView.contentOffset == notesOffset)
            if kind == "long" {
                // Interior reading position can remain exact because neither resize
                // reaches a document boundary; bottom-clamping is a separate case.
                notes.scrollView.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
                _ = try await wait(notes) { abs($0["scroll", default: -1] - 400) < 1 }
                for height: CGFloat in [700, 310] {
                    resize(height)
                    _ = try await wait(notes) { abs($0["height", default: -1] - notes.bounds.height) < 1 }
                    #expect(abs(notes.scrollView.contentOffset.y - 400) < 1)
                }
            }
            resize(700)
            #expect(scroll.contentOffset == .zero)
            if normalFits {
                #expect(abs(scroll.bounds.height - normalHeight) < 1 && !scroll.isScrollEnabled)
                #expect(abs(notes.frame.minY - normalHeight) < 1)
            }
            #expect(try await evaluate(notes, "window.retainedLayoutMarker") { $0 as? String } == "retained")
            let back: UIButton = try #require(element("toolbarBack", in: controller.view))
            back.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            #expect(outer.isScrollEnabled)
            #expect(element("episode-1", in: controller.view, as: UIButton.self) != nil)
        }
    }
}

@MainActor private final class EvaluationOnce { var done = false }

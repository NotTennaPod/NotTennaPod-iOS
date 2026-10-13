import UIKit
import WebKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ShownotesRaceViewTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Expected current shownotes document/message delivery")
    }

    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }

    private func episode(_ id: Int64, marker: String, duration: Int32 = 30_000) -> LibraryEpisode {
        LibraryEpisode(id: id, details: .init(title: "Race \(id)", description:
            "<p>\(marker)</p>" + (0..<100).map { "<p>\(marker) paragraph \($0) retained reading state.</p>" }.joined(),
            media: .init(url: "https://example.invalid/media/\(id)", size: 0, durationMilliseconds: duration)))
    }

    private func state(_ web: ShownotesWebView) async throws -> [String] {
        try #require(try await web.callAsyncJavaScript("""
            return [globalThis.apShownotesDocument || '', document.querySelector('p')?.textContent || '', getSelection().toString()];
            """, in: nil, contentWorld: .defaultClient) as? [String])
    }

    private func settleFrames(_ web: ShownotesWebView) async throws {
        _ = try await web.callAsyncJavaScript("""
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            """, in: nil, contentWorld: .defaultClient)
    }

    private func selectVisibleParagraph(_ web: ShownotesWebView, window: UIWindow) async throws -> String {
        let text = try #require(try await web.callAsyncJavaScript("""
            const paragraph = Array.from(document.querySelectorAll('p')).find(p => {
                const bounds = p.getBoundingClientRect();
                return bounds.top >= 0 && bounds.bottom < innerHeight;
            });
            if (!paragraph) throw new Error('No visible paragraph');
            const range = document.createRange(); range.selectNodeContents(paragraph);
            getSelection().removeAllRanges(); getSelection().addRange(range);
            return getSelection().toString();
            """, in: nil, contentWorld: .defaultClient) as? String)
        try #require(!text.isEmpty)
        try await wait { (find("shownotesSelection-share", in: window) as UIButton?) != nil }
        return text
    }

    /// Replay an obsolete document's messages through the real isolated-world
    /// WebKit bridge. The following sentinel uses the same frame/transport, so
    /// assertions run after native delivery, without guessing a sleep duration.
    private func postObsolete(_ web: ShownotesWebView, document: String, types: [String],
                              delivery: ShownotesRaceDelivery) async throws {
        let expected = delivery.count + 1
        _ = try await web.callAsyncJavaScript("""
            for (const type of types) {
                window.webkit.messageHandlers.apSelection.postMessage({
                    document: obsoleteDocument, type, text: 'Obsolete selection', rects: [[20, 80, 120, 20]]
                });
            }
            window.webkit.messageHandlers.apRaceDelivery.postMessage('delivered');
            """, arguments: ["obsoleteDocument": document, "types": types], in: nil, contentWorld: .defaultClient)
        try await wait { delivery.count == expected }
    }

    @Test(arguments: [false, true])
    func rapidAToBToARejectsObsoleteReadinessAndSelection(matchingSavedRecord: Bool) async throws {
        try await withViewTestWindow { host, window in
            let web = ShownotesWebView(), saved = ShownotesScrollStore(), delivery = ShownotesRaceDelivery()
            host.view.addSubview(web); web.frame = host.view.bounds
            web.configuration.userContentController.add(delivery, contentWorld: .defaultClient, name: "apRaceDelivery")
            defer {
                web.configuration.userContentController.removeScriptMessageHandler(forName: "apRaceDelivery", contentWorld: .defaultClient)
                web.removeFromSuperview()
            }
            let savedID: Int64 = matchingSavedRecord ? 1 : 2
            try saved.save(episodeID: savedID, offset: 300)
            var currentID: Int64 = 1
            var restorations: [Int64] = []
            web.restoreScrollOffset = {
                restorations.append(currentID)
                return CGFloat(saved.offset(for: currentID) ?? 0)
            }
            let first = episode(1, marker: "CurrentAlpha"), second = episode(2, marker: "ObsoleteBeta")
            web.show(first)
            try await wait { !web.isLoading && restorations.count == 1 && web.scrollView.contentSize.height > 2000 }
            let oldA = try await state(web)[0]
            currentID = 2; web.show(second)
            try await wait { !web.isLoading && restorations.count == 2 }
            let oldB = try await state(web)[0]
            _ = try await selectVisibleParagraph(web, window: window)

            // No suspension between replacements: none of these pending loads
            // can deliver a native ready callback before the final media wins.
            restorations.removeAll()
            currentID = 1; web.show(first)
            currentID = 2; web.show(second)
            currentID = 1; web.show(first)
            try #require(restorations.isEmpty)
            try await wait { !web.isLoading && restorations.count == 1 }
            let current = try await state(web)
            #expect(current[1] == "CurrentAlpha")
            #expect(current[2].isEmpty)
            #expect(current[0] != oldA && current[0] != oldB)
            #expect(restorations == [1])
            #expect(web.scrollView.contentOffset.y == (matchingSavedRecord ? 300 : 0))
            #expect((find("shownotesSelection-share", in: window) as UIButton?) == nil)
            for obsolete in [oldA, oldB] {
                try await postObsolete(web, document: obsolete, types: ["selection"], delivery: delivery)
                #expect((find("shownotesSelection-share", in: window) as UIButton?) == nil)
            }

            web.scrollView.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
            try await settleFrames(web)
            let selected = try await selectVisibleParagraph(web, window: window)
            try await settleFrames(web)
            try #require(web.scrollView.contentOffset.y == 600)
            for obsolete in [oldB, oldA] {
                try await postObsolete(web, document: obsolete, types: ["ready", "hide", "interaction"], delivery: delivery)
                #expect(try await state(web) == [current[0], "CurrentAlpha", selected])
                #expect(web.scrollView.contentOffset.y == 600)
                #expect((find("shownotesSelection-share", in: window) as UIButton?) != nil)
                #expect(restorations == [1])
            }
            var shared: String?
            web.shareSelection = { text, _ in shared = text }
            await web.performSelectionAction(.share)
            #expect(shared == selected)
            #expect(saved.offset(for: savedID) == 300)
            #expect(saved.offset(for: savedID == 1 ? 2 : 1) == nil)
        }
    }

    @Test(arguments: [false, true])
    func equalHTMLMediaReplacementDuringReadinessUsesCurrentSavedRecord(matchingSavedRecord: Bool) async throws {
        try await withViewTestWindow { host, window in
            let web = ShownotesWebView(), saved = ShownotesScrollStore(), delivery = ShownotesRaceDelivery()
            host.view.addSubview(web); web.frame = host.view.bounds
            web.configuration.userContentController.add(delivery, contentWorld: .defaultClient, name: "apRaceDelivery")
            defer {
                web.configuration.userContentController.removeScriptMessageHandler(forName: "apRaceDelivery", contentWorld: .defaultClient)
                web.removeFromSuperview()
            }
            let savedID: Int64 = matchingSavedRecord ? 2 : 1
            try saved.save(episodeID: savedID, offset: 300)
            var currentID: Int64 = 1
            var restorations: [Int64] = []
            web.restoreScrollOffset = {
                restorations.append(currentID)
                return CGFloat(saved.offset(for: currentID) ?? 0)
            }
            web.show(episode(1, marker: "OriginalAlpha"))
            try await wait { !web.isLoading && restorations.count == 1 && web.scrollView.contentSize.height > 2000 }
            let obsolete = try await state(web)[0]
            restorations.removeAll()
            web.show(episode(1, marker: "SharedDocument"))
            currentID = 2
            // Different raw duration, same formatted HTML: readiness belongs to
            // media 2 even though media 1 initiated this document's load.
            web.show(episode(2, marker: "SharedDocument", duration: 60_000))
            try #require(restorations.isEmpty)
            try await wait { !web.isLoading && restorations.count == 1 }
            let current = try await state(web)
            #expect(current[0] != obsolete)
            #expect(current[1] == "SharedDocument" && current[2].isEmpty)
            #expect(restorations == [2])
            #expect(web.scrollView.contentOffset.y == (matchingSavedRecord ? 300 : 0))

            web.scrollView.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
            try await settleFrames(web)
            let selected = try await selectVisibleParagraph(web, window: window)
            try await settleFrames(web)
            try #require(web.scrollView.contentOffset.y == 600)
            currentID = 1
            web.show(episode(1, marker: "SharedDocument", duration: 90_000))
            try await postObsolete(web, document: obsolete, types: ["ready", "hide", "interaction"], delivery: delivery)
            #expect(try await state(web) == [current[0], "SharedDocument", selected])
            #expect(web.scrollView.contentOffset.y == 600)
            #expect((find("shownotesSelection-share", in: window) as UIButton?) != nil)
            #expect(restorations == [2])
            #expect(saved.offset(for: savedID) == 300)
            #expect(saved.offset(for: savedID == 1 ? 2 : 1) == nil)
        }
    }
}

@MainActor private final class ShownotesRaceDelivery: NSObject, WKScriptMessageHandler {
    var count = 0
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        count += 1
    }
}

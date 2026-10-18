import UIKit
import Testing
import WebKit
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct ShownotesLinkMenuViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let found = view as? T { return found }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func wait(_ ready: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(ready())
    }
    @Test func feedScriptsDoNotRunAndPlainTextIsNotAutoLinked() async throws {
        // Feed-supplied scripts must not run (they could change what the notes show);
        // plain text such as a phone number must not be turned into a link.
        try await withViewTestWindow { host, _ in
            let web = ShownotesWebView()
            web.frame = host.view.bounds
            host.view.addSubview(web)
            defer { web.removeFromSuperview() }
            web.show(LibraryEpisode(id: 1, details: .init(title: "Scripts", description: """
                <p id="target">Original text</p><p>Call 555-123-4567</p>
                <script>document.getElementById('target').textContent = 'Changed by the feed'; document.body.dataset.ran = 'yes';</script>
                <img src="data:," onerror="document.body.dataset.handler = 'yes'">
                """)))
            try await wait { !web.isLoading }
            let state = try await web.callAsyncJavaScript(
                "return [document.getElementById('target').textContent, document.body.dataset.ran || '', document.body.dataset.handler || '']",
                in: nil, contentWorld: .defaultClient) as? [String]
            #expect(state == ["Original text", "", ""])
            #expect(web.configuration.dataDetectorTypes.isEmpty)
        }
    }
    @Test func selectAllCopiesExactSourceTextIncludingImageAlternatives() async throws {
        try await withViewTestWindow { host, _ in
            let web = ShownotesWebView()
            web.frame = host.view.bounds
            host.view.addSubview(web)
            let pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNIaNjwHwAFZAKQkQo/aQAAAABJRU5ErkJggg=="
            web.show(LibraryEpisode(id: 1, details: .init(title: "Selection", description: """
                <p><a href="https://example.invalid/image"><img alt="Linked image" src="\(pixel)">Mixed link text</a></p><p><img alt="Plain image" src="\(pixel)"></p><p>Selectableword</p><p><a href="https://example.invalid/text">Text link</a></p>
                """)))
            try await wait { !web.isLoading }
            let ready = try await web.evaluateJavaScript("document.readyState")
            #expect(ready as? String == "complete")
            web.becomeFirstResponder()
            web.selectAll(nil)
            let deadline = ContinuousClock.now + .seconds(5)
            var selection = ""
            repeat {
                selection = (try await web.evaluateJavaScript("getSelection().toString()")) as? String ?? ""
                if !selection.contains("Selectableword") { try await Task.sleep(for: .milliseconds(10)) }
            } while !selection.contains("Selectableword") && ContinuousClock.now < deadline
            try #require(selection.contains("Selectableword"))
            let expectedSelection = "Mixed link text\n\n\n\nSelectableword\n\nText link"
            var shared: String?
            var search: String?
            web.shareSelection = { value, source in
                #expect(source === web)
                shared = value
            }
            web.openLink = { search = $0 }
            await web.performSelectionAction(.share)
            #expect(shared == expectedSelection)
            await web.performSelectionAction(.webSearch)
            #expect(search == ShownotesWebView.webSearchURL(for: expectedSelection).absoluteString)
            let change = UIPasteboard.general.changeCount
            web.copy(nil)
            try await wait { UIPasteboard.general.changeCount != change }
            #expect(UIPasteboard.general.string == "Linked imageMixed link text\n\nPlain image\n\nSelectableword\n\nText link")
        }
    }
    @Test func searchQueryPreservesReservedCharactersAndUnicode() throws {
        let text = "AntennaPod selection + & # café 🎧\nsecond line?=100%"
        let url = ShownotesWebView.webSearchURL(for: text)
        #expect(url.scheme == "x-web-search")
        #expect(url.fragment == nil)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedQuery?.removingPercentEncoding == text)
        #expect(components.percentEncodedQuery?.contains("%2B%20%26%20%23") == true)
    }
    @Test func selectionToolbarUsesCurrentAsymmetricInsetsAndClippedRange() async throws {
        try await withViewTestWindow { host, _ in
            let clip = UIView(); clip.clipsToBounds = true; host.view.addSubview(clip)
            let web = ShownotesWebView(); clip.addSubview(web)
            let toolbar = ShownotesSelectionToolbar(); toolbar.source = web
            host.view.addSubview(toolbar)
            toolbar.configure([("copy", "Copy"), ("share", "Share"), ("all", "Select all"), ("search", "Web search")].map { id, title in
                .init(id: id, title: title, perform: {})
            })
            for (width, height, left, right) in [(466.0,678.0,0.0,0.0),(640,678,0,84),(640,678,84,0),(834,1194,43,7),(402,874,7,43)] {
                host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
                host.additionalSafeAreaInsets = .init(top: 0, left: left, bottom: 0, right: right)
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                clip.frame = CGRect(x: 24, y: 100, width: width - 48, height: height - 200)
                web.frame = CGRect(x: 0, y: -100, width: clip.bounds.width, height: height)
                toolbar.frame = host.view.bounds
                toolbar.fragments = [CGRect(x: 24, y: 280, width: 100, height: 20)]
                toolbar.setNeedsLayout(); toolbar.layoutIfNeeded()
                let panel: UIView = try #require(find("shownotesSelectionToolbar", in: toolbar))
                #expect(!panel.isHidden)
                let safe = toolbar.bounds.inset(by: toolbar.safeAreaInsets)
                // Additional insets augment the real device insets. This is a
                // fitting-row scenario; narrow allocation is verified separately.
                try #require(safe.width >= 325)
                #expect(safe.contains(panel.frame))
                let labels = panel.subviews.compactMap { $0 as? UIButton }.filter { !$0.isHidden }.map { $0.title(for: .normal) ?? "" }
                #expect(labels == ["Copy", "Share", "Select all", "Web search"])
                #expect(abs(panel.bounds.height - 48) <= 1)
                toolbar.fragments = [CGRect(x: 24, y: 2_000, width: 100, height: 20)]
                toolbar.setNeedsLayout(); toolbar.layoutIfNeeded()
                #expect(panel.isHidden)
            }
            toolbar.removeFromSuperview()
        }
    }
    @Test(arguments: [false, true]) func selectionOverflowKeepsEveryActionReachable(rtl: Bool) async throws {
        try await withViewTestWindow { host, _ in
            host.view.frame = CGRect(x: 0, y: 0, width: 210, height: 340)
            host.additionalSafeAreaInsets = .init(top: 0, left: rtl ? 36 : 0, bottom: 0, right: rtl ? 0 : 36)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            let web = ShownotesWebView(); web.frame = host.view.bounds; host.view.addSubview(web)
            let toolbar = ShownotesSelectionToolbar(); toolbar.frame = host.view.bounds; toolbar.source = web
            toolbar.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            toolbar.fragments = [CGRect(x: 45, y: 120, width: 20, height: 20)]
            var performed: [String] = []
            let actions = [("copy", "Copy"), ("share", "Share"), ("all", "Select all"), ("search", "Web search")]
            toolbar.configure(actions.map { id, title in .init(id: id, title: title) { performed.append(id) } })
            host.view.addSubview(toolbar); toolbar.setNeedsLayout(); toolbar.layoutIfNeeded()
            let more: UIButton = try #require(find("shownotesSelection-more", in: toolbar))
            let panel: UIView = try #require(find("shownotesSelectionToolbar", in: toolbar))
            let primary = panel.subviews.compactMap { $0 as? UIButton }.filter { $0 !== more && !$0.isHidden }
            for button in primary {
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: toolbar)
                #expect(toolbar.hitTest(point, with: nil) === button)
                button.sendActions(for: .touchUpInside)
            }
            #expect(!more.isHidden); more.sendActions(for: .touchUpInside); toolbar.layoutIfNeeded()
            let popup: UIScrollView = try #require(find("shownotesSelectionOverflow", in: toolbar))
            let overflow = popup.subviews.compactMap { $0 as? UIButton }
            // Check the configured inventory, not only whichever children the
            // implementation happens to render; a dropped action must fail.
            #expect((primary + overflow).map { $0.accessibilityIdentifier ?? "" } == actions.map { "shownotesSelection-" + $0.0 })
            let safe = toolbar.bounds.inset(by: toolbar.safeAreaInsets)
            #expect(!popup.isHidden && popup.bounds.height > 0)
            #expect(safe.contains(popup.frame) && safe.contains(panel.frame))
            #expect(popup.frame.maxY <= panel.frame.minY)
            for button in overflow {
                popup.scrollRectToVisible(button.frame, animated: false)
                let visible = button.convert(button.bounds, to: popup).intersection(popup.bounds)
                try #require(!visible.isEmpty && !visible.isNull)
                let point = popup.convert(CGPoint(x: visible.midX, y: visible.midY), to: toolbar)
                #expect(toolbar.hitTest(point, with: nil) === button)
                button.sendActions(for: .touchUpInside)
            }
            #expect(performed == actions.map(\.0))
            more.sendActions(for: .touchUpInside); toolbar.layoutIfNeeded()
            #expect(popup.isHidden)
            toolbar.removeFromSuperview()
        }
    }
    @Test func selectionDismissalSurvivesResizeAndUnrelatedFrameEvents() async throws {
        try await withViewTestWindow { host, window in
            let web = ShownotesWebView(); web.frame = host.view.bounds; host.view.addSubview(web)
            web.show(LibraryEpisode(id: 1, details: .init(title: "Selection lifetime", description: "<p>Selectableword</p><iframe srcdoc='child'></iframe>")))
            try await wait { !web.isLoading }
            web.becomeFirstResponder(); web.selectAll(nil)
            try await wait { (find("shownotesSelection-share", in: window) as UIButton?) != nil }
            _ = try await web.callAsyncJavaScript("document.querySelector('iframe').contentWindow.dispatchEvent(new Event('resize')); await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));", in: nil, contentWorld: .defaultClient)
            let share: UIButton = try #require(find("shownotesSelection-share", in: window))
            var shared = false
            web.shareSelection = { _, _ in shared = true }
            share.sendActions(for: .touchUpInside)
            try await wait { shared }
            _ = try await web.callAsyncJavaScript("dispatchEvent(new Event('resize')); await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));", in: nil, contentWorld: .defaultClient)
            #expect((find("shownotesSelection-share", in: window) as UIButton?) == nil)
            web.show(LibraryEpisode(id: 2, details: .init(title: "Replacement", description: "<p>Replacement</p>")))
            try await wait { !web.isLoading }
            #expect((find("shownotesSelection-share", in: window) as UIButton?) == nil)
        }
    }
    @Test func sourceTitleFontBoxesAndVisibleShareAnchor() async throws {
        try await withViewTestWindow { host, _ in
            for (destination, sourceHeight, sourceFontSize, nativeFontSize) in [("https://example.invalid/path?q=one%20two&x=3", 118.0, 47.0, 18.0), ("antennapod://timecode/15000", 71.0, 53.0, 20.0)] {
                let controller = ShownotesLinkMenuController(menu: .init(destination: destination, canOpenInBrowser: true)) { _ in }
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.traitOverrides.preferredContentSizeCategory = .large
                controller.view.frame = CGRect(x: 0, y: 0, width: 1080 / 2.625, height: 2400 / 2.625)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let heading: UILabel = try #require(find("shownotesLinkTitle", in: controller.view))
                // WindowInspector confirms Android resolves18sp to47px and20sp
                // to53px at density2.625. Compare boxes at the same font size;
                // do not bake that emulator's rounded17.905/20.190pt fonts into iOS.
                #expect(abs(heading.font.pointSize - nativeFontSize) < 0.000001)
                let expectedTitleHeight = sourceHeight / sourceFontSize * nativeFontSize
                #expect(abs(heading.bounds.height - expectedTitleHeight) <= 1, "native title \(heading.bounds.height), normalized source \(expectedTitleHeight)")
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
            }
            let clip = UIView(frame: CGRect(x: 20, y: 50, width: 180, height: 240)); clip.clipsToBounds = true
            host.view.addSubview(clip)
            let notes = ShownotesWebView(); clip.addSubview(notes)
            notes.frame = CGRect(x: -40, y: -60, width: 400, height: 900)
            let point = notes.convert(notes.linkShareAnchorRect, to: clip)
            #expect(clip.bounds.contains(point))
            // Share popover anchors at the centre of the visible notes area.
            #expect(abs(point.midX - clip.bounds.midX) <= 1)
            #expect(abs(point.midY - clip.bounds.midY) <= 1)
        }
    }
    @Test(arguments: [false, true]) func sourceOrderAndReachabilityAcrossLocalSizes(rtl: Bool) async throws {
        try await withViewTestWindow { host, _ in
            let menu = ShownotesLinkMenu(destination: "https://example.invalid/path?q=one%20two&x=3", canOpenInBrowser: true)
            var performed: [ShownotesLinkMenu.Action] = []
            let controller = ShownotesLinkMenuController(menu: menu) { performed.append($0) }
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                controller.traitOverrides.preferredContentSizeCategory = category
                for (width, height, left, right) in [(402.0,874.0,7.0,43.0),(800,900,43,7),(874,300,7,43),(320,180,43,7),(466,678,0,84)] {
                    controller.additionalSafeAreaInsets = .init(top: 9, left: left, bottom: 11, right: right)
                    controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
                    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                    let panel: UIView = try #require(find("shownotesLinkMenu", in: controller.view))
                    let scroll: UIScrollView = try #require(find("shownotesLinkActions", in: panel))
                    let outer: UIScrollView = try #require(find("shownotesLinkViewport", in: panel))
                    let safe = controller.view.bounds.inset(by: controller.view.safeAreaInsets)
                    #expect(safe.contains(panel.frame))
                    let title: UILabel = try #require(find("shownotesLinkTitle", in: controller.view))
                    #expect(title.accessibilityLabel == menu.destination)
                    var previous: CGFloat = 0
                    for action in menu.actions {
                        let button: UIButton = try #require(find("shownotesLink-" + action.rawValue, in: controller.view))
                        // Actions stacked in source order, each spanning the menu width.
                        #expect(button.frame.minY >= previous - 0.5)
                        #expect(button.frame.minX <= 0.5 && button.frame.width >= panel.bounds.width - 1)
                        #expect(button.frame.height >= 48)
                        #expect(button.title(for: .normal) == [.openInBrowser: "Open in browser", .copyURL: "Copy URL", .shareURL: "Share URL", .goToPosition: "Go to this position"][action])
                        #expect(button.point(inside: CGPoint(x: 4, y: button.bounds.midY), with: nil))
                        if outer.isScrollEnabled { outer.scrollRectToVisible(button.convert(button.bounds, to: outer), animated: false) }
                        else { scroll.scrollRectToVisible(button.frame, animated: false) }
                        let visible = button.convert(button.bounds, to: panel).intersection(panel.bounds)
                        if !outer.isScrollEnabled { #expect(abs(title.convert(title.bounds, to: panel).minY - 18) <= 1) }
                        #expect(visible.height >= min(button.frame.height, panel.bounds.height) - 0.5)
                        previous = button.frame.maxY
                    }
                    #expect(controller.menu == menu && performed.isEmpty)
                }
            }
        }
    }
    @Test func actionCommitsOnceAfterDismissalAndEscapeIsInert() async throws {
        try await withViewTestWindow { host, _ in
            let model = ShownotesLinkMenu(destination: "antennapod://timecode/15000", canOpenInBrowser: true)
            var actions: [ShownotesLinkMenu.Action] = []
            var dismissedBeforeAction = false
            let controller = ShownotesLinkMenuController(menu: model) {
                dismissedBeforeAction = host.presentedViewController == nil
                actions.append($0)
            }
            host.present(controller, animated: false)
            try await wait { controller.view.window != nil && !controller.isBeingPresented }
            let button: UIButton = try #require(find("shownotesLink-go_to_position_label", in: controller.view))
            button.sendActions(for: .touchUpInside); button.sendActions(for: .touchUpInside)
            try await wait { actions.count == 1 }
            #expect(actions == [.goToPosition] && dismissedBeforeAction)
            #expect(controller.keyCommands?.isEmpty == true)
            let cancelled = ShownotesLinkMenuController(menu: model) { actions.append($0) }
            host.present(cancelled, animated: false)
            try await wait { cancelled.view.window != nil && !cancelled.isBeingPresented }
            #expect(cancelled.accessibilityPerformEscape())
            try await wait { host.presentedViewController == nil }
            #expect(actions == [.goToPosition])
        }
    }
    /// System text services (Speak Selection's Speak, Speak…, Pause and the
    /// services menu) are the iOS counterpart of Android's PROCESS_TEXT entries
    /// in the selection toolbar's overflow. A real service depends on device
    /// settings and system speech state, so this drives our integration with
    /// controlled commands; the real Speak action is a hardware-checklist item.
    @Test func offeredTextServicesJoinTheOverflowAndRunOnTheirResponder() async throws {
        try await withViewTestWindow { host, window in
            let services = TextServiceResponder(frame: host.view.bounds)
            host.view.addSubview(services)
            let web = ShownotesWebView(); web.frame = services.bounds; services.addSubview(web)
            web.show(LibraryEpisode(id: 1, details: .init(title: "Text services", description: "<p>Selectableword</p><p><a href=\"https://example.invalid/text\">Text link</a></p>")))
            try await wait { !web.isLoading }
            web.becomeFirstResponder(); web.selectAll(nil)
            try await wait { (find("shownotesSelection-share", in: window) as UIButton?) != nil }
            var prepared = 0
            web.willPerformTextService = { prepared += 1 }
            @MainActor func toolbar() throws -> (panel: UIView, more: UIButton) {
                let panel: UIView = try #require(find("shownotesSelectionToolbar", in: window))
                panel.superview?.layoutIfNeeded()
                return (panel, try #require(find("shownotesSelection-more", in: window)))
            }
            @MainActor func providers() -> [UIButton] {
                func all(_ view: UIView) -> [UIButton] {
                    ((view as? UIButton).map { [$0] } ?? []) + view.subviews.flatMap(all)
                }
                return all(window).filter { $0.accessibilityIdentifier?.hasPrefix("shownotesSelection-provider-") == true }
            }
            @MainActor func primary(_ panel: UIView) -> [String] {
                panel.subviews.compactMap { $0 as? UIButton }
                    .filter { !$0.isHidden && $0.accessibilityIdentifier != "shownotesSelection-more" }
                    .map { $0.title(for: .normal) ?? "" }
            }

            // Only a refused command offered (Pause while nothing speaks):
            // no overflow, like Android without PROCESS_TEXT activities.
            let refused = TextServiceMenuBuilder(speech: [UICommand(title: "Pause", action: #selector(TextServiceResponder.refusedService(_:)))])
            web.buildMenu(with: refused)
            #expect(refused.replacedRoot, "the system edit menu must not appear next to the toolbar")
            var (panel, more) = try toolbar()
            #expect(primary(panel) == ["Copy", "Share", "Select all", "Web search"])
            #expect(more.isHidden)
            #expect(providers().isEmpty)

            let offered = TextServiceMenuBuilder(
                speech: [UICommand(title: "Speak", action: #selector(TextServiceResponder.speakService(_:))),
                         UICommand(title: "Pause", action: #selector(TextServiceResponder.refusedService(_:)))],
                services: [UICommand(title: "Other service", action: #selector(TextServiceResponder.otherService(_:)))])
            web.buildMenu(with: offered)
            #expect(offered.replacedRoot)
            (panel, more) = try toolbar()
            #expect(primary(panel) == ["Copy", "Share", "Select all", "Web search"])
            try #require(!more.isHidden)
            more.sendActions(for: .touchUpInside); panel.superview?.layoutIfNeeded()
            let popup: UIScrollView = try #require(find("shownotesSelectionOverflow", in: window))
            let overflow = popup.subviews.compactMap { $0 as? UIButton }.filter { !$0.isHidden }
            #expect(!popup.isHidden)
            #expect(overflow.map { $0.title(for: .normal) ?? "" } == ["Speak", "Other service"])
            #expect(overflow.allSatisfy { $0.accessibilityIdentifier?.hasPrefix("shownotesSelection-provider-") == true })
            let speak = try #require(overflow.first)
            speak.sendActions(for: .touchUpInside)
            #expect(services.performed == ["speak"])
            #expect(prepared == 1)
            // The service runs on the current range; the toolbar retires and
            // the shownotes and their selection stay as they were.
            #expect((find("shownotesSelection-share", in: window) as UIButton?) == nil)
            let selection = try await web.evaluateJavaScript("getSelection().toString()") as? String ?? ""
            #expect(selection.contains("Selectableword") && selection.contains("Text link"))
        }
    }
}

/// A responder above the shownotes that implements controlled text services.
private final class TextServiceResponder: UIView {
    private(set) var performed: [String] = []
    @objc func speakService(_ sender: Any?) { performed.append("speak") }
    @objc func otherService(_ sender: Any?) { performed.append("other") }
    @objc func refusedService(_ sender: Any?) { performed.append("refused") }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(refusedService(_:)) { return false }
        if action == #selector(speakService(_:)) || action == #selector(otherService(_:)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// The context-menu builder UIKit hands `buildMenu(with:)`, reduced to the
/// speech and services menus the shownotes toolbar reads.
private final class TextServiceMenuBuilder: NSObject, UIMenuBuilder {
    private let menus: [UIMenu.Identifier: UIMenu]
    private(set) var replacedRoot = false
    init(speech: [UICommand], services: [UICommand] = []) {
        var menus: [UIMenu.Identifier: UIMenu] = [:]
        if !speech.isEmpty { menus[.speech] = UIMenu(options: .displayInline, children: speech) }
        if !services.isEmpty { menus[.services] = UIMenu(options: .displayInline, children: services) }
        self.menus = menus
    }
    var system: UIMenuSystem { .context }
    func menu(for identifier: UIMenu.Identifier) -> UIMenu? { menus[identifier] }
    func action(for identifier: UIAction.Identifier) -> UIAction? { nil }
    func __command(forAction action: Selector, propertyList: Any?) -> UICommand? { nil }
    func replace(menu replacedIdentifier: UIMenu.Identifier, with replacementMenu: UIMenu) {}
    func replaceChildren(ofMenu parentIdentifier: UIMenu.Identifier, from childrenBlock: ([UIMenuElement]) -> [UIMenuElement]) {
        if parentIdentifier == .root { replacedRoot = childrenBlock([UICommand(title: "Copy", action: #selector(UIResponderStandardEditActions.copy(_:)))]).isEmpty }
    }
    func replace(menu replacedIdentifier: UIMenu.Identifier, with replacementElements: [UIMenuElement]) {}
    func replace(action replacedIdentifier: UIAction.Identifier, with replacementElements: [UIMenuElement]) {}
    func __replaceCommand(forAction replacedAction: Selector, propertyList replacedPropertyList: Any?, with replacementElements: [UIMenuElement]) {}
    func insertSibling(_ siblingMenu: UIMenu, beforeMenu siblingIdentifier: UIMenu.Identifier) {}
    func insertElements(_ insertedElements: [UIMenuElement], beforeMenu siblingIdentifier: UIMenu.Identifier) {}
    func insertElements(_ insertedElements: [UIMenuElement], afterMenu siblingIdentifier: UIMenu.Identifier) {}
    func insertSibling(_ siblingMenu: UIMenu, afterMenu siblingIdentifier: UIMenu.Identifier) {}
    func insertChild(_ childMenu: UIMenu, atStartOfMenu parentIdentifier: UIMenu.Identifier) {}
    func insertElements(_ insertedElements: [UIMenuElement], beforeAction siblingIdentifier: UIAction.Identifier) {}
    func insertElements(_ insertedElements: [UIMenuElement], afterAction siblingIdentifier: UIAction.Identifier) {}
    func __insert(_ insertedElements: [UIMenuElement], beforeCommandForAction siblingAction: Selector, propertyList siblingPropertyList: Any?) {}
    func __insert(_ insertedElements: [UIMenuElement], afterCommandForAction siblingAction: Selector, propertyList siblingPropertyList: Any?) {}
    func insertElements(_ childElements: [UIMenuElement], atStartOfMenu parentIdentifier: UIMenu.Identifier) {}
    func insertChild(_ childMenu: UIMenu, atEndOfMenu parentIdentifier: UIMenu.Identifier) {}
    func insertElements(_ childElements: [UIMenuElement], atEndOfMenu parentIdentifier: UIMenu.Identifier) {}
    func remove(menu removedIdentifier: UIMenu.Identifier) {}
    func remove(action removedIdentifier: UIAction.Identifier) {}
    func __removeCommand(forAction removedAction: Selector, propertyList removedPropertyList: Any?) {}
}

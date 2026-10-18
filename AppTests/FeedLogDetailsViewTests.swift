import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct FeedLogDetailsViewTests {
    private func details(title: String? = "Podcast", diagnostic: String? = "Permission denied") -> FeedLogDetails {
        let log = FeedLibraryLog(feedID: 1, date: .distantPast, title: title, kind: .failure(.io(code: 13)), detail: diagnostic)
        return FeedLogDetails(log: log, feed: nil, text: Appearance.text)
    }
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: type) }.first
    }
    private func layout(_ controller: UIViewController, width: CGFloat = 402, height: CGFloat = 874) {
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    @Test func originalSectionsWordingOrderingAndFieldCopyActions() throws {
        var copied: [String] = []
        let value = details()
        let controller = FeedLogDetailsDialog.make(value) { copied.append($0) }
        layout(controller)
        let body = try #require(element("feedLogDetailsBody", in: controller.view, as: FeedLogDetailsBody.self))
        body.layoutIfNeeded()
        let ids = ["feedLogPodcast", "feedLogStatus", "feedLogTechnical", "feedLogURL"]
        let expected = ["Podcast", "IO error", "Permission denied", "unknown"]
        var end: CGFloat = 0
        for (index, id) in ids.enumerated() {
            let heading = try #require(element(id + "Heading", in: body, as: UILabel.self))
            let label = try #require(element(id, in: body, as: UILabel.self))
            // Values use secondary text, visibly softer than the primary-coloured headings, in light and dark.
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                var value: CGFloat = 0, headingValue: CGFloat = 0
                #expect(label.textColor.resolvedColor(with: traits).getWhite(&value, alpha: nil))
                #expect(heading.textColor.resolvedColor(with: traits).getWhite(&headingValue, alpha: nil))
                #expect(style == .dark ? value < headingValue - 0.1 : value > headingValue + 0.1)
            }
            // Heading/value pairs stack in source order, values aligned with their heading.
            #expect(heading.frame.minY >= end - 0.5 && (index > 0 || heading.frame.minY > 0))
            #expect(label.frame.minY >= heading.frame.maxY - 0.5 && abs(label.frame.minX - heading.frame.minX) < 1 && label.frame.minX > 0)
            #expect(heading.font.fontName == "Roboto-Medium" && heading.font.pointSize == 16)
            #expect(label.text == expected[index]); end = label.frame.maxY
        }
        #expect(body.bounds.height >= end && body.bounds.height - end <= 32, "Body fits its content with a bottom margin")
        for id in ["feedLogTechnical", "feedLogURL"] {
            let control = try #require(element(id + "Copy", in: body, as: UIControl.self))
            control.sendActions(for: .touchUpInside)
        }
        #expect(copied == ["Permission denied", "unknown"])
        let copyButton = try #require(element("feedLogDetailsCopy", in: controller.view, as: UIButton.self))
        #expect(copyButton.isEnabled) // Field copying never consumes/dismisses dialog actions.
        let technical = try #require(element("feedLogTechnical", in: body, as: UILabel.self))
        let accessibilityCopy = try #require(technical.accessibilityCustomActions?.first)
        #expect(accessibilityCopy.actionHandler?(accessibilityCopy) == true)
        #expect(copied.last == "Permission denied")
        copyButton.sendActions(for: .touchUpInside)
        #expect(copied.last == value.clipboard && !copyButton.isEnabled)
    }

    /// The server's failed refresh (a server library): Android's sections with the server's words, then when each side last
    /// refreshed, stacked in order without overlap or clipping at phone, Duo and tablet widths, in both directions.
    @Test func theServersFailureWithWhenEachSideLastRefreshed() throws {
        var feed = LibraryFeed(id: 7, source: "https://example.test/feed.xml", metadata: ParsedFeed(format: .rss, title: "Podcast"), episodes: [])
        feed.serverRefresh = ServerRefreshStatus(lastAttempt: Date(timeIntervalSince1970: 1_700_000_000), label: "parser_exception")
        feed.localRefreshAttempt = Date(timeIntervalSince1970: 1_700_003_600)
        let value = try #require(FeedLogDetails.refreshFailure(latestLog: nil, feed: feed, text: Appearance.text, date: { _ in "date" }))
        #expect(value.origins == ["The server: Failed (date)", "This device: Successful (date)"])
        let controller = FeedLogDetailsDialog.make(value) { _ in }
        for width in [320, 402, 600, 834] as [CGFloat] {
            for rtl in [false, true] {
                controller.loadViewIfNeeded()
                controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                layout(controller, width: width)
                let body = try #require(element("feedLogDetailsBody", in: controller.view, as: FeedLogDetailsBody.self))
                body.semanticContentAttribute = controller.view.semanticContentAttribute
                body.setNeedsLayout(); body.layoutIfNeeded()
                let ids = ["feedLogPodcast", "feedLogStatus", "feedLogTechnical", "feedLogURL", "feedLogOrigins"]
                var end: CGFloat = 0
                for id in ids {
                    let heading = try #require(element(id + "Heading", in: body, as: UILabel.self))
                    let label = try #require(element(id, in: body, as: UILabel.self))
                    #expect(heading.frame.minY >= end - 0.5 && label.frame.minY >= heading.frame.maxY - 0.5, "\(id) \(width) rtl=\(rtl)")
                    #expect(label.frame.minX > 0 && label.frame.maxX < body.bounds.width, "\(id) side margins")
                    let needed = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude)).height
                    #expect(needed <= label.frame.height + 0.5, "\(id) not clipped")
                    #expect(label.textAlignment == (rtl ? .right : .left))
                    end = label.frame.maxY
                }
                #expect(element("feedLogTechnical", in: body, as: UILabel.self)?.text == "")
                #expect(element("feedLogOrigins", in: body, as: UILabel.self)?.text == "The server: Failed (date)\nThis device: Successful (date)")
                #expect(body.bounds.height >= end)
            }
        }
        #expect(value.clipboard.hasSuffix("Last refresh: \nThe server: Failed (date)\nThis device: Successful (date)"))
        // This device's own failure (any library) shows no such section.
        #expect(element("feedLogOrigins", in: FeedLogDetailsDialog.make(details()) { _ in }.view, as: UILabel.self) == nil)
    }

    @Test func missingTitleLongDetailsRTLAndShortViewportRetainScrollableBodyAndPinnedActions() throws {
        let controller = FeedLogDetailsDialog.make(details(title: nil, diagnostic: String(repeating: "long diagnostic line\n", count: 80))) { _ in }
        for width in [320, 402, 834] as [CGFloat] {
            for rtl in [false, true] {
                controller.loadViewIfNeeded()
                controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                layout(controller, width: width, height: 360)
                let body = try #require(element("feedLogDetailsBody", in: controller.view, as: FeedLogDetailsBody.self))
                body.setNeedsLayout(); body.layoutIfNeeded()
                #expect(element("feedLogPodcast", in: body, as: UILabel.self) == nil)
                let heading = try #require(element("feedLogStatusHeading", in: body, as: UILabel.self))
                #expect(heading.frame.minY > 0 && heading.frame.minY < 48, "Status is the first section when there is no podcast title")
                #expect(heading.frame.minX > 0 && heading.frame.maxX < body.bounds.width, "Heading keeps side margins")
                #expect(heading.textAlignment == (rtl ? .right : .left))
                let scroll = try #require(body.superview as? UIScrollView)
                #expect(scroll.contentSize.height > scroll.bounds.height)
                let ok = try #require(element("feedLogDetailsOK", in: controller.view, as: UIButton.self))
                let actionFrame = ok.convert(ok.bounds, to: controller.view)
                let bodyViewport = scroll.convert(scroll.bounds, to: controller.view)
                #expect(actionFrame.minY >= bodyViewport.maxY)
                #expect(controller.view.bounds.contains(actionFrame))
                scroll.contentOffset.y = scroll.contentSize.height - scroll.bounds.height
                #expect(ok.convert(ok.bounds, to: controller.view) == actionFrame)
                #expect(actionFrame.minY >= scroll.convert(scroll.bounds, to: controller.view).maxY)
            }
        }
    }

    @Test func ordinaryMessageStillUsesItsAttributedLabelAndConfirmAction() throws {
        var confirmed = 0
        let controller = SourceMessageController(title: "Existing message", message: "First line", details: "Second line") { confirmed += 1 }
        layout(controller)
        let label = try #require(element("sourceMessage", in: controller.view, as: UILabel.self))
        #expect(label.attributedText?.string == "First line\n\nSecond line")
        #expect(label.frame.minX > 0 && label.frame.width > 0)
        let button = try #require(element("sourceMessageOK", in: controller.view, as: UIButton.self))
        button.sendActions(for: .touchUpInside)
        #expect(confirmed == 1 && !button.isEnabled)
    }

    @Test func presentedDialogFieldCopiesStayOpenAndTerminalActionsDismiss() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); window.rootViewController = host
        window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); window.isHidden = true; previousKey?.makeKey() }
        for action in ["feedLogDetailsCopy", "feedLogDetailsOK", "escape"] {
            var copied: [String] = []
            let value = details()
            let dialog = FeedLogDetailsDialog.make(value) { copied.append($0) }
            host.present(dialog, animated: false)
            dialog.view.layoutIfNeeded()
            #expect(host.presentedViewController === dialog)
            let field = try #require(element("feedLogTechnicalCopy", in: dialog.view, as: UIControl.self))
            field.sendActions(for: .touchUpInside)
            #expect(copied == ["Permission denied"] && host.presentedViewController === dialog)
            if action == "escape" { #expect(dialog.accessibilityPerformEscape()) }
            else {
                let button = try #require(element(action, in: dialog.view, as: UIButton.self))
                button.sendActions(for: .touchUpInside)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while host.presentedViewController != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(host.presentedViewController == nil)
            #expect(copied == (action == "feedLogDetailsCopy" ? ["Permission denied", value.clipboard] : ["Permission denied"]))
        }
    }
}

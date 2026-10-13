import UIKit
import Testing
@testable import NotTennaPod

@MainActor
@Suite(.serialized)
struct MessageTitleViewTests {
    @Test func recordedTabletWidthsRespectContentRequestAndMinimum() throws {
        for (size, shortWidth, fillingWidth, clockWidth): (CGSize, CGFloat, CGFloat, CGFloat) in [
            (CGSize(width: 640, height: 960), 464, 532, 532),
            // These unmounted views have no system insets:640-48-76 leaves516.
            // Android's observed67-point system insets leave449, so its minimum480 wins.
            (CGSize(width: 960, height: 640), 480, 532, 516),
            (CGSize(width: 834, height: 1210), 552, 552, 552),
            (CGSize(width: 1280, height: 960), 528, 532, 532)
        ] {
            let short = SourceMessageController(message: "Short message.")
            let long = SourceMessageController(message: String(repeating: "This recording-only message checks the original dialog's wrapping and requested width. ", count: 20))
            let clock = SleepTimerTimeRangeController(from: 22, to: 6) { _, _ in }
            let choice = SourceSingleChoiceController(title: "Choose default page", identifier: "sizingChoice",
                choices: ["Home", "Queue", "Inbox", "Subscriptions", "All episodes", "Downloads", "Playback history"].map { ($0, $0) },
                selectedIndex: 0) { _ in }
            for (controller, id, expected): (UIViewController, String, CGFloat) in [
                (short, "sourceMessageContent", shortWidth), (long, "sourceMessageContent", fillingWidth),
                (clock, "sourceMessageContent", clockWidth), (choice, "sizingChoiceContent", fillingWidth)
            ] {
                normalText(controller)
                controller.view.frame = CGRect(origin: .zero, size: size)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let content = try #require(element(id, in: controller.view, as: UIView.self))
                // Dialog width matches the Android dialog to within an imperceptible amount.
                #expect(abs(content.bounds.width - expected) <= 2)
            }
        }
    }
    @Test func minimumWidthExpansionRetainsOriginalPreferredWidthTitleFallback() throws {
        // Android original builder at960x1280:643-point final panel,18sp title
        // retained from its532-point preferred-width first measurement.
        let text = "Choose the default page for your podcast library"
        let message = SourceMessageController(title: text, message: "Short message.")
        let choice = SourceSingleChoiceController(title: text, identifier: "expandedChoice",
            choices: [("home", "Home")], selectedIndex: 0) { _ in }
        for (controller, identifier): (UIViewController, String) in [
            (message, "sourceMessageTitle"), (choice, "expandedChoiceTitle")
        ] {
            normalText(controller)
            controller.view.frame = CGRect(x: 0, y: 0, width: 960, height: 1280)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let title = try #require(element(identifier, in: controller.view, as: UILabel.self))
            #expect(title.font.pointSize == 18)
            #expect(title.accessibilityLabel == text)
        }
    }
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func normalText(_ controller: UIViewController) {
        controller.loadViewIfNeeded()
        controller.view.traitOverrides.preferredContentSizeCategory = .large
    }
    private func layout(_ controller: UIViewController, width: CGFloat) {
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 700)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }
    @MainActor private final class PaddedBody: UIView {
        let marker = UILabel()
        init() {
            super.init(frame: .zero)
            marker.text = "Custom content"; addSubview(marker)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 100) }
        override func layoutSubviews() {
            super.layoutSubviews()
            marker.frame = CGRect(x: 24, y: 24, width: max(0, bounds.width - 48), height: 24)
        }
    }
    @Test(arguments: [false, true], [false, true])
    func messageSpacersDoNotDuplicateCustomContentPadding(custom: Bool, hasTitle: Bool) throws {
        let supplied = custom ? PaddedBody() : nil
        let controller = SourceMessageController(title: hasTitle ? "Warning" : nil, message: custom ? "" : "Body text",
            positive: .init(title: "OK", identifier: "OK"), customBody: supplied)
        normalText(controller); layout(controller, width: 320)
        let content: UIView = try #require(supplied ?? element("sourceMessage", in: controller.view, as: UILabel.self))
        let viewport = try #require(content.superview as? UIScrollView)
        let frame = content.convert(content.bounds, to: controller.view)
        let viewportFrame = viewport.convert(viewport.bounds, to: controller.view)
        // Visible spacing: no doubled padding around custom content, no overlap with the title.
        #expect(abs((frame.minY - viewportFrame.minY) - (!custom && !hasTitle ? 18 : 0)) <= 1)
        if hasTitle {
            let title = try #require(element("sourceMessageTitle", in: controller.view, as: UILabel.self))
            #expect(abs((frame.minY - title.convert(title.bounds, to: controller.view).maxY) - (custom ? 0 : 16)) <= 1)
            #expect(title.bounds.height >= title.font.lineHeight)
        }
        if let supplied {
            supplied.layoutIfNeeded()
            #expect(abs((supplied.marker.convert(supplied.marker.bounds, to: controller.view).minY - frame.minY) - 24) <= 1)
            #expect(viewport.contentSize.height >= 100 - 0.5)
        }
    }
    @Test func freshFittingTitlesKeepSingleLineAndOriginalAccessibilityText() throws {
        for text in ["Warning", "First line\nSecond line", "First\rSecond"] {
            let controller = SourceMessageController(title: text, message: "Body text")
            normalText(controller)
            layout(controller, width: 700)
            let title = try #require(element("sourceMessageTitle", in: controller.view, as: UILabel.self))
            #expect(title.numberOfLines == 1 && title.font.pointSize == 24)
            #expect(title.text == text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "\u{feff}"))
            #expect(title.accessibilityLabel == text)
        }
    }
    @Test func customContentDoesNotClipTheFallbackTitle() throws {
        let body = PaddedBody()
        let controller = SourceMessageController(title: "A long warning that requires two title lines",
            message: "", positive: .init(title: "OK", identifier: "OK"), customBody: body)
        normalText(controller); layout(controller, width: 320)
        let title = try #require(element("sourceMessageTitle", in: controller.view, as: UILabel.self))
        try #require(title.numberOfLines == 2 && title.font.pointSize == 18)
        let measured = title.sizeThatFits(CGSize(width: title.bounds.width, height: .greatestFiniteMagnitude))
        #expect(title.bounds.height >= ceil(measured.height))
        #expect(body.convert(body.bounds, to: controller.view).minY >= title.convert(title.bounds, to: controller.view).maxY - 0.5)
    }
    @Test(arguments: [false, true])
    func fallbackPersistsAcrossWideningWithoutReplacingBodyOrActions(rtl: Bool) throws {
        let text = "First line\nSecond line\nThird line"
        let controller = SourceMessageController(title: text,
            message: String(repeating: "A long body with independently scrolling content.\n", count: 80))
        normalText(controller)
        controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        layout(controller, width: 700)
        let title = try #require(element("sourceMessageTitle", in: controller.view, as: UILabel.self))
        let message = try #require(element("sourceMessage", in: controller.view, as: UILabel.self))
        let body = try #require(message.superview as? UIScrollView)
        let action = try #require(element("sourceMessageOK", in: controller.view, as: UIButton.self))
        #expect(title.numberOfLines == 1 && title.font.pointSize == 24)
        body.contentOffset.y = 100
        layout(controller, width: 188)
        #expect(title.numberOfLines == 2 && title.font.pointSize == 18)
        #expect(title.text == text && title.accessibilityLabel == text)
        #expect(title.lineBreakMode == .byTruncatingTail)
        #expect(title.bounds.height <= ceil(title.font.lineHeight * 2))
        #expect(title.convert(title.bounds, to: controller.view).maxY <= body.convert(body.bounds, to: controller.view).minY)
        layout(controller, width: 700)
        #expect(title.numberOfLines == 2 && title.font.pointSize == 18)
        #expect(element("sourceMessage", in: controller.view, as: UILabel.self) === message)
        #expect(element("sourceMessageOK", in: controller.view, as: UIButton.self) === action)
        #expect(body.contentOffset.y == 100)
        let fresh = SourceMessageController(title: text, message: "Body text")
        normalText(fresh)
        layout(fresh, width: 700)
        let freshTitle = try #require(element("sourceMessageTitle", in: fresh.view, as: UILabel.self))
        #expect(freshTitle.numberOfLines == 1 && freshTitle.font.pointSize == 24)
    }
    @Test func localTextSizeChangeUsesLocalMetricsAndRetainsFallback() async throws {
        let text = "Warning message"
        let controller = SourceMessageController(title: text, message: "Body text")
        normalText(controller)
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            layout(controller, width: 320)
            let title = try #require(element("sourceMessageTitle", in: controller.view, as: UILabel.self))
            #expect(title.numberOfLines == 1 && title.font.pointSize == 24)
            controller.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            layout(controller, width: 320)
            try #require(title.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
            let initialBase = try #require(UIFont(name: "Roboto-Regular", size: 24))
            let initialScaled = UIFontMetrics(forTextStyle: .body).scaledFont(for: initialBase, compatibleWith: title.traitCollection)
            let scaledWidth = (text as NSString).size(withAttributes: [.font: initialScaled]).width
            try #require(scaledWidth > title.bounds.width, "This fixture must actually need fallback")
            let base = try #require(UIFont(name: "Roboto-Regular", size: 18))
            let expected = UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: title.traitCollection)
            #expect(title.numberOfLines == 2)
            #expect(title.font.pointSize == expected.pointSize && title.font.pointSize > 24)
            controller.view.traitOverrides.preferredContentSizeCategory = .large
            layout(controller, width: 320)
            #expect(title.font.pointSize == 18 && title.numberOfLines == 2)
        }
    }
    @Test func unresolvedWidthDoesNotTriggerFallbackAndCarriageReturnDoesNotAddALine() {
        let title = SourceDialogTitle("First\rSecond")
        title.traitOverrides.preferredContentSizeCategory = .large
        #expect(title.measuredSize(width: 0) == .zero)
        _ = title.measuredSize(width: 512)
        #expect(title.font.pointSize == 24 && title.numberOfLines == 1)
        _ = title.measuredSize(width: 80)
        let wide = title.measuredSize(width: 512)
        #expect(title.font.pointSize == 18 && title.numberOfLines == 2)
        #expect(wide.height <= ceil(title.font.lineHeight))
        #expect(title.accessibilityLabel == "First\rSecond")
    }
    @Test func emptyAndAbsentTitlesShareCompositionButWhitespaceIsNotDiscarded() throws {
        var frames: [CGRect] = []
        for text: String? in [nil, "", " "] {
            let controller = SourceMessageController(title: text, message: "Body text")
            normalText(controller); layout(controller, width: 320)
            let title = element("sourceMessageTitle", in: controller.view, as: UILabel.self)
            #expect((title != nil) == (text == " "))
            let action = try #require(element("sourceMessageOK", in: controller.view, as: UIButton.self))
            frames.append(action.convert(action.bounds, to: controller.view))
        }
        #expect(frames[0] == frames[1])
        #expect(frames[2] != frames[0])
    }
    @Test(arguments: [false, true], ["Warning", "الحلقة غير متاحة للاستماع الآن حاول مرة أخرى لاحقًا"])
    func alignmentUsesTheContainerLeadingEdge(rtl: Bool, text: String) {
        let title = SourceDialogTitle(text)
        title.traitOverrides.preferredContentSizeCategory = .large
        title.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        _ = title.measuredSize(width: 512)
        #expect(title.textAlignment == (rtl ? .right : .left))
        #expect(title.font.pointSize == 24 && title.numberOfLines == 1)
        _ = title.measuredSize(width: 80)
        #expect(title.textAlignment == (rtl ? .right : .left))
        #expect(title.font.pointSize == 18 && title.numberOfLines == 2)
    }

}

import UIKit
import Testing
@testable import NotTennaPod

@MainActor
@Suite(.serialized)
struct MessageActionReachabilityTests {
    @Test(arguments: [false, true])
    func longBodyGetsSpaceBeforeStackedActionsExpand(rtl: Bool) throws {
        for longBody in [false, true] {
            let controller = SourceMessageController(title: "Warning",
                message: longBody ? String(repeating: "Message body line\n", count: 80) : "Body text",
                positive: .init(title: "Continue", identifier: "positive"),
                negative: .init(title: "Cancel", identifier: "negative"),
                neutral: .init(title: "More information", identifier: "neutral"))
            controller.loadViewIfNeeded()
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let label = try #require(element("sourceMessage", in: controller.view, as: UILabel.self))
            let body = try #require(label.superview as? UIScrollView)
            let actions = try #require(element("sourceMessageActions", in: controller.view, as: UIScrollView.self))
            let buttons = try ["positive", "negative", "neutral"].map {
                try #require(element($0, in: controller.view, as: UIButton.self))
            }
            if longBody {
                // A long message keeps most of the dialog readable and scrollable,
                // while the actions area still shows at least one whole button.
                #expect(body.bounds.height > 150 && body.contentSize.height > body.bounds.height)
                #expect(actions.isScrollEnabled)
                #expect(actions.bounds.height >= buttons.map(\.bounds.height).min()! - 0.5)
            } else {
                // A short message leaves all three stacked actions visible without scrolling.
                #expect(!actions.isScrollEnabled && actions.contentSize.height <= actions.bounds.height + 0.5)
                #expect(body.bounds.height >= label.intrinsicContentSize.height - 0.5)
            }
            // Message and actions do not overlap.
            #expect(body.convert(body.bounds, to: controller.view).maxY <= actions.convert(actions.bounds, to: controller.view).minY + 0.5)
            let actionOffset = actions.contentOffset
            body.contentOffset.y = max(0, body.contentSize.height - body.bounds.height)
            #expect(actions.contentOffset == actionOffset)
        }
    }

    @Test(arguments: ["positive", "negative", "neutral"], [false, true])
    func extremeHeightKeepsContentAndActionsReachableAndRestoresScrollPositions(selected: String, rtl: Bool) async throws {
        var performed: [String] = []
        func action(_ id: String, _ title: String) -> SourceMessageController.Action {
            .init(title: title, identifier: id, perform: { performed.append(id) })
        }
        let controller = SourceMessageController(title: "A warning title that needs two lines",
            message: Array(repeating: "Message body line", count: 60).joined(separator: "\n"),
            positive: action("positive", "Continue"), negative: action("negative", "Cancel"),
            neutral: action("neutral", "More information"))
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            controller.view.traitOverrides.preferredContentSizeCategory = .large
            @MainActor func resize(_ height: CGFloat) {
                controller.view.frame = CGRect(x: 0, y: 100, width: 320, height: height)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            }
            resize(600)
            let label = try #require(element("sourceMessage", in: controller.view, as: UILabel.self))
            let title = try #require(element("sourceMessageTitle", in: controller.view, as: UILabel.self))
            let body = try #require(label.superview as? UIScrollView)
            let actions = try #require(element("sourceMessageActions", in: controller.view, as: UIScrollView.self))
            let buttons = try ["positive", "negative", "neutral"].map {
                try #require(element($0, in: controller.view, as: UIButton.self))
            }
            let normalBodyFrame = body.convert(body.bounds, to: controller.view)
            let normalActionFrame = actions.convert(actions.bounds, to: controller.view)
            try #require(body.contentSize.height - body.bounds.height > 120)
            try #require(actions.contentSize.height - actions.bounds.height > 40)
            body.contentOffset.y = 120; actions.contentOffset.y = 40
            resize(160)
            // The viewport can show a complete control, but the ordinary allocator
            // cannot fit title + readable body + an action in it simultaneously.
            try #require(controller.view.bounds.height - 48 >= buttons[0].bounds.height)
            #expect(label.superview === body && element("sourceMessageActions", in: controller.view, as: UIScrollView.self) === actions)
            reveal(title)
            #expect(abs(visibleFrame(of: title, in: window).height - title.bounds.height) <= 1)
            let line = ceil(20 * label.font.pointSize / 14)
            for y in [CGFloat.zero, label.bounds.height - line] {
                let rect = CGRect(x: 0, y: y, width: label.bounds.width, height: line)
                reveal(rect, of: label)
                let expected = label.convert(rect, to: window)
                #expect(visibleFrame(of: label, in: window).intersection(expected).height >= line - 0.01)
            }
            for button in buttons {
                reveal(button)
                let frame = button.convert(button.bounds, to: window)
                #expect(abs(visibleFrame(of: button, in: window).height - frame.height) <= 1)
                let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
                #expect(hit === button || hit?.isDescendant(of: button) == true)
            }
            resize(600)
            #expect(body.contentOffset.y == 120 && actions.contentOffset.y == 40)
            #expect(body.convert(body.bounds, to: controller.view) == normalBodyFrame)
            #expect(actions.convert(actions.bounds, to: controller.view) == normalActionFrame)
            resize(160)
            let selectedButton = try #require(buttons.first { $0.accessibilityIdentifier == selected })
            reveal(selectedButton)
            let frame = selectedButton.convert(selectedButton.bounds, to: window)
            let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
            try #require(hit === selectedButton || hit?.isDescendant(of: selectedButton) == true)
            selectedButton.sendActions(for: .touchUpInside); selectedButton.sendActions(for: .touchUpInside)
            #expect(performed == [selected])
        }
    }

    @Test(arguments: [false, true], [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge])
    func overflowReadingSurvivesCollapsedBoundsAndGrowth(rtl: Bool, category: UIContentSizeCategory) async throws {
        let controller = SourceMessageController(title: "A long warning title that uses its fallback",
            message: Array(repeating: "Message body line", count: 80).joined(separator: "\n"))
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            controller.view.traitOverrides.preferredContentSizeCategory = category
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: rtl ? 5 : 30, bottom: 0, right: rtl ? 30 : 5)
            @MainActor func resize(_ size: CGSize) {
                controller.view.frame = CGRect(origin: CGPoint(x: 0, y: 100), size: size)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            }
            resize(CGSize(width: 360, height: 180))
            let label = try #require(element("sourceMessage", in: controller.view, as: UILabel.self))
            let title = try #require(element("sourceMessageTitle", in: controller.view, as: UILabel.self))
            let body = try #require(label.superview as? UIScrollView)
            let viewport = try #require(element("sourceMessageContent", in: controller.view, as: UIScrollView.self))
            try #require(viewport.isScrollEnabled && !body.isScrollEnabled)
            #expect(title.textAlignment == (rtl ? .right : .left))
            let visibleViewport = viewport.convert(viewport.bounds, to: controller.view)
            let safe = controller.view.bounds.inset(by: controller.view.safeAreaInsets)
            #expect(safe.contains(visibleViewport))
            reveal(CGRect(x: 0, y: 700, width: label.bounds.width, height: 20), of: label)
            let offset = viewport.contentOffset
            try #require(offset.y > 300)
            resize(.zero)
            resize(CGSize(width: 360, height: 180))
            #expect(viewport.contentOffset == offset)
            let readingY = viewport.convert(CGPoint(x: 0, y: viewport.bounds.minY), to: body).y
            try #require(readingY > 0 && readingY < body.contentSize.height - 600)
            resize(CGSize(width: 360, height: 600))
            #expect(!viewport.isScrollEnabled && body.isScrollEnabled)
            #expect(abs(body.contentOffset.y - readingY) <= 1)
            #expect(title.textAlignment == (rtl ? .right : .left))
        }
    }

    @Test(arguments: [false, true])
    func focusedCustomInputKeepsSelectionAndVisibleCaretThroughOverflow(rtl: Bool) async throws {
        let input = FeedURLEditInputView(value: Array(repeating: "https://example.com/feed", count: 35).joined(separator: "\n"))
        let controller = SourceMessageController(title: "Edit feed URL", message: "",
            positive: .init(title: "OK", identifier: "positive"), customBody: input)
        controller.avoidsKeyboard = true
        try await withViewTestWindow { host, window in
            defer { input.textView.resignFirstResponder() }
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            controller.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            @MainActor func resize(_ height: CGFloat) {
                controller.view.frame = CGRect(x: 0, y: 100, width: 360, height: height)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            }
            resize(180)
            let text = input.textView
            try #require(text.becomeFirstResponder())
            text.selectedRange = NSRange(location: (text.text as NSString).length, length: 0)
            let selection = text.selectedRange, value = text.text
            controller.revealTextPosition(text)
            let viewport = try #require(element("sourceMessageContent", in: controller.view, as: UIScrollView.self))
            try #require(viewport.isScrollEnabled)
            @MainActor func verifyCaret() throws {
                let selected = try #require(text.selectedTextRange)
                let caret = text.convert(text.caretRect(for: selected.end), to: window)
                #expect(visibleFrame(of: text, in: window).contains(caret))
                #expect(text.isFirstResponder && text.selectedRange == selection && text.text == value)
            }
            try verifyCaret()
            resize(600)
            try #require(!viewport.isScrollEnabled)
            try verifyCaret()
        }
    }

    private func reveal(_ rect: CGRect, of view: UIView) {
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                scroll.scrollRectToVisible(view.convert(rect, to: scroll), animated: false)
            }
            ancestor = current.superview
        }
    }

    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }

    private func visibleFrame(of view: UIView, in window: UIWindow) -> CGRect {
        var frame = view.convert(view.bounds, to: window)
        var ancestor = view.superview
        while let current = ancestor {
            if current.clipsToBounds { frame = frame.intersection(current.convert(current.bounds, to: window)) }
            ancestor = current.superview
        }
        return frame.intersection(window.bounds)
    }

    private func reveal(_ view: UIView) {
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                scroll.scrollRectToVisible(view.convert(view.bounds, to: scroll), animated: false)
            }
            ancestor = current.superview
        }
    }

    @Test(arguments: ["positive", "negative", "neutral"], [false, true])
    func stackedActionsRemainTappableInTruncatedFooter(selected: String, rtl: Bool) async throws {
        var performed: [String] = []
        func action(_ id: String, title: String) -> SourceMessageController.Action {
            .init(title: title, identifier: id, perform: { performed.append(id) })
        }
        let controller = SourceMessageController(title: "A warning\nwith a title\nthat wraps", message: "Body text",
            positive: action("positive", title: "Continue"), negative: action("negative", title: "Cancel"),
            neutral: action("neutral", title: "More information"))
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            @MainActor func resize(_ height: CGFloat) {
                controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: height)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            }
            resize(700)
            let buttons = try ["positive", "negative", "neutral"].map { id in
                try #require(element(id, in: controller.view, as: UIButton.self))
            }
            let normalFrames = buttons.map { $0.convert($0.bounds, to: controller.view) }
            #expect(normalFrames[0].minY < normalFrames[1].minY && normalFrames[1].minY < normalFrames[2].minY)
            resize(240)
            // This scenario has a positive but insufficient footer, not the separate
            // zero-footer allocation defect.
            try #require(buttons.contains { visibleFrame(of: $0, in: window).height < $0.bounds.height },
                         "The short fixture must actually clip an action before scrolling")
            for button in buttons {
                reveal(button)
                let frame = button.convert(button.bounds, to: window)
                let visible = visibleFrame(of: button, in: window)
                #expect(abs(visible.width - frame.width) <= 1 && abs(visible.height - frame.height) <= 1,
                        "Scrolling must expose the complete action, not only its center")
                let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
                #expect(hit === button || hit?.isDescendant(of: button) == true,
                        "Visible action must accept a touch: \(button.accessibilityIdentifier ?? "") frame=\(frame)")
            }
            resize(700)
            for (button, original) in zip(buttons, normalFrames) {
                let frame = button.convert(button.bounds, to: controller.view)
                #expect(abs(frame.minX - original.minX) <= 1 && abs(frame.minY - original.minY) <= 1)
                #expect(frame.size == original.size)
            }
            resize(240)
            let button = try #require(buttons.first { $0.accessibilityIdentifier == selected })
            reveal(button)
            let frame = button.convert(button.bounds, to: window)
            let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
            try #require(hit === button || hit?.isDescendant(of: button) == true)
            button.sendActions(for: .touchUpInside); button.sendActions(for: .touchUpInside)
            #expect(performed == [selected])
        }
    }
}

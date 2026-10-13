import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SearchFeedMenuTests {
    private func find<T: UIView>(_ id: String, _ root: UIView, as: T.Type = T.self) -> T? {
        if let value = root as? T, value.accessibilityIdentifier == id { return value }
        return root.subviews.lazy.compactMap { find(id, $0, as: T.self) }.first
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    @Test func contextActionsStayOrderedReachableAndDispatchAfterDismissal() async throws {
        let feed = LibraryFeed(id: 1, source: "https://example.org/feed", metadata: .init(format: .rss, title: "Long podcast title for the context menu"), episodes: [])
        var selected: SearchFeedMenu.Action?
        let controller = PopupMenuController(feed: feed) { selected = $0 }
        try await withViewTestWindow { host, _ in
            host.present(controller, animated: false)
            try await wait { controller.view.window != nil }
            controller.additionalSafeAreaInsets = .init(top: 0, left: 19, bottom: 10, right: 47)
            controller.view.frame.size = CGSize(width: 320, height: 190)
            controller.view.semanticContentAttribute = .forceRightToLeft
            controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let panel: UIView = try #require(find("searchFeedContextMenu", controller.view))
            #expect(controller.view.safeAreaLayoutGuide.layoutFrame.contains(panel.frame))
            let buttons = try SearchFeedMenu.actions(for: feed).map { action in
                try #require(find("searchFeedAction-\(action.rawValue)", controller.view, as: UIButton.self))
            }
            #expect(zip(buttons, buttons.dropFirst()).allSatisfy { $0.frame.maxY <= $1.frame.minY })
            let scroll = try #require(buttons.last?.superview as? UIScrollView)
            scroll.scrollRectToVisible(buttons.last!.frame, animated: false)
            #expect(scroll.bounds.intersects(buttons.last!.frame))
            #expect(buttons.last?.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            buttons.last?.sendActions(for: .touchUpInside)
            try await wait { selected == .share && host.presentedViewController == nil }
        }
    }
    @Test func tagDraftSurvivesKeyboardResizeAndCancelDoesNotSave() async throws {
        var feed = LibraryFeed(id: 1, source: "fixture", metadata: .init(format: .rss), episodes: [])
        feed.tags = (0..<30).map { "Long tag \($0)" } + ["#root"]
        var saved: [String]?
        let controller = FeedTagsController.make(feed: feed, suggestions: ["Existing"], bottomNavigation: false) { saved = $0 }
        try await withViewTestWindow { host, _ in
            host.present(controller, animated: false)
            try await wait { controller.view.window != nil }
            let field: UITextField = try #require(find("feedTagInput", controller.view))
            field.text = "Uncommitted draft"; field.becomeFirstResponder()
            controller.additionalSafeAreaInsets = .init(top: 0, left: 19, bottom: 0, right: 47)
            controller.view.semanticContentAttribute = .forceRightToLeft
            controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            controller.view.frame.size = CGSize(width: 420, height: 700)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            try await wait { controller.view.keyboardLayoutGuide.layoutFrame.minY > controller.view.safeAreaInsets.top + 100 }
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(field.text == "Uncommitted draft"); #expect(field.isFirstResponder)
            let body = try #require(find("feedTagsBody", controller.view, as: FeedTagsBody.self))
            #expect(body.minimumMessageViewportHeight >= field.bounds.height)
            let scroll = try #require(body.superview as? UIScrollView)
            #expect(scroll.bounds.contains(field.convert(field.bounds, to: scroll)))
            field.text = ""; field.sendActions(for: .editingChanged)
            body.textFieldDidBeginEditing(field); controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            scroll.contentOffset.y = 0; body.setNeedsLayout(); body.layoutIfNeeded()
            let dropdown: UIScrollView = try #require(find("feedTagSuggestions", controller.view))
            #expect(dropdown.isHidden)
            field.text = "Uncommitted draft"
            let cancel: UIButton = try #require(find("feedTagsCancel", controller.view))
            cancel.sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil }
            #expect(saved == nil)
        }
    }
    @Test func addRemoveSuggestionAndSaveIncludeUnsubmittedText() async throws {
        var feed = LibraryFeed(id: 1, source: "fixture", metadata: .init(format: .rss), episodes: [])
        feed.tags = ["First", "#root"]
        var saved: [String]?
        let controller = FeedTagsController.make(feed: feed, suggestions: ["Existing tag"], bottomNavigation: true) { saved = $0 }
        try await withViewTestWindow { host, _ in
            host.present(controller, animated: false); try await wait { controller.view.window != nil }
            let field: UITextField = try #require(find("feedTagInput", controller.view))
            let root: UIButton = try #require(find("feedTagsRoot", controller.view)); #expect(root.isHidden)
            let remove: UIButton = try #require(find("feedTagRemove-0", controller.view)); remove.sendActions(for: .touchUpInside)
            field.becomeFirstResponder(); controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let suggestion: UIButton = try #require(find("feedTagSuggestion-0", controller.view))
            suggestion.sendActions(for: .touchUpInside)
            #expect(field.text == "Existing tag")
            let add: UIButton = try #require(find("feedTagAdd", controller.view)); add.sendActions(for: .touchUpInside)
            #expect(field.text == "")
            field.text = " Pending "
            let confirm: UIButton = try #require(find("feedTagsSave", controller.view)); confirm.sendActions(for: .touchUpInside)
            try await wait { saved != nil && host.presentedViewController == nil }
            #expect(Set(saved ?? []) == Set(["Existing tag", "Pending", "#root"]))
        }
    }
    @Test(arguments: [false, true]) func tagChipsKeepSourceLookAndRemovalAfterResize(dark: Bool) async throws {
        // Material 1.12 Assist chip: visible 32dp inside 48dp, close icon 18dp,
        // 16dp leading text inset, 34dp trailing close area. Source XML/capture:
        // feed-settings-tags/android-saved-tags (420dpi, font scale 1).
        // Geometry is checked to within a point; sub-point differences are invisible.
        let body = FeedTagsBody(tags: ["Science", "Listening"], suggestions: [], showRoot: false)
        try await withViewTestWindow { host, _ in
            host.view.addSubview(body)
            body.overrideUserInterfaceStyle = dark ? .dark : .light
            body.traitOverrides.preferredContentSizeCategory = .large
            body.frame = CGRect(origin: .zero, size: body.sizeThatFits(CGSize(width: 342, height: 1000)))
            body.layoutIfNeeded()
            let surface: UIView = try #require(find("feedTagSurface-0", body))
            let remove: UIButton = try #require(find("feedTagRemove-0", body))
            let chip = try #require(surface.superview)
            let label = try #require(chip.subviews.compactMap { $0 as? UILabel }.first)
            #expect(abs(surface.bounds.height - 32) <= 1 && abs(chip.bounds.height - 48) <= 1)
            #expect(abs(surface.frame.midY - chip.bounds.midY) <= 1)
            #expect(abs(remove.bounds.width - 34) <= 1 && abs(remove.bounds.height - 32) <= 1)
            let icon = remove.imageRect(forContentRect: remove.bounds).size
            #expect(abs(icon.width - 18) <= 1 && abs(icon.height - 18) <= 1)
            #expect(abs(label.frame.minX - 16) <= 1 && label.frame.maxX <= remove.frame.minX + 0.5)
            #expect(remove.accessibilityLabel == "Delete Listening")
            let expectedFill = dark ? UIColor(red: 35/255, green: 49/255, blue: 65/255, alpha: 1)
                : UIColor(red: 222/255, green: 238/255, blue: 248/255, alpha: 1)
            let component: CGFloat = dark ? 204/255 : 68/255
            let expectedInk = UIColor(red: component, green: component, blue: component, alpha: 1)
            // The Android chip shades, approximately (an exact shade is not something a person checks).
            func near(_ actual: UIColor?, _ expected: UIColor) -> Bool {
                var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), e: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
                guard actual?.resolvedColor(with: body.traitCollection).getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3) == true,
                      expected.getRed(&e.0, green: &e.1, blue: &e.2, alpha: &e.3) else { return false }
                return abs(a.0 - e.0) <= 12 / 255 && abs(a.1 - e.1) <= 12 / 255 && abs(a.2 - e.2) <= 12 / 255
            }
            #expect(near(surface.backgroundColor, expectedFill))
            #expect(near(remove.tintColor, expectedInk))
            #expect(near(surface.layer.borderColor.map { UIColor(cgColor: $0) }, expectedInk))
            let font = try #require(label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            #expect(font.fontName == "Roboto-Medium" && font.pointSize == 14)
            body.semanticContentAttribute = .forceRightToLeft
            body.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            body.frame.size = body.sizeThatFits(CGSize(width: 260, height: 1000))
            body.setNeedsLayout(); body.layoutIfNeeded()
            let second: UIView = try #require(find("feedTagSurface-1", body))
            #expect(surface.convert(surface.bounds, to: body).minX > second.convert(second.bounds, to: body).minX)
            #expect(remove.frame.minX <= 0.5 && label.frame.minX >= remove.frame.maxX - 0.5)
            #expect(chip.bounds.contains(surface.frame) && chip.bounds.contains(remove.frame))
            #expect(surface.bounds.height > 32)
            let hit = body.hitTest(remove.convert(CGPoint(x: remove.bounds.midX, y: remove.bounds.midY), to: body), with: nil)
            #expect(hit === remove)
            remove.sendActions(for: .touchUpInside)
            #expect(body.draft.displayed == ["Science"])
            let remaining: UIButton = try #require(find("feedTagRemove-0", body))
            #expect(remaining.accessibilityLabel == "Delete Science")
            remaining.sendActions(for: .touchUpInside)
            #expect(body.draft.displayed.isEmpty)
        }
    }
}

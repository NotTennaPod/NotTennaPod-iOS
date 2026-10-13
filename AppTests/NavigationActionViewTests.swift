import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct NavigationActionViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: T.self) }.first
    }
    private func mounted(custom: Bool, nondefault: Bool = false, _ run: @MainActor (UIViewController, NavigationPreferenceStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NavigationActions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NavigationPreferenceStore(file: directory.appendingPathComponent("prefs.json"))
        if nondefault {
            var initial = NavigationCustomization(preferences: store.value)
            initial.move(from: 1, to: 3)
            try store.update(initial.confirmed(updating: store.value))
        }
        let controller: UIViewController = custom ? NavigationCustomizationController(preferences: store) : DefaultPageController(preferences: store)
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.traitOverrides.preferredContentSizeCategory = .large
            try await run(controller, store)
        }
    }
    private func layout(_ controller: UIViewController, width: CGFloat) {
        controller.view.frame = CGRect(x: 0, y: 100, width: width, height: 400)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }
    private func reveal(_ button: UIView) {
        var parent = button.superview
        while let view = parent {
            if let scroll = view as? UIScrollView { scroll.scrollRectToVisible(button.convert(button.bounds, to: scroll), animated: false) }
            parent = view.superview
        }
    }
    private func visible(_ button: UIView, in root: UIView) -> CGRect {
        var frame = button.convert(button.bounds, to: root), parent = button.superview
        while let view = parent {
            if view.clipsToBounds { frame = frame.intersection(view.convert(view.bounds, to: root)) }
            parent = view.superview
        }
        return frame
    }
    @Test(arguments: [false, true], [false, true])
    func normalActionsUseSourceInsetsAndTrailingCancel(custom: Bool, rtl: Bool) async throws {
        try await mounted(custom: custom) { controller, _ in
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            layout(controller, width: 700)
            let ids = custom ? ["customizeOK", "customizeCancel", "customizeReset"] : ["defaultPageCancel"]
            let buttons = try ids.map { try #require(find($0, in: controller.view, as: UIButton.self)) }
            let panel = try #require(buttons[0].superview)
            for button in buttons {
                // Whole wording visible, full-height touch target, not clipped.
                let text = try #require(button.titleLabel)
                #expect(button.bounds.width >= ceil(text.intrinsicContentSize.width) - 0.5)
                #expect(button.bounds.height >= 48 - 0.5)
                #expect(abs(visible(button, in: controller.view).height - button.bounds.height) <= 0.5)
                #expect(panel.bounds.contains(button.frame))
            }
            // The first action sits at the trailing edge; Reset (customization only) at the leading edge,
            // Cancel just before OK, none overlapping.
            let midX = panel.bounds.midX
            #expect(rtl ? buttons[0].frame.midX < midX : buttons[0].frame.midX > midX)
            if custom {
                #expect(rtl ? buttons[2].frame.midX > midX : buttons[2].frame.midX < midX)
                #expect(rtl ? buttons[1].frame.minX >= buttons[0].frame.maxX : buttons[1].frame.maxX <= buttons[0].frame.minX)
                #expect(rtl ? buttons[1].frame.maxX <= buttons[2].frame.minX : buttons[1].frame.minX >= buttons[2].frame.maxX)
                let gap = rtl ? buttons[1].frame.minX - buttons[0].frame.maxX : buttons[0].frame.minX - buttons[1].frame.maxX
                #expect(gap < 24)
            }
        }
    }
    @Test(arguments: [false, true])
    func localButtonTypographyUpdatesWithoutRecreatingActions(custom: Bool) async throws {
        try await mounted(custom: custom) { controller, store in
            layout(controller, width: 700)
            let id = custom ? "customizeCancel" : "defaultPageCancel"
            let button = try #require(find(id, in: controller.view, as: UIButton.self))
            let label = try #require(button.titleLabel), original = store.value
            for category: UIContentSizeCategory in [.accessibilityExtraExtraExtraLarge, .large, .accessibilityExtraExtraExtraLarge, .large] {
                label.traitOverrides.preferredContentSizeCategory = category
                let expected = Appearance.font(14, medium: true, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while label.font.pointSize != expected.pointSize || button.bounds.height < ceil(expected.lineHeight + 20) {
                    if ContinuousClock.now >= deadline { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(label.font.pointSize == expected.pointSize)
                // The action grows with the text size and stays fully visible.
                #expect(button.bounds.height >= max(48, ceil(expected.lineHeight + 20)) - 0.5)
                #expect(find(id, in: controller.view, as: UIButton.self) === button)
                #expect(abs(visible(button, in: controller.view).height - button.bounds.height) <= 0.5)
                #expect(store.value == original)
            }
        }
    }
    @Test(arguments: ["customizeOK", "customizeCancel", "customizeReset"], [false, true])
    func stackedActionsRemainReachableAndKeepDraftSemantics(selected: String, rtl: Bool) async throws {
        try await mounted(custom: true, nondefault: selected == "customizeReset") { controller, store in
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            layout(controller, width: 700)
            let editor = try #require(controller as? NavigationCustomizationController)
            let list = try #require(find("customizeList", in: controller.view, as: UICollectionView.self))
            let original = store.value
            editor.collectionView(list, moveItemAt: IndexPath(item: 1, section: 0), to: IndexPath(item: 2, section: 0))
            list.reloadData(); list.layoutIfNeeded()
            let ids = ["customizeOK", "customizeCancel", "customizeReset"]
            let buttons = try ids.map { try #require(find($0, in: controller.view, as: UIButton.self)) }
            layout(controller, width: 230)
            // Narrow width stacks the actions vertically in order, without overlap.
            #expect(buttons[0].frame.maxY <= buttons[1].frame.minY + 0.5 && buttons[1].frame.maxY <= buttons[2].frame.minY + 0.5)
            #expect(visible(buttons[2], in: controller.view).height < buttons[2].bounds.height)
            let reading = list.contentOffset
            for button in buttons {
                reveal(button)
                let frame = button.convert(button.bounds, to: controller.view)
                #expect(abs(visible(button, in: controller.view).height - frame.height) <= 1)
                let hit = controller.view.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
                #expect(hit === button || hit?.isDescendant(of: button) == true)
                #expect(list.contentOffset == reading)
            }
            #expect(store.value == original)
            layout(controller, width: 700)
            for (id, button) in zip(ids, buttons) { #expect(find(id, in: controller.view, as: UIButton.self) === button) }
            layout(controller, width: 230)
            let action = try #require(buttons.first { $0.accessibilityIdentifier == selected })
            reveal(action); action.sendActions(for: .touchUpInside)
            if selected == "customizeOK" {
                #expect(Array(store.value.configuration.orderedTags.prefix(2)) == Array(original.configuration.visibleDrawerItems.prefix(2).map(\.rawValue).reversed()))
            } else if selected == "customizeReset" {
                try #require(original.configuration != NavigationConfiguration())
                var expected = original; expected.configuration = NavigationConfiguration()
                #expect(store.value == expected)
            } else { #expect(store.value == original) }
        }
    }
}

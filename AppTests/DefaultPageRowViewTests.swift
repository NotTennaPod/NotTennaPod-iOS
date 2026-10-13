import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct DefaultPageRowViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: T.self) }.first
    }
    private func mounted(_ run: @MainActor (DefaultPageController, UIScrollView, NavigationPreferenceStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DefaultPageRows-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NavigationPreferenceStore(file: directory.appendingPathComponent("prefs.json"))
        let controller = DefaultPageController(preferences: store)
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.traitOverrides.preferredContentSizeCategory = .large
            let list = try #require(find("defaultPageChoices", in: controller.view, as: UIScrollView.self))
            try await run(controller, list, store)
        }
    }
    private func layout(_ controller: UIViewController, width: CGFloat, height: CGFloat = 400) {
        controller.view.frame = CGRect(x: 0, y: 100, width: width, height: height)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }
    private func rows(_ list: UIScrollView) -> [UIControl] {
        list.subviews.compactMap { $0 as? UIControl }.sorted { $0.frame.minY < $1.frame.minY }
    }
    @Test(arguments: [false, true])
    func choicesWrapWithoutExtraPaddingAndKeepRadioAndSelection(rtl: Bool) async throws {
        try await mounted { controller, list, store in
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            layout(controller, width: 700)
            let original = store.value, controls = rows(list)
            try #require(controls.count == 7)
            #expect(controls.allSatisfy { $0.bounds.height >= 44 }, "Rows are comfortably tappable")
            let selected = try #require(controls.first { $0.accessibilityTraits.contains(.selected) })
            list.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            layout(controller, width: 280)
            var bottom: CGFloat = 0
            for row in controls {
                let label = try #require(row.subviews.compactMap { $0 as? UILabel }.first)
                let expected = Appearance.font(16, compatibleWith: list.traitCollection)
                #expect(label.font.pointSize == expected.pointSize, "Dynamic Type reaches the row text")
                #expect(label.textAlignment == (rtl ? .right : .left))
                let measured = ceil(label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height)
                #expect(label.bounds.height >= measured - 0.5, "Wrapped text is not clipped")
                #expect(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame))
                #expect(row.frame.minY >= bottom - 0.5, "Rows do not overlap")
                bottom = row.frame.maxY
                let radio = try #require(row.subviews.first { !($0 is UILabel) })
                #expect(radio.bounds.width > 0 && radio.bounds.height > 0)
                #expect(abs(radio.frame.midY - row.bounds.midY) < 1, "Radio is vertically centred")
                #expect(rtl ? radio.frame.minX >= label.frame.maxX : radio.frame.maxX <= label.frame.minX, "Radio precedes its label")
                if row.accessibilityIdentifier == "defaultPage-remember" { #expect(measured > expected.lineHeight * 2) }
            }
            #expect(abs(list.contentSize.height - bottom) < 1)
            #expect(rows(list).elementsEqual(controls, by: { $0 === $1 }))
            #expect(selected.accessibilityTraits.contains(.selected))
            #expect(store.value == original)
            let remember = try #require(controls.last)
            list.contentOffset.y = list.contentSize.height - list.bounds.height
            controller.view.layoutIfNeeded()
            let point = remember.convert(CGPoint(x: remember.bounds.midX, y: remember.bounds.maxY - 4), to: controller.view)
            let hit = controller.view.hitTest(point, with: nil)
            #expect(hit === remember || hit?.isDescendant(of: remember) == true)
            remember.sendActions(for: .touchUpInside)
            #expect(store.value.defaultPage == "remember")
            let reopened = DefaultPageController(preferences: store); reopened.loadViewIfNeeded()
            let checked = try #require(find("defaultPage-remember", in: reopened.view, as: UIControl.self))
            #expect(checked.accessibilityTraits.contains(.selected))
        }
    }
    /// Reveal through the actual enabled scrolling ancestors, then test UIKit's
    /// hit routing. A zero-height inner viewport must not count as reachable.
    private func reveal(_ target: UIView, rect: CGRect, in root: UIView) -> CGPoint {
        var ancestor = target.superview
        while let current = ancestor, current !== root {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled {
                scroll.scrollRectToVisible(target.convert(rect, to: scroll), animated: false)
                scroll.layoutIfNeeded()
            }
            ancestor = current.superview
        }
        return target.convert(CGPoint(x: rect.midX, y: rect.midY), to: root)
    }

    @Test(arguments: [false, true], [0, 6])
    func shortWindowKeepsChoicesAndCancelReachable(rtl: Bool, selection: Int) async throws {
        try await mounted { controller, list, store in
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            controller.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            layout(controller, width: 380, height: 700)
            let controls = rows(list), original = store.value
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: 3, left: 19, bottom: 7, right: 5)
            layout(controller, width: 380, height: 200)
            let cancel = try #require(find("defaultPageCancel", in: controller.view, as: UIButton.self))
            let title = try #require(find("defaultPageTitle", in: controller.view, as: UIView.self))
            let panel = try #require(list.superview)
            let safe = controller.view.bounds.inset(by: controller.view.safeAreaInsets)
            #expect(safe.contains(panel.frame))
            try #require(panel.bounds.height > cancel.bounds.height)
            #expect(title.bounds.height > 0)
            for row in controls {
                let point = reveal(row, rect: CGRect(x: row.bounds.midX - 4, y: row.bounds.midY - 4, width: 8, height: 8), in: controller.view)
                let hit = controller.view.hitTest(point, with: nil)
                #expect(hit === row || hit?.isDescendant(of: row) == true)
            }
            let wrapped = try #require(controls.last)
            let label = try #require(wrapped.subviews.compactMap { $0 as? UILabel }.first)
            let lineHeight = ceil(label.font.lineHeight)
            try #require(label.bounds.height > 2 * lineHeight && panel.bounds.height > lineHeight)
            for y in [CGFloat.zero, label.bounds.maxY - lineHeight] {
                let line = CGRect(x: 0, y: y, width: label.bounds.width, height: lineHeight)
                _ = reveal(label, rect: line, in: controller.view)
                #expect(panel.bounds.contains(label.convert(line, to: panel)))
                #expect(list.bounds.contains(label.convert(line, to: list)))
            }
            let point = reveal(cancel, rect: cancel.bounds, in: controller.view)
            let hit = controller.view.hitTest(point, with: nil)
            #expect(hit === cancel || hit?.isDescendant(of: cancel) == true)
            #expect(panel.bounds.contains(cancel.convert(cancel.bounds, to: panel)))
            #expect(store.value == original)
            #expect(rows(list).elementsEqual(controls, by: { $0 === $1 }))
            let chosen = controls[selection]
            _ = reveal(chosen, rect: chosen.bounds.insetBy(dx: 4, dy: chosen.bounds.height / 2 - 4), in: controller.view)
            chosen.sendActions(for: .touchUpInside)
            #expect(store.value.defaultPage == NavigationPreferences.defaultPageChoices[selection])
        }
    }

    @Test
    func rootAndListCategoryChangesRemeasureAutomatically() async throws {
        try await mounted { controller, list, _ in
            layout(controller, width: 320)
            let target = try #require(rows(list).last)
            let label = try #require(target.subviews.compactMap { $0 as? UILabel }.first)
            for owner in [controller.view!, list] {
                for category: UIContentSizeCategory in [.accessibilityExtraExtraExtraLarge, .large] {
                    owner.traitOverrides.preferredContentSizeCategory = category
                    let expected = Appearance.font(16, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while ContinuousClock.now < deadline {
                        let needed = ceil(label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height)
                        if label.font.pointSize == expected.pointSize, target.bounds.height >= needed - 0.5 { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let needed = ceil(label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height)
                    #expect(label.font.pointSize == expected.pointSize)
                    #expect(target.bounds.height >= needed - 0.5, "Row grows to fit its text")
                    #expect(list.contentOffset.y == 0)
                }
            }
        }
    }

}

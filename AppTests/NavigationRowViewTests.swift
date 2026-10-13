import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct NavigationRowViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: T.self) }.first
    }
    private func mounted(nondefault: Bool = false, _ run: @MainActor (NavigationCustomizationController, UICollectionView, NavigationPreferenceStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NavigationRows-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NavigationPreferenceStore(file: directory.appendingPathComponent("prefs.json"))
        if nondefault {
            var saved = store.value
            saved.configuration.orderedTags = Array(saved.configuration.visibleDrawerItems.map(\.rawValue).reversed())
            try store.update(saved)
        }
        let controller = NavigationCustomizationController(preferences: store)
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.traitOverrides.preferredContentSizeCategory = .large
            let list = try #require(find("customizeList", in: controller.view, as: UICollectionView.self))
            try await run(controller, list, store)
        }
    }
    private func layout(_ controller: UIViewController, width: CGFloat, height: CGFloat = 400) {
        controller.view.frame = CGRect(x: 0, y: 100, width: width, height: height)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }
    @Test(arguments: [false, true])
    func wrappingUsesMeasuredLocalFontAndSourceMargins(rtl: Bool) async throws {
        try await mounted { controller, list, store in
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            layout(controller, width: 320)
            let original = store.value
            for category: UIContentSizeCategory in [.accessibilityExtraExtraExtraLarge, .large] {
                list.traitOverrides.preferredContentSizeCategory = category
                let expected = Appearance.font(16, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while ContinuousClock.now < deadline {
                    let label: UILabel? = find("customize-row-shown", in: list)
                    if label?.font.pointSize == expected.pointSize { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let top = UIFontMetrics(forTextStyle: .body).scaledValue(for: 16, compatibleWith: list.traitCollection)
                #expect(abs(list.contentInset.top - top) <= 0.5)
                #expect(abs(list.contentOffset.y + top) <= 0.5)
                for index in [0, 1, 4] {
                    let path = IndexPath(item: index, section: 0)
                    list.scrollToItem(at: path, at: .top, animated: false); list.layoutIfNeeded()
                    let cell = try #require(list.cellForItem(at: path))
                    let label = try #require(cell.contentView.subviews.compactMap { $0 as? UILabel }.first)
                    #expect(label.font.pointSize == expected.pointSize)
                    #expect(label.numberOfLines == 0)
                    let header = index == 0
                    // Wrapped wording stays inside the row and is never clipped.
                    #expect(cell.contentView.bounds.contains(label.frame))
                    let needed = ceil(label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height)
                    #expect(label.bounds.height >= needed)
                    #expect(cell.bounds.height >= needed + 16 + 1)
                    if category.isAccessibilityCategory, index == 4 { #expect(needed > expected.lineHeight * 1.5) }
                    if !header {
                        // Drag handle: labelled, touchable, beside (not over) the wording, vertically centred.
                        let handle = try #require(cell.contentView.subviews.first { $0.accessibilityLabel == Appearance.text("sort") })
                        #expect(handle.bounds.width >= 40 && handle.bounds.height >= 40)
                        #expect(!handle.frame.intersects(label.frame))
                        #expect(rtl ? handle.frame.minX >= label.frame.maxX - 0.5 : handle.frame.maxX <= label.frame.minX + 0.5)
                        #expect(abs(handle.frame.midY - cell.bounds.midY) <= 1)
                    }
                }
                list.contentOffset.y = -list.adjustedContentInset.top
            }
            #expect(store.value == original)
        }
    }
    @Test(arguments: [false, true])
    func reflowPreservesPartialItemAndUnsavedOrder(rtl: Bool) async throws {
        try await mounted { controller, list, store in
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            layout(controller, width: 340)
            controller.collectionView(list, moveItemAt: IndexPath(item: 1, section: 0), to: IndexPath(item: 2, section: 0))
            list.reloadData(); list.layoutIfNeeded()
            let original = store.value
            let path = IndexPath(item: 3, section: 0)
            let initial = try #require(list.layoutAttributesForItem(at: path)).frame
            try #require(initial.minY + 7 < list.contentSize.height - list.bounds.height)
            list.contentOffset.y = initial.minY + 7 - list.contentInset.top
            list.layoutIfNeeded()
            let cell = try #require(list.cellForItem(at: path)), tag = cell.accessibilityIdentifier
            for (width, category): (CGFloat, UIContentSizeCategory) in [(230, .accessibilityExtraExtraExtraLarge), (340, .large)] {
                list.traitOverrides.preferredContentSizeCategory = category
                layout(controller, width: width)
                let current = try #require(list.layoutAttributesForItem(at: path)).frame
                #expect(abs(current.minY - list.contentOffset.y - list.contentInset.top + 7) <= 1, "row=\(current.minY), offset=\(list.contentOffset.y)")
                #expect(list.cellForItem(at: path)?.accessibilityIdentifier == tag)
                #expect(store.value == original)
                layout(controller, width: width)
                #expect(abs(current.minY - list.contentOffset.y - list.contentInset.top + 7) <= 1, "row=\(current.minY), offset=\(list.contentOffset.y)")
            }
            let confirm = try #require(find("customizeOK", in: controller.view, as: UIButton.self))
            confirm.sendActions(for: .touchUpInside)
            #expect(Array(store.value.configuration.orderedTags.prefix(2)) == Array(original.configuration.visibleDrawerItems.prefix(2).map(\.rawValue).reversed()))
            #expect(store.value.configuration.hiddenTags == original.configuration.hiddenTags)
        }
    }
    @Test
    func shrinkingDeeplyScrolledRowKeepsThatItemVisible() async throws {
        try await mounted { controller, list, store in
            list.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            layout(controller, width: 230, height: 300)
            let original = store.value, path = IndexPath(item: 4, section: 0)
            let large = try #require(list.layoutAttributesForItem(at: path)).frame
            try #require(large.height > 100)
            let hidden = large.height * 0.75
            try #require(large.minY + hidden < list.contentSize.height - list.bounds.height)
            list.contentOffset.y = large.minY + hidden - list.contentInset.top; list.layoutIfNeeded()
            let tag = try #require(list.cellForItem(at: path)).accessibilityIdentifier
            list.traitOverrides.preferredContentSizeCategory = .large
            layout(controller, width: 340, height: 300)
            let small = try #require(list.layoutAttributesForItem(at: path)).frame
            try #require(hidden > small.height)
            try #require(small.minY + small.height * 0.75 < list.contentSize.height - list.bounds.height)
            // UIScrollView rounds fractional offsets to local display pixels.
            let pixelTolerance = 0.5 / list.traitCollection.displayScale
            #expect(abs(list.contentOffset.y + list.contentInset.top - small.minY - small.height * 0.75) <= pixelTolerance)
            #expect(list.cellForItem(at: path)?.accessibilityIdentifier == tag)
            #expect(small.maxY > list.contentOffset.y)
            let cancel = try #require(find("customizeCancel", in: controller.view, as: UIButton.self))
            cancel.sendActions(for: .touchUpInside)
            #expect(store.value == original)
        }
    }

    @Test
    func partiallyVisibleFirstRowSurvivesFixedPaddingReflow() async throws {
        try await mounted { controller, list, _ in
            layout(controller, width: 340)
            list.contentOffset.y = 8 - list.contentInset.top
            list.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            layout(controller, width: 230)
            #expect(abs(list.contentOffset.y + list.contentInset.top - 8) < 0.5)
            list.traitOverrides.preferredContentSizeCategory = .large
            layout(controller, width: 340)
            #expect(abs(list.contentOffset.y + list.contentInset.top - 8) < 0.5)
        }
    }

    @Test(arguments: [false, true], ["customizeOK", "customizeCancel", "customizeReset"])
    func shortWindowKeepsRowsActionsAndDraftSemantics(rtl: Bool, selected: String) async throws {
        try await mounted(nondefault: true) { controller, list, store in
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            layout(controller, width: 700, height: 700)
            let original = store.value
            let ids = ["customizeOK", "customizeCancel", "customizeReset"]
            let buttons = try ids.map { try #require(find($0, in: controller.view, as: UIButton.self)) }
            controller.collectionView(list, moveItemAt: IndexPath(item: 1, section: 0), to: IndexPath(item: 2, section: 0))
            list.reloadData(); list.layoutIfNeeded()
            controller.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: 3, left: 17, bottom: 7, right: 5)
            layout(controller, width: 360, height: 200)
            let panel = try #require(list.superview)
            try #require(panel.bounds.height > buttons[0].bounds.height)
            #expect(list.frame == panel.bounds)
            #expect(controller.view.bounds.inset(by: controller.view.safeAreaInsets).contains(panel.frame))
            try #require(list.bounds.height > 40)
            for index in [0, 1, list.numberOfItems(inSection: 0) - 1] {
                let path = IndexPath(item: index, section: 0)
                list.scrollToItem(at: path, at: .top, animated: false); list.layoutIfNeeded()
                let cell = try #require(list.cellForItem(at: path))
                let label = try #require(cell.contentView.subviews.compactMap { $0 as? UILabel }.first)
                let lineHeight = ceil(label.font.lineHeight)
                try #require(list.bounds.height >= lineHeight)
                for y in [CGFloat.zero, max(0, label.bounds.height - lineHeight)] {
                    let rect = CGRect(x: 0, y: y, width: label.bounds.width, height: lineHeight)
                    list.scrollRectToVisible(label.convert(rect, to: list), animated: false)
                    list.layoutIfNeeded()
                    #expect(list.bounds.contains(label.convert(rect, to: list)))
                }
            }
            list.contentOffset.y = max(0, list.contentSize.height - list.bounds.height)
            list.layoutIfNeeded()
            for button in buttons.reversed() {
                try #require(button.isDescendant(of: list))
                list.scrollRectToVisible(button.convert(button.bounds, to: list), animated: false)
                list.layoutIfNeeded()
                #expect(list.bounds.contains(button.convert(button.bounds, to: list)))
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: controller.view)
                let hit = controller.view.hitTest(point, with: nil)
                #expect(hit === button || hit?.isDescendant(of: button) == true)
                #expect(find(button.accessibilityIdentifier!, in: controller.view, as: UIButton.self) === button)
                #expect((button.superview as? UIScrollView)?.isScrollEnabled == false)
            }
            #expect(store.value == original)
            let action = try #require(buttons.first { $0.accessibilityIdentifier == selected })
            list.scrollRectToVisible(action.convert(action.bounds, to: list), animated: false)
            action.sendActions(for: .touchUpInside)
            if selected == "customizeOK" {
                let eligible = original.configuration.visibleDrawerItems.filter { $0 != .subscriptionList }.map(\.rawValue)
                #expect(store.value.configuration.orderedTags == Array(eligible.prefix(2).reversed()) + Array(eligible.dropFirst(2)))
            } else if selected == "customizeReset" {
                var expected = original; expected.configuration = NavigationConfiguration()
                #expect(store.value == expected)
            } else { #expect(store.value == original) }
        }
    }

    @Test(arguments: [false, true])
    func shortWindowRetainsCollectionReadingAndDraftThroughTransitions(rtl: Bool) async throws {
        try await mounted { controller, list, store in
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            layout(controller, width: 340, height: 350)
            let original = store.value, path = IndexPath(item: 3, section: 0)
            let before = try #require(list.layoutAttributesForItem(at: path)).frame
            try #require(before.minY + 7 < list.contentSize.height - list.bounds.height)
            list.contentOffset.y = before.minY + 7 - list.contentInset.top
            for (width, height, category): (CGFloat, CGFloat, UIContentSizeCategory) in [
                (340, 150, .large), (230, 150, .accessibilityExtraExtraExtraLarge), (340, 350, .large)
            ] {
                list.traitOverrides.preferredContentSizeCategory = category
                layout(controller, width: width, height: height)
                let frame = try #require(list.layoutAttributesForItem(at: path)).frame
                #expect(abs(frame.minY - list.contentOffset.y - list.contentInset.top + 7) < 0.5)
            }
            let ordinary = list.contentOffset
            layout(controller, width: 340, height: 150)
            list.contentOffset = .zero; list.layoutIfNeeded()
            let title = try #require(find("customizeTitle", in: controller.view, as: UIView.self))
            #expect(title.isDescendant(of: list))
            #expect(list.bounds.contains(title.convert(title.bounds, to: list)))
            let saved = list.contentOffset, frame = list.frame
            layout(controller, width: 0, height: 0)
            #expect(list.superview?.isHidden == true && list.contentOffset == saved && list.frame == frame)
            layout(controller, width: 340, height: 350)
            #expect(list.contentOffset == ordinary)
            #expect(!title.isDescendant(of: list))
            #expect(store.value == original)
        }
    }

    @Test func shortWindowRestoresIndependentActionReadingPosition() async throws {
        try await mounted { controller, list, _ in
            layout(controller, width: 230, height: 400)
            let actions = try #require(find("customizeActions", in: controller.view, as: UIScrollView.self))
            let reset = try #require(find("customizeReset", in: controller.view, as: UIButton.self))
            try #require(actions.contentSize.height > actions.bounds.height)
            actions.scrollRectToVisible(reset.frame, animated: false)
            let offset = actions.contentOffset
            try #require(offset.y > 0 && actions.bounds.contains(reset.frame))
            layout(controller, width: 230, height: 150)
            #expect(list.frame == list.superview?.bounds)
            layout(controller, width: 230, height: 400)
            #expect(actions.contentOffset == offset)
            #expect(actions.bounds.contains(reset.frame))
        }
    }

    @Test(arguments: [false, true])
    func scrolledRowUnderTopPaddingDoesNotStealTouchesAndHandleStaysReachable(rtl: Bool) async throws {
        try await mounted { controller, list, _ in
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            layout(controller, width: 340, height: 400)
            let path = IndexPath(item: 1, section: 0)
            for category: UIContentSizeCategory in [.large, .accessibilityExtraExtraExtraLarge, .large] {
                list.traitOverrides.preferredContentSizeCategory = category
                layout(controller, width: 340, height: 400)
                list.scrollToItem(at: path, at: .top, animated: false); list.layoutIfNeeded()
                let cell = try #require(list.cellForItem(at: path))
                let handle = try #require(cell.contentView.subviews.first { $0.accessibilityLabel == Appearance.text("sort") })
                let top = list.contentInset.top
                // A touch in the top padding band scrolls the list rather than grabbing a
                // drag handle scrolled underneath it.
                let center = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: list)
                list.contentOffset.y = center.y - top / 2
                list.layoutIfNeeded()
                let clipped = CGPoint(x: center.x, y: list.bounds.minY + top / 2)
                #expect(list.hitTest(clipped, with: nil) === list)
                list.scrollRectToVisible(handle.convert(handle.bounds, to: list), animated: false)
                list.layoutIfNeeded()
                let visibleCenter = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: list)
                #expect(list.bounds.inset(by: list.contentInset).contains(visibleCenter))
                #expect(list.hitTest(visibleCenter, with: nil) === handle)
            }
        }
    }

    @Test func usableLineAndHandleBudgetKeepsOrdinaryComposition() async throws {
        try await mounted { controller, list, _ in
            list.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            layout(controller, width: 340, height: 700)
            let title = try #require(find("customizeTitle", in: controller.view, as: UIView.self))
            let actions = try #require(find("customizeActions", in: controller.view, as: UIScrollView.self))
            let lineHeight = ceil(Appearance.font(16, compatibleWith: list.traitCollection).lineHeight)
            let top = UIFontMetrics(forTextStyle: .body).scaledValue(for: 16, compatibleWith: list.traitCollection)
            let minimum = top + max(40, lineHeight)
            let height = 48 + title.frame.maxY + actions.contentSize.height + minimum
            layout(controller, width: 340, height: height)
            // With room for one line and a handle, title and actions keep their ordinary places
            // and a row's first line and drag handle can still be scrolled fully into view.
            #expect(!title.isDescendant(of: list) && !actions.isDescendant(of: list))
            let path = IndexPath(item: 1, section: 0)
            list.scrollToItem(at: path, at: .top, animated: false); list.layoutIfNeeded()
            let cell = try #require(list.cellForItem(at: path))
            let label = try #require(cell.contentView.subviews.compactMap { $0 as? UILabel }.first)
            let line = CGRect(x: 0, y: 0, width: label.bounds.width, height: lineHeight)
            list.scrollRectToVisible(label.convert(line, to: list), animated: false)
            #expect(list.bounds.inset(by: list.contentInset).contains(label.convert(line, to: list)))
            let handle = try #require(cell.contentView.subviews.first { $0.accessibilityLabel == Appearance.text("sort") })
            list.scrollRectToVisible(handle.convert(handle.bounds, to: list), animated: false)
            #expect(list.bounds.inset(by: list.contentInset).insetBy(dx: -0.5 / list.traitCollection.displayScale, dy: -0.5 / list.traitCollection.displayScale).contains(handle.convert(handle.bounds, to: list)),
                    "viewport=\(list.bounds), handle=\(handle.convert(handle.bounds, to: list)), scale=\(list.traitCollection.displayScale)")
        }
    }

    @Test func offscreenSupplementaryTextFollowsTextSizeChanges() async throws {
        try await mounted { controller, list, store in
            layout(controller, width: 340, height: 700)
            let title = try #require(find("customizeTitle", in: controller.view, as: UILabel.self))
            let ok = try #require(find("customizeOK", in: controller.view, as: UIButton.self))
            let original = store.value
            layout(controller, width: 340, height: 150)
            let path = IndexPath(item: 4, section: 0)
            list.scrollToItem(at: path, at: .top, animated: false); list.layoutIfNeeded()
            let header = try #require(list.collectionViewLayout.layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 0)))
            let footer = try #require(list.collectionViewLayout.layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionFooter, at: IndexPath(item: 0, section: 0)))
            try #require(!list.bounds.intersects(header.frame) && !list.bounds.intersects(footer.frame))
            let initialHeight = list.contentSize.height
            for category: UIContentSizeCategory in [.accessibilityExtraExtraExtraLarge, .large] {
                controller.view.traitOverrides.preferredContentSizeCategory = category
                let traits = UITraitCollection(preferredContentSizeCategory: category)
                let expected = Appearance.font(14, medium: true, compatibleWith: traits).pointSize
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while ok.titleLabel?.font.pointSize != expected && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                #expect(ok.titleLabel?.font.pointSize == expected)
                #expect(title.font.pointSize == Appearance.font(18, compatibleWith: traits).pointSize)
                if category != .large { #expect(list.contentSize.height > initialHeight) }
            }
            #expect(store.value == original)
        }
    }

}

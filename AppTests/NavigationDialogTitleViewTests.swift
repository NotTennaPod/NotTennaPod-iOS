import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
@Suite(.serialized)
struct NavigationDialogTitleViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func withDialog(custom: Bool, _ run: (UIViewController, NavigationPreferenceStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NavigationTitle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try NavigationPreferenceStore(file: directory.appendingPathComponent("preferences.json"))
        let controller: UIViewController = custom ? NavigationCustomizationController(preferences: preferences)
            : DefaultPageController(preferences: preferences)
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.traitOverrides.preferredContentSizeCategory = .large
            try await run(controller, preferences)
        }
    }
    private func layout(_ controller: UIViewController, width: CGFloat) {
        controller.view.frame = CGRect(x: 0, y: 100, width: width, height: 400)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    @Test(arguments: [false, true], [false, true])
    func sourceTitleFallbackPreservesListAndActionState(custom: Bool, rtl: Bool) async throws {
        try await withDialog(custom: custom) { controller, preferences in
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            layout(controller, width: 700)
            let titleID = custom ? "customizeTitle" : "defaultPageTitle"
            let listID = custom ? "customizeList" : "defaultPageChoices"
            let actionID = custom ? "customizeCancel" : "defaultPageCancel"
            let title = try #require(element(titleID, in: controller.view, as: UILabel.self))
            let list = try #require(element(listID, in: controller.view, as: UIScrollView.self))
            let cancel = try #require(element(actionID, in: controller.view, as: UIButton.self))
            let original = preferences.value, wording = title.text
            let selected = list.subviews.compactMap { $0 as? UIControl }.first { $0.accessibilityTraits.contains(.selected) }
            if !custom { try #require(selected != nil) }
            let originalFirstTags = Array(original.configuration.visibleDrawerItems.prefix(2)).map(\.rawValue)
            if let customization = controller as? NavigationCustomizationController,
               let collection = list as? UICollectionView {
                try #require(collection.numberOfItems(inSection: 0) > 2)
                customization.collectionView(collection, moveItemAt: IndexPath(item: 1, section: 0),
                    to: IndexPath(item: 2, section: 0))
                collection.reloadData(); collection.layoutIfNeeded()
            }
            #expect(title.font.pointSize == 24 && title.numberOfLines == 1)
            #expect(title.textAlignment == (rtl ? .right : .left))
            try #require(list.contentSize.height - list.bounds.height > 40)
            list.contentOffset.y = 40
            for width: CGFloat in [185, 700] {
                layout(controller, width: width)
                #expect(title.font.pointSize == 18 && title.numberOfLines == 2)
                #expect(title.accessibilityLabel == wording)
                #expect(title.bounds.height >= ceil(title.sizeThatFits(CGSize(width: title.bounds.width, height: .greatestFiniteMagnitude)).height))
                let gap = list.convert(list.bounds, to: controller.view).minY - title.convert(title.bounds, to: controller.view).maxY
                #expect(abs(gap - (custom ? 0 : 16)) <= 1)
                #expect(element(titleID, in: controller.view, as: UILabel.self) === title)
                #expect(element(listID, in: controller.view, as: UIScrollView.self) === list)
                #expect(element(actionID, in: controller.view, as: UIButton.self) === cancel)
                #expect(list.contentOffset.y == 40)
                #expect(preferences.value == original)
                if let selected { #expect(selected.accessibilityTraits.contains(.selected) && selected.superview === list) }
            }
            if custom {
                #expect(abs(list.contentInset.top - 16) <= 1)
                list.contentOffset.y = -list.adjustedContentInset.top
                layout(controller, width: 185)
                #expect(list.contentOffset.y == -list.adjustedContentInset.top)
                layout(controller, width: 185)
                #expect(list.contentOffset.y == -list.adjustedContentInset.top)
                let bottom = max(-list.adjustedContentInset.top,
                    list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
                list.contentOffset.y = bottom
                layout(controller, width: 700)
                let newBottom = max(-list.adjustedContentInset.top,
                    list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
                #expect(list.contentOffset.y == min(bottom, newBottom))
                layout(controller, width: 700)
                #expect(list.contentOffset.y == min(bottom, newBottom))
                let confirm = try #require(element("customizeOK", in: controller.view, as: UIButton.self))
                confirm.sendActions(for: .touchUpInside)
                #expect(Array(preferences.value.configuration.orderedTags.prefix(2)) == Array(originalFirstTags.reversed()))
            }
        }
    }

    @Test(arguments: [false, true])
    func localTitleTraitsUpdateAutomatically(custom: Bool) async throws {
        try await withDialog(custom: custom) { controller, _ in
            layout(controller, width: 320)
            let title = try #require(element(custom ? "customizeTitle" : "defaultPageTitle", in: controller.view, as: UILabel.self))
            for category: UIContentSizeCategory in [.accessibilityExtraExtraExtraLarge, .large] {
                title.traitOverrides.preferredContentSizeCategory = category
                let base = try #require(UIFont(name: "Roboto-Regular", size: 18))
                let expected = UIFontMetrics(forTextStyle: .body).scaledFont(for: base,
                    compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while title.font.pointSize != expected.pointSize, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(title.font.pointSize == expected.pointSize && title.numberOfLines == 2)
                #expect(title.bounds.height >= ceil(title.sizeThatFits(CGSize(width: title.bounds.width, height: .greatestFiniteMagnitude)).height))
            }
        }
    }
}

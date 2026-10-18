import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct DownloadsSwipeViewTests {
    private func find<T: UIView>(_ id: String, _ view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        for child in view.subviews { if let result: T = find(id, child) { return result } }; return nil
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    @Test(arguments: [CGSize(width: 393, height: 852), CGSize(width: 834, height: 1194), CGSize(width: 720, height: 420)])
    func configurationDraftCancelPickerAndConfirmedEnableState(size: CGSize) async throws {
        var saved: DownloadsSwipePreferences?
        try await withViewTestWindow { host, _ in
            let controller = UIViewController(); host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.frame = CGRect(origin: .zero, size: size)
            defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            let first = DownloadsSwipeSettingsController.make(value: nil) { saved = $0 }
            controller.present(first, animated: false)
            try await wait { first.view.window != nil && !first.isBeingPresented }
            first.view.frame = CGRect(origin: .zero, size: size); first.view.setNeedsLayout(); first.view.layoutIfNeeded()
            #expect(first.view.bounds.size == size)
            let body: DownloadsSwipeSettingsBody = try #require(find("downloadsSwipeSettings", first.view))
            #expect(body.draft == DownloadsSwipePreferences())
            let preview: UIControl = try #require(find("downloadsSwipePreview-left", first.view))
            #expect(preview.isAccessibilityElement && preview.accessibilityTraits.contains(.button))
            #expect(preview.accessibilityLabel == "Swipe left" && preview.accessibilityValue == "Delete")
            let toggle: UIControl = try #require(find("downloadsSwipeEnabled", first.view))
            toggle.sendActions(for: .touchUpInside)
            #expect(!body.draft.enabled && saved == nil)
            let left: UIButton = try #require(find("downloadsSwipeChange-left", first.view))
            left.sendActions(for: .touchUpInside)
            try await wait { first.presentedViewController != nil && first.presentedViewController?.isBeingPresented == false }
            let picker = try #require(first.presentedViewController)
            picker.view.frame = CGRect(origin: .zero, size: size); picker.view.setNeedsLayout(); picker.view.layoutIfNeeded()
            for action in DownloadsSwipeAction.allCases { #expect(find("downloadsSwipeChoice-" + action.rawValue, picker.view) as UIButton? != nil) }
            let favorite: UIButton = try #require(find("downloadsSwipeChoice-MARK_FAV", picker.view))
            favorite.sendActions(for: .touchUpInside)
            try await wait { first.presentedViewController == nil }
            #expect(body.draft.left == .favorite && body.draft.right == .delete && saved == nil)
            #expect(preview.accessibilityValue == "Add to favorites")
            preview.sendActions(for: .touchUpInside)
            try await wait { first.presentedViewController != nil && first.presentedViewController?.isBeingPresented == false }
            let reopenedPicker = try #require(first.presentedViewController)
            let selected: UIButton = try #require(find("downloadsSwipeChoice-MARK_FAV", reopenedPicker.view))
            // The current choice is highlighted: its icon is tinted differently from the other choices.
            let unselected: UIButton = try #require(find("downloadsSwipeChoice-ADD_TO_QUEUE", reopenedPicker.view))
            let tint = try #require(selected.subviews.compactMap { $0 as? UIImageView }.first?.tintColor)
            let other = try #require(unselected.subviews.compactMap { $0 as? UIImageView }.first?.tintColor)
            #expect(tint.resolvedColor(with: selected.traitCollection) != other.resolvedColor(with: unselected.traitCollection))
            let pickerCancel: UIButton = try #require(find("downloadsSwipePickerCancel", reopenedPicker.view))
            pickerCancel.sendActions(for: .touchUpInside)
            try await wait { first.presentedViewController == nil }
            let cancel: UIButton = try #require(find("downloadsSwipeCancel", first.view)); cancel.sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController == nil }
            #expect(saved == nil)
            var initial = DownloadsSwipePreferences(); initial.left = .queue; initial.right = .played
            let second = DownloadsSwipeSettingsController.make(value: initial) { saved = $0 }
            controller.present(second, animated: false); try await wait { second.view.window != nil }
            second.view.frame = CGRect(origin: .zero, size: size); second.view.setNeedsLayout(); second.view.layoutIfNeeded()
            #expect(second.view.bounds.size == size)
            let secondBody: DownloadsSwipeSettingsBody = try #require(find("downloadsSwipeSettings", second.view))
            #expect(secondBody.draft == initial)
            let secondToggle: UIControl = try #require(find("downloadsSwipeEnabled", second.view)); secondToggle.sendActions(for: .touchUpInside)
            let confirm: UIButton = try #require(find("downloadsSwipeConfirm", second.view)); confirm.sendActions(for: .touchUpInside)
            try await wait { saved != nil }
            #expect(saved?.enabled == false && saved?.left == .queue && saved?.right == .played)
        }
    }
}

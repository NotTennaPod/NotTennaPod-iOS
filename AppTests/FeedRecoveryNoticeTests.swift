import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct FeedRecoveryNoticeTests {
    private func label(in view: UIView) -> UILabel? {
        if let label = view as? UILabel, label.accessibilityIdentifier == "feedRecoveryNotice" { return label }
        return view.subviews.lazy.compactMap { label(in: $0) }.first
    }
    @Test func recoveredNoticeUsesSafeAreaAndRetiresWhenPreviewCloses() async throws {
        let preview = FeedPreviewController(content: UIViewController(), recoveredBySearch: true)
        try await withViewTestWindow { host, _ in
            host.present(preview, animated: false)
            let deadline = ContinuousClock.now + .seconds(3)
            while label(in: preview.view) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let notice = try #require(label(in: preview.view))
            #expect(notice.numberOfLines == 2)
            #expect(notice.text == "The suggested podcast did not have an RSS link, NotTennaPod found a podcast that could match")
            preview.additionalSafeAreaInsets = .init(top: 0, left: 19, bottom: 10, right: 47)
            preview.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            preview.view.frame.size = CGSize(width: 200, height: 140)
            preview.view.setNeedsLayout(); preview.view.layoutIfNeeded()
            let box = try #require(notice.superview)
            let safe = preview.view.safeAreaLayoutGuide.layoutFrame
            #expect(box.frame.minX >= safe.minX && box.frame.maxX <= safe.maxX)
            #expect(box.frame.minY >= safe.minY && box.frame.maxY <= safe.maxY)
            #expect(notice.frame.width > 0 && notice.frame.height > 0 && box.bounds.contains(notice.frame), "Notice text stays inside its box")
            host.dismiss(animated: false)
            let retired = ContinuousClock.now + .seconds(3)
            while label(in: preview.view) != nil, ContinuousClock.now < retired { try await Task.sleep(for: .milliseconds(10)) }
            #expect(label(in: preview.view) == nil)
        }
    }
}

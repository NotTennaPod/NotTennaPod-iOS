import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct AutomaticDownloadFilterViewTests {
    private func element(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { element(id, in: $0) }.first
    }
    @Test func controlsFollowSourceCompositionAtPhoneWidth() async throws {
        // Source composition (android-filter-saved-layout.json): Include | Exclude side by side at the top,
        // then the term input, then the minimum-duration row, all inside the body.
        try await withViewTestWindow { host, _ in
            let body = AutomaticDownloadFilterBody(value: .init(exclude: "\"Skip\" ", minimumDurationSeconds: 0))
            host.view.addSubview(body)
            let width: CGFloat = 898 / 2.625
            body.frame = .init(origin: .zero, size: body.sizeThatFits(.init(width: width, height: .greatestFiniteMagnitude)))
            body.layoutIfNeeded()
            let include = try #require(element("downloadFilterInclude", in: body))
            let exclude = try #require(element("downloadFilterExclude", in: body))
            let input = try #require(body.term.superview)
            let duration = try #require(element("downloadFilterDuration", in: body))
            #expect(abs(include.frame.minY - exclude.frame.minY) < 1, "Include and Exclude share one row")
            #expect(include.frame.maxX <= exclude.frame.minX + 1, "Include precedes Exclude without overlap")
            #expect(input.frame.minY >= max(include.frame.maxY, exclude.frame.maxY) - 1, "Term input sits below the mode row")
            #expect(duration.frame.minY >= input.frame.maxY - 1, "Duration row sits below the term input")
            for control in [include, exclude, input, duration] {
                #expect(body.bounds.insetBy(dx: -1, dy: -1).contains(control.frame) && control.frame.width > 0 && control.frame.height > 0)
            }
            body.removeFromSuperview()
        }
    }
    @Test func resizeKeepsDraftAndControlsWithinBodyInBothDirections() async throws {
        try await withViewTestWindow { host, _ in
            let body = AutomaticDownloadFilterBody(value: .init(exclude: "\"one\" \"two\" \"three\"", minimumDurationSeconds: 600))
            host.view.addSubview(body)
            body.term.text = "unsaved"; body.duration.text = "15"
            for direction in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
                body.semanticContentAttribute = direction
                for width: CGFloat in [230, 314, 560] {
                    body.frame = .init(origin: .zero, size: body.sizeThatFits(.init(width: width, height: .greatestFiniteMagnitude)))
                    body.setNeedsLayout(); body.layoutIfNeeded()
                    for id in ["downloadFilterInclude", "downloadFilterExclude", "downloadFilterDuration", "downloadFilterMinutes"] {
                        let control = try #require(element(id, in: body))
                        #expect(body.bounds.contains(control.frame))
                    }
                    #expect(body.term.text == "unsaved")
                    #expect(body.confirmed == .init(exclude: "\"one\" \"two\" \"three\" ", minimumDurationSeconds: 900))
                }
            }
            body.removeFromSuperview()
        }
    }
}

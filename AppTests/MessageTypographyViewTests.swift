import UIKit
import Testing
@testable import NotTennaPod

@MainActor
@Suite(.serialized)
struct MessageTypographyViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func withHost(_ run: (UIViewController) async throws -> Void) async throws {
        try await withViewTestWindow { host, window in
            try await run(host)
        }
    }
    private func mount(_ dialog: SourceMessageController, in host: UIViewController, x: CGFloat = 0) {
        host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
        dialog.view.frame = CGRect(x: x, y: 100, width: 320, height: 500)
        dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
    }
    private func expectedFont(_ name: String, traits: UITraitCollection) throws -> UIFont {
        let base = try #require(UIFont(name: name, size: 14))
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: traits)
    }
    private func assertTypography(_ label: UILabel, button: UIButton) throws {
        let expected = try expectedFont("Roboto-Regular", traits: label.traitCollection)
        let buttonLabel = try #require(button.titleLabel)
        let expectedButton = try expectedFont("Roboto-Medium", traits: buttonLabel.traitCollection)
        // Text follows the person's text size (to within a point).
        #expect(abs(label.font.pointSize - expected.pointSize) <= 1)
        #expect(abs(buttonLabel.font.pointSize - expectedButton.pointSize) <= 1)
        let text = try #require(label.attributedText)
        for index in [0, text.length - 1] {
            // Lines grow with the text: never overlapping or cramped, never spread apart.
            let paragraph = try #require(text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.maximumLineHeight >= label.font.lineHeight - 1 && paragraph.maximumLineHeight <= label.font.lineHeight * 1.6)
            if let attributedFont = text.attribute(.font, at: index, effectiveRange: nil) as? UIFont {
                #expect(abs(attributedFont.pointSize - expected.pointSize) <= 1)
            }
        }
        // The whole message fits its label, and the action is tall enough for its title.
        #expect(label.bounds.height >= label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height - 1)
        #expect(button.bounds.height >= expectedButton.lineHeight + 20)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Local trait change must update typography without the test requesting layout")
    }

    @Test func simultaneouslyMountedDialogsUseIndependentLocalTextSizesAndPreserveStyling() async throws {
        try await withHost { host in
            let normal = SourceMessageController(title: "Warning", message: "Normal message")
            normal.loadViewIfNeeded(); normal.view.traitOverrides.preferredContentSizeCategory = .large
            var performed = 0
            let message = "Warning 🎧", details = "Details 🔎\nSecond line"
            let enlarged = SourceMessageController(title: "Warning", message: message, details: details,
                positive: .init(title: "OK", identifier: "confirm", perform: { performed += 1 }))
            enlarged.loadViewIfNeeded()
            enlarged.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            mount(normal, in: host); mount(enlarged, in: host, x: 330)
            let normalLabel = try #require(element("sourceMessage", in: normal.view, as: UILabel.self))
            let normalButton = try #require(element("sourceMessageOK", in: normal.view, as: UIButton.self))
            let label = try #require(element("sourceMessage", in: enlarged.view, as: UILabel.self))
            let button = try #require(element("confirm", in: enlarged.view, as: UIButton.self))
            try #require(label.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
            try #require(normalLabel.traitCollection.preferredContentSizeCategory == .large)
            let text = try #require(label.attributedText)
            let detailsIndex = (message as NSString).length
            let color = try #require(text.attribute(.foregroundColor, at: detailsIndex, effectiveRange: nil) as? UIColor)
            for category: UIContentSizeCategory in [.accessibilityExtraExtraExtraLarge, .large, .accessibilityExtraExtraExtraLarge, .large] {
                enlarged.view.traitOverrides.preferredContentSizeCategory = category
                enlarged.updateAction(identifier: "confirm", title: "OK (1)", isEnabled: false)
                for _ in 0..<3 { enlarged.view.setNeedsLayout(); enlarged.view.layoutIfNeeded() }
                try assertTypography(label, button: button)
                try assertTypography(normalLabel, button: normalButton)
                #expect(label.attributedText?.string == message + "\n\n" + details)
                #expect((label.attributedText?.attribute(.foregroundColor, at: detailsIndex, effectiveRange: nil) as? UIColor) == color)
                #expect(button.title(for: .normal) == "OK (1)" && !button.isEnabled)
                #expect(element("sourceMessage", in: enlarged.view, as: UILabel.self) === label)
                #expect(element("confirm", in: enlarged.view, as: UIButton.self) === button)
            }
            enlarged.updateAction(identifier: "confirm", title: "OK", isEnabled: true)
            button.sendActions(for: .touchUpInside); button.sendActions(for: .touchUpInside)
            #expect(performed == 1)
        }
    }

    @Test func localTraitChangesInvalidateMountedDialogWithoutManualLayout() async throws {
        try await withHost { host in
            let dialog = SourceMessageController(title: "Warning", message: "Body text\nSecond line")
            dialog.loadViewIfNeeded(); dialog.view.traitOverrides.preferredContentSizeCategory = .large
            mount(dialog, in: host)
            let label = try #require(element("sourceMessage", in: dialog.view, as: UILabel.self))
            let button = try #require(element("sourceMessageOK", in: dialog.view, as: UIButton.self))
            for category: UIContentSizeCategory in [.accessibilityExtraExtraExtraLarge, .large] {
                dialog.view.traitOverrides.preferredContentSizeCategory = category
                let traits = UITraitCollection(preferredContentSizeCategory: category)
                let expected = try expectedFont("Roboto-Regular", traits: traits)
                let expectedButton = try expectedFont("Roboto-Medium", traits: traits)
                try await waitUntil {
                    guard let paragraph = label.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else { return false }
                    return abs(label.font.pointSize - expected.pointSize) <= 1
                        && abs((button.titleLabel?.font.pointSize ?? 0) - expectedButton.pointSize) <= 1
                        && paragraph.maximumLineHeight >= label.font.lineHeight - 1
                        && button.bounds.height >= expectedButton.lineHeight + 20
                }
                try assertTypography(label, button: button)
            }
        }
    }
}

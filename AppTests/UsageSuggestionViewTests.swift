import UIKit
import Testing
@testable import NotTennaPod

@MainActor
struct UsageSuggestionViewTests {
    private func popup(offer: Bool) -> UsageSuggestionView {
        let view = UsageSuggestionView(frame: CGRect(x: 0, y: 0, width: 402, height: 800), anchorBottom: 200, offerStreaming: offer)
        view.layoutIfNeeded()
        return view
    }
    private func button(_ id: String, in view: UIView) throws -> UIButton {
        if let button = view as? UIButton, button.accessibilityIdentifier == id { return button }
        for child in view.subviews {
            if let match = try? button(id, in: child) { return match }
        }
        throw MissingButton()
    }
    private struct MissingButton: Error {}

    @Test(arguments: [false, true]) func buttonsDispatchOnlyTheSelectedResponse(offer: Bool) throws {
        for accept in [false, true] {
            let view = popup(offer: offer)
            var responses: [Bool] = [], dismissals = 0
            view.respond = { responses.append($0) }; view.dismiss = { dismissals += 1 }
            let button = try button(accept ? "usageSuggestion-yes" : "usageSuggestion-no", in: view)
            #expect(view.hitTest(button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: view), with: nil) === button)
            button.sendActions(for: .touchUpInside)
            #expect(responses == [accept])
            #expect(dismissals == 0)
        }
    }

    @Test(arguments: [false, true]) func outsideTapAndAccessibilityEscapeDismissWithoutAnswering(offer: Bool) throws {
        let view = popup(offer: offer)
        var responses: [Bool] = [], dismissals = 0
        view.respond = { responses.append($0) }; view.dismiss = { dismissals += 1 }
        #expect(view.accessibilityViewIsModal)
        let outside = try #require(view.hitTest(CGPoint(x: 10, y: 700), with: nil) as? UIControl)
        #expect(outside === view)
        outside.sendActions(for: .touchUpInside)
        #expect(dismissals == 1 && responses.isEmpty)
        #expect(view.accessibilityPerformEscape())
        #expect(dismissals == 2 && responses.isEmpty)
    }

    // This verifies the action endpoint only. The XCUI hardware-key delivery failure remains open.
    @Test func escapeCommandTargetsDismissalWithoutChoosingPreference() throws {
        let view = popup(offer: true)
        var responses: [Bool] = [], dismissals = 0
        view.respond = { responses.append($0) }; view.dismiss = { dismissals += 1 }
        let command = try #require(view.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
        #expect(command.modifierFlags.isEmpty && command.wantsPriorityOverSystemBehavior)
        let action = try #require(command.action)
        #expect(UIApplication.shared.sendAction(action, to: view, from: command, for: nil))
        #expect(dismissals == 1 && responses.isEmpty)
    }
}

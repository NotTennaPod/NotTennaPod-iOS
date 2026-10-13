#if DEBUG
import UIKit

/// Isolated event-delivery fixture for the production dialog. Not a library
/// feature or proof of an end-to-end podcast journey.
@MainActor
final class MessageOverflowFixture: UIViewController {
    private var short = true
    private var dialog: SourceMessageController!
    private let toggle = UIButton(type: .system)
    private let result = UILabel()
    private var actionCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        toggle.setTitle("Grow", for: .normal)
        toggle.accessibilityIdentifier = "fixtureResize"
        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            short.toggle(); toggle.setTitle(short ? "Grow" : "Shrink", for: .normal)
            view.setNeedsLayout()
        }, for: .touchUpInside)
        result.text = "Actions: 0"; result.accessibilityIdentifier = "fixtureResult"
        view.addSubview(toggle); view.addSubview(result)
        func action(_ title: String, id: String) -> SourceMessageController.Action {
            .init(title: title, identifier: id, perform: { [weak self] in
                guard let self else { return }
                actionCount += 1; result.text = "Actions: \(actionCount), \(id)"
            })
        }
        dialog = SourceMessageController(title: "A warning title that needs two lines",
            message: Array(repeating: "Message body line", count: 8).joined(separator: "\n"),
            positive: action("Continue", id: "positive"), negative: action("Cancel", id: "negative"),
            neutral: action("More information", id: "neutral"))
        addChild(dialog); view.addSubview(dialog.view); dialog.didMove(toParent: self)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        toggle.frame = CGRect(x: safe.minX + 8, y: safe.minY, width: 90, height: 44)
        result.frame = CGRect(x: toggle.frame.maxX + 8, y: safe.minY, width: max(0, safe.width - 114), height: 44)
        dialog.view.frame = CGRect(x: safe.minX, y: safe.minY + 52, width: min(320, safe.width),
                                  height: short ? 160 : min(560, max(0, safe.height - 52)))
        dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
    }
}
#endif

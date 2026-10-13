#if DEBUG
import UIKit
import NotTennaPodCore

/// Actual event routing through the production chooser in a constrained window.
/// Embedded dismissal is observed at the control, not claimed as modal evidence.
@MainActor final class DefaultPageOverflowFixture: UIViewController {
    private var short = true
    private let toggle = UIButton(type: .system)
    private let result = UILabel()
    private var dialog: DefaultPageController?
    private var actionCount = 0
    private let preferences: NavigationPreferenceStore

    init(preferences: NavigationPreferenceStore) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
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
        let chooser = DefaultPageController(preferences: preferences)
        addChild(chooser); view.addSubview(chooser.view); chooser.didMove(toParent: self)
        dialog = chooser
        func observe(_ view: UIView) {
            if let control = view as? UIControl {
                control.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    actionCount += 1
                    result.text = "Actions: \(actionCount), \(preferences.value.defaultPage)"
                }, for: .touchUpInside)
            }
            view.subviews.forEach(observe)
        }
        observe(chooser.view)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        toggle.frame = CGRect(x: safe.minX + 8, y: safe.minY, width: 90, height: 44)
        result.frame = CGRect(x: toggle.frame.maxX + 8, y: safe.minY, width: max(0, safe.width - 114), height: 44)
        dialog?.view.frame = CGRect(x: safe.minX, y: safe.minY + 52, width: min(340, safe.width),
                                   height: short ? 180 : min(320, max(0, safe.height - 52)))
        dialog?.view.setNeedsLayout(); dialog?.view.layoutIfNeeded()
    }
}
#endif

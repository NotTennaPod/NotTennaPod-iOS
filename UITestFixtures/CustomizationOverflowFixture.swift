#if DEBUG
import UIKit
import NotTennaPodCore

@MainActor final class CustomizationOverflowFixture: UIViewController {
    private let preferences: NavigationPreferenceStore
    private var dialog: NavigationCustomizationController!
    private let toggle = UIButton(type: .system)
    private let result = UILabel()
    private let snapshot = UIButton(type: .system)
    private let offset = UILabel()
    private weak var list: UICollectionView?
    private var short = true
    private var actions = 0
    init(preferences: NavigationPreferenceStore) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        var seed = NavigationCustomization(preferences: preferences.value)
        seed.move(from: 2, to: 3)
        do { try preferences.update(seed.confirmed(updating: preferences.value)) }
        catch { preconditionFailure("Unable to seed isolated customization fixture") }
        toggle.accessibilityIdentifier = "fixtureResize"; toggle.setTitle("Grow", for: .normal)
        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            short.toggle(); toggle.setTitle(short ? "Grow" : "Shrink", for: .normal); view.setNeedsLayout()
        }, for: .touchUpInside)
        result.accessibilityIdentifier = "fixtureResult"; result.text = "Actions: 0"
        result.numberOfLines = 2; result.font = .systemFont(ofSize: 12)
        snapshot.setTitle("Snapshot", for: .normal); snapshot.accessibilityIdentifier = "fixtureSnapshot"
        offset.accessibilityIdentifier = "fixtureOffset"; offset.font = .systemFont(ofSize: 12)
        snapshot.addAction(UIAction { [weak self] _ in
            guard let self, let list else { return }
            offset.text = "Offset: \(list.contentOffset.y)"
            let point = CGPoint(x: list.bounds.width * 0.8, y: list.bounds.minY + list.contentInset.top / 2)
            offset.accessibilityValue = list.indexPathForItem(at: point).map { String($0.item) } ?? "none"
        }, for: .touchUpInside)
        [toggle, snapshot, result, offset].forEach(view.addSubview)
        dialog = NavigationCustomizationController(preferences: preferences)
        addChild(dialog); view.addSubview(dialog.view); dialog.didMove(toParent: self)
        func observe(_ view: UIView) {
            if let collection = view as? UICollectionView { list = collection }
            if let button = view as? UIButton {
                button.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    actions += 1
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        guard let self else { return }
                        let value = preferences.value.configuration
                        result.text = "Actions: \(actions); Home hidden: \(value.hiddenTags.contains(NavigationDestination.home.rawValue)); Default: \(value == NavigationConfiguration())"
                        result.accessibilityValue = value.orderedTags.joined(separator: ",") + "|"
                            + value.hiddenTags.joined(separator: ",") + "|" + preferences.value.defaultPage
                    }
                }, for: .touchUpInside)
            }
            view.subviews.forEach(observe)
        }
        observe(dialog.view)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        toggle.frame = CGRect(x: safe.minX + 8, y: safe.minY, width: 70, height: 44)
        snapshot.frame = CGRect(x: toggle.frame.maxX, y: safe.minY, width: 85, height: 44)
        result.frame = CGRect(x: snapshot.frame.maxX + 8, y: safe.minY, width: max(0, safe.width - 179), height: 24)
        offset.frame = CGRect(x: result.frame.minX, y: safe.minY + 24, width: result.frame.width, height: 20)
        dialog.view.frame = CGRect(x: safe.minX, y: safe.minY + 52, width: min(300, safe.width),
                                  height: short ? 220 : min(550, max(0, safe.height - 52)))
        dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
    }
}
#endif

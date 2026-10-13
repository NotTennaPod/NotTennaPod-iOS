import UIKit
import NotTennaPodCore

/// The Material action bar has its own scroll viewport. Controllers retain
/// ownership of the buttons and their save/cancel callbacks.
@MainActor final class NavigationDialogActions: UIScrollView {
    private let positive: UIButton
    private let negative: UIButton?
    private let neutral: UIButton?
    var onMetricsChange: (() -> Void)?

    init(positive: UIButton, negative: UIButton? = nil, neutral: UIButton? = nil) {
        self.positive = positive; self.negative = negative; self.neutral = neutral
        super.init(frame: .zero)
        contentInsetAdjustmentBehavior = .never
        for button in [positive, negative, neutral].compactMap({ $0 }) {
            addSubview(button)
            button.titleLabel?.adjustsFontForContentSizeCategory = false
            button.titleLabel?.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UILabel, _) in
                self?.onMetricsChange?()
            }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIScrollView, _) in
            self?.onMetricsChange?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        // Delivered button touches must yield when a footer/ancestor drag wins.
        if view === positive || view === negative || view === neutral { return true }
        return super.touchesShouldCancel(in: view)
    }

    func measuredLayout(width: CGFloat, rightToLeft: Bool, inheritedTraits: UITraitCollection? = nil) -> SourceMessageActionsLayout {
        let buttons = [positive, negative, neutral]
        for button in buttons.compactMap({ $0 }) {
            guard let label = button.titleLabel else { continue }
            let traits = inheritedTraits.map { Appearance.textMetricsTraits(inheriting: $0, through: [self, button, label]) }
                ?? label.traitCollection
            let font = Appearance.font(14, medium: true, compatibleWith: traits)
            if label.font != font { label.font = font }
        }
        return SourceMessageActionsLayout(width: width,
            positiveTextWidth: positive.titleLabel?.intrinsicContentSize.width ?? 0,
            negativeTextWidth: negative?.titleLabel?.intrinsicContentSize.width,
            neutralTextWidth: neutral?.titleLabel?.intrinsicContentSize.width,
            rightToLeft: rightToLeft,
            buttonHeight: (buttons.compactMap { $0?.titleLabel?.font.lineHeight }.max() ?? 0) + 20)
    }

    func apply(_ layout: SourceMessageActionsLayout, frame: CGRect) {
        let previousFrame = self.frame, previousSize = contentSize, previousOffset = contentOffset
        let idle = !isTracking && !isDragging && !isDecelerating
        self.frame = frame
        contentSize = CGSize(width: frame.width, height: layout.height)
        isScrollEnabled = layout.height > frame.height
        for (button, rect) in zip([positive, negative, neutral], [layout.positive, layout.negative, layout.neutral]) {
            if let button, let rect { button.frame = rect }
        }
        if idle, previousFrame != frame || previousSize != contentSize {
            let offset = CGPoint(x: 0, y: min(max(0, previousOffset.y), max(0, layout.height - frame.height)))
            if contentOffset != offset { setContentOffset(offset, animated: false) }
        }
    }
}

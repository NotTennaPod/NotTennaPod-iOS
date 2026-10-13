import UIKit
import NotTennaPodCore

/// The horizontally swipeable area of source `ItemPagerFragment` (ViewPager2 below the pager's toolbar).
///
/// Pages sit in visual slots: list order in left-to-right and mirrored in right-to-left, so the next episode is
/// revealed by dragging towards the reading start. There is no indicator, counter or arrow; swiping (or VoiceOver's
/// three-finger scroll) is the only way to change episode. The owner builds the pages and decides which page is
/// visible; this view only reports where the scrolling settled.
@MainActor final class EpisodePagerView: UIView, UIScrollViewDelegate {
    final class PagingScrollView: UIScrollView {
        weak var pager: EpisodePagerView?
        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            pager?.accessibilityPage(direction) ?? false
        }
    }

    let scroll = PagingScrollView()
    private(set) var count = 1
    private(set) var rightToLeft = false
    /// The settled page; changes only when scrolling stops on another page.
    private(set) var settledPage = 0
    private var containers: [Int: UIView] = [:]
    /// The page nearest the middle while scrolling moves (drives preloading of its neighbours).
    var onCenteredPageChanged: ((Int) -> Void)?
    var onSettled: ((Int) -> Void)?
    var onScrollingChanged: ((Bool) -> Void)?
    var accessibilityAnnouncement: ((Int) -> String?)?
    private var centeredPage = 0
    private(set) var isMoving = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "episodePager"
        scroll.pager = self
        scroll.accessibilityIdentifier = "episodePagerScroll"
        scroll.isPagingEnabled = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.scrollsToTop = false
        scroll.delegate = self
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Places the page containers. The settled page is moved into view unless a swipe is in progress.
    func update(count: Int, settled: Int, rightToLeft: Bool, pages: [Int: UIView]) {
        self.count = max(1, count); self.rightToLeft = rightToLeft
        for (index, view) in containers where pages[index] !== view { view.removeFromSuperview() }
        containers = pages
        if !isMoving { settledPage = settled; centeredPage = settled }
        // The settled page comes first, so every lookup by identifier finds the page a person sees.
        for index in pages.keys.sorted(by: { ($0 == settledPage ? 0 : 1, $0) < ($1 == settledPage ? 0 : 1, $1) }).reversed() {
            guard let view = pages[index] else { continue }
            if view.superview !== scroll { scroll.addSubview(view) }
            scroll.sendSubviewToBack(view)
        }
        setNeedsLayout(); layoutIfNeeded()
    }

    private func slot(of page: Int) -> Int { rightToLeft ? count - 1 - page : page }
    private func page(atSlot slot: Int) -> Int { min(max(0, rightToLeft ? count - 1 - slot : slot), count - 1) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        if scroll.frame != bounds { scroll.frame = bounds }
        scroll.contentSize = CGSize(width: width * CGFloat(count), height: bounds.height)
        for (index, view) in containers {
            view.frame = CGRect(x: CGFloat(slot(of: index)) * width, y: 0, width: width, height: bounds.height)
            // Only the settled page belongs to VoiceOver; neighbours are prepared off screen.
            view.accessibilityElementsHidden = index != settledPage
        }
        if !isMoving {
            let target = CGPoint(x: CGFloat(slot(of: settledPage)) * width, y: 0)
            if scroll.contentOffset != target { scroll.setContentOffset(target, animated: false) }
        }
    }

    // MARK: UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { setMoving(true) }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isMoving, bounds.width > 0 else { return }
        let centered = page(atSlot: Int((scrollView.contentOffset.x / bounds.width).rounded()))
        if centered != centeredPage { centeredPage = centered; onCenteredPageChanged?(centered) }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

    private func setMoving(_ moving: Bool) {
        guard isMoving != moving else { return }
        isMoving = moving; onScrollingChanged?(moving)
    }

    private func settle() {
        guard bounds.width > 0 else { return }
        let target = page(atSlot: Int((scroll.contentOffset.x / bounds.width).rounded()))
        setMoving(false)
        let changed = target != settledPage
        settledPage = target; centeredPage = target
        if changed { onSettled?(target) } else { setNeedsLayout() }
    }

    /// Moves one page as a finished swipe does (VoiceOver scrolling and tests). Returns whether it moved.
    @discardableResult
    func move(_ step: EpisodePagerModel.Step, animated: Bool) -> Bool {
        guard !isMoving else { return false }
        let target = step == .next ? settledPage + 1 : settledPage - 1
        guard (0..<count).contains(target), bounds.width > 0 else { return false }
        setMoving(true)
        centeredPage = target; onCenteredPageChanged?(target)
        let offset = CGPoint(x: CGFloat(slot(of: target)) * bounds.width, y: 0)
        if animated && scroll.contentOffset != offset { scroll.setContentOffset(offset, animated: true) }
        else { scroll.setContentOffset(offset, animated: false); settle() }
        return true
    }

    /// VoiceOver three-finger scroll: `.left` reveals the page on the right, which is the next page in
    /// left-to-right and the previous one in right-to-left (ViewPager2's mirrored page actions).
    fileprivate func accessibilityPage(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let step: EpisodePagerModel.Step
        switch direction {
        case .left: step = rightToLeft ? .previous : .next
        case .right: step = rightToLeft ? .next : .previous
        case .next: step = .next
        case .previous: step = .previous
        default: return false
        }
        let target = step == .next ? settledPage + 1 : settledPage - 1
        guard move(step, animated: false) else { return false }
        UIAccessibility.post(notification: .pageScrolled, argument: accessibilityAnnouncement?(target))
        return true
    }
}

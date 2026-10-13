import UIKit

/// The active Android path does not register a MediaRouter compat media session:
/// the classic controller shows receiver title/volume and session actions, not
/// an invented second episode player.
@MainActor final class CastConnectedController: UIViewController {
    private let runtime: CastApplicationRuntime
    private let identity: CastSessionIdentity
    private let clock: any CastChooserClock
    private let panel = UIView(), scroll = CastVolumeScrollView(), volumePanel = UIView()
    private let name = Appearance.label(nil, size: 20)
    private let volume = CastReceiverVolumeSlider()
    private let audio = UIImageView(image: UIImage(named: "cast_audio"))
    private let close = UIButton(type: .custom), disconnect = UIButton(type: .custom), stop = UIButton(type: .custom)
    private var observation: CastChooserCancellation?
    private var volumeUpdate: CastChooserCancellation?
    private enum VolumeTarget: Equatable { case receiver, member(String) }
    private var trackingVolume: VolumeTarget?
    private var pendingUpdate = false
    private var receivedState: CastConnectionState?
    private var closing = false
    private var lastRightToLeft: Bool?
    private let groupList = CastVolumeScrollView(), expand = UIButton(type: .custom)
    private var chevron: CastGroupChevron!
    private var groupRows: [String: CastMemberVolumeRow] = [:]
    private var memberOrder: [String] = []
    private var pendingMemberReveal = Set<String>()
    private var groupExpanded = false
    private var groupAnimation: UIViewPropertyAnimator?
    init(runtime: CastApplicationRuntime, identity: CastSessionIdentity, clock: any CastChooserClock = ContinuousCastChooserClock()) {
        self.runtime = runtime; self.identity = identity
        self.clock = clock
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    override var canBecomeFirstResponder: Bool { !closing }
    override var keyCommands: [UIKeyCommand]? {
        guard !closing else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFromKeyboard(_:)))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }
    // Take keyboard focus as the dialog appears, so Escape works during the fade-in too.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        becomeFirstResponder()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        resignFirstResponder()
    }
    @objc private func closeFromKeyboard(_ command: UIKeyCommand) { dismissController() }


    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32); view.accessibilityViewIsModal = true
        view.addSubview(panel); panel.addSubview(scroll)
        panel.backgroundColor = Appearance.color(0xffffff, 0x424242); panel.clipsToBounds = true
        panel.accessibilityIdentifier = "castConnectedPanel"
        // Already inside the presenting view's physical safe area.
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "castConnectedContent"
        for child in [name, close, volumePanel, disconnect, stop] { scroll.addSubview(child) }
        volumePanel.addSubview(audio); volumePanel.addSubview(volume); volumePanel.addSubview(expand)
        scroll.addSubview(groupList); groupList.clipsToBounds = true
        groupList.contentInsetAdjustmentBehavior = .never
        groupList.backgroundColor = Appearance.accent
        groupList.accessibilityIdentifier = "castGroupMembers"
        expand.accessibilityIdentifier = "castGroupExpand"
        expand.tintColor = .white
        chevron = CastGroupChevron(button: expand)
        expand.addAction(UIAction { [weak self] _ in
            guard let self, !closing, memberOrder.count > 1 else { return }
            finishGroupAnimation()
            view.layoutIfNeeded(); groupExpanded.toggle(); updateExpand()
            animateGroupLayout(expanding: groupExpanded)
        }, for: .touchUpInside)
        volumePanel.backgroundColor = Appearance.accent
        audio.tintColor = .white
        name.numberOfLines = 1; name.lineBreakMode = .byTruncatingTail
        name.adjustsFontForContentSizeCategory = false
        name.textColor = Appearance.color(0x212121, 0xffffff)
        name.accessibilityIdentifier = "castConnectedName"
        close.setImage(UIImage(named: "cast_close"), for: .normal); close.tintColor = Appearance.foreground
        close.accessibilityLabel = Appearance.text("mr_controller_close_description"); close.accessibilityIdentifier = "castConnectedClose"
        close.addAction(UIAction { [weak self] _ in self?.dismissController() }, for: .touchUpInside)
        for (button, title, id, stopReceiver) in [(disconnect, "mr_controller_disconnect", "castDisconnect", false), (stop, "mr_controller_stop_casting", "castStop", true)] {
            button.setTitle(Appearance.text(title), for: .normal); button.setTitleColor(Appearance.accent, for: .normal)
            button.accessibilityIdentifier = id
            button.titleLabel?.numberOfLines = 0; button.titleLabel?.lineBreakMode = .byWordWrapping
            button.addAction(UIAction { [weak self] _ in
                guard let self, !closing else { return }
                // The displayed route may have ended while a volume gesture
                // defers dismissal. An old dialog must not stop its replacement.
                if runtime.state.identity == identity, runtime.state.phase == .connected {
                    guard stopReceiver || runtime.state.canDisconnect else { return }
                    runtime.end(stopReceiver: stopReceiver)
                }
                dismissController()
            }, for: .touchUpInside)
        }
        volume.accessibilityIdentifier = "castReceiverVolume"
        volume.accessibilityLabel = Appearance.text("mr_controller_volume_slider")
        volume.addAction(UIAction { [weak self] _ in
            guard let self, !closing, runtime.state.identity == identity, runtime.state.phase == .connected, runtime.state.hasVariableVolume else { return }
            runtime.setVolume(volume.value)
        }, for: .valueChanged)
        volume.addAction(UIAction { [weak self] _ in self?.beginVolumeTouch(.receiver) }, for: .editingDidBegin)
        volume.addAction(UIAction { [weak self] _ in self?.endVolumeTouch(.receiver) }, for: .editingDidEnd)
        for label in [name, disconnect.titleLabel!, stop.titleLabel!] {
            label.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UILabel, _) in self?.view.setNeedsLayout() }
        }
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLayoutDirection.self]) { [weak self] (_: UIView, _) in self?.view.setNeedsLayout() }
        let outside = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
        observation = runtime.observe({ [weak self] in self?.render($0) }, problem: { _ in })
    }
    override func viewSafeAreaInsetsDidChange() { super.viewSafeAreaInsetsDidChange(); view.setNeedsLayout() }
    private func beginVolumeTouch(_ target: VolumeTarget) {
        guard !closing else { return }
        volumeUpdate?.cancel(); volumeUpdate = nil; trackingVolume = target
    }
    private func endVolumeTouch(_ target: VolumeTarget) {
        guard !closing, trackingVolume == target else { return }
        volumeUpdate?.cancel()
        volumeUpdate = clock.schedule(after: 0.5) { [weak self] in
            guard let self else { return }
            volumeUpdate = nil; trackingVolume = nil
            if pendingUpdate { pendingUpdate = false; render(runtime.state) }
        }
    }
    private func render(_ state: CastConnectionState) {
        guard !closing else { return }
        guard state.identity == identity, state.phase == .connected else {
            // Source update() defers route loss as well as content changes until
            // the current gesture and its shared500ms settling window finish.
            if trackingVolume != nil { pendingUpdate = true }
            else { dismissController() }
            return
        }
        let previous = receivedState; receivedState = state
        // The source master slider consumes unsuppressed volume callbacks and
        // initial/re-enabled volume layout. A settled touch does not replay a
        // volume callback discarded during that touch.
        if trackingVolume != .receiver,
           previous == nil || previous?.volume != state.volume || previous?.muted != state.muted
            || previous?.hasVariableVolume == false && state.hasVariableVolume {
            volume.value = state.muted ? 0 : state.volume
        }
        if trackingVolume != nil {
            pendingUpdate = true
            // Unrelated route-volume callbacks remain live even while general
            // dialog updates (names, membership, capabilities) are deferred.
            for member in state.members where trackingVolume != .member(member.id) {
                if let old = previous?.members.first(where: { $0.id == member.id }),
                   old.volume != member.volume || old.muted != member.muted {
                    groupRows[member.id]?.updateVolume(member)
                }
            }
            return
        }
        let ids = state.members.map(\.id)
        let membershipChanged = ids != memberOrder
        for id in memberOrder where !ids.contains(id) {
            pendingMemberReveal.remove(id)
            if let row = groupRows.removeValue(forKey: id) {
                row.retire(); row.isAccessibilityElement = false; row.accessibilityElementsHidden = true
                if groupExpanded {
                    UIView.animate(withDuration: 0.2, animations: { row.alpha = 0 }, completion: { _ in row.removeFromSuperview() })
                } else { row.removeFromSuperview() }
            }
        }
        memberOrder = ids
        for member in state.members {
            if groupRows[member.id] == nil {
                let row = CastMemberVolumeRow(member: member, begin: { [weak self] in self?.beginVolumeTouch(.member(member.id)) },
                    end: { [weak self] in self?.endVolumeTouch(.member(member.id)) }, change: { [weak self] value in
                    guard let self, !closing, runtime.state.identity == identity, runtime.state.phase == .connected else { return }
                    runtime.setMemberVolume(value, memberID: member.id)
                }, relayout: { [weak self] in self?.view.setNeedsLayout() })
                groupRows[member.id] = row; groupList.addSubview(row)
                if groupExpanded { row.alpha = 0; pendingMemberReveal.insert(member.id) }
            }
            groupRows[member.id]?.render(member)
        }
        updateExpand()
        if membershipChanged, groupExpanded { animateGroupLayout(expanding: true) }
        name.text = state.name
        disconnect.isHidden = !state.canDisconnect
        disconnect.isEnabled = state.canDisconnect
        volumePanel.isHidden = !state.hasVariableVolume
        volume.isEnabled = state.hasVariableVolume
        if !state.hasVariableVolume {
            volume.cancelTracking(with: nil)
        }
        view.setNeedsLayout()
    }
    private func updateExpand() {
        expand.isHidden = memberOrder.count <= 1
        expand.accessibilityLabel = Appearance.text(groupExpanded ? "mr_controller_collapse_group" : "mr_controller_expand_group")
        groupList.accessibilityElementsHidden = !groupExpanded || expand.isHidden
        chevron?.update(expanded: groupExpanded)
    }
    private func finishGroupAnimation() {
        guard let animator = groupAnimation else { return }; groupAnimation = nil
        if animator.state == .active { animator.stopAnimation(false) }
        if animator.state == .stopped { animator.finishAnimation(at: .end) }
    }
    private func animateGroupLayout(expanding: Bool) {
        finishGroupAnimation()
        let animator = UIViewPropertyAnimator(duration: 0.4,
            controlPoint1: CGPoint(x: expanding ? 0 : 0.4, y: 0), controlPoint2: CGPoint(x: 0.2, y: 1))
        animator.addAnimations { [weak self] in self?.view.setNeedsLayout(); self?.view.layoutIfNeeded() }
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, self.groupAnimation === animator else { return }
            self.groupAnimation = nil
            let revealing = pendingMemberReveal.compactMap { groupRows[$0] }; pendingMemberReveal.removeAll()
            if groupExpanded { UIView.animate(withDuration: 0.4) { for row in revealing { row.alpha = 1 } } }
            else { for row in revealing { row.alpha = 1 } }
        }
        groupAnimation = animator; animator.startAnimation()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        guard safe.size.width > 48, safe.size.height > 48 else { panel.isHidden = true; return }
        panel.isHidden = false
        let size = view.bounds.size, portrait = view.bounds.width < view.bounds.height
        let shortest = min(size.width, size.height)
        let desired: CGFloat = shortest >= 720 ? size.width * (portrait ? 0.7 : 0.5)
            : shortest >= 600 ? size.width * (portrait ? 0.9 : 0.6) : 320
        let panelWidth = min(desired, safe.size.width - 48), width = max(192, panelWidth)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(_ leading: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rtl ? width - leading - w : leading, y: y, width: w, height: h)
        }
        name.font = Appearance.font(20, medium: true, compatibleWith: name.traitCollection)
        name.textAlignment = rtl ? .right : .left
        let header = max(72, ceil(name.font.lineHeight + 24))
        name.frame = frame(24, 0, width - 84, header)
        close.frame = frame(width - 60, (header - 48) / 2, 48, 48)
        let volumeHeight: CGFloat = volumePanel.isHidden ? 0 : 80
        volumePanel.frame = CGRect(x: 0, y: header, width: width, height: volumeHeight)
        audio.frame = frame(24, 28, 24, 24)
        volume.frame = frame(48, 16, width - 60 - (expand.isHidden ? 0 : 48), 48)
        expand.frame = frame(width - 60, 16, 48, 48)
        volume.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        for button in [disconnect, stop] {
            button.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: button.titleLabel?.traitCollection)
        }
        let disconnectWidth: CGFloat = disconnect.isHidden ? 0 : max(64, ceil(disconnect.titleLabel?.intrinsicContentSize.width ?? 0) + 16)
        let stopWidth = max(64, ceil(stop.titleLabel?.intrinsicContentSize.width ?? 0) + 16)
        let visibleActions = disconnect.isHidden ? [stop] : [disconnect, stop]
        let actionHeight = max(48, ceil((visibleActions.map { $0.titleLabel?.font.lineHeight ?? 0 }.max() ?? 0) + 20))
        let stacked = disconnectWidth + stopWidth + 24 > width
        var height = header + volumeHeight + 4
        disconnect.frame = .zero
        if stacked {
            let stopHeight = max(actionHeight, ceil(stop.titleLabel?.sizeThatFits(CGSize(width: width - 24, height: .greatestFiniteMagnitude)).height ?? 0) + 20)
            let disconnectHeight = max(actionHeight, ceil(disconnect.titleLabel?.sizeThatFits(CGSize(width: width - 24, height: .greatestFiniteMagnitude)).height ?? 0) + 20)
            stop.frame = frame(12, height, width - 24, stopHeight); height += stopHeight
            if !disconnect.isHidden {
                disconnect.frame = frame(12, height, width - 24, disconnectHeight); height += disconnectHeight
            }
        } else {
            stop.frame = frame(width - 12 - stopWidth, height, stopWidth, actionHeight)
            if !disconnect.isHidden {
                disconnect.frame = frame(width - 12 - stopWidth - disconnectWidth, height, disconnectWidth, actionHeight)
            }
            height += actionHeight
        }
        height += 4
        let footerHeight = height - header - volumeHeight
        var listHeight: CGFloat = 0
        let oldMemberOffset = groupList.contentOffset.y
        var memberHeight: CGFloat = 16
        let landscape = size.width > size.height
        for id in memberOrder {
            guard let row = groupRows[id] else { continue }
            row.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            let rowHeight = row.height(landscape: landscape)
            let target = CGRect(x: 0, y: memberHeight, width: width, height: rowHeight)
            row.landscape = landscape
            if row.needsInitialPlacement {
                UIView.performWithoutAnimation { row.frame = target; row.setNeedsLayout(); row.layoutIfNeeded() }
                row.needsInitialPlacement = false
            } else { row.frame = target; row.setNeedsLayout() }
            memberHeight += rowHeight
        }
        if groupExpanded, memberOrder.count > 1 {
            let cap: CGFloat = landscape ? 132 : 288
            let available = safe.height - 48 - height
            // Shrink member viewport first. At extents smaller than the fixed
            // controls, retain one usable row and let the outer panel scroll.
            listHeight = min(memberHeight, cap, max(40, available))
        }
        groupList.frame = CGRect(x: 0, y: header + volumeHeight, width: width, height: listHeight)
        groupList.contentSize = CGSize(width: width, height: memberHeight)
        groupList.contentOffset.y = min(max(0, oldMemberOffset), max(0, memberHeight - listHeight))
        stop.frame.origin.y += listHeight
        if !disconnect.isHidden { disconnect.frame.origin.y += listHeight }
        height = header + volumeHeight + listHeight + footerHeight
        let viewportHeight = min(height, safe.height - 48)
        panel.frame = CGRect(x: safe.midX - panelWidth / 2, y: safe.midY - viewportHeight / 2, width: panelWidth, height: viewportHeight)
        let old = scroll.contentOffset
        let oldMaxX = max(0, scroll.contentSize.width - scroll.bounds.width)
        let leadingOffset = lastRightToLeft == true ? oldMaxX - old.x : old.x
        lastRightToLeft = rtl
        scroll.frame = panel.bounds; scroll.contentSize = CGSize(width: width, height: height)
        scroll.isScrollEnabled = width > panelWidth || height > viewportHeight
        let maxX = max(0, width - panelWidth)
        let retainedLeading = min(max(0, leadingOffset), maxX)
        scroll.contentOffset = CGPoint(x: rtl ? maxX - retainedLeading : retainedLeading, y: min(max(0, old.y), max(0, height - viewportHeight)))
    }
    @objc private func outside(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { dismissController() }
    }
    private func dismissController() {
        guard !closing else { return }; closing = true
        observation?.cancel(); volumeUpdate?.cancel(); volumeUpdate = nil; trackingVolume = nil; pendingUpdate = false
        groupAnimation?.stopAnimation(true); for row in groupRows.values { row.retire() }
        dismiss(animated: true)
    }
    override func accessibilityPerformEscape() -> Bool { dismissController(); return true }
}

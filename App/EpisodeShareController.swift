import UIKit
import NotTennaPodCore

/// ShareDialog's application-owned choices precede the system share recipient.
@MainActor final class EpisodeShareController: UIViewController {
    private let feed: LibraryFeed, episode: LibraryEpisode
    private let share: (Any) -> Void
    private let defaults: UserDefaults
    private let panel = UIView(), scroll = UIScrollView()
    private let heading = Appearance.label(Appearance.text("share_label"), size: 22)
    private let position = EpisodeShareCheckbox(type: .custom)
    private var cards: [UIButton] = [], titles: [UILabel] = [], descriptions: [UILabel] = [], icons: [UIImageView] = []
    private var withPosition: Bool
    init(feed: LibraryFeed, episode: LibraryEpisode, defaults: UserDefaults = .standard, share: @escaping (Any) -> Void) {
        self.feed = feed; self.episode = episode; self.defaults = defaults; self.share = share
        withPosition = defaults.bool(forKey: "shareEpisodeStartAt")
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    private func social(abbreviated: Bool) -> String {
        EpisodeShareText.social(feed: feed, episode: episode, withPosition: withPosition, abbreviated: abbreviated,
            startingPosition: Appearance.text("share_starting_position_label"), website: Appearance.text("share_dialog_episode_website_label"),
            mediaFile: Appearance.text("share_dialog_media_file_label"))
    }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.accessibilityViewIsModal = true; panel.accessibilityIdentifier = "episodeShareSheet"
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28; panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]; panel.clipsToBounds = true
        view.addSubview(panel); panel.addSubview(scroll); scroll.contentInsetAdjustmentBehavior = .never
        heading.accessibilityTraits.insert(.header); scroll.addSubview(heading)
        addCard("share_dialog_for_social", description: social(abbreviated: true), id: "episodeShareSocial") { [weak self] in self?.social(abbreviated: false) }
        if let media = episode.details.media {
            if let url = media.url { addCard("share_dialog_media_address", description: url, id: "episodeShareMediaAddress") { url } }
            if episode.userState.isDownloaded, let file = episode.userState.localFileURL {
                addCard("share_dialog_media_file_label", description: "", id: "episodeShareFile") { URL(fileURLWithPath: file) }
            }
        }
        position.accessibilityIdentifier = "episodeSharePosition"
        position.setTitle(Appearance.text("share_playback_position_dialog_label"), for: .normal)
        position.setTitleColor(Appearance.foreground, for: .normal); position.tintColor = Appearance.accent
        position.contentHorizontalAlignment = .leading; position.titleLabel?.numberOfLines = 0
        position.addAction(UIAction { [weak self] _ in
            guard let self else { return }; withPosition.toggle(); defaults.set(withPosition, forKey: "shareEpisodeStartAt")
            updatePosition(); descriptions[0].text = social(abbreviated: true)
            cards[0].accessibilityValue = descriptions[0].text; view.setNeedsLayout()
        }, for: .touchUpInside)
        scroll.addSubview(position); updatePosition()
        scroll.accessibilityElements = [heading, cards[0], position] + Array(cards.dropFirst())
        let tap = UITapGestureRecognizer(target: self, action: #selector(outside(_:))); tap.cancelsTouchesInView = false; view.addGestureRecognizer(tap)
    }
    private func updatePosition() {
        position.checked = withPosition
        position.accessibilityValue = Appearance.text(withPosition ? "episode_share_checked" : "episode_share_not_checked")
    }
    private func addCard(_ key: String, description: String, id: String, value: @escaping () -> Any?) {
        let card = UIButton(type: .custom), title = Appearance.label(Appearance.text(key), size: 16), detail = Appearance.label(description, size: 14)
        title.numberOfLines = 0; detail.numberOfLines = cards.isEmpty ? 7 : 2; detail.lineBreakMode = .byTruncatingTail
        let icon = UIImageView(image: UIImage(named: "ic_share")); icon.tintColor = Appearance.foreground; icon.contentMode = .scaleAspectFit
        [title, detail, icon].forEach { $0.isUserInteractionEnabled = false; card.addSubview($0) }
        card.backgroundColor = Appearance.navigation; card.layer.cornerRadius = 4
        card.layer.shadowOpacity = 0.18; card.layer.shadowRadius = 1; card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.accessibilityIdentifier = id; card.accessibilityLabel = title.text; card.accessibilityValue = detail.text
        card.addAction(UIAction { [weak self] _ in
            guard let self, let content = value() else { return }
            dismiss(animated: true) { self.share(content) }
        }, for: .touchUpInside)
        scroll.addSubview(card); cards.append(card); titles.append(title); descriptions.append(detail); icons.append(icon)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame, width = min(640, max(0, safe.width))
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let contentWidth = max(0, width - 32), textWidth = max(0, contentWidth - 72)
        heading.font = Appearance.font(22, compatibleWith: traitCollection)
        let headingHeight = heading.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height
        heading.frame = CGRect(x: 16, y: 16, width: contentWidth, height: headingHeight)
        var y = heading.frame.maxY + 16
        for index in cards.indices {
            titles[index].font = Appearance.font(16, medium: true, compatibleWith: traitCollection)
            descriptions[index].font = Appearance.font(14, compatibleWith: traitCollection)
            let titleHeight = titles[index].sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let detailHeight = descriptions[index].text?.isEmpty == false ? descriptions[index].sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height : 0
            titles[index].frame = CGRect(x: rtl ? 56 : 16, y: 16, width: textWidth, height: titleHeight)
            descriptions[index].frame = CGRect(x: rtl ? 56 : 16, y: 16 + titleHeight, width: textWidth, height: detailHeight)
            var height = 32 + titleHeight + detailHeight
            if index == 0 {
                position.titleLabel?.font = Appearance.font(14, compatibleWith: traitCollection)
                let checkHeight = max(48, (position.titleLabel?.sizeThatFits(CGSize(width: max(0, contentWidth - 96), height: .greatestFiniteMagnitude)).height ?? 0) + 16)
                position.frame = CGRect(x: rtl ? 56 : 8, y: 16 + titleHeight + detailHeight, width: max(0, contentWidth - 64), height: checkHeight)
                height = position.frame.maxY
                position.frame = position.frame.offsetBy(dx: 16, dy: y)
            }
            icons[index].frame = CGRect(x: rtl ? 16 : contentWidth - 40, y: (height - 24) / 2, width: 24, height: 24)
            cards[index].frame = CGRect(x: 16, y: y, width: contentWidth, height: height); y += height + 16
        }
        let height = min(safe.height, y), bottom = view.bounds.maxY - safe.maxY
        panel.frame = CGRect(x: safe.midX - width / 2, y: safe.maxY - height, width: width, height: height + bottom)
        scroll.frame = CGRect(x: 0, y: 0, width: width, height: height); scroll.contentSize = CGSize(width: width, height: y)
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))]
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func outside(_ gesture: UITapGestureRecognizer) { if !panel.frame.contains(gesture.location(in: view)) { dismiss(animated: true) } }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }
}

@MainActor private final class EpisodeShareCheckbox: UIButton {
    var checked = false { didSet { setNeedsDisplay() } }
    override func titleRect(forContentRect rect: CGRect) -> CGRect {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        return CGRect(x: rtl ? 0 : 32, y: 0, width: max(0, rect.width - 32), height: rect.height)
    }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let x: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - 24 : 4
        let box = UIBezierPath(roundedRect: CGRect(x: x, y: bounds.midY - 9, width: 18, height: 18), cornerRadius: 1)
        (checked ? Appearance.accent : Appearance.secondary).setStroke(); box.lineWidth = 2; box.stroke()
        if checked {
            Appearance.accent.setFill(); box.fill(); UIColor.white.setStroke()
            let mark = UIBezierPath(); mark.move(to: CGPoint(x: x + 3, y: bounds.midY))
            mark.addLine(to: CGPoint(x: x + 7, y: bounds.midY + 4)); mark.addLine(to: CGPoint(x: x + 15, y: bounds.midY - 5))
            mark.lineWidth = 2; mark.stroke()
        }
    }
}

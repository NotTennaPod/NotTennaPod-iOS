import UIKit
import NotTennaPodCore

@MainActor
enum FeedLogDetailsDialog {
    /// Header's isJumpToFeed=false path. Caller resolves the current feed first.
    static func make(_ details: FeedLogDetails,
                     copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }) -> SourceMessageController {
        make(details, open: nil, copy: copy)
    }
    static func make(_ details: FeedLogDetails, open: (() -> Void)?,
                     copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }) -> SourceMessageController {
        let body = FeedLogDetailsBody(details, copy: copy)
        let controller = SourceMessageController(title: Appearance.text("download_error_details"), message: "",
            positive: .init(title: Appearance.text("ok"), identifier: "feedLogDetailsOK"),
            neutral: .init(title: Appearance.text("copy_to_clipboard"), identifier: "feedLogDetailsCopy",
                          perform: { copy(details.clipboard) }),
            customBody: body)
        if details.feedID != nil, let open {
            body.addOpen { [weak controller] in controller?.dismiss(animated: true, completion: open) }
        }
        return controller
    }
}

/// The original custom view has 24-point padding and an eight-point gap before
/// each status/detail section. Field taps copy without dismissing the parent.
@MainActor
final class FeedLogDetailsBody: UIView {
    private struct Section {
        let heading, value: UILabel
        let gap: CGFloat
    }
    private var sections: [Section] = []
    private var openButton: UIButton?

    init(_ details: FeedLogDetails, copy: @escaping (String) -> Void) {
        super.init(frame: .zero)
        accessibilityIdentifier = "feedLogDetailsBody"
        if let podcast = details.podcast {
            addSection("feed", value: podcast, id: "feedLogPodcast", gap: 0, singleLine: true)
        }
        if let episode = details.episode {
            addSection("episode", value: episode, id: "feedLogEpisode", gap: 8, singleLine: true)
            sections.last?.value.lineBreakMode = .byTruncatingMiddle
        }
        addSection("download_log_details_human_readable_reason_title", value: details.status,
                   id: "feedLogStatus", gap: 8)
        addSection("download_log_details_technical_reason_title", value: details.technical,
                   id: "feedLogTechnical", gap: 8, copy: copy)
        addSection("download_log_details_file_url_title", value: details.fileURL,
                   id: "feedLogURL", gap: 8, copy: copy)
        // A server library: when the server and this device last refreshed the podcast.
        if !details.origins.isEmpty {
            addSection("ntp_refresh_last_title", value: details.origins.joined(separator: "\n"), id: "feedLogOrigins", gap: 8)
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (body: FeedLogDetailsBody, _) in
            body.sections.forEach { $0.heading.font = Appearance.font(16, medium: true); $0.value.font = Appearance.font(14) }
            body.setNeedsLayout(); body.superview?.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func addOpen(_ action: @escaping () -> Void) {
        let button = UIButton(type: .custom)
        button.setTitle(Appearance.text("download_log_open_feed"), for: .normal)
        button.setTitleColor(Appearance.accent, for: .normal)
        button.titleLabel?.font = Appearance.font(14, medium: true)
        button.accessibilityIdentifier = "downloadLogOpenPodcast"
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        addSubview(button); openButton = button
    }

    private func addSection(_ key: String, value: String, id: String, gap: CGFloat,
                            singleLine: Bool = false, copy: ((String) -> Void)? = nil) {
        let heading = Appearance.label(Appearance.text(key), size: 16)
        heading.font = Appearance.font(16, medium: true)
        heading.accessibilityTraits.insert(.header); heading.accessibilityIdentifier = id + "Heading"
        let label = Appearance.label(value, size: 14)
        label.textColor = Appearance.secondary
        label.accessibilityIdentifier = id
        if singleLine { label.numberOfLines = 1; label.lineBreakMode = .byTruncatingTail }
        if let copy {
            let tap = UIAction { _ in copy(value) }
            let control = FieldCopyControl(action: tap)
            control.accessibilityIdentifier = id + "Copy"
            control.isAccessibilityElement = false
            label.addSubview(control); label.isUserInteractionEnabled = true
            label.accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("copy_to_clipboard")) { _ in
                copy(value); return true
            }]
        }
        addSubview(heading); addSubview(label); sections.append(Section(heading: heading, value: label, gap: gap))
    }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let contentWidth = max(0, width - 48)
        var y: CGFloat = 24
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for section in sections {
            y += section.gap
            let opens = section.value.accessibilityIdentifier == "feedLogPodcast" && openButton != nil
            let buttonWidth = opens ? min(contentWidth, (openButton?.sizeThatFits(.zero).width ?? 0) + 24) : 0
            let width = max(0, contentWidth - (opens ? buttonWidth + 8 : 0))
            // Source TitleMedium ends four points before the value's trailing edge.
            let headingWidth = max(0, width - 4)
            let headingHeight = section.heading.sizeThatFits(CGSize(width: headingWidth, height: .greatestFiniteMagnitude)).height
            let valueHeight = max(section.value.font.lineHeight,
                section.value.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            if apply {
                let start: CGFloat = 24 + (rtl && opens ? buttonWidth + 8 : 0)
                section.heading.frame = CGRect(x: start + (rtl ? 4 : 0), y: y, width: headingWidth, height: ceil(headingHeight))
                section.value.frame = CGRect(x: start, y: y + ceil(headingHeight), width: width, height: ceil(valueHeight))
                section.heading.textAlignment = rtl ? .right : .left; section.value.textAlignment = section.heading.textAlignment
                section.value.subviews.forEach { $0.frame = section.value.bounds }
                if opens { openButton?.frame = CGRect(x: rtl ? 24 : 24 + contentWidth - buttonWidth, y: y,
                                                     width: buttonWidth, height: max(48, ceil(headingHeight) + ceil(valueHeight))) }
            }
            y += max(opens ? 48 : 0, ceil(headingHeight) + ceil(valueHeight))
        }
        return y + 24
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: arrange(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = arrange(width: bounds.width, apply: true) }
}

@MainActor
private final class FieldCopyControl: UIControl {
    init(action: UIAction) { super.init(frame: .zero); addAction(action, for: .touchUpInside) }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? Appearance.foreground.withAlphaComponent(0.08) : .clear }
    }
}

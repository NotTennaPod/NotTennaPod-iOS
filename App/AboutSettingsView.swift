import UIKit
import NotTennaPodCore

/// Settings → About for NotTennaPod, composed like Android's `AboutFragment`
/// (`preferences_about.xml`): the teaser banner, then preference rows. The statement that NotTennaPod is not
/// AntennaPod follows the banner. Version copies itself on a tap, as Android's does; Licenses lists what ships.
/// Contributors and Privacy policy are left out: both are AntennaPod's own.
@MainActor final class AboutSettingsView: UIView {
    var onCopyVersion: ((String) -> Void)?
    var onOpenLicenses: (() -> Void)?
    /// Frames laid out leading to trailing; mirrored for right-to-left layout.
    private var items: [(view: UIView, frame: CGRect)] = []

    static var versionSummary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        var y: CGFloat = 0
        let banner = UIImageView(image: UIImage(named: "about-teaser"))
        banner.contentMode = .scaleAspectFill
        banner.clipsToBounds = true
        banner.isAccessibilityElement = false
        banner.accessibilityIdentifier = "aboutTeaser"
        let bannerHeight = (width * 500 / 1024).rounded()
        place(banner, CGRect(x: 0, y: 0, width: width, height: bannerHeight)); y = bannerHeight + 16

        let textWidth = max(0, width - 32)
        let heading = Appearance.label(Appearance.text("about_nottennapod_title"), size: 16)
        heading.font = Appearance.font(16, medium: true)
        heading.numberOfLines = 0
        heading.accessibilityTraits = .header
        heading.accessibilityIdentifier = "aboutStatementTitle"
        let headingHeight = heading.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        place(heading, CGRect(x: 16, y: y, width: textWidth, height: headingHeight)); y += headingHeight + 8
        let statement = Appearance.label(Appearance.text("about_nottennapod_message"), size: 14)
        statement.textColor = Appearance.secondary
        statement.numberOfLines = 0
        statement.accessibilityIdentifier = "aboutStatement"
        let statementHeight = statement.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        place(statement, CGRect(x: 16, y: y, width: textWidth, height: statementHeight)); y += statementHeight + 8

        let version = Self.versionSummary
        y = row(y: y, width: width, icon: "ic_star", title: Appearance.text("nottennapod_version"), summary: version,
                identifier: "about_version") { [weak self] in self?.onCopyVersion?(version) }
        y = row(y: y, width: width, icon: "ic_info", title: Appearance.text("licenses"), summary: Appearance.text("licenses_summary"),
                identifier: "about_licenses") { [weak self] in self?.onOpenLicenses?() }
        frame.size.height = y + 16
        registerForTraitChanges([UITraitLayoutDirection.self]) { (view: AboutSettingsView, _) in view.setNeedsLayout() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func place(_ view: UIView, _ frame: CGRect) {
        addSubview(view); items.append((view, frame)); view.frame = frame
    }

    /// A preference row as in Settings: 24-point icon at 16, title and summary from 72, at least 64 points high.
    private func row(y: CGFloat, width: CGFloat, icon: String, title: String, summary: String, identifier: String,
                     action: @escaping () -> Void) -> CGFloat {
        let textWidth = max(0, width - 72 - 16)
        let titleLabel = Appearance.label(title, size: 16)
        let summaryLabel = Appearance.label(summary, size: 14)
        summaryLabel.textColor = Appearance.secondary
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let summaryHeight = summaryLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let height = max(64, titleHeight + summaryHeight + 32)
        let control = UIControl()
        control.isAccessibilityElement = true
        control.accessibilityLabel = title
        control.accessibilityHint = summary
        control.accessibilityTraits = .button
        control.accessibilityIdentifier = identifier
        control.addAction(UIAction { _ in action() }, for: .touchUpInside)
        place(control, CGRect(x: 0, y: y, width: width, height: height))
        let image = UIImageView(image: UIImage(named: icon)); image.tintColor = Appearance.secondary
        let top = (height - titleHeight - summaryHeight) / 2
        for (view, frame) in [(image as UIView, CGRect(x: 16, y: y + (height - 24) / 2, width: 24, height: 24)),
                              (titleLabel, CGRect(x: 72, y: y + top, width: textWidth, height: titleHeight)),
                              (summaryLabel, CGRect(x: 72, y: y + top + titleHeight, width: textWidth, height: summaryHeight))] {
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false  // the row speaks for them
            place(view, frame)
        }
        return y + height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (view, frame) in items {
            view.frame = rtl ? CGRect(x: bounds.width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height) : frame
            (view as? UILabel)?.textAlignment = .natural
        }
    }
}

/// Settings → About → Licenses: what NotTennaPod is built from and under which licence (`NOTICE.md`), as
/// Android's `LicensesFragment` lists its libraries. The texts themselves ship in the source (`Licenses/`).
@MainActor final class LicensesSettingsView: UIView {
    static let components: [(name: String, license: String)] = [
        ("AntennaPod (the app NotTennaPod is a clone of)", "GNU General Public License v3.0"),
        ("FFmpeg 9.0.2", "GNU Lesser General Public License v2.1 or later"),
        ("dav1d 1.5.4", "BSD 2-Clause License"),
        ("SwiftSoup 2.13.9", "MIT License"),
        ("Google Cast SDK 4.8.6", "Google Cast SDK Additional Developer Terms of Service"),
        ("GTMSessionFetcher 5.3.1", "Apache License 2.0"),
        ("AndroidX Media3, Material Components, AndroidX DrawerLayout, AOSP", "Apache License 2.0"),
        ("OkHttp 4.12.0 (redirect and retry rules)", "Apache License 2.0"),
        ("Roboto font", "SIL Open Font License 1.1"),
    ]
    private var items: [(view: UIView, frame: CGRect)] = []

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        var y: CGFloat = 8
        let textWidth = max(0, width - 32)
        for (index, component) in Self.components.enumerated() {
            let title = Appearance.label(component.name, size: 16)
            title.numberOfLines = 0
            let license = Appearance.label(component.license, size: 14)
            license.textColor = Appearance.secondary
            license.numberOfLines = 0
            title.isAccessibilityElement = false; license.isAccessibilityElement = false  // the row speaks for them
            let titleHeight = title.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let licenseHeight = license.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let height = max(64, titleHeight + licenseHeight + 32)
            let row = UIView()
            row.isAccessibilityElement = true
            row.accessibilityLabel = component.name
            row.accessibilityValue = component.license
            row.accessibilityTraits = .staticText
            row.accessibilityIdentifier = "license-\(index)"
            let top = (height - titleHeight - licenseHeight) / 2
            for (view, frame) in [(row, CGRect(x: 0, y: y, width: width, height: height)),
                                  (title as UIView, CGRect(x: 16, y: y + top, width: textWidth, height: titleHeight)),
                                  (license, CGRect(x: 16, y: y + top + titleHeight, width: textWidth, height: licenseHeight))] {
                addSubview(view); items.append((view, frame)); view.frame = frame
            }
            y += height
        }
        frame.size.height = y + 8
        registerForTraitChanges([UITraitLayoutDirection.self]) { (view: LicensesSettingsView, _) in view.setNeedsLayout() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (view, frame) in items {
            view.frame = rtl ? CGRect(x: bounds.width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height) : frame
            (view as? UILabel)?.textAlignment = .natural
        }
    }
}

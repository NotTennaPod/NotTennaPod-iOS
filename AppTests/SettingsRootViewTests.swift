import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// The mounted Settings root shows Android's unofficial-package composition, with NotTennaPod's About row
/// under Project and its own notice. About shows that NotTennaPod is not AntennaPod.
/// Expected text is Android's English from the oracle, not read back from the app.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct SettingsRootViewTests {
    static let rows: [(key: String, title: String, summary: String?, icon: String)] = [
        ("prefScreenInterface", "User interface", "Appearance, subscriptions, lockscreen", "ic_appearance"),
        ("prefScreenPlayback", "Playback", "Headphone controls, Skip intervals, Queue", "ic_play_24dp"),
        ("prefScreenDownloads", "Downloads", "Update interval, Mobile data, Automatic download, Automatic deletion", "ic_download"),
        ("prefScreenSynchronization", "Synchronization", "Synchronize with other devices", "ic_cloud"),
        ("prefScreenImportExport", "Backup & restore", "Move subscriptions and queue to another device", "ic_storage"),
        ("notifications", "Notifications", nil, "ic_notifications"),
    ]
    static let notice = "NotTennaPod is not AntennaPod and has no affiliation with the AntennaPod project. Please don't report"
        + " NotTennaPod problems to the AntennaPod team. NotTennaPod is free software, licensed under the GNU General Public License (GPL) version 3."
    static let absent = ["Documentation & support", "User forum", "Contribute", "Report bug",
                         "This is a development version of AntennaPod and not meant for daily use"]

    private func find<T: UIView>(_ id: String, _ view: UIView, as: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id, let found = view as? T { return found }
        return view.subviews.lazy.compactMap { find(id, $0, as: T.self) }.first
    }
    private func all<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all($0, T.self) }
    }
    private func png(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
        return UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }.pngData()
    }
    private func rgb(_ color: UIColor?, _ style: UIUserInterfaceStyle) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color?.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map { Int(($0 * 255).rounded()) }
    }

    @MainActor private func openSettings(_ body: @MainActor (LibraryViewController, ViewTestWindowHost) throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsRootView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let nav = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nav, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.frame = host.view.bounds
            defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            try #require(find("navigationMore", controller.view, as: UIControl.self)).sendActions(for: .touchUpInside)
            let settings = try #require(all(controller.view, UIControl.self).first { $0.accessibilityLabel == "Settings" })
            settings.sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            try body(controller, host)
        }
    }

    /// Checks composition, text, icons and that nothing is clipped, at the current size and direction.
    @MainActor private func checkRoot(_ controller: LibraryViewController, rtl: Bool, _ label: String) throws {
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let screen = try #require(all(controller.view, NavigationSettingsView.self).first, "\(label)")
        screen.layoutIfNeeded()
        let scroll = try #require(screen.superview as? UIScrollView)
        #expect(screen.effectiveUserInterfaceLayoutDirection == (rtl ? .rightToLeft : .leftToRight), "\(label)")
        let texts = all(screen, UILabel.self).compactMap(\.text)
        for text in Self.absent { #expect(!texts.contains(text), "\(label): \(text)") }
        #expect(!all(controller.view, UIView.self).contains { ["prefDocumentation", "prefViewForum", "prefContribute",
            "prefSendBugReport"].contains($0.accessibilityIdentifier ?? "") }, "\(label)")

        // Search field first, then the six rows, then Project with About, then the notice; nothing after it.
        let search = try #require(all(screen, UILabel.self).first { $0.text == "Search…" }, "\(label)")
        let rowViews = try Self.rows.map { try #require(find($0.key, screen, as: UIControl.self), "\(label) \($0.key)") }
        let project = try #require(find("project", screen), "\(label)")
        let about = try #require(find("prefAbout", screen, as: UIControl.self), "\(label)")
        #expect(all(project, UILabel.self).first?.text == "Project" && about.accessibilityLabel == "About", "\(label)")
        #expect(about.accessibilityTraits.contains(.button), "\(label)")
        let aboutIcon = try #require(all(about, UIImageView.self).first, "\(label)")
        #expect(png(aboutIcon.image) == png(UIImage(named: "ic_info")), "\(label)")
        let notice = try #require(find("settingsSpinOffNotice", screen), "\(label)")
        let ordered = [search.convert(search.bounds, to: screen)] + (rowViews + [project, about, notice]).map(\.frame)
        #expect(zip(ordered, ordered.dropFirst()).allSatisfy { $0.maxY <= $1.minY + 0.5 }, "\(label)")
        let bottoms = screen.subviews.filter { !$0.isHidden }.map(\.frame.maxY)
        #expect(bottoms.allSatisfy { $0 <= notice.frame.maxY + 0.5 }, "\(label): the notice is the last row")
        #expect(scroll.contentSize.height >= notice.frame.maxY, "\(label): the notice can be scrolled to")

        for (view, row) in zip(rowViews, Self.rows) {
            #expect(view.accessibilityLabel == row.title && view.accessibilityHint == row.summary, "\(label) \(row.key)")
            #expect(view.accessibilityTraits.contains(.button), "\(label) \(row.key)")
            let icon = try #require(all(view, UIImageView.self).first, "\(label) \(row.key)")
            #expect(png(icon.image) == png(UIImage(named: row.icon)), "\(label) \(row.key)")
            let title = try #require(all(view, UILabel.self).first { $0.text == row.title })
            #expect(rtl ? icon.frame.minX > title.frame.maxX : icon.frame.maxX < title.frame.minX, "\(label) \(row.key)")
        }

        // The notice: no title, exact text, secondary colour, red circled "i", static and unclipped.
        #expect(!(notice is UIControl) && (notice.gestureRecognizers ?? []).isEmpty, "\(label)")
        #expect(notice.isAccessibilityElement && notice.accessibilityLabel == Self.notice, "\(label)")
        #expect(notice.accessibilityTraits == .staticText, "\(label)")
        let noticeLabels = all(notice, UILabel.self)
        #expect(noticeLabels.count == 1 && noticeLabels.first?.text == Self.notice, "\(label)")
        let text = try #require(noticeLabels.first)
        #expect(zip(rgb(text.textColor, .light), rgb(Appearance.secondary, .light)).allSatisfy { abs($0 - $1) <= 12 }, "\(label): secondary text")
        let needed = text.sizeThatFits(CGSize(width: text.bounds.width, height: .greatestFiniteMagnitude)).height
        #expect(text.bounds.height >= needed - 0.5 && notice.bounds.contains(text.frame), "\(label): notice text not clipped")
        #expect(text.bounds.width > 150, "\(label)")
        let icon = try #require(all(notice, UIImageView.self).first)
        #expect(!icon.isAccessibilityElement && icon.bounds.size == CGSize(width: 24, height: 24), "\(label)")
        #expect(png(icon.image) == png(UIImage(named: "ic_info_white")), "\(label)")
        for style in [UIUserInterfaceStyle.light, .dark] {
            let red = rgb(icon.tintColor, style)
            #expect(red[0] >= 0xB0 && red[1] <= 0x30 && red[2] <= 0x30, "\(label) \(style): a red info icon, \(red)")
        }
        #expect(notice.frame.minX == 0 && notice.frame.width == screen.bounds.width, "\(label)")
        #expect(rtl ? icon.frame.minX > text.frame.maxX && icon.frame.maxX <= notice.bounds.maxX
                    : icon.frame.maxX < text.frame.minX && icon.frame.minX >= 0, "\(label): icon at the leading edge")
        let firstTitle = try #require(all(rowViews[0], UILabel.self).first)
        #expect(abs((rtl ? text.frame.maxX - firstTitle.frame.maxX : text.frame.minX - firstTitle.frame.minX)) < 1,
                "\(label): notice text aligns with the row titles")
    }

    @Test func settingsRootShowsUnofficialCompositionAtEveryWidth() async throws {
        try await openSettings { controller, host in
            // Phone portrait, narrow split/slide-over, tablet portrait and landscape widths.
            for width in [320, host.view.bounds.width, 744, 1024, 1366] as [CGFloat] {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: max(host.view.bounds.height, 600))
                try checkRoot(controller, rtl: false, "width \(width)")
            }
        }
    }

    @Test func settingsRootMirrorsInRightToLeft() async throws {
        try await openSettings { controller, host in
            controller.traitOverrides.layoutDirection = .rightToLeft
            for width in [host.view.bounds.width, 1024] as [CGFloat] {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: host.view.bounds.height)
                try checkRoot(controller, rtl: true, "RTL width \(width)")
            }
            controller.traitOverrides.remove(UITraitLayoutDirection.self)
            try checkRoot(controller, rtl: false, "LTR again")
        }
    }

    @Test func tappingTheNoticeDoesNothing() async throws {
        try await openSettings { controller, _ in
            let screen = try #require(all(controller.view, NavigationSettingsView.self).first)
            let notice = try #require(find("settingsSpinOffNotice", screen))
            let scroll = try #require(screen.superview as? UIScrollView)
            scroll.scrollRectToVisible(notice.frame, animated: false)
            // A real touch at the notice lands on no control and opens nothing.
            let point = notice.convert(CGPoint(x: notice.bounds.midX, y: notice.bounds.midY), to: controller.view)
            let hit = controller.view.hitTest(point, with: nil)
            #expect(hit.map { $0 === notice || $0.isDescendant(of: notice) } == true)
            var ancestor = hit
            while let view = ancestor { #expect(!(view is UIControl)); ancestor = view.superview }
            #expect(controller.presentedViewController == nil)
            #expect(all(controller.view, NavigationSettingsView.self).first === screen)
        }
    }

    /// Settings → About: the banner, the statement that NotTennaPod is not AntennaPod, Version and Licenses, unclipped
    /// and mirrored at every width; Version copies itself, Licenses opens the list.
    @Test func aboutSaysNotTennaPodIsNotAntennaPod() async throws {
        try await openSettings { controller, host in
            try #require(find("prefAbout", controller.view, as: UIControl.self)).sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            #expect(find("screenTitle", controller.view, as: UILabel.self)?.text == "About")
            for (width, rtl) in [(320, false), (host.view.bounds.width, false), (744, false), (1024, false), (1366, false),
                                 (host.view.bounds.width, true), (1024, true)] as [(CGFloat, Bool)] {
                if rtl { controller.traitOverrides.layoutDirection = .rightToLeft } else { controller.traitOverrides.remove(UITraitLayoutDirection.self) }
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: max(host.view.bounds.height, 600))
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let page = try #require(all(controller.view, AboutSettingsView.self).first, "width \(width)")
                page.layoutIfNeeded()
                let label = "width \(width)\(rtl ? " RTL" : "")"
                let title = try #require(find("aboutStatementTitle", page, as: UILabel.self))
                let statement = try #require(find("aboutStatement", page, as: UILabel.self))
                #expect(title.text == "NotTennaPod is not AntennaPod" && title.accessibilityTraits.contains(.header), "\(label)")
                for text in ["no native AntennaPod for iOS", "best podcast app ever made", "made with love and appreciation",
                             "has nothing to do with NotTennaPod", "not affiliated with, endorsed by or supported by them",
                             "Please don't report NotTennaPod problems to the AntennaPod team"] {
                    #expect(statement.text?.contains(text) == true, "\(label): \(text)")
                }
                for text in [title, statement] {
                    let needed = text.sizeThatFits(CGSize(width: text.bounds.width, height: .greatestFiniteMagnitude)).height
                    #expect(text.bounds.height >= needed - 0.5 && page.bounds.contains(text.frame), "\(label): not clipped")
                }
                let banner = try #require(find("aboutTeaser", page, as: UIImageView.self))
                #expect(banner.frame.minY == 0 && banner.frame.width == page.bounds.width && banner.frame.maxY <= title.frame.minY, "\(label)")
                let version = try #require(find("about_version", page, as: UIControl.self))
                let licenses = try #require(find("about_licenses", page, as: UIControl.self))
                #expect(version.accessibilityLabel == "NotTennaPod version" && version.accessibilityHint == AboutSettingsView.versionSummary, "\(label)")
                #expect(licenses.accessibilityLabel == "Licenses" && licenses.accessibilityHint == "NotTennaPod uses other great software", "\(label)")
                #expect(statement.frame.maxY <= version.frame.minY && version.frame.maxY <= licenses.frame.minY, "\(label)")
                let scroll = try #require(page.superview as? UIScrollView)
                #expect(scroll.contentSize.height >= licenses.frame.maxY, "\(label): Licenses can be scrolled to")
                // The row icon sits at the leading edge, as in Settings.
                let icon = try #require(all(page, UIImageView.self).first { $0.frame.midY > version.frame.minY && $0.frame.midY < version.frame.maxY })
                #expect(rtl ? icon.frame.minX > page.bounds.midX : icon.frame.maxX < page.bounds.midX, "\(label): icon at the leading edge")
            }
            controller.traitOverrides.remove(UITraitLayoutDirection.self)
            let page = try #require(all(controller.view, AboutSettingsView.self).first)
            let previous = UIPasteboard.general.items
            defer { UIPasteboard.general.items = previous }  // leave the clipboard as it was
            UIPasteboard.general.string = ""
            try #require(find("about_version", page, as: UIControl.self)).sendActions(for: .touchUpInside)
            #expect(UIPasteboard.general.string == AboutSettingsView.versionSummary)
            try #require(find("about_licenses", page, as: UIControl.self)).sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            #expect(find("screenTitle", controller.view, as: UILabel.self)?.text == "Licenses")
            let list = try #require(all(controller.view, LicensesSettingsView.self).first)
            let rows = all(list, UIView.self).filter { $0.accessibilityIdentifier?.hasPrefix("license-") == true }
            #expect(rows.compactMap(\.accessibilityLabel) == [
                "AntennaPod (the app NotTennaPod is a clone of)",
                "FFmpeg 9.0.2", "dav1d 1.5.4", "SwiftSoup 2.13.9", "Google Cast SDK 4.8.6",
                "GTMSessionFetcher 5.3.1", "AndroidX Media3, Material Components, AndroidX DrawerLayout, AOSP",
                "OkHttp 4.12.0 (redirect and retry rules)", "Roboto font",
            ])
            #expect(rows.first?.accessibilityValue == "GNU General Public License v3.0")
        }
    }
}

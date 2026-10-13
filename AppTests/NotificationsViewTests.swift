import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted checks: Settings → Notifications as a person sees it, the download-failure message and its Details action,
/// and the single Download log sheet. Expected text is Android's English, not read from the app.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct NotificationsViewTests {
    static let rows: [(key: String, title: String, summary: String)] = [
        ("prefShowDownloadReport", "Download failed", "Shown when download or feed update fails."),
        ("pref_gpodnet_notifications", "Synchronization failed", "Shown when gpodder synchronization fails."),
    ]

    private func find<T: UIView>(_ id: String, _ view: UIView, as: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id, let found = view as? T { return found }
        return view.subviews.lazy.compactMap { find(id, $0, as: T.self) }.first
    }
    private func all<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all($0, T.self) }
    }
    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition())
    }

    private struct Fixture {
        let store: FeedLibraryStore
        let preferences: NotificationPreferenceStore
        let file: URL
        let controller: LibraryViewController
    }

    private func withController(_ body: @MainActor (Fixture, ViewTestWindowHost) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M30View-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        let file = root.appendingPathComponent("notification-preferences.json")
        let preferences = try NotificationPreferenceStore(file: file)
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        controller.notificationPreferences = preferences
        do {
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                try await body(Fixture(store: store, preferences: preferences, file: file, controller: controller), host)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    /// Main drawer → Settings → Notifications, through the actual rows.
    private func openNotifications(_ controller: LibraryViewController) throws -> NotificationSettingsView {
        try #require(find("navigationMore", controller.view, as: UIControl.self)).sendActions(for: .touchUpInside)
        let settings = try #require(all(controller.view, UIControl.self).first { $0.accessibilityLabel == "Settings" })
        settings.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        let row = try #require(find("notifications", controller.view, as: UIControl.self))
        #expect(row.accessibilityLabel == "Notifications" && row.accessibilityHint == nil)
        row.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        return try #require(all(controller.view, NotificationSettingsView.self).first)
    }

    /// Composition, wording, states and a readable, unclipped layout at the current size and direction.
    private func checkScreen(_ controller: LibraryViewController, syncEnabled: Bool,
                             on: [Bool], rtl: Bool, _ label: String) throws {
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        // A new size renders the screen again; check the one on screen now.
        let screen = try #require(all(controller.view, NotificationSettingsView.self).first, "\(label)")
        screen.layoutIfNeeded()
        #expect(screen.effectiveUserInterfaceLayoutDirection == (rtl ? .rightToLeft : .leftToRight), "\(label)")
        // Toolbar title.
        let titles = all(controller.view, UILabel.self).filter { $0.text == "Notifications" && !$0.isDescendant(of: screen) && $0.window != nil }
        #expect(!titles.isEmpty, "\(label): toolbar says Notifications")
        // "Errors" first, then the two rows in Android's order; nothing else.
        let header = try #require(all(screen, UILabel.self).first { $0.text == "Errors" }, "\(label)")
        #expect(header.accessibilityTraits.contains(.header), "\(label)")
        let controls = try Self.rows.map { try #require(find($0.key, screen, as: UIControl.self), "\(label) \($0.key)") }
        #expect(all(screen, UIControl.self).count == 2, "\(label): exactly two rows")
        let headerFrame = header.convert(header.bounds, to: screen)
        #expect(headerFrame.maxY <= controls[0].frame.minY + 0.5 && controls[0].frame.maxY <= controls[1].frame.minY + 0.5, "\(label) order")
        for (index, (control, row)) in zip(controls, Self.rows).enumerated() {
            let enabled = index == 0 || syncEnabled
            #expect(control.accessibilityLabel == row.title && control.accessibilityHint == row.summary, "\(label) \(row.key)")
            #expect(control.accessibilityValue == (on[index] ? "On" : "Off"), "\(label) \(row.key)")
            #expect(control.isEnabled == enabled, "\(label) \(row.key) enabled")
            #expect(control.accessibilityTraits.contains(.notEnabled) == !enabled, "\(label) \(row.key): VoiceOver says dimmed")
            let title = try #require(all(control, UILabel.self).first { $0.text == row.title }, "\(label)")
            let summary = try #require(all(control, UILabel.self).first { $0.text == row.summary }, "\(label)")
            #expect((title.alpha < 0.5 && summary.alpha < 0.5) == !enabled, "\(label) \(row.key): dimmed text")
            let indicator = try #require(all(control, PreferenceSwitchView.self).first, "\(label)")
            #expect(indicator.isOn == on[index] && indicator.preferenceEnabled == enabled, "\(label) \(row.key)")
            // Nothing clipped or overlapping; the switch at the trailing edge, the text before it.
            for text in [title, summary] {
                let needed = text.sizeThatFits(CGSize(width: text.bounds.width, height: .greatestFiniteMagnitude)).height
                #expect(text.bounds.height >= needed - 0.5 && control.bounds.contains(text.frame), "\(label) \(row.key) text unclipped")
                #expect(!text.frame.intersects(indicator.frame), "\(label) \(row.key)")
            }
            #expect(title.frame.maxY <= summary.frame.minY + 0.5, "\(label) \(row.key): summary under the title")
            #expect(control.bounds.contains(indicator.frame) && control.frame.maxX <= screen.bounds.width + 0.5, "\(label)")
            #expect(rtl ? indicator.frame.maxX < title.frame.minX : indicator.frame.minX > title.frame.maxX, "\(label) \(row.key) switch side")
            #expect(title.textAlignment == (rtl ? .right : .left), "\(label)")
        }
        let scroll = try #require(screen.superview as? UIScrollView)
        #expect(scroll.contentSize.height >= controls[1].frame.maxY, "\(label): the last row can be reached")
    }

    @Test func notificationsScreenShowsAndroidCompositionAndDisabledSyncRow() async throws {
        try await withController { fixture, host in
            let screen = try openNotifications(fixture.controller)
            for width in [320, host.view.bounds.width, 744, 1024] as [CGFloat] {
                fixture.controller.view.frame = CGRect(x: 0, y: 0, width: width, height: max(host.view.bounds.height, 600))
                try checkScreen(fixture.controller, syncEnabled: false, on: [true, true], rtl: false, "width \(width)")
            }
            _ = screen
            // Without an account the sync row cannot be switched; the download row saves at once.
            let current = try #require(all(fixture.controller.view, NotificationSettingsView.self).first)
            try #require(find("pref_gpodnet_notifications", current, as: UIControl.self)).sendActions(for: .touchUpInside)
            try #require(find("prefShowDownloadReport", current, as: UIControl.self)).sendActions(for: .touchUpInside)
            #expect(fixture.controller.presentedViewController == nil, "no dialog or permission request")
            try checkScreen(fixture.controller, syncEnabled: false, on: [false, true], rtl: false, "after toggle")
            // Saved data, read back from the file.
            let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any])
            #expect(saved["prefShowDownloadReport"] as? Bool == false)
            #expect(try NotificationPreferenceStore(file: fixture.file).value.synchronizationFailedEnabled(account: nil))
            // Back returns to Settings.
            try #require(find("toolbarBack", fixture.controller.view, as: UIControl.self)).sendActions(for: .touchUpInside)
            fixture.controller.view.layoutIfNeeded()
            #expect(all(fixture.controller.view, NotificationSettingsView.self).isEmpty)
            #expect(find("notifications", fixture.controller.view, as: UIControl.self) != nil)
        }
    }

    @Test func notificationsScreenMirrorsInRightToLeft() async throws {
        try await withController { fixture, host in
            _ = try openNotifications(fixture.controller)
            fixture.controller.traitOverrides.layoutDirection = .rightToLeft
            for width in [host.view.bounds.width, 1024] as [CGFloat] {
                fixture.controller.view.frame = CGRect(x: 0, y: 0, width: width, height: host.view.bounds.height)
                try checkScreen(fixture.controller, syncEnabled: false, on: [true, true], rtl: true, "RTL \(width)")
            }
            fixture.controller.traitOverrides.remove(UITraitLayoutDirection.self)
        }
    }

    /// With an account the sync row works and its choice belongs to that account (Android resets it to On at
    /// every login and logout, `SynchronizationCredentials.clear()`).
    @Test func syncRowWithAccountTogglesAndResetsForAnotherAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M30Sync-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = try NotificationPreferenceStore(file: root.appendingPathComponent("notification-preferences.json"))
        let account = UUID()
        try await withViewTestWindow { host, _ in
            let screen = NotificationSettingsView(preferences: preferences, synchronizationAccount: account, width: host.view.bounds.width)
            host.view.addSubview(screen); defer { screen.removeFromSuperview() }
            screen.layoutIfNeeded()
            let row = try #require(find("pref_gpodnet_notifications", screen, as: UIControl.self))
            #expect(row.isEnabled && !row.accessibilityTraits.contains(.notEnabled) && row.accessibilityValue == "On")
            row.sendActions(for: .touchUpInside)
            #expect(row.accessibilityValue == "Off" && !preferences.value.synchronizationFailedEnabled(account: account))
            // Reopened for the same account: still Off. After logout or another login: On.
            for (other, expected) in [(account, "Off"), (nil, "On"), (UUID(), "On")] as [(UUID?, String)] {
                let again = NotificationSettingsView(preferences: preferences, synchronizationAccount: other, width: host.view.bounds.width)
                #expect(find("pref_gpodnet_notifications", again, as: UIControl.self)?.accessibilityValue == expected)
            }
        }
    }

    /// The in-app message (Android Snackbar with "Details"): Details leaves Settings and opens the Download log.
    @Test func downloadMessageDetailsLeavesSettingsAndOpensLog() async throws {
        try await withController { fixture, _ in
            _ = try openNotifications(fixture.controller)
            #expect(fixture.controller.settingsVisible)
            let text = "Download of \"Episode 404\" failed."
            #expect(fixture.controller.showDownloadError(text))
            fixture.controller.view.layoutIfNeeded()
            let snackbar = try #require(all(fixture.controller.view, Snackbar.self).first)
            snackbar.pauseTimeout()
            #expect(snackbar.message == text && snackbar.window != nil)
            let details = try #require(find("downloadErrorDetails", snackbar, as: UIButton.self))
            #expect(details.title(for: .normal) == "Details")
            // A later message replaces it (one at a time).
            #expect(fixture.controller.showDownloadError("Download of \"Other\" failed. Will be retried later."))
            let replacement = try #require(all(fixture.controller.view, Snackbar.self).first)
            replacement.pauseTimeout()
            #expect(snackbar.superview == nil && all(fixture.controller.view, Snackbar.self).count == 1)
            try #require(find("downloadErrorDetails", replacement, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait { fixture.controller.presentedViewController is DownloadLogController
                && fixture.controller.presentedViewController?.isBeingPresented == false }
            #expect(!fixture.controller.settingsVisible, "Settings closed")
            fixture.controller.presentedViewController?.dismiss(animated: false)
            try await wait { fixture.controller.presentedViewController == nil }
        }
    }

    /// Tapping the notification twice (or while the log is open) keeps one Download log sheet (Android stacks two).
    @Test func notificationRouteKeepsOneLogSheet() async throws {
        try await withController { fixture, _ in
            fixture.controller.openDownloadLogFromNotification()
            fixture.controller.openDownloadLogFromNotification()
            try await wait { fixture.controller.presentedViewController is DownloadLogController
                && fixture.controller.presentedViewController?.isBeingPresented == false }
            let sheet = try #require(fixture.controller.presentedViewController)
            fixture.controller.openDownloadLogFromNotification()
            try await Task.sleep(for: .milliseconds(300))
            #expect(fixture.controller.presentedViewController === sheet && sheet.presentedViewController == nil)
            // Closed, the next tap opens it again.
            sheet.dismiss(animated: false)
            try await wait { fixture.controller.presentedViewController == nil }
            fixture.controller.openDownloadLogFromNotification()
            try await wait { fixture.controller.presentedViewController is DownloadLogController
                && fixture.controller.presentedViewController !== sheet }
            fixture.controller.presentedViewController?.dismiss(animated: false)
            try await wait { fixture.controller.presentedViewController == nil }
        }
    }
}

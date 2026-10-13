import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// The fallback: the server library the registry chose could not be found on this device (its folder or database is
/// missing), so this device's library opened. The main screen says so once, in the app's notice, with its exact words,
/// whole (never clipped) at the device's own size and at iPhone, iPad and Duo sizes in both orientations, left to right
/// and right to left, with large text, and readable by VoiceOver; a later start for the same occurrence, another scene,
/// a damaged registry and a normal start show nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct MissingLibraryNoticeViewTests {
    static let message = "The server library could not be found on this device, so this device's library is open instead."

    enum Start { case folderMissing, databaseMissing, registryDamaged, normal }

    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: type) }.first
    }

    private func count(_ id: String, in view: UIView) -> Int {
        (view.accessibilityIdentifier == id ? 1 : 0) + view.subviews.reduce(0) { $0 + count(id, in: $1) }
    }

    private func wait(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    /// The real opening of a device whose registry chooses a server library, and the notice after that start.
    private func started(_ start: Start) throws -> (LibraryGraphStart.Opening, MissingLibraryNotice) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MissingLibraryNoticeView-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11", file = LibraryRegistryFile(root: root)
        if start == .registryDamaged {
            try Data("{".utf8).write(to: file.url)
        } else {
            var registry = LibraryRegistry()
            registry.libraries = [.init(id: id, serverURL: "https://sync.example.test", serverID: "server-1",
                                        accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f", username: "alice", state: .active, createdAt: 0)]
            registry.active = .server(id)
            try file.write(registry)
            let location = LibraryLocation(root: root, reference: .server(id))
            if start != .folderMissing { try location.prepare() }
            if start == .normal { try Data("library".utf8).write(to: location.database) }
        }
        let opening = try LibraryGraphStart.openingLibrary(root: root, keep: LibraryKeep(.init(root: root, secrets: MemoryServerSecrets())))
        var notice = MissingLibraryNotice()
        notice.started(opening)
        return (opening, notice)
    }

    /// The main screen as a scene installs it for a started graph, asking for the notice as the app's scene does.
    private func screen(take: @escaping () -> Bool) -> LibraryViewController {
        let feed = LibraryFeed(id: 1, source: "fixture://feed", metadata: .init(format: .rss, title: "Fallback feed"),
            episodes: (1...5).map { LibraryEpisode(id: Int64($0), details: .init(title: "Episode \($0)")) })
        let snapshot = FeedLibrarySnapshot(feeds: [feed], queue: [])
        let controller = LibraryViewController(library: nil, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, loadSnapshot: { snapshot })
        controller.takeMissingLibraryNotice = take
        return controller
    }

    private func mount(_ controller: LibraryViewController, in host: ViewTestWindowHost, rtl: Bool) {
        controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
        controller.view.frame = host.view.bounds
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    private func unmount(_ controller: LibraryViewController) {
        controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
    }

    @Test(arguments: [Start.folderMissing, .databaseMissing], [false, true])
    func messageAppearsOnceWholeAndReadable(start: Start, rtl: Bool) async throws {
        #expect(Appearance.text("ntp_server_library_missing") == Self.message)
        var (opening, notice) = try started(start)
        #expect(opening.location.reference == .standalone && notice.isDue)
        for largeText in [false, true] {
            if largeText { (opening, notice) = try started(start) }
            var asked = 0
            let controller = screen { asked += 1; return notice.take() }
            try await withViewTestWindow { host, window in
                // The notice is drawn in the window, above the screen and anything it presents.
                window.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                if largeText { window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge }
                mount(controller, in: host, rtl: rtl)
                defer { unmount(controller) }
                try await wait { element("applicationNotice", in: window, as: UILabel.self) != nil }
                let label: UILabel = try #require(element("applicationNotice", in: window))
                #expect(label.text == Self.message)
                // VoiceOver reads it (it is also announced as it appears).
                #expect(label.isAccessibilityElement && label.accessibilityLabel == Self.message)
                #expect(!label.isHidden && label.alpha == 1 && !label.accessibilityElementsHidden)
                #expect(label.numberOfLines == 0 && label.textAlignment == .center)
                #expect(controller.presentedViewController == nil, "a notice, not a dialog")
                #expect(asked >= 1 && !notice.isDue)
                // Once: the scene becoming active again (or another chance to show it) adds nothing.
                controller.showMissingLibraryNoticeIfDue()
                #expect(count("applicationNotice", in: window) == 1)
                let own = window.bounds.size
                let sizes = [own, CGSize(width: own.height, height: own.width), CGSize(width: 320, height: 568),
                             CGSize(width: 402, height: 874), CGSize(width: 874, height: 402), CGSize(width: 1024, height: 1366),
                             CGSize(width: 1366, height: 1024), CGSize(width: 540, height: 720), CGSize(width: 1114, height: 720)]
                for size in sizes {
                    controller.view.frame = CGRect(origin: .zero, size: size)
                    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                    #expect(element("applicationNotice", in: window, as: UILabel.self) === label)
                    #expect(label.text == Self.message)
                    let safe = controller.view.safeAreaLayoutGuide.layoutFrame
                    let frame = label.convert(label.bounds, to: controller.view)
                    #expect(frame.minX >= safe.minX && frame.maxX <= safe.maxX && frame.minY >= safe.minY && frame.maxY <= safe.maxY,
                            "inside the safe area at \(size): \(frame) in \(safe)")
                    #expect(abs((frame.minX - safe.minX) - (safe.maxX - frame.maxX)) <= 1, "centred at \(size)")
                    let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
                    #expect(label.bounds.height >= needed, "whole at \(size): \(label.bounds.height) < \(needed)")
                }
            }
            // A later graph start for the same occurrence (after an import, a switch or a Keep), or another scene
            // connecting: its screen shows nothing.
            notice.started(opening)
            #expect(!notice.isDue)
            try await withViewTestWindow { host, window in
                var asked = 0
                let next = screen { asked += 1; return notice.take() }
                mount(next, in: host, rtl: rtl)
                defer { unmount(next) }
                try await wait { asked >= 1 }
                next.showMissingLibraryNoticeIfDue()
                #expect(element("applicationNotice", in: window, as: UILabel.self) == nil)
            }
        }
    }

    @Test(arguments: [Start.registryDamaged, .normal])
    func nothingAppearsWithoutAMissingServerLibrary(start: Start) async throws {
        var (_, notice) = try started(start)
        #expect(!notice.isDue)
        try await withViewTestWindow { host, window in
            var asked = 0
            let controller = screen { asked += 1; return notice.take() }
            mount(controller, in: host, rtl: false)
            defer { unmount(controller) }
            try await wait { asked >= 1 }
            controller.showMissingLibraryNoticeIfDue()
            #expect(element("applicationNotice", in: window, as: UILabel.self) == nil)
        }
    }

    /// The app's own wiring (`AppDelegate.connectMissingLibraryNotice`, `SceneDelegate.libraryBecameActive`), with the
    /// app's notice state and backup preferences swapped for the test's and put back afterwards. A screen not in a
    /// scene a person sees takes nothing; a screen that appeared before the message was due (its scene not yet active
    /// at launch) shows it when the scene becomes active, once. A backup failure report pending at that activation
    /// (shown at every activation) waits for the message's whole time, then shows: neither replaces the other. A later
    /// activation and another scene's screen do not show the message again.
    @Test func activationShowsTheMessageOnceAndAPendingBackupReportAfterIt() async throws {
        let app = try #require(UIApplication.shared.delegate as? AppDelegate)
        try #require(app.libraryStartup.isStarted, "the test host's library has started")
        try await wait { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MissingLibraryNoticeBackup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let savedNotice = app.missingLibraryNotice, savedBackup = app.automaticBackupPreferences
        defer {
            app.missingLibraryNotice = savedNotice; app.automaticBackupPreferences = savedBackup
            try? FileManager.default.removeItem(at: root)
        }
        let report = "Automatic database export failed: the backup folder cannot be reached."
        let backup = try AutomaticDatabaseExportPreferenceStore(file: root.appendingPathComponent("automatic-database-export.json"))
        try backup.update { $0.pendingError = report }
        app.automaticBackupPreferences = backup
        app.missingLibraryNotice = MissingLibraryNotice()
        let (opening, _) = try started(.folderMissing)

        // Not in a scene a person sees: nothing is taken.
        let unseen = screen { false }
        app.connectMissingLibraryNotice(unseen)
        app.missingLibraryNotice.started(opening)
        unseen.loadViewIfNeeded()
        unseen.showMissingLibraryNoticeIfDue()
        #expect(app.missingLibraryNotice.isDue)
        app.missingLibraryNotice = MissingLibraryNotice()

        // The scene's screen appears before the message is due, as at a launch whose scene is not active yet.
        let controller = screen { false }
        app.connectMissingLibraryNotice(controller)
        let connected = try #require(controller.takeMissingLibraryNotice)
        var asked = 0
        controller.takeMissingLibraryNotice = { asked += 1; return connected() }
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { closeTestWindow(window, restoringKey: previous) }
        try await wait { asked >= 1 }
        #expect(element("applicationNotice", in: window, as: UILabel.self) == nil)
        app.missingLibraryNotice.started(opening)

        // The scene becomes active.
        let sceneDelegate = SceneDelegate()
        sceneDelegate.window = window
        sceneDelegate.libraryBecameActive(scene)
        let shown = ContinuousClock.now
        let explanation: UILabel = try #require(element("applicationNotice", in: window))
        #expect(explanation.text == Self.message)
        #expect(!app.missingLibraryNotice.isDue)
        #expect(backup.value.pendingError == nil, "the report is taken, to be shown next")
        try await wait { element("applicationNotice", in: window, as: UILabel.self)?.text == report }
        #expect(ContinuousClock.now - shown >= .seconds(3), "the message had its whole time")
        #expect(explanation.superview == nil)
        let next: UILabel = try #require(element("applicationNotice", in: window))
        #expect(next.isAccessibilityElement && next.accessibilityLabel == report)

        // A later activation shows neither again.
        sceneDelegate.libraryBecameActive(scene)
        #expect(element("applicationNotice", in: window, as: UILabel.self) === next)
        #expect(count("applicationNotice", in: window) == 1)

        // Another scene's screen, or this scene connecting again, shows nothing.
        let other = screen { false }
        app.connectMissingLibraryNotice(other)
        let otherConnected = try #require(other.takeMissingLibraryNotice)
        var otherAsked = 0
        other.takeMissingLibraryNotice = { otherAsked += 1; return otherConnected() }
        let otherWindow = UIWindow(windowScene: scene)
        otherWindow.rootViewController = other; otherWindow.makeKeyAndVisible()
        defer { closeTestWindow(otherWindow, restoringKey: window) }
        try await wait { otherAsked >= 1 }
        let otherDelegate = SceneDelegate()
        otherDelegate.window = otherWindow
        otherDelegate.libraryBecameActive(scene)
        #expect(element("applicationNotice", in: otherWindow, as: UILabel.self) == nil)
    }
}

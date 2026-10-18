import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Work the system ended while it ran: at the next launch the main screen says once what became of it, in the
/// app's notice, with its exact words, whole (never clipped) and centred at the device's own size and at iPhone, iPad
/// and Duo sizes in both orientations, left to right and right to left, with large text, and readable by VoiceOver;
/// after the missing-library message when both are due, each for its whole time, and never twice.
@MainActor @Suite(.serialized)
struct InterruptedWorkNoticeViewTests {
    nonisolated static let importRolledBack = "The database import was interrupted. Your library was not changed."
    nonisolated static let importCompleted = "The interrupted database import was completed."
    nonisolated static let exportLocationUnknown = "An export may be incomplete. Its location is unknown."
    nonisolated static let exportNamed = "The export \"nottennapod-feeds-2026-10-09.opml\" may be incomplete."

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

    private func screen() -> LibraryViewController {
        let feed = LibraryFeed(id: 1, source: "fixture://feed", metadata: .init(format: .rss, title: "Imported feed"),
            episodes: (1...5).map { LibraryEpisode(id: Int64($0), details: .init(title: "Episode \($0)")) })
        let snapshot = FeedLibrarySnapshot(feeds: [feed], queue: [])
        return LibraryViewController(library: nil, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, loadSnapshot: { snapshot })
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

    /// The label shows `message` whole, centred and inside the safe area at every size.
    private func expectWhole(_ label: UILabel, _ message: String, in controller: LibraryViewController, window: UIWindow) {
        let own = window.bounds.size
        let sizes = [own, CGSize(width: own.height, height: own.width), CGSize(width: 320, height: 568),
                     CGSize(width: 402, height: 874), CGSize(width: 874, height: 402), CGSize(width: 1024, height: 1366),
                     CGSize(width: 1366, height: 1024), CGSize(width: 540, height: 720), CGSize(width: 1114, height: 720)]
        for size in sizes {
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(element("applicationNotice", in: window, as: UILabel.self) === label)
            #expect(label.text == message)
            let safe = controller.view.safeAreaLayoutGuide.layoutFrame
            let frame = label.convert(label.bounds, to: controller.view)
            #expect(frame.minX >= safe.minX && frame.maxX <= safe.maxX && frame.minY >= safe.minY && frame.maxY <= safe.maxY,
                    "inside the safe area at \(size): \(frame) in \(safe)")
            #expect(abs((frame.minX - safe.minX) - (safe.maxX - frame.maxX)) <= 1, "centred at \(size)")
            let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
            #expect(label.bounds.height >= needed, "whole at \(size): \(label.bounds.height) < \(needed)")
        }
    }

    @Test(arguments: [importRolledBack, importCompleted, exportLocationUnknown, exportNamed], [false, true])
    func outcomeAppearsOnceWholeAndReadable(message: String, rtl: Bool) async throws {
        #expect(Appearance.text("database_import_interrupted") == Self.importRolledBack)
        #expect(Appearance.text("database_import_interrupted_completed") == Self.importCompleted)
        #expect(Appearance.text("export_interrupted_location_unknown") == Self.exportLocationUnknown)
        #expect(String(format: Appearance.text("export_interrupted"), "nottennapod-feeds-2026-10-09.opml") == Self.exportNamed)
        for largeText in [false, true] {
            var acknowledged = 0, asked = 0
            var pending = [LibraryViewController.LaunchNotice(message: message, shown: { acknowledged += 1 })]
            let controller = screen()
            controller.takeRecoveryNotices = { asked += 1; defer { pending = [] }; return pending }
            try await withViewTestWindow { host, window in
                window.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                if largeText { window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge }
                mount(controller, in: host, rtl: rtl)
                defer { unmount(controller) }
                try await wait { element("applicationNotice", in: window, as: UILabel.self) != nil }
                let label: UILabel = try #require(element("applicationNotice", in: window))
                #expect(label.text == message)
                #expect(label.isAccessibilityElement && label.accessibilityLabel == message)
                #expect(!label.isHidden && label.alpha == 1 && !label.accessibilityElementsHidden)
                #expect(label.numberOfLines == 0 && label.textAlignment == .center)
                #expect(controller.presentedViewController == nil, "a notice, not a dialog")
                #expect(asked >= 1 && pending.isEmpty && acknowledged == 1, "Acknowledged once it is on screen")
                controller.showMissingLibraryNoticeIfDue()
                #expect(count("applicationNotice", in: window) == 1 && acknowledged == 1, "once")
                expectWhole(label, message, in: controller, window: window)
            }
        }
    }

    /// The app's own wiring (`AppDelegate.connectMissingLibraryNotice`, `SceneDelegate.libraryBecameActive`), with the
    /// app's notice state swapped for the test's and put back afterwards: the missing-library message has its whole
    /// time, the import's outcome follows, and a later activation or another scene's screen shows neither again.
    @Test func activationShowsTheImportOutcomeAfterTheMissingLibraryMessageOnce() async throws {
        let app = try #require(UIApplication.shared.delegate as? AppDelegate)
        try #require(app.libraryStartup.isStarted, "the test host's library has started")
        try await wait { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InterruptedWorkNotice-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let savedNotice = app.missingLibraryNotice, savedPending = app.pendingNotices, savedBackup = app.automaticBackupPreferences
        defer {
            app.missingLibraryNotice = savedNotice; app.pendingNotices = savedPending; app.automaticBackupPreferences = savedBackup
            try? FileManager.default.removeItem(at: root)
        }
        // No backup report pending: only the two messages under test.
        app.automaticBackupPreferences = try AutomaticDatabaseExportPreferenceStore(file: root.appendingPathComponent("automatic-database-export.json"))
        // A start that fell back from a missing server library, and an import the system ended (as the graph start sets them).
        let id = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11", file = LibraryRegistryFile(root: root)
        var registry = LibraryRegistry()
        registry.libraries = [.init(id: id, serverURL: "https://sync.example.test", serverID: "server-1",
                                    accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f", username: "alice", state: .active, createdAt: 0)]
        registry.active = .server(id)
        try file.write(registry)
        let opening = try LibraryGraphStart.openingLibrary(root: root, keep: LibraryKeep(.init(root: root, secrets: MemoryServerSecrets())))
        app.missingLibraryNotice = MissingLibraryNotice()
        app.missingLibraryNotice.started(opening)
        // An import the system ended, recovered at an earlier (background) launch: kept until a person sees it.
        let pending = PendingNotices(root: root), attempt = UUID()
        try pending.add(PendingNotice(id: attempt, kind: .importRolledBack))
        app.pendingNotices = pending

        let controller = screen()
        app.connectMissingLibraryNotice(controller)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { closeTestWindow(window, restoringKey: previous) }
        let sceneDelegate = SceneDelegate()
        sceneDelegate.window = window
        sceneDelegate.libraryBecameActive(scene)
        try await wait { element("applicationNotice", in: window, as: UILabel.self) != nil }
        let shown = ContinuousClock.now
        let first: UILabel = try #require(element("applicationNotice", in: window))
        #expect(first.text == "The server library could not be found on this device, so this device's library is open instead.")
        #expect(try pending.all().map(\.id) == [attempt], "Waiting behind the first message: not yet seen, so not acknowledged")
        try await wait { element("applicationNotice", in: window, as: UILabel.self)?.text == Self.importRolledBack }
        #expect(try pending.all().isEmpty, "Acknowledged once on screen")
        #expect(ContinuousClock.now - shown >= .seconds(3), "the first message had its whole time")
        let next: UILabel = try #require(element("applicationNotice", in: window))
        #expect(next.isAccessibilityElement && next.accessibilityLabel == Self.importRolledBack)

        sceneDelegate.libraryBecameActive(scene)
        #expect(element("applicationNotice", in: window, as: UILabel.self) === next && count("applicationNotice", in: window) == 1)

        let other = screen()
        app.connectMissingLibraryNotice(other)
        let otherWindow = UIWindow(windowScene: scene)
        otherWindow.rootViewController = other; otherWindow.makeKeyAndVisible()
        defer { closeTestWindow(otherWindow, restoringKey: window) }
        let otherDelegate = SceneDelegate()
        otherDelegate.window = otherWindow
        otherDelegate.libraryBecameActive(scene)
        #expect(element("applicationNotice", in: otherWindow, as: UILabel.self) == nil)
    }

    /// A start that fell back from a missing server library, as the graph start records it.
    private func missingLibraryOpening(_ root: URL) throws -> LibraryGraphStart.Opening {
        let id = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11", file = LibraryRegistryFile(root: root)
        var registry = LibraryRegistry()
        registry.libraries = [.init(id: id, serverURL: "https://sync.example.test", serverID: "server-1",
                                    accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f", username: "alice", state: .active, createdAt: 0)]
        registry.active = .server(id)
        try file.write(registry)
        return try LibraryGraphStart.openingLibrary(root: root, keep: LibraryKeep(.init(root: root, secrets: MemoryServerSecrets())))
    }

    /// A durable notice queued behind the missing-library message is never presented or acknowledged once its scene has
    /// left the foreground (`background`) or its screen has left its window (`detached`): it is given back, and the
    /// next screen a person sees (the next launch's) shows it.
    @Test(arguments: [false, true])
    func aQueuedNoticeWaitsForAScreenAPersonSees(detached: Bool) async throws {
        let app = try #require(UIApplication.shared.delegate as? AppDelegate)
        try #require(app.libraryStartup.isStarted, "the test host's library has started")
        try await wait { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InterruptedWorkNoticeQueued-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let savedNotice = app.missingLibraryNotice, savedPending = app.pendingNotices, savedBackup = app.automaticBackupPreferences
        defer {
            app.missingLibraryNotice = savedNotice; app.pendingNotices = savedPending; app.automaticBackupPreferences = savedBackup
            try? FileManager.default.removeItem(at: root)
        }
        app.automaticBackupPreferences = try AutomaticDatabaseExportPreferenceStore(file: root.appendingPathComponent("automatic-database-export.json"))
        app.missingLibraryNotice = MissingLibraryNotice()
        app.missingLibraryNotice.started(try missingLibraryOpening(root))
        let pending = PendingNotices(root: root), attempt = UUID()
        try pending.add(PendingNotice(id: attempt, kind: .exportMayBeIncomplete, name: "nottennapod-feeds-2026-10-09.opml"))
        app.pendingNotices = pending

        let controller = screen()
        app.connectMissingLibraryNotice(controller)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        var closed = false
        defer { if !closed { closeTestWindow(window, restoringKey: previous) } }
        let sceneDelegate = SceneDelegate()
        sceneDelegate.window = window
        sceneDelegate.libraryBecameActive(scene)
        try await wait { element("applicationNotice", in: window, as: UILabel.self) != nil }
        #expect(element("applicationNotice", in: window, as: UILabel.self)?.text
                == "The server library could not be found on this device, so this device's library is open instead.")
        // Before the first message's time is over, the person leaves (locks, switches app) or the window goes away.
        if detached {
            closeTestWindow(window, restoringKey: previous); closed = true
        } else {
            controller.sceneIsSeen = { false }
            try await wait { element("applicationNotice", in: window, as: UILabel.self) == nil } // the first message's time ends
        }
        #expect(try pending.all().map(\.id) == [attempt], "Not seen: still pending")

        // The next launch's screen, which a person sees.
        let next = screen()
        app.connectMissingLibraryNotice(next)
        let nextWindow = UIWindow(windowScene: scene)
        nextWindow.rootViewController = next; nextWindow.makeKeyAndVisible()
        defer { closeTestWindow(nextWindow, restoringKey: previous) }
        let nextDelegate = SceneDelegate()
        nextDelegate.window = nextWindow
        nextDelegate.libraryBecameActive(scene)
        try await wait { element("applicationNotice", in: nextWindow, as: UILabel.self)?.text == Self.exportNamed }
        #expect(try pending.all().isEmpty, "Acknowledged once on screen")
        if !detached { #expect(element("applicationNotice", in: window, as: UILabel.self) == nil, "Never shown where nobody saw it") }
    }

    /// A notice a screen took but never showed (the screen went away first) is still there for the next launch.
    @Test func aNoticeNeverOnScreenStaysForTheNextLaunch() throws {
        let app = try #require(UIApplication.shared.delegate as? AppDelegate)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InterruptedWorkNoticeKept-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = app.pendingNotices
        defer { app.pendingNotices = saved; try? FileManager.default.removeItem(at: root) }
        let pending = PendingNotices(root: root), attempt = UUID()
        try pending.add(PendingNotice(id: attempt, kind: .exportMayBeIncomplete, name: "nottennapod-feeds-2026-10-09.opml"))
        app.pendingNotices = pending
        let taken = app.takeRecoveryNotices()
        #expect(taken.map(\.message) == [Self.exportNamed])
        #expect(app.takeRecoveryNotices().isEmpty, "Not offered to another screen of this process")
        #expect(try pending.all().map(\.id) == [attempt], "Never on screen: kept")
        taken.first?.shown()
        #expect(try pending.all().isEmpty)
    }
}

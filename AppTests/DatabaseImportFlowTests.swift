import UIKit
import Testing
import Synchronization
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted database import flow: source `importDatabase` warning (No / Confirm), picker, progress, then the
/// non-cancelable "Import successful" / restart or "Import error". The out-of-process system picker
/// is captured; the real Files picker runs in the database import journey.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct DatabaseImportFlowTests {
    private final class Host: UIViewController {
        var pickers: [UIDocumentPickerViewController] = []
        var messages: [SourceMessageController] = []
        override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
            if let picker = controller as? UIDocumentPickerViewController { pickers.append(picker); completion?(); return }
            super.present(controller, animated: animated, completion: completion)
        }
    }
    private final class Gate: Sendable {
        let state = Mutex<(open: Bool, failure: AndroidDatabaseRestore.Failure?, calls: Int, restarts: Int, interrupted: Bool)>((false, nil, 0, 0, false))
    }

    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let match = view as? T, view.accessibilityIdentifier == id { return match }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: type) }.first
    }
    private func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), Comment(rawValue: stage))
    }
    private func withFlow(_ gate: Gate, _ body: @MainActor (Host, DatabaseImportFlow) async throws -> Void) async throws {
        try await withViewTestWindow { window, _ in
            let host = Host()
            window.addChild(host); window.view.addSubview(host.view); host.view.frame = window.view.bounds; host.didMove(toParent: window)
            defer { host.presentedViewController?.dismiss(animated: false); host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
            let flow = DatabaseImportFlow(host: host, presentMessage: { [weak host] dialog in
                guard let host, let dialog = dialog as? SourceMessageController else { return }
                host.messages.append(dialog); host.present(dialog, animated: false)
            }, perform: { _ in
                gate.state.withLock { $0.calls += 1 }
                while !gate.state.withLock({ $0.open }) { try await Task.sleep(for: .milliseconds(5)) }
                if let failure = gate.state.withLock({ $0.failure }) { throw failure }
                if gate.state.withLock({ $0.interrupted }) { throw DatabaseImportInterrupted() }
            }, restart: { gate.state.withLock { $0.restarts += 1 } })
            try await body(host, flow)
        }
    }
    private func text(_ dialog: SourceMessageController, _ id: String) -> String? {
        (find(id, in: dialog.view) as UILabel?)?.text ?? (find(id, in: dialog.view) as UIButton?)?.title(for: .normal)
    }

    @Test func warningNoChangesNothingAndConfirmOpensAnyFilePicker() async throws {
        let gate = Gate()
        try await withFlow(gate) { host, flow in
            flow.begin()
            try await wait("warning") { host.messages.count == 1 && host.presentedViewController != nil }
            let warning = host.messages[0]; warning.loadViewIfNeeded()
            #expect(text(warning, "sourceMessageTitle") == "Database import")
            #expect(text(warning, "sourceMessage") == "Importing a database will replace all of your current subscriptions and playing history. You should export your current database as a backup. Do you want to replace?")
            #expect(text(warning, "databaseImportNo") == "No" && text(warning, "databaseImportConfirm") == "Confirm")
            let no: UIButton = try #require(find("databaseImportNo", in: warning.view))
            no.sendActions(for: .touchUpInside)
            try await wait("warning dismissed") { host.presentedViewController == nil }
            #expect(host.pickers.isEmpty && gate.state.withLock { $0.calls } == 0)

            flow.begin()
            try await wait("warning again") { host.messages.count == 2 && host.presentedViewController === host.messages[1] }
            let confirm: UIButton = try #require(find("databaseImportConfirm", in: host.messages[1].view))
            confirm.sendActions(for: .touchUpInside)
            try await wait("picker") { host.pickers.count == 1 }
            #expect(host.pickers[0] === flow.picker)
            flow.documentPickerWasCancelled(host.pickers[0])
            #expect(flow.picker == nil && gate.state.withLock { $0.calls } == 0, "Picker cancel imports nothing")
        }
    }

    @Test func progressThenNonCancelableSuccessAndOKRestarts() async throws {
        let gate = Gate()
        try await withFlow(gate) { host, flow in
            flow.start(URL(fileURLWithPath: "/backup.db"))
            try await wait("progress") { host.presentedViewController is PleaseWaitController && gate.state.withLock { $0.calls } == 1 }
            let progress = try #require(host.presentedViewController)
            #expect((find("opmlExportProgressMessage", in: progress.view) as UILabel?)?.text == "Please wait…")
            gate.state.withLock { $0.open = true }
            try await wait("success") { host.messages.count == 1 && host.presentedViewController === host.messages[0] }
            let success = host.messages[0]
            #expect(text(success, "sourceMessageTitle") == "Import successful")
            #expect(text(success, "sourceMessage") == "Please press OK to restart NotTennaPod")
            #expect(!success.allowsImplicitCancellation, "setCancelable(false)")
            #expect(!success.accessibilityPerformEscape())
            #expect(host.presentedViewController === success && gate.state.withLock { $0.restarts } == 0)
            let ok: UIButton = try #require(find("databaseImportRestart", in: success.view))
            #expect(ok.title(for: .normal) == "OK")
            ok.sendActions(for: .touchUpInside)
            try await wait("restart") { gate.state.withLock { $0.restarts } == 1 }
        }
    }

    @Test(arguments: [(AndroidDatabaseRestore.Failure.newerVersion(3_110_001), "This database was exported with a newer version of NotTennaPod. Your current installation does not yet know how to handle this file."),
                      (.invalid("file is not a database"), "file is not a database")])
    func failureShowsImportErrorWithSourceText(_ failure: AndroidDatabaseRestore.Failure, _ message: String) async throws {
        let gate = Gate(); gate.state.withLock { $0.open = true; $0.failure = failure }
        try await withFlow(gate) { host, flow in
            flow.start(URL(fileURLWithPath: "/backup.db"))
            try await wait("error") { host.messages.count == 1 && host.presentedViewController === host.messages[0] }
            #expect(text(host.messages[0], "sourceMessageTitle") == "Import error")
            #expect(text(host.messages[0], "sourceMessage") == message)
            #expect(text(host.messages[0], "sourceMessageOK") == "OK")
            #expect(gate.state.withLock { $0.restarts } == 0)
        }
    }

    /// Background time ended before the commit: the import rolled back and says so in plain words.
    @Test func interruptedImportSaysTheLibraryWasNotChanged() async throws {
        let gate = Gate(); gate.state.withLock { $0.open = true; $0.interrupted = true }
        try await withFlow(gate) { host, flow in
            flow.start(URL(fileURLWithPath: "/backup.db"))
            try await wait("error") { host.messages.count == 1 && host.presentedViewController === host.messages[0] }
            #expect(text(host.messages[0], "sourceMessageTitle") == "Import error")
            #expect(text(host.messages[0], "sourceMessage") == "The database import was interrupted. Your library was not changed.")
            #expect(text(host.messages[0], "sourceMessageOK") == "OK")
            #expect(gate.state.withLock { $0.restarts } == 0)
        }
    }

    /// The import's outcome is acknowledged when its result dialog is on screen, not when it is merely queued.
    @Test func theOutcomeIsAcknowledgedWhenItsDialogAppears() async throws {
        let gate = Gate(); gate.state.withLock { $0.open = true; $0.interrupted = true }
        var shown = 0
        var queued: [SourceMessageController] = []
        try await withViewTestWindow { window, _ in
            let host = Host()
            window.addChild(host); window.view.addSubview(host.view); host.view.frame = window.view.bounds; host.didMove(toParent: window)
            defer { host.presentedViewController?.dismiss(animated: false); host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
            // The presenter waits (a transition, a screen not attached yet): the dialog is only queued.
            let flow = DatabaseImportFlow(host: host, presentMessage: { dialog in
                if let dialog = dialog as? SourceMessageController { queued.append(dialog) }
            }, perform: { _ in
                if gate.state.withLock({ $0.interrupted }) { throw DatabaseImportInterrupted() }
            }, restart: {}, outcomeShown: { shown += 1 })
            flow.start(URL(fileURLWithPath: "/backup.db"))
            try await wait("queued") { queued.count == 1 }
            #expect(shown == 0, "Queued, not seen")
            host.present(queued[0], animated: false)
            try await wait("on screen") { shown == 1 }
        }
    }

    @Test func databaseRowsFollowSourceOrder() throws {
        let shell = BackupRestoreView(importAction: {}, exportAction: {}, databaseExportAction: {}, databaseImportAction: {})
        shell.frame = CGRect(origin: .zero, size: shell.sizeThatFits(CGSize(width: 390, height: 844))); shell.layoutIfNeeded()
        let export: UIButton = try #require(find("databaseExport", in: shell)), restore: UIButton = try #require(find("databaseImport", in: shell))
        let opml: UIButton = try #require(find("opmlExport", in: shell))
        #expect(export.frame.maxY <= restore.frame.minY && restore.frame.maxY <= opml.frame.minY)
        #expect(restore.accessibilityLabel == "Database import" && restore.accessibilityHint == "Import NotTennaPod database from another device")
    }

    /// Source `preferences_import_export.xml:35-44` — HTML category last: HTML export, Favorites export.
    @Test func htmlCategoryFollowsOPMLWithSourceRows() throws {
        var taps: [String] = []
        let shell = BackupRestoreView(importAction: {}, exportAction: {}, databaseExportAction: {}, databaseImportAction: {},
                                      htmlExportAction: { taps.append("html") }, favoritesExportAction: { taps.append("favorites") })
        shell.frame = CGRect(origin: .zero, size: shell.sizeThatFits(CGSize(width: 390, height: 844))); shell.layoutIfNeeded()
        #expect(shell.subviews.compactMap { ($0 as? UILabel)?.text } == ["Database", "OPML", "HTML"])
        let opml: UIButton = try #require(find("opmlImportPreference", in: shell))
        let html: UIButton = try #require(find("htmlExport", in: shell)), favorites: UIButton = try #require(find("favoritesExport", in: shell))
        #expect(opml.frame.maxY <= html.frame.minY && html.frame.maxY <= favorites.frame.minY)
        #expect(html.accessibilityLabel == "HTML export" && html.accessibilityHint == "Show your subscriptions to a friend")
        #expect(favorites.accessibilityLabel == "Favorites export" && favorites.accessibilityHint == "Export saved favorites to file")
        #expect(shell.bounds.height >= favorites.frame.maxY)
        html.sendActions(for: .touchUpInside); favorites.sendActions(for: .touchUpInside)
        #expect(taps == ["html", "favorites"])
    }
}

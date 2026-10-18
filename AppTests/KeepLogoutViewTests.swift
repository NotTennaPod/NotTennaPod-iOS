import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// The Synchronization page's rows and dialogs for a Keep at logout, previous libraries and the export choice
/// (PROTOCOL §15.5): their words, order, layout at the device's widths in both orientations, left to right and
/// right to left, VoiceOver labels and values, and the action each control reaches.
@MainActor @Suite(.serialized)
struct KeepLogoutViewTests {
    nonisolated static let open = "0b8c1d58-4f8e-4d0e-9b8b-3c1f5f8d2a10"
    /// Two previous libraries kept the same day (their labels show the time), and an older one.
    nonisolated static let previous: [LibraryRegistry.PreviousLibrary] = [
        .init(id: "3a1d1f2e-0000-4000-8000-000000000001", identity: "a", keptAt: 1_780_000_000_000),
        .init(id: "3a1d1f2e-0000-4000-8000-000000000002", identity: "b", keptAt: 1_780_000_600_000),
        .init(id: "3a1d1f2e-0000-4000-8000-000000000003", identity: "c", keptAt: 1_700_000_000_000),
    ]

    enum State: String, CaseIterable, Sendable {
        case keeping, keepingCast, keepStalledStorage, keepStalled, loggedOutCast, readyCast, previousOnly, serverWithPrevious
        /// The Keep waits for playback that may resume after an interruption, with "Stop playback and continue";
        /// a Keep that stalled for lack of storage keeps its explanation and gets the action too.
        case keepingInterrupted, keepStalledInterrupted

        var page: ServerSynchronizationPage {
            var registry = LibraryRegistry()
            registry.previous = KeepLogoutViewTests.previous
            func entry(_ state: LibraryRegistry.ServerLibrary.State) -> LibraryRegistry.ServerLibrary {
                .init(id: KeepLogoutViewTests.open, serverURL: "https://sync.example.test", serverID: "s", accountID: ContractIdentity.randomUUID(),
                      username: "alice", state: state, operation: state == .keeping ? ContractIdentity.randomUUID() : nil, createdAt: 0)
            }
            let summaries = { (entry: LibraryRegistry.ServerLibrary) in [entry.id: ServerLibrarySummary(entry: entry, hasUsableToken: true)] }
            switch self {
            case .keeping, .keepingCast, .keepStalledStorage, .keepStalled, .keepingInterrupted, .keepStalledInterrupted:
                registry.libraries = [entry(.keeping)]; registry.active = .server(KeepLogoutViewTests.open)
                let failure: KeepFailure? = self == .keepStalledStorage || self == .keepStalledInterrupted ? .storage
                    : self == .keepStalled ? .other : nil
                return .make(registry: registry, open: .server(KeepLogoutViewTests.open), otherProvider: false, summaries: summaries(entry(.keeping)),
                             castBlocks: self == .keepingCast, keepFailure: failure,
                             playbackHold: self == .keepingInterrupted || self == .keepStalledInterrupted ? .resumingAfterInterruption : nil)
            case .loggedOutCast:
                registry.libraries = [entry(.inactive)]
                return .make(registry: registry, open: .server(KeepLogoutViewTests.open), otherProvider: false, summaries: [:], castBlocks: true)
            case .readyCast:
                registry.libraries = [entry(.ready)]
                return .make(registry: registry, open: .standalone, otherProvider: false, summaries: summaries(entry(.ready)), castBlocks: true)
            case .previousOnly:
                return .make(registry: registry, open: .standalone, otherProvider: false, summaries: [:])
            case .serverWithPrevious:
                registry.libraries = [entry(.active)]; registry.active = .server(KeepLogoutViewTests.open)
                return .make(registry: registry, open: .server(KeepLogoutViewTests.open), otherProvider: false, summaries: summaries(entry(.active)))
            }
        }

        var status: (String, String)? {
            switch self {
            case .keeping: ("Logged out", "This library will become this phone's own library when playback is paused or stopped.")
            case .keepingInterrupted: ("Logged out", "This library will become this phone's own library when playback is paused or stopped. Playback may resume when the interruption ends.")
            case .keepStalledInterrupted: ("Logged out", "You can keep listening. NotTennaPod could not finish keeping this library. There is not enough storage. It tries again when playback is paused or the app opens. Playback may resume when the interruption ends.")
            case .keepingCast: ("Logged out", "Keeping this library finishes after you disconnect from Cast.")
            case .keepStalledStorage: ("Logged out", "You can keep listening. NotTennaPod could not finish keeping this library. There is not enough storage. It tries again when playback is paused or the app opens.")
            case .keepStalled: ("Logged out", "You can keep listening. NotTennaPod could not finish keeping this library. It tries again when playback is paused or the app opens.")
            case .loggedOutCast: ("Logged out", "This device's library will be used after you disconnect from Cast.")
            case .readyCast: ("Server library ready", "It will be used after you disconnect from Cast.")
            case .previousOnly, .serverWithPrevious: nil
            }
        }

        var identifiers: [String] {
            let previous = KeepLogoutViewTests.previous.sorted { $0.keptAt < $1.keptAt }.map { "ntp_server_previous_library-\($0.id)" }
            let ordinary = ["preference_synchronization_description", "pref_synchronization_sync", "pref_synchronization_force_full_sync",
                            "pref_synchronization_logout"]
            switch self {
            case .keeping, .keepingCast, .keepStalledStorage, .keepStalled:
                return [ordinary[0], "ntp_server_status"] + ordinary.dropFirst() + previous
            case .keepingInterrupted, .keepStalledInterrupted:
                return [ordinary[0], "ntp_server_status", "ntp_server_stop_playback"] + ordinary.dropFirst() + previous
            case .loggedOutCast:
                return [ordinary[0], "ntp_server_status"] + ordinary.dropFirst() + ["ntp_server_libraries"] + previous
            case .readyCast: return ["preference_synchronization_description", "ntp_server_status", "pref_synchronization_logout"] + previous
            case .previousOnly: return ordinary + previous
            case .serverWithPrevious:
                return ["preference_synchronization_description", "ntp_server_setlogin_information", "pref_synchronization_sync",
                        "pref_synchronization_force_full_sync", "ntp_server_log", "pref_synchronization_logout"] + previous
            }
        }
    }

    private func find<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: T.self) }.first
    }

    /// Snapshots for the record (`TEST_RUNNER_KEEP_SHOTS=<folder>`); nothing is written otherwise.
    private func snapshot(_ view: UIView, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["KEEP_SHOTS"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad"
            : ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" ? "Duo" : "iPhone"
        let url = URL(fileURLWithPath: folder).appendingPathComponent(device, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: .init(for: view.traitCollection)).image { context in
            Appearance.background.setFill(); context.fill(view.bounds)
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: url.appendingPathComponent(name + ".png"))
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "The component must reach its observable completion state")
    }

    @Test(arguments: State.allCases)
    func everyStateShowsItsRowsAndWordsAtEveryWidthAndDirection(state: State) async throws {
        let page = state.page
        try await withViewTestWindow { host, window in
            let portrait = min(window.bounds.width, window.bounds.height), landscape = max(window.bounds.width, window.bounds.height)
            for rtl in [false, true] {
                let settings = SynchronizationSettingsView(state: SynchronizationState(), server: page, width: portrait)
                settings.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                host.view.addSubview(settings)
                defer { settings.removeFromSuperview() }
                var actions: [SynchronizationSettingsView.Action] = []
                settings.onAction = { actions.append($0) }
                for width in [portrait, landscape] {
                    settings.frame.size = settings.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
                    settings.setNeedsLayout(); settings.layoutIfNeeded()
                    let rows = settings.subviews.compactMap { $0 as? UIControl }.sorted { $0.frame.minY < $1.frame.minY }
                    #expect(rows.compactMap(\.accessibilityIdentifier) == state.identifiers, "\(state) \(width) rtl=\(rtl)")
                    if width == portrait { snapshot(settings, "rows-\(state.rawValue)-\(rtl ? "rtl" : "ltr")") }
                    let inset: CGFloat = width >= 600 ? 24 : 16
                    for (index, row) in rows.enumerated() {
                        let id = row.accessibilityIdentifier ?? "?"
                        #expect(row.frame.minX == 0 && abs(row.frame.width - width) < 0.5 && row.frame.height >= 64, "\(id)")
                        if index > 0 { #expect(abs(rows[index - 1].frame.maxY - row.frame.minY) < 0.5, "\(id) follows without gap or overlap") }
                        for label in row.subviews.compactMap({ $0 as? UILabel }) where !(label.text ?? "").isEmpty {
                            let needed = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude)).height
                            #expect(needed <= label.frame.height + 0.5 && label.frame.maxY <= row.bounds.height + 0.5, "\(id) \(label.text ?? "")")
                            #expect(label.frame.minX >= inset - 0.5 && label.frame.maxX <= width - inset + 0.5, "\(id) horizontal")
                        }
                    }
                }
                if let (title, summary) = state.status {
                    let status: UIControl = try #require(find("ntp_server_status", in: settings))
                    #expect(status.accessibilityLabel == title && status.accessibilityValue == summary)
                    #expect(status.accessibilityTraits.contains(.staticText))
                }
                // "Library from before %1$@": the date, with the time for the two kept the same day.
                let labels = SynchronizationSettingsView.previousLibraryLabels(KeepLogoutViewTests.previous)
                for library in KeepLogoutViewTests.previous {
                    let row: UIControl = try #require(find("ntp_server_previous_library-\(library.id)", in: settings))
                    #expect(row.accessibilityLabel == labels[library.id] && row.accessibilityTraits.contains(.button))
                    #expect(row.accessibilityLabel?.hasPrefix("Library from before ") == true)
                    actions.removeAll()
                    row.sendActions(for: .touchUpInside)
                    #expect(actions == [.previousLibrary(library.id)])
                }
                // "Stop playback and continue" reaches its own action and reads as a button.
                if state == .keepingInterrupted || state == .keepStalledInterrupted {
                    let stop: UIControl = try #require(find("ntp_server_stop_playback", in: settings))
                    #expect(stop.accessibilityLabel == "Stop playback and continue" && stop.accessibilityTraits.contains(.button))
                    actions.removeAll()
                    stop.sendActions(for: .touchUpInside)
                    #expect(actions == [.stopPlayback])
                }
                #expect(labels[KeepLogoutViewTests.previous[0].id] != labels[KeepLogoutViewTests.previous[1].id])
                #expect((labels[KeepLogoutViewTests.previous[0].id]?.count ?? 0) > (labels[KeepLogoutViewTests.previous[2].id]?.count ?? 0),
                        "the same day's labels add the time")
            }
            #expect(page.providerChoiceBlocked == [.keeping, .keepingCast, .keepStalledStorage, .keepStalled, .keepingInterrupted,
                                                   .keepStalledInterrupted].contains(state))
        }
    }

    /// Presents a dialog and checks it fits: its title, message and buttons inside the window, nothing overlapping.
    private func present(_ dialog: SourceMessageController, rtl: Bool, in host: ViewTestWindowHost, window: UIWindow) async throws {
        if rtl { dialog.traitOverrides.layoutDirection = .rightToLeft }
        host.present(dialog, animated: false)
        try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
        dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
    }

    private func buttons(_ ids: [String], in dialog: SourceMessageController, window: UIWindow) throws -> [CGRect] {
        try ids.map { id in
            let button: UIButton = try #require(find(id, in: dialog.view), "\(id)")
            let frame = button.convert(button.bounds, to: window)
            #expect(window.bounds.contains(frame) && frame.height >= 48, "\(id) inside the window")
            let title = try #require(button.titleLabel)
            // Its whole title shows: on one line, or wrapped when the stacked buttons are narrower than it.
            #expect(title.sizeThatFits(CGSize(width: title.bounds.width, height: CGFloat.greatestFiniteMagnitude)).height <= title.bounds.height + 1,
                    "\(id) not clipped")
            #expect(title.frame.minX >= -0.5 && title.frame.maxX <= button.bounds.width + 0.5 && title.frame.maxY <= button.bounds.height + 0.5, "\(id) inside its button")
            return frame
        }
    }

    private func close(_ dialog: SourceMessageController, host: ViewTestWindowHost) async throws {
        if dialog.presentingViewController != nil { dialog.dismiss(animated: false) }
        try await wait { host.presentedViewController == nil }
    }

    @Test(arguments: [false, true])
    func theLogoutDialogOffersKeepGoBackAndCancel(rtl: Bool) async throws {
        try await withViewTestWindow { host, window in
            for unconfirmed in [0, 1, 7] {
                var chosen: [ServerLogoutChoice] = []
                let dialog = ServerSynchronizationDialogs.logout(unconfirmed: unconfirmed) { chosen.append($0) }
                try await present(dialog, rtl: rtl, in: host, window: window)
                let title: UILabel = try #require(find("sourceMessageTitle", in: dialog.view))
                #expect(title.text == "Logout")
                let message: UILabel = try #require(find("sourceMessage", in: dialog.view))
                let question = "Which library should this phone use after logging out?"
                switch unconfirmed {
                case 0: #expect(message.text == question)
                case 1: #expect(message.text == question + "\n\n1 change has not been confirmed by the server. If you keep this library, it stays on this phone and is not sent. If you go back, it is kept for when you log in again.")
                default: #expect(message.text == question + "\n\n7 changes have not been confirmed by the server. If you keep this library, they stay on this phone and are not sent. If you go back, they are kept for when you log in again.")
                }
                let frames = try buttons(["serverLogoutKeep", "serverLogoutGoBack", "serverLogoutCancel"], in: dialog, window: window)
                // Keep, then Go back, then Cancel: stacked in that order when they do not fit side by side; never overlapping.
                for (index, frame) in frames.enumerated() {
                    for other in frames.dropFirst(index + 1) { #expect(!frame.insetBy(dx: 0.5, dy: 0.5).intersects(other)) }
                }
                if frames[0].minY != frames[1].minY {
                    #expect(frames[0].maxY <= frames[1].minY + 0.5 && frames[1].maxY <= frames[2].minY + 0.5)
                }
                #expect(find("serverLogoutKeep", in: dialog.view, as: UIButton.self)?.title(for: .normal) == "Keep using this library")
                #expect(find("serverLogoutGoBack", in: dialog.view, as: UIButton.self)?.title(for: .normal) == "Go back to the library from before you signed in")
                #expect(find("serverLogoutCancel", in: dialog.view, as: UIButton.self)?.title(for: .normal) == "Cancel")
                snapshot(window, "logout-\(unconfirmed)-\(rtl ? "rtl" : "ltr")")
                let id = unconfirmed == 1 ? "serverLogoutGoBack" : unconfirmed == 7 ? "serverLogoutKeep" : "serverLogoutCancel"
                try #require(find(id, in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
                try await wait { host.presentedViewController == nil }
                #expect(chosen == (unconfirmed == 1 ? [.goBack] : unconfirmed == 7 ? [.keep] : []))
            }
        }
    }

    @Test(arguments: [false, true])
    func theExportChoiceOffersBothLibraries(rtl: Bool) async throws {
        try await withViewTestWindow { host, window in
            for pick in [0, 1] {
                var selected: [Int] = []
                let dialog = ServerSynchronizationDialogs.exportChoice(serverSummary: "alice on sync.example.test") { selected.append($0) }
                try await present(dialog, rtl: rtl, in: host, window: window)
                #expect(find("sourceMessageTitle", in: dialog.view, as: UILabel.self)?.text == "Export which library?")
                let server: UIControl = try #require(find("exportServerLibrary", in: dialog.view))
                let own: UIControl = try #require(find("exportOwnLibrary", in: dialog.view))
                #expect(server.accessibilityLabel == "The server's library" && server.accessibilityValue == "alice on sync.example.test")
                #expect(own.accessibilityLabel == "This phone's own library" && own.accessibilityTraits.contains(.button))
                let serverFrame = server.convert(server.bounds, to: window), ownFrame = own.convert(own.bounds, to: window)
                #expect(window.bounds.contains(serverFrame) && window.bounds.contains(ownFrame) && serverFrame.maxY <= ownFrame.minY + 0.5)
                for row in [server, own] {
                    for label in row.subviews.compactMap({ $0 as? UILabel }) {
                        #expect(label.textAlignment == (rtl ? .right : .left), "the choices follow the dialog's direction")
                        let frame = label.convert(label.bounds, to: window)
                        #expect(label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height <= label.bounds.height + 0.5)
                        #expect(frame.minX >= serverFrame.minX && frame.maxX <= serverFrame.maxX)
                    }
                }
                _ = try buttons(["exportChoiceCancel"], in: dialog, window: window)
                if pick == 0 { snapshot(window, "export-choice-\(rtl ? "rtl" : "ltr")") }
                (pick == 0 ? server : own).sendActions(for: .touchUpInside)
                try await wait { host.presentedViewController == nil && !selected.isEmpty }
                #expect(selected == [pick])
            }
        }
    }

    @Test(arguments: [false, true])
    func aPreviousLibraryOffersItsExportsAndRemoval(rtl: Bool) async throws {
        try await withViewTestWindow { host, window in
            let title = SynchronizationSettingsView.previousLibraryLabels(KeepLogoutViewTests.previous)[KeepLogoutViewTests.previous[0].id]
            var events: [String] = []
            let dialog = ServerSynchronizationDialogs.previousLibrary(title: title, export: { events.append("export") }, remove: { events.append("remove") })
            try await present(dialog, rtl: rtl, in: host, window: window)
            #expect(find("sourceMessageTitle", in: dialog.view, as: UILabel.self)?.text == title)
            _ = try buttons(["previousLibraryCancel"], in: dialog, window: window)
            snapshot(window, "previous-library-\(rtl ? "rtl" : "ltr")")
            let export: UIControl = try #require(find("previousLibraryExport", in: dialog.view))
            let remove: UIControl = try #require(find("previousLibraryRemove", in: dialog.view))
            #expect(export.accessibilityLabel == "Export" && remove.accessibilityLabel == "Remove library")
            let exportFrame = export.convert(export.bounds, to: window), removeFrame = remove.convert(remove.bounds, to: window)
            #expect(window.bounds.contains(exportFrame) && window.bounds.contains(removeFrame) && exportFrame.maxY <= removeFrame.minY + 0.5)
            export.sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil && events == ["export"] }

            var kinds: [LibraryExportKind] = []
            let exports = ServerSynchronizationDialogs.previousLibraryExports { kinds.append($0) }
            try await present(exports, rtl: rtl, in: host, window: window)
            let rows = try LibraryExportKind.allCases.map { kind -> UIControl in try #require(find("previousLibraryExport-\(kind)", in: exports.view)) }
            #expect(rows.map(\.accessibilityLabel) == ["Database export", "OPML export", "HTML export", "Favorites export"])
            let frames = rows.map { $0.convert($0.bounds, to: window) }
            #expect(frames.allSatisfy { window.bounds.contains($0) } && zip(frames, frames.dropFirst()).allSatisfy { $0.maxY <= $1.minY + 0.5 })
            snapshot(window, "previous-library-exports-\(rtl ? "rtl" : "ltr")")
            rows[3].sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil && kinds == [.favorites] }

            let removal = ServerSynchronizationDialogs.previousLibraryRemoval(title: title) { events.append("removed") }
            try await present(removal, rtl: rtl, in: host, window: window)
            #expect(find("sourceMessage", in: removal.view, as: UILabel.self)?.text == "Remove this library from this device? Its library data and downloads will be deleted.")
            _ = try buttons(["previousLibraryRemoveConfirm", "previousLibraryRemoveCancel"], in: removal, window: window)
            snapshot(window, "previous-library-removal-\(rtl ? "rtl" : "ltr")")
            try #require(find("previousLibraryRemoveConfirm", in: removal.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil && events == ["export", "removed"] }
        }
    }

    /// "Force full synchronization" asks first: it says the whole library is downloaded again, with its estimated size
    /// when one is known; OK runs it, Cancel sends nothing. The message and buttons fit at every width and direction.
    @Test(arguments: [false, true])
    func forceFullSynchronizationAsksFirstWithItsEstimatedSize(rtl: Bool) async throws {
        try await withViewTestWindow { host, window in
            for estimate in [Int64?.some(287_400_000), nil] {
                var confirmed = 0
                let dialog = ServerSynchronizationDialogs.fullSynchronization(estimate: estimate) { confirmed += 1 }
                try await present(dialog, rtl: rtl, in: host, window: window)
                #expect(find("sourceMessageTitle", in: dialog.view, as: UILabel.self)?.text == "Force full synchronization")
                let message: UILabel = try #require(find("sourceMessage", in: dialog.view))
                #expect(message.text == (estimate == nil ? "This downloads your whole library from the server again. Continue?"
                    : "This downloads your whole library from the server again (estimated 287 MB). Continue?"))
                let frame = message.convert(message.bounds, to: window)
                #expect(window.bounds.contains(frame))
                #expect(message.sizeThatFits(CGSize(width: message.bounds.width, height: .greatestFiniteMagnitude)).height <= message.bounds.height + 1,
                        "the whole message shows")
                let frames = try buttons(["fullSynchronizationConfirm", "fullSynchronizationCancel"], in: dialog, window: window)
                #expect(!frames[0].insetBy(dx: 0.5, dy: 0.5).intersects(frames[1]))
                #expect(find("fullSynchronizationConfirm", in: dialog.view, as: UIButton.self)?.title(for: .normal) == "OK")
                #expect(find("fullSynchronizationCancel", in: dialog.view, as: UIButton.self)?.title(for: .normal) == "Cancel")
                snapshot(window, "full-sync-\(estimate == nil ? "unknown" : "estimate")-\(rtl ? "rtl" : "ltr")")
                let id = estimate == nil ? "fullSynchronizationCancel" : "fullSynchronizationConfirm"
                try #require(find(id, in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
                try await wait { host.presentedViewController == nil }
                try await wait { confirmed == (estimate == nil ? 0 : 1) }
                #expect(confirmed == (estimate == nil ? 0 : 1), "OK runs it; Cancel sends nothing")
            }
        }
    }

    @Test func theAttachmentAndRemovalDialogsUseTheRoundTwoWording() {
        #expect(String(format: Appearance.text("ntp_server_use_library_message"), "https://sync.example.test")
                == "NotTennaPod will use your library from https://sync.example.test on this device. The library on this device is kept unchanged; when you log out, you can choose which one to keep.")
        #expect(Appearance.plural("ntp_server_remove_library_unsent", 3) == "It has 3 changes that have not been confirmed by the server. Removing it deletes them.")
    }
}

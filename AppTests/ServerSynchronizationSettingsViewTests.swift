import UIKit
import Synchronization
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// The Synchronization page in every state of PROTOCOL §15.5 (rows by state, the status row and subtitle),
/// the provider chooser's third row, the sign-in dialog and the kept libraries' dialog, at the device's widths in
/// both orientations, left to right and right to left, with their VoiceOver identifiers, labels and values.
@MainActor @Suite(.serialized)
struct ServerSynchronizationSettingsViewTests {
    enum PageState: String, CaseIterable, Sendable {
        case keptLibraries, loggedOut, attaching, ready, server, needsSignIn, serverNeedsUpdate, appNeedsUpdate
        case lineageUnknown, recovering, recoveryIncomplete, unreachable, attention
        /// An account without this library's history explains itself even with no usable token;
        /// starting over, the server's library is prepared while this one, now inactive, stays
        /// open.
        case lineageUnknownSignedOut, startingOver, recoveryWaiting
        case serverRestored, sharedInstallation, serverLostChanges, waitingForBackground
        /// A switch waiting for playback, playing or resuming after an interruption, with "Stop playback and continue".
        case readyPlaying, readyInterrupted, loggedOutInterrupted
        /// No network, or only mobile data sync may not use: why nothing is sent, instead of the last result.
        case offline, waitingForWiFi
        /// The attachment's download waits for Wi-Fi (mobile data or Low Data Mode with the preference off), or for space; a
        /// download or its staging waits for space; a Force full synchronization holds other devices' changes.
        case attachingWaitsForWiFi, attachingWaitsForSpace, waitingForSpace, fullSynchronizing, fullSynchronizationWaitsForWiFi
        /// The repair waits for any connection; a recovery that waits for space says so before "Restoring…".
        case fullSynchronizationWaitsOffline, recoveryWaitingForSpace
        /// Pushing waits for an explicit retry: a change too large for the server, or one it refused (with Needs attention).
        case changeTooLarge, changeRefused

        static let open = "0b8c1d58-4f8e-4d0e-9b8b-3c1f5f8d2a10", kept = "7c3b6f0e-2a59-4a8e-8d6f-0f1e2d3c4b5a"
        static func entry(_ id: String, _ state: LibraryRegistry.ServerLibrary.State, user: String = "alice") -> LibraryRegistry.ServerLibrary {
            .init(id: id, serverURL: "https://sync.example.test", serverID: "s", accountID: ContractIdentity.randomUUID(),
                  username: user, state: state, createdAt: 0)
        }
        static let lastSync = ServerLibraryStatus(lastSynchronizedAt: Int64(Date().addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000), successful: true)

        var page: ServerSynchronizationPage {
            var registry = LibraryRegistry()
            let kept = Self.entry(Self.kept, .inactive, user: "bob")
            func make(_ libraries: [LibraryRegistry.ServerLibrary], open: LibraryReference = .standalone, token: Bool = true,
                      signals: ServerSynchronizationSignals = .init(), hold: LibraryPlaybackHold? = nil,
                      waits: [String: ServerAttachWait] = [:]) -> ServerSynchronizationPage {
                registry.libraries = libraries; registry.active = open
                var summaries: [String: ServerLibrarySummary] = [:]
                for library in libraries {
                    summaries[library.id] = .init(entry: library, unsentChanges: library.id == Self.kept ? 3 : 4,
                                                  lastSynchronization: Self.lastSync, hasUsableToken: token)
                }
                return .make(registry: registry, open: open, otherProvider: false, summaries: summaries,
                             attachProgress: [Self.open: 12], attachWaits: waits, exchange: signals, playbackHold: hold)
            }
            let active = Self.entry(Self.open, .active)
            switch self {
            case .keptLibraries: return make([kept, Self.entry(Self.open, .inactive, user: "carol")])
            case .loggedOut: return make([Self.entry(Self.open, .inactive), kept], open: .server(Self.open))
            case .attaching: return make([Self.entry(Self.open, .attaching), kept])
            case .ready: return make([Self.entry(Self.open, .ready)])
            case .server: return make([active], open: .server(Self.open))
            case .needsSignIn: return make([active], open: .server(Self.open), token: false)
            case .serverNeedsUpdate: return make([active], open: .server(Self.open), signals: .init(pause: .serverNeedsUpdate))
            case .appNeedsUpdate: return make([active], open: .server(Self.open), signals: .init(pause: .appNeedsUpdate))
            case .lineageUnknown: return make([active], open: .server(Self.open), signals: .init(pause: .lineageUnknown))
            case .lineageUnknownSignedOut:
                return make([active], open: .server(Self.open), token: false, signals: .init(pause: .lineageUnknown))
            case .startingOver:
                return make([Self.entry(Self.kept, .inactive), Self.entry(Self.open, .attaching)], open: .server(Self.kept))
            case .recoveryWaiting: return make([active], open: .server(Self.open), signals: .init(recovery: .waiting))
            case .recovering: return make([active], open: .server(Self.open), signals: .init(recovery: .running))
            case .recoveryIncomplete: return make([active], open: .server(Self.open), signals: .init(recovery: .incomplete))
            case .unreachable: return make([active], open: .server(Self.open), signals: .init(unreachable: true))
            case .attention: return make([active], open: .server(Self.open), signals: .init(attentionItems: 2))
            case .serverRestored: return make([active], open: .server(Self.open), signals: .init(pause: .serverRestored))
            case .sharedInstallation: return make([active], open: .server(Self.open), signals: .init(pause: .sharedInstallation))
            case .serverLostChanges: return make([active], open: .server(Self.open), signals: .init(pause: .serverLostChanges))
            case .waitingForBackground: return make([active], open: .server(Self.open), signals: .init(waitingForBackground: true))
            case .offline: return make([active], open: .server(Self.open), signals: .init(unreachable: true, networkWait: .offline))
            case .waitingForWiFi: return make([active], open: .server(Self.open), signals: .init(networkWait: .mobileDataOff))
            case .attachingWaitsForWiFi: return make([Self.entry(Self.open, .attaching), kept], waits: [Self.open: .network(.mobileDataOff)])
            case .attachingWaitsForSpace: return make([Self.entry(Self.open, .attaching), kept], waits: [Self.open: .space(shortfall: 1)])
            case .waitingForSpace:
                var signals = ServerSynchronizationSignals()
                signals.insufficientSpace = true
                return make([active], open: .server(Self.open), signals: signals)
            case .fullSynchronizing:
                var signals = ServerSynchronizationSignals()
                signals.fullSynchronizing = true
                return make([active], open: .server(Self.open), signals: signals)
            case .fullSynchronizationWaitsForWiFi:
                var signals = ServerSynchronizationSignals()
                signals.fullSynchronizationWaits = .mobileDataOff
                return make([active], open: .server(Self.open), signals: signals)
            case .fullSynchronizationWaitsOffline:
                var signals = ServerSynchronizationSignals()
                signals.fullSynchronizationWaits = .offline
                return make([active], open: .server(Self.open), signals: signals)
            case .recoveryWaitingForSpace:
                var signals = ServerSynchronizationSignals(recovery: .running)
                signals.insufficientSpace = true
                return make([active], open: .server(Self.open), signals: signals)
            case .changeTooLarge: return make([active], open: .server(Self.open), signals: .init(pause: .changeTooLarge))
            case .changeRefused: return make([active], open: .server(Self.open), signals: .init(pause: .changeRefused, attentionItems: 1))
            case .readyPlaying: return make([Self.entry(Self.open, .ready)], hold: .playing)
            case .readyInterrupted: return make([Self.entry(Self.open, .ready)], hold: .resumingAfterInterruption)
            case .loggedOutInterrupted:
                return make([Self.entry(Self.open, .inactive), kept], open: .server(Self.open), hold: .resumingAfterInterruption)
            }
        }

        /// The rows a person sees, top to bottom.
        var identifiers: [String] {
            let ordinary = ["preference_synchronization_description", "pref_synchronization_sync",
                            "pref_synchronization_force_full_sync", "pref_synchronization_logout"]
            let server = ["preference_synchronization_description", "ntp_server_setlogin_information", "pref_synchronization_sync",
                          "pref_synchronization_force_full_sync", "ntp_server_log", "pref_synchronization_logout"]
            func status(_ rows: [String], extra: [String] = []) -> [String] { [rows[0], "ntp_server_status"] + extra + rows.dropFirst() }
            switch self {
            case .keptLibraries: return ordinary + ["ntp_server_libraries"]
            case .loggedOut: return status(ordinary) + ["ntp_server_libraries"]
            case .attaching, .ready, .startingOver, .attachingWaitsForWiFi, .attachingWaitsForSpace:
                return ["preference_synchronization_description", "ntp_server_status", "pref_synchronization_logout"]
            case .server, .unreachable: return server
            case .needsSignIn, .serverNeedsUpdate, .appNeedsUpdate, .recovering, .recoveryIncomplete, .recoveryWaiting: return status(server)
            case .serverRestored, .sharedInstallation, .serverLostChanges, .waitingForBackground, .changeTooLarge: return status(server)
            case .changeRefused: return status(Array(server.dropLast())) + ["ntp_server_attention", "pref_synchronization_logout"]
            case .offline, .waitingForWiFi, .waitingForSpace, .fullSynchronizing, .fullSynchronizationWaitsForWiFi, .fullSynchronizationWaitsOffline,
                 .recoveryWaitingForSpace: return status(server)
            case .lineageUnknown, .lineageUnknownSignedOut: return status(server, extra: ["ntp_server_start_over"])
            case .attention: return Array(server.dropLast()) + ["ntp_server_attention", "pref_synchronization_logout"]
            case .readyPlaying, .readyInterrupted:
                return ["preference_synchronization_description", "ntp_server_status", "ntp_server_stop_playback", "pref_synchronization_logout"]
            case .loggedOutInterrupted: return status(ordinary, extra: ["ntp_server_stop_playback"]) + ["ntp_server_libraries"]
            }
        }

        /// The status row's title and summary as a person reads them.
        var status: (String, String)? {
            switch self {
            case .keptLibraries, .server, .unreachable, .attention: nil
            case .loggedOut: ("Logged out", "This device's library will be used when playback is paused or stopped.")
            case .attaching, .startingOver: ("Preparing the server library", "Downloading the account's library (12 items so far)…")
            case .ready: ("Server library ready", "It will be used when playback is paused or stopped.")
            case .needsSignIn: ("Sign in again", "The server no longer accepts this device's login. Your changes are kept and sent after you sign in.")
            case .serverNeedsUpdate: ("This server needs updating", "Your changes are kept until then.")
            case .appNeedsUpdate: ("This app needs updating", "Your changes are kept until then.")
            case .lineageUnknown, .lineageUnknownSignedOut:
                ("Synchronization paused", "The server no longer has this library's history. This library and its changes are kept on this device.")
            case .recovering: ("Restoring synchronization", "The server was restored from a backup. Your changes are being sent again.")
            case .recoveryIncomplete: ("Synchronization restored", "Some changes could not be restored. See the synchronization log.")
            case .recoveryWaiting: ("Restoring synchronization", "Some changes are waiting for another device to restore them. See the synchronization log.")
            case .serverRestored: ("Synchronization paused", "The server was restored from a backup. This library and its changes are kept on this device.")
            case .sharedInstallation: ("Synchronization paused", "Another copy of this library uses the same login. This library and its changes are kept on this device.")
            case .serverLostChanges: ("Synchronization paused", "The server no longer has some changes this library sent. This library and its changes are kept on this device.")
            case .changeTooLarge: ("Synchronization paused", "A change made on this device is too large for the server. It is kept on this device; later changes wait behind it.")
            case .changeRefused: ("Synchronization paused", "A change made on this device was refused by the server. It is kept on this device; later changes wait behind it.")
            case .waitingForBackground: ("Waiting to apply changes", "Large changes from the server are applied when NotTennaPod is in the background and not playing, so they never slow it down while you use it.")
            case .readyPlaying: ("Server library ready", "It will be used when playback is paused or stopped.")
            case .readyInterrupted: ("Server library ready", "It will be used when playback is paused or stopped. Playback may resume when the interruption ends.")
            case .loggedOutInterrupted: ("Logged out", "This device's library will be used when playback is paused or stopped. Playback may resume when the interruption ends.")
            case .offline: ("No network connection", "Changes are kept and sent when the connection returns.")
            case .waitingForWiFi: ("Waiting for Wi-Fi", "Synchronization over mobile data is off in Settings → Downloads → Mobile updates. Changes are kept and sent on Wi-Fi.")
            case .attachingWaitsForWiFi: ("Waiting for Wi-Fi", "Synchronization over mobile data is off in Settings → Downloads → Mobile updates, and Low Data Mode counts as mobile data. The account's library continues downloading on Wi-Fi.")
            case .attachingWaitsForSpace: ("There is not enough space left on your device.", "The account's library continues downloading when space is free.")
            case .waitingForSpace: ("There is not enough space left on your device.", "Synchronization continues when space is free.")
            case .fullSynchronizing: ("Force full synchronization", "In progress. Changes from other devices appear when it finishes.")
            case .fullSynchronizationWaitsOffline: ("Force full synchronization", "Waiting for a network connection: it downloads your whole library when the connection returns.")
            case .recoveryWaitingForSpace: ("There is not enough space left on your device.", "Synchronization continues when space is free.")
            case .fullSynchronizationWaitsForWiFi: ("Force full synchronization", "Waiting for Wi-Fi: it downloads your whole library, and synchronization over mobile data is off in Settings → Downloads → Mobile updates (Low Data Mode counts as mobile data). Other changes keep synchronizing.")
            }
        }

        /// The toolbar subtitle (PROTOCOL §15.5 status table).
        var subtitle: String? {
            switch self {
            case .keptLibraries, .loggedOut, .loggedOutInterrupted: nil
            case .attaching, .startingOver, .attachingWaitsForSpace: "Preparing…"
            case .attachingWaitsForWiFi: "Waiting for Wi-Fi"
            case .ready, .readyPlaying, .readyInterrupted: "Ready"
            case .needsSignIn: "Sign in again"
            case .serverNeedsUpdate, .appNeedsUpdate, .lineageUnknown, .lineageUnknownSignedOut, .serverRestored, .sharedInstallation,
                 .serverLostChanges, .changeTooLarge, .changeRefused: "Paused"
            case .recovering: "Restoring…"
            case .unreachable: "Waiting for the server"
            case .offline: "No network connection"
            case .waitingForWiFi: "Waiting for Wi-Fi"
            case .server, .recoveryIncomplete, .recoveryWaiting, .attention, .waitingForBackground, .waitingForSpace, .fullSynchronizing, .fullSynchronizationWaitsForWiFi,
                 .fullSynchronizationWaitsOffline: "Successful ("
            case .recoveryWaitingForSpace: "Restoring…"
            }
        }
    }

    private func find<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: T.self) }.first
    }

    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), "The component must reach its observable completion state")
    }

    /// Snapshots of the rows for the record (`TEST_RUNNER_SYNCHRONIZATION_SHOTS=<folder>`); nothing is written otherwise.
    private func snapshot(_ view: UIView, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SYNCHRONIZATION_SHOTS"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad"
            : ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" ? "Duo" : "iPhone"
        let url = URL(fileURLWithPath: folder).appendingPathComponent(device, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: .init(for: view.traitCollection)).image { context in
            Appearance.background.setFill(); context.fill(view.bounds)
            view.layer.render(in: context.cgContext)
        }
        try? image.pngData()?.write(to: url.appendingPathComponent(name + ".png"))
    }

    @Test(arguments: PageState.allCases)
    func everyStateShowsItsRowsInOrderAtEveryWidthAndDirection(state: PageState) async throws {
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
                // Portrait, then the same view resized as a rotation does.
                for width in [portrait, landscape] {
                    settings.frame.size = settings.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
                    settings.setNeedsLayout(); settings.layoutIfNeeded()
                    let rows = settings.subviews.compactMap { $0 as? UIControl }.sorted { $0.frame.minY < $1.frame.minY }
                    #expect(rows.compactMap(\.accessibilityIdentifier) == state.identifiers, "\(state) \(width) rtl=\(rtl)")
                    let inset: CGFloat = width >= 600 ? 24 : 16
                    for (index, row) in rows.enumerated() {
                        let id = row.accessibilityIdentifier ?? "?"
                        #expect(row.frame.minX == 0 && abs(row.frame.width - width) < 0.5 && row.frame.height >= 64, "\(id)")
                        if index > 0 { #expect(abs(rows[index - 1].frame.maxY - row.frame.minY) < 0.5, "\(id) follows without gap or overlap") }
                        let labels = row.subviews.compactMap { $0 as? UILabel }.filter { !($0.text ?? "").isEmpty }
                        for label in labels {
                            // Nothing clipped: every label holds its whole text inside the row.
                            let needed = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude)).height
                            #expect(needed <= label.frame.height + 0.5 && label.frame.minY >= -0.5 && label.frame.maxY <= row.bounds.height + 0.5, "\(id) \(label.text ?? "")")
                            #expect(label.frame.minX >= inset - 0.5 && label.frame.maxX <= width - inset + 0.5, "\(id) horizontal")
                        }
                        let icon = row.subviews.compactMap { $0 as? UIImageView }.first
                        let leading: CGFloat = icon == nil ? inset : (width >= 600 ? 96 : 72)
                        for label in labels {
                            #expect(abs((rtl ? width - label.frame.maxX : label.frame.minX) - leading) <= 1, "\(id) text column")
                        }
                        if let icon {
                            #expect(abs((rtl ? width - icon.frame.maxX : icon.frame.minX) - inset) <= 1 && icon.frame.width == 48, "\(id) icon")
                        }
                    }
                    if width == portrait { snapshot(settings, "rows-\(state.rawValue)-\(rtl ? "rtl" : "ltr")") }
                }
                // VoiceOver: label, value and traits; the status row's words.
                if let (title, summary) = state.status {
                    let status: UIControl = try #require(find("ntp_server_status", in: settings))
                    #expect(status.accessibilityLabel == title && status.accessibilityValue == summary)
                    #expect(status.accessibilityTraits.contains([.needsSignIn, .recoveryIncomplete, .recoveryWaiting].contains(state) ? .button : .staticText))
                }
                let provider: UIControl = try #require(find("preference_synchronization_description", in: settings))
                if page.showsOrdinaryRows {
                    #expect(provider.accessibilityLabel == "Choose synchronization provider")
                } else {
                    #expect(provider.accessibilityLabel == nil && provider.accessibilityTraits.contains(.staticText))
                    #expect(provider.accessibilityValue?.hasPrefix("NotTennaPod server is an open-source synchronization server") == true)
                    let logout: UIControl = try #require(find("pref_synchronization_logout", in: settings))
                    #expect(logout.accessibilityValue == "Logged in as alice on https://sync.example.test. You can choose your synchronization provider again once you have logged out.")
                }
                if state == .server {
                    let sync: UIControl = try #require(find("pref_synchronization_sync", in: settings))
                    #expect(sync.accessibilityValue == "Synchronize subscription and episode state changes\n4 changes not yet synchronized")
                }
                if state == .keptLibraries {
                    let kept: UIControl = try #require(find("ntp_server_libraries", in: settings))
                    #expect(kept.accessibilityLabel == "Server libraries on this device")
                    #expect(kept.accessibilityValue == "2 libraries, 7 changes not yet synchronized")
                }
                if state == .attention {
                    let attention: UIControl = try #require(find("ntp_server_attention", in: settings))
                    #expect(attention.accessibilityLabel == "Needs attention" && attention.accessibilityValue == "2 items")
                }
                // The waiting switch's own action, a button VoiceOver reads by its words.
                if page.rows.contains(.stopPlayback) {
                    let stop: UIControl = try #require(find("ntp_server_stop_playback", in: settings))
                    #expect(stop.accessibilityLabel == "Stop playback and continue" && stop.accessibilityValue == nil)
                    #expect(stop.accessibilityTraits.contains(.button) && stop.isEnabled)
                } else {
                    #expect(find("ntp_server_stop_playback", in: settings, as: UIControl.self) == nil)
                }
                // Every actionable row reaches its own action (two rows swapping theirs would be noticed); the provider
                // and explaining status rows do not act.
                var expected: [String: SynchronizationSettingsView.Action] = [
                    "ntp_server_setlogin_information": .serverPassword, "pref_synchronization_sync": .synchronize,
                    "pref_synchronization_force_full_sync": .full, "ntp_server_log": .log, "ntp_server_attention": .attention,
                    "ntp_server_start_over": .startOver, "pref_synchronization_logout": .logout, "ntp_server_libraries": .keptLibraries]
                if page.showsOrdinaryRows {
                    // Today's rows without an account: only the provider choice and the kept libraries act.
                    expected = ["preference_synchronization_description": .choose, "ntp_server_libraries": .keptLibraries]
                }
                if page.rows.contains(.stopPlayback) { expected["ntp_server_stop_playback"] = .stopPlayback }
                if state == .needsSignIn { expected["ntp_server_status"] = .serverPassword }
                // "See the synchronization log." opens the log: a recovery that could not restore everything or waits.
                if state == .recoveryIncomplete || state == .recoveryWaiting { expected["ntp_server_status"] = .log }
                var acted: Set<String> = []
                for row in settings.subviews.compactMap({ $0 as? UIControl }) where row.isEnabled {
                    let id = row.accessibilityIdentifier ?? ""
                    actions.removeAll()
                    row.sendActions(for: .touchUpInside)
                    #expect(actions.map { "\($0)" } == (expected[id].map { ["\($0)"] } ?? []), "\(state) \(id): \(actions)")
                    if !actions.isEmpty { acted.insert(id) }
                }
                let shown = Set(state.identifiers + (state == .needsSignIn ? ["ntp_server_status"] : []))
                #expect(acted == Set(expected.keys).intersection(shown), "\(state): rows that acted \(acted.sorted())")
            }
        }
    }

    @Test func subtitlesFollowTheStatusTable() {
        for state in PageState.allCases {
            let text = state.page.subtitle.map(ServerSynchronizationText.subtitle)
            if let expected = state.subtitle { #expect(text?.hasPrefix(expected) == true, "\(state): \(text ?? "nil")") }
            else { #expect(text == nil, "\(state)") }
        }
    }

    @Test func plainWordsForEverySignInFailure() {
        func text(_ error: any Error) -> String { ServerSynchronizationText.message(for: error) }
        #expect(text(ServerClientError.wrongCredentials) == "Wrong username or password")
        #expect(text(ServerClientError.unreachable) == "The server cannot be reached. Check the address and your network connection.")
        #expect(text(ServerClientError.notAServer) == "This address is not a NotTennaPod server.")
        #expect(text(ServerClientError.serverNeedsUpdate) == "This server needs updating")
        #expect(text(ServerClientError.appNeedsUpdate) == "This app needs updating")
        #expect(text(ServerClientError.busy(retryAfter: 2)) == "The server is busy. Try again shortly.")
        #expect(text(ServerClientError.rateLimited(retryAfter: nil)) == "Too many attempts. Try again later.")
        let limited = text(ServerClientError.rateLimited(retryAfter: 600))
        let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("jm")
        #expect(limited == "Too many attempts. Try again after \(formatter.string(from: Date().addingTimeInterval(659))).", "\(limited)")
        #expect(text(ServerClientError.forbidden) == "This account is disabled.")
    }

    @Test func providerChoicesOfferTheServerThird() async throws {
        try await withViewTestWindow { host, window in
            for rtl in [false, true] {
                let choices = SynchronizationProviderChoices(frame: .zero)
                choices.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                host.view.addSubview(choices)
                defer { choices.removeFromSuperview() }
                let width = min(window.bounds.width, window.bounds.height) - 48
                choices.frame.size = choices.sizeThatFits(CGSize(width: width, height: 900))
                choices.layoutIfNeeded()
                let rows = ["syncProvider-gpodder", "syncProvider-nextcloud", "syncProvider-server"].compactMap { find($0, in: choices, as: UIControl.self) }
                try #require(rows.count == 3)
                #expect(rows[1].frame.maxY <= rows[2].frame.minY + 0.5)
                #expect(rows[2].accessibilityLabel == Appearance.text("ntp_server_description") && rows[2].accessibilityTraits.contains(.button))
                let icon = try #require(rows[2].subviews.compactMap { $0 as? UIImageView }.first)
                let label = try #require(rows[2].subviews.compactMap { $0 as? UILabel }.first)
                #expect(icon.image != nil && icon.frame.width == 48)
                #expect(rtl ? icon.frame.minX > label.frame.maxX : icon.frame.maxX < label.frame.minX)
                let needed = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude)).height
                #expect(needed <= label.frame.height + 0.5 && rows[2].frame.maxY <= choices.bounds.height + 0.5)
                var server = 0, other: [SynchronizationHTTPClient.Backend] = []
                choices.onSelectServer = { server += 1 }; choices.onSelect = { other.append($0) }
                for row in rows { row.sendActions(for: .touchUpInside) }
                #expect(server == 1 && other == [.gpodder, .nextcloud])
                snapshot(choices, "provider-choices-\(rtl ? "rtl" : "ltr")")
            }
        }
    }

    // MARK: - Dialogs

    /// A server that answers `/v1/info`, and a sign-in that accepts only `secret-password`.
    final class StubServer: SynchronizationHTTPTransport, Sendable {
        let signIns = Mutex(0)
        func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/info") {
                return .init(status: 200, body: Data(#"{"server_id":"s1","protocol":{"min":1,"max":1}}"#.utf8))
            }
            if path.hasSuffix("/v1/auth/device") {
                signIns.withLock { $0 += 1 }
                let body = try ContractJSON.decode(request.httpBody ?? Data())
                guard body["password"]?.stringValue == "secret-password" else {
                    return .init(status: 401, body: Data(#"{"error":"unauthorized","message":"no"}"#.utf8))
                }
                let install = body["install_id"]?.stringValue ?? ""
                return .init(status: 200, body: Data(#"{"token":"ntp1_t","install_id":"\#(install)","account":{"account_id":"9d0f8c5e-56f4-4b9e-8a39-34a95c0f2a2b","namespace":"4f13d776-a268-4469-91ec-b63f9e88cdde","username":"alice"}}"#.utf8))
            }
            return .init(status: 404, body: Data(#"{"error":"not_found","message":"no"}"#.utf8))
        }
    }

    private func accounts(_ transport: StubServer) throws -> (ServerAccounts, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ServerDialogs-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let accounts = ServerAccounts(.init(root: root, openLibrary: { .standalone }, requestSwitch: { _, _, _ in },
            secrets: MemoryServerSecrets(), makeClient: { ServerClient(address: $0, transport: transport) },
            device: ServerDevice(name: "NotTennaPod on iPhone", appVersion: "view-test")))
        return (accounts, root)
    }

    @Test(arguments: [false, true])
    func theSignInDialogAsksForTheAddressThenTheCredentials(rtl: Bool) async throws {
        let transport = StubServer()
        let (accounts, root) = try self.accounts(transport)
        defer { try? FileManager.default.removeItem(at: root) }
        try await withViewTestWindow { host, window in
            for (address, warns) in [("http://192.168.1.20:8080", true), ("sync.example.test", false), ("http://100.101.102.103:8080", false)] {
                let flow = ServerSignInFlow(accounts: accounts)
                var signedIn: ServerPendingSignIn?
                let dialog = ServerAuthenticationController(flow: flow) { signedIn = $0 }
                if rtl { dialog.traitOverrides.layoutDirection = .rightToLeft }
                host.present(dialog, animated: false)
                try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
                let title: UILabel = try #require(find("sourceMessageTitle", in: dialog.view))
                #expect(title.accessibilityLabel == Appearance.text("gpodnetauth_login_butLabel"))
                let host_: UITextField = try #require(find("serverHost", in: dialog.view))
                #expect(host_.accessibilityLabel == "Server address" && host_.keyboardType == .URL)
                host_.text = address
                try #require(find("serverProceed", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
                try await wait { flow.stage == .credentials && !flow.busy }
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                #expect(title.accessibilityLabel == ServerAddress(entered: address)?.string)
                let warning: UILabel = try #require(find("serverEncryptionWarning", in: dialog.view))
                #expect((warning.alpha == 1) == warns, "\(address)")
                let username: UITextField = try #require(find("serverUsername", in: dialog.view))
                let password: UITextField = try #require(find("serverPassword", in: dialog.view))
                #expect(password.isSecureTextEntry)
                // Every control lies inside the dialog's panel, mirrored in right to left.
                for control in [username, password] {
                    let frame = control.convert(control.bounds, to: window)
                    #expect(window.bounds.contains(frame) && frame.width > 100)
                }
                username.text = "alice"; password.text = "wrong"
                try #require(find("serverLogin", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
                try await wait { flow.error != nil && !flow.busy }
                dialog.view.layoutIfNeeded()
                let error: UILabel = try #require(find("serverAuthenticationError", in: dialog.view))
                #expect(error.text == "Wrong username or password" && !error.isHidden)
                password.text = "secret-password"
                try #require(find("serverLogin", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
                try await wait { signedIn != nil && host.presentedViewController == nil }
                #expect(signedIn?.kind == .firstAttachment && signedIn?.username == "alice")
                #expect(password.text?.isEmpty != false, "the password is not kept in the dialog")
            }
        }
    }

    @Test(arguments: [false, true])
    func keptLibrariesListEachWithLogInAndRemove(rtl: Bool) async throws {
        let page = PageState.keptLibraries.page
        try await withViewTestWindow { host, window in
            let body = KeptServerLibrariesBody(libraries: page.keptLibraries)
            let dialog = SourceMessageController(title: Appearance.text("ntp_server_libraries_title"), message: "",
                positive: .init(title: Appearance.text("close_label"), identifier: "keptLibrariesClose"), customBody: body)
            if rtl { dialog.traitOverrides.layoutDirection = .rightToLeft }
            var logins: [String] = [], removals: [String] = []
            body.onLogin = { logins.append($0.entry.id) }; body.onRemove = { removals.append($0.entry.id) }
            host.present(dialog, animated: false)
            try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
            dialog.view.layoutIfNeeded()
            for library in page.keptLibraries {
                let name: UILabel = try #require(find("keptLibrary-\(library.entry.id)", in: body))
                #expect(name.text == "\(library.entry.username) on sync.example.test")
                let details: UILabel = try #require(find("keptLibraryDetails-\(library.entry.id)", in: body))
                #expect(details.text?.contains("changes not yet synchronized") == true && details.text?.contains("Last synchronized") == true)
                let login: UIButton = try #require(find("keptLibraryLogin-\(library.entry.id)", in: body))
                let remove: UIButton = try #require(find("keptLibraryRemove-\(library.entry.id)", in: body))
                let loginFrame = login.convert(login.bounds, to: window), removeFrame = remove.convert(remove.bounds, to: window)
                #expect(window.bounds.contains(loginFrame) && window.bounds.contains(removeFrame) && loginFrame.height >= 48)
                // "Log in" is the trailing action, as a dialog's confirming button.
                #expect(rtl ? loginFrame.maxX <= removeFrame.minX : loginFrame.minX >= removeFrame.maxX)
                login.sendActions(for: .touchUpInside); remove.sendActions(for: .touchUpInside)
            }
            #expect(logins == page.keptLibraries.map(\.entry.id) && removals == logins)
            snapshot(dialog.view, "kept-libraries-dialog-\(rtl ? "rtl" : "ltr")")
            dialog.dismiss(animated: false)
            try await wait { host.presentedViewController == nil }
        }
    }

    /// `version_unsupported` (PROTOCOL §15.5 status table): the exchange's report names the side, the page's status row says it,
    /// "This server needs updating" or "This app needs updating", each "Your changes are kept until then.", under
    /// "Paused", in both directions; the row explains and does not act.
    @Test(arguments: [false, true])
    func theSideThatNeedsUpdatingIsNamed(rtl: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ServerUpdateSide-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = PageState.open
        var registry = LibraryRegistry()
        registry.libraries = [PageState.entry(id, .active)]; registry.active = .server(id)
        try LibraryRegistryFile(root: root).write(registry)
        let secrets = MemoryServerSecrets()
        try secrets.saveInstallation(.init(transportNonce: ContractIdentity.randomUUID(), token: "ntp1_token"), library: id,
                                     install: ContractIdentity.randomUUID())
        let accounts = ServerAccounts(.init(root: root, openLibrary: { .server(id) }, requestSwitch: { _, _, _ in }, secrets: secrets,
            makeClient: { ServerClient(address: $0, transport: StubServer()) },
            device: ServerDevice(name: "NotTennaPod on iPhone", appVersion: "view-test")))
        await accounts.refresh()
        try await withViewTestWindow { host, window in
            for (appNeedsUpdate, title) in [(false, "This server needs updating"), (true, "This app needs updating")] {
                var report = ServerExchangeReport()
                report.pause = .versionUnsupported
                report.appNeedsUpdate = appNeedsUpdate
                accounts.exchangeReported(report)
                let page = accounts.page(otherProvider: false)
                #expect(page.subtitle.map(ServerSynchronizationText.subtitle) == "Paused")
                let width = min(window.bounds.width, window.bounds.height)
                let settings = SynchronizationSettingsView(state: SynchronizationState(), server: page, width: width)
                settings.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                host.view.addSubview(settings)
                defer { settings.removeFromSuperview() }
                settings.frame.size = settings.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
                settings.layoutIfNeeded()
                let status: UIControl = try #require(find("ntp_server_status", in: settings))
                #expect(status.accessibilityLabel == title && status.accessibilityValue == "Your changes are kept until then.", "\(title)")
                #expect(status.accessibilityTraits.contains(.staticText) && !status.accessibilityTraits.contains(.button))
                let words = status.subviews.compactMap { ($0 as? UILabel)?.text }
                #expect(words == [title, "Your changes are kept until then."])
                snapshot(settings, "rows-update-\(appNeedsUpdate ? "app" : "server")-\(rtl ? "rtl" : "ltr")")
            }
        }
    }

    // MARK: - Settings search follows the page

    /// A settings screen over a library of its own, whose Synchronization page is `server`'s.
    private func settingsScreen(_ server: ServerAccounts, folder: URL) async throws -> (LibraryViewController, FeedLibraryStore) {
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let accounts = SynchronizationAccounts(store: store, credentials: ViewTestCredentials())
        let delivery = SynchronizationDelivery(store: store, publisher: ViewTestPublisher(),
            text: .init(errorTitle: "Synchronization failed", errorPrefix: "Error: "), foreground: { _ in false }, episodesChanged: { _ in })
        let coordinator = SynchronizationCoordinator(store: store, execute: { _ in throw CancellationError() })
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil, timeDisplayPreferences: nil,
            navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil, synchronizationAccounts: accounts,
            synchronization: coordinator, synchronizationDelivery: delivery, serverAccounts: server)
        return (controller, store)
    }

    /// Server accounts whose registry holds `entry`, with `open` the library the graph opened and a usable token.
    private func serverAccounts(root: URL, entry: LibraryRegistry.ServerLibrary, open: LibraryReference) throws -> ServerAccounts {
        var registry = LibraryRegistry()
        registry.libraries = [entry]; registry.active = open
        try LibraryRegistryFile(root: root).write(registry)
        let secrets = MemoryServerSecrets()
        try secrets.saveInstallation(.init(transportNonce: ContractIdentity.randomUUID(), token: "ntp1_token"), library: entry.id,
                                     install: ContractIdentity.randomUUID())
        return ServerAccounts(.init(root: root, openLibrary: { open }, requestSwitch: { _, _, _ in }, secrets: secrets,
            makeClient: { ServerClient(address: $0, transport: StubServer()) }, device: ServerDevice(name: "NotTennaPod on iPhone", appVersion: "view-test")))
    }

    private func mount(_ controller: LibraryViewController, _ host: ViewTestWindowHost) {
        host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
        controller.view.frame = host.view.bounds
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    private func unmount(_ controller: LibraryViewController) {
        controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
    }

    private func shownSearch(_ controller: LibraryViewController) -> SettingsSearchView? {
        if case .settingsSearch(let search)? = controller.path.last { search } else { nil }
    }

    /// "Needs attention" appears in an open settings search when an item arrives, and leaves a search kept behind a
    /// result's page when its last item goes, so Back shows the search without it; the text typed stays.
    @Test func aSettingsSearchFollowsNeedsAttentionWhileOpenAndKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SearchFollowsPage-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try serverAccounts(root: folder, entry: PageState.entry(PageState.open, .active), open: .server(PageState.open))
        await server.refresh()
        let (controller, store) = try await settingsScreen(server, folder: folder)
        func finds(_ search: SettingsSearchView) -> Bool { search.results.contains { $0.entry.key == "ntp_server_attention" } }
        try await withViewTestWindow { host, _ in
            mount(controller, host)
            defer { unmount(controller) }
            controller.push(.settings(.main))
            controller.openSettingsSearch()
            let search = try #require(shownSearch(controller))
            search.setQuery("Needs attention")
            #expect(!finds(search), "nothing needs attention yet")
            var signals = server.exchange; signals.attentionItems = 1
            server.update(signals: signals)
            try await wait { finds(search) }
            // Open the result, then the last item goes while the search is kept behind the screens.
            let result = try #require(search.results.first { $0.entry.key == "ntp_server_attention" })
            controller.openSettingsSearchResult(result)
            let pages = controller.path.suffix(2).map { screen -> SettingsPage? in if case .settings(let page) = screen { page } else { nil } }
            #expect(pages == [.synchronization, .synchronizationAttention], "the result opens Needs attention over the page")
            signals.attentionItems = 0
            server.update(signals: signals)
            for _ in 0..<2 {
                let back: UIButton = try #require(find("toolbarBack", in: controller.view))
                back.sendActions(for: .touchUpInside)
                controller.view.layoutIfNeeded()
            }
            #expect(shownSearch(controller) === search)
            try await wait { !finds(search) }
            #expect(search.field.text == "Needs attention", "the text typed stays")
        }
        try await store.close()
    }

    /// While a server library is prepared or waits to be switched to, the page shows no "Synchronize now" or "Force
    /// full synchronization", and settings search does not find them; Logout is found.
    @Test(arguments: [LibraryRegistry.ServerLibrary.State.attaching, .ready])
    func aPreparedServerLibraryIsSearchedAsThePageShowsIt(state: LibraryRegistry.ServerLibrary.State) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SearchPrepared-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try serverAccounts(root: folder, entry: PageState.entry(PageState.open, state), open: .standalone)
        await server.refresh()
        let (controller, store) = try await settingsScreen(server, folder: folder)
        try await withViewTestWindow { host, _ in
            mount(controller, host)
            defer { unmount(controller) }
            #expect(controller.synchronizationSettings?.serverPage?.rows.contains(.synchronize) == false)
            let keys = Set(controller.settingsSearchItems().map(\.entry.key))
            #expect(!keys.contains("pref_synchronization_sync") && !keys.contains("pref_synchronization_force_full_sync"), "\(state)")
            #expect(keys.contains("pref_synchronization_logout"))
        }
        try await store.close()
    }

    // MARK: - Synchronization log and Needs attention (PROTOCOL §15.5)

    /// The log: one row per entry in the order given (newest first), what happened, the detail and the time, inside
    /// the row at the device's widths in both orientations and directions, read by VoiceOver as one element; with no
    /// entries, the empty view's words.
    @Test(arguments: [false, true])
    func theLogShowsEveryEntryInOrderAtEveryWidth(rtl: Bool) async throws {
        try await withViewTestWindow { host, window in
            let list = ServerSyncLogView()
            if rtl { list.traitOverrides.layoutDirection = .rightToLeft }
            host.view.addSubview(list)
            defer { list.removeFromSuperview() }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let kinds = ["push", "outcome", "paused", "unknown_kind"]
            let entries = (0..<12).map { index in
                ServerSyncLogEntry(time: now - Int64(index) * 60_000, kind: kinds[index % kinds.count],
                                   detail: index == 1 ? "favorite.set rejected invalid: a long reason the server gave for refusing this change, which wraps"
                                       : "podcast.subscribe applied \(index)")
            }
            list.update(entries)
            let portrait = min(window.bounds.width, window.bounds.height), landscape = max(window.bounds.width, window.bounds.height)
            for width in [portrait, landscape] {
                list.frame = CGRect(x: 0, y: 0, width: width, height: max(window.bounds.height, 600))
                list.layoutIfNeeded(); list.table.layoutIfNeeded()
                let cells = list.table.visibleCells.compactMap { $0 as? ServerSyncLogCell }.sorted { $0.frame.minY < $1.frame.minY }
                try #require(cells.count >= 4, "rows shown: \(cells.count)")
                let inset: CGFloat = width >= 600 ? 24 : 16
                for (index, cell) in cells.enumerated() {
                    let entry = entries[index]
                    let label = ["push": "Sent", "outcome": "Result", "paused": "Paused"][entry.kind] ?? entry.kind
                    #expect(cell.accessibilityIdentifier == "serverSyncLogRow" && cell.isAccessibilityElement)
                    #expect(cell.accessibilityLabel == label, "\(cell.accessibilityLabel ?? "")")
                    #expect(cell.accessibilityValue?.hasPrefix(entry.detail + ", ") == true, "\(cell.accessibilityValue ?? "")")
                    for text in cell.contentView.subviews.flatMap(\.subviews).compactMap({ $0 as? UILabel }) {
                        let frame = text.convert(text.bounds, to: cell)
                        let needed = text.sizeThatFits(CGSize(width: text.bounds.width, height: .greatestFiniteMagnitude)).height
                        #expect(needed <= text.bounds.height + 0.5, "\(text.text ?? "") clipped")
                        #expect(frame.minX >= inset - 0.5 && frame.maxX <= width - inset + 0.5 && frame.maxY <= cell.bounds.height + 0.5,
                                "\(text.text ?? "") inside the row")
                        #expect(text.effectiveUserInterfaceLayoutDirection == (rtl ? .rightToLeft : .leftToRight) && text.textAlignment == .natural)
                    }
                    if index > 0 { #expect(cells[index - 1].frame.maxY <= cell.frame.minY + 0.5, "no overlap") }
                }
                if width == portrait { snapshot(list, "log-\(rtl ? "rtl" : "ltr")") }
            }
            let empty: UIView = try #require(find("serverSyncLogEmpty", in: list))
            #expect(empty.isHidden && !list.table.isHidden)
            list.update([])
            list.layoutIfNeeded()
            #expect(!empty.isHidden && list.table.isHidden)
            let words = empty.subviews.compactMap { ($0 as? UILabel)?.text }
            #expect(words == ["No synchronization log", "What is sent to the server and what it answers will appear here."])
            snapshot(list, "log-empty-\(rtl ? "rtl" : "ltr")")
        }
    }

    /// Needs attention: each kind with its words and actions (the confirming action trailing, as in a dialog), every
    /// control inside the screen at the device's widths and directions, each action reaching its own handler; then the
    /// empty screen.
    @Test(arguments: [false, true])
    func needsAttentionShowsEachItemWithItsActions(rtl: Bool) async throws {
        let items: [ServerAttentionItem] = [
            .init(kind: .staleSubscription(feedURL: "https://example.test/feed.xml", title: "A podcast with a long title that needs two lines on a phone"),
                  ids: ["s-1"], createdAt: 4),
            .init(kind: .refusedURL(url: "https://example.test/other.xml", podcastTitle: "Pea", ownerTitle: "Queue"), ids: ["u-1"], createdAt: 3),
            .init(kind: .refusedChanges(count: 2), ids: ["x-1", "x-2"], createdAt: 2),
            .init(kind: .incompleteRecovery(problems: 3), ids: ["r-1"], createdAt: 1),
            .init(kind: .refusedListening(episodeTitle: "An episode whose listening could not be synchronized"), ids: ["l-1"], createdAt: 0),
            .init(kind: .refusedTooLarge(podcastTitle: "Pea"), ids: ["d-1"], createdAt: 0),
            .init(kind: .refusedQueueAdd(episodeTitle: "An episode added to the queue"), ids: ["q-1"], createdAt: 0),
        ]
        let words: [String: (String, String)] = [
            "s-1": ("A podcast with a long title that needs two lines on a phone",
                    "The subscription was not completed because this podcast was removed on another device."),
            "u-1": ("Pea", "The feed URL was not changed: https://example.test/other.xml belongs to Queue."),
            "rejected": ("Some changes were refused by the server", "2 changes were not synchronized. The synchronization log lists them."),
            "r-1": ("Some changes could not be restored",
                    "After the server was restored from a backup, 3 changes could not be restored. The synchronization log lists them."),
            "l-1": ("An episode whose listening could not be synchronized",
                    "Listening on an episode can't be synchronized: its feed data is too large for the server."),
            "d-1": ("Pea", "A change to this podcast is too large for the server. It is kept on this device; later changes to this podcast wait behind it."),
            "q-1": ("An episode added to the queue", "Adding an episode to the queue can't be synchronized: its feed data is too large for the server."),
        ]
        try await withViewTestWindow { host, window in
            let list = ServerAttentionView()
            if rtl { list.traitOverrides.layoutDirection = .rightToLeft }
            host.view.addSubview(list)
            defer { list.removeFromSuperview() }
            var subscribed: [String] = [], logs = 0, dismissed: [[String]] = [], retried: [[String]] = [], kept: [[String]] = []
            list.onSubscribeAgain = { subscribed.append($0) }
            list.onShowLog = { logs += 1 }
            list.onDismiss = { dismissed.append($0.ids) }
            list.onTryAgain = { retried.append($0.ids) }
            list.onKeepOnDevice = { kept.append($0.ids) }
            list.update(items)
            let portrait = min(window.bounds.width, window.bounds.height), landscape = max(window.bounds.width, window.bounds.height)
            for width in [portrait, landscape] {
                list.frame.size = CGSize(width: width, height: list.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
                list.setNeedsLayout(); list.layoutIfNeeded()
                var previous: CGFloat = -1
                for item in items {
                    let id = item.identifier
                    let text: UIView = try #require(find("ntp_server_attention_item-\(id)", in: list))
                    #expect(text.isAccessibilityElement && text.accessibilityLabel == words[id]?.0 && text.accessibilityValue == words[id]?.1, "\(id)")
                    let frame = text.convert(text.bounds, to: list)
                    #expect(frame.minY >= previous, "\(id) in order, below the previous item's actions")
                    let texts = text.subviews.compactMap { $0 as? UILabel }
                    #expect(texts.map(\.text) == [words[id]?.0, words[id]?.1], "\(id) shows its words")
                    for label in texts {
                        let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
                        #expect(needed <= label.bounds.height + 0.5, "\(label.text ?? "") clipped")
                        #expect(label.textAlignment == .natural, "aligned as the page's rows")
                    }
                    let inset: CGFloat = width >= 600 ? 24 : 16
                    #expect(frame.minX >= inset - 0.5 && frame.maxX <= width - inset + 0.5 && frame.maxY <= list.bounds.height + 0.5)
                    // What waits on this device is never dismissed: "Keep only on this device" (or the log) takes Dismiss's place.
                    let leadingID = switch item.kind {
                    case .refusedListening, .refusedQueueAdd: "serverAttentionKeep-\(id)"
                    case .refusedTooLarge: "serverAttentionLog-\(id)"
                    default: "serverAttentionDismiss-\(id)"
                    }
                    let dismiss: UIButton = try #require(find(leadingID, in: list))
                    if item.waits { #expect(find("serverAttentionDismiss-\(id)", in: list, as: UIButton.self) == nil) }
                    let primaryID: String? = switch item.kind {
                    case .staleSubscription: "serverAttentionSubscribe-\(id)"
                    case .refusedChanges, .incompleteRecovery: "serverAttentionLog-\(id)"
                    case .refusedListening, .refusedQueueAdd, .refusedTooLarge: "serverAttentionRetry-\(id)"
                    case .refusedURL: nil
                    }
                    #expect(find("serverAttentionSubscribe-\(id)", in: list, as: UIButton.self) == nil || primaryID?.hasPrefix("serverAttentionSubscribe") == true)
                    #expect(find("serverAttentionLog-\(id)", in: list, as: UIButton.self) == nil || primaryID?.hasPrefix("serverAttentionLog") == true
                            || leadingID.hasPrefix("serverAttentionLog"))
                    // Inside the screen's width and the list (which scrolls), below the item's words.
                    let dismissFrame = dismiss.convert(dismiss.bounds, to: list)
                    #expect(list.bounds.contains(dismissFrame) && dismissFrame.maxX <= width - inset + 0.5 && dismissFrame.minX >= inset - 0.5)
                    #expect(dismissFrame.height >= 48 && dismissFrame.minY >= frame.maxY)
                    previous = dismissFrame.maxY
                    if let primaryID {
                        let primary: UIButton = try #require(find(primaryID, in: list))
                        let primaryFrame = primary.convert(primary.bounds, to: list)
                        #expect(list.bounds.contains(primaryFrame) && primaryFrame.maxX <= width - inset + 0.5 && primaryFrame.minX >= inset - 0.5)
                        #expect(primaryFrame.height >= 48 && abs(primaryFrame.minY - dismissFrame.minY) < 0.5, "\(id): side by side")
                        #expect(rtl ? primaryFrame.maxX <= dismissFrame.minX : primaryFrame.minX >= dismissFrame.maxX, "\(id): the action trails")
                    }
                }
                if width == portrait { snapshot(list, "attention-\(rtl ? "rtl" : "ltr")") }
            }
            for id in ["serverAttentionSubscribe-s-1", "serverAttentionLog-rejected", "serverAttentionLog-r-1",
                       "serverAttentionDismiss-u-1", "serverAttentionDismiss-rejected", "serverAttentionRetry-l-1", "serverAttentionKeep-l-1",
                       "serverAttentionLog-d-1", "serverAttentionRetry-d-1", "serverAttentionRetry-q-1", "serverAttentionKeep-q-1"] {
                try #require(find(id, in: list, as: UIButton.self)).sendActions(for: .touchUpInside)
            }
            #expect(subscribed == ["https://example.test/feed.xml"] && logs == 3 && dismissed == [["u-1"], ["x-1", "x-2"]])
            #expect(retried == [["l-1"], ["d-1"], ["q-1"]] && kept == [["l-1"], ["q-1"]])
            let keep = try #require(find("serverAttentionKeep-l-1", in: list, as: UIButton.self))
            #expect(keep.configuration?.title == "Keep only on this device")
            #expect(find("serverAttentionRetry-l-1", in: list, as: UIButton.self)?.configuration?.title == "Try again")
            list.update([])
            list.frame.size = CGSize(width: portrait, height: 600)
            list.layoutIfNeeded()
            let empty: UILabel = try #require(find("serverAttentionEmpty", in: list))
            #expect(!empty.isHidden && empty.text == "Nothing needs attention" && find("serverAttentionDismiss-s-1", in: list, as: UIButton.self) == nil)
        }
    }
}

/// Synchronization passwords kept in memory for the test.
private final class ViewTestCredentials: SynchronizationCredentialStore, Sendable {
    private let storage = Mutex<[UUID: String]>([:])
    func insert(_ password: String, id: UUID) throws { storage.withLock { $0[id] = password } }
    func password(id: UUID) throws -> String {
        try storage.withLock { guard let value = $0[id] else { throw SynchronizationCredentialError.missing }; return value }
    }
    func remove(id: UUID) throws { storage.withLock { $0[id] = nil } }
}

/// Synchronization notifications that go nowhere.
@MainActor private final class ViewTestPublisher: SynchronizationNotificationPublishing {
    func isAuthorized() async -> Bool { false }
    func publishError(title: String, body: String) async throws {}
    func clearErrors() async {}
}

import Foundation
import Testing
@testable import NotTennaPodCore

/// The Synchronization page's rows, subtitle and status row for every state of PROTOCOL §15.5.
struct ServerSynchronizationPageTests {
    private func entry(_ id: String, _ state: LibraryRegistry.ServerLibrary.State, user: String = "alice") -> LibraryRegistry.ServerLibrary {
        .init(id: id, serverURL: "https://sync.example.test", serverID: "s", accountID: ContractIdentity.randomUUID(),
              username: user, state: state, createdAt: 0)
    }
    private let a = ContractIdentity.randomUUID(), b = ContractIdentity.randomUUID()

    private func registry(_ libraries: [LibraryRegistry.ServerLibrary], active: LibraryReference = .standalone) -> LibraryRegistry {
        var registry = LibraryRegistry(); registry.libraries = libraries; registry.active = active; return registry
    }

    @Test func withoutAServerLibraryThePageIsTodaysPlusKeptLibraries() {
        let none = ServerSynchronizationPage.make(registry: LibraryRegistry(), open: .standalone, otherProvider: false, summaries: [:])
        #expect(none.mode == .none && none.rows.isEmpty && none.subtitle == nil && none.showsOrdinaryRows)
        let kept = ServerSynchronizationPage.make(registry: registry([entry(a, .inactive), entry(b, .inactive, user: "bob")]),
                                                  open: .standalone, otherProvider: false,
                                                  summaries: [a: .init(entry: entry(a, .inactive), unsentChanges: 3)])
        #expect(kept.rows == [.keptLibraries] && kept.keptLibraries.map(\.entry.id) == [a, b])
        #expect(kept.keptLibraries.first?.unsentChanges == 3)
        // One provider at a time: with gpodder.net or Nextcloud chosen, nothing of the server shows.
        let gpodder = ServerSynchronizationPage.make(registry: registry([entry(a, .inactive), entry(b, .attaching)]),
                                                     open: .standalone, otherProvider: true, summaries: [:])
        #expect(gpodder.mode == .none && gpodder.rows.isEmpty)
    }

    /// A recovery that cannot go on until space is freed says so (what unblocks it), while the subtitle still says it is
    /// restoring; a repair waiting for a connection says that, not Wi-Fi.
    @Test func whatOnlyFreeSpaceUnblocksComesFirst() {
        let open = entry(a, .active)
        var signals = ServerSynchronizationSignals(recovery: .running)
        signals.insufficientSpace = true
        let page = ServerSynchronizationPage.make(registry: registry([open], active: .server(a)), open: .server(a), otherProvider: false,
                                                  summaries: [a: .init(entry: open, hasUsableToken: true)], exchange: signals)
        #expect(page.condition == .waitingForSpace && page.subtitle == .restoring)
        var offline = ServerSynchronizationSignals()
        offline.fullSynchronizationWaits = .offline
        let waiting = ServerSynchronizationPage.make(registry: registry([open], active: .server(a)), open: .server(a), otherProvider: false,
                                                     summaries: [a: .init(entry: open, hasUsableToken: true)], exchange: offline)
        #expect(waiting.condition == .fullSynchronizationWaitsForNetwork(.offline))
    }

    @Test func attachingReadyAndLoggedOutExplainThemselves() {
        let attaching = ServerSynchronizationPage.make(registry: registry([entry(a, .attaching), entry(b, .inactive)]), open: .standalone,
                                                       otherProvider: false, summaries: [:], attachProgress: [a: 12])
        #expect(attaching.mode == .attaching && attaching.condition == .attaching(items: 12))
        #expect(attaching.rows == [.provider, .status, .logout] && attaching.subtitle == .preparing && !attaching.showsOrdinaryRows)
        let ready = ServerSynchronizationPage.make(registry: registry([entry(a, .ready)]), open: .standalone, otherProvider: false, summaries: [:])
        #expect(ready.mode == .ready && ready.condition == .ready && ready.subtitle == .ready && ready.rows == [.provider, .status, .logout])
        let loggedOut = ServerSynchronizationPage.make(registry: registry([entry(a, .inactive)], active: .server(a)), open: .server(a),
                                                       otherProvider: false, summaries: [:])
        #expect(loggedOut.mode == .none && loggedOut.condition == .loggedOut && loggedOut.subtitle == nil)
        #expect(loggedOut.rows == [.status, .keptLibraries])
    }

    /// A switch or Keep waiting for playback, a resumption after an interruption included, offers "Stop playback
    /// and continue" right below its status row, a Keep that stalled (storage) too, with its explanation; a wait for
    /// Cast, an attachment and server mode do not.
    @Test func aSwitchOrKeepWaitingForPlaybackOffersToStopIt() {
        var keeping = entry(a, .keeping)
        keeping.operation = ContractIdentity.randomUUID()
        for hold in [LibraryPlaybackHold.playing, .resumingAfterInterruption] {
            func page(_ libraries: [LibraryRegistry.ServerLibrary], open: LibraryReference, cast: Bool = false,
                      failure: KeepFailure? = nil) -> ServerSynchronizationPage {
                .make(registry: registry(libraries, active: open), open: open, otherProvider: false, summaries: [:],
                      castBlocks: cast, keepFailure: failure, playbackHold: hold)
            }
            let ready = page([entry(a, .ready)], open: .standalone)
            #expect(ready.condition == .ready && ready.playbackHold == hold)
            #expect(ready.rows == [.provider, .status, .stopPlayback, .logout])
            let loggedOut = page([entry(a, .inactive)], open: .server(a))
            #expect(loggedOut.condition == .loggedOut && loggedOut.rows == [.status, .stopPlayback, .keptLibraries])
            let waitingKeep = page([keeping], open: .server(a))
            #expect(waitingKeep.condition == .keeping && waitingKeep.rows == [.status, .stopPlayback])
            for failure in [KeepFailure.storage, .other, .interrupted] {
                let stalled = page([keeping], open: .server(a), failure: failure)
                #expect(stalled.condition == .keepStalled(failure == .interrupted ? nil : failure), "\(failure)")
                #expect(stalled.playbackHold == hold && stalled.rows == [.status, .stopPlayback], "\(failure)")
            }
            for other in [page([entry(a, .ready)], open: .standalone, cast: true), page([entry(a, .inactive)], open: .server(a), cast: true),
                          page([keeping], open: .server(a), cast: true),
                          page([entry(a, .attaching)], open: .standalone), page([entry(a, .active)], open: .server(a))] {
                #expect(other.playbackHold == nil && !other.rows.contains(.stopPlayback), "\(String(describing: other.condition))")
            }
        }
        let idle = ServerSynchronizationPage.make(registry: registry([entry(a, .ready)]), open: .standalone, otherProvider: false, summaries: [:])
        #expect(idle.playbackHold == nil && idle.rows == [.provider, .status, .logout])
    }

    /// PROTOCOL §6.11: an account without this library's history explains itself even when the token is gone
    /// (signing in again cannot help), with "Start over with the server's library"; starting over prepares the
    /// server's new library while this one, now inactive, stays open, then waits for the switch; a recovery explains
    /// itself while it runs and, finished incomplete, says so.
    @Test func lineageUnknownStartOverAndRecoveryExplainThemselves() {
        func page(_ libraries: [LibraryRegistry.ServerLibrary], open: LibraryReference, token: Bool = true,
                  signals: ServerSynchronizationSignals = .init()) -> ServerSynchronizationPage {
            .make(registry: registry(libraries, active: open), open: open, otherProvider: false,
                  summaries: Dictionary(uniqueKeysWithValues: libraries.map { ($0.id, ServerLibrarySummary(entry: $0, hasUsableToken: token)) }),
                  attachProgress: [b: 5], exchange: signals)
        }
        let unknown = page([entry(a, .active)], open: .server(a), token: false, signals: .init(pause: .lineageUnknown))
        #expect(unknown.condition == .lineageUnknown && unknown.subtitle == .paused)
        #expect(unknown.rows == [.provider, .status, .startOver, .changeLogin, .synchronize, .fullSynchronization, .log, .logout])
        let attaching = page([entry(a, .inactive), entry(b, .attaching)], open: .server(a))
        #expect(attaching.mode == .attaching && attaching.condition == .attaching(items: 5) && attaching.library?.entry.id == b)
        #expect(attaching.rows == [.provider, .status, .logout])
        let ready = page([entry(a, .inactive), entry(b, .ready)], open: .server(a))
        #expect(ready.mode == .ready && ready.condition == .ready && ready.library?.entry.id == b)
        let restoring = page([entry(a, .active)], open: .server(a), signals: .init(recovery: .running))
        #expect(restoring.condition == .recovering && restoring.subtitle == .restoring)
        let signIn = page([entry(a, .active)], open: .server(a), token: false, signals: .init(recovery: .running))
        #expect(signIn.condition == .needsSignIn, "a recovery waits for the sign-in first")
        let waiting = page([entry(a, .active)], open: .server(a), signals: .init(recovery: .waiting))
        #expect(waiting.condition == .recoveryWaiting && waiting.rows.contains(.status))
        let incomplete = page([entry(a, .active)], open: .server(a), signals: .init(recovery: .incomplete))
        #expect(incomplete.condition == .recoveryIncomplete && incomplete.rows.contains(.status))
    }

    @Test func serverModeRowsAndEveryStatus() {
        let open = registry([entry(a, .active)], active: .server(a))
        let status = ServerLibraryStatus(lastSynchronizedAt: 1_000, successful: true)
        func page(token: Bool = true, _ exchange: ServerSynchronizationSignals = .init(), unsent: Int = 0) -> ServerSynchronizationPage {
            .make(registry: open, open: .server(a), otherProvider: false,
                  summaries: [a: .init(entry: entry(a, .active), unsentChanges: unsent, lastSynchronization: status, hasUsableToken: token)],
                  exchange: exchange)
        }
        let normal = page(unsent: 4)
        #expect(normal.mode == .server && normal.condition == nil && normal.subtitle == .report(status) && normal.unsentChanges == 4)
        #expect(normal.rows == [.provider, .changeLogin, .synchronize, .fullSynchronization, .log, .logout])
        let signIn = page(token: false)
        #expect(signIn.condition == .needsSignIn && signIn.subtitle == .signInAgain)
        #expect(signIn.rows == [.provider, .status, .changeLogin, .synchronize, .fullSynchronization, .log, .logout])
        #expect(page(.init(pause: .serverNeedsUpdate)).condition == .serverNeedsUpdate)
        #expect(page(.init(pause: .appNeedsUpdate)).subtitle == .paused)
        let lineage = page(.init(pause: .lineageUnknown))
        #expect(lineage.condition == .lineageUnknown && lineage.subtitle == .paused)
        #expect(lineage.rows == [.provider, .status, .startOver, .changeLogin, .synchronize, .fullSynchronization, .log, .logout])
        // The recovery's pauses say they are paused and why, never a stale "Successful" (PROTOCOL §15).
        for (pause, condition) in [(ServerSynchronizationSignals.Pause.serverRestored, ServerSynchronizationPage.Condition.serverRestored),
                                   (.sharedInstallation, .sharedInstallation), (.serverLostChanges, .serverLostChanges)] {
            let paused = page(.init(pause: pause))
            #expect(paused.condition == condition && paused.subtitle == .paused, "\(pause)")
            #expect(paused.rows == [.provider, .status, .changeLogin, .synchronize, .fullSynchronization, .log, .logout], "\(pause)")
            #expect(page(token: false, .init(pause: pause)).condition == .needsSignIn, "signing in comes first")
            #expect(page(.init(pause: pause, recovery: .running)).condition == .recovering, "a running recovery explains itself")
        }
        #expect(page(.init(recovery: .running)).subtitle == .restoring)
        let incomplete = page(.init(recovery: .incomplete))
        #expect(incomplete.condition == .recoveryIncomplete && incomplete.subtitle == .report(status) && incomplete.rows.contains(.status))
        let unreachable = page(.init(unreachable: true))
        #expect(unreachable.condition == .unreachable && unreachable.subtitle == .waitingForServer && !unreachable.rows.contains(.status))
        let attention = page(.init(attentionItems: 2))
        #expect(attention.rows == [.provider, .changeLogin, .synchronize, .fullSynchronization, .log, .attention, .logout])
        // Large changes waiting for the app to leave the foreground say so in the status row.
        let waiting = page(.init(waitingForBackground: true))
        #expect(waiting.condition == .waitingForBackground && waiting.subtitle == .report(status))
        #expect(waiting.rows == [.provider, .status, .changeLogin, .synchronize, .fullSynchronization, .log, .logout])
        #expect(page(.init(pause: .serverRestored, waitingForBackground: true)).condition == .serverRestored, "a pause explains itself first")
        // A change too large for the server, or refused by it, pauses pushing alone (PROTOCOL §6.13): the page says so, with
        // Needs attention when it lists something, and signing in or a running recovery still explains itself first.
        for (pause, condition) in [(ServerSynchronizationSignals.Pause.changeTooLarge, ServerSynchronizationPage.Condition.changeTooLarge),
                                   (.changeRefused, .changeRefused)] {
            let paused = page(.init(pause: pause, attentionItems: 1))
            #expect(paused.condition == condition && paused.subtitle == .paused, "\(pause)")
            #expect(paused.rows == [.provider, .status, .changeLogin, .synchronize, .fullSynchronization, .log, .attention, .logout], "\(pause)")
            #expect(page(token: false, .init(pause: pause)).condition == .needsSignIn)
            #expect(page(.init(pause: pause, recovery: .running)).condition == .recovering)
            #expect(page(.init(pause: pause, unreachable: true)).condition == condition, "the pause before what the last exchange found")
        }
    }

    /// The exchange's pauses reach the page: a change too large and a change refused, each its own status.
    @Test func refusedChangesReachThePage() {
        #expect(ServerPauseReason.changeTooLarge.pullsContinue && ServerPauseReason.changeRefused.pullsContinue, "pulls go on")
        #expect(ServerPauseReason.changeTooLarge.clearedByRetry && ServerPauseReason.changeRefused.clearedByRetry)
        #expect(!ServerPauseReason.versionUnsupported.clearedByRetry && !ServerPauseReason.signIn.clearedByRetry)
    }

    /// No network, or only mobile data sync may not use: the status row and the subtitle say so instead of the last
    /// "Successful (…)", before what the last exchange found (an unreachable server, waiting changes), and after a pause
    /// or a running recovery, which explain themselves first.
    @Test func noPermittedNetworkSaysWhyInsteadOfTheLastResult() {
        let open = registry([entry(a, .active)], active: .server(a))
        let status = ServerLibraryStatus(lastSynchronizedAt: 1_000, successful: true)
        func page(token: Bool = true, _ exchange: ServerSynchronizationSignals) -> ServerSynchronizationPage {
            .make(registry: open, open: .server(a), otherProvider: false,
                  summaries: [a: .init(entry: entry(a, .active), unsentChanges: 2, lastSynchronization: status, hasUsableToken: token)],
                  exchange: exchange)
        }
        for wait in [ServerNetworkWait.offline, .mobileDataOff] {
            let waiting = page(.init(networkWait: wait))
            #expect(waiting.condition == .waitingForNetwork(wait) && waiting.subtitle == .waitingForNetwork(wait), "\(wait)")
            #expect(waiting.rows == [.provider, .status, .changeLogin, .synchronize, .fullSynchronization, .log, .logout], "\(wait)")
            #expect(waiting.unsentChanges == 2, "changes stay counted")
            #expect(page(.init(unreachable: true, waitingForBackground: true, networkWait: wait)).condition == .waitingForNetwork(wait))
            #expect(page(.init(recovery: .incomplete, networkWait: wait)).condition == .waitingForNetwork(wait))
            #expect(page(token: false, .init(networkWait: wait)).condition == .needsSignIn, "signing in comes first")
            #expect(page(.init(pause: .serverRestored, networkWait: wait)).condition == .serverRestored, "a pause explains itself first")
            #expect(page(.init(pause: .appNeedsUpdate, networkWait: wait)).condition == .appNeedsUpdate)
            #expect(page(.init(recovery: .running, networkWait: wait)).condition == .recovering)
        }
        #expect(page(.init()).subtitle == .report(status), "the network back: the last result again")
    }

    @Test func settingsSearchFindsServerRowsOnlyWhileThePageShowsThem() {
        let base = SettingsSearch.visibleIndex(gpodderSelected: false)
        #expect(SettingsSearch.visibleIndex(gpodderSelected: false, server: []) == base)
        #expect(!SettingsSearch.index.contains { $0.key.hasPrefix("ntp_server_") }, "Android's index is unchanged")
        let server = SettingsSearch.visibleIndex(gpodderSelected: false, server: .serverMode).map(\.key)
        let kept = SettingsSearch.visibleIndex(gpodderSelected: false, server: .keptLibraries).map(\.key)
        #expect(server.filter { $0.hasPrefix("ntp_server_") } == ["ntp_server_setlogin_information", "ntp_server_log"])
        #expect(kept.filter { $0.hasPrefix("ntp_server_") } == ["ntp_server_libraries"])
        // After the Synchronization page's own rows, before the next page's.
        let logout = server.firstIndex(of: "pref_synchronization_logout")!
        #expect(server[logout + 1] == "ntp_server_setlogin_information")
        // "Needs attention" only while it has items, in its place on the page (after the log).
        let attention = SettingsSearch.visibleIndex(gpodderSelected: false, server: [.serverMode, .attention]).map(\.key)
        #expect(attention.filter { $0.hasPrefix("ntp_server_") } == ["ntp_server_setlogin_information", "ntp_server_log", "ntp_server_attention"])
        #expect(!SettingsSearch.visibleIndex(gpodderSelected: false, server: [.keptLibraries, .attention]).contains { $0.key == "ntp_server_attention" },
                "never outside server mode")
        let items = SettingsSearch.resolve(SettingsSearch.visibleIndex(gpodderSelected: false, server: [.serverMode, .attention]), text: { "[\($0)]" })
        let found = items.first { $0.entry.key == "ntp_server_attention" }
        #expect(found?.title == "[ntp_server_attention_title]" && found?.summary == "[ntp_server_attention_sum]")
        // The log's and Needs attention's results open their screens; the other rows are highlighted on the page.
        #expect(SettingsSearch.serverScreen(forKey: "ntp_server_log") == .log)
        #expect(SettingsSearch.serverScreen(forKey: "ntp_server_attention") == .attention)
        #expect(SettingsSearch.serverScreen(forKey: "ntp_server_setlogin_information") == nil)
        #expect(SettingsSearch.serverScreen(forKey: "pref_synchronization_sync") == nil)
    }

    /// "Start over" (PROTOCOL §6.11 `lineage_unknown`) is found only while the page offers it, in its place on the page (before
    /// "Change login information"); its result highlights the row.
    @Test func settingsSearchFindsStartOverOnlyWhileThePageOffersIt() {
        let open = registry([entry(a, .active)], active: .server(a))
        func keys(_ exchange: ServerSynchronizationSignals) -> [String] {
            let page = ServerSynchronizationPage.make(registry: open, open: .server(a), otherProvider: false,
                                                      summaries: [a: .init(entry: entry(a, .active), hasUsableToken: true)], exchange: exchange)
            return SettingsSearch.visibleIndex(gpodderSelected: false, server: SettingsSearch.ServerRows(page: page)).map(\.key)
        }
        let unknown = keys(.init(pause: .lineageUnknown))
        #expect(unknown.filter { $0.hasPrefix("ntp_server_") } == ["ntp_server_start_over", "ntp_server_setlogin_information", "ntp_server_log"])
        for signals in [ServerSynchronizationSignals(), .init(pause: .serverRestored), .init(recovery: .incomplete)] {
            #expect(!keys(signals).contains("ntp_server_start_over"), "\(signals)")
        }
        #expect(!SettingsSearch.visibleIndex(gpodderSelected: false, server: [.keptLibraries, .startOver]).contains { $0.key == "ntp_server_start_over" },
                "never outside server mode")
        let found = SettingsSearch.resolve(SettingsSearch.visibleIndex(gpodderSelected: false, server: [.serverMode, .startOver]), text: { "[\($0)]" })
            .first { $0.entry.key == "ntp_server_start_over" }
        #expect(found?.title == "[ntp_server_start_over_title]" && found?.summary == "[ntp_server_start_over_sum]")
        #expect(SettingsSearch.serverScreen(forKey: "ntp_server_start_over") == nil)
    }

    /// While a server library is being prepared or waits to be switched to, the page shows its provider, status and
    /// Logout only: settings search finds neither "Synchronize now" nor "Force full synchronization" then. In
    /// server mode, and without a server library (no provider, gpodder.net or Nextcloud), the index is what it was.
    @Test func settingsSearchFindsOnlyThePagesOwnActions() {
        let sync: Set<String> = ["pref_synchronization_sync", "pref_synchronization_force_full_sync"]
        func keys(_ page: ServerSynchronizationPage, gpodder: Bool = false) -> Set<String> {
            Set(SettingsSearch.visibleIndex(gpodderSelected: gpodder, server: SettingsSearch.ServerRows(page: page)).map(\.key))
        }
        let attaching = ServerSynchronizationPage.make(registry: registry([entry(a, .attaching)]), open: .standalone, otherProvider: false,
                                                       summaries: [:])
        let ready = ServerSynchronizationPage.make(registry: registry([entry(a, .ready)]), open: .standalone, otherProvider: false, summaries: [:])
        for page in [attaching, ready] {
            #expect(!page.rows.contains(.synchronize) && !page.rows.contains(.fullSynchronization))
            #expect(keys(page).isDisjoint(with: sync), "\(page.mode)")
            #expect(keys(page).isSuperset(of: ["preference_synchronization_description", "pref_synchronization_logout"]), "\(page.mode)")
        }
        let server = ServerSynchronizationPage.make(registry: registry([entry(a, .active)], active: .server(a)), open: .server(a),
                                                    otherProvider: false, summaries: [a: .init(entry: entry(a, .active), hasUsableToken: true)])
        #expect(keys(server).isSuperset(of: sync) && keys(server).contains("ntp_server_log"))
        let standalone = ServerSynchronizationPage.make(registry: LibraryRegistry(), open: .standalone, otherProvider: false, summaries: [:])
        let otherProvider = ServerSynchronizationPage.make(registry: registry([entry(a, .attaching)]), open: .standalone, otherProvider: true,
                                                           summaries: [:])
        #expect(keys(standalone) == Set(SettingsSearch.visibleIndex(gpodderSelected: false).map(\.key)))
        #expect(keys(otherProvider, gpodder: true) == Set(SettingsSearch.visibleIndex(gpodderSelected: true).map(\.key)))
    }

    /// PROTOCOL §15.5 and "Wording": a previous library's row is found while the page lists it, titled as the page titles
    /// it, opening the page at that row; without previous libraries nothing is added.
    @Test func settingsSearchFindsPreviousLibraryRowsWhileThePageListsThem() {
        let base = SettingsSearch.visibleIndex(gpodderSelected: false)
        #expect(SettingsSearch.visibleIndex(gpodderSelected: false, previousLibraries: []) == base)
        let libraries = [(id: "p-1", label: "Library from before Oct 7, 2026"), (id: "p-2", label: "Library from before Oct 8, 2026")]
        let index = SettingsSearch.visibleIndex(gpodderSelected: false, server: .keptLibraries, previousLibraries: libraries)
        #expect(index.map(\.key).filter { $0.hasPrefix("ntp_server_") }
                == ["ntp_server_libraries", "ntp_server_previous_library-p-1", "ntp_server_previous_library-p-2"])
        let items = SettingsSearch.resolve(index, text: { "[\($0)]" }).filter { $0.entry.key.hasPrefix("ntp_server_previous_library-") }
        #expect(items.map(\.title) == ["Library from before Oct 7, 2026", "Library from before Oct 8, 2026"])
        #expect(items.allSatisfy { $0.entry.screen == .synchronization && $0.info.contains("Library from before") && $0.displaySummary == nil })
        // In server mode the page lists them after its own rows too.
        let server = SettingsSearch.visibleIndex(gpodderSelected: false, server: .serverMode, previousLibraries: [libraries[0]]).map(\.key)
        let log = server.firstIndex(of: "ntp_server_log")!
        #expect(server[log + 1] == "ntp_server_previous_library-p-1")
    }
}

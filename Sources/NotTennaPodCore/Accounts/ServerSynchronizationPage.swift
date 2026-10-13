import Foundation

/// A server library kept on this device, as the Synchronization page shows it (PROTOCOL §15.5).
public struct ServerLibrarySummary: Equatable, Sendable {
    public var entry: LibraryRegistry.ServerLibrary
    /// Facts not yet acknowledged by the server: unreceipted outbox entries and drafts.
    public var unsentChanges: Int
    public var lastSynchronization: ServerLibraryStatus?
    /// The current installation has a token the server has not refused.
    public var hasUsableToken: Bool

    public init(entry: LibraryRegistry.ServerLibrary, unsentChanges: Int = 0, lastSynchronization: ServerLibraryStatus? = nil,
                hasUsableToken: Bool = false) {
        self.entry = entry; self.unsentChanges = unsentChanges
        self.lastSynchronization = lastSynchronization; self.hasUsableToken = hasUsableToken
    }

    public var address: ServerAddress? { ServerAddress(stored: entry.serverURL) }
}

/// What the exchange tells the page about the open server library. Without an exchange there is no
/// exchange: everything here stays at its default.
public struct ServerSynchronizationSignals: Equatable, Sendable {
    public enum Pause: Equatable, Sendable {
        case serverNeedsUpdate, appNeedsUpdate, lineageUnknown
        /// Pauses the recovery resolves (recovery, a new installation); until then sync says it is
        /// paused and why (PROTOCOL §15.5).
        /// `lineage_mismatch`: the server was restored from a backup.
        case serverRestored
        /// `installation_conflict` or `installation_superseded`: another copy of this library uses its login.
        case sharedInstallation
        /// `dependency_missing` naming a change this library holds: the server lost changes it had accepted.
        case serverLostChanges
    }
    public enum Recovery: Equatable, Sendable {
        case running
        /// Caught up; some changes wait for another device to restore what they depend on.
        case waiting
        case incomplete
    }
    public var pause: Pause?
    public var recovery: Recovery?
    /// The last request found no server (network, DNS, refused).
    public var unreachable = false
    /// Items of the "Needs attention" list.
    public var attentionItems = 0
    /// Large changes from the server wait for the app to leave the foreground.
    public var waitingForBackground = false
    public init(pause: Pause? = nil, recovery: Recovery? = nil, unreachable: Bool = false, attentionItems: Int = 0,
                waitingForBackground: Bool = false) {
        self.pause = pause; self.recovery = recovery; self.unreachable = unreachable; self.attentionItems = attentionItems
        self.waitingForBackground = waitingForBackground
    }
}

/// The Synchronization page's server-mode state (PROTOCOL §15.5): which rows show, the toolbar subtitle and the status row.
/// A pure function of the registry, the library the graph opened and what the account service and later stages
/// know, so every state can be checked without a server.
public struct ServerSynchronizationPage: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// No NotTennaPod server: the page's ordinary rows (gpodder.net, Nextcloud or no provider).
        case none
        /// A first attachment is being prepared.
        case attaching
        /// The server library is ready and waits for the activation rule (a pause or stop).
        case ready
        /// The open library is the server library.
        case server
    }

    /// Something the status row explains (PROTOCOL §15.5 status table); nil: nothing to explain.
    public enum Condition: Equatable, Sendable {
        case attaching(items: Int)
        case ready
        /// Ready, while a Cast session is connecting or has media loaded (PROTOCOL §15.4).
        case readyCast
        case loggedOut
        /// Logged out, switch pending, while a Cast session is connecting or has media loaded.
        case loggedOutCast
        /// Logged out keeping this library (PROTOCOL §15.4): the Keep waits for the activation rule.
        case keeping
        /// The same, while a Cast session is connecting or has media loaded.
        case keepingCast
        /// Keeping this library has not finished (a failure in phases 2–6), with its reason when known.
        case keepStalled(KeepFailure?)
        case recovering
        /// A recovery's changes wait for another device to restore what they depend on.
        case recoveryWaiting
        case recoveryIncomplete
        case needsSignIn
        case serverNeedsUpdate
        case appNeedsUpdate
        case lineageUnknown
        /// The recovery's pauses (PROTOCOL §15.5 "Synchronization paused"), each with the cause it can honestly
        /// name.
        case serverRestored
        case sharedInstallation
        case serverLostChanges
        case unreachable
        /// Large changes from the server are applied when the app is in the background.
        case waitingForBackground
    }

    public enum Row: Equatable, Sendable {
        /// The provider row: "NotTennaPod server" with the app icon, not actionable.
        case provider
        case status
        case startOver
        case changeLogin
        case synchronize
        case fullSynchronization
        case log
        case attention
        case logout
        /// "Server libraries on this device", after the page's ordinary rows when no provider is chosen.
        case keptLibraries
        /// "Library from before %1$@": a library kept aside at logout (PROTOCOL §15.4), in any state.
        case previousLibrary(String)
        /// "Stop playback and continue", below the status row while a switch or a Keep waits for playback.
        case stopPlayback
    }

    /// The subtitle under the toolbar title: short and quiet (PROTOCOL §15).
    public enum Subtitle: Equatable, Sendable {
        case preparing, ready, restoring, signInAgain, paused, waitingForServer
        /// Today's "Successful (…)" or "Failed (…)".
        case report(ServerLibraryStatus)
    }

    public var mode: Mode
    public var condition: Condition?
    /// The server library the rows are about (attaching, ready or open).
    public var library: ServerLibrarySummary?
    /// Kept libraries offered under "Server libraries on this device" (no provider chosen only).
    public var keptLibraries: [ServerLibrarySummary]
    public var exchange: ServerSynchronizationSignals
    /// Libraries kept aside at logout, oldest first (PROTOCOL §15.4).
    public var previousLibraries: [LibraryRegistry.PreviousLibrary] = []
    /// While a Keep at logout has not finished, the provider choice does not open (PROTOCOL §15.5).
    public var providerChoiceBlocked = false
    /// The playback a waiting switch or Keep waits for (ready, logged out, keeping or a stalled Keep, not Cast), which
    /// the status row names and "Stop playback and continue" ends; nil when playback does not hold it.
    public var playbackHold: LibraryPlaybackHold?

    public init(mode: Mode, condition: Condition? = nil, library: ServerLibrarySummary? = nil,
                keptLibraries: [ServerLibrarySummary] = [], exchange: ServerSynchronizationSignals = .init(),
                previousLibraries: [LibraryRegistry.PreviousLibrary] = [], providerChoiceBlocked: Bool = false,
                playbackHold: LibraryPlaybackHold? = nil) {
        self.mode = mode; self.condition = condition; self.library = library
        self.keptLibraries = keptLibraries; self.exchange = exchange
        self.previousLibraries = previousLibraries; self.providerChoiceBlocked = providerChoiceBlocked
        self.playbackHold = playbackHold
    }

    /// The page for the registry and the library the current graph opened. `otherProvider` is a gpodder.net or
    /// Nextcloud account in the open library (one provider at a time: the server rows never mix with it).
    /// `playbackHold`: what of this device's playback holds a waiting switch or Keep (`LibraryActivationState`).
    public static func make(registry: LibraryRegistry, open: LibraryReference, otherProvider: Bool,
                            summaries: [String: ServerLibrarySummary], attachProgress: [String: Int] = [:],
                            exchange: ServerSynchronizationSignals = .init(), castBlocks: Bool = false,
                            keepFailure: KeepFailure? = nil, playbackHold: LibraryPlaybackHold? = nil) -> ServerSynchronizationPage {
        var page = makeState(registry: registry, open: open, otherProvider: otherProvider, summaries: summaries,
                             attachProgress: attachProgress, exchange: exchange, castBlocks: castBlocks, keepFailure: keepFailure)
        page.previousLibraries = registry.previous.filter { $0.state == .ready }.sorted { ($0.keptAt, $0.id) < ($1.keptAt, $1.id) }
        // Only a switch or Keep that waits for the activation rule waits for playback; Cast names its own wait. A
        // Keep that stalled keeps its explanation and, while playback holds its next attempt, the action too.
        switch page.condition {
        case .ready?, .loggedOut?, .keeping?, .keepStalled?: page.playbackHold = playbackHold
        default: page.playbackHold = nil
        }
        return page
    }

    private static func makeState(registry: LibraryRegistry, open: LibraryReference, otherProvider: Bool,
                                  summaries: [String: ServerLibrarySummary], attachProgress: [String: Int],
                                  exchange: ServerSynchronizationSignals, castBlocks: Bool,
                                  keepFailure: KeepFailure?) -> ServerSynchronizationPage {
        func summary(_ entry: LibraryRegistry.ServerLibrary) -> ServerLibrarySummary {
            var value = summaries[entry.id] ?? ServerLibrarySummary(entry: entry)
            value.entry = entry
            return value
        }
        let kept = registry.libraries.filter { $0.state == .inactive }.map(summary)
        if registry.keeping != nil {
            // Logged out, keeping this library (PROTOCOL §15.4): as "No provider", with the status row; the provider choice opens
            // only once the Keep has finished.
            let condition: Condition = keepFailure.map { .keepStalled($0 == .interrupted ? nil : $0) } ?? (castBlocks ? .keepingCast : .keeping)
            return ServerSynchronizationPage(mode: .none, condition: condition, keptLibraries: otherProvider ? [] : kept,
                                             exchange: exchange, providerChoiceBlocked: true)
        }
        if case .server(let id) = open, let entry = registry.library(id) {
            // Started over with the server's library (PROTOCOL §6.11 `lineage_unknown`): the new library is prepared, then waits
            // for the switch, while this one stays open.
            if entry.state == .inactive, !otherProvider, let next = registry.libraries.first(where: { $0.state == .attaching || $0.state == .ready }) {
                return next.state == .attaching
                    ? ServerSynchronizationPage(mode: .attaching, condition: .attaching(items: attachProgress[next.id] ?? 0), library: summary(next), exchange: exchange)
                    : ServerSynchronizationPage(mode: .ready, condition: castBlocks ? .readyCast : .ready, library: summary(next), exchange: exchange)
            }
            if entry.state == .inactive {
                // Logged out while playing: this device's library follows at the next pause or stop.
                return ServerSynchronizationPage(mode: .none, condition: castBlocks ? .loggedOutCast : .loggedOut,
                                                 keptLibraries: otherProvider ? [] : kept, exchange: exchange)
            }
            let library = summary(entry)
            // A server that no longer has this library's history explains itself first: signing in again cannot help.
            let condition: Condition? = if exchange.pause == .lineageUnknown { .lineageUnknown }
                else if !library.hasUsableToken { .needsSignIn }
                // A running recovery explains itself ("Restoring…"); otherwise the pause that waits for it does.
                else if exchange.recovery != .running, let stopped = exchange.pause?.stopped { stopped }
                else if exchange.pause == .serverNeedsUpdate { .serverNeedsUpdate }
                else if exchange.pause == .appNeedsUpdate { .appNeedsUpdate }
                else if exchange.recovery == .running { .recovering }
                else if exchange.recovery == .waiting { .recoveryWaiting }
                else if exchange.recovery == .incomplete { .recoveryIncomplete }
                else if exchange.unreachable { .unreachable }
                else if exchange.waitingForBackground { .waitingForBackground }
                else { nil }
            return ServerSynchronizationPage(mode: .server, condition: condition, library: library, exchange: exchange)
        }
        if !otherProvider {
            if let entry = registry.libraries.first(where: { $0.state == .attaching }) {
                return ServerSynchronizationPage(mode: .attaching, condition: .attaching(items: attachProgress[entry.id] ?? 0),
                                                 library: summary(entry), exchange: exchange)
            }
            if let entry = registry.libraries.first(where: { $0.state == .ready || $0.state == .active }) {
                return ServerSynchronizationPage(mode: .ready, condition: castBlocks ? .readyCast : .ready, library: summary(entry), exchange: exchange)
            }
        }
        return ServerSynchronizationPage(mode: .none, keptLibraries: otherProvider ? [] : kept, exchange: exchange)
    }

    /// The rows in order. With mode `.none` these are shown after the page's ordinary rows (and the status row
    /// below its provider row).
    public var rows: [Row] {
        let previous = previousLibraries.map { Row.previousLibrary($0.id) }
        let stop: [Row] = playbackHold == nil ? [] : [.stopPlayback]
        switch mode {
        case .none:
            return (condition == nil ? [] : [.status]) + stop + (keptLibraries.isEmpty ? [] : [.keptLibraries]) + previous
        case .attaching, .ready:
            return [.provider, .status] + stop + [.logout] + previous
        case .server:
            var rows: [Row] = [.provider]
            if condition != nil && condition != .unreachable { rows.append(.status) }
            if condition == .lineageUnknown { rows.append(.startOver) }
            rows += [.changeLogin, .synchronize, .fullSynchronization, .log]
            if exchange.attentionItems > 0 { rows.append(.attention) }
            rows.append(.logout)
            return rows + previous
        }
    }

    /// Whether the page shows its own provider rows (gpodder.net, Nextcloud or "Choose synchronization provider").
    public var showsOrdinaryRows: Bool { mode == .none }

    public var subtitle: Subtitle? {
        switch condition {
        case .attaching: return .preparing
        case .ready, .readyCast: return .ready
        case .loggedOut, .loggedOutCast, .keeping, .keepingCast, .keepStalled: return nil
        case .recovering: return .restoring
        case .needsSignIn: return .signInAgain
        case .serverNeedsUpdate, .appNeedsUpdate, .lineageUnknown, .serverRestored, .sharedInstallation, .serverLostChanges: return .paused
        case .unreachable: return .waitingForServer
        case .recoveryWaiting, .recoveryIncomplete, .waitingForBackground, nil:
            guard mode == .server else { return nil }
            return library?.lastSynchronization.map(Subtitle.report)
        }
    }

    /// The unsent changes "Synchronize now" mentions.
    public var unsentChanges: Int { library?.unsentChanges ?? 0 }
}

extension ServerSynchronizationSignals.Pause {
    /// The status-row condition of a pause the recovery resolves.
    var stopped: ServerSynchronizationPage.Condition? {
        switch self {
        case .serverRestored: .serverRestored
        case .sharedInstallation: .sharedInstallation
        case .serverLostChanges: .serverLostChanges
        case .serverNeedsUpdate, .appNeedsUpdate, .lineageUnknown: nil
        }
    }
}

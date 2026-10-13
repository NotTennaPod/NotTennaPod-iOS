import Foundation

/// The activation rule of PROTOCOL §15.4 (audio safety): a library switch runs only when nothing plays, nothing is
/// about to play, and nothing will resume by itself. A pause the person makes, a stop or the end of the last
/// episode satisfy it; an interruption by a phone call does not, because playback resumes after it.
public struct LibraryActivationState: Equatable, Sendable {
    public var wantsPlayback: Bool
    public var phase: PlaybackCoordinator.Phase
    /// An audio-session interruption holds playback that resumes by itself when it ends.
    public var awaitsInterruptionResumption: Bool
    /// A player command is queued or running (a Play just tapped has not shown its effect yet).
    public var hasPendingCommands: Bool
    /// A Cast session is connecting, or connected with media loaded on the receiver.
    public var castBlocks: Bool

    public init(wantsPlayback: Bool = false, phase: PlaybackCoordinator.Phase = .idle, awaitsInterruptionResumption: Bool = false,
                hasPendingCommands: Bool = false, castBlocks: Bool = false) {
        self.wantsPlayback = wantsPlayback; self.phase = phase
        self.awaitsInterruptionResumption = awaitsInterruptionResumption
        self.hasPendingCommands = hasPendingCommands; self.castBlocks = castBlocks
    }

    /// The state of a library graph's player; without one (the library could not open) nothing can play.
    @MainActor public init(_ playback: PlaybackCoordinator?, castBlocks: Bool) {
        self.init(wantsPlayback: playback?.wantsPlayback ?? false, phase: playback?.phase ?? .idle,
                  awaitsInterruptionResumption: playback?.awaitsInterruptionResumption ?? false,
                  hasPendingCommands: playback?.hasPendingCommands ?? false, castBlocks: castBlocks)
    }

    public var permitsSwitch: Bool {
        guard !wantsPlayback, !awaitsInterruptionResumption, !hasPendingCommands, !castBlocks else { return false }
        switch phase {
        case .preparing, .playing, .buffering: return false
        // Asking to confirm streaming, the player is unloaded and stays so until a tap (Cancel keeps the phase).
        case .idle, .stopped, .paused, .failed, .awaitingStreamingConfirmation: return true
        }
    }

    /// What of this device's playback holds a waiting switch or Keep, as its page names it; nil when playback does not.
    public var playbackHold: LibraryPlaybackHold? {
        if awaitsInterruptionResumption { return .resumingAfterInterruption }
        if wantsPlayback { return .playing }
        switch phase {
        case .preparing, .playing, .buffering: return .playing
        case .idle, .stopped, .paused, .failed, .awaitingStreamingConfirmation: return nil
        }
    }
}

/// Playback that a waiting library switch or Keep waits for (PROTOCOL §15.4). The person can end it with "Stop playback
/// and continue", which stops playback, a resumption still pending included, as Pause or Stop would.
public enum LibraryPlaybackHold: Equatable, Sendable {
    /// Playing, preparing or about to play.
    case playing
    /// Paused by an interruption (a call, another app's audio) that resumes playback when it ends; the player shows
    /// paused meanwhile. Only the interruption's end or a command of the person ends it, never the app coming back.
    case resumingAfterInterruption
}

/// Switches between libraries (PROTOCOL §15.4): a switch is recorded in the registry, and runs as the database
/// import's commit does, minus the file replacement: stop the library graph, then start it again; the start
/// applies the recorded switch before it opens any library. It runs only when the activation rule holds, checked
/// on the main actor after every player state change, at scene activation and when the switch is requested.
@MainActor public final class LibrarySwitcher {
    private let registry: LibraryRegistryFile
    private let activation: @MainActor () -> LibraryActivationState
    private let allowed: @MainActor () -> Bool
    private let settle: @MainActor () async -> Void
    private let retire: @MainActor () -> Void
    private let restart: @MainActor () async -> Void
    private let clock: () -> Date
    /// The library the current graph opened.
    public private(set) var openLibrary: LibraryReference = .standalone
    /// A switch is recorded and waits for the activation rule.
    public private(set) var isPending = false
    private var switching = false
    /// A Keep at logout waits for the same rule (PROTOCOL §15.4) and, when it holds, runs instead of a switch. `runKeep`
    /// takes the library gate, checks the rule again holding it, then stops the graph, runs the Keep and starts the
    /// graph again.
    public var keepPending: @MainActor () -> Bool = { false }
    public var runKeep: (@MainActor () async -> Void)?

    /// `activation` reads the player's state for the rule; `allowed` adds the app's own conditions (being in the
    /// foreground); `settle` returns once the player's queued commands have finished; `retire` closes the graph's
    /// command admission (it runs synchronously, in the same main-actor step as the final check); `restart` stops the
    /// library graph and starts it again.
    public init(registry: LibraryRegistryFile, activation: @escaping @MainActor () -> LibraryActivationState,
                allowed: @escaping @MainActor () -> Bool = { true }, settle: @escaping @MainActor () async -> Void = {},
                retire: @escaping @MainActor () -> Void = {}, restart: @escaping @MainActor () async -> Void,
                clock: @escaping () -> Date = { Date() }) {
        self.registry = registry; self.activation = activation; self.allowed = allowed; self.settle = settle
        self.retire = retire; self.restart = restart; self.clock = clock
    }

    /// At every graph start, after `LibraryRegistryFile.openingLibrary()` chose the library.
    public func opened(_ library: LibraryReference) {
        openLibrary = library
        // A registry that cannot be read now may hold a switch: keep checking at the next triggers.
        do { isPending = try registry.read().pendingSwitch != nil } catch { isPending = true }
    }

    /// Records a switch and runs it at once if the activation rule holds; otherwise it waits.
    public func request(_ target: LibraryReference, reason: LibraryRegistry.SwitchReason) async throws {
        let time = Int64((clock().timeIntervalSince1970 * 1_000).rounded(.down))
        let saved = try registry.update { try $0.recordSwitch(to: target, reason: reason, at: time) }
        isPending = saved.pendingSwitch != nil
        await attempt()
    }

    /// Runs a waiting switch if the activation rule holds now. Everything from the check to closing the graph's
    /// command admission runs synchronously, so no command can start playback in between; the asynchronous teardown
    /// follows. When only queued player commands hold it (they may publish no further state change), it waits for
    /// them and checks again. Checks run one at a time, each after the one before: checks interleaved at their waits
    /// (the page's "Stop playback and continue" and those after each player state change) each saw the others'
    /// waits queued on the player as pending commands, and could all give up.
    @discardableResult public func attempt() async -> Bool {
        let previous = checks
        let check = Task { @MainActor in
            _ = await previous?.value
            return await self.check()
        }
        checks = check
        return await check.value
    }

    private var checks: Task<Bool, Never>?

    private func check() async -> Bool {
        for _ in 0..<8 {
            let keep = runKeep != nil && keepPending()
            guard isPending || keep, !switching, allowed() else { return false }
            var state = activation()
            if state.permitsSwitch {
                if keep, let runKeep {
                    switching = true
                    defer { switching = false }
                    await runKeep()
                    return true
                }
                guard begin() else { return false }
                defer { switching = false }
                await restart()
                return true
            }
            state.hasPendingCommands = false
            guard state.permitsSwitch else { return false }
            await settle()
        }
        return false
    }

    /// Synchronous: decides whether the recorded switch needs a restart and, if so, retires the graph's commands.
    /// A registry that cannot be read keeps the switch pending for the next trigger.
    private func begin() -> Bool {
        guard var next = try? registry.read() else { return false }
        guard next.pendingSwitch != nil else { isPending = false; return false }
        next.applyPendingSwitch()
        if next.libraryToOpen == openLibrary {
            // A dropped switch, or one back to the library that is open: no restart needed.
            isPending = (try? registry.write(next)) == nil
            return false
        }
        switching = true
        retire()
        return true
    }

    /// Schedules `attempt()` in its own task, so a switch is never cancelled with the caller (for example the
    /// event loop of the graph the switch stops).
    public func attemptSoon() {
        guard isPending || (runKeep != nil && keepPending()) else { return }
        Task { await self.attempt() }
    }

    /// Called when what of playback holds a waiting switch or Keep changes (the Synchronization page names it).
    public var onPlaybackHoldChange: (@MainActor () -> Void)?

    /// Re-checks the rule after each state change of a graph's player. Cancel the task when the graph stops.
    public func observe(_ playback: PlaybackCoordinator) -> Task<Void, Never> {
        let events = playback.events()
        return Task { [weak self] in
            var hold = self?.activation().playbackHold
            for await event in events {
                guard case .stateChanged = event, let self else { continue }
                let now = activation().playbackHold
                if now != hold { hold = now; onPlaybackHoldChange?() }
                attemptSoon()
            }
        }
    }
}

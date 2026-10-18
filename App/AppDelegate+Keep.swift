import UIKit
import OSLog
import NotTennaPodCore

// "Keep using this library" at logout (PROTOCOL §15.4): the Keep transaction runs at a
// launch before anything opens, or at runtime when the activation rule holds in the foreground.
extension AppDelegate {
    /// The Keep engine for the device's libraries.
    func libraryKeep(root: URL) -> LibraryKeep {
        LibraryKeep(.init(root: root, secrets: KeychainServerSecrets(markerAccount: Self.serverMarkerAccount(root))))
    }

    /// Whether a Keep waits: a library logged out with "Keep using this library", or a converted library whose Keep
    /// has not published yet.
    var keepIsPending: Bool {
        guard let root = libraryDirectory else { return false }
        if libraryLocation?.converted != nil { return true }
        // Asked on every player state change: the registry is read again only when its file changed.
        let probe = keepPendingProbe.flatMap { $0.root == root ? $0 : nil } ?? KeepPendingProbe(root: root)
        keepPendingProbe = probe
        return probe.isPending
    }

    /// Why keeping the library has not finished, for the page's status row (PROTOCOL §15.5).
    var keepFailure: KeepFailure? {
        guard keepIsPending else { return nil }
        switch keepOutcome {
        case .notCommitted(let failure)?, .notPublished(let failure)?: return failure
        case .finished?, .cleanupPending?, nil: return nil
        }
    }

    /// Runs the pending Keep at runtime (the switcher calls it once the activation rule holds in the foreground): the
    /// library gate exclusively first, waiting for exports still collecting their source; then the rule again, holding
    /// the gate, with the graph's command admission retired in the same step (`LibraryKeepRuntime`);
    /// then the account-policy writes and playback saves settled and the graph stopped with the downloads detached,
    /// never cancelled; then every unfinished Keep's phases; the gate is released before the graph
    /// starts again, whatever the outcome.
    func runPendingKeep() async {
        guard let root = libraryDirectory else { return }
        let log = Logger(subsystem: "org.nottennapod.app", category: "Libraries")
        await LibraryKeepRuntime(gate: .shared, mayRun: { [weak self] in
            guard let self else { return false }
            let state = LibraryActivationState(playback, castBlocks: castRuntime?.blocksLibrarySwitch ?? false)
            return state.permitsSwitch && UIApplication.shared.applicationState != .background && keepIsPending
        }, retire: { [weak self] in
            // In the same step as the check: no command admitted after it reaches the graph the Keep stops.
            log.notice("Keeping this library: the graph stops")
            self?.retireLibraryGraph()
        }, stop: { [weak self] in
            guard let self else { return }
            if let backing = accountPolicy?.backing as? ServerAccountPolicyBacking { await backing.settle() }
            BackgroundMediaDownloads.shared.beginDetach()
            await stopLibraryGraph()
            BackgroundMediaDownloads.shared.endDetach()
        }, keep: { [weak self] in
            guard let self, let result = libraryKeep(root: root).runUnfinished() else { return }
            keepOutcome = result.outcome
            log.notice("Keep at logout: \(String(describing: result.outcome), privacy: .public)")
        }, restart: { [weak self] in
            guard let self else { return }
            keepJustAttempted = true
            restartLibraryGraph()
            serverAccounts?.pageChanged()
            // Live transfers name their libraries' current folders again (PROTOCOL §15.4 "Task records").
            Task { await BackgroundMediaDownloads.shared.normalizeLiveTasks() }
        }).run()
    }

    /// A kept library's pinned removals (PROTOCOL §15.4 "A podcast removed elsewhere"): the podcast is deleted once the player
    /// is no longer on its episode, at the graph start and after each change of the player's episode.
    func finishPinnedRemovals(store: FeedLibraryStore) {
        pinnedRemovalObservation?.cancel(); pinnedRemovalObservation = nil
        guard let playback, !(libraryLocation?.reference.isServer ?? false) || libraryLocation?.converted != nil else { return }
        let events = playback.events()
        pinnedRemovalObservation = Task { [weak self, weak playback] in
            guard (try? await store.hasPinnedFeedRemovals()) == true else { return }
            var episode: Int64? = -1
            if await self?.finishPinnedRemovalsNow(store: store) == true { return }
            for await event in events {
                guard case .stateChanged = event, let playback, playback.episode?.id != episode else { continue }
                episode = playback.episode?.id
                if await self?.finishPinnedRemovalsNow(store: store) == true { return }
            }
        }
    }

    /// Returns whether nothing is left to finish.
    private func finishPinnedRemovalsNow(store: FeedLibraryStore) async -> Bool {
        do {
            if try await !store.finishPinnedFeedRemovals().isEmpty {
                try await feedDeletion?.resume().value
                for controller in Self.libraryControllers { _ = controller.reloadLibrary(preservingEpisodeDetails: true) }
            }
            return try await !store.hasPinnedFeedRemovals()
        } catch {
            Logger(subsystem: "org.nottennapod.app", category: "Libraries").error("Pinned removal retained for retry")
            return false
        }
    }
}

extension LibraryReference {
    var isServer: Bool { if case .server = self { true } else { false } }
}

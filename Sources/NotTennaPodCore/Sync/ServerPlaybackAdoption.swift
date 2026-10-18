import Foundation

/// The sync layer's side of adoption while paused (PROTOCOL §8.6): when what adoption depends on changed (position knowledge),
/// after an exchange applied what another device did, at launch, and whenever the player stops playing, a remote position
/// waiting for the player's episode is adopted
/// through the coordinator's command queue (`PlaybackCoordinator.adoptRemotePosition`). Sync never seeks, pauses or
/// replaces playing audio: while the player plays, prepares or waits to resume after an interruption, the position
/// keeps waiting, and the next pause tries again. Failures are ignored; the next attempt starts over.
@MainActor public final class ServerPlaybackAdoption {
    private let store: FeedLibraryStore
    private weak var playback: PlaybackCoordinator?
    private var running: Task<Void, Never>?
    private var again = false

    public init(store: FeedLibraryStore, playback: PlaybackCoordinator) {
        self.store = store
        self.playback = playback
    }

    /// Tries once now (or once more after the attempt in progress).
    public func attempt() {
        guard running == nil else { again = true; return }
        guard let playback, !playback.playsForSynchronization, !playback.awaitsInterruptionResumption,
              let episodeID = playback.episode?.id else { return }
        let store = store
        running = Task { [weak self] in
            // A rebaseline settles the version without moving the player; only an adoption goes through the
            // coordinator's command queue (which checks again that nothing plays).
            switch (try? await store.serverAdoptionCheck(episodeID: episodeID)) ?? .none {
            case .adopt:
                try? await playback.adoptRemotePosition(episodeID: episodeID) { stillPaused in
                    try await store.adoptRemotePosition(episodeID: episodeID, stillPaused: stillPaused)
                }
            case .rebaseline:
                _ = try? await store.noteAdoptionBaseline(episodeID: episodeID)
            case .none:
                break
            }
            guard let self else { return }
            self.running = nil
            if self.again { self.again = false; self.attempt() }
        }
    }

    /// Returns once the attempt in progress (and any it queued) has finished, for tests.
    func settle() async {
        while let running { await running.value }
    }
}

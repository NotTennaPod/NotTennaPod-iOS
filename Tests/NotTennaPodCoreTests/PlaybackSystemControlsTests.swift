import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1))) @MainActor
struct PlaybackSystemControlsTests {
    @Test func repeatedSystemPauseDoesNotCreateDuplicateListeningActions() async throws {
        try await PCPlaybackFixture.withFixture { f in
            try await f.store.selectSynchronizationAccount(UUID())
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            let identity = try #require(f.player.systemSnapshot?.identity)
            f.engine.position(10_000); try await f.player.awaitPendingOperations()
            #expect(try await f.player.performSystemCommand(.pause, for: identity))
            #expect(try await f.player.performSystemCommand(.pause, for: identity))
            #expect(try await f.actions().count == 1)
        }
    }
    @Test func sourceMetadataReflectsSeekPauseBufferingAndReceiverEffectiveRate() async throws {
        try await PCPlaybackFixture.withFixture { f in
            let owner = PlaybackSystemControls(playback: f.player); owner.start(); defer { owner.stop() }
            #expect(owner.snapshot == nil)
            try await f.player.select(episodeID: 1)
            #expect(owner.snapshot?.rate == 0 && owner.snapshot?.canSeek == false)
            f.engine.ready(); try await f.player.awaitPendingOperations()
            let identity = try #require(owner.snapshot?.identity)
            #expect(try await owner.perform(.rate(2), for: identity))
            f.engine.position(42_000); try await f.player.awaitPendingOperations()
            #expect(owner.snapshot?.positionMilliseconds == 42_000 && owner.snapshot?.durationMilliseconds == 100_000)
            #expect(owner.snapshot?.rate == 2 && owner.snapshot?.title == "Episode 1")
            #expect(try await owner.perform(.seek(milliseconds: 70_000), for: identity))
            #expect(f.engine.seeks.last == 70_000)
            #expect(try await owner.perform(.pause, for: identity))
            #expect(owner.snapshot?.rate == 0 && owner.snapshot?.defaultRate == 2)
            #expect(try await f.store.episode(id: 1)?.userState.positionMilliseconds == 70_000)
            #expect(try await owner.perform(.play, for: identity))
            f.engine.state(.playing, buffering: true); try await f.player.awaitPendingOperations()
            #expect(owner.snapshot?.rate == 0 && owner.snapshot?.wantsPlayback == true)
            let receiver = PCPlaybackEngine(); receiver.maximumRate = 2
            f.routes.setRemote(receiver); receiver.ready(); try await f.player.awaitPendingOperations()
            #expect(try await owner.perform(.rate(4), for: identity))
            #expect(f.player.speed == 4 && owner.snapshot?.defaultRate == 2 && owner.snapshot?.rate == 2)
            #expect(try await owner.perform(.pause, for: identity))
            #expect(!receiver.playing && owner.snapshot?.identity == identity)
        }
    }

    @Test func retiredSelectionAndStoppedAdapterCannotCommandReplacement() async throws {
        try await PCPlaybackFixture.withFixture { f in
            let owner = PlaybackSystemControls(playback: f.player); owner.start(); defer { owner.stop() }
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            let old = try #require(owner.snapshot?.identity)
            try await f.player.select(episodeID: 2); f.engine.ready(); try await f.player.awaitPendingOperations()
            #expect(try await owner.perform(.pause, for: old) == false)
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            #expect(try await owner.perform(.next, for: old) == false)
            let current = try #require(owner.snapshot?.identity)
            #expect(current != old && f.player.wantsPlayback)
            let delayed = Task { try await owner.perform(.pause, for: current) }
            owner.stop()
            #expect(try await delayed.value == false)
            #expect(f.player.wantsPlayback)
            owner.start()
            #expect(try await owner.perform(.pause, for: current))
            #expect(!f.player.wantsPlayback)
        }
    }

    @Test func noSyntheticLiveDurationAndNoUnsupportedScrubbing() async throws {
        try await PCPlaybackFixture.withFixture { f in
            f.engine.duration = -1
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            let state = try #require(f.player.systemSnapshot)
            #expect(state.durationMilliseconds == nil && !state.canSeek && state.canSkip)
            #expect(try await f.player.performSystemCommand(.seek(milliseconds: 5000), for: state.identity) == false)
            #expect(try await f.player.performSystemCommand(.skip(seconds: 30, direction: .forward), for: state.identity))
            #expect(f.engine.seeks.last == 30_000)
            #expect(try await f.player.performSystemCommand(.restart, for: state.identity))
            #expect(f.engine.seeks.last == 0)
            #expect(try await f.player.performSystemCommand(.rate(.nan), for: state.identity) == false)
        }
    }

    @Test func restoredSelectionAcceptsPlayThenPauseWithoutCreatingSecondSelection() async throws {
        try await PCPlaybackFixture.withFixture { f in
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            try await f.player.stop()
            let identity = try #require(f.player.systemSnapshot?.identity)
            #expect(try await f.player.performSystemCommand(.play, for: identity))
            #expect(try await f.player.performSystemCommand(.pause, for: identity))
            f.engine.ready(); try await f.player.awaitPendingOperations()
            #expect(f.player.phase == .paused && f.player.systemSnapshot?.identity == identity)
        }
    }

    @Test func unknownDurationMinuteTimerSurvivesRouteThenExpiresWithoutCompleting() async throws {
        try await PCPlaybackFixture.withFixture { f in
            _ = try await f.store.enqueue([1, 2])
            f.engine.duration = -1
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            let session = try await f.store.playbackSession()?.id
            try await f.player.startSleepTimer(mode: .minutes, value: 8000)
            f.clock.milliseconds += 3000; f.engine.position(3000)
            try await f.player.awaitPendingOperations()
            #expect(f.player.sleepTimerValue?.display == 5000 && f.engine.volume == 0.5)
            #expect(f.player.sample?.positionMilliseconds == 0)
            #expect(try await f.store.episode(id: 1)?.userState.positionMilliseconds == 0)
            let receiver = PCPlaybackEngine(); receiver.duration = -1
            f.routes.setRemote(receiver); receiver.ready(); try await f.player.awaitPendingOperations()
            #expect(try await f.store.playbackSession()?.id == session)
            f.clock.milliseconds += 3000; receiver.position(6000)
            try await f.player.awaitPendingOperations()
            #expect(f.player.sleepTimerValue?.display == 2000 && receiver.volume == 0.2)
            // A duration learned later must not restart the countdown.
            f.clock.milliseconds += 1000; receiver.position(7000, duration: 100_000)
            try await f.player.awaitPendingOperations()
            #expect(f.player.sleepTimerValue?.display == 1000)
            f.clock.milliseconds += 1000; receiver.position(8000, duration: -1)
            try await f.player.awaitPendingOperations()
            #expect(!receiver.playing && f.player.phase == .paused && f.player.sleepTimer == nil)
            #expect(receiver.volume == 1 && f.player.episode?.id == 1)
            #expect(try await f.store.episode(id: 1)?.userState.positionMilliseconds == 8000)
            #expect(try await f.store.episode(id: 1)?.userState.playState != .played)
            #expect(try await f.store.queue().map(\.id) == [1, 2])
        }
    }

    @Test func unknownDurationDoesNotFadeOrExpireEpisodeMode() async throws {
        try await PCPlaybackFixture.withFixture { f in
            f.engine.duration = -1
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            try await f.player.startSleepTimer(mode: .episodes, value: 1)
            for position: Int32 in [3000, 6000, 9000] {
                f.clock.milliseconds += 3000; f.engine.position(position); try await f.player.awaitPendingOperations()
            }
            #expect(f.player.sleepTimer?.remaining == 1 && f.player.wantsPlayback && f.engine.volume == 1)
            #expect(try await f.store.episode(id: 1)?.userState.positionMilliseconds == 0)
        }
    }
}

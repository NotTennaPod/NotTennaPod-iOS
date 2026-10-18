import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite @MainActor
struct PlaybackVideoCommandTests {
    @Test func tracksUseActualLocalSessionAndPreservePlaybackIntent() async throws {
        try await withVideoFixture { f in
            #expect(f.player.videoPresentation?.mediaTracks.map(\.id) == [1, 2, 9])
            try await f.player.selectAudioTrack(id: 2)
            #expect(f.engine.selectedAudioTrackID == 2 && f.engine.trackCommands == [2])
            #expect(f.player.wantsPlayback && f.player.episode?.id == 1)
            try await f.player.selectAudioTrack(id: 2)
            #expect(f.engine.trackCommands == [2])
            await #expect(throws: PlaybackTrackSelectionError.self) { try await f.player.selectAudioTrack(id: 9) }
            #expect(f.engine.trackCommands == [2])
            f.engine.rejectTrack = true
            await #expect(throws: PlaybackTrackSelectionError.self) { try await f.player.selectAudioTrack(id: 1) }
            try await f.player.pause()
            #expect(!f.player.wantsPlayback && f.engine.base.reading?.sample.status == .paused)
        }
    }

    @Test func queuedTrackChoiceCannotCrossSameEpisodeReplacement() async throws {
        try await withVideoFixture { f in
            let gate = VideoCommandGate()
            let block = Task { try await f.player.deleteLocalMedia(target: .init(episodeID: 999, feedID: 999, source: "missing", media: .remote(mediaURL: nil, originalFile: nil)), operation: {
                await gate.wait(); return .stale
            }) }
            await gate.waitUntilEntered()
            let reads = f.engine.presentationReads
            let choice = Task { try await f.player.selectAudioTrack(id: 2) }
            while f.engine.presentationReads == reads { await Task.yield() }
            f.engine.replacePresentation()
            gate.open()
            _ = try await block.value
            await #expect(throws: CancellationError.self) { try await choice.value }
            #expect(f.engine.trackCommands.isEmpty)
        }
    }

    @Test func retiredPictureCallbacksCannotControlAToBToAOrSameEpisodeReplacement() async throws {
        try await withVideoFixture { f in
            let old = try #require(f.engine.videoPictureInPicture?.onSetPlaying)
            try await f.player.select(episodeID: 2); f.engine.ready(); try await f.settle()
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.settle()
            old(false); try await f.settle()
            #expect(f.player.wantsPlayback)
            let retired = try #require(f.engine.videoPictureInPicture)
            let saved = try #require(retired.onSetPlaying)
            f.engine.replacePresentation(); f.engine.announce(); try await f.settle()
            #expect(retired.onSetPlaying == nil && retired.onSeekSourceTime == nil)
            saved(false); try await f.settle()
            #expect(f.player.wantsPlayback)
            f.engine.videoPictureInPicture?.onSetPlaying?(false); try await f.settle()
            #expect(!f.player.wantsPlayback)
        }
    }

    @Test(arguments: ["session", "layer", "picture"])
    func eachPresentationIdentityIndependentlyRetiresCapturedCallbacks(change: String) async throws {
        try await withVideoFixture { f in
            let oldID = f.engine.mediaPresentationID
            let oldLayer = f.engine.videoDisplayLayer
            let oldPicture = try #require(f.engine.videoPictureInPicture)
            let saved = try #require(oldPicture.onSetPlaying)
            f.engine.replacePresentation()
            if change != "session" { f.engine.mediaPresentationID = oldID }
            if change != "layer" { f.engine.videoDisplayLayer = oldLayer }
            if change != "picture" { f.engine.videoPictureInPicture = oldPicture }
            f.engine.announce(); try await f.settle()
            saved(false); try await f.settle()
            #expect(f.player.wantsPlayback)
            if change == "picture" { #expect(oldPicture.onSetPlaying == nil && oldPicture.onSeekSourceTime == nil) }
            f.engine.videoPictureInPicture?.onSetPlaying?(false); try await f.settle()
            #expect(!f.player.wantsPlayback)
        }
    }

    @Test func castReturnRetiresLocalCommandsAndRestoresNewBinding() async throws {
        try await withVideoFixture { f in
            let old = try #require(f.engine.videoPictureInPicture)
            let saved = try #require(old.onSetPlaying)
            let remote = PCPlaybackEngine()
            f.routes.setRemote(remote); remote.ready(); try await f.settle()
            #expect(f.player.videoPresentation == nil && old.onSetPlaying == nil)
            await #expect(throws: PlaybackTrackSelectionError.self) { try await f.player.selectAudioTrack(id: 2) }
            saved(false); try await f.settle(); #expect(remote.playing)
            f.routes.setRemote(nil); f.engine.ready(); try await f.settle()
            saved(false); try await f.settle(); #expect(f.player.wantsPlayback)
            f.engine.videoPictureInPicture?.onSetPlaying?(false); try await f.settle()
            #expect(!f.player.wantsPlayback)
        }
    }

    @Test func pictureSeekWaitsForActualPreparedTimebaseIncludingPausedSeek() async throws {
        try await withVideoFixture { f in
            try await f.player.pause(); try await f.settle()
            let seek = try #require(f.engine.videoPictureInPicture?.onSeekSourceTime)
            var completed = false
            let task = Task { try await seek(CMTime(value: 23_750, timescale: 1_000)); completed = true }
            await f.engine.waitForSeek(); try await f.settle()
            #expect(!completed && f.engine.base.seeks == [23_750] && !f.player.wantsPlayback)
            f.engine.replacePresentation(); f.engine.finishSeek(); try await f.settle()
            try await task.value
            #expect(completed && !f.player.wantsPlayback && f.player.systemSnapshot?.positionMilliseconds == 23_750)
        }
    }

    @Test func pendingPictureSeekCancelsOnUnobservedCastRoundTrip() async throws {
        try await withVideoFixture { f in
            let seek = try #require(f.engine.videoPictureInPicture?.onSeekSourceTime)
            let task = Task { try await seek(CMTime(seconds: 30, preferredTimescale: 1_000)) }
            await f.engine.waitForSeek()
            f.routes.setRemote(PCPlaybackEngine()); f.routes.setRemote(nil)
            f.engine.ready(); try await f.settle()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(f.player.wantsPlayback)
        }
    }

    @Test func pendingPictureSeekSettlesWithErrorWhenEngineFails() async throws {
        try await withVideoFixture { f in
            let seek = try #require(f.engine.videoPictureInPicture?.onSeekSourceTime)
            var settled = false
            let task = Task {
                defer { settled = true }
                try await seek(CMTime(seconds: 15, preferredTimescale: 1_000))
            }
            await f.engine.waitForSeek()
            #expect(!settled)
            f.engine.base.reading = nil
            f.engine.onEvent?(.failed(generation: f.engine.base.generation, message: "Controlled decoder failure"))
            try await f.settle()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(settled && f.player.phase == .failed && !f.player.wantsPlayback)
            #expect(f.player.videoPresentation == nil && f.engine.videoPictureInPicture == nil)
        }
    }

    @Test func newerPauseCancelsPendingSeekWithoutResumingPlayback() async throws {
        try await withVideoFixture { f in
            let seek = try #require(f.engine.videoPictureInPicture?.onSeekSourceTime)
            let task = Task { try await seek(CMTime(seconds: 15, preferredTimescale: 1_000)) }
            await f.engine.waitForSeek()
            try await f.player.pause(); try await f.settle()
            await #expect(throws: CancellationError.self) { try await task.value }
            f.engine.finishSeek(); try await f.settle()
            #expect(!f.player.wantsPlayback && f.player.phase == .paused)
        }
    }

#if DEBUG
    /// A Picture in Picture seek is a seek like any other: while an earlier pause's save waits for a busy
    /// store, the engine seeks at once.
    @Test func pictureSeekDoesNotWaitForEarlierPauseSave() async throws {
        try await withVideoFixture { f in
            let gate = VideoStoreGate(holding: { if case .recordPlayback = $0 { true } else { false } })
            f.player.storeGate = { try await gate.pass($0) }
            let pausing = Task { try await f.player.pause() }
            await gate.waitUntilHolding()
            let seek = try #require(f.engine.videoPictureInPicture?.onSeekSourceTime)
            let task = Task { try await seek(CMTime(value: 23_750, timescale: 1_000)) }
            // A bounded wait on the condition: without hoisting the seek waits for the held save and never comes.
            for _ in 0..<2_000 where f.engine.base.seeks.isEmpty { await Task.yield() }
            #expect(f.engine.base.seeks == [23_750] && gate.isHolding, "the engine seeked while the pause's save waits")
            gate.release(); try await pausing.value
            f.engine.finishSeek(); try await f.settle()
            try await task.value
            #expect(!f.player.wantsPlayback && f.player.systemSnapshot?.positionMilliseconds == 23_750)
            f.player.storeGate = nil
        }
    }

    /// A Pause after a Picture in Picture seek does not wait for that seek's recording: the audio stops at once.
    @Test func pauseDoesNotWaitForPictureSeekRecord() async throws {
        try await withVideoFixture { f in
            let gate = VideoStoreGate(holding: { if case .recordSeekIntent = $0 { true } else { false } })
            f.player.storeGate = { try await gate.pass($0) }
            let seek = try #require(f.engine.videoPictureInPicture?.onSeekSourceTime)
            let task = Task { try await seek(CMTime(value: 23_750, timescale: 1_000)) }
            await gate.waitUntilHolding()
            let pausing = Task { try await f.player.pause() }
            for _ in 0..<2_000 where f.player.wantsPlayback { await Task.yield() }
            #expect(!f.player.wantsPlayback && f.player.phase == .paused && gate.isHolding, "paused while the seek's record waits")
            #expect(f.engine.base.seeks == [23_750])
            gate.release(); try await pausing.value; try await f.settle()
            // The newer Pause supersedes the seek's settled-timebase wait, as before.
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!f.player.wantsPlayback && f.player.phase == .paused)
            f.player.storeGate = nil
        }
    }
#endif

    @Test func audioOnlyTracksRemainAvailableWithoutInventingVideoSurface() async throws {
        try await withVideoFixture { f in
            f.engine.videoDisplayLayer = nil; f.engine.videoPictureInPicture = nil
            f.engine.announce(); try await f.settle()
            #expect(f.player.videoPresentation != nil && f.player.videoPresentation?.videoDisplayLayer == nil)
            try await f.player.selectAudioTrack(id: 2)
            #expect(f.engine.trackCommands == [2])
            f.engine.mediaPresentationID = nil; f.engine.announce(); try await f.settle()
            #expect(f.player.videoPresentation == nil)
            await #expect(throws: PlaybackTrackSelectionError.self) { try await f.player.selectAudioTrack(id: 1) }
        }
    }

    @Test func ownerStopClearsCallbacksAndCancelsPendingSeek() async throws {
        try await withVideoFixture { f in
            let picture = try #require(f.engine.videoPictureInPicture)
            let play = try #require(picture.onSetPlaying)
            let seek = try #require(picture.onSeekSourceTime)
            let task = Task { try await seek(CMTime(seconds: 15, preferredTimescale: 1_000)) }
            await f.engine.waitForSeek()
            f.owner.stop()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(picture.onSetPlaying == nil && picture.onSeekSourceTime == nil)
            play(false); try await f.settle(); #expect(f.player.wantsPlayback)
            f.engine.finishSeek(); f.owner.start(); try await f.settle()
            picture.onSetPlaying?(false); try await f.settle(); #expect(!f.player.wantsPlayback)
        }
    }
}

@MainActor private final class VideoCommandEngine: PlaybackVideoPresenting {
    let base = PCPlaybackEngine()
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)? {
        get { base.onEvent } set { base.onEvent = newValue }
    }
    var reading: PlaybackEngineReading? { base.reading }
    var videoDisplayLayer: AVSampleBufferDisplayLayer?
    var videoPictureInPicture: PlaybackVideoPictureInPicture?
    private var presentationID: UUID?
    var presentationReads = 0
    var mediaPresentationID: UUID? {
        get { presentationReads += 1; return presentationID }
        set { presentationID = newValue }
    }
    let mediaTracks: [PlaybackMediaTrack] = [.init(id: 1, kind: .audio, codec: "aac"),
        .init(id: 2, kind: .audio, codec: "aac"), .init(id: 9, kind: .video, codec: "h264")]
    var selectedAudioTrackID: Int32? = 1
    var selectedVideoTrackID: Int32? = 9
    var rejectTrack = false
    var trackCommands: [Int32] = []
    var seekWaiter: CheckedContinuation<Void, Never>?
    func replacePresentation() {
        mediaPresentationID = UUID()
        let layer = AVSampleBufferDisplayLayer(); videoDisplayLayer = layer
        videoPictureInPicture = PlaybackVideoPictureInPicture(displayLayer: layer, currentTime: { .zero })
    }
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        base.load(episode: episode, generation: generation, positionMilliseconds: positionMilliseconds)
        replacePresentation()
    }
    func ready() { base.ready() }
    func announce() { if let reading { onEvent?(.stateChanged(reading)) } }
    func play(commandID: UUID) { base.play(commandID: commandID) }
    func pause(commandID: UUID) { base.pause(commandID: commandID) }
    func setSpeed(_ value: Float, commandID: UUID) { base.setSpeed(value, commandID: commandID) }
    func seek(to positionMilliseconds: Int64, commandID: UUID) {
        base.seek(to: positionMilliseconds, commandID: commandID)
        base.reading?.buffering = true; announce()
        seekWaiter?.resume(); seekWaiter = nil
    }
    func finishSeek() { base.reading?.buffering = false; announce() }
    func waitForSeek() async {
        if base.reading?.buffering == true { return }
        await withCheckedContinuation { seekWaiter = $0 }
    }
    func selectAudioTrack(id: Int32, commandID: UUID) throws {
        if rejectTrack { throw PlaybackTrackSelectionError.unsupported }
        trackCommands.append(id); selectedAudioTrackID = id
        base.commandID = commandID; base.reading?.commandID = commandID
    }
    func unload() { base.unload(); mediaPresentationID = nil; videoDisplayLayer = nil; videoPictureInPicture = nil }
}

@MainActor private final class VideoCommandFixture {
    let store: FeedLibraryStore
    let engine = VideoCommandEngine()
    let routes: RoutedPlaybackEngine
    let player: PlaybackCoordinator
    let owner: PlaybackSystemControls
    init(store: FeedLibraryStore) {
        self.store = store; routes = RoutedPlaybackEngine(local: engine)
        player = PlaybackCoordinator(store: store, engine: routes)
        owner = PlaybackSystemControls(playback: player)
    }
    func settle() async throws {
        try await player.awaitPendingOperations()
        // Drain the app-lifetime stream and any task admitted by its callback.
        for _ in 0..<8 { await Task.yield(); try await player.awaitPendingOperations() }
    }
}

@MainActor private func withVideoFixture(_ body: (VideoCommandFixture) async throws -> Void) async throws {
    try await PCPlaybackFixture.withFixture { base in
        let f = VideoCommandFixture(store: base.store)
        f.owner.start()
        do {
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.settle()
            try await body(f)
            f.owner.stop(); try await f.player.stop()
        } catch { f.owner.stop(); try? await f.player.stop(); throw error }
    }
}

@MainActor private final class VideoCommandGate {
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func open() { waiter?.resume(); waiter = nil }
}

/// Holds the first store write `holding` selects until `release` (the coordinator's `storeGate`).
@MainActor private final class VideoStoreGate {
    let holding: (PlaybackStoreCall) -> Bool
    private var held: CheckedContinuation<Void, Never>?
    private var used = false
    var isHolding: Bool { held != nil }
    init(holding: @escaping (PlaybackStoreCall) -> Bool) { self.holding = holding }
    func pass(_ call: PlaybackStoreCall) async throws {
        guard !used, holding(call) else { return }
        used = true
        await withCheckedContinuation { held = $0 }
    }
    func waitUntilHolding() async { while held == nil { await Task.yield() } }
    func release() { held?.resume(); held = nil }
}

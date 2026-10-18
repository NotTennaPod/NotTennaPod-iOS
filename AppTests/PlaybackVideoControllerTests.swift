import UIKit
import AVFoundation
import AVKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Controlled session seam. This proves screen-to-shared-owner behavior, not decoding.
@MainActor private final class VideoControllerSessionFixture: PlaybackVideoPresenting {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    let videoDisplayLayer: AVSampleBufferDisplayLayer? = AVSampleBufferDisplayLayer()
    let videoPictureInPicture: PlaybackVideoPictureInPicture? = nil
    var mediaPresentationID: UUID? = UUID()
    let mediaTracks: [PlaybackMediaTrack] = [
        .init(id: 0, kind: .video, codec: "h264", videoGeometry: .init(width: 320, height: 180)),
        .init(id: 1, kind: .audio, language: "eng", codec: "aac"),
        .init(id: 2, kind: .audio, language: "deu", codec: "aac")]
    var selectedAudioTrackID: Int32? = 1
    let selectedVideoTrackID: Int32? = 0
    var loads = 0, unloads = 0
    var seeks: [Int64] = [], selectedTracks: [Int32] = []
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        loads += 1; mediaPresentationID = UUID()
        reading = .init(generation: generation,
            sample: .init(positionMilliseconds: Int32(clamping: positionMilliseconds), durationMilliseconds: 120_000, status: .paused))
        onEvent?(.ready(reading!))
    }
    private func change(_ commandID: UUID, _ body: (inout PlaybackEngineReading) -> Void) {
        guard var value = reading else { return }; value.commandID = commandID; body(&value)
        reading = value; onEvent?(.stateChanged(value))
    }
    func play(commandID: UUID) { change(commandID) { $0.sample.status = .playing } }
    func pause(commandID: UUID) { change(commandID) { $0.sample.status = .paused } }
    func seek(to positionMilliseconds: Int64, commandID: UUID) {
        seeks.append(positionMilliseconds)
        change(commandID) { $0.sample.positionMilliseconds = Int32(clamping: positionMilliseconds) }
    }
    func setSpeed(_ speed: Float, commandID: UUID) throws { change(commandID) { $0.speed = speed } }
    func selectAudioTrack(id: Int32, commandID: UUID) throws {
        guard [Int32(1), 2].contains(id) else { throw PlaybackTrackSelectionError.invalidTrack }
        selectedTracks.append(id); selectedAudioTrackID = id; change(commandID) { _ in }
    }
    func unload() { unloads += 1; reading = nil; mediaPresentationID = nil }
}

@MainActor @Suite(.serialized) struct PlaybackVideoControllerTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id { return view as? T }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func wait(file: String = #fileID, line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Waiting at \(file):\(line)")
    }
    @Test func videoAndTrackControlsUseSharedOwnerAndAudioOnlyRetainsItsSession() async throws {
        print("PLAYBACK_VIDEO_PLATFORM_PIP supported=\(AVPictureInPictureController.isPictureInPictureSupported()) simulator=\(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "unknown") OS=\(UIDevice.current.systemVersion)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VideoController-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let url = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Video", episodes: [
                .init(identifier: "video", title: "Video", media: .init(url: "https://example.invalid/video.mp4", size: 0, mimeType: "video/mp4", durationMilliseconds: 120_000))
            ]), source: url.absoluteString, responseURL: url, validator: nil, permanentRedirectURL: nil))
            let episode = try #require(feed.episodes.first), engine = VideoControllerSessionFixture()
            let playback = PlaybackCoordinator(store: store, engine: engine)
            let time = try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json"))
            let intervals = try PlaybackIntervalPreferenceStore(file: root.appendingPathComponent("intervals.json"))
            try await playback.select(episodeID: episode.id, play: false)
            try await wait { playback.phase == .paused }
            let preparedUnloads = engine.unloads
            try await withViewTestWindow { host, window in
                // The video's landscape request must not outlive it: an upright phone returns upright after closing.
                let scene = try #require(window.windowScene), upright = scene.effectiveGeometry.interfaceOrientation
                let controller = PlaybackVideoViewController(playback: playback, library: store, timePreferences: time,
                    intervals: intervals, speeds: nil, timerPreferences: nil, queuePreferences: nil, chapters: nil, transcripts: nil)
                var closed = false; controller.onClose = { closed = true }
                host.present(controller, animated: false)
                try await wait { controller.viewIfLoaded?.window != nil && !controller.isBeingPresented }
                try await wait { scene.effectiveGeometry.interfaceOrientation.isLandscape || controller.landscapeRefusal != nil }
                let video = controller.videoView
                try await wait { video.displayLayer === engine.videoDisplayLayer }
                video.setControlsVisible(true)
                video.playButton.sendActions(for: .touchUpInside)
                try await wait { playback.wantsPlayback && playback.phase == .playing }
                video.forwardButton.sendActions(for: .touchUpInside)
                try await wait { engine.seeks.last == 30_000 }
                video.rewindButton.sendActions(for: .touchUpInside)
                try await wait { engine.seeks.last == 20_000 }
                let seek: PlayerSeekBar = try #require(find("videoSeek", in: video))
                seek.value = 250; seek.sendActions(for: .valueChanged); seek.sendActions(for: .editingDidEnd)
                try await wait { playback.sample?.positionMilliseconds == 60_000 }
                let body = PlaybackVideoAudioTracksView(playback: playback) { Issue.record($0) }
                let german: UIButton = try #require(find("videoAudioTrack-2", in: body))
                german.sendActions(for: .touchUpInside)
                try await wait { german.isEnabled && german.accessibilityTraits.contains(.selected) }
                #expect(engine.selectedTracks == [2])
                // A queued button from the prior media session must not target a
                // replacement which happens to reuse the same numeric track IDs.
                engine.mediaPresentationID = UUID()
                try await playback.setSpeed(1)
                try await wait { (find("videoAudioTrack-2", in: body) as UIButton?) !== german }
                german.sendActions(for: .touchUpInside)
                #expect(engine.selectedTracks == [2])
                let english: UIButton = try #require(find("videoAudioTrack-1", in: body))
                english.sendActions(for: .touchUpInside)
                try await wait { engine.selectedTracks == [2, 1] }
                #expect(playback.wantsPlayback && playback.sample?.positionMilliseconds == 60_000)
                #expect(engine.loads == 1 && engine.unloads == preparedUnloads)
                let session = engine.mediaPresentationID
                controller.close()
                try await wait { closed && host.presentedViewController == nil }
                #expect(engine.loads == 1 && engine.unloads == preparedUnloads)
                #expect(engine.mediaPresentationID == session && playback.wantsPlayback)
                #expect(engine.videoDisplayLayer?.superlayer == nil)
                let reattached = PlaybackVideoViewController(playback: playback, library: store, timePreferences: time,
                    intervals: intervals, speeds: nil, timerPreferences: nil, queuePreferences: nil, chapters: nil, transcripts: nil)
                host.present(reattached, animated: false)
                try await wait { reattached.videoView.displayLayer === engine.videoDisplayLayer }
                try await wait { scene.effectiveGeometry.interfaceOrientation.isLandscape || reattached.landscapeRefusal != nil }
                #expect(playback.sample?.positionMilliseconds == 60_000 && engine.selectedAudioTrackID == 1)
                #expect(engine.loads == 1 && engine.mediaPresentationID == session)
                reattached.close(); try await wait { host.presentedViewController == nil }
                try await wait { scene.effectiveGeometry.interfaceOrientation == upright }
                try await playback.pause()
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
    @Test func restoredVideoMiniPlayerPreparesPictureWithoutStartingPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VideoRestore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let url = URL(string: "https://example.invalid/restored-video")!
            let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Video", episodes: [
                .init(identifier: "video", title: "Video", media: .init(url: "https://example.invalid/video.mp4", size: 0, mimeType: "video/mp4", durationMilliseconds: 120_000))
            ]), source: url.absoluteString, responseURL: url, validator: nil, permanentRedirectURL: nil))
            let episode = try #require(feed.episodes.first), engine = VideoControllerSessionFixture()
            _ = try await store.beginPlayback(episodeID: episode.id)
            let playback = PlaybackCoordinator(store: store, engine: engine)
            try await playback.restore()
            #expect(playback.phase == .stopped && !playback.wantsPlayback && engine.loads == 0)
            let time = try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json"))
            try await withViewTestWindow { host, window in
                let scene = try #require(window.windowScene), upright = scene.effectiveGeometry.interfaceOrientation
                let controller = LibraryViewController(library: store, startupError: nil, downloads: nil,
                    playback: playback, timeDisplayPreferences: time, navigationPreferences: nil,
                    speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
                host.addChild(controller); controller.view.frame = host.view.bounds
                host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value
                let mini: UIButton = try #require(find("miniPlayerOpen", in: controller.view))
                mini.sendActions(for: .touchUpInside)
                try await wait { controller.presentedViewController is PlaybackVideoViewController }
                let video = try #require(controller.presentedViewController as? PlaybackVideoViewController)
                try await wait { video.viewIfLoaded?.window != nil && !video.isBeingPresented && video.videoView.displayLayer != nil }
                try await wait { scene.effectiveGeometry.interfaceOrientation.isLandscape || video.landscapeRefusal != nil }
                #expect(video.videoView.displayLayer === engine.videoDisplayLayer)
                #expect(playback.phase == .paused && !playback.wantsPlayback && engine.loads == 1)
                #expect(playback.episode?.id == episode.id)
                let preparedUnloads = engine.unloads
                video.close(); try await wait { controller.presentedViewController == nil }
                try await wait { scene.effectiveGeometry.interfaceOrientation == upright }
                #expect(engine.unloads == preparedUnloads && !playback.wantsPlayback)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

}

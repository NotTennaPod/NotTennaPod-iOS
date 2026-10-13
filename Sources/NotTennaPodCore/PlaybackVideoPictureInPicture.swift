import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation

/// PiP owns presentation, while all play/seek decisions remain with the actual session.
/// Finite ranges describe the shared display clock. Source-time seek bounds are supplied
/// independently because a streaming processing map may only cover committed output.
@MainActor public final class PlaybackVideoPictureInPicture: NSObject, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    enum Failure: Error { case unavailableMapping }
    public var controller: AVPictureInPictureController {
        if let backingController { return backingController }
        let value = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self))
        if closed { value.contentSource = nil }
        backingController = value
        return value
    }
    private var backingController: AVPictureInPictureController?
    private var displayLayer: AVSampleBufferDisplayLayer
    public var onSetPlaying: (@MainActor (Bool) -> Void)?
    public var onSeekSourceTime: (@MainActor (CMTime) async throws -> Void)?
    public var onRenderSizeChanged: (@MainActor (CMVideoDimensions) -> Void)?
    public var onFailure: (@MainActor (any Error) -> Void)?
    private var currentTime: @MainActor () -> CMTime
    private var timeline: PlaybackVideoTimeline?
    private var seekableSourceRange: CMTimeRange = .invalid
    private var paused = true
    private var closed = false
    private var revision: UInt64 = 0

    init(displayLayer: AVSampleBufferDisplayLayer, currentTime: @escaping @MainActor () -> CMTime) {
        self.currentTime = currentTime
        self.displayLayer = displayLayer
        super.init()
    }

    func update(timeline: PlaybackVideoTimeline, seekableSourceRange: CMTimeRange, paused: Bool) {
        guard !closed else { return }
        self.timeline = timeline; self.seekableSourceRange = seekableSourceRange; self.paused = paused
        controller.invalidatePlaybackState()
    }

    func suspendForReplacement() {
        guard !closed else { return }
        revision &+= 1
        let frozen = currentTime()
        currentTime = { frozen }
        paused = true
        onSetPlaying = nil; onSeekSourceTime = nil; onRenderSizeChanged = nil; onFailure = nil
        backingController?.invalidatePlaybackState()
    }

    func replacePresentation(displayLayer: AVSampleBufferDisplayLayer, currentTime: @escaping @MainActor () -> CMTime) throws {
        guard !closed, displayLayer.isReadyForDisplay else { throw Failure.unavailableMapping }
        revision &+= 1
        self.displayLayer = displayLayer; self.currentTime = currentTime
        backingController?.contentSource = .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
    }

    func close() {
        guard !closed else { return }
        closed = true; revision &+= 1
        backingController?.stopPictureInPicture(); backingController?.contentSource = nil
        onSetPlaying = nil; onSeekSourceTime = nil; onRenderSizeChanged = nil; onFailure = nil
        timeline = nil
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if !closed { onSetPlaying?(playing) }
    }
    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let now = currentTime()
        guard !closed, let range = timeline?.presentationRange, now.isNumeric,
              now >= range.start, now <= range.end else { return .invalid }
        return range
    }
    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { closed || paused }
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        if !closed { onRenderSizeChanged?(newRenderSize) }
    }
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        guard !closed, skipInterval.isNumeric, let timeline, let seek = onSeekSourceTime,
              let source = try? timeline.sourceTime(at: currentTime()),
              seekableSourceRange.start.isNumeric, seekableSourceRange.duration.isNumeric,
              seekableSourceRange.duration >= .zero else {
            onFailure?(Failure.unavailableMapping); completionHandler(); return
        }
        let target = min(seekableSourceRange.end, max(seekableSourceRange.start, source + skipInterval))
        let revision = revision
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, !self.closed, self.revision == revision else { return }
            do { try await seek(target) }
            catch is CancellationError { /* A superseding command still completes the OS callback. */ }
            catch { if !self.closed { self.onFailure?(error) } }
            if !self.closed { self.controller.invalidatePlaybackState() }
        }
    }
}

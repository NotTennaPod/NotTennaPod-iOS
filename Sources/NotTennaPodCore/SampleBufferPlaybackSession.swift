import CoreMedia
import Foundation
import AVFoundation

/// The processed playback session for local and streamed media: native presentation,
/// accepted packet checkpoints and source-derived mapping.
@MainActor final class SampleBufferPlaybackSession {
    enum Failure: Error, Equatable { case closed, outOfOrderPacket }
    var state: SampleBufferPCMOutput.State { output.state }
    var wantsPlayback: Bool { output.wantsPlayback }
    var sourceEnded: Bool { output.sourceEnded }
    var failure: (any Error)? { output.failure }
    var writtenFrames: Int64 { output.writtenFrames }
    var presentedFrames: Int64 { output.presentedFrames }
    var pendingCheckpointCount: Int { clock?.pendingCheckpointCount ?? 0 }
    var onChange: (@MainActor () -> Void)?
    var sourceDurationMilliseconds: Int64? { stream?.sourceDurationMilliseconds ?? videoDurationMilliseconds }
    var sourceSeekable: Bool? { stream?.sourceSeekable ?? videoSeekable }
    var videoDisplayLayer: AVSampleBufferDisplayLayer? { video?.displayLayer }
    private(set) var videoPictureInPicture: PlaybackVideoPictureInPicture?
    private(set) var videoTimeline: PlaybackVideoTimeline?
    private(set) var recoveryMediaMicroseconds: Int64?
    private(set) var sourceRestartRequired = false
    private var processingDrained = false
    var mediaMicroseconds: Int64? {
        get throws {
            if state == .playing { frozenMediaMicroseconds = try mappedPosition(); try schedulePlaybackUpdate() }
            return frozenMediaMicroseconds
        }
    }

    let output: SampleBufferPCMOutput
    private let stream: LocalPCMPlaybackStream?
    private let videoSource: (any PlaybackVideoDecoding)?
    private let video: PlaybackVideoPresentation?
    private weak var videoTransport: NativeSampleBufferTransport?
    private let videoDurationMilliseconds: Int64?
    private let videoSeekable: Bool?
    private var audioInputEnded = false
    private var videoTask: Task<Void, Never>?
    private var videoWaiter: CheckedContinuation<Void, Never>?
    private var videoPrepareWaiter: CheckedContinuation<Void, Never>?
    private var videoPrepared = false
    private var videoInputEnded = false
    private var videoCommittedEnd: CMTime = .zero
    private var videoConsumedSourceEnd: CMTime?
    private let volumeTransport: VolumeControlledPCMTransport?
    private var clock: PCMPlaybackClock?
    private var progress: PCMProcessingProgress?
    private var heardSkips = PCMHeardSkipLedger()
    private var segment: LocalPCMPlaybackStream.Segment?
    private var frozenMediaMicroseconds: Int64?
    private var lastState: SampleBufferPCMOutput.State = .idle
    private var refillTask: Task<Void, Error>?
    private var sourceFailureTask: Task<Void, Never>?
    private var bufferStateTask: Task<Void, Never>?
    private var retryPresentation: PCMSourceRetry.Presentation?
    private var observedSourceDuration: Int64?
    private var observedSourceSeekable: Bool?
    private var playbackUpdateTask: Task<Void, Never>?
    private var pendingPlaybackUpdate: PCMPlaybackLoadState?
    private var lastPlaybackUpdate: PCMPlaybackLoadState?
    private var loadingSpeed: Float?
    private var parameterRequest: UInt64 = 0
    private var appliedParameterRequest: UInt64 = 0
    private var closed = false

    init(stream: LocalPCMPlaybackStream?, transport: any PCMPresentationTransport, maximumQueuedBuffers: Int = 4,
         starvationResumeSeconds: Double = 0, videoSource: (any PlaybackVideoDecoding)? = nil, videoTransport: NativeSampleBufferTransport? = nil,
         videoDurationMilliseconds: Int64? = nil, videoSeekable: Bool? = nil) throws {
        self.stream = stream
        self.videoSource = videoSource
        self.videoTransport = videoTransport
        self.videoDurationMilliseconds = videoDurationMilliseconds; self.videoSeekable = videoSeekable
        if videoSource != nil {
            guard let videoTransport else { throw Failure.outOfOrderPacket }
            video = try videoTransport.attachVideo(displayLayer: AVSampleBufferDisplayLayer())
            videoTimeline = try PlaybackVideoTimeline()
        } else { video = nil }
        volumeTransport = transport as? VolumeControlledPCMTransport
        output = try SampleBufferPCMOutput(transport: transport, sampleRate: stream?.sampleRate ?? 48000,
            channels: stream?.channels ?? 1, maximumFrames: stream?.maximumOutputFrames ?? 4096, maximumQueuedBuffers: maximumQueuedBuffers)
        output.onChange = { [weak self] in self?.outputChanged() }
        output.starvationResumeFrames = Int64(starvationResumeSeconds * Double(stream?.sampleRate ?? 48000))
        if let video {
            try output.requireAdditionalPresentation()
            video.onCapacityChanged = { [weak self] in self?.wakeVideo() }
            video.onFailure = { [weak self] error in self?.output.abort(error) }
            videoPictureInPicture = PlaybackVideoPictureInPicture(displayLayer: video.displayLayer, currentTime: { [weak videoTransport] in
                videoTransport?.currentTime ?? .invalid
            })
        }
        if let bufferState = stream?.bufferState {
            retryPresentation = bufferState.sourceRetry?.claimPresentation()
            observedSourceDuration = bufferState.snapshot.durationMicroseconds
            observedSourceSeekable = bufferState.snapshot.sourceSeekable
            output.canStartPlayback = { [weak self] rebuffering in
                guard let self else { return false }
                return try self.canStartPlayback(rebuffering: rebuffering)
            }
            let events = bufferState.events()
            bufferStateTask = Task { @MainActor [weak self] in
                for await _ in events {
                    guard !Task.isCancelled, let self, !self.closed, self.failure == nil else { return }
                    if self.handleDrainedSource() { return }
                    do { try self.output.refreshReadiness() }
                    catch { self.output.abort(error); return }
                    let duration = bufferState.snapshot.durationMicroseconds
                    let seekable = bufferState.snapshot.sourceSeekable
                    if self.observedSourceDuration != duration || self.observedSourceSeekable != seekable {
                        self.observedSourceDuration = duration
                        self.observedSourceSeekable = seekable
                        self.onChange?()
                    }
                }
            }
        }
        if let sourceFailure = stream?.sourceFailure {
            let events = sourceFailure.events()
            sourceFailureTask = Task { @MainActor [weak self] in
                for await error in events {
                    guard !Task.isCancelled, let self, !self.closed else { return }
                    self.output.abort(error)
                }
            }
        }
    }

    isolated deinit {
        videoTask?.cancel(); videoWaiter?.resume(); videoPrepareWaiter?.resume()
        videoPictureInPicture?.close()
        bufferStateTask?.cancel()
        playbackUpdateTask?.cancel()
        sourceFailureTask?.cancel()
        refillTask?.cancel()
        output.onChange = nil
        output.close()
        let stream = stream, videoSource = videoSource
        Task { await stream?.cancel(); await videoSource?.cancelVideo() }
    }

    func prepare() async throws {
        try validate()
        startVideo()
        try await withTaskCancellationHandler {
            try await startRefill().value
            try validate()
            if stream == nil && !videoPrepared {
                await withCheckedContinuation { videoPrepareWaiter = $0 }
                try validate()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    /// Applied when called: the renderer attenuates now; a boost applies to audio processed from now on.
    /// Synchronous and independent of the caller's task, so a cancelled caller cannot fail playback.
    func setVolumeAdaptation(_ setting: FeedVolumeAdaptation, baseVolume: Float = 1) throws {
        guard !closed else { throw Failure.closed }
        if let failure { throw failure }
        guard let volumeTransport else {
            guard setting == .off && baseVolume == 1 else { throw PlaybackVolumeError.unsupportedEngine }
            return
        }
        do { try volumeTransport.setVolume(setting, baseVolume: baseVolume) }
        catch { throw failure ?? error }
    }

    func play() throws {
        try validate()
        startVideo()
        try output.play()
        if handleDrainedSource() { return }
        if !closed && failure == nil && !sourceEnded { _ = startRefill() }
    }

    func pause() throws { try validate(); try output.pause() }

    func setParameters(speed: Float, skipSilence: Bool) async throws {
        try validate()
        if stream == nil {
            try output.setPresentationRate(speed)
            loadingSpeed = speed
            updatePictureInPicture()
            return
        }
        parameterRequest &+= 1
        let request = parameterRequest
        try await stream?.setParameters(speed: speed, skipSilence: skipSilence)
        try validate()
        guard request >= appliedParameterRequest else { return }
        appliedParameterRequest = request
        loadingSpeed = speed
        if state == .playing { frozenMediaMicroseconds = try mappedPosition() }
        try schedulePlaybackUpdate()
        try output.refreshReadiness()
    }

    func close() {
        guard !closed else { return }
        closed = true
        videoTask?.cancel(); videoTask = nil
        wakeVideo(); videoPrepareWaiter?.resume(); videoPrepareWaiter = nil
        videoPictureInPicture?.close()
        bufferStateTask?.cancel(); bufferStateTask = nil
        retryPresentation = nil
        cancelPlaybackUpdates()
        sourceFailureTask?.cancel()
        sourceFailureTask = nil
        refillTask?.cancel()
        refillTask = nil
        output.close()
        let stream = stream, videoSource = videoSource
        Task { await stream?.cancel(); await videoSource?.cancelVideo() }
    }

    /// Pull video independently of PCM. A frame awaiting future committed audio
    /// mapping retains just that frame; it never blocks the audio decoder's pull.
    private func startVideo() {
        guard videoTask == nil, let source = videoSource, let video else { return }
        let generation = video.generation
        videoTask = Task { @MainActor [weak self] in
            do {
                while let frame = try await source.nextVideoFrame() {
                    try Task.checkCancellation()
                    try self?.validate()
                    guard frame.sourceRange.start.isNumeric, frame.sourceRange.duration.isNumeric,
                          frame.sourceRange.start >= .zero, frame.sourceRange.duration > .zero else {
                        throw PlaybackVideoPresentation.Failure.invalidFrame
                    }
                    while self?.videoMappingCovers(frame.sourceRange) == false {
                        try self?.extendVideoTail(through: frame.sourceRange)
                        if self?.videoMappingCovers(frame.sourceRange) == true { break }
                        await withCheckedContinuation { [weak self] continuation in
                            guard let self else { continuation.resume(); return }
                            self.videoWaiter = continuation
                        }
                        try self?.validate()
                    }
                    guard let timeline = self?.videoTimeline, let covered = timeline.sourceRange else { return }
                    // Decoder preroll may precede the requested source anchor.
                    let clipped = CMTimeRangeGetIntersection(frame.sourceRange, otherRange: covered)
                    if clipped.duration > .zero {
                        for range in try self?.renderRanges(for: clipped, timeline: timeline) ?? [] {
                            while true {
                                do {
                                    try await video.enqueue(frame.pixelBuffer, presentation: range, generation: generation)
                                    break
                                } catch PlaybackVideoPresentation.Failure.full {
                                    await withCheckedContinuation { [weak self] continuation in
                                        guard let self else { continuation.resume(); return }
                                        self.videoWaiter = continuation
                                    }
                                    try self?.validate()
                                }
                            }
                            guard let self else { return }
                            self.videoCommittedEnd = max(self.videoCommittedEnd, range.end)
                            try self.output.commitAdditionalPresentation(through: self.videoCommittedEnd)
                            self.markVideoPrepared()
                        }
                    }
                    self?.videoConsumedSourceEnd = frame.sourceRange.end
                    self?.retireVideoSpans()
                }
                if !video.hasSubmittedImage, let poster = await source.videoPosterFrame() {
                    try self?.validate()
                    try video.showPoster(poster.pixelBuffer, generation: generation)
                }
                guard let self else { return }
                try self.validate()
                try video.finishEnqueuing(generation: generation)
                self.videoInputEnded = true
                try self.output.commitAdditionalPresentation(through: self.videoCommittedEnd, finished: true)
                self.markVideoPrepared()
            } catch {
                guard let self, !self.closed else { return }
                self.markVideoPrepared()
                self.output.abort(error)
            }
        }
    }

    /// One decoded picture spanning several processing intervals still needs one
    /// presentation interval. Timestamp both endpoints on the actual PCM output
    /// grid, avoiding fractional-rounding overlaps between neighboring pictures.
    private func renderRanges(for source: CMTimeRange, timeline: PlaybackVideoTimeline) throws -> [CMTimeRange] {
        let ranges = try timeline.presentationRanges(for: source)
        let scale = Int32(stream?.sampleRate ?? 60000)
        let mappedStart = try ranges.first?.start ?? timeline.presentationTime(at: source.start)
        let mappedEnd = try ranges.last?.end ?? timeline.presentationTime(at: source.end)
        let start = CMTimeConvertScale(mappedStart, timescale: scale, method: .roundHalfAwayFromZero)
        let end = CMTimeConvertScale(mappedEnd, timescale: scale, method: .roundHalfAwayFromZero)
        guard end > start, !ranges.isEmpty else { return [] }
        return [CMTimeRange(start: start, end: end)]
    }

    /// Transfer ownership before closing an old generation. The retained controller
    /// keeps its last image and finite frozen range while the next source prepares.
    func takePictureInPictureForReplacement() -> PlaybackVideoPictureInPicture? {
        let result = videoPictureInPicture
        videoPictureInPicture = nil
        result?.suspendForReplacement()
        return result
    }

    /// Failure/cancellation leaves ownership with the caller. AVKit permits an
    /// active content-source replacement only once the new layer is display-ready.
    func adoptPictureInPicture(_ retained: PlaybackVideoPictureInPicture, didAdopt: @MainActor () -> Void = {}) async throws {
        try validate()
        guard let video, let transport = videoTransport else {
            retained.close(); didAdopt(); return
        }
        while !video.displayLayer.isReadyForDisplay {
            if videoInputEnded && !video.hasSubmittedImage {
                // A valid seek at/past picture EOF has no source to adopt. Never
                // trap valid audio/completion waiting for an image that cannot arrive.
                retained.close()
                didAdopt()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
            try validate()
        }
        try validate()
        // No suspension between the final generation check and ownership commit.
        videoPictureInPicture?.close()
        try retained.replacePresentation(displayLayer: video.displayLayer, currentTime: { [weak transport] in transport?.currentTime ?? .invalid })
        videoPictureInPicture = retained
        didAdopt()
        updatePictureInPicture()
    }

    private func videoMappingCovers(_ source: CMTimeRange) -> Bool {
        guard let covered = videoTimeline?.sourceRange else { return false }
        return source.end <= covered.end
    }

    /// Audio's committed map remains authoritative while audio exists. Beyond its
    /// EOF there is no silence decision left to await: map the video tail at the
    /// selected speed. With no audio receiver, native host time drives identity PTS.
    private func extendVideoTail(through source: CMTimeRange) throws {
        guard audioInputEnded else { return }
        retireVideoSpans(reserving: 1)
        guard var timeline = videoTimeline else { return }
        let start = timeline.sourceRange?.end ?? source.start
        guard source.end > start else { return }
        let outputStart = timeline.presentationRange?.end ?? .zero
        let duration = source.end - start
        let outputDuration = stream == nil ? duration : CMTimeMultiplyByFloat64(duration, multiplier: 1 / Double(loadingSpeed ?? 1))
        try timeline.append(.init(source: CMTimeRange(start: start, end: source.end),
            presentation: CMTimeRange(start: outputStart, duration: outputDuration)))
        videoTimeline = timeline
        if frozenMediaMicroseconds == nil {
            frozenMediaMicroseconds = CMTimeConvertScale(start, timescale: 1_000_000, method: .roundTowardZero).value
        }
        updatePictureInPicture()
    }

    private func commitVideoSpans(_ spans: [PlaybackVideoTimeline.Span]) throws {
        guard var timeline = videoTimeline else { return }
        retireVideoSpans(reserving: spans.count)
        timeline = videoTimeline ?? timeline
        for span in spans { try timeline.append(span, sourceDiscontinuity: timeline.spans.last?.source.end != span.source.start) }
        videoTimeline = timeline
        wakeVideo()
        updatePictureInPicture()
    }

    private func retireVideoSpans(reserving count: Int = 0) {
        guard let map = videoTimeline, map.spans.count + count > map.maximumSpans else { return }
        // Retain every recoverable committed interval until the bounded history
        // needs space. Never guess a discarded earlier recovery position.
        let consumedTime: CMTime
        if videoInputEnded { consumedTime = output.presentationTime }
        else if let consumed = videoConsumedSourceEnd, let mapped = try? map.presentationTime(at: consumed) { consumedTime = mapped }
        else { return }
        videoTimeline?.retire(before: min(output.presentationTime, consumedTime))
    }

    private func wakeVideo() { videoWaiter?.resume(); videoWaiter = nil }
    private func markVideoPrepared() {
        videoPrepared = true
        videoPrepareWaiter?.resume(); videoPrepareWaiter = nil
    }
    private func updatePictureInPicture() {
        guard let videoTimeline else { return }
        let seekRange: CMTimeRange
        if sourceSeekable != false, let duration = sourceDurationMilliseconds {
            seekRange = CMTimeRange(start: .zero, duration: CMTime(value: duration, timescale: 1000))
        } else { seekRange = .invalid }
        videoPictureInPicture?.update(timeline: videoTimeline, seekableSourceRange: seekRange, paused: state != .playing)
    }

    private func startRefill() -> Task<Void, Error> {
        if let refillTask { return refillTask }
        let stream = stream
        // Do not retain the session across blocked decoding/native enqueue. Deinitialization
        // must be able to cancel/flush those operations even without an explicit close call.
        let task = Task { @MainActor [weak self] in
            defer { self?.refillTask = nil }
            do {
                guard let stream else {
                    self?.audioInputEnded = true
                    try self?.output.finishEnqueuing()
                    self?.wakeVideo()
                    return
                }
                if self?.videoTimeline != nil && self?.clock == nil { try await stream.enableVideoTimeline() }
                let initial = await stream.segment
                try self?.initialize(initial)
                while self?.needsRefill == true {
                    let packet = try await stream.nextPacket()
                    guard let output = self?.output else { throw Failure.closed }
                    try self?.validate()
                    guard let packet else {
                        let progress = try await stream.progress
                        let spans = await stream.takeFinalVideoTimelineSpans()
                        let skips = await stream.takeFinalHeardSkips()
                        try self?.commitVideoSpans(spans)
                        self?.heardSkips.append(skips)
                        self?.audioInputEnded = true
                        try self?.finish(progress)
                        break
                    }
                    guard packet.outputStartFrame == output.writtenFrames else { throw Failure.outOfOrderPacket }
                    try await output.enqueue(packet.samples) { [weak self] in
                        guard let self else { throw Failure.closed }
                        try self.accept(packet)
                    }
                }
            } catch {
                let failure = self?.failure ?? error
                self?.output.abort(failure)
                throw failure
            }
        }
        refillTask = task
        return task
    }

    private var needsRefill: Bool {
        stream != nil && !closed && failure == nil && !sourceEnded && !processingDrained && output.availableBufferCount > 0
    }

    private func initialize(_ initial: LocalPCMPlaybackStream.Segment) throws {
        try validate()
        guard clock == nil else { return }
        segment = initial
        let anchor = initial.mediaStartMicroseconds
        clock = try PCMPlaybackClock(sampleRate: stream?.sampleRate ?? 48000, mediaMicroseconds: anchor, speed: initial.parameters.speed)
        heardSkips.beginSegment(at: initial.outputStartFrame)
        frozenMediaMicroseconds = anchor
        if loadingSpeed == nil { loadingSpeed = initial.parameters.speed }
        try schedulePlaybackUpdate()
    }

    private func accept(_ packet: LocalPCMPlaybackStream.Packet) throws {
        try validate()
        guard packet.outputStartFrame + Int64(packet.samples.count / (stream?.channels ?? 1)) == writtenFrames else {
            throw Failure.outOfOrderPacket
        }
        if packet.segment.id != segment?.id {
            guard packet.segment.outputStartFrame == packet.outputStartFrame else { throw Failure.outOfOrderPacket }
            // Mutate the current clock here, after acceptance. A copy made before awaiting
            // enqueue would overwrite position/checkpoint progress from intervening playback.
            try clock?.enqueueCheckpoint(outputFrame: packet.outputStartFrame,
                mediaMicroseconds: packet.segment.mediaStartMicroseconds, speed: packet.segment.parameters.speed)
            heardSkips.beginSegment(at: packet.segment.outputStartFrame)
        }
        segment = packet.segment
        progress = packet.progress
        heardSkips.append(packet.heardSkips)
        try commitVideoSpans(packet.videoTimelineSpans)
    }

    private func finish(_ progress: PCMProcessingProgress) throws {
        try validate()
        self.progress = progress // Includes a final skipped-only tail that emitted no packet.
        if let retry = stream?.bufferState?.sourceRetry,
           retry.requiresDeferredRestart || retry.committedError != nil {
            // Decoder EOF drains its period, including Sonic/silence tails. It
            // does not finish the episode or clear the user's playback intent.
            processingDrained = true
            frozenMediaMicroseconds = try mappedPosition()
            // The retry needs the drained output first: a short remaining piece after a stall plays now.
            if !handleDrainedSource() { try output.drainBeforeRetry() }
        } else { try output.finishEnqueuing() }
    }

    private func outputChanged() {
        wakeVideo()
        updatePictureInPicture()
        if state == .closed { onChange?(); return }
        if state == .failed {
            bufferStateTask?.cancel(); bufferStateTask = nil
            retryPresentation = nil
            cancelPlaybackUpdates()
            sourceFailureTask?.cancel()
            sourceFailureTask = nil
            if let frame = output.recoveryFrame, let progress, let clock {
                // The flush may precede a consumed parameter checkpoint. Map its retained
                // sink history without rewinding the published presentation position.
                recoveryMediaMicroseconds = try? clock.recoveryPosition(presentedFrames: frame,
                    writtenFrames: writtenFrames, progress: progress.hearing(skippedFrames:
                        heardSkips.skippedFrames(heardThrough: min(frame, writtenFrames))), committedTimeline: videoTimeline)
            }
            refillTask?.cancel()
            let stream = stream, videoSource = videoSource
            videoTask?.cancel(); videoTask = nil
            videoPrepareWaiter?.resume(); videoPrepareWaiter = nil
            Task { await stream?.cancel(); await videoSource?.cancelVideo() }
            lastState = state
            onChange?()
            return
        }
        do {
            // Pause/buffering freezes once, before new producer statistics can alter it.
            if state == .playing || state == .ended || lastState == .playing {
                frozenMediaMicroseconds = try mappedPosition()
            }
            try schedulePlaybackUpdate()
        } catch { output.abort(error); return }
        if handleDrainedSource() { return }
        lastState = state
        onChange?()
        if needsRefill && refillTask == nil { _ = startRefill() }
    }

    private func handleDrainedSource() -> Bool {
        guard !closed, failure == nil, presentedFrames == writtenFrames,
              let buffer = stream?.bufferState, let retry = buffer.sourceRetry else { return false }
        if retry.requiresDeferredRestart {
            guard processingDrained, wantsPlayback, !sourceRestartRequired else { return sourceRestartRequired }
            sourceRestartRequired = true
            onChange?()
            return true
        }
        if let error = retry.committedError {
            guard processingDrained else { return false }
            output.abort(error)
            return true
        }
        let state = buffer.snapshot
        if state.isWaitingForSamples && state.isWaitingForSource { retry.commitErrorForDrain() }
        return false
    }

    private func mappedPosition() throws -> Int64? {
        let committed = videoTimeline.flatMap { $0.spans.isEmpty ? nil : $0 }
        if let progress {
            // Skipped silence counts once its removal is heard, not when it is processed.
            let heard = min(presentedFrames, writtenFrames)
            let position = try clock?.position(presentedFrames: presentedFrames, writtenFrames: writtenFrames,
                progress: progress.hearing(skippedFrames: heardSkips.skippedFrames(heardThrough: heard)),
                presentationTime: output.presentationTime, committedTimeline: committed)
            heardSkips.retire(before: heard - Int64(stream?.sampleRate ?? 48000) * 10)
            return position
        }
        if let committed {
            return CMTimeConvertScale(try committed.sourceTime(at: output.presentationTime), timescale: 1_000_000, method: .roundTowardZero).value
        }
        return frozenMediaMicroseconds
    }

    private func canStartPlayback(rebuffering: Bool) throws -> Bool {
        try validate()
        if audioInputEnded { return true }
        guard let bufferState = stream?.bufferState else { return true }
        guard let position = frozenMediaMicroseconds, let loadingSpeed else { return false }
        let ready = presentedFrames < writtenFrames || sourceEnded
        let snapshot = bufferState.snapshot
        // Once the source has a reportable error, requiring another startup
        // threshold would trap the remaining audio behind the deferred error.
        // Drain usable presentation buffers; recovery may still clear the error.
        if ready, snapshot.isUsable,
           bufferState.sourceRetry?.currentError != nil || bufferState.sourceRetry?.requiresDeferredRestart == true { return true }
        return try snapshot.shouldStartPlayback(
            rendererReadyOrEnded: ready,
            positionMicroseconds: position, speed: loadingSpeed, rebuffering: rebuffering)
    }

    /// Keep one in-flight update and one latest snapshot. Native time callbacks must
    /// not build an unbounded actor-task backlog or retain a discarded session.
    private func schedulePlaybackUpdate() throws {
        guard !closed, failure == nil, let position = frozenMediaMicroseconds, let loadingSpeed else { return }
        let update = try PCMPlaybackLoadState(positionMicroseconds: position, speed: loadingSpeed)
        guard update != lastPlaybackUpdate else { return }
        lastPlaybackUpdate = update
        pendingPlaybackUpdate = update
        guard playbackUpdateTask == nil else { return }
        let stream = stream
        playbackUpdateTask = Task { @MainActor [weak self] in
            defer { self?.playbackUpdateTask = nil }
            do {
                while let update = self?.pendingPlaybackUpdate {
                    self?.pendingPlaybackUpdate = nil
                    try Task.checkCancellation()
                    try await stream?.updatePlayback(update)
                }
            } catch {
                guard let self, !self.closed, self.failure == nil else { return }
                self.output.abort(error)
            }
        }
    }

    private func cancelPlaybackUpdates() {
        pendingPlaybackUpdate = nil
        playbackUpdateTask?.cancel()
        playbackUpdateTask = nil
    }


    private func validate() throws {
        guard !closed else { throw Failure.closed }
        if let failure { throw failure }
        if let error = stream?.sourceFailure?.error {
            output.abort(error)
            throw error
        }
        try Task.checkCancellation()
    }
}

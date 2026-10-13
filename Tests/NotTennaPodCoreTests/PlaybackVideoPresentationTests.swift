import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Testing
@testable import NotTennaPodCore
#if canImport(UIKit)
import UIKit
#endif

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct PlaybackVideoPresentationTests {
    private func time(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 48000) }
    private func range(_ start: Double, _ duration: Double) -> CMTimeRange { CMTimeRange(start: time(start), duration: time(duration)) }

    /// Independent fixture: source red/tone[0,.6), removed silence[.6,1.2),
    /// green/tone[1.2,1.8). Audio is explicitly preprocessed here; this verifies
    /// actual native picture presentation on that audio clock, not a DSP oracle.
    @Test(arguments: [0.5, 1.5, 4.0])
    func actualDisplayedColorsFollowProcessedAudioClock(speed: Double) async throws {
        let transport = NativeSampleBufferTransport(muted: true)
        let layer = AVSampleBufferDisplayLayer()
        #if canImport(UIKit)
        let root = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.rootViewController)
        root.loadViewIfNeeded()
        layer.frame = CGRect(x: 10, y: 10, width: 160, height: 100)
        root.view.layer.addSublayer(layer)
        #endif
        defer { transport.close(); layer.removeFromSuperlayer() }
        let video = try transport.attachVideo(displayLayer: layer)
        var map = try PlaybackVideoTimeline()
        try map.append(.init(source: range(0, 0.6), presentation: range(0, 0.6 / speed)))
        try map.append(.init(source: range(0.6, 0.6), presentation: range(0.6 / speed, 0)))
        try map.append(.init(source: range(1.2, 0.6), presentation: range(0.6 / speed, 0.6 / speed)))
        let token = video.generation
        for (source, red) in [(range(0, 0.6), true), (range(1.2, 0.6), false)] {
            for presentation in try map.presentationRanges(for: source) {
                try await video.enqueue(try pixel(red: red), presentation: presentation, generation: token)
            }
        }
        let factory = try PCMSampleBufferFactory(sampleRate: 48000, channels: 1)
        let frames = Int((1.2 / speed * 48000).rounded())
        let producer = Task { @MainActor in
            for start in stride(from: 0, to: frames, by: 4096) {
                let end = min(frames, start + 4096)
                let samples = (start..<end).map { frame -> Int16 in
                    let frequency = frame < frames / 2 ? 440.0 : 880.0
                    return Int16((sin(Double(frame) * frequency * 2 * .pi / 48000) * 4000).rounded())
                }
                try await transport.enqueue(factory.makeBuffer(samples, outputStartFrame: Int64(start)))
                if start == 0 { transport.setPlaying(true, at: .zero) }
            }
            transport.finishEnqueuing()
        }
        defer { producer.cancel() }
        try video.finishEnqueuing(generation: token)
        try await wait { transport.currentTime >= time(0.15 / speed) }
        transport.setRate(0, at: .invalid)
        try await waitDisplayed("displayed red", layer, red: true)
        let first = transport.currentTime
        #expect(try map.sourceTime(at: first) < time(0.6))
        transport.setRate(1, at: .invalid)
        try await wait { transport.currentTime >= time(0.8 / speed) }
        transport.setRate(0, at: .invalid)
        try await waitDisplayed("displayed green", layer, red: false)
        #expect(try map.sourceTime(at: transport.currentTime) >= time(1.2))
        // Finish the bounded producer while playback can relieve native backpressure.
        transport.setRate(1, at: .invalid)
        try await producer.value
        // Seek retires old green frames; actual displayed red verifies replacement.
        try transport.flushAudioAndVideo(at: .zero)
        let next = video.generation
        try await video.enqueue(try pixel(red: true), presentation: range(0, 0.2), generation: next)
        for start in stride(from: 0, to: 9600, by: 4096) {
            try await transport.enqueue(factory.makeBuffer([Int16](repeating: 0, count: min(4096, 9600 - start)), outputStartFrame: Int64(start)))
        }
        try video.finishEnqueuing(generation: next)
        transport.setPlaying(true, at: .zero)
        try await wait { transport.currentTime >= time(0.05) }
        transport.setRate(0, at: .invalid)
        try await waitDisplayed("displayed red", layer, red: true)
        transport.setRate(1, at: .invalid)
        try await wait { video.refresh(); return video.isDrained }
        transport.setPlaying(false, at: time(0.2))
        #expect(video.lastPresentationEnd == time(0.2) && video.queuedFrameCount == 0)
    }

    @Test func pictureInPictureRangeAndSourceSkipUseDifferentTimeDomains() async throws {
        let transport = NativeSampleBufferTransport(muted: true)
        let layer = AVSampleBufferDisplayLayer()
        _ = try transport.attachVideo(displayLayer: layer)
        let pip = PlaybackVideoPictureInPicture(displayLayer: layer, currentTime: { time(0.75) })
        defer { pip.close(); transport.close() }
        var map = try PlaybackVideoTimeline()
        try map.append(.init(source: range(10, 1), presentation: range(0, 0.5)))
        try map.append(.init(source: range(11, 2), presentation: range(0.5, 0)))
        try map.append(.init(source: range(13, 1), presentation: range(0.5, 0.5)))
        pip.update(timeline: map, seekableSourceRange: range(0, 20), paused: true)
        #expect(pip.pictureInPictureControllerTimeRangeForPlayback(pip.controller) == range(0, 1))
        #expect(pip.pictureInPictureControllerIsPlaybackPaused(pip.controller))
        var requested: CMTime?
        var completions = 0
        pip.onSeekSourceTime = { target in requested = target }
        pip.pictureInPictureController(pip.controller, skipByInterval: time(-5), completion: { completions += 1 })
        try await wait { completions == 1 }
        #expect(requested == time(8.5))
        var failures = 0
        pip.onFailure = { _ in failures += 1 }
        pip.onSeekSourceTime = { _ in throw CancellationError() }
        pip.pictureInPictureController(pip.controller, skipByInterval: time(5), completion: { completions += 1 })
        try await wait { completions == 2 }
        #expect(failures == 0)
        pip.onSeekSourceTime = { _ in throw URLError(.cannotDecodeContentData) }
        pip.pictureInPictureController(pip.controller, skipByInterval: time(5), completion: { completions += 1 })
        try await wait { completions == 3 }
        #expect(failures == 1)
        pip.close()
        #expect(!pip.pictureInPictureControllerTimeRangeForPlayback(pip.controller).isValid)
        pip.pictureInPictureController(pip.controller, skipByInterval: time(5), completion: { completions += 1 })
        #expect(completions == 4 && requested == time(8.5))
    }

    actor VideoSource: PlaybackVideoDecoding {
        private var frames: [PlaybackVideoFrame]
        private var poster: PlaybackVideoFrame?
        private(set) var cancelled = false
        init(frames: [PlaybackVideoFrame], poster: PlaybackVideoFrame? = nil) { self.frames = frames; self.poster = poster }
        func nextVideoFrame() -> PlaybackVideoFrame? {
            guard !cancelled, !frames.isEmpty else { return nil }
            return frames.removeFirst()
        }
        func cancelVideo() { cancelled = true; frames.removeAll(); poster = nil }
        func videoPosterFrame() -> PlaybackVideoFrame? { poster }
    }

    @Test func processedSessionRendersSourceMarkersAcrossRemovedSilence() async throws {
        let input: [Int16] = (0..<96000).map { frame in
            if (12000..<84000).contains(frame) { return 0 }
            return Int16((sin(Double(frame) * 2 * .pi * 440 / 48000) * 12000).rounded())
        }
        let frames = try (0..<120).map { index in
            PlaybackVideoFrame(pixelBuffer: try pixel(red: index < 105), sourceRange:
                CMTimeRange(start: CMTime(value: Int64(index), timescale: 60), duration: CMTime(value: 1, timescale: 60)))
        }
        for pair in zip(frames, frames.dropFirst()) { #expect(pair.0.sourceRange.end == pair.1.sourceRange.start) }
        let source = VideoSource(frames: frames)
        let stream = try LocalPCMPlaybackStream(decoder: PlaybackVideoProcessingTests.Decoder(input: input), skipSilence: true, speed: 1.5)
        let transport = NativeSampleBufferTransport(muted: true)
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport,
            videoSource: source, videoTransport: transport, videoDurationMilliseconds: 2000, videoSeekable: true)
        let layer = try #require(session.videoDisplayLayer)
        #if canImport(UIKit)
        let root = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.rootViewController)
        layer.frame = CGRect(x: 10, y: 10, width: 160, height: 100); root.view.layer.addSublayer(layer)
        #endif
        defer { session.close(); layer.removeFromSuperlayer() }
        try await session.prepare(); try session.play()
        try await wait("processed red source time") { ((try? session.mediaMicroseconds) ?? 0) >= 80_000 || session.failure != nil }
        if let failure = session.failure { throw failure }
        try session.pause()
        try await waitDisplayed("processed displayed red", layer, red: true)
        try session.play()
        try await wait("processed green source time") { ((try? session.mediaMicroseconds) ?? 0) >= 1_850_000 || session.failure != nil }
        if let failure = session.failure { throw failure }
        try session.pause()
        try await waitDisplayed("processed displayed green", layer, red: false)
        #expect(session.output.presentationTime < time(1))
        let map = try #require(session.videoTimeline)
        #expect(try map.sourceTime(at: session.output.presentationTime) >= time(1.75))
        try session.play()
        try await wait("processed joint EOF") { session.state == .ended || session.failure != nil }
        if let failure = session.failure { throw failure }
        #expect(try session.mediaMicroseconds == 2_000_000)
    }

    @MainActor final class PiPDelegate: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
        var error: (any Error)?
        func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) { self.error = error }
    }

    @Test func pictureInPictureOwnershipRebindsReadyReplacementWithoutRetiredCommands() async throws {
        try await verifyPictureInPictureReplacement(startSystemPresentation: false)
    }
    // Starting system Picture in Picture needs hardware support; the iOS Simulator reports
    // none, so there this case is reported as skipped (not passed) and is covered by the
    // real-device checklist. The replacement/ownership behaviour without the system
    // presentation is still verified everywhere by the test above.
    @Test(.enabled("System Picture in Picture is unsupported here (Simulator); verified on hardware") {
        await MainActor.run { AVPictureInPictureController.isPictureInPictureSupported() }
    })
    func activePictureInPictureRebindsReadyReplacementWithoutRetiredCommands() async throws {
        try await verifyPictureInPictureReplacement(startSystemPresentation: true)
    }
    private func verifyPictureInPictureReplacement(startSystemPresentation: Bool) async throws {
        #if canImport(UIKit)
        if startSystemPresentation { try #require(AVPictureInPictureController.isPictureInPictureSupported()) }
        let root = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.rootViewController)
        let firstTransport = NativeSampleBufferTransport(muted: true, audioEnabled: false)
        let firstSource = VideoSource(frames: [PlaybackVideoFrame(pixelBuffer: try pixel(red: true), sourceRange: range(0, 5))])
        let first = try SampleBufferPlaybackSession(stream: nil, transport: firstTransport, videoSource: firstSource,
            videoTransport: firstTransport, videoDurationMilliseconds: 5000, videoSeekable: true)
        let oldLayer = try #require(first.videoDisplayLayer)
        oldLayer.frame = CGRect(x: 10, y: 10, width: 160, height: 100); root.view.layer.addSublayer(oldLayer)
        defer { first.close(); oldLayer.removeFromSuperlayer() }
        try await first.prepare(); try first.play()
        let retained = try #require(first.videoPictureInPicture)
        let controller = retained.controller
        let delegate = PiPDelegate(); controller.delegate = delegate
        if startSystemPresentation {
            try await wait("PiP possible") { controller.isPictureInPicturePossible }
            controller.startPictureInPicture()
            try await wait("PiP active") { controller.isPictureInPictureActive || delegate.error != nil }
            if let error = delegate.error { throw error }
            try #require(controller.isPictureInPictureActive)
        } else { try await wait("first source display ready") { oldLayer.isReadyForDisplay } }
        var oldCommands = 0
        retained.onSetPlaying = { _ in oldCommands += 1 }
        let transferred = try #require(first.takePictureInPictureForReplacement())
        first.close()
        #expect(transferred === retained)
        transferred.pictureInPictureController(controller, setPlaying: true)
        #expect(oldCommands == 0)
        let nextTransport = NativeSampleBufferTransport(muted: true, audioEnabled: false)
        let nextSource = VideoSource(frames: [PlaybackVideoFrame(pixelBuffer: try pixel(red: false), sourceRange: range(10, 5))])
        let next = try SampleBufferPlaybackSession(stream: nil, transport: nextTransport, videoSource: nextSource,
            videoTransport: nextTransport, videoDurationMilliseconds: 15000, videoSeekable: true)
        let newLayer = try #require(next.videoDisplayLayer)
        newLayer.frame = oldLayer.frame; root.view.layer.addSublayer(newLayer)
        defer { next.close(); newLayer.removeFromSuperlayer(); retained.close() }
        try await next.prepare()
        let adoption = Task { try await next.adoptPictureInPicture(transferred) }
        defer { adoption.cancel() }
        try await wait("ready PiP replacement") { next.videoPictureInPicture === transferred || next.failure != nil }
        try await adoption.value
        let sameController = next.videoPictureInPicture?.controller === controller
        #expect(sameController)
        #expect(controller.isPictureInPictureActive == startSystemPresentation)
        #expect(transferred.pictureInPictureControllerTimeRangeForPlayback(controller) == range(0, 5))
        try next.play()
        try await wait("replacement source clock") { ((try? next.mediaMicroseconds) ?? 0) > 10_050_000 }
        controller.stopPictureInPicture()
        try await wait("PiP stopped") { !controller.isPictureInPictureActive }
        #endif
    }

    @Test func genuinePosterHoldsThroughAudioTailWithoutExtendingCompletion() async throws {
        let poster = PlaybackVideoFrame(pixelBuffer: try pixel(red: false), sourceRange: range(0.2, 0.1))
        let source = VideoSource(frames: [], poster: poster)
        let stream = try LocalPCMPlaybackStream(decoder: PlaybackVideoProcessingTests.Decoder(
            input: [Int16](repeating: 4000, count: 28800), start: 240000), skipSilence: false)
        let transport = NativeSampleBufferTransport(muted: true)
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport,
            videoSource: source, videoTransport: transport, videoDurationMilliseconds: 5600, videoSeekable: true)
        let layer = try #require(session.videoDisplayLayer)
        #if canImport(UIKit)
        let root = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.rootViewController)
        layer.frame = CGRect(x: 10, y: 10, width: 160, height: 100); root.view.layer.addSublayer(layer)
        #endif
        defer { session.close(); layer.removeFromSuperlayer() }
        try await session.prepare()
        try await wait("actual poster is display ready") { layer.isReadyForDisplay }
        try session.play()
        try await wait("audio tail source time") { ((try? session.mediaMicroseconds) ?? 0) > 5_100_000 || session.failure != nil }
        if let error = session.failure { throw error }
        try session.pause()
        try await waitDisplayed("genuine final green image", layer, red: false)
        #expect(session.output.presentationTime < time(0.6))
        #expect(transport.videoPresentation?.queuedFrameCount == 0)
        try session.play()
        try await wait("audio tail EOF") { session.state == .ended || session.failure != nil }
        if let error = session.failure { throw error }
        #expect(session.writtenFrames == 28800 && session.presentedFrames == 28800)
        #expect(session.output.presentationTime == time(0.6))
        #expect(try session.mediaMicroseconds == 5_600_000)
    }

    @Test(arguments: [0.0, 0.3, 0.9])
    func joinedSessionDrainsUnequalTracksAndVideoOnlyWithoutSilentPCM(audioDuration: Double) async throws {
        let transport = NativeSampleBufferTransport(muted: true, audioEnabled: audioDuration > 0)
        let frames = try (0..<18).map { index in
            PlaybackVideoFrame(pixelBuffer: try pixel(red: index < 9), sourceRange:
                CMTimeRange(start: CMTime(value: Int64(index), timescale: 30), duration: CMTime(value: 1, timescale: 30)))
        }
        for pair in zip(frames, frames.dropFirst()) { #expect(pair.0.sourceRange.end == pair.1.sourceRange.start) }
        let source = VideoSource(frames: frames)
        let stream: LocalPCMPlaybackStream?
        if audioDuration > 0 {
            stream = try LocalPCMPlaybackStream(decoder: PlaybackVideoProcessingTests.Decoder(
                input: [Int16](repeating: 4000, count: Int(audioDuration * 48000))), skipSilence: false)
        } else { stream = nil }
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport,
            videoSource: source, videoTransport: transport, videoDurationMilliseconds: 600, videoSeekable: true)
        defer { session.close() }
        try await session.prepare()
        if audioDuration == 0 { try await session.setParameters(speed: 1.5, skipSilence: false) }
        #expect(session.writtenFrames == 0 || audioDuration > 0)
        try session.play()
        try await wait { session.state == .ended || session.failure != nil }
        if let failure = session.failure { throw failure }
        #expect(session.state == .ended)
        #expect(session.writtenFrames == Int64(audioDuration * 48000))
        #expect(session.presentedFrames == session.writtenFrames)
        #expect(try session.mediaMicroseconds == Int64(max(audioDuration, 0.6) * 1_000_000))
        #expect(session.output.presentationTime == time(max(audioDuration, 0.6)))
        session.close()
        try await wait { session.state == .closed }
    }

    nonisolated private func pixel(red: Bool) throws -> CVReadOnlyPixelBuffer {
        var value: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value)
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(value)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<64 {
            for x in 0..<64 {
                let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                base[offset] = 0; base[offset + 1] = red ? 0 : 255
                base[offset + 2] = red ? 255 : 0; base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return CVReadOnlyPixelBuffer(unsafeBuffer: buffer)
    }
    private func displayedRed(_ layer: AVSampleBufferDisplayLayer) -> Bool? {
        guard let buffer = layer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        if bytes[2] > 200 && bytes[1] < 50 { return true }
        if bytes[1] > 200 && bytes[2] < 50 { return false }
        return nil
    }
    /// The picture a person sees. AVSampleBufferDisplayLayer only produces a displayed
    /// pixel buffer inside a rendering window hierarchy, which the iOS view-test host
    /// provides (the layer is added to the app window above). The macOS `swift test`
    /// runner has no window, so there the picture check is left to the iOS view run on
    /// every device; the host still verifies the audio clock and source-time mapping.
    private func waitDisplayed(_ label: String, _ layer: AVSampleBufferDisplayLayer, red: Bool,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        #if canImport(UIKit)
        try await wait(label, sourceLocation: sourceLocation) { displayedRed(layer) == red }
        #endif
    }
    private func wait(_ label: String = "condition", sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), Comment(rawValue: label), sourceLocation: sourceLocation)
    }
}

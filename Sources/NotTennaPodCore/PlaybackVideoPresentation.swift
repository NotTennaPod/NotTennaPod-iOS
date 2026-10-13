import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation

/// A bounded decoded-picture receiver on the audio transport's synchronizer.
/// Upstream owns decoding, processing spans and joined audio/video end-of-stream.
@MainActor final class PlaybackVideoPresentation {
    enum Failure: Error, Equatable {
        case closed, invalidCapacity, full, concurrentEnqueue, staleGeneration, invalidFrame, finished, rendererNeedsFlush
        case invalidTiming(CMTimeRange)
        case overlappingFrame(previousEnd: CMTime, nextStart: CMTime)
        case invalidPixelStorage(bytes: Int)
    }
    struct Generation: Equatable, Sendable { fileprivate let id = UUID() }
    let displayLayer: AVSampleBufferDisplayLayer
    private(set) var generation = Generation()
    private(set) var sourceEnded = false
    private(set) var hasSubmittedImage = false
    private(set) var enqueueInProgress = false
    private(set) var lastPresentationEnd: CMTime?
    var onCapacityChanged: (@MainActor () -> Void)?
    var onFailure: (@MainActor (any Error) -> Void)?
    var currentTime: CMTime { synchronizer.currentTime() }
    var queuedFrameCount: Int { entries.count }
    var queuedBytes: Int { entries.reduce(0) { $0 + $1.bytes } }
    var isDrained: Bool { sourceEnded && !enqueueInProgress && entries.isEmpty }
    private struct Entry { let end: CMTime; let bytes: Int }
    private var entries: [Entry] = []
    private let maximumQueuedFrames: Int
    private let maximumQueuedBytes: Int
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let receiver: AVSampleBufferVideoRenderer.Receiver
    private var closed = false
    private var monitoringTask: Task<Void, Never>?

    init(synchronizer: AVSampleBufferRenderSynchronizer, displayLayer: AVSampleBufferDisplayLayer,
         maximumQueuedFrames: Int = 12, maximumQueuedBytes: Int = 64 * 1024 * 1024) throws {
        guard (1...120).contains(maximumQueuedFrames), maximumQueuedBytes > 0 else { throw Failure.invalidCapacity }
        self.synchronizer = synchronizer; self.displayLayer = displayLayer
        self.maximumQueuedFrames = maximumQueuedFrames; self.maximumQueuedBytes = maximumQueuedBytes
        receiver = synchronizer.sampleBufferReceiver(adding: displayLayer.sampleBufferRenderer)
    }

    isolated deinit { monitoringTask?.cancel(); receiver.flush() }

    /// Only one bounded submission may suspend at Apple's receiver. A caller must
    /// observe capacity before pulling another decoded frame; this API queues no Tasks.
    func enqueue(_ pixelBuffer: CVReadOnlyPixelBuffer, presentation: CMTimeRange, generation token: Generation) async throws {
        guard !closed else { throw Failure.closed }
        guard token == generation else { throw Failure.staleGeneration }
        guard !sourceEnded else { throw Failure.finished }
        guard !enqueueInProgress else { throw Failure.concurrentEnqueue }
        try Task.checkCancellation()
        refresh()
        guard presentation.start.isNumeric, presentation.start >= .zero,
              presentation.duration.isNumeric, presentation.duration > .zero,
              presentation.end.isNumeric else { throw Failure.invalidTiming(presentation) }
        if let lastPresentationEnd, presentation.start < lastPresentationEnd {
            throw Failure.overlappingFrame(previousEnd: lastPresentationEnd, nextStart: presentation.start)
        }
        let bytes = pixelBuffer.withUnsafeBuffer { CVPixelBufferGetDataSize($0) }
        guard bytes > 0, bytes <= maximumQueuedBytes else { throw Failure.invalidPixelStorage(bytes: bytes) }
        guard entries.count < maximumQueuedFrames, queuedBytes <= maximumQueuedBytes - bytes else { throw Failure.full }
        let buffer = CMReadySampleBuffer(pixelBuffer: pixelBuffer, presentationTimeStamp: presentation.start, duration: presentation.duration)
        enqueueInProgress = true
        defer { enqueueInProgress = false }
        do {
            let result = try await receiver.enqueue(CMReadySampleBuffer(buffer))
            guard !closed else { throw Failure.closed }
            guard token == generation else { throw Failure.staleGeneration }
            try Task.checkCancellation()
            switch result {
            case .enqueued: break
            case .enqueuedWithDecodeFailures(let errors): throw errors.first ?? Failure.rendererNeedsFlush
            case .cancelledDueToFlush: throw Failure.rendererNeedsFlush
            case .cancelledDueToFlushRequiredToResume(let error), .cancelledDueToError(let error): throw error
            @unknown default: throw Failure.rendererNeedsFlush
            }
            entries.append(Entry(end: presentation.end, bytes: bytes))
            lastPresentationEnd = presentation.end
            hasSubmittedImage = true
        } catch {
            // Accepted-then-cancelled data cannot remain in an otherwise usable queue.
            if !closed && token == generation { invalidate(); onFailure?(error) }
            throw error
        }
    }

    /// One genuine decoded EOF poster can hold the picture through an audio tail.
    /// An unspecified image duration and no queue horizon keep it out of timed EOF
    /// accounting; this does not invent source frames or advance either clock.
    func showPoster(_ pixelBuffer: CVReadOnlyPixelBuffer, generation token: Generation) throws {
        guard !closed else { throw Failure.closed }
        guard token == generation else { throw Failure.staleGeneration }
        guard !sourceEnded && !enqueueInProgress && !hasSubmittedImage else { throw Failure.finished }
        let bytes = pixelBuffer.withUnsafeBuffer { CVPixelBufferGetDataSize($0) }
        guard bytes > 0, bytes <= maximumQueuedBytes else { throw Failure.invalidPixelStorage(bytes: bytes) }
        var buffer = CMReadySampleBuffer(pixelBuffer: pixelBuffer, presentationTimeStamp: currentTime)
        buffer.sampleAttachments.displayImmediately = true
        switch receiver.enqueueImmediately(CMReadySampleBuffer(buffer)) {
        case .enqueued: hasSubmittedImage = true
        case .enqueuedWithDecodeFailures(let errors): throw errors.first ?? Failure.rendererNeedsFlush
        case .cancelledDueToFlush: throw Failure.rendererNeedsFlush
        case .cancelledDueToFlushRequiredToResume(let error), .cancelledDueToError(let error): throw error
        @unknown default: throw Failure.rendererNeedsFlush
        }
    }

    func finishEnqueuing(generation token: Generation) throws {
        guard !closed else { throw Failure.closed }
        guard token == generation else { throw Failure.staleGeneration }
        guard !enqueueInProgress else { throw Failure.concurrentEnqueue }
        guard !sourceEnded else { return }
        sourceEnded = true
        let events = receiver.renderingEventsAfterFinishedEnqueuing
        monitoringTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, !self.closed, self.generation == token else { return }
                let error: any Error
                switch event {
                case .didFailToDecode(let errors): error = errors.first ?? Failure.rendererNeedsFlush
                case .requiresFlushToResumeDecoding(let value), .failed(let value): error = value
                @unknown default: error = Failure.rendererNeedsFlush
                }
                self.invalidate(); self.onFailure?(error); return
            }
        }
        refresh()
    }

    /// Queue accounting only. Rendered-picture assertions must inspect native output;
    /// this clock-based drain is not an acoustic or pixel-rendering measurement.
    func refresh() {
        guard !closed else { return }
        let time = currentTime
        guard time.isNumeric else { return }
        let oldCount = entries.count
        entries.removeAll { $0.end <= time }
        if entries.count != oldCount { onCapacityChanged?() }
    }

    /// Called only for a joined seek/replacement; gain changes never flush.
    func invalidate() {
        guard !closed else { return }
        generation = Generation()
        monitoringTask?.cancel(); monitoringTask = nil
        receiver.flush()
        entries.removeAll(); lastPresentationEnd = nil; sourceEnded = false; hasSubmittedImage = false
        onCapacityChanged?()
    }

    func close() {
        guard !closed else { return }
        closed = true; generation = Generation()
        monitoringTask?.cancel(); monitoringTask = nil
        onCapacityChanged = nil; onFailure = nil
        receiver.flush(); entries.removeAll()
        // Receiver attachment has the transport's lifetime. Releasing the closed
        // transport releases its synchronizer and renderer together; do not transfer
        // a still-referenced receiver into removeReceiver's sending parameter.
    }
}

import CoreMedia
import Foundation

/// A presentation receiver with an output volume, applied at once to the audio being presented,
/// without stopping, flushing or re-timing anything (`AVSampleBufferAudioRenderer.volume`).
@MainActor protocol PCMVolumePresentationTransport: PCMPresentationTransport {
    func setRendererVolume(_ volume: Float)
}

/// Volume adaptation and the sleep-timer fade, split the way Android's `applyVolumeAdaption` splits
/// them: the attenuation `min(1, v)` goes to the renderer when commanded, and the LoudnessEnhancer
/// boost applies to the PCM processed from then on (`PodcastVolumeStage`, joined by a short ramp).
/// Queued audio is never flushed, re-processed or compensated; seek and recovery build a new output
/// that starts with the current values. Speed/silence processing and media checkpoints stay upstream.
@MainActor final class VolumeControlledPCMTransport: PCMPresentationTransport {
    enum Failure: Error, Equatable { case closed, concurrentEnqueue, invalidPacket }
    var onTimeChanged: (@MainActor () -> Void)?
    var onFailure: (@MainActor (any Error) -> Void)?
    var currentTime: CMTime { backend.currentTime }
    private(set) var setting: FeedVolumeAdaptation
    private(set) var baseVolume: Float
    private let backend: any PCMVolumePresentationTransport
    private let factory: PCMSampleBufferFactory
    private var stage: PodcastVolumeStage
    private var enqueueInProgress = false
    private var closed = false

    init(backend: any PCMVolumePresentationTransport, sampleRate: Int, channels: Int, maximumFrames: Int = 4096,
         setting: FeedVolumeAdaptation = .off, baseVolume: Float = 1) throws {
        factory = try PCMSampleBufferFactory(sampleRate: sampleRate, channels: channels, maximumFrames: maximumFrames)
        self.backend = backend; self.setting = setting
        self.baseVolume = baseVolume
        let effect = setting.effect(baseVolume: baseVolume)
        stage = PodcastVolumeStage(target: .init(effect, attenuate: false), sampleRate: Double(sampleRate))
        // Before the first enqueue: every renderer starts at the current value.
        backend.setRendererVolume(effect.attenuation)
        backend.onTimeChanged = { [weak self] in
            guard let self, !self.closed else { return }
            self.onTimeChanged?()
        }
        backend.onFailure = { [weak self] error in self?.fail(error) }
    }

    isolated deinit {
        backend.onTimeChanged = nil; backend.onFailure = nil; backend.close()
    }

    func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {
        try validate()
        guard !enqueueInProgress else { throw Failure.concurrentEnqueue }
        enqueueInProgress = true
        defer { enqueueInProgress = false }
        let start = try validatePacket(buffer)
        if stage.isIdentity {
            stage.skip()
            try await backend.enqueue(buffer)
        } else {
            try await backend.enqueue(try process(buffer, start: start))
        }
        try validate()
    }

    /// Every command reaches the renderer, which applies the attenuation to what is heard now. The
    /// boost (and the enhancer switching off) applies to audio processed after this call.
    func setVolume(_ setting: FeedVolumeAdaptation, baseVolume: Float = 1) throws {
        try validate()
        self.setting = setting
        self.baseVolume = baseVolume
        let effect = setting.effect(baseVolume: baseVolume)
        backend.setRendererVolume(effect.attenuation)
        stage.setTarget(.init(effect, attenuate: false))
    }

    func setPlaying(_ playing: Bool, at time: CMTime) { if !closed { backend.setPlaying(playing, at: time) } }
    func observeEnd(_ time: CMTime) { if !closed { backend.observeEnd(time) } }
    func finishEnqueuing() { if !closed { backend.finishEnqueuing() } }
    func stopMonitoring() { backend.stopMonitoring() }
    func setRefreshInterval(_ interval: CMTime) { backend.setRefreshInterval(interval) }
    func close() {
        guard !closed else { return }
        closed = true
        backend.onTimeChanged = nil; backend.onFailure = nil; backend.close()
    }
    private func fail(_ error: any Error) {
        guard !closed else { return }
        let observer = onFailure
        close()
        observer?(error)
    }
    private func validate() throws { guard !closed else { throw Failure.closed } }
    private func validatePacket(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) throws -> Int64 {
        let time = buffer.presentationTimeStamp
        guard buffer.formatDescription == factory.formatDescription,
              time.isNumeric, time >= .zero, buffer.sampleCount > 0, buffer.sampleCount <= factory.maximumFrames,
              buffer.duration == CMTime(value: Int64(buffer.sampleCount), timescale: Int32(factory.sampleRate)),
              buffer.content.withContiguousStorageIfAvailable({ $0.count }) == buffer.sampleCount * factory.channels * 2
        else { throw Failure.invalidPacket }
        let frame = CMTimeConvertScale(time, timescale: Int32(factory.sampleRate), method: .roundTowardZero)
        guard frame == time else { throw Failure.invalidPacket }
        return frame.value
    }
    private func process(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>, start: Int64) throws -> CMReadySampleBuffer<CMReadOnlyDataBlockBuffer> {
        let channels = factory.channels
        var samples = [Int16](repeating: 0, count: buffer.sampleCount * channels)
        _ = buffer.content.withContiguousStorageIfAvailable { bytes in
            samples.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(bytes)) }
        }
        for frame in 0..<buffer.sampleCount {
            let first = frame * channels
            var peak: Float = 0
            for channel in 0..<channels { peak = max(peak, abs(Float(samples[first + channel]) / 32768)) }
            let gains = stage.frame(peak: peak)
            for channel in 0..<channels {
                let value = stage.output(Float(samples[first + channel]) / 32768, gains)
                samples[first + channel] = Int16(clamping: Int(max(-1, min(1, value)) * 32768))
            }
        }
        return try factory.makeBuffer(samples, outputStartFrame: start)
    }
}

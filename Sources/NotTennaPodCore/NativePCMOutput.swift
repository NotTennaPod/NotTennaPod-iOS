import AVFoundation
import Foundation
import NativePCMTransport

/// Bounded native PCM output transport. The owner supplies media-time mapping and decoding.
/// Rate and silence processing belong upstream; this graph preserves supplied PCM at 1x.
@MainActor public final class NativePCMOutput {
    public enum Mode: Sendable { case device, offline }
    public enum Failure: Error, Equatable {
        case invalidFormat, invalidCapacity, invalidFrames, queueFull, emptyQueue, notOffline, notPlaying
    }
    public let sampleRate: Int
    public let channels: Int
    public let bufferCapacity: Int
    public let maximumQueuedBuffers: Int
    public var onBufferCompleted: (@MainActor (UUID) -> Void)?
    public private(set) var scheduledFrames: Int64 = 0
    public private(set) var queuedFrames: Int64 = 0
    public private(set) var wantsPlayback = false
    public var queuedBufferCount: Int { pending.count }
    public var availableBufferCount: Int { maximumQueuedBuffers - pending.count }
    /// Source-consumed frames, capped by returned PCM in manual mode. This is not the
    /// hardware presentation clock; the candidate session rejects device mode until verified.
    public var renderedFrames: Int64 {
        let consumed = Int64(source?.consumedFrames ?? 0)
        return mode == .offline ? min(consumed, offlineRenderedFrames) : consumed
    }

    var isEngineRunning: Bool { engine.isRunning }
    private let mode: Mode
    private let format: AVAudioFormat
    private var engine = AVAudioEngine()
    private var source: APPCMSource?
    private var completionPump: Task<Void, Never>?
    private var epoch = UUID()
    private struct Buffer { let frames: Int; let endFrame: Int64 }
    private var pending: [UUID: Buffer] = [:]
    private var completionsSubmitted: Set<UUID> = []
    private var offlineRenderedFrames: Int64 = 0

    public init(sampleRate: Int, channels: Int, mode: Mode,
                bufferCapacity: Int = 4096, maximumQueuedBuffers: Int = 4) throws {
        guard (1...768_000).contains(sampleRate), (1...32).contains(channels) else {
            throw Failure.invalidFormat
        }
        let tag = channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2
            ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { throw Failure.invalidFormat }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channelLayout: layout)
        guard (1...65_536).contains(bufferCapacity), (1...64).contains(maximumQueuedBuffers) else {
            throw Failure.invalidCapacity
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.mode = mode
        self.bufferCapacity = bufferCapacity
        self.maximumQueuedBuffers = maximumQueuedBuffers
        self.format = format
        try ensureSource()
    }

    isolated deinit { completionPump?.cancel(); engine.stop() }

    /// Returns an identity for source-buffer completion, not hardware presentation. Refill
    /// remains continuous after starvation; silence supplied during starvation does not count
    /// as media frames. A full queue rejects the entire packet before copying any samples.
    @discardableResult public func enqueue(_ samples: [Int16]) throws -> UUID {
        guard !samples.isEmpty, samples.count.isMultiple(of: channels),
              samples.count / channels <= bufferCapacity else { throw Failure.invalidFrames }
        guard pending.count < maximumQueuedBuffers else { throw Failure.queueFull }
        try ensureSource()
        let frames = samples.count / channels
        let accepted = samples.withUnsafeBufferPointer { source!.enqueue($0.baseAddress!, frames: UInt32(frames)) }
        guard accepted else { throw Failure.queueFull }
        let id = UUID()
        scheduledFrames += Int64(frames)
        queuedFrames += Int64(frames)
        pending[id] = Buffer(frames: frames, endFrame: scheduledFrames)
        return id
    }

    private func ensureSource() throws {
        guard source == nil else { return }
        guard let next = APPCMSource(sampleRate: Double(sampleRate), channels: UInt32(channels),
                                     capacityFrames: UInt32(bufferCapacity * maximumQueuedBuffers)) else {
            throw Failure.invalidCapacity
        }
        engine.attach(next.node)
        do {
            try engine.connectNode(next.node, to: engine.mainMixerNode, format: format)
            if mode == .offline {
                try engine.enableManualRenderingMode(.offline, format: format,
                                                    maximumFrameCount: AVAudioFrameCount(bufferCapacity))
                try engine.connectNode(engine.mainMixerNode, to: engine.outputNode, format: format)
            }
        }
        catch { engine.detach(next.node); throw error }
        source = next
    }

    public func play() throws {
        guard !pending.isEmpty else { throw Failure.emptyQueue }
        if !engine.isRunning { try engine.start() }
        wantsPlayback = true
        if mode == .device && completionPump == nil {
            completionPump = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) }
                    catch { return }
                    guard let self else { return }
                    self.submitConsumedBuffers()
                }
            }
        }
    }

    public func pause() {
        engine.pause()
        completionPump?.cancel()
        completionPump = nil
        wantsPlayback = false
    }

    /// Invalidates queued audio and callbacks together. The owner resets its media-time anchor
    /// at the same boundary, including seek and track replacement. Starvation can refill
    /// continuously and does not need a new generation.
    public func reset() {
        epoch = UUID()
        completionPump?.cancel()
        completionPump = nil
        engine.stop()
        source = nil
        // A new graph keeps the old source and any buffered mixer output out of the next
        // generation. Never reset shared ring cursors under a retained render callback.
        engine = AVAudioEngine()
        pending.removeAll()
        completionsSubmitted.removeAll()
        scheduledFrames = 0
        queuedFrames = 0
        offlineRenderedFrames = 0
        wantsPlayback = false
    }

    /// Test/experiment surface: manually render without opening an audio device.
    public func renderOffline(frames: Int) throws -> [Float] {
        guard mode == .offline else { throw Failure.notOffline }
        guard wantsPlayback, engine.isRunning else { throw Failure.notPlaying }
        guard (1...bufferCapacity).contains(frames),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)) else {
            throw Failure.invalidFrames
        }
        let status = try engine.renderOffline(UInt32(frames), to: buffer)
        guard status == .success, let data = buffer.floatChannelData else {
            throw NSError(domain: "NativePCMOutput.OfflineRender", code: Int(status.rawValue))
        }
        offlineRenderedFrames += Int64(buffer.frameLength)
        submitConsumedBuffers()
        var result: [Float] = []
        result.reserveCapacity(Int(buffer.frameLength) * channels)
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<channels { result.append(data[channel][frame]) }
        }
        return result
    }

    private func submitConsumedBuffers() {
        let completed = pending.filter { $0.value.endFrame <= renderedFrames && !completionsSubmitted.contains($0.key) }
            .sorted { $0.value.endFrame < $1.value.endFrame }
        let renderedEpoch = epoch
        let completedIDs = completed.map(\.key)
        completionsSubmitted.formUnion(completedIDs)
        if !completedIDs.isEmpty {
            Task { @MainActor [weak self] in
                for id in completedIDs { self?.complete(id, epoch: renderedEpoch) }
            }
        }
    }

    private func complete(_ id: UUID, epoch completedEpoch: UUID) {
        guard epoch == completedEpoch, let buffer = pending.removeValue(forKey: id) else { return }
        completionsSubmitted.remove(id)
        queuedFrames -= Int64(buffer.frames)
        onBufferCompleted?(id)
    }
}

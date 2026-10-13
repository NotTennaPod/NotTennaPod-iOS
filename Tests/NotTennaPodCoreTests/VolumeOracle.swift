import Accelerate
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// Independent reference for the heard level of processed playback, written from the
/// sources rather than from the app's code: Android's `applyVolumeAdaption` split (`v ≤ 1`: player volume
/// `v`, enhancer off; `v > 1`: player volume 1, LoudnessEnhancer enabled at `(int)(1000·(v−1))` mB, 0 mB
/// included), AOSP's AdaptiveDynamicRangeCompression (`dynamic_range_compression.h/.cpp`) with Android 16
/// semantics (a new target changes the knee and input gain only, the envelope continues; disabled, nothing
/// is processed), plus the PCM join ramp as specified for `PodcastVolumeStage`: a change applies from the
/// next processed frame, crossfading over round(0.02·rate) frames from the previous processing (still
/// running) to the new one (its envelope starting from the previous state), one ramp at a time, latest
/// target next.
///
/// The expected command history comes from the test (what it commanded, and where), never from what
/// reached the renderer: a dropped, extra or late command fails `expectDelivered` and the composed check.
enum VolumeOracle {
    /// Android's split of `v = sleep-timer volume × feed factor`.
    struct Command: Equatable {
        let v: Float
        var playerVolume: Float { v > 1 ? 1 : v }
        /// `nil`: enhancer disabled. An enabled enhancer may have a 0 mB target.
        var millibels: Int32? { v > 1 ? Int32(1000 * (v - 1)) : nil }
    }

    /// A command the test made: `v`, the number of frames processed before it (where its PCM boost
    /// starts) and the presentation frame when it was made (where its renderer value starts).
    struct Expected: Equatable, CustomStringConvertible {
        let v: Float, processed: Int64, presented: Int64
        var description: String { "v \(v) at processed \(processed), presented \(presented)" }
    }

    /// `AdaptiveDynamicRangeCompression::Compress`, one frame at a time, in its int16-scaled float domain.
    struct Compressor {
        private static let slope: Float = 1 / 7 - 1
        private static let minimumLogValue: Float = 0.032766999999999997517097227728299912996590137481689453125
        private var state: Float = 0, gain: Float = 1
        private let attack: Float, release: Float
        private var knee: Float = 0
        init(sampleRate: Float) {
            attack = exp(-1 / (0.001 * sampleRate))
            release = exp(-1 / (0.015 * sampleRate))
        }
        mutating func setTargetGain(_ amplification: Float) {
            // kTargetGain {1,2,3,4,5} → kKneeThreshold {-8,-8,-8.5,-9,-10}, linear, clamped at both ends.
            let gains: [Float] = [1, 2, 3, 4, 5], knees: [Float] = [-8, -8, -8.5, -9, -10]
            var decibels = knees[0]
            if amplification >= gains[4] { decibels = knees[4] }
            else if amplification > gains[0] {
                let index = gains.lastIndex { $0 <= amplification }!
                decibels = knees[index] + (knees[index + 1] - knees[index]) * (amplification - gains[index]) / (gains[index + 1] - gains[index])
            }
            knee = 0.1151292546497023061569109358970308676362037658691406250 * decibels
                + 10.39717719035538401328722102334722876548767089843750
        }
        /// One frame in place: samples in [-1, 1] in, compressed samples in [-1, 1] out.
        mutating func compress(_ frame: inout [Float], inputAmplification: Float) {
            let count = frame.count
            frame.withUnsafeMutableBufferPointer { compress($0.baseAddress!, count: count, inputAmplification: inputAmplification) }
        }
        mutating func compress(_ frame: UnsafeMutablePointer<Float>, count: Int, inputAmplification: Float) {
            var peak: Float = 0
            for index in 0..<count { frame[index] *= inputAmplification; peak = max(peak, abs(frame[index])) }
            let overshoot = Self.fastLog(max(peak, Self.minimumLogValue)) - knee
            let control = max(overshoot, 0) * Self.slope
            let previous = state
            let alpha = control <= state ? attack : release
            state = alpha * state + (1 - alpha) * control
            gain *= exp(state - previous)
            for index in 0..<count { frame[index] = min(max(frame[index] * gain, -32767), 32767) * (1 / Float(32768)) }
        }
        private static func fastLog(_ value: Float) -> Float {
            var bits = value.bitPattern
            let exponent = Int32((bits >> 23) & 255) - 128
            bits &= ~(UInt32(255) << 23)
            bits += UInt32(127) << 23
            let mantissa = Float(bitPattern: bits)
            return (((-1 / Float(3)) * mantissa + 2) * mantissa - 2 / Float(3) + Float(exponent)) * 0.693147180559945286226763982995180413126945495605468750
        }
    }

    /// PCM after the volume stage: `input` interleaved, `commands` in processing order, each applying
    /// from its frame (the number of frames processed before it). Returns samples in [-1, 1].
    static func processedPCM(_ input: [Int16], channels: Int, sampleRate: Int,
                             commands: [(frame: Int64, command: Command)]) -> [Float] {
        var floats = [Float](repeating: 0, count: input.count)
        vDSP.convertElements(of: input, to: &floats)
        vDSP.multiply(1 / Float(32768), floats, result: &floats)
        return processedPCM(floats, channels: channels, sampleRate: sampleRate, commands: commands, attenuateInPCM: false)
    }

    /// `attenuateInPCM`: the AVPlayer tap, where there is no renderer volume and `v ≤ 1` scales the samples.
    static func processedPCM(_ input: [Float], channels: Int, sampleRate: Int,
                             commands: [(frame: Int64, command: Command)], attenuateInPCM: Bool,
                             resets: Set<Int64> = []) -> [Float] {
        enum Mode: Equatable { case linear(Float), enhancer(Int32) }
        struct Path {
            var mode: Mode, compressor: Compressor
            var amplification: Float { if case .enhancer(let millibels) = mode { pow(10, Float(millibels) / 2000) * 32768 } else { 1 } }
            var linearGain: Float? { if case .linear(let gain) = mode { gain } else { nil } }
            mutating func process(_ frame: UnsafeMutablePointer<Float>, count: Int, amplification: Float) {
                switch mode {
                case .linear(let gain): for index in 0..<count { frame[index] *= gain }
                case .enhancer: compressor.compress(frame, count: count, inputAmplification: amplification)
                }
            }
        }
        func mode(_ command: Command) -> Mode {
            command.millibels.map { .enhancer($0) } ?? .linear(attenuateInPCM ? command.playerVolume : 1)
        }
        func fresh(_ mode: Mode) -> Path {
            var compressor = Compressor(sampleRate: Float(sampleRate))
            if case .enhancer(let millibels) = mode { compressor.setTargetGain(pow(10, Float(millibels) / 2000)) }
            return Path(mode: mode, compressor: compressor)
        }
        let rampFrames = Int((0.02 * Double(sampleRate)).rounded())
        let sorted = commands.enumerated().sorted { ($0.element.frame, $0.offset) < ($1.element.frame, $1.offset) }.map(\.element)
        var commandIndex = 0
        var requested = Mode.linear(1)
        while commandIndex < sorted.count && sorted[commandIndex].frame <= 0 {
            requested = mode(sorted[commandIndex].command); commandIndex += 1
        }
        var current = fresh(requested)
        var previous = current, ramping = false
        var position = 0
        let frames = input.count / channels
        var output = [Float](repeating: 0, count: frames * channels)
        let next = UnsafeMutablePointer<Float>.allocate(capacity: channels), before = UnsafeMutablePointer<Float>.allocate(capacity: channels)
        defer { next.deallocate(); before.deallocate() }
        var amplification = current.amplification, previousAmplification: Float = 1
        let events = Set(sorted.map(\.frame)).union(resets).filter { $0 > 0 }.sorted()
        var eventIndex = 0
        input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                var frame = 0
                while frame < frames {
                    while commandIndex < sorted.count && sorted[commandIndex].frame <= Int64(frame) {
                        requested = mode(sorted[commandIndex].command); commandIndex += 1
                    }
                    while eventIndex < events.count && events[eventIndex] <= Int64(frame) { eventIndex += 1 }
                    // A discontinuity: a fresh envelope at the requested target, no ramp.
                    if !resets.isEmpty && resets.contains(Int64(frame)) {
                        current = fresh(requested); ramping = false; position = 0; amplification = current.amplification
                    }
                    if !ramping && requested != current.mode {
                        var compressor = current.compressor
                        if case .enhancer(let millibels) = requested { compressor.setTargetGain(pow(10, Float(millibels) / 2000)) }
                        previous = current; previousAmplification = amplification; ramping = true
                        current = Path(mode: requested, compressor: compressor); amplification = current.amplification
                        position = 0
                    }
                    let segmentEnd = eventIndex < events.count ? min(frames, Int(events[eventIndex])) : frames
                    if !ramping, var gain = current.linearGain, segmentEnd > frame {
                        // Steady enhancer-off segment up to the next command: a plain gain.
                        vDSP_vsmul(input.baseAddress! + frame * channels, 1, &gain, output.baseAddress! + frame * channels, 1,
                                   vDSP_Length((segmentEnd - frame) * channels))
                        frame = segmentEnd
                        continue
                    }
                    let first = frame * channels
                    for channel in 0..<channels { next[channel] = input[first + channel] }
                    current.process(next, count: channels, amplification: amplification)
                    if ramping {
                        for channel in 0..<channels { before[channel] = input[first + channel] }
                        previous.process(before, count: channels, amplification: previousAmplification)
                        position += 1
                        let weight = Float(position) / Float(rampFrames)
                        for channel in 0..<channels { output[first + channel] = weight * next[channel] + (1 - weight) * before[channel] }
                        ramping = position < rampFrames
                    } else {
                        for channel in 0..<channels { output[first + channel] = next[channel] }
                    }
                    frame += 1
                }
            }
        }
        return output
    }

    /// Renderer value in force for each frame: the latest value set at or before that frame's presentation.
    static func rendererValues(_ changes: [(presented: Int64, value: Float)], frames: Int) -> [Float] {
        var result = [Float](repeating: 1, count: frames)
        let sorted = changes.enumerated().sorted { ($0.element.presented, $0.offset) < ($1.element.presented, $1.offset) }.map(\.element)
        var start = 0, value: Float = 1
        for change in sorted {
            let end = min(frames, max(start, Int(change.presented)))
            if end > start { vDSP.fill(&result[start..<end], with: value); start = end }
            value = change.value
        }
        if frames > start { vDSP.fill(&result[start..<frames], with: value) }
        return result
    }

    /// The commands that reached the renderer, in order, are exactly the expected ones with their
    /// boundaries. Before the first frame only the last value counts, on both sides (an output's
    /// preparation may set its starting value more than once).
    @discardableResult
    static func expectDelivered(_ actual: [(value: Float, presented: Int64, processed: Int64)], expected: [Expected],
                                label: String = "", sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        func startingValueOnce<T>(_ list: [T], _ boundary: (T) -> (Int64, Int64)) -> [T] {
            var list = list
            while list.count > 1, boundary(list[0]) == (0, 0), boundary(list[1]) == (0, 0) { list.removeFirst() }
            return list
        }
        let delivered = startingValueOnce(actual) { ($0.presented, $0.processed) }
        let describe = { (list: [(value: Float, presented: Int64, processed: Int64)]) in
            list.map { "\($0.value)@\($0.processed)/\($0.presented)" }.joined(separator: ", ")
        }
        let wanted = startingValueOnce(expected) { ($0.presented, $0.processed) }.map {
            (value: Command(v: $0.v).playerVolume, presented: $0.presented, processed: $0.processed)
        }
        let matches = delivered.count == wanted.count && zip(delivered, wanted).allSatisfy {
            $0.value == $1.value && $0.presented == $1.presented && $0.processed == $1.processed
        }
        #expect(matches, "\(label): renderer received [\(describe(delivered))], expected [\(describe(wanted))]",
                sourceLocation: sourceLocation)
        return matches
    }

    /// Heard = renderer value in force × PCM. Compares frames `0..<frames` sample by sample: equal within
    /// quantization, so the reference's own rises (compressor release, enhancer off) pass and any other
    /// step, overshoot, lost or repeated sample does not.
    static func expectComposed(actualPCM: [Int16], actualRenderer: [(presented: Int64, value: Float)],
                               referencePCM: [Float], referenceRenderer: [(presented: Int64, value: Float)],
                               channels: Int, frames: Int, label: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        guard actualPCM.count >= frames * channels, referencePCM.count >= frames * channels else {
            Issue.record("\(label): \(actualPCM.count / channels) actual and \(referencePCM.count / channels) reference frames, \(frames) compared",
                         sourceLocation: sourceLocation)
            return
        }
        let count = frames * channels
        func perSample(_ values: [Float]) -> [Float] {
            guard channels > 1 else { return values }
            var result = [Float](repeating: 0, count: count)
            for channel in 0..<channels {
                values.withUnsafeBufferPointer { source in
                    result.withUnsafeMutableBufferPointer { target in
                        vDSP_mmov(source.baseAddress!, target.baseAddress! + channel, 1, vDSP_Length(frames), 1, vDSP_Length(channels))
                    }
                }
            }
            return result
        }
        var heard = [Float](repeating: 0, count: count)
        vDSP.convertElements(of: actualPCM[0..<count], to: &heard)
        vDSP.multiply(1 / Float(32768), heard, result: &heard)
        heard = vDSP.multiply(perSample(rendererValues(actualRenderer, frames: frames)), heard)
        let reference = vDSP.multiply(perSample(rendererValues(referenceRenderer, frames: frames)), Array(referencePCM[0..<count]))
        let difference = vDSP.subtract(heard, reference)
        var worst: Float = 0, index: vDSP_Length = 0
        vDSP_maxmgvi(difference, 1, &worst, &index, vDSP_Length(count))
        // Int16 truncation plus float evaluation order: about two least significant bits.
        #expect(worst <= 2.5 / 32768,
                "\(label): heard level differs from the reference by \(worst * 32768) LSB at frame \(Int(index) / channels)",
                sourceLocation: sourceLocation)
    }

    static func samples(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) -> [Int16] {
        guard let data = buffer.content.withContiguousStorageIfAvailable({ Data($0) }) else { return [] }
        var result = [Int16](repeating: 0, count: data.count / 2)
        _ = result.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return result
    }
}

/// A presentation receiver that records what reaches the renderer: every PCM sample in order, every
/// renderer volume with the presentation time and the number of processed frames when it was set, and
/// every play/pause. It has no flush: a gain change cannot stop or re-queue anything here.
@MainActor final class GainRecordingTransport: PCMVolumePresentationTransport {
    struct VolumeChange { let value: Float; let presented: CMTime; let processedFrames: Int64 }
    var currentTime = CMTime.zero
    var onTimeChanged: (@MainActor () -> Void)?
    var onFailure: (@MainActor (any Error) -> Void)?
    private(set) var payload: [Int16] = []
    private(set) var processedFrames: Int64 = 0
    private(set) var sampleRate = 0
    private(set) var channels = 0
    private(set) var end = CMTime.zero
    private(set) var playing = false, closed = false, finished = false
    private(set) var playingChanges: [(playing: Bool, time: CMTime, volumeChangesBefore: Int)] = []
    private(set) var volumes: [VolumeChange] = []
    var hold = false
    private(set) var pending: CheckedContinuation<Void, any Error>?
    var rendererVolume: Float { volumes.last?.value ?? 1 }
    private var bufferEnds: [Int64] = []
    /// Buffers not yet completely presented, as the output counts its queue.
    var queuedBufferCount: Int {
        let presented = presentedFrames
        bufferEnds.removeAll { $0 <= presented }
        return bufferEnds.count
    }

    func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {
        guard !closed else { throw VolumeControlledPCMTransport.Failure.closed }
        if let format = buffer.formatDescription.audioStreamBasicDescription {
            sampleRate = Int(format.mSampleRate); channels = Int(format.mChannelsPerFrame)
        }
        // Recorded on arrival: frames processed before a later volume command are counted even if held.
        payload += VolumeOracle.samples(buffer)
        processedFrames += Int64(buffer.sampleCount)
        bufferEnds.append(processedFrames)
        if hold { hold = false; try await withCheckedThrowingContinuation { pending = $0 } }
        guard !closed else { throw VolumeControlledPCMTransport.Failure.closed }
    }
    func release() { let pending = pending; self.pending = nil; pending?.resume() }
    func setRendererVolume(_ volume: Float) {
        volumes.append(.init(value: volume, presented: currentTime, processedFrames: processedFrames))
    }
    func setPlaying(_ playing: Bool, at time: CMTime) {
        playingChanges.append((playing, time, volumes.count))
        self.playing = playing; currentTime = time
    }
    func observeEnd(_ time: CMTime) { end = time }
    func finishEnqueuing() { finished = true }
    func stopMonitoring() { finished = false }
    func close() {
        closed = true; playing = false
        let pending = pending; self.pending = nil
        pending?.resume(throwing: VolumeControlledPCMTransport.Failure.closed)
    }
    var presentedFrames: Int64 {
        guard sampleRate > 0 else { return 0 }
        return CMTimeConvertScale(currentTime, timescale: Int32(sampleRate), method: .roundTowardZero).value
    }
    func advance(to frame: Int64) {
        currentTime = CMTime(value: frame, timescale: Int32(sampleRate)); onTimeChanged?()
    }

    /// What reached the renderer (the actual side), with presentation and processing frames.
    var delivered: [(value: Float, presented: Int64, processed: Int64)] {
        volumes.map { ($0.value, frames($0.presented), $0.processedFrames) }
    }
    private func frames(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: Int32(max(1, sampleRate)), method: .roundTowardZero).value
    }

    /// Checks the renderer received exactly the `expected` commands at their boundaries, then composes
    /// what is heard (renderer values as delivered × PCM as queued) against the reference built from
    /// `expected` alone, over `input` (the PCM before the volume stage).
    func expectHeard(input: [Int16], expected: [VolumeOracle.Expected], frames: Int, label: String = "",
                     sourceLocation: SourceLocation = #_sourceLocation) {
        VolumeOracle.expectDelivered(delivered, expected: expected, label: label, sourceLocation: sourceLocation)
        let channels = max(1, self.channels)
        let reference = VolumeOracle.processedPCM(Array(input.prefix(frames * channels + channels * 4096)), channels: channels,
            sampleRate: sampleRate, commands: expected.map { ($0.processed, VolumeOracle.Command(v: $0.v)) })
        VolumeOracle.expectComposed(actualPCM: payload, actualRenderer: delivered.map { ($0.presented, $0.value) },
            referencePCM: reference, referenceRenderer: expected.map { ($0.presented, VolumeOracle.Command(v: $0.v).playerVolume) },
            channels: channels, frames: frames, label: label, sourceLocation: sourceLocation)
    }
}

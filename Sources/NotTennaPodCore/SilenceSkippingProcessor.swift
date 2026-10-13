// Adapted from Media3 1.10.0 SilenceSkippingAudioProcessor.
// Copyright 2018 The Android Open Source Project. Apache License 2.0.
// See NOTICE.md and Licenses/Apache-2.0.txt.

/// Stateful interleaved PCM16 processing. Own this value on the decoder's serial executor.
/// This implements the reference's default audio transformation; engine integration is separate.
public struct SilenceSkippingProcessor: Sendable {
    public enum Failure: Error, Equatable { case invalidFormat, incompleteFrame, alreadyFinished }
    public let sampleRate: Int
    public let channels: Int
    public private(set) var skippedFrames: Int64 = 0
    /// Events from the most recent process/finish call, in original source order.
    public private(set) var timelineSpans: [PCMProcessingSpan] = []
    private var consumedTimelineFrames: Int64 = 0
    private var emittedTimelineFrames: Int64 = 0
    private var buffer: [Int16]
    private var start = 0
    private var count = 0
    private var shortening = false
    private var outputSilenceFrames = 0
    private var finished = false

    public init(sampleRate: Int, channels: Int) throws {
        // Bound arithmetic/storage for invalid external formats. No supported format is inferred
        // from this guard: the decoder still has to negotiate interleaved PCM16 explicitly.
        guard (1...768_000).contains(sampleRate), (1...32).contains(channels) else {
            throw Failure.invalidFormat
        }
        let bytesPerFrame = channels * 2
        // Deliberately preserve Media3's actual frame-count-as-byte alignment. Replacing this
        // with a nominal 100-ms buffer changes observed output, especially for stereo.
        let samples = (sampleRate / 10 / 2 / bytesPerFrame) * bytesPerFrame
        guard samples > 0 else { throw Failure.invalidFormat }
        self.sampleRate = sampleRate
        self.channels = channels
        buffer = .init(repeating: 0, count: samples)
    }

    /// Consumes complete frames, returning any output available so far. Retains bounded silence
    /// across calls. Input packet boundaries are significant to the reference's noise scan.
    public mutating func process(_ input: [Int16]) throws -> [Int16] {
        guard !finished else { throw Failure.alreadyFinished }
        guard input.count.isMultiple(of: channels) else { throw Failure.incompleteFrame }
        timelineSpans.removeAll(keepingCapacity: true)
        var output: [Int16] = []
        output.reserveCapacity(input.count)
        var position = 0
        while position < input.count {
            if !shortening {
                let limit = min(input.count, position + buffer.count)
                var noiseEnd = position
                for index in stride(from: limit - 1, through: position, by: -1) {
                    if abs(Int(input[index])) > 1024 {
                        noiseEnd = (index / channels + 1) * channels
                        break
                    }
                }
                if noiseEnd == position {
                    shortening = true
                } else {
                    output.append(contentsOf: input[position..<noiseEnd])
                    recordTimeline(consumed: (noiseEnd - position) / channels, emitted: (noiseEnd - position) / channels)
                    position = noiseEnd
                }
            } else {
                var noiseStart = input.count
                for index in position..<input.count {
                    if abs(Int(input[index])) > 1024 {
                        noiseStart = index / channels * channels
                        break
                    }
                }
                let silenceAvailable = noiseStart - position
                let writeIndex: Int
                let remaining: Int
                if start + count < buffer.count {
                    writeIndex = start + count
                    remaining = buffer.count - writeIndex
                } else {
                    writeIndex = count - (buffer.count - start)
                    remaining = start - writeIndex
                }
                let copied = min(silenceAvailable, remaining)
                buffer.replaceSubrange(writeIndex..<(writeIndex + copied),
                                       with: input[position..<(position + copied)])
                position += copied
                count += copied
                let transition = noiseStart < input.count && silenceAvailable < remaining
                emitSilence(transition: transition, into: &output)
                if transition {
                    shortening = false
                    outputSilenceFrames = 0
                }
            }
        }
        return output
    }

    /// Drain at a true stream end. Seek/track replacement should discard old buffered audio
    /// with reset instead, then establish the new media timeline in the playback engine.
    public mutating func finish() -> [Int16] {
        timelineSpans.removeAll(keepingCapacity: true)
        guard !finished else { return [] }
        var output: [Int16] = []
        if count > 0 { emitSilence(transition: true, into: &output) }
        outputSilenceFrames = 0
        finished = true
        return output
    }

    public mutating func reset() {
        start = 0
        count = 0
        shortening = false
        outputSilenceFrames = 0
        skippedFrames = 0
        finished = false
        timelineSpans.removeAll(keepingCapacity: true)
        consumedTimelineFrames = 0; emittedTimelineFrames = 0
    }

    private enum Ramp { case unchanged, fadeOut, muted, fadeIn }

    private func shortenedSamples(_ samples: Int) -> Int {
        let maxBytes = (sampleRate * 2 - outputSilenceFrames) * channels * 2 - buffer.count
        let requestedBytes = min(Float(samples * 2) * 0.2 + 0.5, Float(maxBytes))
        return Int(requestedBytes) / (channels * 2) * channels
    }

    private mutating func emitSilence(transition: Bool, into output: inout [Int16]) {
        guard count == buffer.count || transition else { return }
        let half = buffer.count / 2
        let consumed: Int
        let emitted: Int
        let ramp: Ramp
        if outputSilenceFrames == 0 {
            consumed = transition ? count : half
            emitted = consumed
            ramp = transition ? .unchanged : .fadeOut
        } else if transition {
            consumed = count
            emitted = half + shortenedSamples(count - half)
            ramp = .fadeIn
        } else {
            consumed = count - half
            emitted = shortenedSamples(consumed)
            ramp = .muted
        }
        let first = ramp == .fadeIn ? start + count - emitted : start
        recordTimeline(consumed: consumed / channels, emitted: emitted / channels, removedFirst: ramp == .fadeIn)
        for index in 0..<emitted {
            let sample = Int(buffer[(first + index) % buffer.count])
            let percent: Int
            switch ramp {
            case .unchanged: percent = 100
            case .muted: percent = 10
            case .fadeOut: percent = (-90 * ((1000 * index * 2) / (emitted * 2 - 1))) / 1000 + 100
            case .fadeIn: percent = 10 + (90 * (1000 * index * 2) / (emitted * 2 - 1)) / 1000
            }
            output.append(Int16(sample * percent / 100))
        }
        count -= consumed
        start = (start + consumed) % buffer.count
        outputSilenceFrames += emitted / channels
        skippedFrames += Int64((consumed - emitted) / channels)
    }

    private mutating func recordTimeline(consumed: Int, emitted: Int, removedFirst: Bool = false) {
        let removed = Int64(consumed - emitted)
        func span(_ inputStart: Int64, _ count: Int64, _ outputStart: Int64, _ outputCount: Int64) -> PCMProcessingSpan {
            PCMProcessingSpan(input: inputStart..<(inputStart + count), output: outputStart..<(outputStart + outputCount))
        }
        if removedFirst && removed > 0 {
            timelineSpans.append(span(consumedTimelineFrames, removed, emittedTimelineFrames, 0))
        }
        if emitted > 0 {
            timelineSpans.append(span(consumedTimelineFrames + (removedFirst ? removed : 0), Int64(emitted), emittedTimelineFrames, Int64(emitted)))
        }
        if !removedFirst && removed > 0 {
            timelineSpans.append(span(consumedTimelineFrames + Int64(emitted), removed, emittedTimelineFrames + Int64(emitted), 0))
        }
        consumedTimelineFrames += Int64(consumed); emittedTimelineFrames += Int64(emitted)
    }
}

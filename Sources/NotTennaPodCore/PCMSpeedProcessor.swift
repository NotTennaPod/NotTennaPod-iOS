// Adapted from Media3 1.10.0 Sonic.java (PCM16, unchanged pitch/sample rate).
// Copyright (C) 2017 The Android Open Source Project
// Copyright (C) 2010 Bill Cox, Sonic Library
// Apache License 2.0; see NOTICE.md and Licenses/Apache-2.0.txt.

/// Bounded, pitch-preserving speed processing before native output. Own on the decoder executor.
/// A speed change requires draining this instance and starting another at an output checkpoint.
/// Input/output counters describe processing, not audio presentation.
public struct PCMSpeedProcessor: Sendable {
    public enum Failure: Error, Equatable { case invalidFormat, invalidSpeed, invalidPacket, alreadyFinished }
    public let sampleRate: Int
    public let channels: Int
    public let speed: Float
    public private(set) var inputFrames: Int64 = 0
    public private(set) var outputFrames: Int64 = 0
    /// Committed consumed/emitted intervals for the last pull, before caller packetization.
    /// These conserve real input/output frames; they do not claim a one-sample phase oracle
    /// for the overlapping pitch-preserving waveform.
    public private(set) var timelineSpans: [PCMProcessingSpan] = []
    public var pendingInputFrames: Int { input.count / channels }

    private let minimumPeriod: Int
    private let maximumPeriod: Int
    private let requiredFrames: Int
    private var input: [Int16] = []
    private var remainingCopy = 0
    private var previousPeriod = 0
    private var previousMinimumDifference: Int32 = 0
    private var minimumDifference: Int32 = 0
    private var maximumDifference: Int32 = 0
    private var adjustmentError: Double = 0
    private var finished = false

    public init(sampleRate: Int, channels: Int, speed: Float) throws {
        guard (8_000...768_000).contains(sampleRate), (1...32).contains(channels) else {
            throw Failure.invalidFormat
        }
        guard speed.isFinite, (0.5...4).contains(speed) else { throw Failure.invalidSpeed }
        self.sampleRate = sampleRate
        self.channels = channels
        self.speed = speed
        minimumPeriod = sampleRate / 400
        maximumPeriod = sampleRate / 65
        requiredFrames = 2 * maximumPeriod
    }

    /// Each call accepts at most 65,536 complete frames. Consume the returned output before
    /// pulling more input; internal retention is bounded by the pitch-detection window.
    public mutating func process(_ samples: [Int16]) throws -> [Int16] {
        guard !finished else { throw Failure.alreadyFinished }
        guard samples.count.isMultiple(of: channels), samples.count / channels <= 65_536 else {
            throw Failure.invalidPacket
        }
        timelineSpans.removeAll(keepingCapacity: true)
        let consumedBefore = inputFrames - Int64(pendingInputFrames)
        let outputBefore = outputFrames
        inputFrames += Int64(samples.count / channels)
        input += samples
        let result = processInput()
        outputFrames += Int64(result.count / channels)
        let consumedAfter = inputFrames - Int64(pendingInputFrames)
        if consumedAfter > consumedBefore {
            timelineSpans.append(.init(input: consumedBefore..<consumedAfter, output: outputBefore..<outputFrames))
        }
        return result
    }

    /// Sonic's explicit EOS flush excludes artificial padding from the returned output count.
    /// Discard the instance on seek/replacement instead of draining unwanted old audio.
    public mutating func finish() -> [Int16] {
        timelineSpans.removeAll(keepingCapacity: true)
        guard !finished else { return [] }
        let consumedBefore = inputFrames - Int64(pendingInputFrames)
        let outputBefore = outputFrames
        let adjusted = pendingInputFrames - remainingCopy
        let expected = max(0, Int(Double(adjusted) / Double(speed) + Double(remainingCopy) + adjustmentError + 0.5))
        adjustmentError = 0
        input += Array(repeating: 0, count: 2 * requiredFrames * channels)
        var result = processInput()
        if result.count / channels > expected { result.removeSubrange((expected * channels)..<result.count) }
        input.removeAll()
        remainingCopy = 0
        finished = true
        outputFrames += Int64(result.count / channels)
        if inputFrames > consumedBefore {
            timelineSpans.append(.init(input: consumedBefore..<inputFrames, output: outputBefore..<outputFrames))
        }
        return result
    }

    private mutating func processInput() -> [Int16] {
        guard speed > Float(1.00001) || speed < Float(0.99999) else {
            let result = input
            input.removeAll(keepingCapacity: true)
            return result
        }
        guard pendingInputFrames >= requiredFrames else { return [] }
        var result: [Int16] = []
        var position = 0
        let rate = Double(speed)
        repeat {
            if remainingCopy > 0 {
                let count = min(requiredFrames, remainingCopy)
                result += input[(position * channels)..<((position + count) * channels)]
                remainingCopy -= count
                position += count
            } else {
                let period = findPeriod(at: position)
                if rate > 1 {
                    let count: Int
                    if rate >= 2 {
                        let expected = Double(period) / (rate - 1) + adjustmentError
                        count = Int((expected + 0.5).rounded(.down))
                        adjustmentError = expected - Double(count)
                    } else {
                        count = period
                        let expected = Double(period) * (2 - rate) / (rate - 1) + adjustmentError
                        remainingCopy = Int((expected + 0.5).rounded(.down))
                        adjustmentError = expected - Double(remainingCopy)
                    }
                    overlap(count: count, down: position, up: position + period, into: &result)
                    position += period + count
                } else {
                    // The supported slider starts at 0.5; Sonic's below-0.5 branch is unnecessary.
                    let expected = Double(period) * (2 * rate - 1) / (1 - rate) + adjustmentError
                    remainingCopy = Int((expected + 0.5).rounded(.down))
                    adjustmentError = expected - Double(remainingCopy)
                    result += input[(position * channels)..<((position + period) * channels)]
                    overlap(count: period, down: position + period, up: position, into: &result)
                    position += period
                }
            }
        } while position + requiredFrames <= pendingInputFrames
        input.removeFirst(position * channels)
        return result
    }

    // The inner loops below read through unsafe buffers (with explicit range preconditions)
    // so unoptimized development builds still process 4× faster than real time; the
    // arithmetic is unchanged.
    private func overlap(count: Int, down: Int, up: Int, into result: inout [Int16]) {
        let channels = channels
        precondition(count >= 0 && (max(down, up) + count) * channels <= input.count)
        guard count > 0 else { return }
        let mixed = input.withUnsafeBufferPointer { input in
            [Int16](unsafeUninitializedCapacity: count * channels) { output, initialized in
                var a = input.baseAddress! + down * channels, b = input.baseAddress! + up * channels
                var target = output.baseAddress!
                var frame = 0
                while frame < count {
                    var channel = 0
                    while channel < channels {
                        target.pointee = Int16((Int(a.pointee) * (count - frame) + Int(b.pointee) * frame) / count)
                        a += 1; b += 1; target += 1; channel += 1
                    }
                    frame += 1
                }
                initialized = count * channels
            }
        }
        result += mixed
    }

    private func downsample(at position: Int, skip: Int) -> [Int16] {
        let width = channels * skip
        let frames = requiredFrames / skip
        precondition(position * channels + frames * width <= input.count)
        return input.withUnsafeBufferPointer { input in
            [Int16](unsafeUninitializedCapacity: frames) { output, initialized in
                var source = input.baseAddress! + position * channels
                var target = output.baseAddress!
                let end = target + frames
                while target < end {
                    var total = 0
                    let group = source + width
                    while source < group { total += Int(source.pointee); source += 1 }
                    target.pointee = Int16(total / width)
                    target += 1
                }
                initialized = frames
            }
        }
    }

    private mutating func findPeriod(at position: Int) -> Int {
        let skip = sampleRate > 4000 ? sampleRate / 4000 : 1
        var period: Int
        if channels == 1 && skip == 1 {
            period = findPeriod(in: input, offset: position, low: minimumPeriod, high: maximumPeriod)
        } else {
            period = findPeriod(in: downsample(at: position, skip: skip), offset: 0,
                                low: minimumPeriod / skip, high: maximumPeriod / skip)
            if skip != 1 {
                period *= skip
                let low = max(minimumPeriod, period - skip * 4)
                let high = min(maximumPeriod, period + skip * 4)
                if channels == 1 {
                    period = findPeriod(in: input, offset: position, low: low, high: high)
                } else {
                    period = findPeriod(in: downsample(at: position, skip: 1), offset: 0, low: low, high: high)
                }
            }
        }
        let usePrevious = minimumDifference != 0 && previousPeriod != 0
            && maximumDifference <= minimumDifference &* 3
            && minimumDifference &* 2 > previousMinimumDifference &* 3
        let chosen = usePrevious ? previousPeriod : period
        previousMinimumDifference = minimumDifference
        previousPeriod = period
        return chosen
    }

    private mutating func findPeriod(in samples: [Int16], offset: Int, low: Int, high: Int) -> Int {
        var best = 0
        var worst = 255
        var smallest: Int32 = 1
        var largest: Int32 = 0
        precondition(low >= 1 && offset >= 0 && offset + 2 * high <= samples.count)
        for period in low...high {
            let difference = samples.withUnsafeBufferPointer { samples -> Int32 in
                // At most 738 × 65,535 per sum: the Java int total cannot overflow, so a
                // native Int sum is identical and avoids generic calls in unoptimized builds.
                var difference = 0
                var first = samples.baseAddress! + offset
                var second = first + period
                let end = first + period
                while first < end {
                    let delta = Int(first.pointee) - Int(second.pointee)
                    difference += delta < 0 ? -delta : delta
                    first += 1; second += 1
                }
                return Int32(truncatingIfNeeded: difference)
            }
            // Preserve Java int arithmetic in the original period-selection comparisons.
            if difference &* Int32(best) < smallest &* Int32(period) {
                smallest = difference
                best = period
            }
            if difference &* Int32(worst) > largest &* Int32(period) {
                largest = difference
                worst = period
            }
        }
        minimumDifference = smallest / Int32(best)
        maximumDifference = largest / Int32(worst)
        return best
    }
}

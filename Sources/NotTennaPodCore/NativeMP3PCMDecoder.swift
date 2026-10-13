import AVFoundation
import CoreMedia
import Foundation
import os
import Synchronization

/// Incremental, caller-confined decoding. Holds one admitted compressed batch and
/// emits at most one bounded PCM packet per pull. A dry input is never decoder EOF.
///
/// Format changes. An MP3 can change sample rate or channel count between frames, as
/// when an ad encoded differently is spliced into a show. Everything after this decoder
/// keeps the stream's first format (`timing`: its first frame's rate r and channel count):
/// - A segment is a run of frames with one sample rate and channel count (stereo, joint
///   stereo and dual channel are all two channels). The parser never mixes segments in a
///   batch and gives each batch its exact source time T: every earlier frame's samples at
///   that frame's own rate.
/// - At a change the old converter is drained to its end and a new one built; the new
///   segment's frames never depend on the old one's. A segment in the stream's format
///   passes through unchanged. Any other is converted: two channels averaged to one, one
///   channel copied to two, and its rate converted by AVAudioConverter, primed so its
///   output is aligned with its input and flushed at the segment's end.
/// - Time origin: a segment whose first packet is at source time T starts at output frame
///   round(T·r) − encoder delay (after an approximate byte seek, round((T − T₀)·r) from that
///   seek's first packet T₀). Its length is the next origin minus its own, so the output
///   timeline has no gap or overlap and rounding never accumulates. A converted segment's
///   converter output is fitted to that length at its end when they differ by at most
///   `joinRoundingLimit` frames (cut, or extended by repeating its last output frame). A
///   larger difference is not rounding: every frame the converter returned is kept, nothing
///   is added, the anomaly is logged (`MP3SegmentJoinDiagnostics`), and the segments after it
///   move by the difference, so this decoder's later times are off the source's by that much.
/// - Seeking: admission drops whole MPEG frames of the segment holding the target; a
///   converted frame starts at its rounded output position. Seek maps describe the first
///   encoding, so seeks into later segments are as approximate as the map is there.
/// - Encoder delay and padding: the declared delay is removed from the stream's start. The
///   declared padding and frame count describe the first encoding only. They are neither
///   applied nor checked, and the source's end ends the audio, once this decoder decodes a
///   change, when it starts in another format, or when its first batch follows a change its
///   parser saw (`Batch.afterFormatChange`; a parse from the source's start sees every earlier
///   change). After an approximate byte seek the parser starts mid-file: a change before
///   the seek is then unknown when decoding starts in the first format, and a stale or
///   splice-updated Xing/LAME declaration can still trim up to its declared padding from the
///   end there. That spliced-header case is not supported.
final class NativeMP3PCMDecoder {
    enum Failure: Error, Equatable {
        case closed, inputPending, finished, invalidBatch, invalidCapacity, conversion, incompleteStream
    }
    /// AVAudioConverter, primed normally and flushed, returns within one frame of N·r ÷ rate
    /// for N frames at a segment's own rate; the segment's length, the difference of two
    /// values rounded to the nearest frame, is within one frame of it too. Both are whole
    /// frames, so they differ by at most one.
    static let joinRoundingLimit: Int64 = 1
    /// For each converted segment, its timeline length minus the frames its converter
    /// returned: fitted when within `joinRoundingLimit`, otherwise kept and carried forward.
    private(set) var joinCorrections: [Int64] = []
    /// How far later segments start after their timeline origin, from converter anomalies.
    private var originShift: Int64 = 0
    /// Tests only: frames added to (or removed from) each converted segment's converter
    /// output at its end, to exercise a converter anomaly.
    private let converterOutputAdjustment: Int64
    enum Step {
        case audio(NativePCMDecoder.Packet)
        case needsInput
        case ended
    }
    let timing: NativeMP3PacketParser.Timing
    let channels: Int
    private(set) var acceptedFrames: Int64 = 0
    private(set) var decodedFrames: Int64 = 0
    private(set) var emittedFrames: Int64 = 0
    private(set) var needsInput = true
    private var decodingEnded = false
    var isEnded: Bool { decodingEnded && outputSamples.isEmpty }
    private let maximumOutputFrames: Int
    private var segment: Segment
    private var pending: AVAudioCompressedBuffer?
    /// The first batch of another configuration, waiting until the current segment drains.
    private var nextSegment: NativeMP3PacketParser.Batch?
    private var sourceEnded = false
    private var drainingSourceFailure = false
    private let rangeOrigin: CMTime?
    private let firstFrame: Int64
    /// A format change was decoded; the declared padding and counts no longer describe the audio.
    private var spliced = false
    /// Output frame of the seek target until the first frame is admitted.
    private var admissionTarget: Int64?
    private var admissionRequested = false
    private var rangeTail: [Int16] = []
    var retainedTailFrames: Int { rangeTail.count / channels }
    /// Decoded frames past the declared end (from raw frame `declaredTailStart`): dropped as
    /// padding at the source's end, released as audio if the source continues.
    private var declaredTail: [Int16] = []
    private var declaredTailStart: Int64 = 0
    private var closed = false
    private var failure: (any Error)?

    init(format: CMAudioFormatDescription, timing: NativeMP3PacketParser.Timing,
         maximumOutputFrames: Int = 4096, firstFrame: Int64 = 0, rangeOrigin: CMTime? = nil,
         sourceTime: CMTime? = nil, afterFormatChange: Bool = false, converterOutputAdjustment: Int64 = 0) throws {
        guard (1...65_536).contains(maximumOutputFrames) else { throw Failure.invalidCapacity }
        guard timing.sampleRate > 0, (1...2).contains(timing.channels), firstFrame >= 0 else { throw Failure.invalidBatch }
        if let rangeOrigin {
            guard rangeOrigin.isNumeric, rangeOrigin.epoch == 0,
                  (0...65_536).contains(timing.remainderFrameCount ?? 0) else { throw Failure.invalidBatch }
        }
        if let sourceTime { guard sourceTime.isNumeric, sourceTime.epoch == 0 else { throw Failure.invalidBatch } }
        self.rangeOrigin = rangeOrigin; self.firstFrame = firstFrame
        self.timing = timing
        self.maximumOutputFrames = maximumOutputFrames
        self.converterOutputAdjustment = converterOutputAdjustment
        channels = timing.channels
        // Packet ordinals remain on the source timeline after a seek. The owner
        // supplies codec preroll; only source-leading padding is removed here.
        acceptedFrames = firstFrame
        decodedFrames = firstFrame
        emittedFrames = rangeOrigin == nil ? max(0, min(firstFrame - (timing.primingFrameCount ?? 0), timing.validFrameCount ?? .max)) : 0
        let start = rangeOrigin == nil ? sourceTime ?? CMTime(value: firstFrame, timescale: timing.sampleRate) : .zero
        segment = try Segment(format: format, rawStart: firstFrame, start: start,
            delay: rangeOrigin == nil ? timing.primingFrameCount ?? 0 : 0,
            timing: timing, maximumFrames: maximumOutputFrames)
        // Starting after a change, or in another format: the declared counts no longer
        // describe the audio (and after one at another rate, packet ordinals are no longer
        // output frames). Only then are those declarations checked.
        spliced = afterFormatChange || segment.conversion != nil
            || start != CMTime(value: firstFrame, timescale: timing.sampleRate) && rangeOrigin == nil
        guard spliced || timing.encodedFrameCount.map({ firstFrame <= $0 }) ?? true else { throw Failure.invalidBatch }
        // The converter's default normal priming and the container's encoder
        // padding are separate. Apply only the declared container padding below.
    }

    func accept(_ batch: NativeMP3PacketParser.Batch) throws {
        try validate()
        guard !sourceEnded else { throw Failure.finished }
        guard needsInput, pending == nil, nextSegment == nil else { throw Failure.inputPending }
        guard batch.firstFrame == acceptedFrames, batch.timing == timing,
              let basic = batch.format.audioStreamBasicDescription, basic.mFormatID == kAudioFormatMPEGLayer3,
              !batch.bytes.isEmpty, batch.bytes.count <= 65_536,
              !batch.descriptions.isEmpty, batch.descriptions.count <= 65_536,
              batch.frameCount > 0, !acceptedFrames.addingReportingOverflow(batch.frameCount).overflow else {
            throw Failure.invalidBatch
        }
        let maximumPacket = batch.descriptions.map(\.mDataByteSize).max() ?? 0
        guard maximumPacket > 0, maximumPacket <= 65_536,
              batch.descriptions.allSatisfy({ $0.mStartOffset >= 0 && $0.mDataByteSize > 0 &&
                  $0.mStartOffset <= Int64(batch.bytes.count) - Int64($0.mDataByteSize) }) else {
            throw Failure.invalidBatch
        }
        if batch.afterFormatChange { spliced = true }
        if MP3FrameConfiguration(basic) == segment.configuration {
            pending = try segment.compressed(batch)
        } else {
            // Decoded after the current segment drains (see `begin`).
            guard batch.rangeOrigin != nil || rangeOrigin == nil else { throw Failure.invalidBatch }
            nextSegment = batch
        }
        acceptedFrames += batch.frameCount
        needsInput = false
    }

    /// Only the source owner may declare actual EOF. Already admitted audio still drains.
    func finish(afterSourceFailure: Bool = false) throws {
        try validate()
        guard !sourceEnded else { throw Failure.finished }
        sourceEnded = true
        drainingSourceFailure = afterSourceFailure
        needsInput = false
    }

    /// Seek admission, before any output. MediaCodecRenderer's exact seek drops
    /// each whole decoded buffer that starts before the target; an MP3 codec
    /// buffer is one MPEG frame. Drop whole frames on this source's frame grid,
    /// so the first audio starts at most one MPEG frame after the target however
    /// compressed reads or converter returns were split. Decoder preroll and
    /// source padding are unchanged; a map's own time estimate is separate.
    func admit(from target: CMTime) throws {
        try validate()
        guard target.isNumeric, target.epoch == 0, !admissionRequested, outputTime == nil,
              outputSamples.isEmpty else { throw Failure.invalidBatch }
        // Output frame e is presented at e (gapless source) or rangeOrigin + e
        // (approximate byte seek).
        let first = CMTimeConvertScale(target - (rangeOrigin ?? .zero), timescale: timing.sampleRate,
            method: .roundAwayFromZero)
        guard first.isNumeric else { throw Failure.invalidBatch }
        admissionRequested = true
        admissionTarget = first.value
    }

    // AVAudioConverter may return a partial PCM buffer when a compressed
    // transport fragment runs dry. Admission above never depends on those
    // returns; grouping them keeps output packets bounded and few. Keep only a
    // partial output quantum between pulls; acquisition remains free to
    // publish every parsed source packet.
    private var outputSamples: [Int16] = []
    private var outputTime: CMTime?
    private var outputEnded = false

    func next() throws -> Step {
        try validate()
        let capacity = maximumOutputFrames * channels
        while outputSamples.count < capacity, !outputEnded {
            switch try nextDecoded() {
            case .audio(let packet):
                if outputTime == nil { outputTime = packet.presentationTime }
                outputSamples.append(contentsOf: packet.samples)
            case .needsInput: return .needsInput
            case .ended: outputEnded = true
            }
        }
        guard !outputSamples.isEmpty, let time = outputTime else { return .ended }
        let count = min(capacity, outputSamples.count)
        let packet = NativePCMDecoder.Packet(samples: Array(outputSamples.prefix(count)),
            sampleRate: Int(timing.sampleRate), channels: channels, presentationTime: time)
        outputSamples.removeFirst(count)
        outputTime = time + CMTime(value: Int64(count / channels), timescale: timing.sampleRate)
        return .audio(packet)
    }

    private func nextDecoded() throws -> Step {
        try validate()
        if decodingEnded { return .ended }
        if needsInput { return .needsInput }
        do {
            while true {
                if segment.ended {
                    if let packet = try finishSegment() { return .audio(packet) }
                    if let batch = nextSegment { try begin(batch); continue }
                    return try complete()
                }
                var error: NSError?
                // Keep callback-supplied storage alive until conversion returns.
                var supplied: AVAudioCompressedBuffer?
                let pcm = segment.pcm
                pcm.frameLength = 0
                let status = segment.converter.convert(to: pcm, error: &error) { [self] _, status in
                    if let buffer = pending {
                        supplied = buffer
                        pending = nil
                        status.pointee = .haveData
                        return buffer
                    }
                    // A segment also ends where the next configuration begins.
                    status.pointee = sourceEnded || nextSegment != nil ? .endOfStream : .noDataNow
                    return nil
                }
                withExtendedLifetime(supplied) {}
                if let error { throw error }
                guard status != .error else { throw Failure.conversion }
                let segmentEnd = nextSegment?.firstFrame ?? acceptedFrames
                if status == .endOfStream {
                    guard sourceEnded || nextSegment != nil, pcm.frameLength == 0,
                          decodedFrames == segmentEnd else { throw Failure.incompleteStream }
                    segment.ended = true
                    continue
                }
                needsInput = status == .inputRanDry
                let count = Int64(pcm.frameLength)
                guard decodedFrames <= segmentEnd - count else { throw Failure.conversion }
                let rawStart = decodedFrames
                decodedFrames += count
                if let packet = try emitDecoded(rawStart: rawStart, count: count) { return .audio(packet) }
                if needsInput { return .needsInput }
                guard count > 0 else { throw Failure.conversion }
            }
        } catch {
            failure = error
            pending = nil
            nextSegment = nil
            rangeTail.removeAll(keepingCapacity: false)
            segment.converter.reset()
            throw error
        }
    }

    /// Decoded frames [rawStart, rawStart + count) of the current segment, as output.
    private func emitDecoded(rawStart: Int64, count: Int64) throws -> NativePCMDecoder.Packet? {
        guard let samples = segment.pcm.int16ChannelData?[0] else { throw Failure.conversion }
        if let conversion = segment.conversion {
            try conversion.convert(UnsafeBufferPointer(start: samples, count: Int(count) * segment.configuration.channels))
            // Hold back the converter's rounding until the segment's length is known.
            let ready = segment.outputFrames(conversion.fed) - 1 - conversion.emitted
            return emitConverted(frames: min(ready, conversion.heldFrames))
        }
        if rangeOrigin != nil {
            rangeTail.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(count) * channels))
            let available = retainedTailFrames - (spliced ? 0 : Int(timing.remainderFrameCount ?? 0))
            return available > 0 ? emitRange(frames: available) : nil
        }
        let priming = timing.primingFrameCount ?? 0
        let start = max(rawStart, priming)
        guard decodedFrames > start else { return nil }
        let offset = Int(start - rawStart) * channels
        var fresh = Array(UnsafeBufferPointer(start: samples + offset, count: Int(decodedFrames - start) * channels))
        var first = start
        if !spliced, let valid = timing.validFrameCount {
            // Past the declared end is padding only if the source ends there: hold it until
            // then. A format change releases it as audio; a source that runs past its declared
            // length in its first format still fails at its end (see `complete`).
            let kept = Int(max(0, min(decodedFrames, priming + valid) - start))
            if kept * channels < fresh.count {
                if declaredTail.isEmpty { declaredTailStart = start + Int64(kept) }
                declaredTail += fresh[(kept * channels)...]
                fresh.removeLast(fresh.count - kept * channels)
            }
        }
        if spliced, !declaredTail.isEmpty {
            fresh = declaredTail + fresh; first = declaredTailStart
            declaredTail.removeAll(keepingCapacity: false)
        }
        guard !fresh.isEmpty else { return nil }
        return emit(fresh, at: segment.origin + first - segment.rawStart)
    }

    /// A segment's end: a converted segment's last frames, fitted to its exact length within
    /// the rounding limit; before a change, everything an approximate seek held back for padding.
    private func finishSegment() throws -> NativePCMDecoder.Packet? {
        guard !segment.flushed else { return nil }
        segment.flushed = true
        if let conversion = segment.conversion {
            try conversion.finish(adjustingBy: converterOutputAdjustment)
            let length = segment.outputFrames(conversion.fed)
            let difference = length - conversion.produced
            joinCorrections.append(difference)
            MP3SegmentJoinDiagnostics.record(correction: difference, limit: Self.joinRoundingLimit)
            if abs(difference) <= Self.joinRoundingLimit {
                conversion.fit(length - conversion.emitted)
            } else {
                // Not rounding: keep what the converter returned and move what follows.
                originShift -= difference
            }
            return emitConverted(frames: conversion.heldFrames)
        }
        if rangeOrigin != nil, nextSegment != nil, !rangeTail.isEmpty {
            return emitRange(frames: retainedTailFrames)
        }
        // The source continues in another format: what was held as declared padding is audio.
        if nextSegment != nil, !declaredTail.isEmpty {
            let tail = declaredTail
            declaredTail.removeAll(keepingCapacity: false)
            return emit(tail, at: segment.origin + declaredTailStart - segment.rawStart)
        }
        return nil
    }

    /// The next configuration's first batch starts a new segment and converter.
    private func begin(_ batch: NativeMP3PacketParser.Batch) throws {
        let start: CMTime
        if let rangeOrigin {
            guard let origin = batch.rangeOrigin else { throw Failure.invalidBatch }
            start = origin - rangeOrigin
        } else { start = batch.startTime }
        segment = try Segment(format: batch.format, rawStart: batch.firstFrame, start: start,
            delay: (rangeOrigin == nil ? timing.primingFrameCount ?? 0 : 0) - originShift, timing: timing,
            maximumFrames: maximumOutputFrames)
        spliced = true
        nextSegment = nil
        pending = try segment.compressed(batch)
        emittedFrames = segment.origin
    }

    /// Approximate byte seeks keep local decoded counts and a separate source
    /// clock. Hold only declared trailing padding until real EOF; a recoverable
    /// interruption must release that held audio rather than trim it.
    private func complete() throws -> Step {
        guard decodedFrames == acceptedFrames else { throw Failure.incompleteStream }
        if rangeOrigin != nil {
            while drainingSourceFailure, !rangeTail.isEmpty {
                if let packet = emitRange(frames: min(retainedTailFrames, maximumOutputFrames)) { return .audio(packet) }
            }
            if !spliced {
                let available = acceptedFrames - firstFrame
                let trimmed = drainingSourceFailure ? 0 : min(available, timing.remainderFrameCount ?? 0)
                guard emittedFrames == available - trimmed else { throw Failure.incompleteStream }
            }
            rangeTail.removeAll(keepingCapacity: false)
        } else if !spliced {
            declaredTail.removeAll(keepingCapacity: false)
            guard drainingSourceFailure || (timing.encodedFrameCount.map({ $0 == decodedFrames }) ?? true),
                  emittedFrames == max(0, min(acceptedFrames - (timing.primingFrameCount ?? 0),
                      timing.validFrameCount ?? Int64.max)) else { throw Failure.incompleteStream }
        }
        decodingEnded = true
        return .ended
    }

    private func emitRange(frames: Int) -> NativePCMDecoder.Packet? {
        let count = frames * channels
        let samples = Array(rangeTail.prefix(count))
        rangeTail.removeFirst(count)
        return emit(samples, at: emittedFrames)
    }

    private func emitConverted(frames: Int64) -> NativePCMDecoder.Packet? {
        guard frames > 0, let conversion = segment.conversion else { return nil }
        let index = segment.origin + conversion.emitted
        conversion.emitted += frames
        return emit(conversion.take(Int(frames)), at: index)
    }

    /// Output frames starting at output frame `index`, less any seek admission drops.
    private func emit(_ samples: [Int16], at index: Int64) -> NativePCMDecoder.Packet? {
        let frames = Int64(samples.count / channels)
        emittedFrames = index + frames
        var dropped: Int64 = 0
        if let target = admissionTarget {
            dropped = segment.firstAdmittedFrame(atOrAfter: target).map { min(frames, max(0, $0 - index)) } ?? 0
            if dropped < frames { admissionTarget = nil }
        }
        guard dropped < frames else { return nil }
        let time = CMTime(value: index + dropped, timescale: timing.sampleRate)
        return NativePCMDecoder.Packet(samples: dropped == 0 ? samples : Array(samples[(Int(dropped) * channels)...]),
            sampleRate: Int(timing.sampleRate), channels: channels,
            presentationTime: rangeOrigin.map { $0 + time } ?? time)
    }

    func close() {
        guard !closed else { return }
        closed = true
        outputSamples.removeAll(keepingCapacity: false)
        outputTime = nil
        rangeTail.removeAll(keepingCapacity: false)
        pending = nil
        nextSegment = nil
        segment.converter.reset()
    }

    private func validate() throws {
        guard !closed else { throw Failure.closed }
        if let failure { throw failure }
    }

    /// One run of frames in a single configuration and its own native decoder.
    private final class Segment {
        let configuration: MP3FrameConfiguration
        let converter: AVAudioConverter
        let pcm: AVAudioPCMBuffer
        /// Raw ordinal of its first packet.
        let rawStart: Int64
        /// Output frame of its first decoded frame (before the encoder delay is removed).
        let origin: Int64
        /// Nil when it is already in the stream's format.
        let conversion: Conversion?
        var ended = false, flushed = false
        private let start: CMTime
        private let rate: Int32
        private var admission: Int64??

        init(format: CMAudioFormatDescription, rawStart: Int64, start: CMTime, delay: Int64,
             timing: NativeMP3PacketParser.Timing, maximumFrames: Int) throws {
            guard var basic = format.audioStreamBasicDescription, basic.mFormatID == kAudioFormatMPEGLayer3,
                  basic.mSampleRate.isFinite, basic.mSampleRate >= 1, basic.mSampleRate.rounded() == basic.mSampleRate,
                  (1...2).contains(basic.mChannelsPerFrame), basic.mFramesPerPacket > 0,
                  start.isNumeric, start.epoch == 0,
                  let input = AVAudioFormat(streamDescription: &basic),
                  let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: basic.mSampleRate,
                      channels: basic.mChannelsPerFrame, interleaved: true),
                  let converter = AVAudioConverter(from: input, to: output),
                  let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(maximumFrames)) else {
                throw Failure.invalidBatch
            }
            configuration = MP3FrameConfiguration(basic)
            self.converter = converter; self.pcm = pcm
            self.rawStart = rawStart; self.start = start; rate = timing.sampleRate
            origin = Self.outputFrame(start, plus: 0, nativeRate: configuration.sampleRate, rate: rate) - delay
            conversion = configuration.sampleRate == timing.sampleRate && configuration.channels == timing.channels ? nil
                : try Conversion(from: configuration, rate: timing.sampleRate, channels: timing.channels, maximumFrames: maximumFrames)
        }

        func compressed(_ batch: NativeMP3PacketParser.Batch) throws -> AVAudioCompressedBuffer {
            let maximumPacket = batch.descriptions.map(\.mDataByteSize).max() ?? 0
            let buffer = AVAudioCompressedBuffer(format: converter.inputFormat,
                packetCapacity: UInt32(batch.descriptions.count), maximumPacketSize: Int(maximumPacket))
            guard batch.bytes.count <= buffer.byteCapacity, let descriptions = buffer.packetDescriptions else {
                throw Failure.invalidBatch
            }
            batch.bytes.withUnsafeBytes { buffer.data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            batch.descriptions.withUnsafeBufferPointer { descriptions.update(from: $0.baseAddress!, count: $0.count) }
            buffer.byteLength = UInt32(batch.bytes.count)
            buffer.packetCount = UInt32(batch.descriptions.count)
            return buffer
        }

        /// Output frames for the segment's first `native` decoded frames.
        func outputFrames(_ native: Int64) -> Int64 {
            guard conversion != nil else { return native }
            return Self.outputFrame(start, plus: native, nativeRate: configuration.sampleRate, rate: rate)
                - Self.outputFrame(start, plus: 0, nativeRate: configuration.sampleRate, rate: rate)
        }

        /// Start of the first whole MPEG frame at or after `target`; nil drops nothing.
        /// Frames beginning inside the encoder delay are heard from the first output frame.
        func firstAdmittedFrame(atOrAfter target: Int64) -> Int64? {
            if let admission { return admission }
            var result: Int64?
            if target > max(origin, 0) {
                let size = configuration.framesPerPacket
                if conversion == nil {
                    result = origin + (target - origin + size - 1) / size * size
                } else {
                    var frame = max(0, (target - origin) * Int64(configuration.sampleRate) / (Int64(rate) * size) - 1)
                    while origin + outputFrames(frame * size) < target { frame += 1 }
                    result = origin + outputFrames(frame * size)
                }
            }
            admission = .some(result)
            return result
        }

        /// round((time + native ÷ nativeRate) × rate), halves up, exactly.
        static func outputFrame(_ time: CMTime, plus native: Int64, nativeRate: Int32, rate: Int32) -> Int64 {
            let denominator = Int128(time.timescale) * Int128(nativeRate)
            let numerator = (Int128(time.value) * Int128(nativeRate) + Int128(native) * Int128(time.timescale)) * Int128(rate)
            let twice = 2 * numerator + denominator, divisor = 2 * denominator
            var quotient = twice / divisor
            if twice % divisor != 0, twice < 0 { quotient -= 1 }
            return Int64(clamping: quotient)
        }
    }

    /// A segment's decoded audio converted to the stream's channel count and rate.
    private final class Conversion {
        private let inputChannels: Int, outputChannels: Int
        private let resampler: AVAudioConverter?
        private let input: AVAudioPCMBuffer?
        private let output: AVAudioPCMBuffer?
        /// Native frames converted so far.
        private(set) var fed: Int64 = 0
        /// Output frames the conversion returned, and those emitted so far.
        private(set) var produced: Int64 = 0
        var emitted: Int64 = 0
        private var held: [Int16] = []
        private var last: [Int16]
        var heldFrames: Int64 { Int64(held.count / outputChannels) }

        init(from configuration: MP3FrameConfiguration, rate: Int32, channels: Int, maximumFrames: Int) throws {
            inputChannels = configuration.channels; outputChannels = channels
            last = Array(repeating: 0, count: channels)
            guard configuration.sampleRate != rate else { resampler = nil; input = nil; output = nil; return }
            // Resample the fewer channels: mix down before, copy up after.
            let mixed = AVAudioChannelCount(min(inputChannels, outputChannels))
            guard let from = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(configuration.sampleRate),
                      channels: mixed, interleaved: true),
                  let to = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: mixed, interleaved: true),
                  let converter = AVAudioConverter(from: from, to: to),
                  let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(maximumFrames)),
                  let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: 8192) else { throw Failure.invalidBatch }
            // Normal priming consumes the converter's own lookahead before its first
            // output and supplies it at the end, so output is aligned with input.
            converter.primeMethod = .normal
            resampler = converter; self.input = input; self.output = output
        }

        func convert(_ samples: UnsafeBufferPointer<Int16>) throws {
            let frames = samples.count / inputChannels
            fed += Int64(frames)
            guard let resampler, let input else { append(mix(samples, frames: frames)); return }
            let mixed = mix(samples, frames: frames)
            guard frames <= Int(input.frameCapacity), let destination = input.int16ChannelData?[0] else { throw Failure.conversion }
            mixed.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: $0.count) }
            input.frameLength = AVAudioFrameCount(frames)
            try resample(resampler, supplying: frames > 0 ? input : nil, end: false)
        }

        /// The converter's last frames, at the segment's end (`extra`: see converterOutputAdjustment).
        func finish(adjustingBy extra: Int64) throws {
            if let resampler {
                try resample(resampler, supplying: nil, end: true)
                resampler.reset()
            }
            if extra > 0 { append(Array(repeating: 0, count: Int(extra) * min(inputChannels, outputChannels))) }
            if extra < 0 {
                let removed = min(Int(-extra) * outputChannels, held.count)
                held.removeLast(removed); produced -= Int64(removed / outputChannels)
            }
        }

        /// Cut the held frames to exactly `frames`, or extend them by repeating the last
        /// output frame (silence only if the conversion returned nothing).
        func fit(_ frames: Int64) {
            let wanted = Int(max(0, frames)) * outputChannels
            if held.count > wanted { held.removeLast(held.count - wanted) }
            while held.count < wanted { held += last }
        }

        func take(_ frames: Int) -> [Int16] {
            let count = frames * outputChannels
            let result = Array(held.prefix(count))
            held.removeFirst(count)
            return result
        }

        private func mix(_ samples: UnsafeBufferPointer<Int16>, frames: Int) -> [Int16] {
            guard inputChannels == 2, outputChannels == 1 else { return Array(samples) }
            return (0..<frames).map { Int16((Int32(samples[2 * $0]) + Int32(samples[2 * $0 + 1])) / 2) }
        }

        private func append(_ mixed: [Int16]) {
            let before = held.count
            if inputChannels == 1, outputChannels == 2 {
                held.reserveCapacity(held.count + mixed.count * 2)
                for sample in mixed { held.append(sample); held.append(sample) }
            } else { held += mixed }
            produced += Int64((held.count - before) / outputChannels)
            if held.count >= outputChannels { last = Array(held.suffix(outputChannels)) }
        }

        private func resample(_ converter: AVAudioConverter, supplying source: AVAudioPCMBuffer?, end: Bool) throws {
            guard let output else { return }
            var supplied = source == nil
            while true {
                var error: NSError?
                var given: AVAudioPCMBuffer?
                output.frameLength = 0
                let status = converter.convert(to: output, error: &error) { _, state in
                    if !supplied, let source {
                        supplied = true; given = source
                        state.pointee = .haveData
                        return source
                    }
                    state.pointee = end ? .endOfStream : .noDataNow
                    return nil
                }
                withExtendedLifetime(given) {}
                if let error { throw error }
                guard status != .error, let samples = output.int16ChannelData?[0] else { throw Failure.conversion }
                let count = Int(output.frameLength) * Int(output.format.channelCount)
                append(Array(UnsafeBufferPointer(start: samples, count: count)))
                // A full output buffer (haveData) leaves more to collect.
                if status == .endOfStream || status == .inputRanDry || output.frameLength == 0 { return }
            }
        }
    }
}

/// Converted MP3 segments against their timeline length (see NativeMP3PCMDecoder). Process-wide
/// so tests can assert every difference stays within the rounding limit; any beyond it is logged.
enum MP3SegmentJoinDiagnostics {
    struct Totals: Equatable, Sendable { var segments = 0; var corrected = 0; var largest: Int64 = 0; var anomalies = 0 }
    private static let totals = Mutex(Totals())
    private static let log = Logger(subsystem: "org.nottennapod.app", category: "playback")
    static var current: Totals { totals.withLock { $0 } }
    static func reset() { totals.withLock { $0 = Totals() } }
    static func record(correction: Int64, limit: Int64) {
        let size = abs(correction)
        totals.withLock {
            $0.segments += 1
            if size > 0 { $0.corrected += 1 }
            $0.largest = max($0.largest, size)
            if size > limit { $0.anomalies += 1 }
        }
        if size > limit {
            log.error("MP3 format change: converted segment \(correction) frames from its length, more than \(limit); kept, later segments moved")
        }
    }
}

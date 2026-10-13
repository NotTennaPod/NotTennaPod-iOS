import CoreMedia
import Foundation

/// Converts retained native packets on a dedicated executor while extraction
/// continues independently. A replacement can retire a read lease without
/// stopping an item-owned producer.
actor NativeBufferedAudioDecoder: PCMDecoding {
    nonisolated let sampleRate: Int, channels: Int
    nonisolated let startFrame: Int64
    nonisolated let decodingStartFrame: Int64
    nonisolated let bufferState: PCMBufferState?
    nonisolated let sourceFailure: PCMSourceFailure?
    private nonisolated let reader: Reader
    private var cancelled = false, reading = false

    static func open(producer: NativeAudioPacketProducer, ownsProducer: Bool = true,
                     maximumFrames: Int = 4096, start: CMTime = .zero,
                     admission: NativeAudioSeekAdmission = .exactFrame) async throws -> NativeBufferedAudioDecoder {
        let reader = Reader(producer: producer, ownsProducer: ownsProducer, admission: admission)
        return try await withTaskCancellationHandler {
            do {
                let format = try await reader.prepare(maximumFrames: maximumFrames, start: start)
                try Task.checkCancellation()
                return NativeBufferedAudioDecoder(reader: reader, format: format, producer: producer)
            } catch { reader.interrupt(); await reader.close(); throw error }
        } onCancel: { reader.interrupt() }
    }
    private init(reader: Reader, format: Reader.Format, producer: NativeAudioPacketProducer) {
        self.reader = reader; sampleRate = format.sampleRate; channels = format.channels
        startFrame = format.startFrame; decodingStartFrame = format.decodingStartFrame
        bufferState = producer.bufferState; sourceFailure = producer.sourceFailure
    }
    func next() async throws -> NativePCMDecoder.Packet? {
        guard !cancelled else { throw CancellationError() }
        guard !reading else { throw FFmpegPCMDecoder.Failure.concurrentRead }
        reading = true; defer { reading = false }
        return try await withTaskCancellationHandler {
            do {
                let packet = try await reader.next()
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                return packet
            } catch { await cancel(); throw error }
        } onCancel: { reader.interrupt() }
    }
    func updatePlayback(_ state: PCMPlaybackLoadState) async throws {
        guard !cancelled else { throw CancellationError() }
        try reader.updatePlayback(state)
    }
    nonisolated func cancel() async { reader.interrupt(); await retire() }
    private func retire() async { cancelled = true; await reader.close() }
    deinit { reader.interrupt() }

    private actor Reader {
        struct Format: Sendable { let sampleRate: Int, channels: Int; let startFrame: Int64, decodingStartFrame: Int64 }
        nonisolated private let executor = BlockingReadExecutor()
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        nonisolated private let producer: NativeAudioPacketProducer
        nonisolated private let lease: NativeAudioPacketProducer.ReadLease
        nonisolated private let ownsProducer: Bool
        private var converter: NativeAudioStreamConverter?
        private var finished = false
        private var targetFrame: Int64 = 0
        private var targetTime = CMTime.zero
        private var presentationOffset = CMTime.zero
        private var sourceSamples = [Int16]()
        private var sourceSampleTime = CMTime.zero
        private var sourceTimes = [Int64]()
        private var sourceUnitFrames = 0
        private let admission: NativeAudioSeekAdmission
        /// Raw ADTS segments after a configuration change: each gets its own
        /// converter once the previous one has drained, and its PCM is converted
        /// to the stream's first format (also after a seek into another segment)
        /// and continues the presented clock.
        private var segment = 0, maximumFrames = 0
        private var nextSegment: NativeAudioStreamParser.Batch?
        private var normalizer: NativeAudioSegmentNormalizer?
        private var continuous = false, clockStarted = false
        private var decodedEnd = CMTime.zero
        private var output: (sampleRate: Int, channels: Int) = (0, 0)
        private var ready: [NativePCMDecoder.Packet] = []
        init(producer: NativeAudioPacketProducer, ownsProducer: Bool, admission: NativeAudioSeekAdmission) {
            self.producer = producer; self.ownsProducer = ownsProducer; lease = producer.makeReadLease()
            self.admission = admission
        }
        func prepare(maximumFrames: Int, start: CMTime) throws -> Format {
            guard (1...65536).contains(maximumFrames) else { throw NativeAudioStreamParser.Failure.invalidCapacity }
            guard start.isNumeric, start.epoch == 0, start >= .zero else { throw NativePCMDecoder.Failure.invalidStart }
            let streamConfiguration = try lease.configuration()
            sourceUnitFrames = Int(streamConfiguration.basic.mFramesPerPacket)
            // A seek can begin inside a later raw ADTS segment; the output keeps
            // the stream's first format either way.
            let first = try lease.next()
            let configuration = first?.configuration ?? streamConfiguration
            segment = first?.segment ?? 0
            self.maximumFrames = maximumFrames
            output = NativeAudioStreamConverter.outputFormat(streamConfiguration)
            let target = CMTimeConvertScale(start, timescale: Int32(output.sampleRate), method: .roundTowardZero)
            guard target.isNumeric, target.value >= 0 else { throw NativePCMDecoder.Failure.invalidStart }
            targetFrame = target.value
            targetTime = start
            if let sourceStart = producer.adtsStart {
                let frame = CMTimeConvertScale(sourceStart.time, timescale: Int32(configuration.basic.mSampleRate), method: .roundTowardZero)
                presentationOffset = sourceStart.time - frame
            }
            if let edit = producer.mp4Edit {
                presentationOffset = CMTime(value: -edit.mediaStart, timescale: Int32(edit.mediaScale))
            }
            let origin = first?.firstFrame ?? 0
            let converter = try NativeAudioStreamConverter(configuration: configuration, maximumFrames: producer.hasMP4SourceTiming ? sourceUnitFrames : maximumFrames, firstFrame: origin)
            if let first { try accept(first, converter: converter) }
            else { finished = true; converter.finish(afterSourceFailure: producer.bufferState.sourceRetry?.committedError != nil) }
            self.converter = converter
            if (converter.sampleRate, converter.channels) != output {
                normalizer = try NativeAudioSegmentNormalizer(sampleRate: converter.sampleRate, channels: converter.channels,
                    outputSampleRate: output.sampleRate, outputChannels: output.channels)
                continuous = true
            }
            let decodingStart = try NativeAudioFormatSelection.frames(origin, from: Double(converter.sampleRate), to: Double(output.sampleRate))
            return Format(sampleRate: output.sampleRate, channels: output.channels, startFrame: targetFrame, decodingStartFrame: decodingStart)
        }
        func next() throws -> NativePCMDecoder.Packet? {
            while true {
                guard let converter else { throw CancellationError() }
                try Task.checkCancellation(); try producer.sourceFailure.check()
                if !ready.isEmpty {
                    if let admitted = admission.admit(ready.removeFirst(), at: targetTime) { return admitted }
                    continue
                }
                switch try converter.next() {
                case .audio(let decoded):
                    guard let packet = try sourcePacket(decoded) else { continue }
                    let timed = presentationOffset == .zero && producer.mp4Edit == nil ? packet : NativePCMDecoder.Packet(samples: packet.samples,
                        sampleRate: packet.sampleRate, channels: packet.channels,
                        presentationTime: producer.mp4Edit == nil ? packet.presentationTime + presentationOffset
                            : CMTimeConvertScale(packet.presentationTime + presentationOffset, timescale: 1_000_000, method: .roundTowardZero),
                        startsDecodedBuffer: packet.startsDecodedBuffer, discontinuity: packet.discontinuity,
                        uneditedTime: packet.uneditedTime)
                    guard continuous else {
                        decodedEnd = timed.presentationTime + CMTime(value: Int64(timed.frameCount), timescale: Int32(timed.sampleRate))
                        clockStarted = true
                        if let admitted = admission.admit(timed, at: targetTime) { return admitted }
                        continue
                    }
                    // A presentation that starts in another segment starts at its first frame.
                    if !clockStarted { decodedEnd = timed.presentationTime; clockStarted = true }
                    try present(normalizer?.process(timed.samples) ?? timed.samples)
                case .ended:
                    guard sourceSamples.isEmpty && sourceTimes.isEmpty else { throw NativeMP3PCMDecoder.Failure.incompleteStream }
                    if let tail = try normalizer?.finish() { try present(tail) }
                    normalizer = nil
                    guard let batch = nextSegment else {
                        if ready.isEmpty { return nil }
                        continue
                    }
                    // The previous segment has drained completely: start the next
                    // one at its first frame, presented right after it.
                    nextSegment = nil; segment = batch.segment; continuous = true
                    let configuration = try batch.configuration ?? lease.configuration()
                    let replacement = try NativeAudioStreamConverter(configuration: configuration,
                        maximumFrames: maximumFrames, firstFrame: batch.firstFrame)
                    if (replacement.sampleRate, replacement.channels) != output {
                        normalizer = try NativeAudioSegmentNormalizer(sampleRate: replacement.sampleRate, channels: replacement.channels,
                            outputSampleRate: output.sampleRate, outputChannels: output.channels)
                    }
                    self.converter = replacement
                    try accept(batch, converter: replacement)
                case .needsInput:
                    guard !finished else { throw NativeAudioStreamParser.Failure.invalidFormat }
                    if let batch = try lease.next() {
                        guard batch.segment == segment else {
                            nextSegment = batch; converter.finish(); continue
                        }
                        try accept(batch, converter: converter)
                    } else {
                        finished = true
                        converter.finish(afterSourceFailure: producer.bufferState.sourceRetry?.committedError != nil)
                    }
                }
            }
        }
        /// PCM of a later segment, in this decoder's format, continuing the clock
        /// without a gap or overlap and in buffers no larger than the converter's.
        private func present(_ samples: [Int16]) throws {
            let size = maximumFrames * output.channels
            for start in stride(from: 0, to: samples.count, by: size) {
                let chunk = Array(samples[start..<min(samples.count, start + size)])
                let packet = NativePCMDecoder.Packet(samples: chunk, sampleRate: output.sampleRate, channels: output.channels,
                    presentationTime: decodedEnd)
                decodedEnd = decodedEnd + CMTime(value: Int64(packet.frameCount), timescale: Int32(output.sampleRate))
                ready.append(packet)
            }
        }
        private func accept(_ batch: NativeAudioStreamParser.Batch, converter: NativeAudioStreamConverter) throws {
            if producer.mp4Sequence != nil {
                guard let times = batch.sourceTimes, times.count == Int(batch.packetCount) else { throw NativeAudioStreamParser.Failure.invalidPacket }
                sourceTimes += times
            }
            try converter.accept(batch)
        }
        private func sourcePacket(_ packet: NativePCMDecoder.Packet) throws -> NativePCMDecoder.Packet? {
            guard producer.hasMP4SourceTiming, let converter else { return packet }
            let frames = sourceUnitFrames
            let size = frames * converter.channels
            // inputRanDry can split native output at arbitrary frame offsets.
            // Admission operates on the source AAC access unit, so retain at
            // most two units while joining those fragments without altering PCM.
            if sourceSamples.isEmpty { sourceSampleTime = packet.presentationTime }
            guard packet.presentationTime == sourceSampleTime + CMTime(value: Int64(sourceSamples.count / converter.channels), timescale: Int32(converter.sampleRate)),
                  packet.samples.count <= size else { throw NativeAudioStreamParser.Failure.invalidPacket }
            sourceSamples += packet.samples
            guard sourceSamples.count >= size else { return nil }
            var time = sourceSampleTime
            if producer.mp4Sequence != nil {
                guard !sourceTimes.isEmpty else { throw NativeAudioStreamParser.Failure.invalidPacket }
                time = CMTime(value: sourceTimes.removeFirst(), timescale: 1_000_000)
            }
            let result = NativePCMDecoder.Packet(samples: Array(sourceSamples.prefix(size)), sampleRate: converter.sampleRate,
                channels: converter.channels, presentationTime: time, uneditedTime: try uneditedTime())
            sourceSamples.removeFirst(size)
            sourceSampleTime = sourceSampleTime + CMTime(value: Int64(frames), timescale: Int32(converter.sampleRate))
            return result
        }

        private func uneditedTime() throws -> CMTime {
            guard let sequence = producer.mp4Sequence, let converter else { return sourceSampleTime }
            let rate = Int32(converter.sampleRate), frames = Int64(sourceUnitFrames)
            let frame = CMTimeConvertScale(sourceSampleTime, timescale: rate, method: .roundTowardZero)
            guard frame.isNumeric, frame.value >= 0, frames > 0, frame.value % frames == 0 else {
                throw NativeAudioStreamParser.Failure.invalidPacket
            }
            let ordinal = frame.value / frames
            var low = 0, high = sequence.count
            while low < high {
                let middle = low + (high - low) / 2
                if sequence[middle].outputPacketOffset <= ordinal { low = middle + 1 }
                else { high = middle }
            }
            guard low > 0 else { throw NativeAudioStreamParser.Failure.invalidPacket }
            let edit = sequence[low - 1], offset = ordinal - edit.outputPacketOffset
            guard offset < edit.packets.count,
                  let raw = Int64(exactly: (Int128(edit.packets.lowerBound) + Int128(offset)) * Int128(frames)) else {
                throw NativeAudioStreamParser.Failure.invalidPacket
            }
            return CMTime(value: raw, timescale: rate)
        }

        nonisolated func updatePlayback(_ state: PCMPlaybackLoadState) throws { try producer.updatePlayback(state) }
        nonisolated func interrupt() { lease.cancel(); if ownsProducer { producer.stop() } }
        func close() async {
            converter = nil; sourceTimes.removeAll(); sourceSamples.removeAll()
            normalizer = nil; nextSegment = nil; ready.removeAll()
            if ownsProducer { await producer.waitForExit() }
        }
    }
}

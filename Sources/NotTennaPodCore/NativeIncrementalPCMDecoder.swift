import AVFoundation
import CoreMedia
import Foundation

/// Sequential native PCM without a declared HTTP extent or a second download.
/// Source seek/retry/duration policy belongs to the playback source.
actor NativeIncrementalPCMDecoder: PCMDecoding {
    nonisolated let sampleRate: Int
    nonisolated let channels: Int
    nonisolated let startFrame: Int64 = 0
    nonisolated var sourceFailure: PCMSourceFailure? { input.sourceFailure }
    private let input: any MediaByteInput
    private let reader: Reader
    private var cancelled = false, reading = false

    static func open(input: any MediaByteInput, maximumFrames: Int = 4096) async throws -> NativeIncrementalPCMDecoder {
        let reader = Reader(input: input)
        do {
            let format = try await withTaskCancellationHandler {
                try await reader.prepare(maximumFrames: maximumFrames)
            } onCancel: { input.cancel() }
            try Task.checkCancellation()
            return NativeIncrementalPCMDecoder(input: input, reader: reader, format: format)
        } catch { input.cancel(); await reader.close(); throw error }
    }
    private init(input: any MediaByteInput, reader: Reader, format: Reader.Format) {
        self.input = input; self.reader = reader; sampleRate = format.sampleRate; channels = format.channels
    }
    deinit { input.cancel() }
    func next() async throws -> NativePCMDecoder.Packet? {
        guard !cancelled else { throw CancellationError() }
        guard !reading else { throw FFmpegPCMDecoder.Failure.concurrentRead }
        reading = true
        defer { reading = false }
        do {
            let packet = try await withTaskCancellationHandler { try await reader.next() } onCancel: { input.cancel() }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            return packet
        } catch { await cancel(); throw error }
    }
    func cancel() async { cancelled = true; input.cancel(); await reader.close() }

    private actor Reader {
        struct Format: Sendable { let sampleRate: Int; let channels: Int }
        nonisolated private let executor = BlockingReadExecutor()
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        let input: any MediaByteInput
        private var parser: NativeAudioStreamParser?
        private var decoder: NativeAudioStreamConverter?
        private var batches: [NativeAudioStreamParser.Batch] = []
        private var position: Int64 = 0
        private var sourceEnded = false, decoderFinished = false
        init(input: any MediaByteInput) { self.input = input }

        func prepare(maximumFrames: Int) throws -> Format {
            try Task.checkCancellation()
            guard (1...65536).contains(maximumFrames) else { throw NativeAudioStreamParser.Failure.invalidCapacity }
            let parser = try NativeAudioStreamParser()
            self.parser = parser
            while parser.configuration == nil { try load() }
            guard let configuration = parser.configuration else { throw NativeAudioStreamParser.Failure.invalidFormat }
            let decoder = try NativeAudioStreamConverter(configuration: configuration, maximumFrames: maximumFrames)
            self.decoder = decoder
            return Format(sampleRate: decoder.sampleRate, channels: decoder.channels)
        }
        func next() throws -> NativePCMDecoder.Packet? {
            guard let decoder else { throw CancellationError() }
            while true {
                try Task.checkCancellation()
                try input.checkFailure()
                switch try decoder.next() {
                case .audio(let packet): return packet
                case .ended: return nil
                case .needsInput:
                    if !batches.isEmpty { try decoder.accept(batches.removeFirst()) }
                    else if sourceEnded {
                        guard !decoderFinished else { throw NativeAudioStreamParser.Failure.invalidFormat }
                        decoderFinished = true; decoder.finish()
                    } else { try load() }
                }
            }
        }
        private func load() throws {
            try Task.checkCancellation()
            guard let parser, !sourceEnded else { throw NativeAudioStreamParser.Failure.closed }
            let bytes = try input.read(at: position, maximumCount: 4096)
            if bytes.isEmpty { sourceEnded = true; batches += try parser.finish() }
            else {
                let next = position.addingReportingOverflow(Int64(bytes.count))
                guard !next.overflow else { throw NativeAudioStreamParser.Failure.invalidCapacity }
                position = next.partialValue; batches += try parser.append(bytes)
            }
        }
        func close() { parser?.close(); parser = nil; decoder = nil; batches.removeAll() }
    }
}

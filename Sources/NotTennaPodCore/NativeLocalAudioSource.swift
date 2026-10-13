import CoreMedia
import Foundation

/// WAV, ADTS, FLAC and MP4 source playback over a retained, read-only local file. This is separate
/// from NativePCMDecoder's exact-frame contract and is selected explicitly.
actor NativeLocalAudioSource {
    private let url: URL
    private let maximumFrames: Int
    private var file: LocalAudioBytes?
    private var format: NativeAudioSourceTimeline.Format?
    private var timeline: NativeAudioSourceTimeline?
    private var producer: NativeAudioPacketProducer?
    private weak var active: NativeAudioSourceDecoder?
    private var operation: (id: UUID, task: Task<NativeAudioSourceDecoder, any Error>)?

    init(url: URL, maximumFrames: Int = 4096, file: LocalAudioBytes? = nil,
         format: NativeAudioSourceTimeline.Format? = nil) throws {
        guard url.isFileURL || file != nil else { throw NativePCMDecoder.Failure.notLocal }
        guard (1...65536).contains(maximumFrames) else { throw NativeAudioStreamParser.Failure.invalidCapacity }
        self.url = url; self.maximumFrames = maximumFrames
        self.file = file; self.format = format
    }
    deinit { producer?.stop() }

    func makeDecoder(start: CMTime = .zero, processStartupTrim: Bool = false) async throws -> NativeAudioSourceDecoder {
        guard start.isNumeric, start.epoch == 0, start >= .zero else { throw NativePCMDecoder.Failure.invalidStart }
        try Task.checkCancellation()
        let id = UUID(), previous = operation?.task
        previous?.cancel()
        let task = Task {
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            await active?.cancel()
            let (file, format) = try await prepareFile()
            if timeline == nil { timeline = try await NativeAudioSourceTimeline.read(input: file.lease(), format: format) }
            guard let timeline else { throw NativePCMDecoder.Failure.invalidFormat }
            guard timeline.supportsNativePacketTimeline else { throw NativePCMDecoder.Failure.invalidFormat }
            let (decodingTimeline, trim) = try timeline.preparingStartupTrim(processStartupTrim)
            let target = timeline.seekable && timeline.mp4EmptyAudioFormat == nil ? start : .zero
            let decoder: any PCMDecoding
            do {
                if let empty = timeline.mp4EmptyAudioFormat {
                    await retireProducer()
                    decoder = try NativeAudioCompletedDecoder(sampleRate: empty.sampleRate, channels: empty.channels, start: .zero, duration: 0)
                } else {
                    let position = CMTimeConvertScale(target, timescale: 1_000_000, method: .roundTowardZero).value
                    let retained = producer?.mp4Edit == decodingTimeline.mp4AudioEdit
                        && producer?.mp4Sequence == decodingTimeline.mp4AudioSequence
                        && producer?.seek(to: position) == true
                    if !retained {
                        await retireProducer()
                        try Task.checkCancellation()
                        if target == .zero && format != .mp4 {
                            producer = NativeAudioPacketProducer(input: file.lease(), timeline: decodingTimeline, format: format)
                        } else if format == .adts, let index = timeline.adtsByteIndex {
                            let point = index.points(at: position).first
                            producer = NativeAudioPacketProducer(input: file.lease(), timeline: decodingTimeline, format: format,
                                adtsStart: .init(bytePosition: point.bytePosition, time: target))
                        } else if format == .flac, timeline.flacByteIndex != nil {
                            producer = NativeAudioPacketProducer(input: file.lease(), timeline: decodingTimeline, format: format, flacStart: target)
                        } else {
                            producer = NativeAudioPacketProducer(input: file.lease(), timeline: decodingTimeline, format: format,
                                indexedStart: target, applyMP4Edits: true)
                        }
                    }
                    guard let producer else { throw NativePCMDecoder.Failure.invalidFormat }
                    decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false,
                        maximumFrames: maximumFrames, start: target, admission: .wholeBuffer)
                }
                do {
                    let prepared = try await NativeAudioSourceDecoder.open(decoder: decoder, timeline: timeline,
                        start: target, admission: .wholeBuffer, startupTrim: trim, owner: self)
                    try Task.checkCancellation()
                    active = prepared
                    return prepared
                } catch { await decoder.cancel(); throw error }
            } catch {
                await retireProducer()
                throw error
            }
        }
        operation = (id, task)
        defer { if operation?.id == id { operation = nil } }
        return try await withTaskCancellationHandler {
            let decoder = try await task.value
            do {
                try Task.checkCancellation()
                guard operation?.id == id else { throw CancellationError() }
                return decoder
            } catch { await decoder.cancel(); throw error }
        } onCancel: { task.cancel() }
    }

    private func prepareFile() async throws -> (LocalAudioBytes, NativeAudioSourceTimeline.Format) {
        if file == nil { file = try LocalAudioBytes(url: url) }
        guard let file else { throw NativePCMDecoder.Failure.invalidFormat }
        if format == nil { format = try NativeAudioSourceTimeline.Format(await file.identify()) }
        guard let format else { throw NativePCMDecoder.Failure.invalidFormat }
        return (file, format)
    }

    private func retireProducer() async {
        guard let producer else { return }
        self.producer = nil
        producer.stop()
        await producer.waitForExit()
    }
}

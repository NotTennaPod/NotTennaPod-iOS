import AVFoundation
import MediaToolbox
import Synchronization

/// The mix owns the tap; the tap retains its state until its finalize callback.
/// Only the setting/error/diagnostic atomics cross threads. All format and DSP
/// state belongs to the serial prepare/process/unprepare callback lifecycle.
@MainActor final class PlaybackVolumeTap {
    private(set) var mix: AVAudioMix
    private let state: VolumeTapState
    var failure: OSStatus { state.failure.load(ordering: .relaxed) }
    var processedFrames: UInt64 { state.frames.load(ordering: .relaxed) }
    var measuredSetting: Int { state.measuredSetting.load(ordering: .acquiring) }
    var measuredBaseVolume: Float { state.measuredBaseVolume.load(ordering: .acquiring) }
    var measuredPowerRatio: Float { state.powerRatio.load(ordering: .relaxed) }

    init(setting: FeedVolumeAdaptation, baseVolume: Float = 1, measure: Bool = false) throws {
        let state = VolumeTapState(setting: setting, baseVolume: baseVolume, measure: measure)
        self.state = state
        let retained = Unmanaged.passRetained(state)
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(), init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<VolumeTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let state = Unmanaged<VolumeTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.prepare(format.pointee)
            }, unprepare: { _ in }, process: { tap, count, flags, buffers, outCount, outFlags in
                let state = Unmanaged<VolumeTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let result = MTAudioProcessingTapGetSourceAudio(tap, count, buffers, outFlags, nil, outCount)
                guard result == noErr else { state.failure.store(result, ordering: .relaxed); outCount.pointee = 0; return }
                state.process(buffers, frames: outCount.pointee,
                    reset: (flags | outFlags.pointee) & kMTAudioProcessingTapFlag_StartOfStream != 0)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreateWithPreferredFormat(kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, nil, &tap)
        guard status == noErr, let tap else {
            retained.release()
            throw PlaybackVolumeError.tapCreation(status)
        }
        let input = AVMutableAudioMixInputParameters()
        // iOS27 default input parameters target the mix of all audio tracks (ID0).
        input.trackID = 0
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [input]
        self.mix = mix
    }

    /// Bind a single selected track directly. The mixed-track API currently does not
    /// deliver samples on the tested iOS27/27.1 runtimes, while a concrete local or
    /// progressive track does. Multiple-track/HLS acceptance remains recorded open.
    func bind(to item: AVPlayerItem, preferConcreteTrack: Bool) {
        let tracks = item.tracks.filter(\.isEnabled).compactMap(\.assetTrack).filter { $0.mediaType == .audio }
        let selected = preferConcreteTrack && tracks.count == 1 ? tracks.first : nil
        let trackID = selected?.trackID ?? 0
        guard item.audioMix == nil || mix.inputParameters.first?.trackID != trackID else { return }
        let input = AVMutableAudioMixInputParameters(track: selected)
        input.trackID = trackID
        input.audioTapProcessor = mix.inputParameters.first?.audioTapProcessor
        let replacement = AVMutableAudioMix(); replacement.inputParameters = [input]
        mix = replacement
        item.audioMix = replacement
    }

    func set(_ setting: FeedVolumeAdaptation) { state.setting.store(setting.rawValue, ordering: .releasing) }
    func setBaseVolume(_ volume: Float) { state.baseVolume.store(volume, ordering: .releasing) }
}

/// The local/progressive AVPlayer route has no queue after the tap, so the whole gain (attenuation and
/// boost) is applied here at render time, through the same stage as processed PCM: every change is
/// joined by its ramp and the enhancer envelope continues; a new stream or format starts afresh.
final class VolumeTapState {
    let setting: Atomic<Int>
    let baseVolume: Atomic<Float>
    let failure = Atomic<OSStatus>(noErr)
    let frames = Atomic<UInt64>(0)
    let measuredSetting = Atomic<Int>(-1)
    let measuredBaseVolume = Atomic<Float>(-1)
    let powerRatio = Atomic<Float>(0)
    private let measure: Bool
    private var format = AudioStreamBasicDescription()
    private var stage: PodcastVolumeStage
    private var sampleBytes = 0
    private var floating = false

    init(setting: FeedVolumeAdaptation, baseVolume: Float, measure: Bool) {
        self.setting = Atomic(setting.rawValue); self.measure = measure
        self.baseVolume = Atomic(baseVolume)
        stage = PodcastVolumeStage(target: Self.target(setting.rawValue, baseVolume), sampleRate: 48000)
    }

    private static func target(_ setting: Int, _ baseVolume: Float) -> PodcastVolumeStage.Target {
        .init((FeedVolumeAdaptation(rawValue: setting) ?? .off).effect(baseVolume: baseVolume), attenuate: true)
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        self.format = format
        floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        sampleBytes = Int(format.mBitsPerChannel / 8)
        if format.mSampleRate > 0 {
            stage = PodcastVolumeStage(target: Self.target(setting.load(ordering: .acquiring), baseVolume.load(ordering: .acquiring)),
                sampleRate: format.mSampleRate)
        }
        guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate > 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              (floating && [4, 8].contains(sampleBytes)) ||
                (!floating && format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && [2, 4].contains(sampleBytes)) else {
            failure.store(kAudioFormatUnsupportedDataFormatError, ordering: .relaxed); return
        }
        failure.store(noErr, ordering: .relaxed)
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames count: Int, reset: Bool) {
        guard count > 0, failure.load(ordering: .relaxed) == noErr else { return }
        let raw = setting.load(ordering: .acquiring)
        let base = baseVolume.load(ordering: .acquiring)
        stage.setTarget(Self.target(raw, base))
        if reset { stage.reset() }
        let steady = !stage.isRamping
        if stage.isIdentity && !measure {
            stage.skip()
            frames.wrappingAdd(UInt64(count), ordering: .relaxed)
            return
        }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        // Validate the complete layout before any sample is changed.
        for buffer in buffers {
            guard buffer.mData != nil, buffer.mNumberChannels > 0,
                  Int(buffer.mDataByteSize) >= count * Int(buffer.mNumberChannels) * sampleBytes else {
                failure.store(kAudioFormatBadPropertySizeError, ordering: .relaxed); return
            }
        }
        var inputPower: Float = 0, outputPower: Float = 0
        for frame in 0..<count {
            var peak: Float = 0
            for buffer in buffers {
                let data = buffer.mData!
                for channel in 0..<Int(buffer.mNumberChannels) {
                    peak = max(peak, abs(read(data, frame * Int(buffer.mNumberChannels) + channel)))
                }
            }
            let gains = stage.frame(peak: peak)
            for buffer in buffers {
                let data = buffer.mData!
                for channel in 0..<Int(buffer.mNumberChannels) {
                    let index = frame * Int(buffer.mNumberChannels) + channel
                    let input = read(data, index)
                    let output = stage.output(input, gains)
                    // Diagnostic mode observes the real decoded/processed samples, then
                    // silences the processed test samples before they reach the output.
                    write(data, index, measure ? 0 : output)
                    if measure { inputPower += input * input; outputPower += output * output }
                }
            }
        }
        frames.wrappingAdd(UInt64(count), ordering: .relaxed)
        // Diagnostics report settled levels only, never a callback that contains a ramp.
        if measure, steady, !stage.isRamping, inputPower > 0 {
            powerRatio.store(outputPower / inputPower, ordering: .relaxed)
            measuredSetting.store(raw, ordering: .releasing)
            measuredBaseVolume.store(base, ordering: .releasing)
        }
    }

    private func read(_ data: UnsafeMutableRawPointer, _ index: Int) -> Float {
        if floating {
            return sampleBytes == 4 ? data.assumingMemoryBound(to: Float.self)[index]
                : Float(data.assumingMemoryBound(to: Double.self)[index])
        }
        return sampleBytes == 2 ? Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
            : Float(data.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
    }
    private func write(_ data: UnsafeMutableRawPointer, _ index: Int, _ value: Float) {
        if floating {
            if sampleBytes == 4 { data.assumingMemoryBound(to: Float.self)[index] = value }
            else { data.assumingMemoryBound(to: Double.self)[index] = Double(value) }
        } else if sampleBytes == 2 {
            data.assumingMemoryBound(to: Int16.self)[index] = Int16(clamping: Int(max(-1, min(1, value)) * 32768))
        } else {
            data.assumingMemoryBound(to: Int32.self)[index] = Int32(clamping: Int64(Double(max(-1, min(1, value))) * 2147483648))
        }
    }
}

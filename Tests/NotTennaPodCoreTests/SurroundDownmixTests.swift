import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// Surround audio plays as stereo with its speaker layout (5.1 as stereo):
/// Lo = L + c·C + c·Ls, Ro = R + c·C + c·Rs, c = 1/√2, LFE omitted, k = 1 (provisional, from AOSP ChannelMix's
/// front and centre levels; not measured on Android), overloads clamped to full scale. FFmpeg layout cases are in
/// PCMStereoDownmixLayoutTests (SwiftPM only: they use the codec module directly).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct SurroundDownmixTests {
    nonisolated static let c = 0.70710678
    nonisolated static func fixture(_ name: String) throws -> URL {
        try FFmpegBufferedSeekReferenceTests.resource(name, directory: "Surround")
    }
    /// The labelled fixtures' tone per position (`make-surround.sh`) and its gains into left and right.
    nonisolated static let fivePointOne: [(frequency: Double, left: Double, right: Double)] = [
        (500, 1, 0), (700, 0, 1), (300, c, c), (60, 0, 0), (1100, c, 0), (1300, 0, c)]
    nonisolated static let sevenPointOne: [(frequency: Double, left: Double, right: Double)] = [(500, 1, 0), (700, 0, 1),
        (300, c, c), (60, 0, 0), (1100, 0.5, 0), (1300, 0, 0.5), (1700, 0.5, 0), (1900, 0, 0.5)]

    /// Sine amplitude at `frequency` in one interleaved channel (Goertzel, after the decoder settles).
    nonisolated static func amplitude(_ samples: [Int16], channels: Int, channel: Int, rate: Int, frequency: Double) -> Double {
        let frames = samples.count / channels, start = min(frames, 4096), end = max(start, frames - 2048)
        let k = 2 * cos(2 * Double.pi * frequency / Double(rate))
        var a = 0.0, b = 0.0
        for frame in start..<end { let next = Double(samples[frame * channels + channel]) + k * a - b; b = a; a = next }
        let n = Double(end - start)
        return 2 * (a * a + b * b - k * a * b).squareRoot() / n
    }

    /// Plays a session to its end through the application's processed route.
    private func play(_ url: URL, from position: Int64 = 0) async throws -> (samples: [Int16], rate: Int, channels: Int) {
        let root = URL.temporaryDirectory.appendingPathComponent("surround-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let owner = PCMPlaybackFactory(cacheDirectory: root, makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let factory = try #require(try await owner.processedIfSupported(url: url, proxy: PodcastProxy(), credentials: nil, userAgent: "test"))
        let session = try await factory.make(positionMilliseconds: position, parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        try await session.prepare(); try session.play()
        let output = try #require(outputs.last)
        let deadline = ContinuousClock.now + .seconds(30)
        while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        try #require(session.state == .ended && session.failure == nil)
        var bytes = Data(), rate = 0, channels = 0
        for buffer in output.buffers {
            let description = try #require(buffer.formatDescription.audioStreamBasicDescription)
            rate = Int(description.mSampleRate); channels = Int(description.mChannelsPerFrame)
            bytes.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) }))
        }
        return (PCMTestFixture.samples(bytes), rate, channels)
    }

    nonisolated static func same(_ a: [(Float, Float)], _ b: [(Float, Float)]) -> Bool {
        a.elementsEqual(b) { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    @Test func coreAudioLayoutsKeepEveryKnownPosition() throws {
        let c = Float(Self.c)
        // Core Audio's AAC 5.1 order: C L R Ls Rs LFE.
        let tagged = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_AAC_5_1))
        let aac = try #require(PCMStereoDownmix(layout: tagged, channels: 6))
        let aacGains: [(Float, Float)] = [(c, c), (1, 0), (0, 1), (c, 0), (0, c), (0, 0)]
        #expect(Self.same(aac.gains.map { ($0.left, $0.right) }, aacGains))
        // Full scale in every channel clamps; a lower level sums exactly.
        let full = [Int16](repeating: .max, count: 6) + [Int16](repeating: .min, count: 6) + [Int16](repeating: 8000, count: 6)
        #expect(full.withUnsafeBufferPointer { aac.apply($0) } == [.max, .max, .min, .min, 19_314, 19_314])
        // A layout with one channel this matrix does not know keeps every other position; that one is silent.
        let partial = try #require(PCMStereoDownmix(labels: [kAudioChannelLabel_Right, kAudioChannelLabel_Left,
            kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround,
            kAudioChannelLabel_Discrete_0], channels: 6))
        #expect([Int16]([10_000, 0, 0, 0, 0, 0]).withUnsafeBufferPointer { partial.apply($0) } == [0, 10_000])
        #expect([Int16]([0, 0, 0, 0, 0, 10_000]).withUnsafeBufferPointer { partial.apply($0) } == [0, 0])
        // No position at all (discrete channels): FFmpeg's default order for the count (6 = L R C LFE Ls Rs).
        let discrete = try #require(PCMStereoDownmix(labels: (0..<6).map { kAudioChannelLabel_Discrete_0 | UInt32($0) }, channels: 6))
        let defaultGains: [(Float, Float)] = [(1, 0), (0, 1), (c, c), (0, 0), (c, 0), (0, c)]
        #expect(Self.same(discrete.gains.map { ($0.left, $0.right) }, defaultGains))
        // Without positions and without a default layout for the count: unsupported.
        #expect(PCMStereoDownmix(labels: nil, channels: 9) == nil)
    }

    /// A 16-bit WAV: WAVE_FORMAT_EXTENSIBLE with `mask`, or plain PCM without a layout; optionally an
    /// ancillary JUNK chunk of `junk` bytes before the format chunk, padded to even unless `pad` is false.
    nonisolated static func wave(channels: Int, mask: UInt32?, frames: [[Int16]], junk: Int = 0, pad: Bool = true) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: Int) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func u32(_ value: Int) { u16(value); u16(value >> 16) }
        let format = mask == nil ? 16 : 40, bytes = frames.count * channels * 2
        let padding = pad ? junk % 2 : 0, ancillary = junk > 0 ? 8 + junk + padding : 0
        text("RIFF"); u32(4 + ancillary + 8 + format + 8 + bytes); text("WAVE")
        if junk > 0 { text("JUNK"); u32(junk); data.append(Data(repeating: 0x5a, count: junk)); data.append(Data(count: padding)) }
        text("fmt "); u32(format)
        u16(mask == nil ? 1 : 0xfffe); u16(channels); u32(48_000); u32(48_000 * channels * 2); u16(channels * 2); u16(16)
        if let mask {
            u16(22); u16(16); u32(Int(mask))
            data.append(contentsOf: [0x01, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71])
        }
        text("data"); u32(bytes)
        for frame in frames { for sample in frame { u16(Int(UInt16(bitPattern: sample))) } }
        return data
    }

    /// 5.1 (WAVE order FL FR FC LFE BL BR, also FFmpeg's default without a layout); quad's mask puts its
    /// last two channels at the back, not at FFmpeg's 4.0 centres; 7.1's side and back pairs share.
    nonisolated static let waves: [(mask: UInt32?, name: String, gains: [(Double, Double)])] = [
        (0x3f, "5.1 mask", [(1, 0), (0, 1), (c, c), (0, 0), (c, 0), (0, c)]),
        (nil, "no layout", [(1, 0), (0, 1), (c, c), (0, 0), (c, 0), (0, c)]),
        (0x33, "quad mask", [(1, 0), (0, 1), (c, 0), (0, c)]),
        (0x63f, "7.1 mask", [(1, 0), (0, 1), (c, c), (0, 0), (0.5, 0), (0, 0.5), (0.5, 0), (0, 0.5)])]
    @Test(arguments: 0..<4)
    func eachLabelledChannelAloneLandsAtItsGainAndFullScaleClamps(index: Int) async throws {
        let (mask, name, expected) = Self.waves[index]
        let channels = expected.count, block = 4800
        // One channel at a time at ±10000, then every channel at full scale, then all at 8000.
        var frames: [[Int16]] = []
        for channel in 0..<channels {
            for i in 0..<block { var frame = [Int16](repeating: 0, count: channels); frame[channel] = i % 2 == 0 ? 10_000 : -10_000; frames.append(frame) }
        }
        frames += Array(repeating: [Int16](repeating: .max, count: channels), count: block)
        frames += Array(repeating: [Int16](repeating: 8000, count: channels), count: block)
        let url = URL.temporaryDirectory.appendingPathComponent("surround-\(UUID()).wav")
        try Self.wave(channels: channels, mask: mask, frames: frames).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let played = try await play(url)
        #expect(played.channels == 2 && played.rate == 48_000 && played.samples.count == frames.count * 2)
        for (channel, gain) in expected.enumerated() {
            let frame = (channel * block + 10) * 2
            #expect(played.samples[frame] == Int16((10_000 * gain.0).rounded()) && played.samples[frame + 1] == Int16((10_000 * gain.1).rounded()),
                "\(name): channel \(channel) gave \(played.samples[frame]), \(played.samples[frame + 1])")
        }
        let full = (channels * block + 10) * 2, sum = (channels * block + block + 10) * 2
        #expect(played.samples[full] == .max && played.samples[full + 1] == .max)
        let row = expected.reduce(0) { $0 + $1.0 }
        #expect(played.samples[sum] == Int16((8000 * row).rounded()) && played.samples[sum + 1] == Int16((8000 * row).rounded()))
    }

    /// The header reader finds the mask after ancillary chunks (odd with and without its pad byte, beyond
    /// 64 KiB) over reads of any size, keeping only a header's worth of bytes.
    @Test(arguments: [(0, true), (5000, true), (4097, true), (4097, false), (70_000, true)])
    func waveHeaderReaderFindsTheMaskInAnyPieces(junk: Int, pad: Bool) {
        let data = Self.wave(channels: 4, mask: 0x33, frames: [[0, 0, 0, 0]], junk: junk, pad: pad)
        for size in [1, 3, 7, 23, 4096, data.count] {
            var reader = WaveHeaderReader()
            var offset = 0
            while offset < data.count, !reader.finished {
                reader.consume(data[offset..<min(data.count, offset + size)]); offset += size
            }
            #expect(reader.finished && reader.channelMask == 0x33, "junk \(junk), pad \(pad), reads of \(size)")
        }
        var plain = WaveHeaderReader()
        plain.consume(Self.wave(channels: 4, mask: nil, frames: [[0, 0, 0, 0]], junk: junk, pad: pad))
        #expect(plain.finished && plain.channelMask == nil)
    }

    /// The mask still holds end to end when the format chunk comes after an ancillary chunk (beyond 64 KiB
    /// too) and arrives split over reads: back-left content stays at the left and every frame plays.
    /// (Odd chunks are covered by the reader test above: Core Audio itself plays neither form natively,
    /// AudioFileStream stopping at a pad byte and AudioFile needing it.)
    @Test(arguments: [(0, true), (5000, true), (70_000, true)])
    func waveMaskAfterAncillaryChunksLocalFragmentedAndStreamed(junk: Int, pad: Bool) async throws {
        let frames = (0..<4800).map { i -> [Int16] in [0, 0, i % 2 == 0 ? 10_000 : -10_000, 0] }
        let data = Self.wave(channels: 4, mask: 0x33, frames: frames, junk: junk, pad: pad)
        func check(_ samples: [Int16], _ route: String) {
            #expect(samples.count == frames.count * 2, "\(route): \(samples.count / 2) frames")
            #expect(samples.count >= 22 && samples[20] == 7071 && samples[21] == 0, "\(route): \(samples.prefix(22).suffix(2))")
            #expect(stride(from: 1, to: samples.count, by: 2).allSatisfy { samples[$0] == 0 }, "\(route): right output")
        }
        let url = URL.temporaryDirectory.appendingPathComponent("surround-junk-\(UUID()).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        check(try await play(url).samples, "local")
        // The same producer over reads of a few bytes, without random access.
        let timeline = try await NativeAudioSourceTimeline.read(input: ADTSFormatChangeTests.Chunked(data), format: .wav)
        let producer = NativeAudioPacketProducer(input: ADTSFormatChangeTests.Chunked(data, largest: 7, randomAccess: false),
            timeline: timeline, format: .wav)
        check(try await ADTSFormatChangeTests.drain(NativeBufferedAudioDecoder.open(producer: producer)).samples, "fragmented")
        producer.stop()
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/wav"], body: data) }
        defer { server.stop() }
        check(try await play(server.url).samples, "streamed")
    }

    /// Nine channels with no layout, for which FFmpeg has no default: unsupported, as before.
    @Test func layoutlessCountWithoutADefaultIsUnsupported() async throws {
        let frames = (0..<4800).map { _ in (0..<9).map { $0 == 3 ? Int16(10_000) : 0 } }
        let url = URL.temporaryDirectory.appendingPathComponent("surround-nine-\(UUID()).wav")
        try Self.wave(channels: 9, mask: nil, frames: frames).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) { _ = try await play(url) }
    }

    @Test(arguments: ["labelled-5.1.m4a", "labelled-5.1.aac", "labelled-5.1.flac", "labelled-5.1.opus", "labelled-7.1.opus"])
    func everyLabelledToneLandsAtItsStatedGainInEachOutput(name: String) async throws {
        let played = try await play(Self.fixture(name))
        #expect(played.channels == 2)
        // A one-second file, played completely (the codec's own padding aside).
        #expect(abs(Double(played.samples.count / 2) / Double(played.rate) - 1) < 0.03)
        let source = 32768.0 / 8, lossless = name.hasSuffix("flac")
        for tone in name.contains("7.1") ? Self.sevenPointOne : Self.fivePointOne {
            for (channel, gain) in [tone.left, tone.right].enumerated() {
                let measured = Self.amplitude(played.samples, channels: 2, channel: channel, rate: played.rate, frequency: tone.frequency) / source
                if gain == 0 { #expect(measured < 0.03, "\(name): \(tone.frequency) Hz leaks \(measured) into output \(channel)") }
                else { #expect(abs(measured / gain - 1) < (lossless ? 0.005 : 0.06), "\(name): \(tone.frequency) Hz at \(measured), expected \(gain)") }
            }
        }
    }

    @Test(arguments: ["labelled-5.1.m4a", "labelled-5.1.opus"])
    func generalizedReaderDownmixesWithTheSameMatrix(name: String) async throws {
        let data = try Data(contentsOf: Self.fixture(name))
        let reader = try await FFmpegMediaReader.open(input: MemoryInput(data), selection: .init(includeVideo: false))
        var samples: [Int16] = [], rate = 0
        while let event = try await reader.next() {
            guard case .audio(let chunk) = event else { continue }
            #expect(chunk.channels == 2)
            rate = chunk.sampleRate; samples += chunk.samples
        }
        await reader.cancel()
        for tone in Self.fivePointOne {
            for (channel, gain) in [tone.left, tone.right].enumerated() {
                let measured = Self.amplitude(samples, channels: 2, channel: channel, rate: rate, frequency: tone.frequency) / 4096
                if gain == 0 { #expect(measured < 0.03) } else { #expect(abs(measured / gain - 1) < 0.06, "\(tone.frequency) Hz: \(measured)") }
            }
        }
    }

    /// Six channels whose layout changes mid-stream (5.1, then hexagonal): each FFmpeg reader mixes every
    /// frame by its own layout, so back-centre after the change reaches both outputs at 0.5 (not the right
    /// output at 1/√2, as 5.1's back-right would).
    @Test(arguments: ["local", "buffered", "media"])
    func ffmpegReadersFollowALayoutChangeWithTheSameChannelCount(reader kind: String) async throws {
        let url = try Self.fixture("layout-change-6ch.aac")
        var samples: [Int16] = [], rate = 0
        if kind == "media" {
            let reader = try await FFmpegMediaReader.open(input: MemoryInput(try Data(contentsOf: url)), selection: .init(includeVideo: false))
            while let event = try await reader.next() {
                guard case .audio(let chunk) = event else { continue }
                #expect(chunk.channels == 2)
                rate = chunk.sampleRate; samples += chunk.samples
            }
            await reader.cancel()
        } else {
            let reader = kind == "local" ? try FFmpegAudioReader(url: url) : try await FFmpegAudioReader.openBuffered(url: url)
            while let chunk = try await reader.next() {
                #expect(chunk.channels == 2)
                rate = chunk.sampleRate; samples += chunk.samples
            }
            await reader.cancel()
        }
        #expect(rate == 48_000 && abs(samples.count / 2 - 96_000) < 2048, "\(kind): \(samples.count / 2) frames")
        let first = Array(samples.prefix(96_000)), second = Array(samples.dropFirst(96_000))
        for (part, frequency, left, right) in [(first, 500.0, Self.c, 0.0), (second, 700.0, 0.5, 0.5)] {
            for (channel, gain) in [left, right].enumerated() {
                let measured = Self.amplitude(part, channels: 2, channel: channel, rate: rate, frequency: frequency) / 4096
                if gain == 0 { #expect(measured < 0.03, "\(kind) \(frequency) Hz output \(channel): \(measured)") }
                else { #expect(abs(measured / gain - 1) < 0.06, "\(kind) \(frequency) Hz output \(channel): \(measured)") }
            }
        }
    }

    @Test(arguments: ["surround.m4a", "surround.opus"])
    func centreDialogueOpensAndPlaysInBothOutputsAndSeeksToTheTail(name: String) async throws {
        let url = try Self.fixture(name)
        let played = try await play(url)
        #expect(played.channels == 2 && abs(Double(played.samples.count / 2) / Double(played.rate) - 20) < 0.05)
        // The speech is only on the centre channel: it reaches both outputs at 1/√2 (−3 dB).
        let reference = try AVAudioFile(forReading: Self.fixture("surround.m4a"), commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: reference.processingFormat, frameCapacity: AVAudioFrameCount(reference.length)))
        try reference.read(into: buffer)
        let centre = buffer.floatChannelData![0] // AAC 5.1 order: C L R Ls Rs LFE
        let centreLevel = 10 * log10((0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(centre[$1] * centre[$1]) } / Double(buffer.frameLength))
        for channel in 0..<2 {
            let values = stride(from: channel, to: played.samples.count, by: 2).map { played.samples[$0] }
            let level = PCMTestFixture.levelDecibels(values)
            #expect(abs(level - (centreLevel - 3.01)) < (name.hasSuffix("opus") ? 1 : 0.5), "\(name) output \(channel): \(level) dB, centre \(centreLevel) dB")
        }
        // A seek near the end plays the rest, through its last frames.
        let tail = try await play(url, from: 19_000)
        #expect(tail.channels == 2 && abs(Double(tail.samples.count / 2) / Double(tail.rate) - 1) < 0.15)
        #expect(PCMTestFixture.levelDecibels(Array(tail.samples.suffix(4800))) > -60)
    }

    private final class MemoryInput: MediaByteInput {
        let data: Data
        init(_ data: Data) { self.data = data }
        var length: Int64? { Int64(data.count) }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func checkFailure() throws {}
        func cancel() {}
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + maximumCount))
        }
    }
}

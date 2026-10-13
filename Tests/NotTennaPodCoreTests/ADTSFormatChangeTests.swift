import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Raw ADTS whose decoder configuration changes mid-stream (an inserted ad encoded differently) plays
/// every segment, in the stream's first format, with a continuous clock. Ordinary ADTS
/// keeps its native route, duration and constant-bitrate seeking.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct ADTSFormatChangeTests {
    nonisolated static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: FFmpegBufferedSeekReferenceTests.resource(name, directory: "PlaybackDecoder"))
    }
    /// Independent frame walk: every segment's configuration, start byte and duration.
    struct Segment: Equatable { let rate: Int, channels: Int, offset: Int, frames: Int
        var seconds: Double { Double(frames * 1024) / Double(rate) }
    }
    nonisolated static func segments(_ data: Data) -> [Segment] {
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        var result: [Segment] = [], offset = 0
        while offset + 7 <= data.count, data[offset] == 0xff, data[offset + 1] & 0xf6 == 0xf0 {
            let rate = rates[Int(data[offset + 2] >> 2 & 15)], channels = Int((data[offset + 2] & 1) << 2 | data[offset + 3] >> 6)
            let size = Int(data[offset + 3] & 3) << 11 | Int(data[offset + 4]) << 3 | Int(data[offset + 5] >> 5)
            if let last = result.last, last.rate == rate, last.channels == channels {
                result[result.count - 1] = .init(rate: rate, channels: channels, offset: last.offset, frames: last.frames + 1)
            } else { result.append(.init(rate: rate, channels: channels, offset: offset, frames: 1)) }
            offset += size
        }
        return result
    }
    /// The show (three copies of the first speech segment), the ad and the rest: a change late in the file.
    nonisolated static func lateChange() throws -> Data {
        let data = try fixture("dai_adts_mono.aac"), parts = segments(data)
        let show = data.prefix(parts[1].offset)
        return show + show + show + data.dropFirst(parts[1].offset)
    }

    /// Positional reads of at most `largest` bytes; optionally not seekable.
    final class Chunked: MediaByteInput {
        let data: Data, largest: Int, randomAccess: Bool
        init(_ data: Data, largest: Int = .max, randomAccess: Bool = true) {
            self.data = data; self.largest = largest; self.randomAccess = randomAccess
        }
        var length: Int64? { Int64(data.count) }
        var supportsRandomAccess: Bool { randomAccess }
        func prepareForSeek() {}
        func checkFailure() throws {}
        func cancel() {}
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            guard offset < data.count else { return Data() }
            // Odd sizes split headers and frames at every possible position.
            let count = min(maximumCount, largest == .max ? .max : 1 + Int(offset % Int64(largest)), data.count - Int(offset))
            return data.subdata(in: Int(offset)..<(Int(offset) + count))
        }
    }

    struct Decoded { var samples: [Int16] = []; var rate = 0, channels = 0; var start = CMTime.zero }
    /// Every packet of a decoder; packets must follow each other without a gap or overlap.
    nonisolated static func drain(_ decoder: any PCMDecoding) async throws -> Decoded {
        var result = Decoded(rate: decoder.sampleRate, channels: decoder.channels, start: decoder.startTime)
        var expected: CMTime?
        while let packet = try await decoder.next() {
            #expect(packet.sampleRate == result.rate && packet.channels == result.channels)
            if let expected { #expect(abs((packet.presentationTime - expected).seconds) < 0.5 / Double(result.rate)) }
            else { result.start = packet.presentationTime }
            expected = packet.presentationTime + CMTime(value: Int64(packet.frameCount), timescale: Int32(packet.sampleRate))
            result.samples += packet.samples
        }
        await decoder.cancel()
        return result
    }
    nonisolated static func local(_ data: Data, start: Double = 0) async throws -> Decoded {
        let url = URL.temporaryDirectory.appendingPathComponent("adts-change-\(UUID()).aac")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try NativeLocalAudioSource(url: url, format: .adts)
        return try await drain(source.makeDecoder(start: CMTime(seconds: start, preferredTimescale: 1000)))
    }
    /// Share of a channel's power at `frequency` over [from, to) seconds of the decoded output.
    nonisolated static func tone(_ decoded: Decoded, channel: Int, frequency: Double, from: Double, to: Double) -> Double {
        let lower = max(0, Int(from * Double(decoded.rate))), upper = min(decoded.samples.count / decoded.channels, Int(to * Double(decoded.rate)))
        guard upper > lower else { return 0 }
        let coefficient = 2 * cos(2 * Double.pi * frequency / Double(decoded.rate))
        var previous = 0.0, beforePrevious = 0.0, total = 0.0
        for frame in lower..<upper {
            let x = Double(decoded.samples[frame * decoded.channels + channel])
            total += x * x
            let current = x + coefficient * previous - beforePrevious
            beforePrevious = previous; previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return total > 0 ? 2 * power / (Double(upper - lower) * total) : 0
    }
    nonisolated static func seconds(_ decoded: Decoded) -> Double { Double(decoded.samples.count / decoded.channels) / Double(decoded.rate) }

    @Test func scannerFindsConfirmedChangesAtTheirFramesInAnyFragmentation() throws {
        for name in ["changing.aac", "dai_adts_mono.aac", "dai_adts_48k.aac", "late"] {
            let data = name == "late" ? try Self.lateChange() : try Self.fixture(name)
            let expected = Self.segments(data).dropFirst().map(\.offset)
            for largest in [Int.max, 4096, 333, 7, 1] {
                var scanner = ADTSSegmentScanner(start: 0)
                var bytes = Data(), changes: [Int] = [], offset = 0
                func take(_ pieces: [ADTSSegmentScanner.Piece]) {
                    for piece in pieces {
                        switch piece {
                        case .bytes(let part): bytes += part
                        case .segment: changes.append(bytes.count)
                        }
                    }
                }
                while offset < data.count {
                    // Odd read sizes split headers and frames at every position.
                    let count = min(largest == .max ? data.count : 1 + (offset * 7919) % largest, data.count - offset)
                    take(scanner.consume(data.subdata(in: offset..<(offset + count)), eof: false))
                    offset += count
                }
                take(scanner.consume(Data(), eof: true))
                #expect(bytes == data && changes == expected && scanner.isActive, "\(name) in reads of \(largest)")
            }
        }
        // Ordinary ADTS has no change; one damaged header is not a segment.
        var ordinary = try Data(contentsOf: FFmpegBufferedSeekReferenceTests.resource("ticks.aac", directory: "HeardRate"))
        var position = 0
        for _ in 0..<50 { position += Int(ordinary[position + 3] & 3) << 11 | Int(ordinary[position + 4]) << 3 | Int(ordinary[position + 5] >> 5) }
        ordinary[position + 3] ^= 0x40 // that frame alone claims another channel configuration
        var scanner = ADTSSegmentScanner(start: 0)
        let pieces = scanner.consume(ordinary, eof: true)
        #expect(pieces == [.bytes(ordinary)] && scanner.isActive)
    }

    @Test(arguments: ["changing.aac", "dai_adts_mono.aac", "dai_adts_48k.aac", "late"])
    func everySegmentPlaysInTheFirstFormatWithAContinuousClock(name: String) async throws {
        let data = name == "late" ? try Self.lateChange() : try Self.fixture(name), parts = Self.segments(data)
        #expect(parts.count == (name == "changing.aac" ? 2 : 3))
        for (largest, randomAccess) in [(Int.max, true), (333, false)] {
            // The app's local route, then the same producer over fragmented non-range reads.
            let decoded: Decoded
            if largest == .max { decoded = try await Self.local(data) }
            else {
                let input = Chunked(data, largest: largest, randomAccess: randomAccess)
                let timeline = try await NativeAudioSourceTimeline.read(input: Chunked(data), format: .adts)
                let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: .adts)
                decoded = try await Self.drain(NativeBufferedAudioDecoder.open(producer: producer))
                producer.stop()
            }
            // The first segment's format, the whole length of every segment.
            #expect(decoded.rate == parts[0].rate && decoded.channels == parts[0].channels)
            let total = parts.reduce(0) { $0 + $1.seconds }
            #expect(abs(Self.seconds(decoded) - total) < 0.05, "\(name): \(Self.seconds(decoded)) s of \(total) s")
            #expect(decoded.start == .zero)
            guard name != "changing.aac" else {
                // Both one-second tone periods are there and audible, at the same pitch.
                let first = PCMTestFixture.levelDecibels(Array(decoded.samples.prefix(40_000)))
                let second = PCMTestFixture.levelDecibels(Array(decoded.samples.suffix(40_000)))
                #expect(first > -40 && abs(first - second) < 6)
                func crossings(_ values: ArraySlice<Int16>) -> Int { zip(values, values.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count }
                let a = crossings(decoded.samples[5_000..<45_000]), b = crossings(decoded.samples[decoded.samples.count - 45_000..<decoded.samples.count - 5_000])
                #expect(abs(a - b) <= max(2, a / 50))
                continue
            }
            // The ad's tone fills [10.03, 15.07) s in both channels, at its own pitch; speech around it.
            let frequency = name.contains("48k") ? 660.0 : 440.0, adStart = parts[0].seconds, adEnd = adStart + parts[1].seconds
            for channel in 0..<2 {
                #expect(Self.tone(decoded, channel: channel, frequency: frequency, from: adStart + 0.1, to: adEnd - 0.1) > 0.9)
                #expect(Self.tone(decoded, channel: channel, frequency: frequency, from: adStart - 2, to: adStart - 0.1) < 0.2)
                #expect(Self.tone(decoded, channel: channel, frequency: frequency, from: adEnd + 0.1, to: adEnd + 2) < 0.2)
            }
            let window = Int(0.05 * Double(decoded.rate))
            let onset = stride(from: Int((adStart - 1) * Double(decoded.rate)), to: Int(adEnd * Double(decoded.rate)), by: window).first {
                Self.tone(decoded, channel: 0, frequency: frequency, from: Double($0) / Double(decoded.rate),
                    to: Double($0 + window) / Double(decoded.rate)) > 0.9
            }.map { Double($0) / Double(decoded.rate) }
            #expect(abs((onset ?? 0) - adStart) <= 0.1, "ad starts at \(String(describing: onset)) s")
        }
    }

    @Test(arguments: ["dai_adts_mono.aac", "dai_adts_48k.aac"], [5.0, 12.0, 18.0])
    func seeksBeforeInsideAndAfterTheChangePlayTheRest(name: String, target: Double) async throws {
        let data = try Self.fixture(name), parts = Self.segments(data)
        let decoded = try await Self.local(data, start: target)
        // Constant-bitrate seeking (as Media3) lands on the first frame at the mapped byte.
        let timeline = try await NativeAudioSourceTimeline.read(input: Chunked(data), format: .adts)
        let byte = try #require(timeline.adtsByteIndex).points(at: Int64(target * 1_000_000)).first.bytePosition
        var landed = 0.0, offset = 0
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        while offset < byte {
            landed += 1024 / Double(rates[Int(data[offset + 2] >> 2 & 15)])
            offset += Int(data[offset + 3] & 3) << 11 | Int(data[offset + 4]) << 3 | Int(data[offset + 5] >> 5)
        }
        let total = parts.reduce(0) { $0 + $1.seconds }
        #expect(abs(decoded.start.seconds - target) <= 0.05)
        #expect(abs(Self.seconds(decoded) - (total - landed)) < 0.1, "\(Self.seconds(decoded)) s after \(target) s, landed at \(landed) s")
        // Wherever it lands, the presentation keeps the stream's first format.
        #expect(decoded.rate == parts[0].rate && decoded.channels == parts[0].channels)
        let frequency = name.contains("48k") ? 660.0 : 440.0
        let adEnd = parts[0].seconds + parts[1].seconds - landed
        if target == 12 {
            // Inside the ad: it plays from the landing point in both channels, then the show resumes.
            for channel in 0..<2 {
                #expect(Self.tone(decoded, channel: channel, frequency: frequency, from: 0.05, to: adEnd - 0.1) > 0.9)
                #expect(Self.tone(decoded, channel: channel, frequency: frequency, from: adEnd + 0.1, to: adEnd + 2) < 0.2)
            }
        } else if target == 5 {
            #expect(Self.tone(decoded, channel: 1, frequency: frequency, from: adEnd - parts[1].seconds + 0.1, to: adEnd - 0.1) > 0.9)
        } else {
            #expect(Self.tone(decoded, channel: 0, frequency: frequency, from: 0, to: Self.seconds(decoded)) < 0.2)
        }
    }

    /// A seek within an already loaded stream reuses its encoded packets; it keeps the first format too.
    @Test(arguments: ["dai_adts_mono.aac", "dai_adts_48k.aac"])
    func retainedSeekIntoTheAdKeepsTheFirstFormat(name: String) async throws {
        let data = try Self.fixture(name), parts = Self.segments(data)
        let timeline = try await NativeAudioSourceTimeline.read(input: Chunked(data), format: .adts)
        let producer = NativeAudioPacketProducer(input: Chunked(data), timeline: timeline, format: .adts)
        defer { producer.stop() }
        let deadline = ContinuousClock.now + .seconds(10)
        while !producer.snapshot().ended, ContinuousClock.now < deadline { await Task.yield() }
        try #require(producer.snapshot().ended)
        try #require(producer.seek(to: 12_000_000))
        let decoded = try await Self.drain(NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false,
            start: CMTime(seconds: 12, preferredTimescale: 1000), admission: .wholeBuffer))
        #expect(decoded.rate == parts[0].rate && decoded.channels == parts[0].channels)
        let total = parts.reduce(0) { $0 + $1.seconds }, adEnd = parts[0].seconds + parts[1].seconds
        // Whole-buffer admission: the first output buffer at or after the target, then everything after it.
        #expect(decoded.start.seconds >= 12 && decoded.start.seconds < 12.1)
        #expect(abs(Self.seconds(decoded) - (total - decoded.start.seconds)) < 0.05,
            "starts at \(decoded.start.seconds) s, \(Self.seconds(decoded)) s of \(total - decoded.start.seconds) s")
        let frequency = name.contains("48k") ? 660.0 : 440.0
        for channel in 0..<2 {
            #expect(Self.tone(decoded, channel: channel, frequency: frequency, from: 0.05, to: adEnd - 12 - 0.1) > 0.9)
        }
    }

    /// Distinct left and right markers survive a mono ad: from the start, after a cold seek into the ad
    /// and after a remote seek (restore) into it, the show after the ad is still stereo.
    @Test(arguments: [0.0, 2.5])
    func showAfterAMonoAdKeepsItsOwnLeftAndRight(target: Double) async throws {
        let data = try Self.fixture("stereo-markers-mono-ad.aac"), parts = Self.segments(data)
        #expect(parts.map(\.channels) == [2, 1, 2])
        let local = try await Self.local(data, start: target)
        let root = URL.temporaryDirectory.appendingPathComponent("adts-markers-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await LoopbackHTTPServer.start { request in
            let start = request.headers["range"].flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0
            if start > 0 {
                return .init(status: 206, headers: ["Content-Type": "audio/aac", "ETag": "\"markers\"",
                    "Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"], body: Data(data.dropFirst(start)))
            }
            return .init(headers: ["Content-Type": "audio/aac", "ETag": "\"markers\"", "Accept-Ranges": "bytes"], body: data)
        }
        defer { server.stop() }
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let owner = PCMPlaybackFactory(cacheDirectory: root, makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let factory = try #require(try await owner.processedIfSupported(url: server.url, proxy: PodcastProxy(), credentials: nil, userAgent: "test"))
        let session = try await factory.make(positionMilliseconds: Int64(target * 1000), parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        try await session.prepare(); try session.play()
        let output = try #require(outputs.last)
        let deadline = ContinuousClock.now + .seconds(20)
        while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        try #require(session.state == .ended && session.failure == nil)
        var bytes = Data(), format = AudioStreamBasicDescription()
        for buffer in output.buffers {
            format = try #require(buffer.formatDescription.audioStreamBasicDescription)
            bytes.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) }))
        }
        #expect(Int(format.mSampleRate) == parts[0].rate && format.mChannelsPerFrame == 2)
        let remote = Decoded(samples: PCMTestFixture.samples(bytes), rate: Int(format.mSampleRate), channels: 2)
        for decoded in [local, remote] {
            #expect(decoded.rate == parts[0].rate && decoded.channels == 2)
            let showAgain = parts[0].seconds + parts[1].seconds - target + 0.1
            #expect(Self.tone(decoded, channel: 0, frequency: 440, from: showAgain, to: showAgain + 1.5) > 0.9)
            #expect(Self.tone(decoded, channel: 1, frequency: 660, from: showAgain, to: showAgain + 1.5) > 0.9)
            #expect(Self.tone(decoded, channel: 0, frequency: 660, from: showAgain, to: showAgain + 1.5) < 0.05)
            #expect(Self.tone(decoded, channel: 1, frequency: 440, from: showAgain, to: showAgain + 1.5) < 0.05)
        }
    }

    /// An HE-AAC show (its decoded rate known only from the codec's profile discovery) keeps that rate
    /// after a cold seek into a following LC segment.
    @Test func coldSeekAfterAnHEAACStartKeepsItsDecodedFormat() async throws {
        let profiles = { (name: String) in try Data(contentsOf: FFmpegBufferedSeekReferenceTests.resource(name, directory: "AACProfiles")) }
        let data = try profiles("he-stereo.aac") + profiles("lc-mono.aac"), parts = Self.segments(data)
        #expect(parts.count == 2)
        let whole = try await Self.local(data)
        #expect(whole.rate == 2 * parts[0].rate && whole.channels == 2)
        for target in [1.0, parts[0].seconds + 1] {
            let sought = try await Self.local(data, start: target)
            #expect(sought.rate == whole.rate && sought.channels == whole.channels, "after a seek to \(target) s")
            #expect(abs(Self.seconds(sought) - (Self.seconds(whole) - target)) < 0.15)
        }
    }

    @Test(arguments: [0, 1, 2])
    func streamedLateChangePlaysToTheTrueEndWithoutAPrematureFinish(configuration: Int) async throws {
        // 0: ranges and a length; 1: no ranges, with a length; 2: no ranges, no length.
        let ranged = configuration == 0, unknownLength = configuration == 2
        let media = try Self.lateChange(), parts = Self.segments(media)
        let root = URL.temporaryDirectory.appendingPathComponent("adts-change-remote-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await LoopbackHTTPServer.start { request in
            let start = ranged ? request.headers["range"].flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0 : 0
            if start > 0 {
                return .init(status: 206, headers: ["Content-Type": "audio/aac", "ETag": "\"late\"",
                    "Content-Range": "bytes \(start)-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(start)))
            }
            return .init(headers: ["Content-Type": "audio/aac", "ETag": "\"late\""], body: media,
                includeAutomaticContentLength: !unknownLength)
        }
        defer { server.stop() }
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let owner = PCMPlaybackFactory(cacheDirectory: root, makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let factory = try #require(try await owner.processedIfSupported(url: server.url, proxy: PodcastProxy(), credentials: nil, userAgent: "test"))
        #expect(factory.mediaSource == nil) // the native ADTS route, not the generalized one
        let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        try await session.prepare(); try session.play()
        let output = try #require(outputs.last)
        let deadline = ContinuousClock.now + .seconds(30)
        while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        try #require(session.state == .ended && session.failure == nil)
        var bytes = Data()
        for buffer in output.buffers { bytes.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })) }
        let decoded = Decoded(samples: PCMTestFixture.samples(bytes), rate: 44_100, channels: 2)
        let total = parts.reduce(0) { $0 + $1.seconds }, adStart = parts[0].seconds
        #expect(abs(Self.seconds(decoded) - total) < 0.05, "\(Self.seconds(decoded)) s of \(total) s")
        #expect(output.end.seconds > total - 0.05)
        for channel in 0..<2 {
            #expect(Self.tone(decoded, channel: channel, frequency: 440, from: adStart + 0.1, to: adStart + parts[1].seconds - 0.1) > 0.9)
        }
    }

    @Test func ordinaryADTSIsUnchangedByFragmentationAndKeepsItsSeekMap() async throws {
        let data = try Data(contentsOf: FFmpegBufferedSeekReferenceTests.resource("ticks.aac", directory: "HeardRate"))
        let whole = try await Self.local(data)
        let timeline = try await NativeAudioSourceTimeline.read(input: Chunked(data), format: .adts)
        let producer = NativeAudioPacketProducer(input: Chunked(data, largest: 333, randomAccess: false), timeline: timeline, format: .adts)
        let fragmented = try await Self.drain(NativeBufferedAudioDecoder.open(producer: producer))
        producer.stop()
        #expect(fragmented.samples == whole.samples && fragmented.rate == whole.rate && fragmented.channels == whole.channels)
        #expect(timeline.seekable && timeline.durationMicroseconds == 30_119_341)
        let sought = try await Self.local(data, start: 20)
        #expect(abs(sought.start.seconds - 20) <= 0.05 && abs(Self.seconds(sought) - (Self.seconds(whole) - 20)) < 0.25)
    }
}

import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct NativeAudioIndexedPacketTests {
    static let names = ["tone.wav", "tone.aac", "tone.m4a", "tone-tail.m4a", "tone.flac"]
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: name.hasPrefix("long") ? "Fixtures/LongNativeFormats" : "Fixtures/StreamingFormats"))
#else
        try #require(Bundle(for: IndexedPacketFixtures.self).url(forResource: name, withExtension: nil))
#endif
    }
    private func kind(_ name: String) -> NativeAudioSourceTimeline.Format {
        name.hasSuffix("wav") ? .wav : name.hasSuffix("aac") ? .adts : name.hasSuffix("flac") ? .flac : .mp4
    }
    private func baseline(_ name: String, after firstFrame: Int64 = 0) throws -> [Int16] {
        let file = try AVAudioFile(forReading: fixture(name), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var samples: [Int16] = []
        while file.framePosition < file.length {
            let origin = file.framePosition
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            let skip = min(Int64(buffer.frameLength), max(0, firstFrame - origin))
            let channels = Int(file.processingFormat.channelCount)
            samples += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0].advanced(by: Int(skip) * channels),
                count: (Int(buffer.frameLength) - Int(skip)) * channels))
        }
        return samples
    }
    /// Collects the decoded audio and checks it is contiguous from the decoder's start (no gaps).
    private func collect(_ decoder: any PCMDecoding) async throws -> [Int16] {
        var samples: [Int16] = []
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: decoder.startFrame + Int64(samples.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            samples += packet.samples
        }
        return samples
    }
    /// User-visible audio outcome: the decode has the reference's length (within 50 ms) and is
    /// audible. Sample identity with Apple's decoder (and AAC decoder history) is not required.
    private func expectAudio(_ actual: [Int16], like expected: [Int16], channels: Int = 1, rate: Int = 48000, _ label: String = "",
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let frames = actual.count / channels, expectedFrames = expected.count / channels
        #expect(abs(frames - expectedFrames) <= rate / 20, "\(label): \(frames) frames, expected \(expectedFrames)", sourceLocation: sourceLocation)
        let peak = actual.lazy.map { abs(Int($0)) }.max() ?? 0, reference = expected.lazy.map { abs(Int($0)) }.max() ?? 0
        #expect(peak * 2 >= reference, "\(label): silent or much quieter than the reference", sourceLocation: sourceLocation)
    }
    /// A seek lands within 0.25 s (12 000 frames at 48 kHz) of the requested frame.
    private func landed(_ frame: Int64, near target: Int64) -> Bool { abs(frame - target) <= 12_000 }
    private func wait(_ predicate: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            await Task.yield()
        }
        try #require(predicate())
    }

    @Test func nativeFLACParserAcceptsPositionedFramesWithOriginalStreamInfo() async throws {
        let data = try Data(contentsOf: fixture("long.flac"))
        // Independent ffprobe packet map and original extractor output agree:
        // frame17280000 begins at4732580. Stream info is kept byte-identical;
        // only its last-metadata-block flag is set, as in Media3's decoder config.
        var prefix = Data(data.prefix(42)); prefix[4] = 0x80
        let positioned = prefix + data.dropFirst(4732580)
        let parser = try NativeAudioStreamParser(); defer { parser.close() }
        var batches: [NativeAudioStreamParser.Batch] = []
        for start in stride(from: 0, to: positioned.count, by: 4096) {
            batches += try parser.append(positioned.subdata(in: start..<min(start + 4096, positioned.count)))
        }
        batches += try parser.finish()
        let configuration = try #require(parser.configuration)
        let decoder = try NativeAudioStreamConverter(configuration: configuration, maximumFrames: 4096, firstFrame: 17280000)
        var current = 0, actual = [Int16](), ended = false
        while !ended {
            switch try decoder.next() {
            case .needsInput:
                if current < batches.count { try decoder.accept(batches[current]); current += 1 }
                else { decoder.finish() }
            case .audio(let packet):
                #expect(packet.presentationTime == CMTime(value: 17280000 + Int64(actual.count), timescale: 48000))
                actual += packet.samples
            case .ended: ended = true
            }
        }
        expectAudio(actual, like: try baseline("long.flac", after: 17280000), "positioned FLAC")
    }

    @Test(arguments: [17, 4096])
    func flacByteSeekFindsLateFrameWithBoundedReads(fragment: Int) async throws {
        let data = try Data(contentsOf: fixture("long.flac"))
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(data), format: .flac)
        let index = try #require(timeline.flacByteIndex), input = Input(data, fragment: fragment)
        let point = try index.position(at: 360000354, input: input)
        // Lands on a frame at or just before 6:00 (Android's is frame 17 280 000 at byte 4 732 580).
        #expect(landed(point.sample, near: 17280000) && point.sample <= 17280017)
        // Seeking six minutes into a 4.8 MB stream reads only a small part of it.
        #expect(input.reads.reduce(0) { $0 + $1.count } < 350000)
        let producerInput = Input(data, fragment: fragment)
        let producer = NativeAudioPacketProducer(input: producerInput, timeline: timeline, format: .flac,
            flacStart: CMTime(value: 360, timescale: 1))
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, start: CMTime(value: 360, timescale: 1), admission: .wholeBuffer)
        #expect(landed(decoder.startFrame, near: 17280000))
        let actual = try await collect(decoder)
        expectAudio(actual, like: try baseline("long.flac", after: decoder.startFrame), channels: decoder.channels, "FLAC 6:00")
        #expect(producerInput.reads.reduce(0) { $0 + $1.count } < 500000)
        await decoder.cancel()
    }

    @Test(arguments: 0..<10)
    func flacByteSeekResolvesIndependentBoundaryPackets(scenario: Int) async throws {
        // ffprobe packet map of the unchanged fixture, including its short final
        // frame. Past-duration low-level lookups clamp to the final sample.
        let cases: [(Int64, Int64, Int64)] = [
            (0, 8256, 0), (1, 8256, 0), (95000, 8256, 0),
            (96000, 9516, 4608), (97000, 9516, 4608),
            (1000000, 20849, 46080), (100000000, 1319153, 4796928),
            (367968000, 4837212, 17662464), (368000000, 4837212, 17662464),
            (400000000, 4837212, 17662464)
        ]
        let data = try Data(contentsOf: fixture("long.flac"))
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(data), format: .flac)
        let index = try #require(timeline.flacByteIndex), input = Input(data)
        let (time, _, sample) = cases[scenario]
        let point = try index.position(at: time, input: input)
        #expect(landed(point.sample, near: sample), "\(time) µs → sample \(point.sample), Android \(sample)")
        #expect(input.reads.reduce(0) { $0 + $1.count } < 500000)
    }

    @Test(arguments: [false, true])
    func flacSeekTableWorksWithoutDeclaredExtent(known: Bool) async throws {
        let original = try Data(contentsOf: fixture("long.flac"))
        // Preserve every original audio frame. Two real table entries plus the
        // standard placeholder refer to ffprobe's original packet positions.
        var cursor = 4
        while true {
            let flag = original[cursor], count = Int(original[cursor + 1]) << 16 | Int(original[cursor + 2]) << 8 | Int(original[cursor + 3])
            cursor += count + 4
            if flag & 128 != 0 { break }
        }
        func big(_ value: UInt64) -> Data { Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        let table = big(0) + big(0) + Data([0x12, 0])
            + big(17280000) + big(UInt64(4732580 - cursor)) + Data([0x12, 0])
            + big(UInt64.max) + big(0) + Data([0, 0])
        var prefix = Data(original.prefix(42)); prefix[4] = 0
        let data = prefix + Data([0x83, 0, 0, 54]) + table + original.dropFirst(cursor)
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(data, known: known), format: .flac)
        #expect(timeline.seekable && timeline.durationMicroseconds.map { abs($0 - 368000000) <= 50_000 } == true)
        let index = try #require(timeline.flacByteIndex), input = Input(data, fragment: 17, known: known)
        let point = try index.position(at: 360000354, input: input)
        #expect(landed(point.sample, near: 17280000))
        // The seek table is used directly: no search through the file.
        #expect(input.reads.reduce(0) { $0 + $1.count } < 100)
        let producer = NativeAudioPacketProducer(input: Input(data, known: known), timeline: timeline, format: .flac,
            flacStart: CMTime(value: 360, timescale: 1))
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, start: CMTime(value: 360, timescale: 1))
        #expect(landed(decoder.startFrame, near: 17280000))
        let actual = try await collect(decoder)
        expectAudio(actual, like: try baseline("long.flac", after: decoder.startFrame), channels: decoder.channels, "FLAC seek table")
        await decoder.cancel()
    }

    @Test(arguments: [false, true])
    func cancelledFLACSeekRetiresBlockedHeaderSearch(prefix: Bool) async throws {
        let data = try Data(contentsOf: fixture("long.flac"))
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(data), format: .flac)
        let input = Input(data, blockedAt: prefix ? nil : 4495607, blockedBelow: prefix ? 262144 : nil)
        let target = CMTime(value: 360000354, timescale: 1_000_000)
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: .flac, flacStart: target)
        defer { producer.stop() }
        let opening = Task { try await NativeBufferedAudioDecoder.open(producer: producer, start: target) }
        defer { opening.cancel() }
        try await wait { input.waiting }
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        // Bounded: if cancellation failed to retire the blocked read, fail instead of hanging the run.
        try await wait { producer.snapshot().exited }
        #expect(input.cancelled && !input.waiting && producer.snapshot().exited)
    }

    @Test(arguments: [false, true], [false, true])
    func flacSourceSeekPreservesCapturedRouteAndOfflineAudio(proxyEnabled: Bool, fractional: Bool) async throws {
        let data = try Data(contentsOf: fixture("long.flac"))
        let credentials = FeedCredentials(username: "flac", password: "captured")
        let offered = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                #expect(request.headers["if-range"] == "\"flac-source\"")
                #expect(offset >= 4490000 && offset < data.count)
                offered.withLock { $0 += data.count - offset }
                return .init(status: 206, headers: ["ETag": "\"flac-source\"",
                    "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], body: Data(data.dropFirst(offset)))
            }
            offered.withLock { $0 += 262144 }
            return .init(headers: ["Content-Type": "audio/flac", "Content-Length": String(data.count), "ETag": "\"flac-source\""],
                body: Data(data.prefix(262144)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("flac-source-http-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SharedStreamingCache(directory: root)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://flac-source.invalid/episode")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let target = CMTime(value: fractional ? 360000354 : 360000000, timescale: 1_000_000)
        let decoder = try await source.makeDecoder(start: target)
        #expect(decoder.sourceDurationMilliseconds.map { abs($0 - 368000) <= 50 } == true)
        #expect(abs(decoder.startTime.seconds - target.seconds) <= 0.25)
        let first = CMTimeConvertScale(decoder.startTime, timescale: 48000, method: .roundTowardZero).value
        var samples = [Int16]()
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: first + Int64(samples.count), timescale: 48000))
            samples += packet.samples
        }
        expectAudio(samples, like: try baseline("long.flac", after: first), "FLAC over HTTP")
        // Seeking six minutes into the stream does not download the 4.8 MB episode.
        #expect(offered.withLock { $0 } < 1000000)
        #expect(cache.snapshot(for: url).committedBytes < 1000000)
        let requests = server.requests.count
        await decoder.cancel()
        server.stop()
        // The same position replays from the cache without the network.
        let replay = try await source.makeDecoder(start: target)
        var repeated = [Int16]()
        while let packet = try await replay.next() { repeated += packet.samples }
        expectAudio(repeated, like: samples, "offline replay")
        #expect(server.requests.count == requests)
        await replay.cancel()
    }

    private static let adtsEndCases: [(name: String, target: Int64, offset: Int64, packets: Int)] = [
        ("tone.aac", 7990000, 66572, 3), ("tone.aac", 8000000, 66750, 2),
        ("tone.aac", 8020000, 66750, 2), ("tone.aac", 8041227, 66917, 1),
        ("tone.aac", 20000000, 66917, 1), ("long.aac", 368000000, 3070500, 67),
        ("long.aac", 369400000, 3082070, 3), ("long.aac", 369448128, 3082451, 0),
        ("long.aac", 400000000, 3082451, 0)
    ]
    private func id3Prefix() -> Data { Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 64]) + Data(repeating: 0, count: 64) }

    @Test(arguments: 0..<9, [false, true])
    func adtsEndByteSeekPlaysOnlyTheRemainingTail(index: Int, tagged: Bool) async throws {
        let scenario = Self.adtsEndCases[index], prefix = tagged ? id3Prefix() : Data()
        let data = prefix + (try Data(contentsOf: fixture(scenario.name)))
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(data), format: .adts)
        let byteIndex = try #require(timeline.adtsByteIndex)
        let target = CMTime(value: scenario.target, timescale: 1_000_000)
        let point = byteIndex.points(at: scenario.target).first
        #expect(point.bytePosition >= Int64(prefix.count), "an ID3 tag is never treated as audio")
        var expected = Data(), expectedPackets = 0, offset = prefix.count
        while offset + 7 <= data.count {
            let size = Int(data[offset + 3] & 3) << 11 | Int(data[offset + 4]) << 3 | Int(data[offset + 5] >> 5)
            try #require(size >= 7 && offset + size <= data.count)
            if offset >= point.bytePosition {
                expected.append(data[(offset + 7)..<(offset + size)]); expectedPackets += 1
            }
            offset += size
        }
        // Android plays the same remaining tail (each packet is 21 ms; within 50 ms).
        #expect(abs(expectedPackets - scenario.packets) <= 2, "\(expectedPackets) packets remain, Android \(scenario.packets)")
        let input = Input(data, fragment: tagged ? 17 : 4096)
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: .adts,
            adtsStart: .init(bytePosition: point.bytePosition, time: target))
        defer { producer.stop() }
        let lease = producer.makeReadLease(); defer { lease.cancel() }
        let format = try lease.configuration()
        #expect(format.basic.mSampleRate == 48000 && format.basic.mChannelsPerFrame == 1)
        var actual = Data(), count = 0
        while let packet = try lease.next() { actual += packet.bytes; count += Int(packet.packetCount) }
        #expect(actual == expected && count == expectedPackets)
        // Seeking to the end of a long stream reads only its tail.
        #expect(input.reads.reduce(0) { $0 + $1.count } < 20000)
        lease.cancel(); producer.stop(); await producer.waitForExit()
        #expect(producer.snapshot().exited)
    }

    @Test(arguments: [false, true]) func cancelledADTSSeekRetiresBlockedLateRead(prefixDiscovery: Bool) async throws {
        let data = try Data(contentsOf: fixture("long.aac"))
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(data), format: .adts)
        let input = Input(data, blockedAt: prefixDiscovery ? nil : 3003750, blockedBelow: prefixDiscovery ? 4096 : nil)
        let target = CMTime(value: prefixDiscovery ? 369448128 : 360000354, timescale: 1_000_000)
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: .adts,
            adtsStart: .init(bytePosition: prefixDiscovery ? 3082451 : 3003750, time: target))
        defer { producer.stop() }
        let opening = Task { try await NativeBufferedAudioDecoder.open(producer: producer, start: target, admission: .wholeBuffer) }
        defer { opening.cancel() }
        try await wait { input.waiting }
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        // Bounded: if cancellation failed to retire the blocked read, fail instead of hanging the run.
        try await wait { producer.snapshot().exited }
        #expect(input.cancelled && !input.waiting && producer.snapshot().exited)
    }

    @Test(arguments: 0..<8)
    func adtsEndSourcePreservesEmptyOrSingleFrameAndOfflineClock(configuration: Int) async throws {
        let long = configuration & 1 != 0, tagged = configuration & 2 != 0, proxyEnabled = configuration & 4 != 0
        let prefix = tagged ? id3Prefix() : Data()
        let data = prefix + (try Data(contentsOf: fixture(long ? "long.aac" : "tone.aac")))
        let target = CMTime(value: long ? 369448128 : 8041227, timescale: 1_000_000)
        let credentials = FeedCredentials(username: "adts-end", password: "fixture")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                #expect(request.headers["if-range"] == "\"adts-end\"")
                return .init(status: 206, headers: ["ETag": "\"adts-end\"",
                    "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], body: Data(data.dropFirst(offset)))
            }
            return .init(headers: ["Content-Type": "audio/aac", "Content-Length": String(data.count), "ETag": "\"adts-end\""],
                body: Data(data.prefix(262144)), keepConnectionOpen: data.count > 262144)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("adts-end-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SharedStreamingCache(directory: root)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://adts-end.invalid/episode")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let decoder = try await source.makeDecoder(start: target)
        #expect(abs(decoder.startTime.seconds - target.seconds) <= 0.25 && decoder.sampleRate == 48000 && decoder.channels == 1)
        #expect(decoder.sourceDurationMilliseconds.map { abs($0 - target.value / 1000) <= 50 } == true && decoder.sourceSeekable == true)
        var samples = [Int16]()
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == decoder.startTime + CMTime(value: Int64(samples.count), timescale: 48000))
            samples += packet.samples
        }
        // Seeking to the very end plays at most a final moment (≤ 50 ms), then ends.
        #expect(samples.count <= 2400)
        // Seeking to the end of a long stream does not download the episode body.
        #expect(cache.snapshot(for: url).committedBytes < 400000)
        let requests = server.requests.count
        await decoder.cancel()
        server.stop()
        let replay = try await source.makeDecoder(start: target)
        #expect(abs(replay.startTime.seconds - target.seconds) <= 0.25)
        if long {
            let stream = try LocalPCMPlaybackStream(decoder: replay, skipSilence: false, speed: 1.5)
            #expect(try await stream.nextPacket() == nil)
            let decoded = await stream.decodedFrames, delivered = await stream.deliveredFrames
            #expect(decoded == 0 && delivered == 0)
            #expect(abs(await stream.segment.mediaStartTime.seconds - target.seconds) <= 0.25)
            await stream.cancel()
        } else {
            var repeated = [Int16]()
            while let packet = try await replay.next() { repeated += packet.samples }
            #expect(abs(repeated.count - samples.count) <= 2400)
            await replay.cancel()
        }
        #expect(server.requests.count == requests)
    }

    @Test(arguments: [1, 17, 4096])
    func adtsSourceByteSeekPreservesPacketsAndBoundedAcquisition(fragment: Int) async throws {
        let data = try Data(contentsOf: fixture("long.aac"))
        let metadata = Input(data)
        let timeline = try await NativeAudioSourceTimeline.read(input: metadata, format: .adts)
        let index = try #require(timeline.adtsByteIndex)
        let target = CMTime(value: 360000354, timescale: 1_000_000)
        let point = index.points(at: target.value).first
        // Seek point within 0.25 s of 6:00 (Media3 chooses byte 3 003 750 at 359.994606 s).
        #expect(abs(point.timeMicroseconds - target.value) <= 250_000)
        #expect(timeline.durationMicroseconds.map { abs($0 - 369448128) <= 50_000 } == true)
        #expect(metadata.reads.reduce(0) { $0 + $1.count } < 200000)
        // Walk complete fixture framing only in the oracle. Production must
        // obtain the same suffix from the late byte position, without this walk.
        var offset = 0, payload = Data(), packets = 0
        while offset + 7 <= data.count {
            let size = Int(data[offset + 3] & 3) << 11 | Int(data[offset + 4]) << 3 | Int(data[offset + 5] >> 5)
            try #require(size >= 7 && offset + size <= data.count)
            if offset >= point.bytePosition {
                payload.append(data[(offset + 7)..<(offset + size)]); packets += 1
            }
            offset += size
        }
        let input = Input(data, fragment: fragment)
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: .adts,
            adtsStart: .init(bytePosition: point.bytePosition, time: target))
        defer { producer.stop() }
        let lease = producer.makeReadLease()
        defer { lease.cancel() }
        let configuration = try lease.configuration()
        #expect(configuration.basic.mSampleRate == 48000 && configuration.primingFrames == 0)
        var actual = Data(), actualPackets = 0, firstFrame: Int64?
        while let batch = try lease.next() {
            if firstFrame == nil { firstFrame = batch.firstFrame }
            #expect(batch.firstFrame == firstFrame! + Int64(actualPackets) * 1024)
            actual.append(batch.bytes); actualPackets += Int(batch.packetCount)
        }
        let origin = try #require(firstFrame)
        #expect(landed(origin, near: 17280017))
        #expect(actual == payload && actualPackets == packets)
        // Reading covers only a bounded start probe (the stream's first format: at most 32 KiB from its
        // first frame), then starts at the seek point and covers only the ~9 s tail.
        let first = index.points(at: 0).first.bytePosition
        let probe = input.reads.prefix { $0.offset < point.bytePosition }
        #expect(probe.allSatisfy { $0.offset >= first && $0.offset + $0.count <= first + 32768 })
        #expect(input.reads.dropFirst(probe.count).first?.offset == point.bytePosition)
        #expect(input.reads.reduce(0) { $0 + $1.count } < 100000)
        lease.cancel(); producer.stop(); await producer.waitForExit()
        #expect(producer.snapshot().exited)
    }

    @Test(arguments: [false, true])
    func adtsSourceSeekUsesCapturedHTTPAndRequestedClock(proxyEnabled: Bool) async throws {
        let data = try Data(contentsOf: fixture("long.aac"))
        let credentials = FeedCredentials(username: "adts", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                #expect(request.headers["if-range"] == "\"adts-source\"")
                return .init(status: 206, headers: ["ETag": "\"adts-source\"",
                    "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], body: Data(data.dropFirst(offset)))
            }
            return .init(headers: ["Content-Type": "audio/aac", "Content-Length": String(data.count), "ETag": "\"adts-source\""],
                body: Data(data.prefix(262144)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("adts-source-http-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SharedStreamingCache(directory: root)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://adts-source.invalid/episode")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let target = CMTime(value: 360000354, timescale: 1_000_000)
        let decoder = try await source.makeDecoder(start: target)
        #expect(abs(decoder.startTime.seconds - target.seconds) <= 0.25)
        #expect(decoder.sourceDurationMilliseconds.map { abs($0 - 369448) <= 50 } == true)
        var samples = [Int16]()
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == decoder.startTime + CMTime(value: Int64(samples.count), timescale: 48000))
            samples += packet.samples
        }
        #expect(cache.snapshot(for: url).committedBytes < 400000)
        let requests = server.requests.count
        await decoder.cancel()
        // Apple's decode of the remaining complete frames is the length/audibility reference.
        let suffix = root.appendingPathComponent("source-suffix.aac")
        try Data(data.dropFirst(3003804)).write(to: suffix)
        let file = try AVAudioFile(forReading: suffix, commonFormat: .pcmFormatInt16, interleaved: true)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var expected = [Int16]()
        while file.framePosition < file.length {
            try file.read(into: output, frameCount: UInt32(min(4096, file.length - file.framePosition)))
            try #require(output.frameLength > 0)
            expected += UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength))
        }
        expectAudio(samples, like: expected, "ADTS 6:00 over HTTP")
        server.stop()
        let replay = try await source.makeDecoder(start: target)
        #expect(abs(replay.startTime.seconds - target.seconds) <= 0.25)
        var repeated = [Int16]()
        while let packet = try await replay.next() { repeated += packet.samples }
        expectAudio(repeated, like: samples, "offline replay")
        #expect(server.requests.count == requests)
        await replay.cancel()
    }

    @Test(arguments: ["long.aac", "long.m4a", "long-tail.m4a", "long.flac"])
    func longIndexedAcquisitionAndCompleteSixMinuteTail(name: String) async throws {
        let data = try Data(contentsOf: fixture(name)), target: Int64 = 17_280_017
        let time = CMTime(value: target, timescale: 48000), traced = Input(data)
        let reader = try NativeAudioPacketFileReader(input: traced, format: kind(name), start: time)
        #expect(reader.firstFrame > 0 && reader.firstFrame <= target + 1024)
        let input = Input(data)
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(data), format: kind(name))
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: kind(name), indexedStart: time)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false, start: time)
        #expect(landed(decoder.startFrame, near: target))
        let actual = try await collect(decoder)
        expectAudio(actual, like: try baseline(name, after: decoder.startFrame), channels: decoder.channels, "\(name) 6:00")
        #expect(try await decoder.next() == nil)
        await decoder.cancel()
        producer.stop(); await producer.waitForExit()
        #expect(producer.snapshot().exited)
    }

    @Test(arguments: ["long.m4a", "long-tail.m4a"], [false, true])
    func longMP4ColdSeekUsesTargetedHTTPAndRetainedOfflineTail(name: String, proxyEnabled: Bool) async throws {
        let data = try Data(contentsOf: fixture(name)), credentials = FeedCredentials(username: "long-index", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                #expect(request.headers["if-range"] == "\"long-index\"")
                // The native container index is in the prefix/tail. Seeking to
                // six minutes must not acquire the intervening episode body.
                #expect(offset < 131072 || offset >= data.count - 524288)
                guard offset < data.count else { return .init(status: 416, headers: ["Content-Range": "bytes */\(data.count)"]) }
                return .init(status: 206, headers: ["Content-Type": "audio/mp4", "ETag": "\"long-index\"",
                    "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], body: Data(data.dropFirst(offset)))
            }
            return .init(headers: ["Content-Type": "audio/mp4", "Content-Length": String(data.count), "ETag": "\"long-index\""],
                body: Data(data.prefix(131072)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("long-mp4-http-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SharedStreamingCache(directory: root)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://long-index.invalid/episode")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let target: Int64 = 17_280_017
        let decoder = try await source.makeDecoder(start: CMTime(value: target, timescale: 48000), admission: .exactFrame)
        #expect(landed(decoder.startFrame, near: target))
        let actual = try await collect(decoder), expected = try baseline(name, after: decoder.startFrame)
        expectAudio(actual, like: expected, channels: decoder.channels, "\(name) 6:00 over HTTP")
        #expect(decoder.sourceDurationMilliseconds.map { abs($0 - 368000) <= 50 } == true && decoder.sourceSeekable == true)
        #expect(cache.snapshot(for: url).committedBytes < 1_048_576)
        await decoder.cancel()
        let requests = server.requests.count
        server.stop()
        // A later position inside the already-fetched tail plays offline.
        let retainedTarget: Int64 = 17_304_000
        let retained = try await source.makeDecoder(start: CMTime(value: retainedTarget, timescale: 48000), admission: .exactFrame)
        #expect(landed(retained.startFrame, near: retainedTarget))
        let tail = try await collect(retained)
        expectAudio(tail, like: try baseline(name, after: retained.startFrame), channels: retained.channels, "\(name) retained tail")
        await retained.cancel()
        #expect(server.requests.count == requests)
    }

    @Test(arguments: names, [Int64(0), 1, 192017, 383843, 480000])
    func indexedPacketsPlayFullTailsFromSeekTarget(name: String, target: Int64) async throws {
        let bytes = try Data(contentsOf: fixture(name)), input = Input(bytes)
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(bytes), format: kind(name))
        let time = CMTime(value: target, timescale: 48000)
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: kind(name), indexedStart: time)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false, start: time)
        let actual = try await collect(decoder), expected = Array(try baseline(name).dropFirst(Int(target) * decoder.channels))
        if !expected.isEmpty { #expect(landed(decoder.startFrame, near: target)) }
        expectAudio(actual, like: expected, channels: decoder.channels, "\(name) @\(target)")
        #expect(try await decoder.next() == nil)
        #expect(producer.bufferState.snapshot.durationMicroseconds == timeline.durationMicroseconds)
        await decoder.cancel()
        producer.stop(); await producer.waitForExit()
        #expect(producer.snapshot().exited)
    }

    @Test(arguments: [false, true])
    func coldSixMinuteSeekSkipsHeldPrefixAndRetainsRealIndexedLoading(proxyEnabled: Bool) async throws {
        let original = try Data(contentsOf: fixture("tone.wav")), expected = try baseline("tone.wav")
        var repeated = Data(original.prefix(44))
        for _ in 0..<46 { repeated.append(original.dropFirst(44)) }
        func little(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        repeated.replaceSubrange(4..<8, with: little(repeated.count - 8))
        repeated.replaceSubrange(40..<44, with: little(repeated.count - 44))
        let media = repeated, credentials = FeedCredentials(username: "indexed", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                #expect(request.headers["if-range"] == "\"indexed\"")
                guard offset < media.count else { return .init(status: 416, headers: ["Content-Range": "bytes */\(media.count)"], body: Data()) }
                return .init(status: 206, headers: ["ETag": "\"indexed\"", "Content-Range": "bytes \(offset)-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(offset)))
            }
            return .init(headers: ["Content-Type": "audio/wav", "Content-Length": String(media.count), "ETag": "\"indexed\""],
                body: Data(media.prefix(131072)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("indexed-native-long-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SharedStreamingCache(directory: root)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://indexed-native.invalid/episode")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let decoder = try await source.makeDecoder(start: CMTime(value: 17280017, timescale: 48000), admission: .exactFrame)
        #expect(decoder.sourceDurationMilliseconds.map { abs($0 - 368000) <= 50 } == true)
        #expect(landed(decoder.startFrame, near: 17280017))
        // 6:00 is 0 s into the 46th copy of the 8 s tone.
        expectAudio(try await collect(decoder), like: Array(expected.dropFirst(Int(max(0, decoder.startFrame - 17280000)))), "WAV 6:00")
        #expect(cache.snapshot(for: url).committedBytes < 2 << 20)
        // The seek fetches from about 6:00 (byte 34 560 044) without downloading the 34 MB in between.
        let seekByte = 34560044, slack = 24000 // 0.25 s of 48 kHz mono 16-bit
        let offsets = server.requests.compactMap { $0.headers["range"].flatMap { Int($0.dropFirst(6).dropLast()) } }
        #expect(offsets.contains { abs($0 - seekByte) <= slack })
        #expect(offsets.allSatisfy { $0 < 131072 || $0 >= seekByte - slack })
        await decoder.cancel()
        let requests = server.requests.count
        server.stop()
        let replay = try await source.makeDecoder(start: CMTime(value: 3605, timescale: 10), admission: .exactFrame)
        #expect(landed(replay.startFrame, near: 17304000))
        expectAudio(try await collect(replay), like: Array(expected.dropFirst(Int(max(0, replay.startFrame - 17280000)))), "WAV offline 6:00.5")
        #expect(server.requests.count == requests)
        await replay.cancel()
    }

    @Test func cancellationInterruptsNativeIndexedCallbackAndRetiresProducer() async throws {
        let input = Input(try Data(contentsOf: fixture("tone.wav")), blockedAt: 131072)
        let producer = NativeAudioPacketProducer(input: input, timeline: .init(durationMicroseconds: 8000000, seekable: true),
            format: .wav, indexedStart: CMTime(value: 4, timescale: 1))
        defer { producer.stop() }
        let opening = Task { try await NativeBufferedAudioDecoder.open(producer: producer, start: CMTime(value: 4, timescale: 1)) }
        defer { opening.cancel() }
        try await wait { input.waiting }
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        // Bounded: if cancellation failed to retire the blocked read, fail instead of hanging the run.
        try await wait { producer.snapshot().exited }
        #expect(input.cancelled && !input.waiting && producer.snapshot().exited)
    }

    private final class Input: MediaByteInput, @unchecked Sendable {
        let bytes: Data, blockedAt: Int64?, blockedBelow: Int64?
        let fragment: Int, known: Bool
        private let condition = NSCondition()
        private var stopped = false, isWaiting = false, largestRead = 0
        struct Read: Sendable { let offset: Int64, count: Int64 }
        private var recordedReads: [Read] = []
        var reads: [Read] { condition.withLock { recordedReads } }
        init(_ bytes: Data, blockedAt: Int64? = nil, fragment: Int = 65536, blockedBelow: Int64? = nil, known: Bool = true) { self.known = known; self.bytes = bytes; self.blockedAt = blockedAt; self.fragment = fragment; self.blockedBelow = blockedBelow }
        var length: Int64? { known ? Int64(bytes.count) : nil }
        var supportsRandomAccess: Bool { true }
        var cancelled: Bool { condition.withLock { stopped } }
        var waiting: Bool { condition.withLock { isWaiting } }
        var maximumRead: Int { condition.withLock { largestRead } }
        func prepareForSeek() {}
        func checkFailure() throws { if cancelled { throw CancellationError() } }
        func cancel() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            condition.lock(); defer { condition.unlock() }
            largestRead = max(largestRead, maximumCount)
            while !stopped && ((blockedAt.map { offset >= $0 } ?? false) || (blockedBelow.map { offset < $0 } ?? false)) {
                isWaiting = true; condition.wait(); isWaiting = false
            }
            if stopped { throw CancellationError() }
            guard offset < bytes.count else { return Data() }
            let end = min(bytes.count, Int(offset) + min(maximumCount, fragment))
            recordedReads.append(.init(offset: offset, count: Int64(end) - offset))
            return bytes.subdata(in: Int(offset)..<end)
        }
    }
}
private final class IndexedPacketFixtures: NSObject {}

import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized)
struct NativeAACProfileTests {
    static let names = ["lc-mono.aac", "lc-stereo.aac", "he-stereo.aac", "hev2-stereo.aac", "he-stereo.m4a", "hev2-stereo.m4a"]
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/AACProfiles"))
#else
        try #require(Bundle(for: AACProfileFixtures.self).url(forResource: name, withExtension: nil, subdirectory: "AACProfiles"))
#endif
    }
    private func expected(_ name: String) -> (rate: Int, channels: Int) { name.hasPrefix("lc-mono") ? (24000, 1) : (48000, 2) }

    private func difference(_ actual: [Int16], _ expected: [Int16]) -> String {
        let differences = zip(actual, expected).enumerated().compactMap { index, pair in
            pair.0 == pair.1 ? nil : (index, abs(Int(pair.0) - Int(pair.1)))
        }
        return "samples \(actual.count)/\(expected.count), differing \(differences.count), first \(differences.first?.0 ?? -1), largest \(differences.map(\.1).max() ?? 0)"
    }

    /// User-visible audio outcome: the decode has the reference's length (within 50 ms) and is
    /// audible. Sample identity with Apple's decoder is not required; the full HE/HEv2 profile is
    /// established by the output rate and channel count.
    private func expectAudio(_ actual: [Int16], like expected: [Int16], channels: Int, rate: Int, _ label: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let frames = actual.count / channels, expectedFrames = expected.count / channels
        #expect(abs(frames - expectedFrames) <= rate / 20, "\(label): \(frames) frames, expected \(expectedFrames)", sourceLocation: sourceLocation)
        let peak = actual.lazy.map { abs(Int($0)) }.max() ?? 0, reference = expected.lazy.map { abs(Int($0)) }.max() ?? 0
        #expect(peak * 2 >= reference, "\(label): silent or much quieter than the reference", sourceLocation: sourceLocation)
    }

    /// Seeks land within 0.25 s of the target, play contiguously to the end and have the
    /// remaining length of the reference (within 50 ms).
    private func expectSeek(_ decoder: any PCMDecoding, target: CMTime, remaining expected: [Int16], _ label: String) async throws {
        var actual = [Int16](), first: CMTime?
        while let packet = try await decoder.next() {
            if first == nil { first = packet.presentationTime }
            #expect(packet.presentationTime == first! + CMTime(value: Int64(actual.count / 2), timescale: 48000))
            actual += packet.samples
        }
        if expected.isEmpty { #expect(actual.count <= 2400 * 2, "\(label): audio after the end") }
        else { #expect(abs((first ?? .invalid).seconds - target.seconds) <= 0.25, "\(label): landed at \(first?.seconds ?? -1) s") }
        expectAudio(actual, like: expected, channels: 2, rate: 48000, label)
        #expect(decoder.sampleRate == 48000 && decoder.channels == 2)
        #expect(try await decoder.next() == nil)
    }

    private func baseline(_ name: String) throws -> [Int16] {
        // The M4A derivatives contain identical packet payloads. Apple's file
        // reader misses their implicit SBR/PS; use the fully identified ADTS
        // counterpart as the independent full-profile waveform oracle.
        let referenceName = name.replacingOccurrences(of: ".m4a", with: ".aac")
        let format = expected(name)
        let reference = try AVAudioFile(forReading: fixture(referenceName), commonFormat: .pcmFormatInt16, interleaved: true)
        try #require(Int(reference.processingFormat.sampleRate) == format.rate && Int(reference.processingFormat.channelCount) == format.channels)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: reference.processingFormat, frameCapacity: 4096))
        var result = [Int16]()
        while reference.framePosition < reference.length {
            try reference.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, reference.length - reference.framePosition)))
            try #require(buffer.frameLength > 0)
            result += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * format.channels))
        }
        return result
    }

    @Test(arguments: names, ["incremental", "buffered"])
    func decodeRetainsFullProfileRateChannelsAndAudio(name: String, route: String) async throws {
        let url = try fixture(name), bytes = try Data(contentsOf: url), format = expected(name)
        let expected = try baseline(name)
        let decoder: any PCMDecoding
        if route == "incremental" { decoder = try await NativeIncrementalPCMDecoder.open(input: Input(bytes)) }
        else {
            let kind: NativeAudioSourceTimeline.Format = name.hasSuffix("m4a") ? .mp4 : .adts
            let timeline = try await NativeAudioSourceTimeline.read(input: Input(bytes), format: kind)
            decoder = try await NativeBufferedAudioDecoder.open(producer: NativeAudioPacketProducer(input: Input(bytes), timeline: timeline, format: kind))
        }
        defer { Task { await decoder.cancel() } }
        #expect(decoder.sampleRate == format.rate && decoder.channels == format.channels)
        var actual = [Int16]()
        while let packet = try await decoder.next() { actual += packet.samples }
        expectAudio(actual, like: expected, channels: format.channels, rate: format.rate, "\(name) \(route)")
        await decoder.cancel()
    }

    @Test(arguments: names, [0, 1])
    func indexedPacketConfigurationRetainsThePlayableFullProfile(name: String, seconds: Int) throws {
        let input = Input(try Data(contentsOf: fixture(name))), format = expected(name)
        let reader = try NativeAudioPacketFileReader(input: input, format: name.hasSuffix("m4a") ? .mp4 : .adts, start: CMTime(value: Int64(seconds), timescale: 1))
        #expect(reader.configuration.basic.mSampleRate == Double(format.rate))
        #expect(reader.configuration.basic.mChannelsPerFrame == UInt32(format.channels))
        let packetFrames = name.hasPrefix("he") ? 2048 : 1024
        let target = Int64(seconds * format.rate)
        #expect(reader.firstPacket <= target / Int64(packetFrames))
        #expect(reader.firstFrame == reader.firstPacket * Int64(packetFrames))
        let file = try AVAudioFile(forReading: fixture(name.replacingOccurrences(of: ".m4a", with: ".aac")))
        var frames = 0
        while let batch = try reader.next() {
            frames += Int(batch.packetCount) * Int(reader.configuration.basic.mFramesPerPacket)
        }
        #expect(abs(Int64(frames) + reader.firstFrame - file.length) <= Int64(format.rate / 20))
    }


    @Test(arguments: names, 0..<4)
    func capturedStreamingPreservesFullProfileAndFiniteOfflineReplay(name: String, configuration: Int) async throws {
        let proxyEnabled = configuration & 1 != 0, known = configuration & 2 != 0
        let bytes = try Data(contentsOf: fixture(name)), format = expected(name), expected = try baseline(name)
        let credentials = FeedCredentials(username: "profile", password: "saved")
        let proxyAuthorization = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"profile\""])
            }
            #expect(request.headers["range"] == nil)
            return .init(headers: ["Content-Type": name.hasSuffix("m4a") ? "audio/mp4" : "audio/aac"], body: bytes, includeAutomaticContentLength: known)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("aac-profile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://profiles.invalid/episode.mp3")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let decoder = try await source.makeDecoder()
        #expect(decoder.sampleRate == format.rate && decoder.channels == format.channels)
        #expect(decoder.sourceSeekable == (known || name.hasSuffix("m4a")))
        var actual = [Int16]()
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: Int64(actual.count / format.channels), timescale: Int32(format.rate)))
            actual += packet.samples
        }
        expectAudio(actual, like: expected, channels: format.channels, rate: format.rate, name)
        await decoder.cancel()
        if known {
            #expect(cache.snapshot(for: url).committedBytes == bytes.count)
            let requests = server.requests.count
            server.stop()
            let replay = try await source.makeDecoder()
            #expect(replay.sampleRate == format.rate && replay.channels == format.channels)
            var replayed = [Int16]()
            while let packet = try await replay.next() { replayed += packet.samples }
            expectAudio(replayed, like: expected, channels: format.channels, rate: format.rate, "\(name) offline")
            await replay.cancel()
            #expect(server.requests.count == requests)
        } else { #expect(cache.snapshot(for: url).committedBytes == 0) }
    }

    @Test(arguments: ["he-stereo.m4a", "hev2-stereo.m4a"], [1, 17, 4096])
    func fragmentedM4APreservesEveryPacketAndFullFrameTimeline(name: String, fragment: Int) throws {
        let bytes = try Data(contentsOf: fixture(name))
        let reference = try Data(contentsOf: fixture(name.replacingOccurrences(of: ".m4a", with: ".aac")))
        var expected = Data(), position = 0, expectedPackets = 0
        while position < reference.count {
            try #require(position + 7 <= reference.count && reference[position] == 255 && reference[position + 1] & 1 == 1)
            let size = Int(reference[position + 3] & 3) << 11 | Int(reference[position + 4]) << 3 | Int(reference[position + 5] >> 5)
            try #require(size >= 7 && position + size <= reference.count)
            expected.append(reference[(position + 7)..<(position + size)])
            position += size; expectedPackets += 1
        }
        let parser = try NativeAudioStreamParser()
        defer { parser.close() }
        var batches: [NativeAudioStreamParser.Batch] = []
        for offset in stride(from: 0, to: bytes.count, by: fragment) {
            batches += try parser.append(bytes.subdata(in: offset..<min(bytes.count, offset + fragment)))
        }
        batches += try parser.finish()
        let format = try #require(parser.configuration)
        #expect(format.basic.mSampleRate == 48000 && format.basic.mChannelsPerFrame == 2)
        #expect(format.primingFrames == 0 && format.validFrames == Int64(expectedPackets * 2048))
        var actual = Data(), frames: Int64 = 0, packets = 0
        for batch in batches {
            #expect(batch.firstFrame == frames)
            for description in try #require(batch.descriptions) {
                let count = description.mVariableFramesInPacket == 0 ? format.basic.mFramesPerPacket : description.mVariableFramesInPacket
                #expect(count == 2048)
                frames += Int64(count)
            }
            actual.append(batch.bytes); packets += Int(batch.packetCount)
        }
        #expect(actual == expected && packets == expectedPackets)
    }

    @Test(arguments: ["he-stereo.m4a", "hev2-stereo.m4a"], [0.5, 1.0, 3.9])
    func finiteFullProfileSeeksLandAndPlayRemainingAudio(name: String, seconds: Double) async throws {
        let target = CMTime(seconds: seconds, preferredTimescale: 48000)
        let expected = Array(try baseline(name).dropFirst(Int(target.value) * 2))
        // The app's streamed seek route: NativeAudioPlaybackSource's indexed producer and buffered decoder.
        let bytes = try Data(contentsOf: fixture(name))
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(bytes), format: .mp4)
        let producer = NativeAudioPacketProducer(input: Input(bytes), timeline: timeline, format: .mp4, indexedStart: target)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false, start: target)
        defer { Task { await decoder.cancel() } }
        try await expectSeek(decoder, target: target, remaining: expected, "\(name) @\(seconds)")
        await decoder.cancel()
        producer.stop(); await producer.waitForExit()
    }

    private static let invalidCookies: [Data] = [Data(), Data([0x13]), Data([0x0b, 0x10]), Data([0x1b, 0x10]),
        Data([0x2b, 0x10]), Data([0x17, 0x90]), Data([0x13, 0x00]), Data([0x13, 0x38]),
        Data([0x13, 0x14]), Data([0x13, 0x12]), Data([0x13, 0x11]), Data([3, 0x80, 0x80, 0x80, 0x80]),
        Data([3, 8, 0, 0, 0x40, 8, 5, 2, 0x13, 0x10]), Data(repeating: 0, count: 65537)]

    @Test(arguments: invalidCookies)
    func unrepresentableOrMalformedCoreIsNotReframed(cookie: Data) {
        #expect(NativeAACProfileDiscovery.core(cookie) == nil)
    }

    @Test func discoveryPreservesErrorsFromCapturedInput() throws {
        enum Sentinel: Error { case read }
        let file = try NativeAudioFileInput(input: Input(Data(contentsOf: fixture("hev2-stereo.m4a"))))
        defer { file.close() }
        #expect(throws: Sentinel.self) {
            _ = try NativeAACProfileDiscovery.file(file.audioFile, checkInput: { throw Sentinel.read })
        }
        #expect(throws: CancellationError.self) {
            _ = try NativeAACProfileDiscovery.file(file.audioFile, checkInput: { throw CancellationError() })
        }
    }

    @Test(arguments: ["he-stereo.m4a", "hev2-stereo.m4a"], ["episode.m4a", "episode.media", "episode.mp3", "episode"])
    func downloadedFullProfileUsesContentInsteadOfSuffix(name: String, filename: String) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("aac-local-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: fixture(name), to: url)
        let expected = try baseline(name)
        let decoder = try NativePCMDecoder(url: url)
        #expect(decoder.sampleRate == 48000 && decoder.channels == 2)
        var actual = [Int16]()
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: Int64(actual.count / 2), timescale: 48000))
            actual += packet.samples
        }
        expectAudio(actual, like: expected, channels: 2, rate: 48000, "\(name) \(filename)")
        await decoder.cancel()
    }

    @Test(arguments: ["he-stereo.m4a", "hev2-stereo.m4a"], [1.0, 3.9, 8.0])
    func downloadedProfileSeeksLandAndPlayRemainingAudio(name: String, seconds: Double) async throws {
        let target = CMTime(seconds: seconds, preferredTimescale: 48000)
        let expected = Array(try baseline(name).dropFirst(Int(target.value) * 2))
        let decoder = try NativePCMDecoder(url: fixture(name), start: target)
        try await expectSeek(decoder, target: target, remaining: expected, "\(name) @\(seconds)")
        await decoder.cancel()
    }

    @Test(arguments: ["he-stereo.m4a", "hev2-stereo.m4a"])
    func localProfileKeepsOpenedMediaAndCancellationStopsReads(name: String) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("aac-owned-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("download.media")
        try FileManager.default.copyItem(at: fixture(name), to: url)
        let expected = try baseline(name)
        let decoder = try NativePCMDecoder(url: url)
        try FileManager.default.removeItem(at: url)
        var actual = [Int16]()
        while let packet = try await decoder.next() { actual += packet.samples }
        expectAudio(actual, like: expected, channels: 2, rate: 48000, name)
        await decoder.cancel()
        await #expect(throws: NativePCMDecoder.Failure.cancelled) { try await decoder.next() }
    }

    @Test(arguments: ["he-stereo.m4a", "hev2-stereo.m4a"], [Float(1), Float(1.5), Float(2)])
    func localProfileFeedsSpeedAndSilenceProcessing(name: String, speed: Float) async throws {
        let actualStream = try LocalPCMPlaybackStream(url: fixture(name), skipSilence: true, speed: speed)
        let expectedStream = try LocalPCMPlaybackStream(url: fixture(name.replacingOccurrences(of: ".m4a", with: ".aac")), skipSilence: true, speed: speed)
        var actual = [Int16](), expected = [Int16]()
        while let samples = try await actualStream.next() { actual += samples }
        while let samples = try await expectedStream.next() { expected += samples }
        #expect(actualStream.sampleRate == 48000 && actualStream.channels == 2)
        #expect(try await actualStream.next() == nil)
        // The M4A plays like its ADTS twin through speed and skip-silence (within 50 ms).
        expectAudio(actual, like: expected, channels: 2, rate: 48000, "\(name) speed=\(speed)")
        #expect(abs(await actualStream.decodedFrames - expectedStream.decodedFrames) <= 2400)
        #expect(abs(await actualStream.totalSkippedFrames - expectedStream.totalSkippedFrames) <= 2400)
        await actualStream.cancel(); await expectedStream.cancel()
    }

    private final class Input: MediaByteInput, Sendable {
        let bytes: Data
        private let cancelled = Mutex(false)
        init(_ bytes: Data) { self.bytes = bytes }
        var length: Int64? { Int64(bytes.count) }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func cancel() { cancelled.withLock { $0 = true } }
        func checkFailure() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            guard offset < bytes.count else { return Data() }
            return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + min(4096, maximumCount)))
        }
    }
}
private final class AACProfileFixtures: NSObject {}

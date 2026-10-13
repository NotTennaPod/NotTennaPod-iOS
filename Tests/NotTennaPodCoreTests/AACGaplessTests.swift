import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(1))) struct AACGaplessTests {
    static let names = ["lc", "he", "hev2"]
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/AACGapless"))
#else
        try #require(Bundle(for: GaplessFixtures.self).url(forResource: name, withExtension: nil, subdirectory: "AACGapless"))
#endif
    }
    private func baseline(_ name: String) throws -> [Int16] {
        let file = try AVAudioFile(forReading: fixture(name + ".m4a"), commonFormat: .pcmFormatInt16, interleaved: true)
        try #require(file.processingFormat.sampleRate == 48000 && file.processingFormat.channelCount == 2)
        // This is the exact native file-reader interval, not the original
        // renderer's separately recorded whole-buffer edit admission.
        try #require(file.length == (name == "lc" ? 192528 : 196544))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var result = [Int16]()
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            result += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2))
        }
        return result
    }
    /// Frames in [Int16] interleaved stereo.
    private static func frames(_ samples: [Int16]) -> Int { samples.count / 2 }
    private static func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }
    private static func microseconds(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .roundTowardZero).value
    }
    /// Same audible run: amount of audio within 50 ms and first media time
    /// within 0.25 s of the expected run.
    private static func expectSameRun(times: [Int64], frames: Int, expectedFirst: Int64?, expectedFrames: Int, _ label: String,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(frames - expectedFrames) <= 2400, "\(label): \(frames) frames, expected \(expectedFrames)", sourceLocation: sourceLocation)
        if let expectedFirst, let first = times.first {
            #expect(abs(first - expectedFirst) <= 250_000, "\(label): starts at \(first) us, expected \(expectedFirst)", sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: names, ["incremental", "buffered", "local"])
    func fullProfileAndDeclaredNativeTrimInterval(name: String, route: String) async throws {
        let url = try fixture(name + ".m4a"), bytes = try Data(contentsOf: url)
        let decoder: any PCMDecoding
        switch route {
        case "local": decoder = try NativePCMDecoder(url: url)
        case "incremental": decoder = try await NativeIncrementalPCMDecoder.open(input: Input(bytes))
        default:
            let timeline = try await NativeAudioSourceTimeline.read(input: Input(bytes), format: .mp4)
            decoder = try await NativeBufferedAudioDecoder.open(producer: NativeAudioPacketProducer(input: Input(bytes), timeline: timeline, format: .mp4))
        }
        defer { Task { await decoder.cancel() } }
        #expect(decoder.sampleRate == 48000 && decoder.channels == 2)
        let expected = try baseline(name)
        var actual = [Int16](), gaps = 0
        while let packet = try await decoder.next() {
            // No audible gap or overlap between consecutive buffers (10 ms).
            let position = CMTime(value: Int64(Self.frames(actual)), timescale: 48000)
            if abs(CMTimeGetSeconds(packet.presentationTime) - CMTimeGetSeconds(position)) > 0.01 { gaps += 1 }
            actual += packet.samples
        }
        #expect(gaps == 0, "\(name) \(route): \(gaps) discontinuities")
        // Every profile decodes the whole file (within 50 ms of the system
        // decoder's trimmed length) with the same loudness, i.e. real audio.
        #expect(abs(Self.frames(actual) - Self.frames(expected)) <= 2400, "\(name) \(route): frames \(Self.frames(actual))/\(Self.frames(expected))")
        let loudness = Self.rms(actual), reference = Self.rms(expected)
        #expect(reference > 100 && abs(loudness - reference) <= reference * 0.1, "\(name) \(route): rms \(loudness), system \(reference)")
        await decoder.cancel()
    }

    @Test(arguments: names, 0..<4)
    func originalSourceEditAdmitsWholeBuffers(name: String, configuration: Int) async throws {
        let known = configuration & 1 == 0, proxyEnabled = configuration & 2 != 0
        let bytes = try Data(contentsOf: fixture(name + ".m4a"))
        let credentials = FeedCredentials(username: "edits", password: "saved")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "audio/mp4"], body: bytes, includeAutomaticContentLength: known)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("aac-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://edits.invalid/opaque.media")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let report = try JSONDecoder().decode(SourceReport.self, from: Data(contentsOf: fixture("android-report.json")))
        try #require(report.complete && report.cases.count == 6)
        let original = try #require(report.cases.first { $0.file == name + ".m4a" })
        try #require(original.ended && original.startMs == 0)
        let expected = original.buffers.filter { !$0.decodeOnly }
        func check(_ decoder: NativeAudioSourceDecoder, expected: [SourceReport.Buffer], _ label: String) async throws {
            #expect(decoder.sampleRate == 48000 && decoder.channels == 2)
            #expect(decoder.sourceDurationMilliseconds == original.durationMs)
            var times = [Int64](), frames = 0
            while let packet = try await decoder.next() {
                times.append(Self.microseconds(packet.presentationTime))
                frames += packet.samples.count / 2
            }
            Self.expectSameRun(times: times, frames: frames, expectedFirst: expected.first?.mediaPtsUs,
                expectedFrames: expected.reduce(0) { $0 + $1.bytes } / 4, "\(name) \(label)")
            await decoder.cancel()
        }
        try await check(source.makeDecoder(), expected: expected, "from start")
        if known {
            server.stop()
            // Offline from the cache: seeking to 1 s plays the rest of the
            // episode, and returning to the start plays all of it again.
            try await check(source.makeDecoder(start: CMTime(value: 1, timescale: 1)),
                expected: expected.filter { $0.mediaPtsUs >= 1_000_000 }, "offline seek to 1 s")
            try await check(source.makeDecoder(), expected: expected, "offline from start")
        }
    }

    @Test func sourceClipStopsBeforeUnneededMediaAndRejectsIncompleteSelectedAudio() async throws {
        var bytes = try Data(contentsOf: fixture("lc.m4a"))
        let elst = try #require(bytes.range(of: Data("elst".utf8)))
        func field(_ value: UInt32) -> Data { Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        // One second from media time one second: exactly that second plays,
        // without needing the unselected remainder of the file.
        bytes.replaceSubrange((elst.upperBound + 8)..<(elst.upperBound + 12), with: field(1000))
        bytes.replaceSubrange((elst.upperBound + 12)..<(elst.upperBound + 16), with: field(48000))
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(bytes), format: .mp4)
        let allowed = bytes.count * 3 / 4
        let producer = NativeAudioPacketProducer(input: Input(bytes, readLimit: allowed), timeline: timeline, format: .mp4, applyMP4Edits: true)
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, admission: .wholeBuffer)
        var times = [Int64](), frames = 0
        while let packet = try await decoder.next() {
            times.append(Self.microseconds(packet.presentationTime))
            frames += packet.frameCount
        }
        Self.expectSameRun(times: times, frames: frames, expectedFirst: 0, expectedFrames: 48000, "one second clip")
        await decoder.cancel()
        // The same read restriction is a real error when the selected edit
        // needs the remaining media. Do not turn truncation into successful EOF.
        let original = try Data(contentsOf: fixture("lc.m4a"))
        let fullTimeline = try await NativeAudioSourceTimeline.read(input: Input(original), format: .mp4)
        await #expect(throws: Input.Failure.readPastSelectedMedia) {
            let full = try await NativeBufferedAudioDecoder.open(producer: NativeAudioPacketProducer(
                input: Input(original, readLimit: allowed), timeline: fullTimeline, format: .mp4, applyMP4Edits: true), admission: .wholeBuffer)
            defer { Task { await full.cancel() } }
            while let _ = try await full.next() {}
        }
    }

    @Test(arguments: names, [0, 980, 1000, 1500, 3000])
    func coldEditedSeeksClampToSelectedSamplesAndRemainReplayable(name: String, milliseconds: Int) async throws {
        var bytes = try Data(contentsOf: fixture(name + ".m4a"))
        func field(_ value: UInt32) -> Data { Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        let elst = try #require(bytes.range(of: Data("elst".utf8)))
        bytes.replaceSubrange((elst.upperBound + 8)..<(elst.upperBound + 12), with: field(1000))
        bytes.replaceSubrange((elst.upperBound + 12)..<(elst.upperBound + 16), with: field(48000))
        // Keep the container's displayed track/movie duration consistent with
        // the new edit; the unchanged sample table describes the original media.
        for type in ["mvhd", "tkhd"] {
            let header = try #require(bytes.range(of: Data(type.utf8)))
            let offset = type == "mvhd" ? 16 : 20
            bytes.replaceSubrange((header.upperBound + offset)..<(header.upperBound + offset + 4), with: field(1000))
        }
        let body = bytes
        // The episode is one second long: a seek inside it plays the rest of
        // that second from the requested position; a seek past it plays nothing.
        let remaining = max(0, 1000 - milliseconds)
        let expectedFirst: Int64? = remaining > 0 ? Int64(milliseconds) * 1000 : nil
        for configuration in 0..<4 {
            let known = configuration & 1 == 0, proxyEnabled = configuration & 2 != 0
            let server = try await LoopbackHTTPServer.start { request in
                if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                    guard offset < body.count else { return .init(status: 416, headers: ["Content-Range": "bytes */\(body.count)"]) }
                    return .init(status: 206, headers: ["Content-Type": "audio/mp4", "Content-Range": "bytes \(offset)-\(body.count - 1)/\(body.count)"], body: Data(body.dropFirst(offset)))
                }
                return .init(headers: ["Content-Type": "audio/mp4"], body: body, includeAutomaticContentLength: known)
            }
            defer { server.stop() }
            let directory = URL.temporaryDirectory.appendingPathComponent("aac-cold-edit-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = try SharedStreamingCache(directory: directory)
            let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
            let url = proxyEnabled ? URL(string: "http://cold-edit.invalid/opaque.media")! : server.url
            let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: nil, cache: cache)
            defer { remote.input.cancel(); remote.relay.cancel() }
            let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: nil, cache: cache)
            let decoder = try await source.makeDecoder(start: CMTime(value: Int64(milliseconds), timescale: 1000))
            #expect(decoder.sourceDurationMilliseconds == 1000 && decoder.sourceSeekable == true)
            var times = [Int64](), frames = 0
            while let packet = try await decoder.next() {
                times.append(Self.microseconds(packet.presentationTime))
                frames += packet.frameCount
            }
            Self.expectSameRun(times: times, frames: frames, expectedFirst: expectedFirst, expectedFrames: remaining * 48,
                "\(name) seek to \(milliseconds) ms, configuration \(configuration)")
            await decoder.cancel()
            // A seek beyond the edit must not poison a later return to its
            // beginning, including an initially unknown extent.
            let replay = try await source.makeDecoder()
            var replayTimes = [Int64](), replayFrames = 0
            while let packet = try await replay.next() {
                replayTimes.append(Self.microseconds(packet.presentationTime))
                replayFrames += packet.frameCount
            }
            Self.expectSameRun(times: replayTimes, frames: replayFrames, expectedFirst: 0, expectedFrames: 48000,
                "\(name) replay from start, configuration \(configuration)")
            await replay.cancel()
        }
    }

    private struct SourceReport: Decodable {
        let complete: Bool
        let cases: [Case]
        struct Case: Decodable {
            let file: String, startMs: Int, ended: Bool, durationMs: Int64
            let buffers: [Buffer]
        }
        struct Buffer: Decodable { let mediaPtsUs: Int64, bytes: Int, decodeOnly: Bool }
    }

    private final class Input: MediaByteInput, Sendable {
        enum Failure: Error, Equatable { case readPastSelectedMedia }
        let bytes: Data
        let readLimit: Int?
        init(_ bytes: Data, readLimit: Int? = nil) { self.bytes = bytes; self.readLimit = readLimit }
        var length: Int64? { Int64(bytes.count) }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func cancel() {}
        func checkFailure() throws { try Task.checkCancellation() }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try Task.checkCancellation()
            if let readLimit, offset >= readLimit { throw Input.Failure.readPastSelectedMedia }
            guard offset < bytes.count else { return Data() }
            return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + min(4096, maximumCount)))
        }
    }
}
private final class GaplessFixtures: NSObject {}

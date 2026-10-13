import CoreMedia
import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct MP4EditedStartupTests {
    private struct Manifest: Decodable {
        let files: [File]
        struct File: Decodable {
            let name: String, sha256: String, edits: [[Int64]]
        }
    }
    private struct Report: Decodable {
        let complete: Bool, cases: [Case]
        struct Case: Decodable {
            let file: String, startMs: Int64, durationMs: Int64
            let ended: Bool, timedOut: Bool
            let admittedBytes: Int, trimmedBytes: Int
            let buffers: [Buffer]
        }
        struct Buffer: Decodable { let mediaPtsUs: Int64, bytes: Int, decodeOnly: Bool }
    }
    private struct Point { let time: Int64, rawFrame: Int64, frames: Int }
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/MP4EditedStartup"))
#else
        try #require(Bundle(for: EditedStartupFixtures.self).url(forResource: name, withExtension: nil, subdirectory: "MP4EditedStartup"))
#endif
    }
    private func reference(_ index: Int) throws -> (Report.Case, Data, [Point]) {
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: fixture("android-report.json")))
        try #require(report.complete && report.cases.count == 36)
        let original = report.cases[index]
        try #require(original.ended && !original.timedOut)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixture("manifest.json")))
        let file = try #require(manifest.files.first { $0.name == original.file })
        let bytes = try Data(contentsOf: fixture(file.name))
        try #require(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == file.sha256)
        let frames: Int64 = file.name.hasPrefix("lc-") ? 1024 : 2048
        var offset: Int64 = 0, points = [Point]()
        // Independently derive unedited sample positions from literal fixture
        // edits. Check their presentation order against every original buffer.
        for edit in file.edits {
            try #require(edit.count == 2)
            let duration = edit[0], mediaStart = edit[1]
            if mediaStart >= 0 {
                let first = mediaStart / frames
                let last = (mediaStart + duration * 48 + frames - 1) / frames
                for packet in first..<last {
                    let time = offset * 1000 + (packet * frames - mediaStart) * 1_000_000 / 48000
                    if time >= original.startMs * 1000 { points.append(Point(time: time, rawFrame: packet * frames, frames: Int(frames))) }
                }
            }
            offset += duration
        }
        let admitted = original.buffers.filter { !$0.decodeOnly }
        try #require(points.map(\.time) == admitted.map(\.mediaPtsUs))
        try #require(points.map { $0.frames * 4 } == admitted.map(\.bytes))
        try #require(original.trimmedBytes == max(0, original.admittedBytes - 3072 * 4))
        return (original, bytes, points)
    }

    /// User-visible outcome of MP4 edit lists: playback starts where Android's does (within
    /// 0.25 s), the shown duration matches (within 50 ms), no audio is lost (within 50 ms),
    /// and speed/skip-silence then apply to the audible result. Packet-level decoder
    /// coordinates and sample identity are not required.
    private func verify(_ decoder: NativeAudioSourceDecoder, original: Report.Case, points: [Point],
                        speed: Float = 1, skipSilence: Bool = false) async throws {
        #expect(decoder.sampleRate == 48000 && decoder.channels == 2)
        #expect(decoder.sourceDurationMilliseconds.map { abs($0 - original.durationMs) <= 50 } == true)
        let observed = Observed(decoder)
        let stream = try LocalPCMPlaybackStream(decoder: observed, skipSilence: skipSilence, speed: speed, maximumOutputFrames: 127)
        var actual = [Int16]()
        while let packet = try await stream.nextPacket() { actual += packet.samples }
        let packets = await observed.packets
        if let firstExpected = points.first {
            let firstActual = try #require(packets.first?.presentationTime)
            #expect(abs(firstActual.seconds - Double(firstExpected.time) / 1_000_000) <= 0.25,
                    "\(original.file) start\(original.startMs): playback starts at \(firstActual.seconds) s")
        } else {
            // A start at or past the edited end: Android presents no audio and the episode ends.
            #expect(actual.isEmpty, "\(original.file) start\(original.startMs): audio played past the end")
        }
        let rawFrames = points.reduce(Int64(0)) { $0 + Int64($1.frames) }
        #expect(abs(await stream.decodedFrames - rawFrames) <= 2400, "\(original.file) start\(original.startMs): audio lost or added")
        // Priming frames removed by the edit list are never presented.
        let invalid = points.reduce(Int64(0)) { $0 + min(Int64($1.frames), max(0, 3072 - $1.rawFrame)) }
        let expectedOutput = Double(rawFrames - invalid) / Double(speed)
        let outputFrames = Double(actual.count / 2)
        if skipSilence {
            #expect(outputFrames <= expectedOutput + 2400, "skip-silence must only shorten the audio")
        } else {
            #expect(abs(outputFrames - expectedOutput) <= expectedOutput * 0.03 + 2400,
                    "\(original.file) start\(original.startMs): \(outputFrames) frames at \(speed)x, expected about \(expectedOutput)")
        }
        await stream.cancel()
        #expect(await observed.cancelled)
    }

    @Test(arguments: Array(stride(from: 0, to: 36, by: 2)), [false, true])
    func editPaddingPrecedesSpeedAndSilenceProcessing(index: Int, skipSilence: Bool) async throws {
        let (original, _, points) = try reference(index)
        let source = try NativeLocalAudioSource(url: fixture(original.file))
        try await verify(source.makeDecoder(processStartupTrim: true), original: original, points: points,
            speed: 1.5, skipSilence: skipSilence)
    }

    @MainActor @Test(arguments: ["lc", "he", "hev2"])
    func repeatedPaddingOnlySourceEndsWithoutPresentingInvalidSamples(profile: String) async throws {
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let factory = try PCMRecoveryFactory(nativeSourceURL: fixture(profile + "-all-prefix-tag.m4a"), makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1.5, skipSilence: true))
        defer { session.close() }
        try await session.prepare()
        #expect(session.state == .ended && session.sourceEnded && session.failure == nil)
        #expect(session.sourceDurationMilliseconds == 20 && session.sourceSeekable == true)
        #expect(session.writtenFrames == 0 && session.presentedFrames == 0)
        session.close()
        #expect(outputs.count == 1 && outputs[0].buffers.isEmpty && outputs[0].closed)
    }

    @Test(arguments: 0..<36, ["local", "direct", "unknown", "proxy"])
    func editedSourceCoordinatesTargetOnlyOriginalPadding(index: Int, route: String) async throws {
        let (original, bytes, points) = try reference(index)
        let start = CMTime(value: original.startMs, timescale: 1000)
        if route == "local" {
            let source = try NativeLocalAudioSource(url: fixture(original.file))
            try await verify(source.makeDecoder(start: start, processStartupTrim: true), original: original, points: points)
            return
        }
        let credentials = FeedCredentials(username: "edited", password: "saved")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "audio/mp4"], body: bytes, includeAutomaticContentLength: route != "unknown")
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("edited-startup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SharedStreamingCache(directory: root)
        let proxy = route == "proxy" ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = route == "proxy" ? URL(string: "http://edited.invalid/episode.media")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        try await verify(source.makeDecoder(start: start, processStartupTrim: true), original: original, points: points)
        if route != "unknown" {
            // Even a partial local cache plus the retained source queue must
            // replay this exact selected window without reopening the network.
            server.stop()
            try await verify(source.makeDecoder(start: start, processStartupTrim: true), original: original, points: points)
        }
    }

    private actor Observed: PCMDecoding {
        nonisolated let sampleRate: Int, channels: Int, startFrame: Int64, startTime: CMTime
        nonisolated let sourceStartupTrim: PCMStartupTrim?
        private let decoder: NativeAudioSourceDecoder
        private(set) var packets = [NativePCMDecoder.Packet](), cancelled = false
        init(_ decoder: NativeAudioSourceDecoder) {
            self.decoder = decoder; sampleRate = decoder.sampleRate; channels = decoder.channels
            startFrame = decoder.startFrame; startTime = decoder.startTime; sourceStartupTrim = decoder.sourceStartupTrim
        }
        func next() async throws -> NativePCMDecoder.Packet? {
            let packet = try await decoder.next(); if let packet { packets.append(packet) }; return packet
        }
        func cancel() async { cancelled = true; await decoder.cancel() }
    }
}
private final class EditedStartupFixtures: NSObject {}

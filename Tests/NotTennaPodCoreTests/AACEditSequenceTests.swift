import CoreMedia
import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) struct AACEditSequenceTests {
    private struct Report: Decodable {
        let complete: Bool
        let cases: [Case]
        struct Case: Decodable {
            let file: String, startMs: Int64, durationMs: Int64, ended: Bool, timedOut: Bool
            let buffers: [Buffer]
        }
        struct Buffer: Decodable { let mediaPtsUs: Int64, bytes: Int, decodeOnly: Bool }
    }
    private struct Manifest: Decodable {
        let files: [File]
        struct File: Decodable { let name: String, sha256: String; let edits: [Edit] }
        struct Edit: Decodable { let duration: Int64, mediaStart: Int64 }
    }
    private func fixture(_ name: String, folder: String = "AACEdits") throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/\(folder)"))
#else
        try #require(Bundle(for: EditFixtures.self).url(forResource: name, withExtension: nil, subdirectory: folder))
#endif
    }
    /// Edit discontinuities (> 200 ms jumps in media time) mark where the
    /// listener hears the next edited section begin.
    private static func jumps(_ times: [Int64]) -> [Int64] {
        var result = times.first.map { [$0] } ?? []
        for (previous, next) in zip(times, times.dropFirst()) where abs(next - previous) > 200_000 { result.append(next) }
        return result
    }
    /// User-visible equivalence with Android's rendered edit list: the same
    /// amount of audio (within 50 ms), starting where Android starts and
    /// jumping between edited sections where Android jumps (within 0.25 s).
    private static func expectAudiblyEqual(times: [Int64], bytes: Int, expected: [Report.Buffer], _ label: String,
                                           sourceLocation: SourceLocation = #_sourceLocation) {
        let frames = bytes / 4, expectedFrames = expected.reduce(0) { $0 + $1.bytes } / 4
        #expect(abs(frames - expectedFrames) <= 2400, "\(label): \(frames) frames, Android \(expectedFrames)", sourceLocation: sourceLocation)
        let actualJumps = jumps(times), expectedJumps = jumps(expected.map(\.mediaPtsUs))
        let sameJumps = actualJumps.count == expectedJumps.count
            && zip(actualJumps, expectedJumps).allSatisfy { abs($0 - $1) <= 250_000 }
        #expect(sameJumps, "\(label): sections \(actualJumps), Android \(expectedJumps)", sourceLocation: sourceLocation)
    }
    private static func drain(_ decoder: some PCMDecoding) async throws -> (times: [Int64], bytes: Int) {
        var times = [Int64](), bytes = 0
        while let packet = try await decoder.next() {
            times.append(CMTimeConvertScale(packet.presentationTime, timescale: 1_000_000, method: .roundTowardZero).value)
            bytes += packet.samples.count * MemoryLayout<Int16>.size
        }
        return (times, bytes)
    }

    /// Every captured edit case runs once. The four network routes (direct/proxy ×
    /// known/unknown length) rotate over profile, edit shape and start, so each route
    /// plays six cases, every edit shape meets every route, and both starts (including
    /// the 1.5× speed check at 0 ms) meet every route. Edit-list handling does not
    /// depend on the route, whose own behaviour other suites cover.
    @Test(arguments: 0..<24)
    func capturedEditSequenceMatchesOriginalRenderer(index: Int) async throws {
        let configuration = (index / 8 + (index % 8) / 2 + index % 2) % 4
        let proxyEnabled = configuration & 1 != 0, known = configuration & 2 == 0
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: fixture("android-report.json")))
        try #require(report.complete && report.cases.count == 24)
        let original = report.cases[index]
        try #require(original.ended && !original.timedOut)
        let bytes = try Data(contentsOf: fixture(original.file))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixture("manifest.json")))
        let identity = try #require(manifest.files.first { $0.name == original.file })
        try #require(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == identity.sha256)
        let credentials = FeedCredentials(username: "edits", password: "saved")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                guard offset < bytes.count else { return .init(status: 416, headers: ["Content-Range": "bytes */\(bytes.count)"]) }
                return .init(status: 206, headers: ["Content-Type": "audio/mp4", "Content-Range": "bytes \(offset)-\(bytes.count - 1)/\(bytes.count)"], body: Data(bytes.dropFirst(offset)))
            }
            return .init(headers: ["Content-Type": "audio/mp4"], body: bytes, includeAutomaticContentLength: known)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("aac-edit-sequence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://edit-sequence.invalid/opaque.media")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let decoder = try await source.makeDecoder(start: CMTime(value: original.startMs, timescale: 1000))
        defer { Task { await decoder.cancel() } }
        #expect(decoder.sourceDurationMilliseconds == original.durationMs && decoder.sourceSeekable == true)
        #expect(decoder.sampleRate == 48000 && decoder.channels == 2)
        let admitted = original.buffers.filter { !$0.decodeOnly }
        let first = try await Self.drain(decoder)
        Self.expectAudiblyEqual(times: first.times, bytes: first.bytes, expected: admitted, "\(original.file) @\(original.startMs)")
        await decoder.cancel()
        // Seeking elsewhere in the same source plays that section too.
        let alternate = try #require(report.cases.first { $0.file == original.file && $0.startMs != original.startMs })
        let replay = try await source.makeDecoder(start: CMTime(value: alternate.startMs, timescale: 1000))
        let second = try await Self.drain(replay)
        Self.expectAudiblyEqual(times: second.times, bytes: second.bytes, expected: alternate.buffers.filter { !$0.decodeOnly },
            "\(alternate.file) @\(alternate.startMs) after seek")
        await replay.cancel()
        if known {
            // Both selected sections have been read: a fresh owner replays
            // offline from the partial cache.
            server.stop()
            let cached = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
            defer { cached.input.cancel(); cached.relay.cancel() }
            let offline = try NativeAudioPlaybackSource(remote: cached, url: url, proxy: proxy, credentials: credentials, cache: cache)
            let again = try await offline.makeDecoder(start: CMTime(value: original.startMs, timescale: 1000))
            let third = try await Self.drain(again)
            Self.expectAudiblyEqual(times: third.times, bytes: third.bytes, expected: admitted, "\(original.file) offline")
            await again.cancel()
        }
        if original.startMs == 0 {
            // Speed processing keeps every decoded frame and advances position
            // through each edited section.
            let fresh = try await source.makeDecoder()
            let speed: Float = proxyEnabled ? 1.5 : 1
            let stream = try LocalPCMPlaybackStream(decoder: fresh, skipSilence: false, speed: speed)
            var segments = [LocalPCMPlaybackStream.Segment](), outputFrames: Int64 = 0
            while let packet = try await stream.nextPacket() {
                outputFrames += Int64(packet.samples.count / 2)
                if segments.last?.id != packet.segment.id { segments.append(packet.segment) }
            }
            let expectedFrames = Int64(admitted.reduce(0) { $0 + $1.bytes } / 4)
            let decodedFrames = await stream.decodedFrames
            #expect(abs(decodedFrames - expectedFrames) <= 2400)
            let expectedOutput = Double(expectedFrames) / Double(speed)
            #expect(abs(Double(outputFrames) - expectedOutput) <= expectedOutput * 0.03 + 2400)
            let anchors = Self.jumps(admitted.map(\.mediaPtsUs)), starts = segments.map(\.mediaStartMicroseconds)
            #expect(starts.count == anchors.count && zip(starts, anchors).allSatisfy { abs($0 - $1) <= 250_000 },
                "segments \(starts), Android sections \(anchors)")
            await stream.cancel()
        }
    }
    @Test(arguments: ["lc-repeat.m4a", "lc-reverse.m4a"], [982, 984, 990])
    func overlappingEditBoundaryKeepsOriginalColdAndRetainedAdmission(name: String, milliseconds: Int) async throws {
        let bytes = try Data(contentsOf: fixture(name))
        let timeline = try await NativeAudioSourceTimeline.read(input: Bytes(bytes), format: .mp4)
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: fixture("android-report.json")))
        let original = try #require(report.cases.first { $0.file == name && $0.startMs == 0 })
        let target = CMTime(value: Int64(milliseconds), timescale: 1000)
        // A seek next to an overlapping edit boundary plays the rest of the
        // edited timeline; the overlapping sections must not be dropped.
        let expected = original.buffers.filter { !$0.decodeOnly && $0.mediaPtsUs >= Int64(milliseconds) * 1000 }
        for retained in [false, true] {
            let producer = NativeAudioPacketProducer(input: Bytes(bytes), timeline: timeline, format: .mp4,
                indexedStart: retained ? .zero : target, applyMP4Edits: true)
            defer { producer.stop() }
            if retained {
                let beginning = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false, admission: .wholeBuffer)
                while let _ = try await beginning.next() {}
                await beginning.cancel()
                try #require(producer.seek(to: Int64(milliseconds) * 1000))
            }
            let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false, start: target, admission: .wholeBuffer)
            let result = try await Self.drain(decoder)
            Self.expectAudiblyEqual(times: result.times, bytes: result.bytes, expected: expected, "\(name) @\(milliseconds), retained=\(retained)")
            await decoder.cancel(); producer.stop(); await producer.waitForExit()
        }
    }
    private final class Bytes: MediaByteInput, Sendable {
        let bytes: Data
        init(_ bytes: Data) { self.bytes = bytes }
        var length: Int64? { Int64(bytes.count) }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func checkFailure() throws { try Task.checkCancellation() }
        func cancel() {}
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try Task.checkCancellation()
            guard offset < bytes.count else { return Data() }
            return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + min(4096, maximumCount)))
        }
    }

}
private final class EditFixtures: NSObject {}

import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Where the audio starts after an MP3 seek. Android (Media3 MediaCodecRenderer)
/// drops each whole decoded buffer that starts before the target, and an MP3
/// codec buffer is one MPEG frame (1152 or 576 samples). So the first heard
/// sample is the start of the first MPEG frame at or after the target: never
/// before it and less than one frame after it, at every sample rate, however
/// the compressed bytes arrived. Two errors are reported separately: admission
/// (labelled start − target, the decoder's grid) and first heard content (where
/// that audio really is in an uninterrupted decode − target), which on an
/// approximate seek map also contains the map's own estimate error.
@Suite(.serialized, .timeLimit(.minutes(3))) struct MP3SeekAdmissionTests {
    struct Marker: Decodable, Sendable {
        struct Header: Decodable, Sendable { let encoderDelay: Int64; let encoderPadding: Int64 }
        let name: String
        let sampleRate: Int
        let channels: Int
        let framesPerPacket: Int64
        let audioFrames: Int64
        let header: Header
        let framesUsingReservoir: Int
        var priming: Int64 { header.encoderDelay }
        var validFrames: Int64 { audioFrames * framesPerPacket - header.encoderDelay - header.encoderPadding }
        /// The independent expectation: the first MPEG frame starting at or after the target.
        func admitted(_ target: CMTime) -> Int64 {
            let first = CMTimeConvertScale(target, timescale: Int32(sampleRate), method: .roundAwayFromZero).value
            guard first > 0 else { return 0 }
            return (first + priming + framesPerPacket - 1) / framesPerPacket * framesPerPacket - priming
        }
        /// Presentation frame of the start of MPEG frame `index` (audio frames, after the Info/Xing frame).
        func boundary(_ index: Int64) -> Int64 { index * framesPerPacket - priming }
    }

    static let markers: [Marker] = {
        struct Manifest: Decodable { let files: [Marker] }
        let url = fixtureURL("manifest.json")!
        return (try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).files) ?? []
    }()
    static let names = ["marker-8k-mono.mp3", "marker-16k-mono.mp3", "marker-22k-stereo-vbr.mp3",
                        "marker-44k-stereo-vbr.mp3", "marker-48k-mono.mp3"]

    static func fixtureURL(_ name: String) -> URL? {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/MP3SeekMarkers")
#else
        Bundle(for: MP3SeekMarkerFixtures.self).url(forResource: name, withExtension: nil, subdirectory: "MP3SeekMarkers")
#endif
    }
    private func marker(_ name: String) throws -> Marker {
        try #require(Self.markers.first { $0.name == name })
    }

    /// Seek targets for one file: the start, just after it, exact frame boundaries
    /// and one sample either side, ordinary millisecond targets, and the end.
    private func targets(_ marker: Marker) -> [CMTime] {
        let rate = Int32(marker.sampleRate)
        let last = marker.boundary(marker.audioFrames - 1)
        var frames: [Int64] = [0, 1, marker.boundary(5), marker.boundary(5) - 1, marker.boundary(5) + 1,
                               marker.boundary(40) + marker.framesPerPacket / 2, last - 1, last, last + 1,
                               marker.validFrames - 1, marker.validFrames + marker.framesPerPacket]
        frames = frames.filter { $0 >= 0 }
        return frames.map { CMTime(value: $0, timescale: rate) }
            + [1, 101, 513, 1001, 2001, 4321].map { CMTime(value: $0, timescale: 1000) }
    }

    // MARK: - Decoder: independent of read and converter fragmentation

    @Test(arguments: names)
    func admissionIsOnTheMPEGFrameGridForEveryReadFragmentation(name: String) throws {
        let marker = try marker(name)
        let data = try Data(contentsOf: try #require(Self.fixtureURL(name)))
        let baseline = try decode(data, chunk: 4096, admit: nil)
        #expect(baseline.time == .zero && baseline.samples.count == Int(marker.validFrames) * marker.channels,
                "\(name): \(baseline.samples.count / marker.channels) frames, \(marker.validFrames) declared")
        for target in targets(marker) {
            let expected = marker.admitted(target)
            var results: [(chunk: Int, time: CMTime, samples: [Int16])] = []
            for chunk in [7, 137, 1000, 4096, 32_768] {
                let result = try decode(data, chunk: chunk, admit: target)
                results.append((chunk, result.time, result.samples))
            }
            for result in results {
                if expected >= marker.validFrames {
                    #expect(result.samples.isEmpty, "\(name) target \(target.seconds): audio after the end (chunk \(result.chunk))")
                    continue
                }
                let admitted = CMTimeConvertScale(result.time, timescale: Int32(marker.sampleRate), method: .roundTowardZero).value
                let wanted = CMTimeConvertScale(target, timescale: Int32(marker.sampleRate), method: .roundAwayFromZero).value
                #expect(result.time == CMTime(value: admitted, timescale: Int32(marker.sampleRate)))
                #expect(admitted == expected, "\(name) target \(wanted): admitted \(admitted), expected \(expected) (chunk \(result.chunk))")
                #expect(admitted >= wanted && admitted - wanted < marker.framesPerPacket)
                // Whole frames: exactly the uninterrupted decode from that frame to the end.
                #expect(result.samples == Array(baseline.samples.dropFirst(Int(expected) * marker.channels)),
                        "\(name) target \(wanted): audio differs from the file at the admitted frame (chunk \(result.chunk))")
            }
        }
    }

    /// Parser → decoder with seek admission, feeding the file in `chunk`-byte reads.
    private func decode(_ data: Data, chunk: Int, admit target: CMTime?) throws -> (time: CMTime, samples: [Int16]) {
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        var decoder: NativeMP3PCMDecoder?
        defer { decoder?.close() }
        var time: CMTime?, samples: [Int16] = []
        func drain() throws {
            while let decoder {
                switch try decoder.next() {
                case .audio(let packet):
                    #expect(packet.frameCount <= 4096)
                    if let time {
                        #expect(packet.presentationTime == time + CMTime(value: Int64(samples.count / packet.channels), timescale: Int32(packet.sampleRate)))
                    } else { time = packet.presentationTime }
                    samples += packet.samples
                case .needsInput, .ended: return
                }
            }
        }
        func consume(_ batches: [NativeMP3PacketParser.Batch]) throws {
            for batch in batches {
                if decoder == nil {
                    decoder = try NativeMP3PCMDecoder(format: batch.format, timing: batch.timing)
                    if let target { try decoder!.admit(from: target) }
                }
                try decoder!.accept(batch)
                try drain()
            }
        }
        for offset in stride(from: 0, to: data.count, by: chunk) {
            try consume(parser.append(data.subdata(in: offset..<min(offset + chunk, data.count))))
        }
        try consume(parser.finish())
        try #require(decoder).finish()
        try drain()
        #expect(try #require(decoder).isEnded)
        return (time ?? .invalid, samples)
    }

    // MARK: - Playback source: cold, retained, restore, resume and the end

    @Test(arguments: names)
    func downloadedEpisodeSeeksStartAtTheFirstWholeFrameAfterTheTarget(name: String) async throws {
        let marker = try marker(name)
        let url = try #require(Self.fixtureURL(name))
        let file = try LocalAudioBytes(url: url)
        let source = NativeMP3PlaybackSource(localURL: url, file: file)
        let initial = try await source.makeDecoder(prepareSourceTimeline: true)
        let baseline = try await drain(initial)
        #expect(initial.startTime == .zero && initial.timing.primingFrameCount == marker.priming)
        #expect(baseline.count == Int(marker.validFrames) * marker.channels)
        await initial.cancel()
        // Retained: the loaded episode is reused for every later seek, forward and back (resume rewinds).
        for target in targets(marker) + [CMTime(value: 4321, timescale: 1000), CMTime(value: 1321, timescale: 1000)] {
            let decoder = try await source.makeDecoder(start: target, prepareSourceTimeline: true)
            try await expectAdmission(decoder, marker: marker, target: target, baseline: baseline, path: "retained")
        }
        // Restore: a fresh item opened at a saved position.
        for target in [CMTime(value: 1001, timescale: 1000), CMTime(value: marker.boundary(77), timescale: Int32(marker.sampleRate)),
                       CMTime(value: marker.validFrames - 3, timescale: Int32(marker.sampleRate))] {
            let fresh = NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url))
            let decoder = try await fresh.makeDecoder(start: target, prepareSourceTimeline: true)
            try await expectAdmission(decoder, marker: marker, target: target, baseline: baseline, path: "restore")
        }
    }

    @Test(arguments: names)
    func streamedEpisodeSeeksOutsideLoadedAudioStartAtAWholeFrame(name: String) async throws {
        let marker = try marker(name)
        let media = try Data(contentsOf: try #require(Self.fixtureURL(name)))
        let baseline = try decode(media, chunk: 4096, admit: nil).samples
        // The first response stops after a quarter of the file, so later targets are
        // outside loaded audio and use the file's seek map (a cold indexed seek).
        let prefix = media.count / 4
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"marker\"",
                    "Content-Range": "bytes \(start)-\(media.count - 1)/\(media.count)"], body: media.subdata(in: start..<media.count))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"marker\"", "Content-Length": "\(media.count)"],
                body: Data(media.prefix(prefix)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        // Streaming always has the shared cache and its retry budget.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-admission-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy(), cache: try SharedStreamingCache(directory: directory))
        let initial = try await source.makeDecoder(prepareSourceTimeline: true)
        await initial.cancel()
        let rate = Int32(marker.sampleRate)
        let late = marker.boundary(marker.audioFrames * 2 / 3)
        for target in [CMTime(value: 4321, timescale: 1000), CMTime(value: late, timescale: rate),
                       CMTime(value: late + 1, timescale: rate), CMTime(value: 3003, timescale: 1000),
                       CMTime(value: marker.validFrames - 3, timescale: rate)] {
            let decoder = try await source.makeDecoder(start: target, prepareSourceTimeline: true)
            try await expectAdmission(decoder, marker: marker, target: target, baseline: baseline, path: "indexed", exactGrid: false)
        }
        #expect(server.requests.contains { $0.headers["range"] != nil })
    }

    private func drain(_ decoder: NativeMP3SourceDecoder) async throws -> [Int16] {
        var samples: [Int16] = []
        while let packet = try await decoder.next() {
            #expect(packet.frameCount <= 4096)
            #expect(packet.presentationTime == decoder.startTime + CMTime(value: Int64(samples.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            samples += packet.samples
        }
        return samples
    }

    /// Admission against the decoder's own timeline, then where the heard audio
    /// really is in the uninterrupted decode. `exactGrid` paths have no seek-map
    /// estimate, so the content must be exactly the file from the admitted frame.
    private func expectAdmission(_ decoder: NativeMP3SourceDecoder, marker: Marker, target: CMTime, baseline: [Int16],
                                 path: String, exactGrid: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let rate = Int32(marker.sampleRate), channels = marker.channels
        let samples: [Int16]
        do { samples = try await drain(decoder) } catch { await decoder.cancel(); throw error }
        await decoder.cancel()
        let wanted = CMTimeConvertScale(target, timescale: rate, method: .roundAwayFromZero).value
        let expected = marker.admitted(target)
        if expected >= marker.validFrames {
            #expect(samples.isEmpty, "\(marker.name) \(path) target \(wanted): audio after the end", sourceLocation: sourceLocation)
            return
        }
        let start = CMTimeConvertScale(decoder.startTime, timescale: rate, method: .roundTowardZero).value
        let admission = start - wanted
        #expect(decoder.startTime == CMTime(value: start, timescale: rate) || !exactGrid, sourceLocation: sourceLocation)
        #expect(admission >= 0 && admission < marker.framesPerPacket,
                "\(marker.name) \(path) target \(wanted): admitted at \(start), \(admission) frames late", sourceLocation: sourceLocation)
        if exactGrid {
            #expect(start == expected, "\(marker.name) \(path) target \(wanted): admitted \(start), expected \(expected)", sourceLocation: sourceLocation)
        }
        let heard = PCMLocator.locate(samples, in: baseline, channels: channels, around: Int(start), radius: Int(rate) / 4)
        let content = Int64(heard.offset) - wanted
        print("MP3_ADMISSION \(marker.name) \(path) target=\(wanted) admitted=\(start) admissionError=\(admission) "
              + "heardAt=\(heard.offset) contentError=\(content) frames (\(Double(content) * 1000 / Double(rate)) ms) residual=\(heard.residual)")
        if exactGrid {
            // Nothing estimated on this path: the heard audio is the file from the admitted frame.
            #expect(heard.offset == Int(start) && heard.residual < 0.001,
                    "\(marker.name) \(path) target \(wanted): heard from \(heard.offset), admitted \(start)", sourceLocation: sourceLocation)
            let reference = Array(baseline.dropFirst(Int(start) * channels))
            #expect(AudibleMatch.matches(samples, reference, channels: channels, sampleRate: Int(rate), lengthTolerance: 0),
                    "\(marker.name) \(path) target \(wanted): the rest of the episode differs", sourceLocation: sourceLocation)
        } else {
            // The map's estimate error is separate and unchanged; still within a quarter second, as before.
            #expect(abs(content) <= Int64(rate) / 4 && heard.residual < 0.05,
                    "\(marker.name) \(path) target \(wanted): heard from \(heard.offset)", sourceLocation: sourceLocation)
        }
    }
}

/// Finds where decoded audio occurs in a reference decode by least squares.
enum PCMLocator {
    /// Squared difference from the reference at `offset`, relative to the audio's energy.
    static func residual(_ samples: [Int16], in reference: [Int16], channels: Int, at offset: Int, frames: Int = 1024) -> Double {
        let length = min(frames, samples.count / channels) * channels
        let begin = offset * channels
        guard length > 0, begin >= 0, begin + length <= reference.count else { return .infinity }
        let probe = samples.prefix(length).map(Float.init)
        let energy = Double(vDSP.sumOfSquares(probe))
        let distance = Double(vDSP.distanceSquared(probe, reference[begin..<(begin + length)].map(Float.init)))
        return energy > 0 ? distance / energy : distance
    }

    static func locate(_ samples: [Int16], in reference: [Int16], channels: Int, around expected: Int, radius: Int,
                       frames: Int = 1024) -> (offset: Int, residual: Double) {
        let length = min(frames, samples.count / channels) * channels
        guard length > 0 else { return (-1, .infinity) }
        let probe = samples.prefix(length).map(Float.init)
        let energy = Double(vDSP.sumOfSquares(probe))
        let haystack = reference.map(Float.init)
        var best = (offset: -1, residual: Double.infinity)
        for offset in max(0, expected - radius)...max(0, expected + radius) {
            let begin = offset * channels
            guard begin + length <= haystack.count else { break }
            let distance = Double(vDSP.distanceSquared(probe, haystack[begin..<(begin + length)]))
            let residual = energy > 0 ? distance / energy : distance
            if residual < best.residual { best = (offset, residual) }
        }
        return best
    }
}
private final class MP3SeekMarkerFixtures: NSObject {}

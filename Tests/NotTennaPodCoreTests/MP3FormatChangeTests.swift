import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// MP3s whose sample rate or channel count changes mid-file, as when an ad encoded
/// differently is spliced into a show. Every segment must play completely, at the
/// right pitch and length, in the format of the stream's first frame (mono shows
/// stay mono, stereo shows stereo), with positions and seeks right before, inside
/// and after each change. Expectations come from the fixture bytes and the test's
/// own decoder, never from the production parser or decoder.
@Suite(.serialized, .timeLimit(.minutes(5))) struct MP3FormatChangeTests {
    struct Segment: Decodable, Sendable {
        let byteOffset: Int
        let byteCount: Int
        let sampleRate: Int
        let channels: Int
        let tonesHz: [Double]
        let mpegFrames: Int
        let framesPerPacket: Int
        let markersSeconds: [Double]?
        var samples: Int { mpegFrames * framesPerPacket }
    }
    struct Media: Decodable, Sendable {
        let name: String
        let segments: [Segment]
        var rate: Int { segments[0].sampleRate }
        var channels: Int { segments[0].channels }
        var origins: [Int] { MP3FormatChangeTests.origins(segments.map { ($0.sampleRate, $0.samples) }, rate: rate) }
        /// The longest MPEG frame in output frames: a seek may start up to this late.
        var longestFrame: Int { segments.map { ($0.framesPerPacket * rate + $0.sampleRate - 1) / $0.sampleRate }.max()! + 1 }
    }
    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    /// Output frame where each run of (rate, samples) starts (round half up of its exact
    /// source time at the first rate), and where the audio ends. No file has encoder delay.
    static func origins(_ runs: [(rate: Int, samples: Int)], rate: Int) -> [Int] {
        var numerator = 0, denominator = 1, result: [Int] = []
        for run in runs + [(rate, 0)] {
            result.append((2 * numerator * rate + denominator) / (2 * denominator))
            // Time so far, as an exact fraction of seconds.
            let common = denominator / gcd(denominator, run.rate) * run.rate
            numerator = numerator * (common / denominator) + run.samples * (common / run.rate)
            denominator = common
        }
        return result
    }

    static let media: [Media] = {
        struct Manifest: Decodable { let files: [Media] }
        guard let url = fixtureURL("manifest.json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode(Manifest.self, from: data).files) ?? []
    }()
    static let names = ["dai_mono.mp3", "dai_48k.mp3", "dai_monoshow_stereoad.mp3", "stereo-mono-stereo.mp3",
                        "mono-stereo-mono.mp3", "low-high-low.mp3", "high-low-high.mp3", "converted-chain.mp3"]
    static let limit = NativeMP3PCMDecoder.joinRoundingLimit

    static func fixtureURL(_ name: String) -> URL? {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/MP3FormatChanges")
#else
        Bundle(for: MP3FormatChangeFixtures.self).url(forResource: name, withExtension: nil, subdirectory: "MP3FormatChanges")
#endif
    }
    private func media(_ name: String) throws -> (Media, URL, Data) {
        let media = try #require(Self.media.first { $0.name == name })
        let url = try #require(Self.fixtureURL(name))
        let data = try Data(contentsOf: url)
        try #require(media.segments.last.map { $0.byteOffset + $0.byteCount } == data.count)
        return (media, url, data)
    }

    // MARK: - Every frame reaches the decoder, in batches of one format

    @Test(arguments: names, [7, 1000, 4096])
    func parserKeepsEveryFrameAndSplitsAtEachChange(name: String, chunk: Int) throws {
        let (media, _, data) = try media(name)
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        var batches: [NativeMP3PacketParser.Batch] = []
        for offset in stride(from: 0, to: data.count, by: chunk) {
            batches += try parser.append(data.subdata(in: offset..<min(offset + chunk, data.count)))
        }
        batches += try parser.finish()
        // The frame each packet should be, and its exact time, from the fixture's segments.
        var expected: [(segment: Int, time: CMTime)] = []
        var time = CMTime.zero
        for (index, segment) in media.segments.enumerated() {
            for _ in 0..<segment.mpegFrames {
                expected.append((index, time))
                time = time + CMTime(value: Int64(segment.framesPerPacket), timescale: Int32(segment.sampleRate))
            }
        }
        var payload = Data(), packet = 0
        for batch in batches {
            let format = try #require(batch.format.audioStreamBasicDescription)
            try #require(packet < expected.count, "\(name): more packets than frames")
            let segment = media.segments[expected[packet].segment]
            // One configuration per batch, the frames' own; the stream keeps the first frame's timing.
            #expect(Int(format.mSampleRate) == segment.sampleRate && Int(format.mChannelsPerFrame) == segment.channels
                && Int(format.mFramesPerPacket) == segment.framesPerPacket, "\(name) packet \(packet): batch format")
            #expect(batch.timing.sampleRate == Int32(media.rate) && batch.timing.channels == media.channels)
            #expect(batch.startTime == expected[packet].time, "\(name) packet \(packet): \(batch.startTime.seconds) s")
            let first = packet
            for description in batch.descriptions {
                let start = Int(description.mStartOffset)
                payload.append(batch.bytes.subdata(in: start..<(start + Int(description.mDataByteSize))))
                packet += 1
            }
            #expect(packet <= expected.count && expected[packet - 1].segment == expected[first].segment,
                    "\(name) packet \(first): a batch spans a format change")
        }
        // Every frame, once, in order: nothing skipped at a change of rate.
        #expect(packet == expected.count && payload == data, "\(name): \(packet) packets for \(expected.count) frames")
    }

    // MARK: - Every segment complete, at the right pitch and length

    @Test(arguments: names)
    func everySegmentPlaysCompletelyInTheStreamsFormat(name: String) async throws {
        let (media, url, data) = try media(name)
        MP3SegmentJoinDiagnostics.reset()
        defer { expectJoinsWithinRounding(name) }
        let source = NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url))
        let decoder = try await source.makeDecoder(prepareSourceTimeline: true)
        #expect(decoder.sampleRate == media.rate && decoder.channels == media.channels && decoder.startTime == .zero)
        let output = try await drain(decoder)
        await decoder.cancel()
        let origins = media.origins
        #expect(output.count == origins.last! * media.channels,
                "\(name): \(output.count / media.channels) frames, expected \(origins.last!)")
        for (index, segment) in media.segments.enumerated() {
            let range = (origins[index] * media.channels)..<(min(origins[index + 1] * media.channels, output.count))
            let heard = Array(output[range])
            let reference = try decodeAlone(data, segment)
            #expect(reference.count == segment.samples * segment.channels)
            let label = "\(name) segment \(index) (\(segment.sampleRate) Hz, \(segment.channels) ch)"
            if segment.sampleRate == media.rate {
                // Same rate: exactly the segment decoded on its own, its channels mixed or copied.
                // Any lost or repeated frame at a join would shift the next segment and fail here.
                #expect(heard == mixed(reference, from: segment.channels, to: media.channels), "\(label) differs")
            } else {
                // Converted rate: the length the timeline gives it (checked above), and the same
                // sound as an independent whole-segment conversion, which is not fitted: the two
                // may differ in length only by the join rounding.
                let expected = try resampled(mixed(reference, from: segment.channels, to: media.channels),
                    channels: media.channels, from: segment.sampleRate, to: media.rate)
                #expect(abs(heard.count - expected.count) <= Int(Self.limit) * media.channels, "\(label): \(heard.count) vs \(expected.count)")
                #expect(AudibleMatch.matches(heard, expected, channels: media.channels, sampleRate: media.rate,
                    lengthTolerance: Double(Self.limit) / Double(media.rate) + 1e-9), "\(label) differs from an independent conversion")
            }
            // Each channel carries its segment's tones at their own pitch, mixed or copied.
            for channel in 0..<media.channels where !segment.tonesHz.isEmpty {
                let tones = media.channels == segment.channels ? [segment.tonesHz[channel]] : Array(Set(segment.tonesHz))
                for tone in tones {
                    let wrong = tone * Double(segment.sampleRate) / Double(media.rate)
                    let at = power(heard, channel: channel, channels: media.channels, rate: media.rate, hz: tone)
                    let off = segment.sampleRate == media.rate ? power(heard, channel: channel, channels: media.channels,
                        rate: media.rate, hz: tone * 1.5) : power(heard, channel: channel, channels: media.channels, rate: media.rate, hz: wrong)
                    #expect(at > 100 * off, "\(label) channel \(channel): \(tone) Hz not at its pitch (\(at) vs \(off))")
                }
            }
            if segment.channels == 1, media.channels == 2 {
                #expect(stride(from: 0, to: heard.count, by: 2).allSatisfy { heard[$0] == heard[$0 + 1] }, "\(label) not copied to both channels")
            }
        }
    }

    // MARK: - Positions and seeks before, inside and after each change

    @Test(arguments: names)
    func seeksAroundEachChangeLandOnTheContinuousTimeline(name: String) async throws {
        let (media, url, _) = try media(name)
        MP3SegmentJoinDiagnostics.reset()
        defer { expectJoinsWithinRounding(name) }
        let source = NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url))
        let initial = try await source.makeDecoder(prepareSourceTimeline: true)
        let baseline = try await drain(initial)
        await initial.cancel()
        for target in targets(media) {
            // Retained: the loaded episode; cold: a new item restored at a saved position.
            for cold in [false, true] {
                let item = cold ? NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url)) : source
                let decoder = try await item.makeDecoder(start: target, prepareSourceTimeline: true)
                try await expectSeek(decoder, media, target: target, baseline: baseline, path: cold ? "cold" : "retained")
            }
        }
    }

    @Test(arguments: names)
    func fragmentedStreamPlaysTheSameAudioAndSeeks(name: String) async throws {
        let (media, url, data) = try media(name)
        MP3SegmentJoinDiagnostics.reset()
        defer { expectJoinsWithinRounding(name) }
        let local = NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url))
        let whole = try await local.makeDecoder(prepareSourceTimeline: true)
        let reference = try await drain(whole)
        await whole.cancel()
        // The body arrives in uneven pieces after a short first read.
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(data.count)"],
                  body: Data(data.prefix(1000)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-format-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy(), cache: try SharedStreamingCache(directory: directory))
        let opening = Task { try await source.makeDecoder(prepareSourceTimeline: true) }
        let sizes = [1, 7, 333, 4096, 2, 1500, 9000, 31, 640]
        var offset = 1000, piece = 0
        let deadline = ContinuousClock.now + .seconds(10)
        while server.sentResponseCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        try #require(server.sentResponseCount == 1)
        while offset < data.count {
            let end = min(data.count, offset + sizes[piece % sizes.count])
            try await server.appendResponseBody(data.subdata(in: offset..<end), isFinal: end == data.count)
            offset = end; piece += 1
        }
        let decoder = try await opening.value
        let streamed = try await drain(decoder)
        await decoder.cancel()
        #expect(streamed == reference, "\(name): streamed audio differs from the downloaded file")
        // Seeks within the loaded stream.
        for target in targets(media).prefix(6) {
            let seeked = try await source.makeDecoder(start: target, prepareSourceTimeline: true)
            try await expectSeek(seeked, media, target: target, baseline: reference, path: "streamed")
        }
    }

    /// One fresh item per target, its first response held after a third of the show, so the
    /// seek must load its own range through the first frame's seek map.
    @Test(arguments: ["dai_mono.mp3", "dai_48k.mp3", "dai_monoshow_stereoad.mp3", "low-high-low.mp3", "high-low-high.mp3",
                      "converted-chain.mp3"])
    func streamedSeekOutsideLoadedAudioLoadsItsOwnRange(name: String) async throws {
        let (media, url, data) = try media(name)
        let local = NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url))
        let whole = try await local.makeDecoder(prepareSourceTimeline: true)
        let baseline = try await drain(whole)
        // The duration the first frame's map gives: a person cannot seek beyond it.
        let duration = try #require(whole.sourceDurationMilliseconds)
        await whole.cancel()
        let origins = media.origins
        let prefix = media.segments[0].byteOffset + media.segments[0].byteCount / 3
        // Inside the first changed segment, and after it (where the show resumes).
        for frame in [origins[1] + (origins[2] - origins[1]) / 2, origins[2] + (origins[3] - origins[2]) / 2]
            .map({ min($0, Int(duration) * media.rate / 1000 - media.rate / 5) }) {
            try await seekFreshStream(data, media, baseline: baseline, prefix: prefix,
                target: CMTime(value: Int64(frame), timescale: Int32(media.rate)), label: "\(name) target \(frame)")
        }
    }

    /// A long spliced stream restored at a saved position beyond the first MiB: the first
    /// seek itself takes the indexed path and downloads only part of the file.
    @Test func longSplicedStreamColdSeekUsesTheIndex() async throws {
        let (media, _, data) = try media("dai_48k.mp3")
        let show = media.segments[0], ad = media.segments[1], rest = media.segments[2]
        var long = Data()
        for _ in 0..<8 { long.append(data.subdata(in: show.byteOffset..<(show.byteOffset + show.byteCount))) }
        long.append(data.subdata(in: ad.byteOffset..<(ad.byteOffset + ad.byteCount)))
        long.append(data.subdata(in: rest.byteOffset..<(rest.byteOffset + rest.byteCount)))
        let runs = Array(repeating: (show.sampleRate, show.samples), count: 8) + [(ad.sampleRate, ad.samples), (rest.sampleRate, rest.samples)]
        let origins = Self.origins(runs, rate: media.rate)
        let file = URL.temporaryDirectory.appendingPathComponent("long-splice-\(UUID()).mp3")
        try long.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let local = NativeMP3PlaybackSource(localURL: file, file: try LocalAudioBytes(url: file))
        let whole = try await local.makeDecoder(prepareSourceTimeline: true)
        let baseline = try await drain(whole)
        await whole.cancel()
        #expect(baseline.count == origins.last! * media.channels)
        try #require(long.count > 1_300_000)
        for frame in [origins[8] + (origins[9] - origins[8]) / 2, origins[9] + (origins[10] - origins[9]) / 2] {
            try await seekFreshStream(long, media, baseline: baseline, prefix: 8192, coldStart: true,
                target: CMTime(value: Int64(frame), timescale: Int32(media.rate)), label: "long target \(frame)")
        }
    }

    /// Seeks a fresh streamed item whose first response stops after `prefix` bytes, and checks
    /// the range it loads and where the heard audio really is: the complete tail to the end
    /// (no seek-map label involved), which repeating tones cannot imitate.
    private func seekFreshStream(_ data: Data, _ media: Media, baseline: [Int16], prefix: Int, coldStart: Bool = false,
                                 target: CMTime, label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"splice\"",
                    "Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"], body: data.subdata(in: start..<data.count))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"splice\"", "Content-Length": "\(data.count)"],
                body: Data(data.prefix(prefix)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-format-range-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy(), cache: try SharedStreamingCache(directory: directory))
        if !coldStart {
            // Opens the item from its start, as playback does before a seek.
            await (try await source.makeDecoder(prepareSourceTimeline: true)).cancel()
        }
        let ranges = server.requests.filter { $0.headers["range"] != nil }.count
        let decoder = try await source.makeDecoder(start: target, prepareSourceTimeline: true)
        let samples: [Int16]
        do { samples = try await drain(decoder) } catch { await decoder.cancel(); throw error }
        await decoder.cancel()
        let rate = Int32(media.rate), channels = media.channels
        let wanted = CMTimeConvertScale(target, timescale: rate, method: .roundAwayFromZero).value
        let start = CMTimeConvertScale(decoder.startTime, timescale: rate, method: .roundTowardZero).value
        // This target loaded its own range, beyond what the first response delivered.
        let loads = server.requests.filter { $0.headers["range"] != nil }
        let offsets = loads.compactMap { Int($0.headers["range"]!.dropFirst(6).dropLast()) }
        #expect(loads.count > ranges && offsets.last.map { $0 > prefix } == true, "\(label): no range load (\(offsets))",
                sourceLocation: sourceLocation)
        if coldStart {
            let received = try #require(await source.networkSnapshot).received
            #expect(received < Int64(data.count / 2), "\(label): downloaded \(received) of \(data.count) bytes", sourceLocation: sourceLocation)
        }
        // Admission is exact against the map's own label.
        #expect(start >= wanted && start - wanted < Int64(media.longestFrame), "\(label): admitted \(start)", sourceLocation: sourceLocation)
        // Where the audio really starts: it runs to the end, so its length says where.
        let heard = baseline.count / channels - samples.count / channels
        #expect(!samples.isEmpty && AudibleMatch.matches(samples, Array(baseline.suffix(samples.count)), channels: channels,
                sampleRate: media.rate), "\(label): the heard audio is not the file's tail", sourceLocation: sourceLocation)
        // The first frame's bitrate map is as approximate in later segments as their bitrate
        // and rate make it. The Android comparison of these files has not been run.
        print("MP3_FORMAT_RANGE \(label) admitted=\(start) heardFrom=\(heard) "
              + "labelError=\(Double(start - wanted) / Double(rate)) s contentError=\(Double(heard - Int(wanted)) / Double(rate)) s")
    }

    // MARK: - One frame at another rate

    /// A complete single frame at another rate, last in the stream or between two runs of
    /// the first rate, survives every way the reads can split its headers and boundaries.
    @Test(arguments: ["final", "isolated"])
    func singleFrameAtAnotherRateIsKept(placement: String) async throws {
        let (media, _, source) = try media("high-low-high.mp3")
        let first = media.segments[0], other = media.segments[1], last = media.segments[2]
        let frameSize = try #require(MP3FrameHeader(source[other.byteOffset..<(other.byteOffset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })).byteCount
        var data = source.subdata(in: first.byteOffset..<(first.byteOffset + first.byteCount))
        let changeAt = data.count
        data.append(source.subdata(in: other.byteOffset..<(other.byteOffset + frameSize)))
        let backAt = data.count
        var runs = [(first.sampleRate, first.samples), (other.sampleRate, other.framesPerPacket)]
        var frames = first.mpegFrames + 1
        if placement == "isolated" {
            data.append(source.subdata(in: last.byteOffset..<(last.byteOffset + last.byteCount)))
            runs.append((last.sampleRate, last.samples)); frames += last.mpegFrames
        }
        // Reads end at, and one to three bytes either side of, every header and boundary of the frame.
        var splits: [[Int]] = [[7], [4096], [32_768]].map { chunk in Array(stride(from: chunk[0], to: data.count, by: chunk[0])) }
        for boundary in [changeAt, backAt] { for delta in -3...3 where boundary + delta < data.count { splits.append([boundary + delta]) } }
        for cuts in splits {
            let parser = try NativeMP3PacketParser()
            defer { parser.close() }
            var batches: [NativeMP3PacketParser.Batch] = [], offset = 0
            for cut in cuts + [data.count] where cut > offset {
                while offset < cut {
                    let end = min(cut, offset + 32_768)
                    batches += try parser.append(data.subdata(in: offset..<end)); offset = end
                }
            }
            batches += try parser.finish()
            let packets = batches.reduce(0) { $0 + $1.descriptions.count }
            let changed = batches.filter { $0.sampleRate == Int32(other.sampleRate) }
            #expect(packets == frames && changed.reduce(0) { $0 + $1.descriptions.count } == 1,
                    "\(placement), reads split at \(cuts.prefix(2))…: \(packets) packets, \(changed.count) at \(other.sampleRate) Hz")
            #expect(changed.first.map { $0.startTime == CMTime(value: Int64(first.samples), timescale: Int32(first.sampleRate)) } == true)
        }
        // Played: every frame, and the timeline continues after it.
        let url = URL.temporaryDirectory.appendingPathComponent("single-frame-\(UUID()).mp3")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url))
        let decoder = try await item.makeDecoder(prepareSourceTimeline: true)
        let output = try await drain(decoder)
        await decoder.cancel()
        #expect(output.count == Self.origins(runs, rate: media.rate).last! * media.channels, "\(placement): \(output.count / media.channels) frames")
    }

    // MARK: - Joins: corrections and markers

    /// Converted segments one after another, decoded from the start and from inside each
    /// converted segment (fractional origins, as seeks start): every converter output is
    /// fitted by at most the rounding limit, and every segment's markers, including those
    /// in its last moments, are where its own decode puts them on the stream's timeline.
    @Test(arguments: ["converted-chain.mp3", "dai_48k.mp3", "low-high-low.mp3", "high-low-high.mp3"])
    func convertedSegmentsAreFittedWithinRoundingAndKeepTheirPositions(name: String) throws {
        let (media, _, data) = try media(name)
        let origins = media.origins
        let packets = try packetsOf(data)
        let converted = media.segments.indices.filter { media.segments[$0].sampleRate != media.rate }
        // Packet index of each segment's first frame.
        let firstPackets = media.segments.indices.map { index in media.segments.prefix(index).reduce(0) { $0 + $1.mpegFrames } }
        var starts = [0]
        for index in converted where media.segments[index].mpegFrames > 6 { starts.append(firstPackets[index] + 3) }
        for startPacket in starts {
            let (output, origin, corrections) = try decode(packets, from: startPacket)
            let label = "\(name) from packet \(startPacket) (origin \(origin))"
            let expectedJoins = converted.filter { firstPackets[$0] + media.segments[$0].mpegFrames > startPacket }.count
            #expect(corrections.count == expectedJoins && corrections.allSatisfy { abs($0) <= Self.limit },
                    "\(label): corrections \(corrections)")
            print("MP3_FORMAT_JOINS \(label) corrections=\(corrections)")
            // Total length: to the timeline's end, from this decoder's own origin.
            #expect(output.count / media.channels == origins.last! - origin, "\(label): \(output.count / media.channels) frames")
            for (index, segment) in media.segments.enumerated() where !(segment.markersSeconds ?? []).isEmpty {
                let reference = mixed(try decodeAlone(data, segment), from: segment.channels, to: 1)
                for seconds in segment.markersSeconds ?? [] {
                    // Native position from the segment decoded alone, mapped to the stream's rate.
                    let native = try #require(centroid(reference, channels: 1, near: Int(seconds * Double(segment.sampleRate)),
                        searching: segment.sampleRate / 10, rate: segment.sampleRate))
                    let expected = Double(origins[index]) + native * Double(media.rate) / Double(segment.sampleRate) - Double(origin)
                    // Decoding started mid-segment without preroll: its first frames lack history.
                    guard expected > 0.1 * Double(media.rate) else { continue }
                    let measured = try #require(centroid(mixed(output, from: media.channels, to: 1), channels: 1,
                        near: Int(expected), searching: media.rate / 200, rate: media.rate))
                    // A lost, repeated or delayed frame or converter latency moves a marker by many
                    // frames; measuring a burst's centre at two rates agrees within two.
                    print("MP3_FORMAT_MARKER \(label) segment \(index) at \(seconds) s: offset \(measured - expected)")
                    #expect(abs(measured - expected) <= 2, "\(label) segment \(index) marker \(seconds) s: at \(measured), expected \(expected)")
                }
            }
        }
    }

    /// A converter returning more or fewer frames than rounding explains is not concealed:
    /// every returned frame is kept, none is added, it is recorded as an anomaly, and the
    /// following segments move by exactly the difference with their content intact.
    @Test(arguments: [Int64(7), -7])
    func converterAnomalyIsKeptAndCarriedForward(adjustment: Int64) throws {
        let (media, _, data) = try media("converted-chain.mp3")
        let packets = try packetsOf(data)
        let (normal, _, normalJoins) = try decode(packets, from: 0)
        MP3SegmentJoinDiagnostics.reset()
        let (output, _, joins) = try decode(packets, from: 0, converterOutputAdjustment: adjustment)
        let converted = media.segments.filter { $0.sampleRate != media.rate }.count
        // Each converted segment is off its length by the adjustment beyond its ordinary rounding.
        #expect(joins == normalJoins.map { $0 - adjustment }, "differences \(joins), ordinarily \(normalJoins)")
        #expect(MP3SegmentJoinDiagnostics.current.anomalies == converted)
        // Kept as returned: the output is longer (or shorter) by exactly what the converters returned.
        let origins = media.origins
        #expect(output.count / media.channels == origins.last! - Int(joins.reduce(0, +)), "\(output.count / media.channels) frames")
        #expect(normal.count / media.channels == origins.last!)
        // Every later segment moves by the accumulated difference, its audio intact: the last
        // (native) segment exactly, the converted ones at their markers.
        var shift = 0, converterIndex = 0
        for (index, segment) in media.segments.enumerated() {
            let start = origins[index] + shift
            if segment.sampleRate == media.rate {
                let reference = mixed(try decodeAlone(data, segment), from: segment.channels, to: media.channels)
                let heard = Array(output[(start * media.channels)..<min(output.count, (start + segment.samples) * media.channels)])
                #expect(heard == reference, "segment \(index) is not intact at \(start)")
            } else {
                let reference = mixed(try decodeAlone(data, segment), from: segment.channels, to: 1)
                for seconds in segment.markersSeconds ?? [] {
                    let native = try #require(centroid(reference, channels: 1, near: Int(seconds * Double(segment.sampleRate)),
                        searching: segment.sampleRate / 10, rate: segment.sampleRate))
                    let expected = Double(start) + native * Double(media.rate) / Double(segment.sampleRate)
                    let measured = try #require(centroid(mixed(output, from: media.channels, to: 1), channels: 1,
                        near: Int(expected), searching: media.rate / 200, rate: media.rate))
                    #expect(abs(measured - expected) <= 2, "segment \(index) marker \(seconds) s at \(measured), expected \(expected)")
                }
                shift -= Int(joins[converterIndex]); converterIndex += 1
            }
        }
    }

    // MARK: - A last frame before an ID3v1 tag

    /// The first segment of high-low-high.mp3, then one complete 16 kHz frame, then `tail`.
    private func lastFrameFixture(_ tail: Data, frameBytes: Int? = nil, junk: Int = 0) throws -> (data: Data, first: Segment, frameAt: Int) {
        let (media, _, source) = try media("high-low-high.mp3")
        let first = media.segments[0], other = media.segments[1]
        let word = source[other.byteOffset..<(other.byteOffset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let size = try #require(MP3FrameHeader(word)).byteCount
        var data = source.subdata(in: first.byteOffset..<(first.byteOffset + first.byteCount))
        data.append(Data(repeating: 0x55, count: junk))
        let frameAt = data.count
        data.append(source.subdata(in: other.byteOffset..<(other.byteOffset + (frameBytes ?? size))))
        data.append(tail)
        return (data, first, frameAt)
    }
    private static let id3v1 = Data("TAG".utf8) + Data(repeating: 0, count: 125)

    /// A complete last frame at another rate before a 128-byte ID3v1 tag is kept at every read
    /// size and split, as without the tag.
    @Test func lastFrameBeforeAnID3v1TagIsKept() throws {
        let (data, first, frameAt) = try lastFrameFixture(Self.id3v1)
        let frameEnd = data.count - 128
        var splits: [[Int]] = [7, 4096, 32_768].map { Array(stride(from: $0, to: data.count, by: $0)) }
        for boundary in [frameAt, frameEnd] { for delta in -3...3 { splits.append([boundary + delta]) } }
        for inside in [1, 2, 3, 64, 127] { splits.append([frameEnd + inside]) }
        for cuts in splits {
            let batches = try parse(data, cuts: cuts)
            let packets = batches.reduce(0) { $0 + $1.descriptions.count }
            let changed = batches.filter { $0.sampleRate == 16000 }
            #expect(packets == first.mpegFrames + 1 && changed.reduce(0) { $0 + $1.descriptions.count } == 1,
                    "reads split at \(cuts.prefix(2))…: \(packets) packets, \(changed.count) batches at 16 kHz")
            #expect(changed.first?.startTime == CMTime(value: Int64(first.samples), timescale: Int32(first.sampleRate)))
        }
        // The tracker's own decision, at the real end.
        var tracker = MP3RateTracker()
        _ = tracker.scan(data)
        #expect(tracker.change(atEndOf: data) == frameAt)
    }

    /// What is not a real trailing ID3v1 tag, or a frame that is incomplete or found while
    /// resynchronizing, is not taken as a change of rate at the end; the first rate's frames
    /// are all kept and nothing is given a wrong format.
    @Test(arguments: ["longer", "shorter", "incomplete frame", "after junk"])
    func lastFrameIsNotConfirmedByATagLikeRun(variant: String) throws {
        let fixture: (data: Data, first: Segment, frameAt: Int)
        switch variant {
        case "longer": fixture = try lastFrameFixture(Self.id3v1 + Data([0]))
        case "shorter": fixture = try lastFrameFixture(Data("TAG".utf8) + Data(repeating: 0, count: 60))
        case "incomplete frame": fixture = try lastFrameFixture(Self.id3v1, frameBytes: 100)
        default: fixture = try lastFrameFixture(Self.id3v1, junk: 37)
        }
        var tracker = MP3RateTracker()
        let scan = tracker.scan(fixture.data)
        #expect(scan.change == nil && tracker.change(atEndOf: fixture.data) == nil, "\(variant): taken as a change")
        for chunk in [7, 4096, 32_768] {
            let batches = try parse(fixture.data, cuts: Array(stride(from: chunk, to: fixture.data.count, by: chunk)))
            let firstRate = batches.filter { $0.sampleRate == Int32(fixture.first.sampleRate) }
            #expect(firstRate.reduce(0) { $0 + $1.descriptions.count } == fixture.first.mpegFrames, "\(variant), \(chunk)-byte reads")
            for batch in batches {
                for description in batch.descriptions {
                    let start = Int(description.mStartOffset)
                    let word = batch.bytes[start..<(start + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    #expect(MP3FrameHeader(word).map { $0.configuration.sampleRate == batch.sampleRate } == true,
                            "\(variant), \(chunk)-byte reads: a packet in the wrong format")
                }
            }
        }
    }

    private func parse(_ data: Data, cuts: [Int]) throws -> [NativeMP3PacketParser.Batch] {
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        var batches: [NativeMP3PacketParser.Batch] = [], offset = 0
        for cut in cuts + [data.count] where cut > offset {
            while offset < cut {
                let end = min(cut, offset + 32_768)
                batches += try parser.append(data.subdata(in: offset..<end)); offset = end
            }
        }
        return batches + (try parser.finish())
    }

    /// Every packet of the file in its own batch, as the producer's queue hands them out.
    private func packetsOf(_ data: Data) throws -> [NativeMP3PacketParser.Batch] {
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        var batches: [NativeMP3PacketParser.Batch] = []
        for offset in stride(from: 0, to: data.count, by: 4096) {
            batches += try parser.append(data.subdata(in: offset..<min(offset + 4096, data.count)))
        }
        batches += try parser.finish()
        return batches.flatMap { batch in
            var time = batch.startTime
            return batch.descriptions.enumerated().map { index, description in
                let start = Int(description.mStartOffset), end = start + Int(description.mDataByteSize)
                var single = description; single.mStartOffset = 0
                let frames = Int64(batch.format.audioStreamBasicDescription!.mFramesPerPacket)
                defer { time = time + CMTime(value: frames, timescale: batch.sampleRate) }
                return NativeMP3PacketParser.Batch(bytes: batch.bytes.subdata(in: start..<end), descriptions: [single],
                    format: batch.format, firstFrame: batch.firstFrame + Int64(index) * frames, frameCount: frames,
                    timing: batch.timing, rollDistances: batch.rollDistances.map { [$0[index]] }, sourceTime: time,
                    afterFormatChange: batch.afterFormatChange)
            }
        }
    }

    /// Decodes from `first` to the end; returns the output, this decoder's output origin
    /// (its first frame on the stream's timeline) and its join corrections.
    private func decode(_ packets: [NativeMP3PacketParser.Batch], from first: Int,
                        converterOutputAdjustment: Int64 = 0) throws -> ([Int16], Int, [Int64]) {
        let batch = packets[first]
        let decoder = try NativeMP3PCMDecoder(format: batch.format, timing: batch.timing, firstFrame: batch.firstFrame,
            sourceTime: batch.sourceTime, afterFormatChange: batch.afterFormatChange,
            converterOutputAdjustment: converterOutputAdjustment)
        defer { decoder.close() }
        var output: [Int16] = [], origin: Int?
        func drain() throws {
            while true {
                switch try decoder.next() {
                case .audio(let packet):
                    let time = Int(CMTimeConvertScale(packet.presentationTime, timescale: batch.timing.sampleRate, method: .roundTowardZero).value)
                    if origin == nil { origin = time }
                    // One continuous timeline: no gap or overlap between packets.
                    #expect(time == origin! + output.count / batch.timing.channels)
                    output += packet.samples
                case .needsInput, .ended: return
                }
            }
        }
        for packet in packets[first...] { try decoder.accept(packet); try drain() }
        try decoder.finish(); try drain()
        return (output, try #require(origin), decoder.joinCorrections)
    }

    /// Energy centroid of the loudest burst within `searching` frames after `near`, in frames.
    private func centroid(_ samples: [Int16], channels: Int, near: Int, searching: Int, rate: Int) -> Double? {
        let frames = samples.count / channels
        let lower = max(0, near - searching / 4), upper = min(frames, near + searching)
        guard lower < upper else { return nil }
        let peak = (lower..<upper).max { abs(Int(samples[$0 * channels])) < abs(Int(samples[$1 * channels])) }!
        let half = rate / 250
        var weight = 0.0, sum = 0.0
        for frame in max(0, peak - half)..<min(frames, peak + half) {
            let energy = Double(samples[frame * channels]) * Double(samples[frame * channels])
            weight += energy; sum += energy * Double(frame)
        }
        return weight > 0 ? sum / weight : nil
    }

    // MARK: - Declared timing after a change

    /// A stereo show with a mono ad at the same rate, under a stale Xing/LAME header that
    /// declares only the show's first part. Seeking into the final stereo part must not
    /// apply that declaration (which ends before it) and plays to the end.
    @Test func declaredTimingStopsApplyingAfterAChannelRoundTrip() async throws {
        let (media, _, body) = try media("stereo-mono-stereo.mp3")
        let marker = try Data(contentsOf: try #require(MP3SeekAdmissionTests.fixtureURL("marker-44k-stereo-vbr.mp3")))
        let tag = marker.starts(with: Data("ID3".utf8)) ? 10 + marker[6..<10].reduce(0) { ($0 << 7) | Int($1) } : 0
        let headerSize = try #require(MP3FrameHeader(marker[tag..<(tag + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })).byteCount
        var header = Data(marker[tag..<(tag + headerSize)])
        // The Xing frame count (after "Xing" and its flags) declares the first segment only.
        let xing = try #require(header.range(of: Data("Xing".utf8))).lowerBound
        let count = UInt32(media.segments[0].mpegFrames)
        header.replaceSubrange((xing + 8)..<(xing + 12), with: [UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        let url = URL.temporaryDirectory.appendingPathComponent("stale-header-\(UUID()).mp3")
        try (header + body).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url))
        let whole = try await source.makeDecoder(prepareSourceTimeline: true)
        #expect(whole.timing.encodedFrameCount == Int64(media.segments[0].samples))
        let baseline = try await drain(whole)
        await whole.cancel()
        let delay = Int(whole.timing.primingFrameCount ?? 0)
        let origins = media.origins
        // Retained and restored seeks into the final stereo segment.
        for target in [origins[2] + 1234 - delay, (origins[2] + origins[3]) / 2 - delay] {
            for fresh in [false, true] {
                let item = fresh ? NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url)) : source
                let decoder = try await item.makeDecoder(start: CMTime(value: Int64(target), timescale: Int32(media.rate)),
                    prepareSourceTimeline: true)
                let samples: [Int16]
                do { samples = try await drain(decoder) } catch { await decoder.cancel(); throw error }
                await decoder.cancel()
                let start = Int(CMTimeConvertScale(decoder.startTime, timescale: Int32(media.rate), method: .roundTowardZero).value)
                #expect(start >= target && samples == Array(baseline.dropFirst(start * media.channels)),
                        "target \(target)\(fresh ? " restored" : ""): \(samples.count / media.channels) frames from \(start)")
            }
        }
    }

    // MARK: - Downstream keeps one format

    @MainActor @Test(arguments: names)
    func playbackSessionPlaysThroughEveryChange(name: String) async throws {
        let (media, url, _) = try media(name)
        let cache = URL.temporaryDirectory.appendingPathComponent("mp3-format-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        for (speed, skipSilence) in [(Float(1), false), (Float(1.75), true)] {
            var outputs: [SampleBufferPCMOutputTests.Transport] = []
            let owner = PCMPlaybackFactory(cacheDirectory: cache, makeTransport: {
                let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
            })
            let factory = try await owner.make(.local(url))
            let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: speed, skipSilence: skipSilence))
            defer { session.close() }
            try await session.prepare(); try session.play()
            let output = try #require(outputs.last)
            let deadline = ContinuousClock.now + .seconds(30)
            while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
                if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
                await Task.yield()
            }
            #expect(session.state == .ended && session.failure == nil,
                    "\(name) at \(speed)×: \(session.state), \(String(describing: session.failure))")
            if speed == 1, !skipSilence {
                // One format throughout: every frame of every segment reaches the output.
                #expect(session.writtenFrames == Int64(media.origins.last!), "\(name): \(session.writtenFrames) frames reached the output")
            } else {
                #expect(session.writtenFrames > 0 && Double(session.writtenFrames) < Double(media.origins.last!) / Double(speed) * 1.05)
            }
        }
    }

    // MARK: - Helpers

    /// Every converted segment so far was fitted by no more than the join rounding.
    private func expectJoinsWithinRounding(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let joins = MP3SegmentJoinDiagnostics.current
        #expect(joins.largest <= Self.limit && joins.anomalies == 0,
                "\(name): converted segments fitted by up to \(joins.largest) frames", sourceLocation: sourceLocation)
    }

    /// Targets just before, at and just after each change, in each segment's middle and near the end.
    private func targets(_ media: Media) -> [CMTime] {
        let origins = media.origins, rate = Int32(media.rate)
        var frames: [Int] = []
        for index in 1..<media.segments.count {
            frames += [origins[index] - media.rate / 100, origins[index], origins[index] + 1, origins[index] + media.rate / 50]
        }
        for index in media.segments.indices { frames.append((origins[index] + origins[index + 1]) / 2) }
        frames.append(origins.last! - media.rate / 10)
        return frames.map { CMTime(value: Int64($0), timescale: rate) }
    }

    private func expectSeek(_ decoder: NativeMP3SourceDecoder, _ media: Media, target: CMTime, baseline: [Int16], path: String,
                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let rate = Int32(media.rate), channels = media.channels
        let samples: [Int16]
        do { samples = try await drain(decoder) } catch { await decoder.cancel(); throw error }
        await decoder.cancel()
        let wanted = CMTimeConvertScale(target, timescale: rate, method: .roundAwayFromZero).value
        let start = CMTimeConvertScale(decoder.startTime, timescale: rate, method: .roundTowardZero).value
        let label = "\(media.name) \(path) target \(wanted)"
        #expect(decoder.sampleRate == media.rate && decoder.channels == channels, "\(label): format changed", sourceLocation: sourceLocation)
        #expect(start >= wanted && start - wanted < Int64(media.longestFrame), "\(label): admitted at \(start)", sourceLocation: sourceLocation)
        // The rest of the file, from exactly where the label says (no seek-map estimate here).
        #expect(samples.count == baseline.count - Int(start) * channels, "\(label): \(samples.count / channels) frames to the end",
                sourceLocation: sourceLocation)
        // Tone segments repeat, so compare at the labelled frame rather than search.
        let residual = PCMLocator.residual(samples, in: baseline, channels: channels, at: Int(start))
        #expect(residual < 0.05, "\(label): the audio at \(start) is not the file's there (residual \(residual))",
                sourceLocation: sourceLocation)
        #expect(AudibleMatch.matches(samples, Array(baseline.dropFirst(Int(start) * channels)), channels: channels,
                sampleRate: media.rate, lengthTolerance: 0), "\(label): the rest differs", sourceLocation: sourceLocation)
    }

    private func drain(_ decoder: NativeMP3SourceDecoder) async throws -> [Int16] {
        var samples: [Int16] = []
        while let packet = try await decoder.next() {
            #expect(packet.sampleRate == decoder.sampleRate && packet.channels == decoder.channels)
            #expect(packet.presentationTime == decoder.startTime + CMTime(value: Int64(samples.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            samples += packet.samples
        }
        return samples
    }

    /// The segment's bytes decoded on their own, at their own rate and channel count.
    private func decodeAlone(_ data: Data, _ segment: Segment) throws -> [Int16] {
        var packets: [(offset: Int, size: Int)] = [], offset = segment.byteOffset
        let end = segment.byteOffset + segment.byteCount
        while offset < end {
            let word = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let version = (word >> 19) & 3, index = Int((word >> 12) & 15)
            let table = version == 3 ? [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                : [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
            let size = (version == 3 ? 144 : 72) * table[index - 1] * 1000 / segment.sampleRate + Int((word >> 9) & 1)
            packets.append((offset, size)); offset += size
        }
        try #require(offset == end && packets.count == segment.mpegFrames)
        var basic = AudioStreamBasicDescription(mSampleRate: Double(segment.sampleRate), mFormatID: kAudioFormatMPEGLayer3,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(segment.framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(segment.channels), mBitsPerChannel: 0, mReserved: 0)
        let input = try #require(AVAudioFormat(streamDescription: &basic))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(segment.sampleRate),
            channels: AVAudioChannelCount(segment.channels), interleaved: true))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096))
        var cursor = 0, result: [Int16] = []
        while true {
            var supplied: [AVAudioCompressedBuffer] = [], error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, state in
                guard cursor < packets.count else { state.pointee = .endOfStream; return nil }
                let slice = packets[cursor..<min(packets.count, cursor + 32)]
                let buffer = AVAudioCompressedBuffer(format: input, packetCapacity: UInt32(slice.count), maximumPacketSize: slice.map(\.size).max()!)
                var position = 0
                for (i, packet) in slice.enumerated() {
                    data.withUnsafeBytes { buffer.data.advanced(by: position).copyMemory(from: $0.baseAddress!.advanced(by: packet.offset), byteCount: packet.size) }
                    buffer.packetDescriptions![i] = AudioStreamPacketDescription(mStartOffset: Int64(position), mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.size))
                    position += packet.size
                }
                buffer.packetCount = UInt32(slice.count); buffer.byteLength = UInt32(position); cursor += slice.count
                supplied.append(buffer); state.pointee = .haveData; return buffer
            }
            withExtendedLifetime(supplied) {}
            if let error { throw error }
            try #require(status != .error)
            result += UnsafeBufferPointer(start: pcm.int16ChannelData![0], count: Int(pcm.frameLength) * segment.channels)
            if status == .endOfStream { break }
        }
        return result
    }

    /// Two channels averaged to one, or one copied to two.
    private func mixed(_ samples: [Int16], from: Int, to: Int) -> [Int16] {
        if from == to { return samples }
        if from == 2 { return stride(from: 0, to: samples.count, by: 2).map { Int16((Int32(samples[$0]) + Int32(samples[$0 + 1])) / 2) } }
        return samples.flatMap { [$0, $0] }
    }

    /// An independent rate conversion of a whole segment, everything the converter returns.
    private func resampled(_ samples: [Int16], channels: Int, from: Int, to: Int) throws -> [Int16] {
        let source = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(from), channels: AVAudioChannelCount(channels), interleaved: false))
        let destination = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(to), channels: AVAudioChannelCount(channels), interleaved: false))
        let converter = try #require(AVAudioConverter(from: source, to: destination))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count / channels)))
        input.frameLength = input.frameCapacity
        for frame in 0..<Int(input.frameLength) {
            for channel in 0..<channels { input.floatChannelData![channel][frame] = Float(samples[frame * channels + channel]) }
        }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: destination,
            frameCapacity: AVAudioFrameCount(samples.count / channels * to / from + 4096)))
        var given = false, error: NSError?
        _ = converter.convert(to: output, error: &error) { _, state in
            if given { state.pointee = .endOfStream; return nil }
            given = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        var result: [Int16] = []
        for frame in 0..<Int(output.frameLength) {
            for channel in 0..<channels {
                result.append(Int16(max(-32768, min(32767, output.floatChannelData![channel][frame].rounded()))))
            }
        }
        return result
    }

    /// Goertzel power of one channel at `hz`, over the middle of the samples.
    private func power(_ samples: [Int16], channel: Int, channels: Int, rate: Int, hz: Double) -> Double {
        let frames = samples.count / channels
        let begin = frames / 4, end = frames - frames / 4
        let coefficient = 2 * cos(2 * Double.pi * hz / Double(rate))
        var previous = 0.0, previous2 = 0.0
        for frame in begin..<max(begin, end) {
            let value = Double(samples[frame * channels + channel]) + coefficient * previous - previous2
            previous2 = previous; previous = value
        }
        return previous * previous + previous2 * previous2 - coefficient * previous * previous2
    }
}
private final class MP3FormatChangeFixtures: NSObject {}

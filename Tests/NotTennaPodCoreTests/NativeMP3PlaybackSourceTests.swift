import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Testing
import Synchronization
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct NativeMP3PlaybackSourceTests {
    private func fixture(_ name: String = "playback-30sec") -> URL {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Fixtures")!
#else
        Bundle(for: ReusableMP3Fixtures.self).url(forResource: name, withExtension: "mp3")!
#endif
    }
    private func sounds(_ actual: [Int16], like expected: [Int16], _ decoder: NativeMP3SourceDecoder) -> Bool {
        !actual.isEmpty && AudibleMatch.matches(actual, expected, channels: decoder.channels, sampleRate: decoder.sampleRate)
    }
    private func near(_ time: CMTime, _ seconds: Double) -> Bool { abs(CMTimeGetSeconds(time) - seconds) <= 0.25 }
    private func completeVBRIFileSamples() throws -> [Int16] {
        let file = try AVAudioFile(forReading: fixture("playback-indexed-vbri-3"), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var samples: [Int16] = []
        // This native file length is estimated1440000; a final full-capacity
        // read returns all1251 independently inventoried MPEG packets instead
        // of clipping1152 valid frames at that estimate.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            samples += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0],
                count: Int(buffer.frameLength * file.processingFormat.channelCount)))
        }
        #expect(samples.count == 1251 * 1152 * 2)
        return samples
    }

    @Test(arguments: ["changed206", "changed200", "changedLength", "lengthWithoutValidator", "omitted206", "unchanged200"],
          [(false, false), (false, true), (true, false), (true, true)])
    func seekAfterServerFileChangedNeverMixesOldAndNewAudio(response: String, mode: (Bool, Bool)) async throws {
        let (proxyEnabled, shared) = mode
        let original = try Data(contentsOf: fixture("playback-indexed-vbr-stereo"))
        var replacement = try Data(contentsOf: fixture("playback-indexed-vbri-3"))
        #expect(replacement.count == original.count && replacement != original)
        if response == "changedLength" || response == "lengthWithoutValidator" {
            replacement = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 1, 0]) + Data(repeating: 0, count: 128) + replacement
        }
        let changed = response.hasPrefix("changed") || response == "lengthWithoutValidator", changedBytes = replacement
        let requests = Mutex(0)
        let auth = "Basic " + Data("identity:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != auth {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"identity\""])
            }
            let first = requests.withLock { $0 += 1; return $0 == 1 }
            if first {
                var headers = ["Content-Type": "audio/mpeg", "Content-Length": "\(original.count)"]
                if response != "lengthWithoutValidator" { headers["ETag"] = "\"original\"" }
                return .init(headers: headers, body: Data(original.prefix(8192)), keepConnectionOpen: true)
            }
            let data = changed ? changedBytes : original
            let full = response.hasSuffix("200") || request.headers["range"] == nil
            let start = full ? 0 : Int(request.headers["range"]?.dropFirst(6).dropLast() ?? "")!
            var headers = ["Content-Type": "audio/mpeg", "Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"]
            if response != "omitted206" && response != "lengthWithoutValidator" { headers["ETag"] = changed ? "\"replacement\"" : "\"original\"" }
            return .init(status: full ? 200 : 206, headers: headers, body: Data(data.dropFirst(start)))
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "identity", password: "saved") : PodcastProxy()
        let remote = proxyEnabled ? URL(string: "http://identity.invalid/episode.mp3")! : server.url
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("identity-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let source = NativeMP3PlaybackSource(url: remote, proxy: proxy, cache: shared ? cache : nil)
        let first = try await source.makeDecoder(prepareSourceTimeline: true)
        await first.cancel()
        if changed {
            do {
                let decoder = try await source.makeDecoder(start: CMTime(value: 20, timescale: 1), prepareSourceTimeline: true)
                await decoder.cancel()
                Issue.record("A changed HTTP representation used the prepared source metadata")
            } catch {
                if response == "lengthWithoutValidator" { #expect((error as? MediaDownloadError) == .invalidRange) }
                else { #expect((error as? URLError)?.code == .resourceUnavailable) }
            }
            // A subsequent attempt plays the new file rather than failing forever.
            let recovered = try await source.makeDecoder(start: CMTime(value: 20, timescale: 1), prepareSourceTimeline: true)
            let actual = try await drain(recovered).flatMap(\.samples)
            let expected = try completeVBRIFileSamples()
            await recovered.cancel()
            #expect(near(recovered.startTime, 20))
            #expect(sounds(actual, like: Array(expected.suffix(actual.count)), recovered))
        } else {
            let decoder = try await source.makeDecoder(start: CMTime(value: 20, timescale: 1), prepareSourceTimeline: true)
            let actual = try await drain(decoder).flatMap(\.samples)
            let baseline = try NativePCMDecoder(url: fixture("playback-indexed-vbr-stereo"))
            var expected: [Int16] = []
            while let packet = try await baseline.next() { expected += packet.samples }
            await baseline.cancel(); await decoder.cancel()
            #expect(near(decoder.startTime, 20))
            #expect(sounds(actual, like: Array(expected.suffix(actual.count)), decoder))
        }
    }

    @Test func replacedCachedFilePlaysNewAudio() async throws {
        let original = try Data(contentsOf: fixture("playback-indexed-vbr-stereo"))
        let replacement = try Data(contentsOf: fixture("playback-indexed-vbri-3"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(original.count)", "ETag": "\"original\""],
                body: Data(original.prefix(8192)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("identity-generation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy(), cache: cache)
        let initial = try await source.makeDecoder(prepareSourceTimeline: true)
        await initial.cancel()
        let old = cache.representation(for: server.url)
        try #require(old?.validation == .strongETag("\"original\""))
        try cache.invalidate(for: server.url, matching: old, generation: cache.generation(for: server.url))
        let fresh = HTTPMediaRepresentation(length: Int64(replacement.count), validation: .strongETag("\"new\""))
        try cache.admit(fresh, for: server.url)
        let writer = try #require(try cache.beginWrite(for: server.url, at: 0, contentLength: Int64(replacement.count)))
        try writer.append(replacement); try writer.finish()
        let reopened = try await source.makeDecoder(prepareSourceTimeline: true)
        let actual = try await drain(reopened).flatMap(\.samples)
        let expected = try completeVBRIFileSamples()
        await reopened.cancel()
        #expect(sounds(actual, like: expected, reopened), "new cache PCM: \(actual.count) samples, oracle: \(expected.count)")
    }

    @Test(arguments: [false, true], [false, true])
    func cacheAfterRelaunchNeverMixesChangedServerFile(changed: Bool, proxyEnabled: Bool) async throws {
        let original = try Data(contentsOf: fixture("playback-indexed-vbr-stereo"))
        let replacement = try Data(contentsOf: fixture("playback-indexed-vbri-3"))
        let counter = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            let first = counter.withLock { $0 += 1; return $0 == 1 }
            if first {
                return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(original.count)", "ETag": "\"original\""],
                    body: Data(original.prefix(8192)), keepConnectionOpen: true)
            }
            let range = request.headers["range"]
            let start = range.flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0
            let data = changed ? replacement : original
            return .init(status: start == 0 ? 200 : 206, headers: ["Content-Type": "audio/mpeg", "ETag": changed ? "\"new\"" : "\"original\"",
                "Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"], body: Data(data.dropFirst(start)))
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("identity-reopen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let remote = proxyEnabled ? URL(string: "http://reopened.invalid/media.mp3")! : server.url
        func seed() async throws {
            let cache = try SharedStreamingCache(directory: directory)
            var source: NativeMP3PlaybackSource? = NativeMP3PlaybackSource(url: remote, proxy: proxy, cache: cache)
            let decoder = try await source!.makeDecoder(prepareSourceTimeline: true)
            await decoder.cancel(); source = nil
            let deadline = ContinuousClock.now + .seconds(5)
            while !decoder.producerSnapshot.exited, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(decoder.producerSnapshot.exited)
        }
        try await seed()
        let reopened = try SharedStreamingCache(directory: directory)
        #expect(reopened.representation(for: remote)?.validation == .strongETag("\"original\""))
        let source = NativeMP3PlaybackSource(url: remote, proxy: proxy, cache: reopened)
        if changed {
            do {
                let decoder = try await source.makeDecoder(start: CMTime(value: 20, timescale: 1), prepareSourceTimeline: true)
                await decoder.cancel(); Issue.record("Replacement bytes joined the reopened cache")
            } catch { #expect((error as? URLError)?.code == .resourceUnavailable) }
            let fresh = try await source.makeDecoder(prepareSourceTimeline: true)
            let actual = try await drain(fresh).flatMap(\.samples)
            let expected = try completeVBRIFileSamples()
            await fresh.cancel()
            #expect(sounds(actual, like: expected, fresh), "replacement PCM: \(actual.count) samples, file oracle: \(expected.count)")
        } else {
            let decoder = try await source.makeDecoder(start: CMTime(value: 20, timescale: 1), prepareSourceTimeline: true)
            let actual = try await drain(decoder).flatMap(\.samples)
            let baseline = try NativePCMDecoder(url: fixture("playback-indexed-vbr-stereo"))
            var expected: [Int16] = []
            while let packet = try await baseline.next() { expected += packet.samples }
            await baseline.cancel(); await decoder.cancel()
            #expect(near(decoder.startTime, 20))
            #expect(sounds(actual, like: Array(expected.suffix(actual.count)), decoder))
        }
    }

    @Test(arguments: ["playback-30sec", "playback-indexed-vbr-low-rate", "playback-indexed-mllt-stereo-v3"],
          [(false, false), (false, true), (true, false), (true, true)])
    func seekPastEndEndsEpisodeAndLaterPlaybackIsComplete(name: String, mode: (Bool, Bool)) async throws {
        let (proxyEnabled, shared) = mode
        let local = fixture(name), media = try Data(contentsOf: local)
        let tag = media.starts(with: [0x49, 0x44, 0x33]) ? 10 + media[6...9].reduce(0) { ($0 << 7) | Int($1) } : 0
        let counter = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == FeedCredentials(username: "end", password: "saved").authorization(utf8: false))
            if proxyEnabled && request.headers["proxy-authorization"] != "Basic " + Data("proxy:saved".utf8).base64EncodedString() {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"end\""])
            }
            let first = counter.withLock { $0 += 1; return $0 == 1 }
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg",
                    "Content-Range": "bytes \(start)-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(start)))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(media.count)"],
                body: first ? Data(media.prefix(tag + 8192)) : media, keepConnectionOpen: first)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("past-end-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let remote = proxyEnabled ? URL(string: "http://end.invalid/audio.mp3")! : server.url
        let source = NativeMP3PlaybackSource(url: remote, proxy: proxy,
            credentials: FeedCredentials(username: "end", password: "saved"), cache: shared ? cache : nil)
        let initial = try await source.makeDecoder(prepareSourceTimeline: true)
        let duration = try #require(initial.bufferState?.snapshot.durationMicroseconds)
        #expect((30_000_000...30_200_000).contains(duration))
        await initial.cancel()
        for target in [duration + 1, duration + 60_000_000] {
            // Past the end: nothing plays, duration and seekability are kept.
            let decoder = try await source.makeDecoder(start: CMTime(value: target, timescale: 1_000_000), prepareSourceTimeline: true)
            #expect(try await decoder.next() == nil)
            #expect(decoder.bufferState?.snapshot.durationMicroseconds == duration)
            #expect(decoder.bufferState?.snapshot.sourceSeekable == true)
            await decoder.cancel()
        }
        let equal = try await source.makeDecoder(start: CMTime(value: duration, timescale: 1_000_000), prepareSourceTimeline: true)
        #expect(try await equal.next() == nil)
        await equal.cancel()
        let replay = try await source.makeDecoder(prepareSourceTimeline: true)
        let replayed = try await drain(replay)
        let baseline = try NativePCMDecoder(url: local)
        var expected: [Int16] = []
        while let packet = try await baseline.next() { expected += packet.samples }
        await baseline.cancel()
        if name == "playback-indexed-vbr-low-rate" { expected = Array(expected[576..<(576 + 30 * 22050)]) }
        #expect(sounds(replayed.flatMap(\.samples), like: expected, replay))
        #expect(replay.startTime == .zero)
        await replay.cancel()
    }

    @Test(arguments: ["playback-30sec", "playback-unknown-duration", "playback-indexed-vbr-stereo", "playback-indexed-vbr-low-rate",
                      "playback-indexed-mllt-stereo-v3", "playback-indexed-mllt-stereo-v4"],
          [(false, false), (false, true), (true, false), (true, true)])
    func seekOutsideLoadedAudioLandsOnTargetAndPlaysRest(name: String, mode: (Bool, Bool)) async throws {
        try await indexedSeeks(name: name, mode: mode)
    }

    @Test(arguments: ["playback-indexed-vbri-9", "playback-indexed-vbri-3"],
          [(false, false), (false, true), (true, false), (true, true)])
    func vbriMediaPreservesAudioAcrossIndexedSeeks(name: String, mode: (Bool, Bool)) async throws {
        try await indexedSeeks(name: name, mode: mode, targets: [29500, 29800, 2000, 0])
    }

    private func indexedSeeks(name: String, mode: (Bool, Bool), targets: [Int64] = [20000, 24000, 2000, 0]) async throws {
        let (proxyEnabled, useSharedCache) = mode
        let local = fixture(name), media = try Data(contentsOf: local)
        let tagBytes = media.starts(with: [0x49, 0x44, 0x33]) ? 10 + media[6...9].reduce(0) { ($0 << 7) | Int($1) } : 0
        let initialPrefix = tagBytes + 8192
        let credentials = FeedCredentials(username: "indexed", password: "captured")
        let requests = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != "Basic " + Data("proxy:saved".utf8).base64EncodedString() {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"indexed\""])
            }
            guard request.headers["authorization"] == credentials.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"indexed\""])
            }
            let number = requests.withLock { value in value += 1; return value }
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"stable\"",
                    "Content-Range": "bytes \(start)-\(media.count - 1)/\(media.count)"], body: media.subdata(in: start..<media.count))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"stable\"", "Content-Length": "\(media.count)"],
                body: number == 1 ? Data(media.prefix(initialPrefix)) : media, keepConnectionOpen: number == 1)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!,
            username: "proxy", password: "saved") : PodcastProxy()
        let remote = proxyEnabled ? URL(string: "http://indexed-mp3.invalid/audio.mp3")! : server.url
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("indexed-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let source = NativeMP3PlaybackSource(url: remote, proxy: proxy, credentials: credentials, cache: useSharedCache ? cache : nil)
        let initial = try await source.makeDecoder(prepareSourceTimeline: true)
        if name.contains("mllt") || name.contains("vbri") {
            // Duration from the MLLT/VBRI index is shown before downloading.
            #expect(abs((initial.sourceDurationMilliseconds ?? 0) - 30024) <= 100)
        }
        await initial.cancel()
        let file = try AVAudioFile(forReading: local, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var reference: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            reference += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0],
                count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount)))
        }
        // Independent file decoding omits MPEG2 container trimming on this
        // runtime. The generated source is exactly30s; ffprobe records its
        // encoder delay/padding separately from the production metadata reader.
        if name == "playback-indexed-vbr-low-rate" { reference = Array(reference[576..<(576 + 30 * 22050)]) }
        for milliseconds in targets {
            let decoder = try await source.makeDecoder(start: CMTime(value: milliseconds, timescale: 1000), prepareSourceTimeline: true)
            let audio = try await drain(decoder)
            let samples = audio.flatMap(\.samples)
            #expect(near(decoder.startTime, Double(milliseconds) / 1000), "\(name) target \(milliseconds) ms")
            // The remaining audio (to the end of the file) sounds like the file.
            #expect(sounds(samples, like: Array(reference.suffix(samples.count)), decoder), "\(name) target \(milliseconds) ms")
            // The reference ends where the episode's audio ends, so the heard audio's
            // start is its length back from there. It must be where the user asked
            // (within 0.25 s), like the shown position. The indexed/CBR seek maps give
            // a position label up to ~0.1 s from the heard audio, as Android's
            // Mp3Extractor does; nobody can hear that, so only 0.25 s is required.
            let heardStart = Double(reference.count - samples.count) / Double(decoder.channels * decoder.sampleRate)
            #expect(abs(heardStart - Double(milliseconds) / 1000) <= 0.25,
                    "\(name) target \(milliseconds) ms: audio heard from \(heardStart) s")
            var timestamp = decoder.startTime
            for packet in audio {
                #expect(packet.presentationTime == timestamp)
                timestamp = timestamp + CMTime(value: Int64(packet.samples.count / decoder.channels), timescale: Int32(decoder.sampleRate))
            }
            await decoder.cancel()
        }
    }

    @Test(arguments: [false, true])
    func authenticatedEpisodePlaysCompletelyAndRepeatedSeeksUseLoadedAudio(proxyEnabled: Bool) async throws {
        let url = fixture(), media = try Data(contentsOf: url)
        let credentials = FeedCredentials(username: "mp3", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != "Basic " + Data("proxy:saved".utf8).base64EncodedString() {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"source\""])
            }
            guard request.headers["authorization"] == credentials.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"source\""])
            }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: media)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!,
            username: "proxy", password: "saved") : PodcastProxy()
        let remote = proxyEnabled ? URL(string: "http://reusable-mp3.invalid/audio.mp3")! : server.url
        let source = NativeMP3PlaybackSource(url: remote, proxy: proxy, credentials: credentials)
        let first = try await source.makeDecoder()
        #expect(first.sampleRate == 44100 && first.channels == 1 && first.startFrame == 0)
        #expect(abs((first.timing.durationMilliseconds ?? 0) - 30040) <= 100)
        let initial = try await drain(first)
        await first.cancel()

        // Independent native file demuxer, including every leading/trailing sample.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var expected: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            try #require(buffer.frameLength > 0)
            expected += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
        }
        #expect(sounds(initial.flatMap(\.samples), like: expected, first))
        let baselineDecoder = try await source.makeDecoder()
        let baseline = try await drain(baselineDecoder).flatMap(\.samples)
        await baselineDecoder.cancel()
        for milliseconds: Int64 in [1, 123, 1000, 29900, 30100, 0, 1000] {
            let target = CMTime(value: milliseconds, timescale: 1000)
            let decoder = try await source.makeDecoder(start: target)
            let samples = try await drain(decoder).flatMap(\.samples)
            if milliseconds > 30040 {
                #expect(samples.isEmpty, "audio after the end")
            } else {
                #expect(near(decoder.startTime, Double(milliseconds) / 1000), "target \(milliseconds) ms")
                let start = CMTimeConvertScale(decoder.startTime, timescale: 44100, method: .roundTowardZero).value
                let tail = Array(baseline.dropFirst(Int(start)))
                #expect(tail.count < 44100 / 10 || sounds(samples, like: tail, decoder), "target \(milliseconds) ms")
            }
            await decoder.cancel()
        }
        // Seeks reuse the loaded episode instead of downloading it again.
        let accepted = server.requests.filter { $0.headers["authorization"] == credentials.authorization(utf8: false)
            && (!proxyEnabled || $0.headers["proxy-authorization"] != nil) }
        #expect(accepted.count == 1)
    }

    @Test(arguments: ["playback-30sec", "playback-unknown-duration", "playback-vbr-stereo", "playback-vbr-low-rate"])
    func seeksWithinLoadedAudioLandOnTargetAndPlayRest(name: String) async throws {
        let media = try Data(contentsOf: fixture(name))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg"], body: media)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let initial = try await source.makeDecoder(prepareSourceTimeline: true)
        let baseline = try await drain(initial).flatMap(\.samples)
        let sampleRate = initial.sampleRate, channels = initial.channels
        await initial.cancel()
        let targets: [Int64] = name.contains("vbr") ? [500, 350, 0] : [10000, 2000, 29900, 0]
        for target in targets {
            let decoder = try await source.makeDecoder(start: CMTime(value: target, timescale: 1000), prepareSourceTimeline: true)
            #expect(near(decoder.startTime, Double(target) / 1000))
            let packets = try await drain(decoder)
            let start = CMTimeConvertScale(decoder.startTime, timescale: Int32(sampleRate), method: .roundTowardZero).value
            let expected = Array(baseline.dropFirst(Int(start) * channels))
            #expect(sounds(packets.flatMap(\.samples), like: expected, decoder), "target \(target) ms")
            await decoder.cancel()
        }
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func seekAfterOldAudioReleasedStillPlaysCorrectly(throughInterface: Bool) async throws {
        let segment = try Data(contentsOf: fixture("playback-unknown-duration"))
        let media = (0..<12).reduce(into: Data()) { data, _ in data.append(segment) }
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: media) }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seek-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy(), cache: cache)
        let first = try await source.makeDecoder(prepareSourceTimeline: true)
        let baseline = try await drain(first).flatMap(\.samples)
        if throughInterface {
            let active: any PCMDecoding = first
            try await active.updatePlayback(.init(positionMicroseconds: 320_000_000, speed: 1))
        } else {
            try await first.updatePlayback(.init(positionMicroseconds: 320_000_000, speed: 1))
        }
        let lower = try #require(first.producerSnapshot.bufferedRange?.lowerBound)
        try #require(lower > 19_000_000)
        await first.cancel()
        // The requested sample remains buffered, but its native preroll reaches
        // into the discarded five-minute back buffer. Reconstruct from cache.
        let target = CMTime(value: (lower + 999) / 1000 + 1, timescale: 1000)
        let next = try await source.makeDecoder(start: target, prepareSourceTimeline: true)
        #expect(near(next.startTime, CMTimeGetSeconds(target)))
        let packets = try await drain(next)
        let start = CMTimeConvertScale(next.startTime, timescale: Int32(next.sampleRate), method: .roundTowardZero).value
        let expected = Array(baseline.dropFirst(Int(start) * next.channels))
        #expect(sounds(packets.flatMap(\.samples), like: expected, next))
        #expect(server.requests.count == 1)
        await next.cancel()
    }

    @Test(arguments: [false, true], [false, true])
    func seekInLiveStreamReloadsFromStartAndPlaysNewAudio(proxyEnabled: Bool, firstEnded: Bool) async throws {
        let oldMedia = try Data(contentsOf: fixture("playback-unknown-duration"))
        let newURL = fixture("playback-vbr-stereo"), newMedia = try Data(contentsOf: newURL)
        let accepted = Mutex(0), delays = Mutex<[Int64]>([])
        let credentials = FeedCredentials(username: "live", password: "captured")
        let retry = PCMSourceRetry { value in delays.withLock { $0.append(value) }; try Task.checkCancellation() }
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != "Basic " + Data("proxy:saved".utf8).base64EncodedString() {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"live\""])
            }
            guard request.headers["authorization"] == credentials.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"live\""])
            }
            let ordinal = accepted.withLock { value in defer { value += 1 }; return value }
            if ordinal == 0 || ordinal == 2 { return .init(status: 503, body: Data()) }
            if ordinal == 1 {
                let wire = Data("\(String(oldMedia.count, radix: 16))\r\n".utf8) + oldMedia
                    + Data((firstEnded ? "\r\n0\r\n\r\n" : "\r\n").utf8)
                return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                    body: wire, keepConnectionOpen: !firstEnded)
            }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: newMedia)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!,
            username: "proxy", password: "saved") : PodcastProxy()
        let remote = proxyEnabled ? URL(string: "http://live-seek.invalid/audio.mp3")! : server.url
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-seek-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let source = NativeMP3PlaybackSource(url: remote, proxy: proxy, credentials: credentials, cache: cache, retry: retry)
        let first = try await source.makeDecoder(prepareSourceTimeline: true)
        #expect(first.channels == 1 && first.bufferState?.snapshot.sourceSeekable == false)
        if firstEnded { _ = try await drain(first) }
        else { _ = try await first.next(); try await wait { first.producerSnapshot.parsedFrames > 441_000 } }
        await first.cancel()
        // Both same-position and nonzero live seeks reload at zero, even after
        // transient server errors.
        let next = try await source.makeDecoder(start: CMTime(value: firstEnded ? 5 : 0, timescale: 1), prepareSourceTimeline: true)
        #expect(next.startTime == .zero && next.channels == 2)
        guard next.channels == 2 else { await next.cancel(); return }
        let actual = try await drain(next).flatMap(\.samples)
        let file = try AVAudioFile(forReading: newURL, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var expected: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            try #require(buffer.frameLength > 0)
            expected += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2))
        }
        #expect(sounds(actual, like: expected, next))
        await next.cancel()
    }

    @Test func seekInUnseekableStreamRestartsFromBeginning() async throws {
        let media = try Data(contentsOf: fixture("playback-unknown-duration"))
        let wire = Data("\(String(media.count, radix: 16))\r\n".utf8) + media + Data("\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: wire, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let first = try await source.makeDecoder(prepareSourceTimeline: true)
        let initial = try #require(try await first.next())
        try await wait { first.producerSnapshot.parsedFrames > 441_000 }
        await first.cancel()
        let next = try await source.makeDecoder(start: CMTime(value: 5, timescale: 1), prepareSourceTimeline: true)
        #expect(next.startTime == .zero)
        #expect(next.bufferState?.snapshot.sourceSeekable == false)
        #expect(try await next.next()?.samples == initial.samples)
        await next.cancel()
    }

    @Test(arguments: [0, 1000])
    func cancelledLoadingCanBeRetriedAndPlays(prefixCount: Int) async throws {
        let media = try Data(contentsOf: fixture())
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(media.count)],
                body: Data(media.prefix(prefixCount)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let loading = Task { try await source.makeDecoder() }
        defer { loading.cancel() }
        try await wait {
            let snapshot = await source.networkSnapshot
            return snapshot?.waitingReaders == 1 && server.sentResponseCount == 1
        }
        loading.cancel()
        await #expect(throws: CancellationError.self) { try await loading.value }
        let replacement = Task { try await source.makeDecoder() }
        defer { replacement.cancel() }
        try await wait { (await source.networkSnapshot)?.waitingReaders == 1 }
        try await server.appendResponseBody(Data(media.dropFirst(prefixCount)), isFinal: true)
        let decoder = try await replacement.value
        #expect(try await decoder.next()?.presentationTime == .zero)
        await decoder.cancel()
    }

    @Test func newSeekWhileWaitingForDataPlaysNewTarget() async throws {
        let media = try Data(contentsOf: fixture())
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(media.count)],
                body: Data(), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let old = Task { try await source.makeDecoder(start: CMTime(value: 1000, timescale: 1000)) }
        defer { old.cancel() }
        try await wait {
            let snapshot = await source.networkSnapshot
            return snapshot?.waitingReaders == 1 && server.sentResponseCount == 1
        }
        let latest = Task { try await source.makeDecoder(start: CMTime(value: 2000, timescale: 1000)) }
        defer { latest.cancel() }
        await #expect(throws: CancellationError.self) { try await old.value }
        try await wait { (await source.networkSnapshot)?.waitingReaders == 1 }
        try await server.appendResponseBody(media, isFinal: true)
        let decoder = try await latest.value
        #expect(near(decoder.startTime, 2))
        #expect(try await decoder.next()?.presentationTime == decoder.startTime)
        await decoder.cancel()
    }

    @Test func stoppingWhileWaitingForDataThenReplayingPlaysWholeEpisode() async throws {
        let media = try Data(contentsOf: fixture())
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(media.count)],
                body: Data(media.prefix(4096)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let old = try await source.makeDecoder()
        let reading = Task { try await drain(old) }
        defer { reading.cancel() }
        // Independent parsing can already be waiting while the decoder still
        // drains queued audio. Synchronize on the actual blocked consumer too.
        try await wait { let network = await source.networkSnapshot; return old.producerSnapshot.waitingConsumer && network?.waitingReaders == 1 }
        await old.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        try await server.appendResponseBody(Data(media.dropFirst(4096)), isFinal: true)
        let latest = try await source.makeDecoder()
        // The whole 30 s episode plays (within 50 ms).
        #expect(abs(try await drain(latest).reduce(0) { $0 + $1.frameCount } - 1_323_000) <= 2205)
        await latest.cancel()
    }

    @Test func seekWhileWaitingForDataDoesNotHangAndPlaysNewTarget() async throws {
        let media = try Data(contentsOf: fixture())
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(media.count)],
                body: Data(media.prefix(4096)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let old = try await source.makeDecoder()
        let reading = Task { try await drain(old) }
        defer { reading.cancel() }
        try await wait {
            let network = await source.networkSnapshot
            return old.producerSnapshot.waitingConsumer && network?.waitingReaders == 1
        }
        let replacement = Task { try await source.makeDecoder(start: CMTime(value: 2, timescale: 1)) }
        defer { replacement.cancel() }
        // A new seek must not hang behind the old reader that waits for data.
        await #expect(throws: CancellationError.self) { try await reading.value }
        try await wait { (await source.networkSnapshot)?.waitingReaders == 1 }
        try await server.appendResponseBody(Data(media.dropFirst(4096)), isFinal: true)
        let decoder = try await replacement.value
        #expect(near(decoder.startTime, 2))
        #expect(try await decoder.next()?.presentationTime == decoder.startTime)
        await decoder.cancel()
    }

    @Test func unfinishedSourceFeedsNativeProcessedPresentationAndRebuildsPaused() async throws {
        let media = try Data(contentsOf: fixture("playback-unknown-duration"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                body: Data("\(String(media.count, radix: 16))\r\n".utf8) + media + Data("\r\n".utf8),
                keepConnectionOpen: true)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        func session() async throws -> SampleBufferPlaybackSession {
            let decoder = try await source.makeDecoder()
            let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: true, speed: 1.5)
            let transport = try VolumeControlledPCMTransport(backend: NativeSampleBufferTransport(muted: true),
                sampleRate: decoder.sampleRate, channels: decoder.channels, maximumFrames: 4096, setting: .lightReduction)
            return try SampleBufferPlaybackSession(stream: stream, transport: transport)
        }
        let first = try await session()
        defer { first.close() }
        try first.play()
        try await wait { (try first.mediaMicroseconds ?? 0) > 1_000_000 || first.failure != nil }
        try #require(first.failure == nil)
        #expect(!first.sourceEnded)
        #expect((await source.networkSnapshot)?.completed == false)
        try first.pause()
        try await first.setParameters(speed: 2, skipSilence: false)
        try first.setVolumeAdaptation(.heavyReduction)
        #expect(first.state == .paused && !first.wantsPlayback)
        first.close()
        let second = try await session()
        defer { second.close() }
        try await second.prepare()
        #expect(second.state == .paused && !second.wantsPlayback)
        #expect(try second.mediaMicroseconds == 0)
        try second.play()
        try await wait { (try second.mediaMicroseconds ?? 0) > 500_000 || second.failure != nil }
        try #require(second.failure == nil)
        #expect(server.requests.count == 1)
    }

    @Test func truncatedBodyCannotBecomeSuccessfulEOFAndInvalidTargetDoesNotStartNetworking() async throws {
        let media = try Data(contentsOf: fixture()).prefix(8000)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg"], body: Data(media))
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        for invalid in [CMTime.invalid, .indefinite, .positiveInfinity, CMTime(value: -1, timescale: 1000)] {
            await #expect(throws: NativePCMDecoder.Failure.invalidStart) { try await source.makeDecoder(start: invalid) }
        }
        #expect(server.requests.isEmpty)
        let decoder = try await source.makeDecoder()
        await #expect(throws: NativeMP3PCMDecoder.Failure.incompleteStream) { try await drain(decoder) }
        await decoder.cancel()
    }

    private func drain(_ decoder: NativeMP3SourceDecoder) async throws -> [NativePCMDecoder.Packet] {
        var packets: [NativePCMDecoder.Packet] = []
        while let packet = try await decoder.next() { packets.append(packet) }
        return packets
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < deadline
        try #require(try await condition())
    }
}
private final class ReusableMP3Fixtures: NSObject {}

import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) struct NativeAudioPlaybackSourceTests {
    static let names = ["tone.wav", "tone.aac", "tone.m4a", "tone-tail.m4a", "tone.flac"]
    private static func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        try #require(Bundle(for: NativeSourceFixtures.self).url(forResource: name, withExtension: nil))
#endif
    }
    private func baseline(_ name: String) throws -> [Int16] {
        try baseline(Self.fixture(name))
    }
    private func baseline(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var result: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            result += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount)))
        }
        return result
    }
    private func collect(_ decoder: any PCMDecoding, alreadyReadFrames: Int64 = 0) async throws -> [Int16] {
        var result: [Int16] = []
        while let packet = try await decoder.next() {
            // Contiguous timestamps: the position shown to the user follows the audio heard.
            #expect(packet.presentationTime == CMTime(value: decoder.startFrame + alreadyReadFrames + Int64(result.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            result += packet.samples
        }
        return result
    }
    private func wait(_ predicate: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            await Task.yield()
        }
        try #require(predicate())
    }
    /// Lossless formats must decode exactly; lossy ones must sound the same.
    private func sounds(_ actual: [Int16], like expected: [Int16], _ name: String, _ decoder: any PCMDecoding) -> Bool {
        name.hasSuffix("wav") || name.hasSuffix("flac") ? actual == expected
            : AudibleMatch.matches(actual, expected, channels: decoder.channels, sampleRate: decoder.sampleRate)
    }
    private let quarterSecond: Int64 = 12000

    @Test(arguments: names, [0, 1, 2, 3])
    func completeAudioPlaysAndReplaysFromLoadedData(name: String, configuration: Int) async throws {
        let known = configuration & 1 == 0, proxy = configuration & 2 != 0
        let context = try await Context.open(name: name, known: known, proxyEnabled: proxy)
        defer { context.close() }
        let source = try context.source()
        let decoder = try await source.makeDecoder()
        let expected = try baseline(name)
        if name != "tone.aac" || known {
            #expect(abs((decoder.sourceDurationMilliseconds ?? 0) - 8000) <= 100)
        }
        #expect(decoder.sourceSeekable == (known || (name != "tone.aac" && name != "tone.flac")))
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: 1)
        var actual: [Int16] = []
        while let samples = try await stream.next() { actual += samples }
        #expect(sounds(actual, like: expected, name, decoder), "\(name) configuration=\(configuration): played audio differs")
        if name == "tone.aac" && !known {
            // Unknown-length stream: duration becomes known at the end, still not seekable.
            #expect(abs((decoder.sourceDurationMilliseconds ?? 0) - 8000) <= 100 && decoder.sourceSeekable == false)
        }
        await stream.cancel()
        let requests = context.server.requests.count
        if known { context.server.stop() }
        let replay = try await source.makeDecoder()
        #expect(sounds(try await collect(replay), like: expected, name, replay))
        await replay.cancel()
        // A finite, already loaded episode replays without the network.
        if known { #expect(context.server.requests.count == requests) }
    }

    @Test(arguments: ["tone.wav", "tone.flac"], [false, true])
    func seekWithinLoadedAudioPlaysCorrectTailOffline(name: String, proxyEnabled: Bool) async throws {
        let context = try await Context.open(name: name, known: true, proxyEnabled: proxyEnabled)
        defer { context.close() }
        let source = try context.source(), expected = try baseline(name)
        let first = try await source.makeDecoder()
        #expect(try await collect(first) == expected)
        await first.cancel()
        context.server.stop()
        let requests = context.server.requests.count
        let seek = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        #expect(abs(seek.startFrame - 192000) <= quarterSecond)
        #expect(try await collect(seek) == Array(expected.dropFirst(Int(seek.startFrame))))
        // Far-ahead playback position (older history released), then seek back.
        try await seek.updatePlayback(.init(positionMicroseconds: 304_000_000, speed: 1))
        await seek.cancel()
        let back = try await source.makeDecoder(start: CMTime(value: 1, timescale: 1), admission: .exactFrame)
        #expect(abs(back.startFrame - 48000) <= quarterSecond)
        #expect(try await collect(back) == Array(expected.dropFirst(Int(back.startFrame))))
        await back.cancel()
        #expect(context.server.requests.count == requests)
    }

    @MainActor @Test(arguments: [false, true])
    func unknownDurationAppearsAtEndWhilePausedWithoutMakingLiveSeekable(proxyEnabled: Bool) async throws {
        let context = try await Context.open(name: "tone.aac", known: false, proxyEnabled: proxyEnabled, heldPrefix: 32768)
        defer { context.close() }
        let source = try context.source()
        let decoder = try await source.makeDecoder()
        let transport = Transport()
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: 1, maximumOutputFrames: 127)
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare()
        try await wait { context.remote.input.snapshot().waitingReaders > 0 }
        #expect(session.sourceDurationMilliseconds == nil && session.sourceSeekable == false)
        #expect(session.state == .paused && !transport.playing)
        let data = try Data(contentsOf: Self.fixture("tone.aac"))
        try await context.server.appendResponseBody(Data(data.dropFirst(32768)), isFinal: true)
        let deadline = ContinuousClock.now + .seconds(5)
        while session.sourceDurationMilliseconds == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(abs((session.sourceDurationMilliseconds ?? 0) - 8000) <= 100 && session.sourceSeekable == false)
        // Learning the duration must not start playback.
        #expect(session.state == .paused && !transport.playing)
        session.close()
        // A seek in the originally live stream restarts it from the beginning.
        let next = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        #expect(next.startFrame == 0)
        await next.cancel()
    }

    @Test(arguments: [false, true])
    func liveStreamFailureKeepsPlayedAudioThenRetryPlaysRecording(proxyEnabled: Bool) async throws {
        let live = try Data(contentsOf: Self.fixture("tone.aac")), recorded = try Data(contentsOf: Self.fixture("tone.wav"))
        let calls = Mutex(0), credentials = FeedCredentials(username: "native", password: "deferred")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let first = calls.withLock { $0 += 1; return $0 == 1 }
            if first {
                let prefix = Data(live.prefix(32768))
                return .init(headers: ["Content-Type": "audio/aac", "Transfer-Encoding": "chunked"],
                    body: Data("8000\r\n".utf8) + prefix + Data("\r\n".utf8), keepConnectionOpen: true)
            }
            return .init(headers: ["Content-Type": "audio/wav"], body: recorded)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("native-deferred-owner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SharedStreamingCache(directory: root)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://native-deferred.invalid/audio")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let old = try await source.makeDecoder()
        let actual = try await collect(old), expected = try baseline("tone.aac")
        #expect(!actual.isEmpty && AudibleMatch.matches(actual, Array(expected.prefix(actual.count)), channels: old.channels, sampleRate: old.sampleRate))
        #expect(old.sourceDurationMilliseconds == nil)
        let replacement = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        #expect(replacement.startFrame == 0 && replacement.sampleRate == 48000 && replacement.sourceDurationMilliseconds == 8000)
        #expect(replacement.sourceSeekable == true)
        #expect(try await collect(replacement) == baseline("tone.wav"))
        await replacement.cancel()
    }

    @Test(arguments: names, [false, true])
    func seekDuringStreamingLandsAtTargetAndPlaysTail(name: String, known: Bool) async throws {
        let context = try await Context.open(name: name, known: known, proxyEnabled: true)
        defer { context.close() }
        let source = try context.source(), expected = try baseline(name)
        let old = try await source.makeDecoder() // playback in progress
        let decoder = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        // Unknown-length ADTS/FLAC streams are not seekable and restart from the beginning.
        let target = !known && (name == "tone.aac" || name == "tone.flac") ? Int64(0) : Int64(decoder.sampleRate * 4)
        #expect(abs(decoder.startFrame - target) <= Int64(decoder.sampleRate / 4))
        let actual = try await collect(decoder)
        let tail = Array(expected.dropFirst(Int(decoder.startFrame) * decoder.channels))
        #expect(sounds(actual, like: tail, name, decoder), "\(name), known=\(known): seek tail differs audibly")
        await decoder.cancel()
        withExtendedLifetime(old) {}
    }

    @Test(arguments: ["tone.wav", "tone.aac", "tone.m4a", "tone.flac"])
    func streamingPlaysBeforeDownloadCompletesAndStopsPromptly(name: String) async throws {
        let context = try await Context.open(name: name, known: false, proxyEnabled: true, heldPrefix: 32768)
        defer { context.close() }
        let source = try context.source()
        let decoder = try await source.makeDecoder()
        let first = try #require(try await decoder.next())
        let expectedStart = Array(try baseline(name).prefix(first.samples.count))
        #expect(sounds(first.samples, like: expectedStart, name, decoder))
        #expect(!context.remote.input.snapshot().completed)
        let blocked = Task { try await collect(decoder, alreadyReadFrames: Int64(first.frameCount)) }
        defer { blocked.cancel() }
        try await wait { context.remote.input.snapshot().waitingReaders > 0 }
        // Stopping while waiting for network data ends without hanging.
        await decoder.cancel()
        await #expect(throws: CancellationError.self) { try await blocked.value }
        withExtendedLifetime(source) {}
    }

    @Test func seekIntoLiveStreamPlaysNewFiniteResponseAndLaterSeeksOffline() async throws {
        let live = try Data(contentsOf: Self.fixture("tone.aac")), recorded = try Data(contentsOf: Self.fixture("tone.wav"))
        let starts = Mutex(0), credentials = FeedCredentials(username: "period", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                guard offset < recorded.count else { return .init(status: 416, headers: ["Content-Range": "bytes */\(recorded.count)"], body: Data()) }
                return .init(status: 206, headers: ["ETag": "\"recorded\"", "Content-Range": "bytes \(offset)-\(recorded.count - 1)/\(recorded.count)"], body: Data(recorded.dropFirst(offset)))
            }
            let first = starts.withLock { $0 += 1; return $0 == 1 }
            return .init(headers: ["Content-Type": "application/octet-stream", "ETag": first ? "\"live\"" : "\"recorded\""],
                body: first ? Data(live.prefix(32768)) : recorded, keepConnectionOpen: first, includeAutomaticContentLength: !first)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("native-period-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SharedStreamingCache(directory: root), url = URL(string: "http://period.invalid/audio")!
        let proxy = PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!)
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let first = try await source.makeDecoder()
        #expect(first.sourceDurationMilliseconds == nil && first.sourceSeekable == false)
        let replacement = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        #expect(replacement.startFrame == 0 && replacement.sourceDurationMilliseconds == 8000 && replacement.sourceSeekable == true)
        let expected = try baseline("tone.wav")
        #expect(try await collect(replacement) == expected)
        await replacement.cancel()
        server.stop()
        let seek = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        #expect(abs(seek.startFrame - 192000) <= quarterSecond)
        #expect(try await collect(seek) == Array(expected.dropFirst(Int(seek.startFrame))))
        await seek.cancel()
    }

    @Test(arguments: [127, 4096], [false, true])
    func seeksLandNearTargetAndPastEndPlaysNothing(capacity: Int, proxyEnabled: Bool) async throws {
        let context = try await Context.open(name: "tone.wav", known: true, proxyEnabled: proxyEnabled)
        defer { context.close() }
        let source = try context.source(maximumFrames: capacity), expected = try baseline("tone.wav")
        let initial = try await source.makeDecoder()
        #expect(try await collect(initial) == expected)
        await initial.cancel()
        context.server.stop()
        // Targets in 96 kHz ticks: start, just after start, ~4 s, 4 s, just before end, past end.
        for ticks: Int64 in [0, 1, 384034, 384000, 767999, 960001, 0] {
            let target = CMTime(value: ticks, timescale: 96000), targetFrame = ticks / 2
            let decoder = try await source.makeDecoder(start: target)
            let actual = try await collect(decoder)
            if targetFrame < 360000 {
                #expect(abs(decoder.startFrame - targetFrame) <= quarterSecond, "target \(ticks)")
                #expect(actual == Array(expected.dropFirst(Int(decoder.startFrame))), "target \(ticks)")
            } else {
                #expect(actual.count <= Int(quarterSecond), "target \(ticks): audio after end")
            }
            await decoder.cancel()
        }
    }

    @MainActor @Test func pausedSessionAfterSeekShowsTargetPosition() async throws {
        let context = try await Context.open(name: "tone.wav", known: true, proxyEnabled: false)
        defer { context.close() }
        let source = try context.source()
        let initial = try await source.makeDecoder()
        _ = try await collect(initial); await initial.cancel()
        let decoder = try await source.makeDecoder(start: CMTime(value: 192017, timescale: 48000))
        let transport = Transport()
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: 1, maximumOutputFrames: 127)
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare()
        #expect(session.state == .paused && !transport.playing)
        let position = try #require(try session.mediaMicroseconds)
        #expect(abs(position - 4_000_354) <= 250_000)
    }

    @Test(arguments: ["tone.aac", "tone.m4a"], [false, true])
    func seekAfterHistoryReleasedStillPlaysOffline(name: String, proxyEnabled: Bool) async throws {
        let context = try await Context.open(name: name, known: true, proxyEnabled: proxyEnabled)
        defer { context.close() }
        let source = try context.source(), expected = try baseline(name)
        let initial = try await source.makeDecoder()
        _ = try await collect(initial)
        try await initial.updatePlayback(.init(positionMicroseconds: 304000000, speed: 1))
        await initial.cancel()
        context.server.stop()
        let requests = context.server.requests.count
        let target = CMTime(value: 192017, timescale: 48000)
        let decoder = try await source.makeDecoder(start: target)
        #expect(abs(CMTimeGetSeconds(decoder.startTime) - CMTimeGetSeconds(target)) <= 0.25)
        let actual = try await collect(decoder)
        let tail: [Int16]
        if name == "tone.aac" {
            // ADTS CBR seeking (as on Android) resynchronizes at the frame
            // boundary the byte map selects; the audio heard is that suffix.
            let bytes = try Data(contentsOf: Self.fixture(name))
            var offset = 0
            while offset < 33286 {
                try #require(offset + 7 <= bytes.count && bytes[offset] == 0xff)
                let length = Int(bytes[offset + 3] & 3) << 11 | Int(bytes[offset + 4]) << 3 | Int(bytes[offset + 5] >> 5)
                try #require(length >= 7 && offset + length <= bytes.count)
                offset += length
            }
            let suffix = context.root.appendingPathComponent("fallback-source.aac")
            try Data(bytes.dropFirst(offset)).write(to: suffix)
            tail = try baseline(suffix)
        } else { tail = Array(expected.dropFirst(Int(decoder.startFrame))) }
        #expect(sounds(actual, like: tail, name, decoder))
        await decoder.cancel()
        #expect(context.server.requests.count == requests)
    }

    private final class DisconnectCounter: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func increment() { value.withLock { $0 += 1 } }
    }
    @MainActor private final class Transport: PCMPresentationTransport {
        var currentTime = CMTime.zero
        var onTimeChanged: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        var playing = false
        func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {}
        func setPlaying(_ value: Bool, at time: CMTime) { playing = value; currentTime = time }
        func observeEnd(_ time: CMTime) {}
        func finishEnqueuing() {}
        func stopMonitoring() {}
        func close() { playing = false }
    }
    private struct Context: Sendable {
        let server: LoopbackHTTPServer, remote: PCMRemoteInput, cache: SharedStreamingCache
        let root: URL, url: URL, proxy: PodcastProxy, credentials: FeedCredentials
        let disconnected: DisconnectCounter
        func source(maximumFrames: Int = 4096) throws -> NativeAudioPlaybackSource {
            try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache, maximumFrames: maximumFrames)
        }
        func close() {
            remote.input.cancel(); remote.relay.cancel(); server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        static func open(name: String, known: Bool, proxyEnabled: Bool, heldPrefix: Int? = nil) async throws -> Context {
            let bytes = try Data(contentsOf: fixture(name)), credentials = FeedCredentials(username: "source", password: "captured")
            let disconnected = DisconnectCounter()
            let server = try await LoopbackHTTPServer.start(onClientDisconnect: { disconnected.increment() }) { request in
                #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
                if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                    #expect(request.headers["if-range"] == "\"source\"")
                    guard offset < bytes.count else { return .init(status: 416, headers: ["Content-Range": "bytes */\(bytes.count)"], body: Data()) }
                    return .init(status: 206, headers: ["ETag": "\"source\"", "Content-Range": "bytes \(offset)-\(bytes.count - 1)/\(bytes.count)"], body: Data(bytes.dropFirst(offset)))
                }
                return .init(headers: ["Content-Type": "application/octet-stream", "ETag": "\"source\""],
                    body: heldPrefix.map { Data(bytes.prefix($0)) } ?? bytes, keepConnectionOpen: heldPrefix != nil, includeAutomaticContentLength: known)
            }
            let root = URL.temporaryDirectory.appendingPathComponent("native-source-\(UUID())")
            let url = proxyEnabled ? URL(string: "http://source.invalid/wrong.mp3")! : server.url.appendingPathComponent("wrong.mp3")
            let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
            do {
                let cache = try SharedStreamingCache(directory: root)
                let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
                return Context(server: server, remote: remote, cache: cache, root: root, url: url, proxy: proxy,
                    credentials: credentials, disconnected: disconnected)
            } catch { server.stop(); try? FileManager.default.removeItem(at: root); throw error }
        }
    }
}
private final class NativeSourceFixtures: NSObject {}

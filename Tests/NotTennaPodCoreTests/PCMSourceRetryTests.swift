import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite struct PCMSourceRetryTests {
    @Test func sourceDelayAndProgressResetRemainSeparateFromErrorThreshold() throws {
        let retry = PCMSourceRetry(), error = URLError(.networkConnectionLost)
        retry.recordSamples(100, durationKnown: true)
        #expect(try (1...4).map { _ in try retry.plan(for: error, lengthKnown: true)?.delayMilliseconds } == [0,1000,2000,3000])
        #expect(retry.currentError != nil && retry.snapshot.errorCount == 4)
        retry.recordSamples(1, durationKnown: true)
        #expect(retry.currentError == nil)
        #expect(try retry.plan(for: error, lengthKnown: true)?.delayMilliseconds == 4000)
        #expect(retry.snapshot.errorCount == 1)
        #expect(try retry.plan(for: error, lengthKnown: true)?.delayMilliseconds == 1000)
        for _ in 0..<10 { _ = try retry.plan(for: error, lengthKnown: true) }
        #expect(try retry.plan(for: error, lengthKnown: true)?.delayMilliseconds == 5000)
    }
    @Test func replayedPacketsDoNotClearAnErrorOrResetTheLoadRetryBudget() throws {
        let retry = PCMSourceRetry(), error = URLError(.networkConnectionLost)
        retry.recordSamples(100, durationKnown: true, extractedThrough: 100)
        for _ in 0..<4 { _ = try retry.plan(for: error, lengthKnown: true) }
        retry.recordSamples(50, durationKnown: false, extractedThrough: 50)
        retry.recordSamples(50, durationKnown: true, extractedThrough: 100)
        #expect(retry.snapshot.extractedSamples == 100 && retry.snapshot.durationKnown && retry.currentError != nil)
        #expect(try retry.plan(for: error, lengthKnown: true)?.delayMilliseconds == 4000)
        #expect(retry.snapshot.errorCount == 5)
        retry.recordSamples(50, durationKnown: true, extractedThrough: 125)
        #expect(retry.snapshot.extractedSamples == 125 && retry.currentError == nil)
        #expect(try retry.plan(for: error, lengthKnown: true)?.delayMilliseconds == 5000)
        #expect(retry.snapshot.errorCount == 1)
    }
    @Test func wrappedFatalCausesAreNotHiddenByOuterNetworkErrors() throws {
        let nativeNetwork = NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "kCFErrorDomainCFNetwork", code: URLError.networkConnectionLost.rawValue)])
        #expect(try PCMSourceRetry().plan(for: nativeNetwork, lengthKnown: true)?.delayMilliseconds == 0)
        let missing = CocoaError(.fileReadNoSuchFile)
        let wrapped = NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue,
            userInfo: [NSUnderlyingErrorKey: missing])
        #expect(try PCMSourceRetry().plan(for: wrapped, lengthKnown: true) == nil)
        #expect(try PCMSourceRetry().plan(for: URLError(.appTransportSecurityRequiresSecureConnection), lengthKnown: true) == nil)
        #expect(try PCMSourceRetry().plan(for: MediaDownloadError.httpStatus(416), lengthKnown: true) == nil)
        for status in [401,404,429,500,503] {
            #expect(try PCMSourceRetry().plan(for: MediaDownloadError.httpStatus(status), lengthKnown: true)?.delayMilliseconds == 0)
        }
    }
}

@MainActor @Suite(.serialized) struct PCMFiniteRetryTests {
    private func fixture() -> URL {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
#else
        Bundle(for: RetryFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3")!
#endif
    }
    private func wait(_ condition: () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = ContinuousClock.now + .seconds(8)
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < end
        try #require(try await condition(), sourceLocation: sourceLocation)
    }
    private func drain(_ decoder: any PCMDecoding) async throws -> [Int16] {
        var samples: [Int16] = []
        do {
            while let packet = try await decoder.next() { samples += packet.samples }
            await decoder.cancel(); return samples
        } catch { await decoder.cancel(); throw error }
    }
    private func read(_ input: any MediaByteInput) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try input.read(at: 0, maximumCount: 4096) }) }
        }
    }
    @Test(arguments: [false, true])
    func interruptedMP3ResumesCapturedRangeAndPreservesEverySample(proxyEnabled: Bool) async throws {
        try await interruptedMP3(proxyEnabled: proxyEnabled, initialLengthKnown: true)
    }
    /// Waits for the real eight-second upstream idle failure; the proxy resume path is covered
    /// without that wait by interruptedMP3ResumesCapturedRangeAndPreservesEverySample(proxyEnabled: true).
    @Test func knownDurationWithoutHTTPLengthResumesAndCachesResolvedRange() async throws {
        try await interruptedMP3(proxyEnabled: false, initialLengthKnown: false)
    }
    private func interruptedMP3(proxyEnabled: Bool, initialLengthKnown: Bool) async throws {
        let media = try Data(contentsOf: fixture()), counter = RetryCounter()
        let credentials = FeedCredentials(username: "retry", password: "captured")
        let split = media.count / 2
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if counter.next() == 1 {
                if initialLengthKnown {
                    return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(media.count), "ETag": "\"same\""], body: Data(media.prefix(split)), keepConnectionOpen: true)
                }
                return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked", "ETag": "\"same\""],
                    body: Data("\(String(split, radix: 16))\r\n".utf8) + Data(media.prefix(split)) + Data("\r\n".utf8), keepConnectionOpen: true)
            }
            // Resumption must be validated against the same file; the exact offset is not asserted.
            #expect(request.headers["if-range"] == "\"same\"")
            let begin = request.headers["range"].flatMap { Int($0.dropFirst(6).split(separator: "-").first ?? "") } ?? 0
            return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"same\"",
                "Content-Range": "bytes \(begin)-\(media.count-1)/\(media.count)"], body: Data(media.dropFirst(begin)))
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://retry.invalid/audio.mp3")! : server.url
        let source = NativeMP3PlaybackSource(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let decoder = try await source.makeDecoder(prepareSourceTimeline: true)
        try await wait { await source.networkSnapshot?.cachedRanges.contains(0..<Int64(split)) == true }
        if initialLengthKnown { try await server.appendResponseBody(Data(), isFinal: true) }
        else {
            // Preserve the actual8s upstream idle interruption. Xing metadata
            // already declares duration, so this must resume, never reset at0.
            #expect((decoder.bufferState?.snapshot.durationMicroseconds ?? 0) > 29_000_000)
        }
        // The interrupted stream resumes and the whole episode is heard, nothing lost.
        let actual = try await drain(decoder)
        let baseline = try NativePCMDecoder(url: fixture())
        PCMTestFixture.expectAudiblyEquivalent(actual, try await drain(baseline), channels: 1, sampleRate: 44_100)
        #expect(server.requests.count == 2)
        #expect((await source.networkSnapshot)?.failure == nil)
    }
    // Each case waits for the real eight-second upstream idle failure, so the proxy dimension is
    // covered once per behaviour rather than crossed with every case.
    @Test func pausedCachedSeekPreservesPendingRetryProgressAndLaterRecovery() async throws {
        try await pausedSeek(proxyEnabled: true, outsideBuffer: false)
    }
    @Test(arguments: [false, true])
    func pausedOutsideBufferSeekStartsFreshLoadAndRetryBudget(cancelReplacement: Bool) async throws {
        try await pausedSeek(proxyEnabled: false, outsideBuffer: true, cancelReplacement: cancelReplacement)
    }
    @Test func seekPastFullyLoadedAudioDoesNotRestartItsLoad() async throws {
        let media = try Data(contentsOf: fixture())
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg"], body: media)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("completed-seek-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory), retry = PCMSourceRetry()
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy(), cache: cache, retry: retry)
        let first = try await source.makeDecoder(prepareSourceTimeline: true)
        #expect(!(try await drain(first)).isEmpty)
        let next = try await source.makeDecoder(start: CMTime(value: 35, timescale: 1), prepareSourceTimeline: true)
        #expect(try await next.next() == nil)
        #expect(next.startTime == CMTime(value: 35, timescale: 1))
        #expect((await source.networkSnapshot)?.received == Int64(media.count) && server.requests.count == 1)
        await next.cancel()
    }
    @Test(arguments: [false, true])
    func beyondDurationEndsWithoutLoadingAndBackwardSeekRestoresIntent(playing: Bool) async throws {
        let media = try Data(contentsOf: fixture()), counter = RetryCounter()
        let server = try await LoopbackHTTPServer.start { request in
            let first = counter.next() == 1
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg",
                    "Content-Range": "bytes \(start)-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(start)))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(media.count)"],
                body: first ? Data(media.prefix(8192)) : media, keepConnectionOpen: first)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("end-intent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "End", episodes: [
            .init(identifier: "end", title: "Episode", media: .init(url: server.url.absoluteString, size: 0, durationMilliseconds: 30000))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        var outputs: [RetryTransport] = []
        var ended = 0
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), makeFactory: {
            try PCMRecoveryFactory(mp3URL: $0, proxy: PodcastProxy(), makeTransport: {
                let output = RetryTransport(); outputs.append(output); return output
            })
        }, positionTicker: PCMPlaybackEngineTests.Ticker())
        defer { engine.unload() }
        engine.bindStatistics(lastPlayed: { _ in 0 }, synchronize: { _ in })
        engine.onEvent = { if case .ended = $0 { ended += 1 } }
        let generation = UUID()
        engine.load(episode: try #require(try await store.episode(id: 1)), generation: generation, positionMilliseconds: 0)
        try await wait { engine.reading?.isPrepared == true }
        try engine.setSpeed(1.5, commandID: UUID())
        if playing { engine.play(commandID: UUID()) }
        engine.seek(to: 35000, commandID: UUID())
        try await wait { ended == 1 }
        #expect(server.requests.count == 1 && outputs.count == 2)
        #expect(outputs[0].closed && outputs[1].bytes.isEmpty && !outputs[1].playing)
        #expect(engine.reading?.sample.positionMilliseconds == 35000)
        #expect(engine.reading?.generation == generation && engine.reading?.speed == 1.5)
        engine.seek(to: 2000, commandID: UUID())
        try await wait { outputs.count == 3 && !outputs[2].bytes.isEmpty && engine.reading?.buffering == false }
        #expect(engine.reading?.generation == generation && engine.reading?.speed == 1.5)
        #expect(engine.reading?.sample.status == (playing ? .playing : .paused))
        #expect(outputs[1].closed && outputs[2].playing == playing)
        #expect(ended == 1 && server.requests.count == 2)
        engine.unload(); try await store.close()
    }
    private func pausedSeek(proxyEnabled: Bool, outsideBuffer: Bool, cancelReplacement: Bool = false) async throws {
        let audio = try Data(contentsOf: fixture()), counter = RetryCounter()
        let tag = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 1, 28, 32]) + Data(repeating: 0, count: 20_000)
        let media = tag + audio, split = tag.count + audio.count / 2
        let credentials = FeedCredentials(username: "seek", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let attempt = counter.next()
            if attempt == 1 {
                return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(media.count), "ETag": "\"stable\""],
                    body: Data(media.prefix(split)), keepConnectionOpen: true)
            }
            guard let begin = Int(request.headers["range"]?.dropFirst(6).split(separator: "-").first ?? ""),
                  (0..<media.count).contains(begin) else {
                Issue.record("Expected a valid range request"); return nil
            }
            // A fresh retry budget still belongs to the same prepared media.
            #expect(request.headers["if-range"] == "\"stable\"")
            if attempt <= (outsideBuffer ? 5 : 4) { return .init(status: 503, headers: ["Content-Type": "audio/mpeg"]) }
            return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"stable\"",
                "Content-Range": "bytes \(begin)-\(media.count-1)/\(media.count)"], body: Data(media.dropFirst(begin)))
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cached-seek-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory.appendingPathComponent("cache"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://seek.invalid/audio.mp3")! : server.url
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Seek", episodes: [
            .init(identifier: "seek", title: "Episode", media: .init(url: url.absoluteString, size: 0, durationMilliseconds: 30000))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let gate = RetryGate(); defer { gate.cancelAll() }
        let retry = PCMSourceRetry(sleep: gate.sleep)
        var outputs: [RetryTransport] = []
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), makeFactory: {
            try PCMRecoveryFactory(mp3URL: $0, proxy: proxy, credentials: credentials, cache: cache, retry: retry, makeTransport: {
                let output = RetryTransport(); outputs.append(output); return output
            })
        }, positionTicker: PCMPlaybackEngineTests.Ticker(), now: { 5000 })
        defer { engine.unload() }
        let player = PlaybackCoordinator(store: store, engine: engine, clock: { Date(timeIntervalSince1970: 5) })
        try await player.select(episodeID: 1, play: false)
        try await wait { player.phase == .paused || player.phase == .failed }
        try #require(player.phase == .paused && outputs.count == 1)
        let generation = try #require(engine.reading?.generation)
        try await player.setSpeed(1.5)
        // The connection drops halfway; drive the network retries while paused.
        let deadline = ContinuousClock.now + .seconds(12)
        while gate.waiting == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(gate.waiting == 1)
        for attempt in 2...4 {
            gate.advance()
            try await wait { gate.waiting == 1 && server.requests.count == attempt }
        }
        try #require(retry.currentError != nil)
        let target: Int64 = outsideBuffer ? 20000 : 4000
        try await player.seek(to: target)
        if outsideBuffer {
            // Seeking past the downloaded part starts a new load with its own retries.
            try await wait { player.phase == .failed || (server.requests.count == 5 && gate.waiting == 1) }
            try #require(player.phase != .failed)
            if cancelReplacement {
                engine.unload()
                try await wait { gate.waiting == 0 }
                #expect(outputs.count == 1 && outputs[0].closed && engine.reading == nil)
                try await store.close()
                return
            }
            gate.advance()
        }
        try await wait { player.phase == .failed || (outputs.count == 2 && engine.reading?.buffering == false) }
        // The paused seek lands where requested, keeps the speed and stays paused.
        try #require(player.phase == .paused && outputs.count == 2)
        #expect((target...(target + 250)).contains(Int64(engine.reading?.sample.positionMilliseconds ?? -1)))
        #expect(engine.reading?.generation == generation && engine.reading?.speed == 1.5)
        #expect(outputs[0].closed && !outputs[1].playing)
        if !outsideBuffer {
            #expect(gate.waiting == 1)
            gate.advance()
            try await wait { retry.currentError == nil }
        }
        #expect(player.phase == .paused && !outputs[1].playing)
        // Once the network recovers, playback continues past the original interruption.
        try await player.play()
        try await wait {
            outputs[1].advance(frame: Int64(outputs[1].bytes.count / 2))
            return (engine.reading?.sample.positionMilliseconds ?? 0) >= 18000
        }
        try await player.pause()
        let saved = try #require(try await store.episode(id: 1)?.userState.positionMilliseconds)
        #expect(saved >= 18000 && engine.reading?.generation == generation)
        engine.unload(); try await store.close()
        let reopened = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        #expect(try await reopened.episode(id: 1)?.userState.positionMilliseconds == saved)
        try await reopened.close()
    }
    // Eight-second idle wait per case: each value of each dimension once instead of the 2×2 grid.
    @Test(arguments: [(false, true), (true, false)])
    func unpreparedRetryReplacesPartialTagAndParser(proxyEnabled: Bool, prepareTimeline: Bool) async throws {
        try await unpreparedRetry(proxyEnabled: proxyEnabled, prepareTimeline: prepareTimeline, outcome: 0)
    }
    @Test(arguments: [false, true])
    func unpreparedRetryPreservesExhaustionAndCancellation(cancel: Bool) async throws {
        try await unpreparedRetry(proxyEnabled: false, prepareTimeline: true, outcome: cancel ? 1 : 2)
    }
    private func unpreparedRetry(proxyEnabled: Bool, prepareTimeline: Bool, outcome: Int) async throws {
        let media = try Data(contentsOf: fixture()), counter = RetryCounter()
        // A valid ID3v2.3 padding tag declares10000 bytes; the first response
        // stops inside it. The replacement starts with entirely different bytes.
        let partial = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 78, 16]) + Data(repeating: 0, count: 4990)
        let credentials = FeedCredentials(username: "unprepared", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            #expect(request.headers["range"] == nil && request.headers["if-range"] == nil)
            if counter.next() == 1 {
                return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked", "ETag": "\"old\""],
                    body: Data("1388\r\n".utf8) + partial + Data("\r\n".utf8), keepConnectionOpen: true)
            }
            if outcome == 2 { return .init(status: 503, headers: ["Content-Type": "audio/mpeg"]) }
            return .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"new\""], body: media)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unprepared-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let gate = RetryGate(); defer { gate.cancelAll() }
        let retry = PCMSourceRetry(sleep: gate.sleep)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://unprepared.invalid/audio.mp3")! : server.url
        var source: NativeMP3PlaybackSource? = NativeMP3PlaybackSource(url: url, proxy: proxy, credentials: credentials, cache: cache, retry: retry)
        let opening = Task { try await #require(source).makeDecoder(prepareSourceTimeline: prepareTimeline) }
        defer { opening.cancel() }
        let deadline = ContinuousClock.now + .seconds(12)
        while gate.waiting == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(gate.waiting == 1)
        #expect(server.requests.count == 1)
        if outcome == 1 {
            opening.cancel()
            await #expect(throws: CancellationError.self) { try await opening.value }
            source = nil
            try await wait { gate.waiting == 0 }
            #expect(server.requests.count == 1 && gate.delays == [0])
            return
        }
        gate.advance()
        if outcome == 2 {
            for attempt in 2...3 {
                try await wait { gate.waiting == 1 && server.requests.count == attempt }
                gate.advance()
            }
            await #expect(throws: MediaDownloadError.httpStatus(503)) { try await opening.value }
            #expect(server.requests.count == 4 && gate.delays == [0,1000,2000])
            return
        }
        let decoder = try await opening.value
        #expect(decoder.startTime == .zero)
        // The retried response replaces the partial first one: the full episode plays.
        let actual = try await drain(decoder)
        PCMTestFixture.expectAudiblyEquivalent(actual, try await drain(NativePCMDecoder(url: fixture())),
            channels: 1, sampleRate: 44_100)
        #expect(server.requests.count == 2 && gate.delays == [0])
        #expect(retry.currentError == nil)
    }
    @Test func unavailableHeadersUseThreeRetriesThenReportOriginalError() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(status: 503, headers: ["Content-Type": "audio/mpeg"]) }
        defer { server.stop() }
        let clock = RetryGate(); defer { clock.cancelAll() }
        let retry = PCMSourceRetry(sleep: clock.sleep)
        let input = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: 65536,
            backing: .memory(capacity: 131072), retry: retry)
        defer { input.cancel() }
        let task = Task { try await read(input) }; defer { task.cancel() }
        for attempt in 1...3 {
            try await wait { clock.waiting == 1 && server.requests.count == attempt }
            clock.advance()
        }
        await #expect(throws: MediaDownloadError.httpStatus(503)) { try await task.value }
        #expect(server.requests.count == 4 && clock.delays == [0,1000,2000])
        #expect(retry.snapshot.errorCount == 4 && input.snapshot().failure != nil)
    }
    @Test(arguments: [false, true], [(Float(1), false), (Float(1.5), false), (Float(1.5), true)])
    func bufferedAudioOutlivesThresholdAndLateRecoveryPreservesPause(recover: Bool, processing: (Float, Bool)) async throws {
        let media = try Data(contentsOf: fixture()), split = media.count / 2, counter = RetryCounter()
        let server = try await LoopbackHTTPServer.start { request in
            let attempt = counter.next()
            if attempt == 1 {
                return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(media.count), "ETag": "\"same\""], body: Data(media.prefix(split)), keepConnectionOpen: true)
            }
            let begin = request.headers["range"].flatMap { Int($0.dropFirst(6).split(separator: "-").first ?? "") } ?? 0
            return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "Content-Length": String(media.count - begin),
                "Content-Range": "bytes \(begin)-\(media.count-1)/\(media.count)", "ETag": "\"same\""],
                body: recover && attempt >= 5 ? Data(media.dropFirst(begin)) : Data())
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("buffered-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let gate = RetryGate(); defer { gate.cancelAll() }
        let retry = PCMSourceRetry(sleep: gate.sleep)
        var source: NativeMP3PlaybackSource? = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy(), cache: cache, retry: retry)
        let decoder = try await #require(source).makeDecoder(prepareSourceTimeline: true)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: processing.1, speed: processing.0, maximumOutputFrames: 4096)
        let transport = RetryTransport()
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport)
        defer { session.close() }
        try await session.prepare()
        try await wait { await source?.networkSnapshot?.cachedRanges.contains(0..<Int64(split)) == true }
        try await server.appendResponseBody(Data(), isFinal: true)
        try await wait { gate.waiting == 1 }
        for attempts in 2...4 {
            gate.advance()
            try await wait { server.requests.count == attempts && gate.waiting == 1 }
        }
        #expect(gate.delays == [0,1000,2000,3000])
        #expect(retry.currentError != nil && retry.snapshot.errorCount == 4)
        let reportableError = try #require(retry.currentError) as NSError
        #expect(session.failure == nil && !session.wantsPlayback && !transport.playing)
        if recover {
            gate.advance()
            try await wait { retry.currentError == nil && cache.snapshot(for: server.url).committedBytes == media.count }
            #expect(session.failure == nil && !session.wantsPlayback && !transport.playing)
        }
        try session.play()
        let deadline = ContinuousClock.now + .seconds(8)
        while session.failure == nil && session.state != .ended && ContinuousClock.now < deadline {
            transport.advance(frame: session.writtenFrames)
            try await Task.sleep(for: .milliseconds(2))
        }
        if recover {
            #expect(session.state == .ended && session.failure == nil)
            #expect(try #require(try session.mediaMicroseconds) >= 29_000_000)
            #expect(server.requests.count == 5)
        } else {
            #expect(session.failure != nil && !session.sourceEnded)
            #expect((try #require(session.failure) as NSError).isEqual(reportableError))
            #expect(try #require(try session.mediaMicroseconds) >= 14_000_000)
            #expect(session.presentedFrames == session.writtenFrames)
        }
        // Every available packet, including codec/filter tails, is compared with
        // independent file decoding. A full recording's cut PCM prefix is not an
        // EOF oracle: its final synthesis samples depend on subsequent packets.
        let referenceURL = recover ? fixture() : try prefixOracle(media, directory: directory)
        let input = try await drain(NativePCMDecoder(url: referenceURL))
        let expected = try processed(input, speed: processing.0, skipSilence: processing.1)
        PCMTestFixture.expectAudiblyEquivalent(transport.bytes, expected, channels: 1, sampleRate: 44_100)
        session.close(); source = nil
        try await wait { gate.waiting == 0 }
    }
    private func prefixOracle(_ media: Data, directory: URL) throws -> URL {
        // ffprobe independently establishes 572 complete packets ending at59905.
        // Only non-audio Xing/LAME length fields change; all572 packet hashes
        // match the original. Keep576 priming
        // and clear original end padding, which is not part of this prefix.
        try #require(media.count == 120_017 && String(decoding: media[21..<25], as: UTF8.self) == "Xing")
        var prefix = Data(media.prefix(59_905))
        prefix.replaceSubrange(29..<33, with: [0, 0, 2, 60])
        prefix.replaceSubrange(33..<37, with: [0, 0, 234, 1])
        prefix[163] &= 0xf0; prefix[164] = 0
        let url = directory.appendingPathComponent("finite-prefix.mp3")
        try prefix.write(to: url)
        return url
    }
    private func processed(_ input: [Int16], speed: Float, skipSilence: Bool) throws -> Data {
        var silence = skipSilence ? try SilenceSkippingProcessor(sampleRate: 44100, channels: 1) : nil
        var rate = speed == 1 ? nil : try PCMSpeedProcessor(sampleRate: 44100, channels: 1, speed: speed)
        var samples: [Int16] = []
        for offset in stride(from: 0, to: input.count, by: 4096) {
            let packet = Array(input[offset..<min(input.count, offset + 4096)])
            let quiet = try silence?.process(packet) ?? packet
            samples += try rate?.process(quiet) ?? quiet
        }
        let tail = silence?.finish() ?? []
        samples += try rate?.process(tail) ?? tail
        samples += rate?.finish() ?? []
        return samples.withUnsafeBytes { Data($0) }
    }
}

@MainActor private final class RetryTransport: PCMPresentationTransport {
    var currentTime = CMTime.zero
    var onTimeChanged: (@MainActor () -> Void)?
    var onFailure: (@MainActor (any Error) -> Void)?
    var playing = false, closed = false
    var bytes = Data()
    func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {
        bytes.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) }))
    }
    func flush(at time: CMTime) { currentTime = time }
    func setPlaying(_ playing: Bool, at time: CMTime) { self.playing = playing; currentTime = time }
    func observeEnd(_ time: CMTime) {}
    func finishEnqueuing() {}
    func stopMonitoring() {}
    func close() { playing = false; closed = true }
    func advance(frame: Int64) { currentTime = CMTime(value: frame, timescale: 44100); onTimeChanged?() }
}
private final class RetryCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
private final class RetryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var cancelled: Set<UUID> = []
    private var history: [Int64] = []
    var delays: [Int64] { lock.withLock { history } }
    var waiting: Int { lock.withLock { held.count } }
    func sleep(_ milliseconds: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelled.remove(id) != nil { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                history.append(milliseconds); held.append((id, continuation))
                lock.unlock()
            }
        } onCancel: { self.cancel(id) }
    }
    func advance() {
        let next = lock.withLock { held.isEmpty ? nil : held.removeFirst().1 }
        next?.resume()
    }
    private func cancel(_ id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard let index = held.firstIndex(where: { $0.0 == id }) else { cancelled.insert(id); return nil }
            return held.remove(at: index).1
        }
        continuation?.resume(throwing: CancellationError())
    }
    func cancelAll() {
        let pending = lock.withLock { let values = held; held.removeAll(); return values }
        for (_, continuation) in pending { continuation.resume(throwing: CancellationError()) }
    }
}
private final class RetryFixtures: NSObject {}

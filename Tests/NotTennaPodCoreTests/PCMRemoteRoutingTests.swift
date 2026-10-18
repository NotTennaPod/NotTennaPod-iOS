import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct PCMRemoteRoutingTests {
    nonisolated static let names = ["playback-30sec.mp3", "padded.mp3", "tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm",
        "tone.wav", "tone.flac", "tone.aac", "tone.m4a", "tone-tail.m4a", "variable.flac", "variable-table.flac"]
    private func fixture(_ requested: String) throws -> URL {
        let name = requested == "padded.mp3" ? "playback-30sec.mp3" : requested
        let variableFLAC = name.hasPrefix("variable")
#if SWIFT_PACKAGE
        return try #require(Bundle.module.url(forResource: name, withExtension: nil,
            subdirectory: name.hasPrefix("playback") ? "Fixtures" : variableFLAC ? "Fixtures/FLACVariants" : "Fixtures/StreamingFormats"))
#else
        return try #require(Bundle(for: RemoteRoutingFixtures.self).url(forResource: name, withExtension: nil,
            subdirectory: variableFLAC ? "FLACVariants" : nil))
#endif
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    private struct Reference { let samples: [Int16]?; let frames: Int; let channels: Int; let sampleRate: Int }
    private func expected(_ name: String) async throws -> Reference {
        // The native reference decoder cannot read Opus/Vorbis; those 8 s, 48 kHz tone
        // fixtures are checked for complete duration and audible content only.
        if name == "tone-vorbis.ogg" { return .init(samples: nil, frames: 384_000, channels: 2, sampleRate: 48_000) }
        if name.contains("opus") { return .init(samples: nil, frames: 384_648, channels: 1, sampleRate: 48_000) }
        let decoder = try NativePCMDecoder(url: fixture(name))
        var result: [Int16] = []
        while let packet = try await decoder.next() { result += packet.samples }
        await decoder.cancel()
        return .init(samples: result, frames: result.count / decoder.channels, channels: decoder.channels,
                     sampleRate: decoder.sampleRate)
    }
    /// Complete audible playback: same duration (within 50 ms) and loudness envelope as an
    /// independent local decode; not a sample-identical or hashed comparison.
    private func expectAudio(_ actual: Data, matches reference: Reference, sourceLocation: SourceLocation = #_sourceLocation) {
        let samples = PCMTestFixture.samples(actual)
        if let expected = reference.samples {
            PCMTestFixture.expectAudiblyEquivalent(samples, expected, channels: reference.channels,
                sampleRate: reference.sampleRate, sourceLocation: sourceLocation)
        } else {
            PCMTestFixture.expectAudibleDuration(samples, expectedFrames: reference.frames, channels: reference.channels,
                sampleRate: reference.sampleRate, sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: [Float(0.5), 1.5, 2], [false, true])
    func capturedNativeProcessingRebuildUsesSavedSourceOffline(speed: Float, proxyEnabled: Bool) async throws {
        let (file, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let root = URL.temporaryDirectory.appendingPathComponent("native-processing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: file)
        let credentials = FeedCredentials(username: "native", password: "processing")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "application/octet-stream", "ETag": "\"quiet\""], body: bytes)
        }
        defer { server.stop() }
        let url = proxyEnabled ? URL(string: "http://native-processing.invalid/wrong.mp3")! : server.url
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let owner = PCMPlaybackFactory(cacheDirectory: root, makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let factory = try await owner.make(.remote(url, proxy: proxy, credentials: credentials))
        #expect(factory.providesSourceDuration)
        for processed in [false, true] {
            if processed { server.stop() }
            let parameters = PCMRecoverySession.Parameters(speed: processed ? speed : 1, skipSilence: processed)
            let independent = try LocalPCMPlaybackStream(url: file, skipSilence: parameters.skipSilence,
                speed: parameters.speed)
            var expected: [Int16] = []
            while let samples = try await independent.next() { expected += samples }
            await independent.cancel()
            let session = try await factory.make(positionMilliseconds: 0, parameters: parameters)
            defer { session.close() }
            let output = try #require(outputs.last)
            #expect(session.state == .idle && output.buffers.isEmpty && !output.playing)
            try await session.prepare()
            #expect(session.state == .paused && !output.playing)
            #expect(session.sourceDurationMilliseconds == 600 && session.sourceSeekable == true)
            try session.play()
            let deadline = ContinuousClock.now + .seconds(8)
            while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
                if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
                await Task.yield()
            }
            try #require(session.state == .ended && session.failure == nil)
            var actual = Data()
            for buffer in output.buffers {
                actual.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) }))
            }
            PCMTestFixture.expectAudiblyEquivalent(PCMTestFixture.samples(actual), expected)
            if processed { #expect(actual.count < bytes.count - 44) }
            session.close()
            #expect(output.closed && !output.playing)
        }
        #expect(server.requests.count == 1 && outputs.count == 2)
    }

    // Configurations: direct/proxy crossed with declared/unknown length.
    @Test(arguments: names, [0, 1, 2, 3])
    func capturedConnectionPlaysCompleteAudioAndSavesCompletion(name: String, configuration: Int) async throws {
        let proxyEnabled = configuration & 1 != 0, unknownLength = configuration & 2 != 0
        let root = URL.temporaryDirectory.appendingPathComponent("remote-routing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var body = try Data(contentsOf: fixture(name))
        if name == "padded.mp3" {
            // A valid ID3v2.4 padding-only tag larger than the HTTP memory window.
            // Encoded audio is unchanged; identification must retain its peeked bytes.
            let size = 196_608
            let header = Data([0x49, 0x44, 0x33, 4, 0, 0] + [21, 14, 7, 0].map { UInt8((size >> $0) & 0x7f) })
            body = header + Data(repeating: 0, count: size) + body
        }
        let media = body, expected = try await expected(name)
        let credentials = FeedCredentials(username: "route", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "text/html", "ETag": "\"stable\""], body: media,
                includeAutomaticContentLength: !unknownLength)
        }
        defer { server.stop() }
        let base = proxyEnabled ? URL(string: "http://remote-routing.invalid")! : server.url
        let url = base.appendingPathComponent("wrong.wav")
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Remote", episodes: [
            .init(identifier: "one", title: "One", media: .init(url: url.absoluteString, size: 0,
                mimeType: "audio/wav", durationMilliseconds: 999000))]), source: base.appendingPathComponent("feed").absoluteString,
            responseURL: base.appendingPathComponent("feed"), validator: nil, permanentRedirectURL: nil))
        let outputs = PCMPlaybackEngineTests.Outputs()
        let owner = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("cache"), makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.values.append(output); return output
        })
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, selected in
            #expect(selected == url)
            return try await owner.make(.remote(selected, proxy: proxy, credentials: credentials))
        }, positionTicker: outputs.ticker)
        defer { engine.unload() }
        let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
            var result = PlaybackPreferences(); result.end.smartMarkAsPlayedSeconds = 0; return result
        })
        var failures: [String] = []
        let consume = engine.onEvent
        engine.onEvent = { event in
            if case .failed(_, let message) = event { failures.append(message) }
            consume?(event)
        }
        func finish() async throws {
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused || player.phase == .failed }
            try #require(player.phase == .paused, "Source failure: \(failures)")
            if !unknownLength, outputs.values.count == 1 {
                #expect(server.requests.count == 1)
                for (index, position) in [Int64(4000), 0].enumerated() {
                    try await player.seek(to: position)
                    try await wait { (outputs.values.count == index + 2 && player.phase == .paused) || player.phase == .failed }
                    try #require(player.phase == .paused, "Seek failure: \(failures)")
                }
                let retiredOutputsClosed = outputs.values.dropLast().allSatisfy { $0.closed }
                #expect(retiredOutputsClosed)
            }
            try await player.play()
            let output = try #require(outputs.values.last)
            let deadline = ContinuousClock.now + .seconds(12)
            while player.phase != .idle, player.phase != .failed, ContinuousClock.now < deadline {
                if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
                await Task.yield()
            }
            try #require(player.phase == .idle, "Completion failure: \(failures)")
            var actual = Data()
            for buffer in output.buffers { actual.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })) }
            expectAudio(actual, matches: expected)
            #expect(output.closed)
            let episode = try #require(try await store.episode(id: 1))
            #expect(episode.userState.playState == .played && episode.userState.positionMilliseconds == 0)
            #expect(try await store.queue().isEmpty)
            #expect(try await store.playbackSession() == nil)
        }
        try await finish()
        // Initial handoff is asserted before explicit seeks above. Unseeked
        // unknown-length playback must still use exactly its original request.
        if unknownLength { #expect(server.requests.count == 1) }
        if !unknownLength {
            let requestsBeforeOfflineReplay = server.requests.count
            server.stop()
            try await finish()
            #expect(server.requests.count == requestsBeforeOfflineReplay && outputs.values.count == 4)
        }
        try await store.close()
    }

    @Test func redirectHandoffStripsForeignCredentialsAndCachesOriginalIdentity() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("remote-redirect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: fixture("tone-opus.ogg"))
        let expected = try await expected("tone-opus.ogg")
        let target = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == nil)
            return .init(headers: ["Content-Type": "application/octet-stream", "ETag": "\"target\""], body: bytes)
        }
        defer { target.stop() }
        let credentials = FeedCredentials(username: "private", password: "origin-only")
        let destination = target.url.appendingPathComponent("misleading.mp3").absoluteString
        let original = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(status: 302, headers: ["Location": destination], body: Data())
        }
        defer { original.stop() }
        let outputs = PCMPlaybackEngineTests.Outputs()
        let owner = PCMPlaybackFactory(cacheDirectory: root, makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.values.append(output); return output
        })
        for attempt in 0..<2 {
            if attempt == 1 { original.stop(); target.stop() }
            let factory = try await owner.make(.remote(original.url, proxy: PodcastProxy(), credentials: credentials))
            let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
            defer { session.close() }
            let output = try #require(outputs.values.last)
            try await session.prepare(); try session.play()
            let deadline = ContinuousClock.now + .seconds(10)
            while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
                if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
                await Task.yield()
            }
            try #require(session.state == .ended && session.failure == nil)
            var actual = Data()
            for buffer in output.buffers { actual.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })) }
            expectAudio(actual, matches: expected)
        }
        #expect(original.requests.count == 1 && target.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func initialFailureAndLiveSeekReuseCapturedContext(partialPrefix: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("remote-live-seek-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: fixture("playback-unknown-duration.mp3"))
        let expected = try await expected("playback-unknown-duration.mp3")
        let credentials = FeedCredentials(username: "captured", password: "live")
        let attempts = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                if !partialPrefix { return .init(status: 503, body: Data()) }
                // Valid ID3 prefix, but the chunked transfer stalls before its tag
                // or terminal chunk. The relay read deadline triggers retry.
                let prefix = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 12, 0, 0]) + Data(repeating: 0, count: 2038)
                let wire = Data("800\r\n".utf8) + prefix + Data("\r\n".utf8)
                return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: wire, keepConnectionOpen: true)
            }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: bytes, includeAutomaticContentLength: false)
        }
        defer { server.stop() }
        let outputs = PCMPlaybackEngineTests.Outputs()
        let owner = PCMPlaybackFactory(cacheDirectory: root, makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.values.append(output); return output
        })
        let factory = try await owner.make(.remote(server.url, proxy: PodcastProxy(), credentials: credentials))
        let initial = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        try await initial.prepare(); initial.close()
        #expect(server.requests.count == 2)
        // Source policy normalizes an unseekable seek to zero and starts one new load.
        let replacement = try await factory.make(positionMilliseconds: 4000, parameters: .init(speed: 1, skipSilence: false))
        defer { replacement.close() }
        try await replacement.prepare(); try replacement.play()
        let output = try #require(outputs.values.last)
        let deadline = ContinuousClock.now + .seconds(10)
        while replacement.state != .ended, replacement.failure == nil, ContinuousClock.now < deadline {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        try #require(replacement.state == .ended && replacement.failure == nil)
        var actual = Data()
        for buffer in output.buffers { actual.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })) }
        expectAudio(actual, matches: expected)
        #expect(server.requests.count == 3 && outputs.values.first?.closed == true)
    }

    @Test func cancellationStopsAProbeWaitingForBytes() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("remote-probe-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let disconnected = Mutex(false)
        let server = try await LoopbackHTTPServer.start(onClientDisconnect: { disconnected.withLock { $0 = true } }) { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "100000"],
                body: Data([0x49, 0x44, 0x33]), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let owner = PCMPlaybackFactory(cacheDirectory: root, makeTransport: {
            Issue.record("Cancelled detection must not allocate an output")
            return SampleBufferPCMOutputTests.Transport()
        })
        let task = Task { try await owner.make(.remote(server.url, proxy: PodcastProxy())) }
        try await wait { server.sentResponseCount == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await wait { disconnected.withLock { $0 } }
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [Data(), Data("<html>not audio</html>".utf8), Data([0x4f, 0x67, 0x67]), Data([0x4f, 0x67, 0x67, 0x53, 0, 2])])
    func invalidContentFailsBeforeAllocatingOutput(bytes: Data) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("remote-probe-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: bytes) }
        defer { server.stop() }
        let owner = PCMPlaybackFactory(cacheDirectory: root, makeTransport: {
            Issue.record("Invalid detection must not allocate an output")
            return SampleBufferPCMOutputTests.Transport()
        })
        await #expect(throws: (any Error).self) {
            let factory = try await owner.make(.remote(server.url, proxy: PodcastProxy()))
            _ = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        }
        #expect(server.requests.count == 1)
    }
}
private final class RemoteRoutingFixtures: NSObject {}

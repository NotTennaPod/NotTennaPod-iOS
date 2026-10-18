import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor
struct PCMSourceSeekabilityTests {
    /// Within an imperceptible 50 ms of `target` (durations and seek anchors).
    private func near<T: BinaryInteger>(_ value: T?, _ target: T, tolerance: T = 50) -> Bool {
        guard let value else { return false }
        return value >= target - tolerance && value <= target + tolerance
    }
    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg"], [false, true])
    func unknownLengthInitialPositionAndRebuildStayAtZero(name: String, completeInitially: Bool) async throws {
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil,
            subdirectory: "Fixtures/StreamingFormats")))
        let prefix = data.count * 3 / 4
        let first = completeInitially ? data : Data(data.prefix(prefix))
        let body = Data("\(String(first.count, radix: 16))\r\n".utf8) + first
            + Data("\r\n\(completeInitially ? "0\r\n\r\n" : "")".utf8)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Transfer-Encoding": "chunked"], body: body, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let outputs = PCMPlaybackEngineTests.Outputs()
        let factory = try PCMRecoveryFactory(bufferedInput: input, maximumOutputFrames: 127,
            maximumQueuedBuffers: 2, makeTransport: {
                let output = SampleBufferPCMOutputTests.Transport()
                outputs.values.append(output); return output
            })
        let owner = PCMRecoverySession(positionMilliseconds: 4000, parameters: .init(speed: 1, skipSilence: false),
            lastPlayedMilliseconds: { 0 }, synchronizeStatistics: {}, factory: { position, parameters in
                try await factory.make(positionMilliseconds: position, parameters: parameters)
            })
        defer { owner.close() }
        try await owner.seekPaused(to: 4000)
        #expect(try owner.positionMilliseconds == 0)
        #expect(owner.sourceSeekable == false && owner.outputState == .paused)
        if !completeInitially {
            #expect(owner.sourceDurationMilliseconds == nil && !input.snapshot().completed)
            let suffix = Data(data.suffix(from: prefix))
            try await server.appendResponseBody(Data("\(String(suffix.count, radix: 16))\r\n".utf8)
                + suffix + Data("\r\n0\r\n\r\n".utf8))
        }
        try await PCMPlaybackEngineTests().wait { input.snapshot().completed && near(owner.sourceDurationMilliseconds, 8000) }
        #expect(owner.sourceSeekable == false && input.declaredLength == nil && input.length == Int64(data.count))
        try await owner.recoverPaused(to: 7990)
        #expect(try owner.positionMilliseconds == 0)
        #expect(owner.sourceSeekable == false && outputs.values.count == 2)
        #expect(outputs.values[0].closed && !outputs.values[1].playing && server.requests.count == 1)
        try owner.play()
        try await PCMPlaybackEngineTests().wait { outputs.values[1].playing }
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg"])
    func laterRangeLengthDoesNotReclassifyOriginallyUnknownOgg(name: String) async throws {
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil,
            subdirectory: "Fixtures/StreamingFormats")))
        let prefix = data.count * 3 / 4
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"],
                    body: Data(data.dropFirst(start)))
            }
            return .init(headers: ["Transfer-Encoding": "chunked"],
                body: Data("\(String(prefix, radix: 16))\r\n".utf8) + data.prefix(prefix) + Data("\r\n".utf8), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        _ = try await Task.detached { try input.read(at: 0, maximumCount: 1) }.value
        input.prepareForSeek()
        _ = try await Task.detached { try input.read(at: Int64(prefix), maximumCount: 1) }.value
        try await PCMPlaybackEngineTests().wait { input.snapshot().completed }
        #expect(input.initialDeclaredLength == nil && input.declaredLength == Int64(data.count))
        let factory = try PCMRecoveryFactory(bufferedInput: input, maximumOutputFrames: 127,
            maximumQueuedBuffers: 2, makeTransport: { SampleBufferPCMOutputTests.Transport() })
        let owner = PCMRecoverySession(positionMilliseconds: 4000, parameters: .init(speed: 1, skipSilence: false),
            lastPlayedMilliseconds: { 0 }, synchronizeStatistics: {}, factory: { position, parameters in
                try await factory.make(positionMilliseconds: position, parameters: parameters)
            })
        defer { owner.close() }
        try await owner.seekPaused(to: 4000)
        #expect(owner.sourceSeekable == false && owner.outputState == .paused)
        #expect(try owner.positionMilliseconds == 0)
        try await owner.recoverPaused(to: 7990)
        #expect(owner.sourceSeekable == false)
        #expect(try owner.positionMilliseconds == 0)
        #expect(server.requests.count == 2)
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg"], [false, true])
    func OggSeekAndPersistenceUseDeclaredLength(name: String, knownLength: Bool) async throws {
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil,
            subdirectory: "Fixtures/StreamingFormats")))
        let body = knownLength ? data : Data("\(String(data.count, radix: 16))\r\n".utf8)
            + data + Data("\r\n0\r\n\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: knownLength ? [:] : ["Transfer-Encoding": "chunked"], body: body)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episode = ParsedEpisode(identifier: "audio", title: "Audio", media: ParsedMedia(
            url: server.url.absoluteString, size: 0, durationMilliseconds: 12345))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Seekability", episodes: [episode]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
            validator: nil, permanentRedirectURL: nil))
        let outputs = PCMPlaybackEngineTests.Outputs(), clock = PCMPlaybackEngineTests.Clock()
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), makeFactory: {
            try PCMRecoveryFactory(bufferedURL: $0, makeTransport: {
                let output = SampleBufferPCMOutputTests.Transport()
                outputs.values.append(output); return output
            })
        }, positionTicker: outputs.ticker, now: { clock.now })
        let player = PlaybackCoordinator(store: store, engine: engine, clock: { clock.date })
        let helper = PCMPlaybackEngineTests()
        do {
            try await player.select(episodeID: 1, play: false)
            try await helper.wait { player.phase == .paused || player.phase == .failed }
            try #require(player.phase == .paused && outputs.values.count == 1)
            try await helper.wait { near(player.sample?.durationMilliseconds, 8000) }
            #expect(player.sample?.seekable == knownLength)
            try await player.play()
            try await helper.wait { outputs.values[0].playing }
            outputs.values[0].advance(4800)
            try await player.pause()
            #expect(player.sample?.positionMilliseconds == 100)
            // A seekable source's measured duration is saved; otherwise the feed's value is kept.
            let saved = try await store.episode(id: 1)?.details.media?.durationMilliseconds
            #expect(knownLength ? near(saved, 8000) : saved == 12345)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
            try await player.seek(to: 4000)
            // Seekable sources land at the requested 4 s; unseekable ones restart at 0.
            let anchor: Int32 = knownLength ? 4000 : 0
            try await helper.wait { outputs.values.count == 2 && engine.reading?.buffering == false
                && near(engine.reading?.sample.positionMilliseconds, anchor) }
            #expect(player.sample?.seekable == knownLength && !outputs.values[1].playing)
            #expect(outputs.values[0].closed && server.requests.count == 1)
            try await player.play()
            try await helper.wait { outputs.values[1].playing }
            try await player.stop()
            let final = try await store.episode(id: 1)?.details.media?.durationMilliseconds
            #expect(knownLength ? near(final, 8000) : final == 12345)
        } catch { engine.unload(); try? await store.close(); throw error }
        engine.unload(); try await store.close()
    }
}

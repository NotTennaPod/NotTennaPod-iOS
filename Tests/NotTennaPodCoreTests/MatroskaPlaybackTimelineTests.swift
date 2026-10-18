import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor
struct MatroskaPlaybackTimelineTests {
    private func fixture(variant: String = "original") throws -> Data {
        var data = try Data(contentsOf: #require(Bundle.module.url(forResource: "tone-opus.webm", withExtension: nil,
            subdirectory: "Fixtures/StreamingFormats")))
        if variant == "no-cue-declaration" {
            try #require(Data(data[102..<106]) == Data([0x1C, 0x53, 0xBB, 0x6B]))
            data[105] = 0x6C // Same-sized unknown SeekID; the actual Cues stay intact.
        } else if variant == "empty-cues" {
            try #require(data[86255] == 0xBB && data[86272] == 0xBB)
            data[86255] = 0xEC; data[86272] = 0xEC // Replace CuePoint elements with Void.
        } else if variant == "no-duration" {
            let field = try #require(data.range(of: Data([0x44, 0x89]), in: 0..<438))
            data[field.lowerBound + 1] = 0x88 // Unknown Info child; same bytes/offsets elsewhere.
        }
        return data
    }

    @Test func cueHTTPFailurePreservesOriginalErrorAndCreatesNoOutput() async throws {
        let data = try fixture()
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] != nil { return .init(status: 403, body: Data()) }
            return .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4),
                keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        var outputs = 0
        let factory = try PCMRecoveryFactory(bufferedInput: input,
            makeTransport: { outputs += 1; return SampleBufferPCMOutputTests.Transport() })
        await #expect(throws: MediaDownloadError.httpStatus(403)) {
            try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        }
        #expect(outputs == 0 && input.snapshot().waitingReaders == 0 && input.snapshot().activeTransfers == 0)
        #expect((input.sourceFailure?.error as? MediaDownloadError) == .httpStatus(403))
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test func cancelledMetadataLoaderIsInertBeforeFileOrHTTPUse() async throws {
        let loader = MatroskaTimelineLoader()
        loader.cancel()
        await #expect(throws: CancellationError.self) {
            try await loader.load(url: URL(fileURLWithPath: "/nonexistent/antennapod-timeline"), input: nil)
        }
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        await #expect(throws: CancellationError.self) { try await loader.load(url: nil, input: input) }
        #expect(server.requests.isEmpty && !FileManager.default.fileExists(atPath: input.cacheURL.path))
        #expect(!input.snapshot().cancelled)
    }

    @Test(arguments: [false, true], [false, true])
    func preparationWaitsForCuesAndCancellationCreatesNoOutput(knownLength: Bool, cancel: Bool) async throws {
        let data = try fixture(), count = data.count * 3 / 4
        let prefix = knownLength ? Data(data.prefix(count)) : Data("\(String(count, radix: 16))\r\n".utf8)
            + data.prefix(count) + Data("\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                let held = offset == 86250
                return .init(status: 206, headers: ["Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)",
                    "Content-Length": String(data.count - offset)],
                    body: held ? Data() : Data(data.suffix(from: offset)), keepConnectionOpen: held)
            }
            return .init(headers: knownLength ? ["Content-Length": String(data.count)] : ["Transfer-Encoding": "chunked"],
                body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        var outputs = 0
        let factory = try PCMRecoveryFactory(bufferedInput: input, maximumOutputFrames: 127,
            maximumQueuedBuffers: 2, makeTransport: { outputs += 1; return SampleBufferPCMOutputTests.Transport() })
        let opening = Task { try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false)) }
        defer { opening.cancel() }
        try await PCMPlaybackEngineTests().wait { outputs > 0 || server.requests.contains { $0.headers["range"] == "bytes=86250-" } }
        let requestedCues = server.requests.contains { $0.headers["range"] == "bytes=86250-" }
        #expect(requestedCues && outputs == 0)
        if !requestedCues {
            opening.cancel()
            if let wrong = try? await opening.value { wrong.close() }
            return
        }
        if cancel {
            opening.cancel()
            await #expect(throws: CancellationError.self) { try await opening.value }
            try await PCMPlaybackEngineTests().wait { input.snapshot().waitingReaders == 0 }
            #expect(outputs == 0 && !input.snapshot().cancelled && input.sourceFailure?.error == nil)
        } else {
            try await server.appendResponseBody(Data(data.suffix(from: 86250)), toConnectionAt: 1)
            let session = try await opening.value
            defer { session.close() }
            try await session.prepare()
            #expect(outputs == 1 && session.state == .paused && session.sourceSeekable == true)
            #expect(session.sourceDurationMilliseconds.map { abs($0 - 8008) <= 50 } == true && session.writtenFrames > 0)
        }
    }

    @Test(arguments: ["original", "no-cue-declaration", "empty-cues", "no-duration"])
    func declaredMetadataControlsSeekTargetAndDuration(variant: String) async throws {
        let data = try fixture(variant: variant)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audio.media")
        try data.write(to: url)
        let transport = SampleBufferPCMOutputTests.Transport()
        let factory = try PCMRecoveryFactory(bufferedURL: url, maximumOutputFrames: 127,
            maximumQueuedBuffers: 2, makeTransport: { transport })
        let session = try await factory.make(positionMilliseconds: 4000, parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        try await session.prepare()
        let seekable = variant == "original"
        #expect(session.sourceSeekable == seekable && session.state == .paused && !transport.playing)
        // With cues the seek lands within 0.25 s of 4 s; without a seek map playback starts from the beginning.
        let media = try #require(try session.mediaMicroseconds)
        #expect(seekable ? abs(media - 4_000_000) <= 250_000 : media == 0)
        // Without a declared duration the length is discovered at the end of the file (~8 s).
        try await PCMPlaybackEngineTests().wait { session.sourceDurationMilliseconds.map { abs($0 - 8008) <= 50 } == true }
    }

    @Test(arguments: ["original", "no-cue-declaration", "empty-cues", "no-duration"], [false, true])
    func HTTPMetadataControlsExplicitSeekAndStoredDuration(variant: String, knownLength: Bool) async throws {
        let data = try fixture(variant: variant)
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
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Metadata", episodes: [episode]),
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
        let helper = PCMPlaybackEngineTests(), seekable = variant == "original"
        do {
            try await player.select(episodeID: 1, play: false)
            try await helper.wait { player.phase == .paused || player.phase == .failed }
            try #require(player.phase == .paused && outputs.values.count == 1)
            try await helper.wait { (player.sample?.durationMilliseconds).map { abs(Int($0) - 8008) <= 50 } == true }
            #expect(player.sample?.seekable == seekable)
            try await player.play()
            try await helper.wait { outputs.values[0].playing }
            outputs.values[0].advance(4800)
            try await player.pause()
            #expect(player.sample?.positionMilliseconds == 100)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
            #expect((try await store.episode(id: 1)?.details.media?.durationMilliseconds).map { seekable ? abs(Int($0) - 8008) <= 50 : $0 == 12345 } == true)
            let late = outputs.values[0].onTimeChanged
            try await player.seek(to: 4000)
            // Seekable: lands within 0.25 s of 4 s. Not seekable: restarts from the beginning.
            let landed: (Int32?) -> Bool = { position in
                guard let position else { return false }
                return seekable ? abs(Int(position) - 4000) <= 250 : position == 0
            }
            try await helper.wait { outputs.values.count == 2 && engine.reading?.buffering == false
                && landed(engine.reading?.sample.positionMilliseconds) }
            let anchor = engine.reading?.sample.positionMilliseconds
            #expect(player.sample?.seekable == seekable && !outputs.values[1].playing && outputs.values[0].closed)
            // A late tick from the retired output cannot move the new position.
            late?(); outputs.values[0].advance(999999)
            #expect(engine.reading?.sample.positionMilliseconds == anchor)
            try await player.play()
            try await helper.wait { outputs.values[1].playing }
            try await player.stop()
            #expect((try await store.episode(id: 1)?.details.media?.durationMilliseconds).map { seekable ? abs(Int($0) - 8008) <= 50 : $0 == 12345 } == true)
            #expect(server.requests.count == 1 && outputs.values.allSatisfy { $0.closed })
        } catch { engine.unload(); try? await store.close(); throw error }
        engine.unload(); try await store.close()
    }
}

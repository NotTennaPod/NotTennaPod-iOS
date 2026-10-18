import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor
struct PCMSourceDurationTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    private enum Failure: Error { case deadline }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil,
            subdirectory: "Fixtures/StreamingFormats")))
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func chunk(_ data: Data, end: Bool = false) -> Data {
        Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n\(end ? "0\r\n\r\n" : "")".utf8)
    }
    /// The displayed duration of the 8 s tone fixtures, within an imperceptible 50 ms.
    private func showsToneDuration(_ milliseconds: Int64?) -> Bool {
        guard let milliseconds else { return false }
        return abs(milliseconds - 8000) <= 50
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"], [false, true])
    func unknownHTTPDurationAndPausedEOFPreserveDeclaredLength(name: String, completeInitially: Bool) async throws {
        let data = try fixture(name), prefix = data.count * 3 / 4
        let body = chunk(completeInitially ? data : Data(data.prefix(prefix)), end: completeInitially)
        let server = try await LoopbackHTTPServer.start { request in
            if name == "tone-opus.webm", let range = request.headers["range"] {
                // Original WebM preparation follows declared cues before readiness.
                // Hold any later audio read-ahead until the initial body is released.
                guard range == "bytes=86250-" else { return nil }
                return .init(status: 206, headers: ["Content-Range": "bytes 86250-86289/*"],
                    body: Data(data.suffix(from: 86250)))
            }
            return .init(headers: ["Transfer-Encoding": "chunked"], body: body, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let transport = Transport()
        let factory = try PCMRecoveryFactory(bufferedInput: input, maximumOutputFrames: 127,
            maximumQueuedBuffers: 2, makeTransport: { transport })
        let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        try await session.prepare()
        #expect(session.state == .paused && !transport.playing)
        #expect(input.declaredLength == nil)
        if !completeInitially {
            // WebM declares its duration up front; Ogg duration is unknown until fully loaded.
            if name == "tone-opus.webm" { #expect(showsToneDuration(session.sourceDurationMilliseconds)) }
            else { #expect(session.sourceDurationMilliseconds == nil) }
            #expect(input.length == nil && !input.snapshot().completed)
            try await server.appendResponseBody(chunk(Data(data.suffix(from: prefix)), end: true), toConnectionAt: 0)
        }
        try await wait { input.snapshot().completed }
        try await wait { showsToneDuration(session.sourceDurationMilliseconds) }
        #expect(session.state == .paused && !transport.playing)
        #expect(input.declaredLength == nil && input.length == Int64(data.count))
        if name == "tone-opus.webm", !completeInitially {
            #expect(server.requests.filter { $0.headers["range"] == nil }.count == 1)
        } else { #expect(server.requests.count == 1) }
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg"])
    func knownLengthOggReadsTailForDurationBeforePresenting(name: String) async throws {
        let data = try fixture(name)
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()), offset > 0 {
                return .init(status: 206, headers: ["Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"],
                    body: Data(data.suffix(from: offset)))
            }
            return .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4),
                keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            Issue.record("Known-length Ogg duration preparation did not finish using range reads")
            input.cancel()
        }
        defer { watchdog.cancel() }
        let transport = Transport()
        let factory = try PCMRecoveryFactory(bufferedInput: input, makeTransport: { transport })
        let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        try await session.prepare()
        #expect(showsToneDuration(session.sourceDurationMilliseconds))
        #expect(server.requests.contains { $0.headers["range"] != nil })
        #expect(input.declaredLength == Int64(data.count) && session.state == .paused && !transport.playing)
    }

    @Test func unknownDurationDoesNotBlockEngineReadinessAndUpdatesWhilePaused() async throws {
        let data = try fixture("tone-opus.ogg"), prefix = data.count * 3 / 4
        let body = chunk(Data(data.prefix(prefix)))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Transfer-Encoding": "chunked"], body: body, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let item = ParsedEpisode(identifier: "audio", title: "Audio", media: ParsedMedia(url: server.url.absoluteString, size: 0))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Unknown", episodes: [item]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
            validator: nil, permanentRedirectURL: nil))
        let transport = Transport()
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), makeFactory: {
            try PCMRecoveryFactory(bufferedURL: $0, maximumOutputFrames: 127, maximumQueuedBuffers: 2,
                makeTransport: { transport })
        }, positionTicker: PCMPlaybackEngineTests.Ticker())
        let player = PlaybackCoordinator(store: store, engine: engine)
        do {
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused || player.phase == .failed }
            try #require(player.phase == .paused && engine.reading?.isPrepared == true)
            #expect(player.sample?.durationMilliseconds == -1 && !transport.playing)
            try await server.appendResponseBody(chunk(Data(data.suffix(from: prefix)), end: true))
            try await wait { showsToneDuration((player.sample?.durationMilliseconds).map(Int64.init)) }
            #expect(player.phase == .paused && !transport.playing && player.sample?.positionMilliseconds == 0)
            try await player.play()
            try await wait { transport.playing }
            try await player.stop()
        } catch { engine.unload(); try? await store.close(); throw error }
        engine.unload(); try await store.close()
    }
}

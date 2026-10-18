import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct FFmpegPlaybackSourceTests {
    private enum Failure: Error { case deadline }
    private func fixture(_ name: String) throws -> URL {
        try FFmpegBufferedSeekReferenceTests.resource(name, directory: "StreamingFormats")
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"], [false, true])
    func capturedFileSurvivesUnlinkOrPathReplacement(name: String, replace: Bool) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("captured-codec-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("opaque")
        try FileManager.default.copyItem(at: fixture(name), to: url)
        let source = try FFmpegPlaybackSource(url: url, maximumFrames: 65_536)
        // No decoder exists yet: retaining only the pathname would read this
        // replacement or fail. Repeated seeks must retain the original bytes.
        try FileManager.default.removeItem(at: url)
        if replace { try Data("a different item".utf8).write(to: url) }
        for target in [Int64(0), 4000, 0] {
            let decoder = try await source.makeDecoder(start: CMTime(value: target, timescale: 1000))
            var audio = AudibleAudio()
            while let packet = try await decoder.next() { audio.add(packet) }
            // The original episode keeps playing correctly after its file was removed or replaced.
            try FFmpegBufferedSeekReferenceTests.expectAudible(audio, target: target * 1000, reference: name,
                                                               "\(name) @ \(target) ms, replaced=\(replace)")
            await decoder.cancel()
        }
    }

    @Test func cacheGenerationReplacementRetiresDecoderAndReopensCapturedRequestContext() async throws {
        let originalBytes = try Data(contentsOf: fixture("tone-opus.ogg"))
        let newBytes = try Data(contentsOf: fixture("tone-vorbis.ogg"))
        let login = FeedCredentials(username: "captured", password: "context")
        let requests = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == login.authorization(utf8: false))
            #expect(request.headers["user-agent"] == "AntennaPod/retained-ffmpeg")
            let first = requests.withLock { value in defer { value += 1 }; return value == 0 }
            return .init(body: first ? originalBytes : newBytes)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("codec-generation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let remote = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: login,
            cache: cache, userAgent: "AntennaPod/retained-ffmpeg")
        let source = FFmpegPlaybackSource(remote: remote, url: server.url, proxy: PodcastProxy(),
            credentials: login, cache: cache, maximumFrames: 65_536)
        let old = try await source.makeDecoder(start: .zero)
        try cache.invalidate(for: server.url, matching: remote.input.httpRepresentation, generation: remote.cached.generation)
        let replacement = try await source.makeDecoder(start: .zero)
        #expect(remote.input.snapshot().cancelled)
        await #expect(throws: (any Error).self) { _ = try await old.next() }
        var frames = 0
        while let packet = try await replacement.next() { frames += packet.frameCount }
        let reference = try FFmpegBufferedSeekReferenceTests.reference("tone-vorbis.ogg")
        #expect(abs(frames - reference.buffers.reduce(0) { $0 + $1.frames }) <= 2400)
        #expect(replacement.sampleRate == reference.sampleRate && server.requests.count == 2)
        await old.cancel(); await replacement.cancel()
    }

    @Test func mediaRepresentationReplacementReopensCapturedContextAndRetiresBothTracks() async throws {
        func media(_ name: String) throws -> Data {
            try Data(contentsOf: FFmpegBufferedSeekReferenceTests.resource(name, directory: "PlaybackDecoder"))
        }
        let original = try media("video-multitrack.mp4"), changed = try media("video-only.mp4")
        let login = FeedCredentials(username: "captured", password: "media-context")
        let requests = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == login.authorization(utf8: false))
            #expect(request.headers["user-agent"] == "AntennaPod/retained-media")
            let first = requests.withLock { value in defer { value += 1 }; return value == 0 }
            return .init(body: first ? original : changed)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("media-generation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let remote = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: login,
            cache: cache, userAgent: "AntennaPod/retained-media")
        let source = FFmpegPlaybackSource(remote: remote, url: server.url, proxy: PodcastProxy(), credentials: login,
            cache: cache, maximumFrames: 4096)
        try await source.selectAudioTrack(2)
        let old = try await source.makeMedia(start: .zero)
        let audio = try #require(try await old.makeAudioDecoder())
        #expect(try await old.nextVideoFrame() != nil)
        try cache.invalidate(for: server.url, matching: remote.input.httpRepresentation, generation: remote.cached.generation)
        let replacement = try await source.makeMedia(start: .zero)
        #expect(remote.input.snapshot().cancelled)
        #expect(replacement.metadata.selectedAudioTrackID == nil)
        #expect(await source.selectedAudioTrackID() == nil)
        #expect(try await replacement.makeAudioDecoder() == nil)
        await #expect(throws: (any Error).self) { _ = try await audio.next() }
        await #expect(throws: (any Error).self) { _ = try await old.nextVideoFrame() }
        var pictures = 0
        while try await replacement.nextVideoFrame() != nil { pictures += 1 }
        #expect(pictures == 200 && server.requests.count == 2)
        await old.cancel(); await replacement.cancel()
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"], [false, true])
    func repeatedSeeksOnOneSourcePlayTheRequestedAudio(name: String, http: Bool) async throws {
        let url = try fixture(name), data = try Data(contentsOf: url)
        let server = try await LoopbackHTTPServer.start { _ in .init(body: data) }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let source = try http ? FFmpegPlaybackSource(input: input, maximumFrames: 65_536)
            : FFmpegPlaybackSource(url: url, maximumFrames: 65_536)
        var previous: FFmpegPCMDecoder?
        for target in [Int64(0), 3883, 4000, 7990, 0] {
            let decoder = try await source.makeDecoder(start: CMTime(value: target, timescale: 1000))
            if let previous { await previous.cancel() }
            #expect(await source.producerSnapshot()?.cancelled == false)
            #expect(abs(decoder.startTime.seconds - Double(target) / 1000) <= 0.25)
            var audio = AudibleAudio()
            while let packet = try await decoder.next() { audio.add(packet) }
            try FFmpegBufferedSeekReferenceTests.expectAudible(audio, target: target * 1000, reference: name,
                                                               "\(name) @ \(target) ms, http=\(http)")
            previous = decoder
        }
        await previous?.cancel()
        if http { #expect(!input.snapshot().cancelled) }
    }

    @Test(arguments: [false, true])
    func lazyOpeningCancellationAndSupersessionKeepOneTransfer(supersede: Bool) async throws {
        let data = try Data(contentsOf: fixture("tone-opus.ogg"))
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        var source: FFmpegPlaybackSource? = FFmpegPlaybackSource(input: input, maximumFrames: 4096)
        weak var observed = source
        let first = Task { [source = try #require(source)] in try await source.makeDecoder(start: .zero) }
        defer { first.cancel() }
        try await wait { input.snapshot().waitingReaders > 0 && server.requests.count == 1 }
        if !supersede {
            first.cancel()
            await #expect(throws: CancellationError.self) { try await first.value }
        }
        let replacement = Task { [source = try #require(source)] in try await source.makeDecoder(start: .zero) }
        defer { replacement.cancel() }
        if supersede { await #expect(throws: CancellationError.self) { try await first.value } }
        first.cancel()
        try await wait { input.snapshot().waitingReaders > 0 }
        #expect(!input.snapshot().cancelled && input.sourceFailure?.error == nil && server.requests.count == 1)
        let headers = Data("HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        try await server.appendResponseBody(headers + data)
        let decoder = try await replacement.value
        #expect(decoder.startTime == .zero)
        #expect(try await decoder.next()?.presentationTime == .zero)
        source = nil
        #expect(observed != nil) // The live decoder owns the source after factory release.
        await decoder.cancel()
        try await wait { observed == nil }
        #expect(!input.snapshot().cancelled && input.snapshot().waitingReaders == 0)
    }

    @Test func supersededPreparedPacketAndLateLoadUpdatesCannotTouchReplacement() async throws {
        let source = try FFmpegPlaybackSource(url: fixture("tone-opus.webm"), maximumFrames: 4096)
        let original = try await source.makeDecoder(start: .zero)
        let replacement = try await source.makeDecoder(start: CMTime(value: 4000, timescale: 1000))
        let before = try #require(await source.producerSnapshot())
        // The first decoded chunk is retained by the adapter, but its read lease
        // has been superseded. It must not leak that chunk to an obsolete output.
        await #expect(throws: CancellationError.self) { _ = try await original.next() }
        await #expect(throws: FFmpegPCMDecoder.Failure.cancelled) {
            try await original.updatePlayback(.init(positionMicroseconds: 7_000_000, speed: 4))
        }
        await original.cancel()
        let after = try #require(await source.producerSnapshot())
        #expect(after.sourceID == before.sourceID && after.playbackPositionMicroseconds == 4_000_000 && after.speed == before.speed)
        #expect(replacement.sourceFailure?.error == nil)
        #expect(try await replacement.next()?.presentationTime == replacement.startTime)
        await replacement.cancel()
    }

    @Test func cancelledCuePreparationCanRetryWithoutRetiringHTTPSource() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let heldCue = Mutex(false)
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                // Hold only the first cue request; answer any other range like a real server.
                // The decoder may also request the bytes after the stalled prefix (64717-) and
                // retire the held cue transfer; holding that request too made the test wait for
                // URLSession's 60 s timeout in about 1 run in 10.
                if offset == 86250, !heldCue.withLock({ let held = $0; $0 = true; return held }) { return nil }
                return .init(status: 206, headers: ["Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"],
                    body: Data(data.dropFirst(offset)))
            }
            return .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        var complete = false
        defer {
            if !complete {
                let ranges = server.requests.map { $0.headers["range"] ?? "initial" }
                print("cue cancellation diagnostic ranges=\(ranges) state=\(input.snapshot())")
            }
        }
        let source = FFmpegPlaybackSource(input: input, maximumFrames: 4096)
        let initial = Task { try await source.makeDecoder(start: .zero) }
        defer { initial.cancel() }
        try await wait { server.requests.contains { $0.headers["range"] == "bytes=86250-" } && input.snapshot().waitingReaders > 0 }
        initial.cancel()
        await #expect(throws: CancellationError.self) { try await initial.value }
        #expect(await source.producerSnapshot() == nil && !input.snapshot().cancelled)
        // Finish the existing range transfer after its consumer has canceled, on the
        // connection that carried the held request.
        try server.respond(toPath: server.url.path, with: .init(status: 206,
            headers: ["Content-Length": "40", "Content-Range": "bytes 86250-86289/86290"], body: Data(data.suffix(from: 86250))))
        let decoder = try await source.makeDecoder(start: .zero)
        #expect(decoder.startTime == .zero && decoder.bufferState?.snapshot.sourceSeekable == true)
        #expect(try await decoder.next()?.presentationTime == .zero)
        #expect(!input.snapshot().cancelled && input.sourceFailure?.error == nil)
        await decoder.cancel()
        complete = true
    }

    @Test func sourceFailureSurvivesDecoderReplacementAndPreparedOutput() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] == "bytes=86250-" {
                return .init(status: 206, headers: ["Content-Range": "bytes 86250-86289/86290"], body: data.suffix(from: 86250))
            }
            if request.headers["range"] != nil { return nil }
            return .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let source = FFmpegPlaybackSource(input: input, maximumFrames: 4096)
        let original = try await source.makeDecoder(start: .zero)
        let replacement = try await source.makeDecoder(start: .zero)
        await original.cancel()
        try await wait { input.snapshot().waitingReaders > 0 }
        server.stop()
        try await wait { replacement.sourceFailure?.error != nil }
        let expected = try #require(input.sourceFailure?.error) as NSError
        #expect((expected as? URLError)?.code == .networkConnectionLost)
        do { _ = try await replacement.next(); Issue.record("Delivered prepared PCM after source failure") }
        catch { #expect((error as NSError).isEqual(expected)) }
        do { _ = try await source.makeDecoder(start: .zero); Issue.record("A new decoder hid the terminal source error") }
        catch { #expect((error as NSError).isEqual(expected)) }
        #expect(!input.snapshot().cancelled)
        await replacement.cancel()
    }
}

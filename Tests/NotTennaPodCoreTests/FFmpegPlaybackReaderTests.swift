import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct FFmpegPlaybackReaderTests {
    private static let names = ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"]
    private enum Failure: Error { case deadline }
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }
    private func drain(_ reader: FFmpegAudioReader) async throws -> AudibleAudio {
        var result = AudibleAudio()
        while let chunk = try await reader.next() { result.add(chunk) }
        return result
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func firstCueAfterZeroDoesNotHideInitiallyRetainedAudio() async throws {
        var data = try Data(contentsOf: fixture("tone-opus.webm"))
        try #require(data[86255] == 0xBB)
        data[86255] = 0xEC // EBML Void replaces the first CuePoint at time zero.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".webm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = try await FFmpegAudioReader.openBuffered(url: url, maximumFrames: 65_536, timing: .media3)
        do {
            #expect(try await owner.prepareSourceTimeline() == true)
            let first = try await owner.makePlaybackReader(to: .zero)
            let baseline = try await drain(first)
            try FFmpegBufferedSeekReferenceTests.expectAudible(baseline, target: 0, reference: "late-first-cue.webm", "late first cue")
            await first.cancel()
            let retained = try await owner.makePlaybackReader(to: .zero)
            let replayed = try await drain(retained)
            FFmpegBufferedSeekReferenceTests.expectSameAudible(replayed, baseline, "late first cue, replayed")
            await retained.cancel()
        } catch { await owner.cancel(); throw error }
        await owner.cancel()
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg"], [false, true])
    func declaredLengthControlsLiveResetEvenAfterEOF(name: String, knownLength: Bool) async throws {
        let data = try Data(contentsOf: fixture(name))
        let body = knownLength ? data : Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n0\r\n\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: knownLength ? ["Content-Length": String(data.count)] : ["Transfer-Encoding": "chunked"], body: body)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let owner = try await FFmpegAudioReader.openBuffered(input: input, maximumFrames: 65_536, timing: .media3)
        do {
            // Like Android, a stream without a declared length is not seekable; one with a length is.
            #expect(try await owner.prepareSourceTimeline() == knownLength)
            let initial = try await owner.makePlaybackReader(to: .zero)
            let baseline = try await drain(initial)
            #expect(input.length == Int64(data.count))
            #expect((input.declaredLength != nil) == knownLength)
            await initial.cancel()
            let next = try await owner.makePlaybackReader(to: CMTime(value: 4, timescale: 1))
            let actual = try await drain(next)
            if knownLength {
                try FFmpegBufferedSeekReferenceTests.expectAudible(actual, target: 4_000_000, reference: name, "\(name) seek to 4 s")
            } else {
                FFmpegBufferedSeekReferenceTests.expectSameAudible(actual, baseline, "\(name) unseekable stream restarts")
                #expect(next.bufferState?.snapshot.sourceSeekable == false)
            }
            #expect(!input.snapshot().cancelled)
            await next.cancel()
        } catch { await owner.cancel(); throw error }
        await owner.cancel()
    }

    @Test(arguments: [false, true])
    func replacementSupersedesBlockedDecodeWithoutStoppingNativeLoad(failSource: Bool) async throws {
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
        let owner = try await FFmpegAudioReader.openBuffered(input: input, maximumFrames: 127, timing: .media3)
        do {
            _ = try await owner.prepareSourceTimeline()
            let old = try await owner.makePlaybackReader(to: .zero)
            let pending = Task { try await drain(old) }
            defer { pending.cancel() }
            try await wait { await owner.producerSnapshot()?.waitingConsumer == true }
            let before = try #require(await owner.producerSnapshot()), requests = server.requests.count
            let next = try await owner.makePlaybackReader(to: .zero)
            await #expect(throws: CancellationError.self) { try await pending.value }
            pending.cancel(); await old.cancel()
            let first = try #require(try await next.next())
            #expect(first.presentationTime == .zero)
            #expect(await owner.producerSnapshot()?.retained == before.retained)
            #expect(await owner.producerSnapshot()?.sourceID == before.sourceID)
            #expect(await owner.producerSnapshot()?.cancelled == false)
            #expect(server.requests.count == requests && input.snapshot().waitingReaders > 0)
            #expect(!input.snapshot().cancelled && next.sourceFailure?.error == nil)
            if failSource {
                server.stop()
                try await wait { next.sourceFailure?.error != nil }
                let expected = try #require(input.sourceFailure?.error)
                #expect((expected as? URLError)?.code == .networkConnectionLost)
                #expect((next.sourceFailure?.error as NSError?)?.isEqual(expected as NSError) == true)
                do { _ = try await next.next(); Issue.record("Replacement decoded after its source failed") }
                catch { #expect((error as NSError).isEqual(expected as NSError)) }
            } else {
                await next.cancel()
                #expect(await owner.producerSnapshot()?.reading == true)
            }
        } catch { await owner.cancel(); throw error }
        await owner.cancel()
        #expect(input.snapshot().cancelled && input.snapshot().waitingReaders == 0)
    }

    @Test(arguments: [false, true])
    func stoppingOrDroppingOwnerReleasesBlockedChild(drop: Bool) async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        // Timeline preparation is deliberately omitted here: isolate ownership
        // during one sequential native read, without introducing cue range IO.
        var owner: FFmpegAudioReader? = try await FFmpegAudioReader.openBuffered(input: input, timing: .media3)
        weak let observed = owner
        let child = try await #require(owner).makePlaybackReader(to: .zero)
        let pending = Task { try await drain(child) }
        defer { pending.cancel() }
        try await wait { await owner?.producerSnapshot()?.waitingConsumer == true }
        if drop { owner = nil }
        else { await owner?.cancel() }
        await #expect(throws: CancellationError.self) { try await pending.value }
        if drop {
            // Deinit signals stop; it cannot await the blocked native reader's
            // exit. Observe complete retirement rather than assuming ordering
            // between that exit and delivery of the child's cancellation.
            try await wait {
                observed == nil && input.snapshot().cancelled && input.snapshot().waitingReaders == 0
                    && !FileManager.default.fileExists(atPath: input.cacheURL.path)
            }
            #expect(observed == nil)
        }
        #expect(input.snapshot().cancelled && input.snapshot().waitingReaders == 0)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        await child.cancel()
    }
}

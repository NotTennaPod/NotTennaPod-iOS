import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct BufferedPCMRecoveryFactoryTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    @MainActor private final class OutputControl { var shouldFail = true }
    private enum Failure: Error { case deadline, transport }
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func drain(_ port: PCMRecoverySession, through output: Transport) async throws {
        var deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var lastWritten: Int64 = -1
        while port.outputState != .ended {
            if let error = port.failure { throw error }
            let written = output.buffers.reduce(Int64(0)) { $0 + Int64($1.sampleCount) }
            if written > lastWritten {
                lastWritten = written
                deadline = ContinuousClock.now.advanced(by: .seconds(5))
            }
            if output.playing { output.advance(written) }
            guard ContinuousClock.now < deadline else {
                Issue.record("No output progress for five seconds: frames=\(written), state=\(String(describing: port.outputState))")
                throw Failure.deadline
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"], [false, true])
    func seeksAndRendererRebuildsPreserveAllPCMAndReuseSource(name: String, http: Bool) async throws {
        let url = try fixture(name), data = try Data(contentsOf: url)
        let server = try await LoopbackHTTPServer.start { _ in .init(body: data) }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        var outputs: [Transport] = []
        let makeTransport = { @MainActor () -> any PCMPresentationTransport in
            let transport = Transport(); outputs.append(transport); return transport
        }
        let factory = try http ? PCMRecoveryFactory(bufferedInput: input, makeTransport: makeTransport)
            : PCMRecoveryFactory(bufferedURL: url, makeTransport: makeTransport)
        let port = PCMRecoverySession(parameters: .init(speed: 1, skipSilence: false),
            lastPlayedMilliseconds: { 0 }, synchronizeStatistics: {}, factory: factory.make)
        defer { port.close() }
        let referenceSource = try FFmpegPlaybackSource(url: url, maximumFrames: 4096)
        for (index, target) in [Int64(3883), 4000, 7990, 0].enumerated() {
            let speed: Float = index.isMultiple(of: 2) ? 1 : 2
            let silence = !index.isMultiple(of: 2)
            try await port.setParameters(speed: speed, skipSilence: silence)
            let old = outputs.last, late = old?.onTimeChanged
            if index.isMultiple(of: 2) { try await port.seekPaused(to: target) }
            else { try await port.recoverPaused(to: target) }
            let output = try #require(outputs.last)
            #expect(outputs.count == index + 1 && !output.playing)
            if let old { #expect(old.closed); late?(); old.advance(999_999) }
            // Compare the recovered output with standalone processing of the
            // same file from the same position at the same settings.
            let start = CMTime(value: target, timescale: 1000)
            let decoder = try await referenceSource.makeDecoder(start: start)
            // The seek/recovery lands within 0.25 s of the requested position.
            let landed = try port.positionMilliseconds
            #expect(abs(landed - target) <= 250)
            let bytesPerFrame = decoder.channels * MemoryLayout<Int16>.size
            let tolerance = decoder.sampleRate / 20 * bytesPerFrame  // 50 ms of audio
            let expectedStream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: silence, speed: speed)
            var expected = Data()
            while let samples = try await expectedStream.next() { expected.append(samples.withUnsafeBytes { Data($0) }) }
            await expectedStream.cancel()
            if expected.isEmpty {
                // Recorded Android Vorbis 7990-ms seek admits no remaining whole buffer.
                #expect(name == "tone-vorbis.ogg" && target == 7990 && port.outputState == .ended)
            } else {
                #expect(port.outputState == .paused)
                try port.play()
                // A virtual clock compares complete output; it does not impose a five-
                // second wall-time limit on an instrumented full-file transformation.
                try await drain(port, through: output)
            }
            if let failure = port.failure { throw failure }
            let actual = try output.buffers.reduce(into: Data()) {
                $0.append(try #require($1.content.withContiguousStorageIfAvailable { Data($0) }))
            }
            // Nothing audible is lost or added across seeks and renderer
            // rebuilds: same amount of audio within 50 ms, same loudness.
            #expect(abs(actual.count - expected.count) <= tolerance, "\(name) @\(target): bytes \(actual.count)/\(expected.count)")
            func rms(_ data: Data) -> Double {
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                guard !samples.isEmpty else { return 0 }
                return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
            }
            if expected.count > tolerance {
                let loudness = rms(actual), reference = rms(expected)
                #expect(abs(loudness - reference) <= reference * 0.1 + 1, "\(name) @\(target): rms \(loudness), standalone \(reference)")
            }
            #expect(!output.playing && port.parameters.speed == speed && port.parameters.skipSilence == silence)
        }
    }

    @Test func cancellingBlockedSeekDoesNotRetireSourceOrOtherGeneration() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] == "bytes=86250-" {
                // Preparation needs declared cues. Hold only the uncached audio.
                return .init(status: 206, headers: ["Content-Range": "bytes 86250-86289/86290"],
                    body: Data(data.suffix(from: 86250)))
            }
            if request.headers["range"] != nil { return nil }
            return .init(headers: ["Content-Length": String(data.count)], body: data.prefix(data.count * 3 / 4),
                keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        var outputs: [Transport] = []
        let factory = try PCMRecoveryFactory(bufferedInput: input, makeTransport: {
            let output = Transport(); outputs.append(output); return output
        })
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            Issue.record("Cancelled seek or replacement failed to finish while the response was held")
            input.cancel()
        }
        defer { watchdog.cancel() }
        let original = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        defer { original.close() }
        try await original.prepare()
        try await wait { input.snapshot().waitingReaders == 1 && server.requests.contains { $0.headers["range"] == "bytes=64717-" } }
        let seeking = Task { try await factory.make(positionMilliseconds: 7000, parameters: .init(speed: 1, skipSilence: false)) }
        // Wait until the replacement is asking for unavailable encoded audio.
        // Metadata may already be prepared; two native HTTP readers are not needed.
        try await wait { await factory.bufferedProducerSnapshot()?.waitingConsumer == true && input.snapshot().waitingReaders > 0 }
        seeking.cancel()
        await #expect(throws: CancellationError.self) { try await seeking.value }
        #expect(!input.snapshot().cancelled && input.sourceFailure?.error == nil && outputs.count == 1)
        let replacement = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 2, skipSilence: true))
        defer { replacement.close() }
        try await replacement.prepare()
        #expect(replacement.state == .paused && outputs.count == 2)
        original.close()
        try replacement.play()
        try await wait { replacement.state == .playing }
        #expect(!input.snapshot().cancelled && !outputs[1].closed && outputs[0].closed)
    }

    @Test func invalidIntentIsRejectedBeforeHTTPAndOutputFailureLeavesReusableSource() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { _ in .init(body: data) }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let control = OutputControl()
        let factory = try PCMRecoveryFactory(bufferedInput: input, makeTransport: {
            if control.shouldFail { throw Failure.transport }
            return Transport()
        })
        await #expect(throws: PCMSpeedProcessor.Failure.invalidSpeed) {
            try await factory.make(positionMilliseconds: 0, parameters: .init(speed: .nan, skipSilence: false))
        }
        await #expect(throws: NativePCMDecoder.Failure.invalidStart) {
            try await factory.make(positionMilliseconds: -1, parameters: .init(speed: 1, skipSilence: false))
        }
        #expect(server.requests.isEmpty)
        await #expect(throws: Failure.transport) {
            try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        }
        // After the output failure a later attempt on the same source works.
        control.shouldFail = false
        let replacement = try await factory.make(positionMilliseconds: 4000, parameters: .init(speed: 1, skipSilence: false))
        defer { replacement.close() }
        try await replacement.prepare()
        #expect(replacement.state == .paused)
    }

    @Test func lastFactoryAndSessionReleaseRetiresOwnedHTTPCache() async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { _ in .init(body: data) }
        defer { server.stop() }
        var input: HTTPCodecByteInput? = try HTTPCodecByteInput(url: server.url)
        let cache = try #require(input).cacheURL
        var factory: PCMRecoveryFactory? = try PCMRecoveryFactory(bufferedInput: #require(input), makeTransport: { Transport() })
        var session = try await factory?.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        try await session?.prepare()
        input = nil; factory = nil
        // The temporary stream cache stays while the episode is open and is
        // deleted once playback is closed (no leaked storage).
        #expect(FileManager.default.fileExists(atPath: cache.path))
        session?.close(); session = nil
        try await wait { !FileManager.default.fileExists(atPath: cache.path) }
    }
}

import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor struct PCMRecoverySessionTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    enum Problem: Error { case factory }

    @MainActor final class Factory {
        let url: URL
        var pending: [Int64: CheckedContinuation<Void, any Error>] = [:]
        var requests: [(Int64, PCMRecoverySession.Parameters)] = []
        var sessions: [Int64: SampleBufferPlaybackSession] = [:]
        var transports: [Int64: Transport] = [:]
        var prepareEarly = false
        init(_ url: URL) { self.url = url }
        func make(_ position: Int64, _ parameters: PCMRecoverySession.Parameters) async throws -> SampleBufferPlaybackSession {
            requests.append((position, parameters))
            try await withCheckedThrowingContinuation { pending[position] = $0 }
            let t = Transport()
            // Deliberately model a factory whose native work does not honor caller cancellation.
            // The adapter must dispose even a successfully returned obsolete generation.
            let session = try await Task { @MainActor in
                let stream = try LocalPCMPlaybackStream(url: url, start: CMTime(value: position, timescale: 1000),
                    skipSilence: parameters.skipSilence, speed: parameters.speed, maximumOutputFrames: 65536)
                return try SampleBufferPlaybackSession(stream: stream, transport: t, maximumQueuedBuffers: 2)
            }.value
            transports[position] = t; sessions[position] = session
            if prepareEarly { try await session.prepare() }
            return session
        }
        func release(_ position: Int64) { pending.removeValue(forKey: position)?.resume() }
        func fail(_ position: Int64) { pending.removeValue(forKey: position)?.resume(throwing: Problem.factory) }
    }

    private func initial(_ url: URL) throws -> (SampleBufferPlaybackSession, Transport) {
        let t = Transport()
        return (try SampleBufferPlaybackSession(stream: LocalPCMPlaybackStream(url: url,
            skipSilence: false, maximumOutputFrames: 65536), transport: t), t)
    }

    private func owner(_ first: SampleBufferPlaybackSession, _ factory: Factory) -> PCMRecoverySession {
        PCMRecoverySession(initial: first, parameters: .init(speed: 1, skipSilence: false),
            lastPlayedMilliseconds: { 1000 }, synchronizeStatistics: {}, factory: factory.make)
    }

    @Test func replacementPreservesAnchorExactPCMWithoutInventingStatisticsSave() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (first, t) = try initial(url); let f = Factory(url); let s = owner(first, f)
        defer { s.close() }
        try await first.prepare(); try s.play(); t.advance(19200); try s.pause()
        #expect(try s.positionMilliseconds == 400 && s.lastPlayedMilliseconds == 1000)
        try s.pause(); #expect(s.lastPlayedMilliseconds == 1000)
        let stale = t.onTimeChanged
        let seek = Task { try await s.seekPaused(to: 300) }
        try await wait { f.pending[300] != nil }
        #expect(t.closed && first.state == .closed)
        #expect(try s.positionMilliseconds == 300)
        #expect(throws: PCMRecoverySession.Failure.notReady) { try s.play() }
        f.release(300); try await seek.value
        let next = try #require(f.sessions[300]); let nt = try #require(f.transports[300])
        #expect(next.state == .paused && !nt.playing)
        #expect(try s.positionMilliseconds == 300)
        stale?(); #expect(next.presentedFrames == 0)
        // Resumes at the 300 ms anchor and plays the rest of the episode, nothing lost or repeated.
        PCMTestFixture.expectAudiblyEquivalent(try payload(nt), Array(input.dropFirst(28800)).withUnsafeBytes { Data($0) })
        try s.play(); nt.advance(14400)
        #expect(next.state == .ended && s.lastPlayedMilliseconds == 1000)
        #expect(try s.positionMilliseconds == 600)
    }

    @Test func parametersChangedDuringFactoryApplyBeforeFirstDecodedPacket() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (first, _) = try initial(url); let f = Factory(url); let s = owner(first, f)
        defer { s.close() }
        let task = Task { try await s.seekPaused(to: 100) }
        try await wait { f.pending[100] != nil }
        try await s.setParameters(speed: 0.5, skipSilence: false)
        try await s.setParameters(speed: 2, skipSilence: true)
        f.release(100); try await task.value
        let next = try #require(f.sessions[100]); let nt = try #require(f.transports[100])
        #expect(f.requests[0].1 == .init(speed: 1, skipSilence: false))
        #expect(s.parameters == .init(speed: 2, skipSilence: true) && next.state == .paused)
        let expected = try LocalPCMPlaybackStream(url: url, start: CMTime(value: 100, timescale: 1000),
            skipSilence: true, speed: 2, maximumOutputFrames: 65536)
        var bytes = Data()
        while let packet = try await expected.nextPacket() { bytes.append(packet.samples.withUnsafeBytes { Data($0) }) }
        // The replacement plays with the latest speed/skip-silence settings.
        PCMTestFixture.expectAudiblyEquivalent(try payload(nt), bytes)
        #expect(try s.positionMilliseconds == 100)
    }

    @Test func retiredParameterCompletionCannotFailReplacementIntent() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (first, _) = try initial(url); let f = Factory(url); let s = owner(first, f)
        defer { s.close() }
        try await first.prepare()
        first.output.canStartPlayback = { _ in false }
        try s.play()
        #expect(first.state == .buffering)
        // Retire the old output at its parameter/readiness boundary. This models
        // a seek/rebuild overtaking an asynchronous parameter completion.
        first.output.canStartPlayback = { _ in
            s.discardFailedOutput(at: 100)
            throw SampleBufferPlaybackSession.Failure.closed
        }
        try await s.setParameters(speed: 2, skipSilence: true)
        first.output.canStartPlayback = nil
        #expect(first.state == .closed && s.parameters == .init(speed: 2, skipSilence: true))
        let recovery = Task { try await s.recoverPaused(to: 100) }
        try await wait { f.pending[100] != nil }
        f.release(100); try await recovery.value
        #expect(f.requests.last?.1 == .init(speed: 2, skipSilence: true))
        #expect(s.outputState == .paused && f.transports[100]?.playing == false)
    }

    @Test func currentParameterFailureStillPropagates() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (first, _) = try initial(url); let f = Factory(url); let s = owner(first, f)
        defer { s.close() }
        try await first.prepare()
        first.output.canStartPlayback = { _ in false }
        try s.play()
        first.output.canStartPlayback = { _ in throw Problem.factory }
        await #expect(throws: Problem.factory) { try await s.setParameters(speed: 2, skipSilence: true) }
        first.output.canStartPlayback = nil
    }

    @Test func olderFactoryReturningLastCannotReplaceNewestSeek() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (first, _) = try initial(url); let f = Factory(url); let s = owner(first, f)
        defer { s.close() }
        let old = Task { try await s.seekPaused(to: 100) }
        try await wait { f.pending[100] != nil }
        let new = Task { try await s.seekPaused(to: 300) }
        try await wait { f.pending[300] != nil }
        f.release(300); try await new.value
        try s.play()
        f.release(100)
        await #expect(throws: PCMRecoverySession.Failure.closed) { try await old.value }
        #expect(f.sessions[100]?.state == .closed && f.transports[100]?.buffers.isEmpty == true)
        #expect(f.sessions[300]?.state == .playing && f.transports[300]?.closed == false)
        #expect(try s.positionMilliseconds == 300)
    }

    @Test(arguments: [false, true]) func closeOrCancelDiscardsLateFactory(cancel: Bool) async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (first, _) = try initial(url); let f = Factory(url); let s = owner(first, f)
        defer { s.close() }
        let task = Task { try await s.seekPaused(to: 100) }
        try await wait { f.pending[100] != nil }
        if cancel { task.cancel() } else { s.close() }
        f.release(100)
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(f.sessions[100]?.state == .closed && f.transports[100]?.buffers.isEmpty == true)
        #expect(throws: (any Error).self) { try s.play() }
    }

    @Test func factoryFailureCanBeFollowedByFreshSeek() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (first, _) = try initial(url); let f = Factory(url); let s = owner(first, f)
        defer { s.close() }
        let task = Task { try await s.seekPaused(to: 100) }
        try await wait { f.pending[100] != nil }; f.fail(100)
        await #expect(throws: Problem.factory) { try await task.value }
        #expect(throws: PCMRecoverySession.Failure.notReady) { try s.play() }
        let retry = Task { try await s.seekPaused(to: 300) }
        try await wait { f.pending[300] != nil }; f.release(300); try await retry.value
        try s.play(); #expect(f.sessions[300]?.state == .playing)
    }

    @Test func predecodedFactoryCannotLeakOldParameterAudio() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (first, _) = try initial(url); let f = Factory(url); f.prepareEarly = true
        let s = owner(first, f); defer { s.close() }
        let task = Task { try await s.seekPaused(to: 100) }
        try await wait { f.pending[100] != nil }; f.release(100)
        await #expect(throws: PCMRecoverySession.Failure.invalidGeneration) { try await task.value }
        #expect(f.sessions[100]?.state == .closed && f.transports[100]?.playing == false)
    }

    private func payload(_ t: Transport) throws -> Data {
        try t.buffers.reduce(into: Data()) { $0.append(try #require($1.content.withContiguousStorageIfAvailable { Data($0) })) }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}

import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct SampleBufferPCMOutputTests {
    @MainActor final class Transport: PCMPresentationTransport {
        var currentTime = CMTime.zero
        var onTimeChanged: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        var buffers: [CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>] = []
        var playing = false
        var closed = false
        var hold = false
        var error: (any Error)?
        var pending: CheckedContinuation<Void, any Error>?
        var end = CMTime.zero
        var monitoring = false
        func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {
            if let error { throw error }
            buffers.append(buffer)
            if hold { try await withCheckedThrowingContinuation { pending = $0 } }
        }
        func setPlaying(_ playing: Bool, at time: CMTime) { self.playing = playing; currentTime = time }
        func observeEnd(_ time: CMTime) { end = time }
        func finishEnqueuing() { monitoring = true }
        func stopMonitoring() { monitoring = false }
        func close() { closed = true; playing = false }
        func advance(_ frames: Int64) { currentTime = CMTime(value: frames, timescale: 48000); onTimeChanged?() }
        func release() { pending?.resume(); pending = nil }
    }
    func output(_ t: Transport, capacity: Int = 2) throws -> SampleBufferPCMOutput {
        try SampleBufferPCMOutput(transport: t, sampleRate: 48000, channels: 1,
                                  maximumFrames: 127, maximumQueuedBuffers: capacity)
    }

    @Test func exactCapacityRetiresOnlyPresentedBuffersAndEOFEndsOnce() async throws {
        let t = Transport(); let o = try output(t)
        defer { o.close() }
        try await o.enqueue([1, 2, 3]); try await o.enqueue([4, 5])
        #expect(o.writtenFrames == 5 && o.presentedFrames == 0 && o.availableBufferCount == 0)
        await #expect(throws: SampleBufferPCMOutput.Failure.full) { try await o.enqueue([6]) }
        #expect(t.buffers.count == 2)
        try o.finishEnqueuing()
        #expect(o.state == .paused)
        var endings = 0
        o.onChange = { if o.state == .ended { endings += 1 } }
        try o.play(); t.advance(2)
        #expect(o.queuedBufferCount == 2)
        t.advance(3)
        #expect(o.queuedBufferCount == 1 && o.availableBufferCount == 1)
        t.advance(500) // Delayed observer must not invent 495 frames of played audio.
        #expect(o.state == .ended && o.presentedFrames == 5 && !t.playing)
        #expect(t.currentTime == CMTime(value: 5, timescale: 48000))
        t.advance(1000); o.refresh()
        #expect(endings == 1 && o.presentedFrames == 5)
        o.onChange = nil
    }

    @Test func starvationRefillKeepsExactTimelineAndPauseIgnoresLateClock() async throws {
        let t = Transport(); let o = try output(t)
        defer { o.close() }
        try o.play()
        #expect(o.state == .buffering)
        try await o.enqueue([10, 20, 30])
        t.advance(1); try o.pause()
        t.advance(999)
        #expect(o.presentedFrames == 1 && o.state == .paused)
        try o.play()
        #expect(t.currentTime == CMTime(value: 1, timescale: 48000))
        t.advance(10)
        #expect(o.presentedFrames == 3 && o.state == .buffering && o.wantsPlayback && !t.playing)
        try await o.enqueue([40, 50])
        #expect(o.state == .playing && t.currentTime == CMTime(value: 3, timescale: 48000))
        #expect(t.buffers[1].presentationTimeStamp == CMTime(value: 3, timescale: 48000))
        try o.finishEnqueuing(); t.advance(5)
        #expect(o.state == .ended && o.writtenFrames == 5)
    }

    @Test func pendingEnqueueReservesSlotAndPauseDuringAwaitDoesNotAutoplay() async throws {
        let t = Transport(); t.hold = true
        let o = try output(t, capacity: 1)
        defer { o.close() }
        try o.play()
        let task = Task { try await o.enqueue([1, 2]) }
        try await wait { t.pending != nil }
        #expect(o.availableBufferCount == 0 && o.writtenFrames == 0)
        await #expect(throws: SampleBufferPCMOutput.Failure.enqueueInProgress) { try await o.enqueue([3]) }
        #expect(throws: SampleBufferPCMOutput.Failure.enqueueInProgress) { try o.finishEnqueuing() }
        try o.pause(); t.release(); try await task.value
        #expect(o.state == .paused && !t.playing && o.writtenFrames == 2)
    }

    @Test(arguments: [false, true])
    func cancellationAndCloseFenceAcceptedPendingPacket(close: Bool) async throws {
        let t = Transport(); t.hold = true
        let o = try output(t)
        let stale = t.onTimeChanged
        let task = Task { try await o.enqueue([1, 2]) }
        try await wait { t.pending != nil }
        if close { o.close() } else { task.cancel(); try await wait { t.closed } }
        t.release()
        do { try await task.value; Issue.record("Cancelled generation accepted a packet") }
        catch { #expect(close ? o.state == .closed : o.state == .failed) }
        stale?()
        #expect(t.closed && o.writtenFrames == 0 && !o.wantsPlayback)
        // Seeking/replacement is a fresh output. An old callback cannot change its counters.
        let replacementTransport = Transport(); let replacement = try output(replacementTransport)
        defer { replacement.close(); o.close() }
        try await replacement.enqueue([9, 8, 7]); try replacement.play(); stale?()
        #expect(replacement.writtenFrames == 3 && replacement.presentedFrames == 0)
    }

    @Test func invalidInputsAndInvalidClockNeverCreateCompletion() async throws {
        let t = Transport(); let o = try output(t)
        defer { o.close() }
        await #expect(throws: PCMSampleBufferFactory.Failure.invalidFrames) { try await o.enqueue([]) }
        #expect(o.state == .idle && t.buffers.isEmpty && !o.enqueueInProgress)
        try await o.enqueue([1]); try o.play()
        t.currentTime = .invalid; o.refresh()
        #expect(o.state == .failed && t.closed && !o.sourceEnded && o.presentedFrames == 0)
    }

    @Test func repeatedPlayDoesNotRewindUnobservedNativeProgress() async throws {
        let t = Transport(); let o = try output(t)
        defer { o.close() }
        try await o.enqueue([1, 2, 3]); try o.play()
        t.currentTime = CMTime(value: 2, timescale: 48000)
        try o.play()
        #expect(t.currentTime == CMTime(value: 2, timescale: 48000))
        try o.pause()
        #expect(o.presentedFrames == 2)
    }

    @Test func lateProducerReconcilesClockBeforeEnqueueWhenObserverHasNotRun() async throws {
        let t = Transport(); let o = try output(t)
        defer { o.close() }
        try await o.enqueue([1, 2, 3]); try o.play()
        t.currentTime = CMTime(value: 100, timescale: 48000) // No observer delivered yet.
        try await o.enqueue([4, 5])
        #expect(o.presentedFrames == 3 && o.writtenFrames == 5 && o.state == .playing)
        #expect(t.currentTime == CMTime(value: 3, timescale: 48000))
        #expect(t.buffers[1].presentationTimeStamp == t.currentTime)
    }

    @Test(arguments: [1, 2, 4], [1, 7, 127])
    func boundedRollingRefillPreservesEveryPacket(capacity: Int, frames: Int) async throws {
        let t = Transport(); let o = try output(t, capacity: capacity)
        defer { o.close() }
        try o.play()
        for i in 0..<30 {
            if o.availableBufferCount == 0 { t.advance(Int64((i - capacity + 1) * frames)) }
            let packet = [Int16](repeating: Int16(i), count: frames)
            try await o.enqueue(packet)
            #expect(o.queuedBufferCount <= capacity && o.availableBufferCount >= 0)
            #expect(t.buffers[i].presentationTimeStamp == CMTime(value: Int64(i * frames), timescale: 48000))
            let bytes = try #require(t.buffers[i].content.withContiguousStorageIfAvailable { Data($0) })
            #expect(bytes == packet.withUnsafeBytes { Data($0) })
        }
        try o.finishEnqueuing()
        t.advance(Int64(30 * frames))
        #expect(o.state == .ended && o.presentedFrames == Int64(30 * frames))
    }

    @Test(arguments: [NativeSampleBufferTransport.Failure.flushed, .reconfigurationRequired])
    func receiverDiscontinuitiesFailWithoutInventingCompletion(error: NativeSampleBufferTransport.Failure) async throws {
        let t = Transport(); let o = try output(t)
        defer { o.close() }
        try await o.enqueue([1, 2]); try o.play(); t.advance(1)
        t.error = error
        await #expect(throws: NativeSampleBufferTransport.Failure.self) { try await o.enqueue([3]) }
        #expect(o.state == .failed && o.writtenFrames == 2 && o.presentedFrames == 1)
        #expect(!o.sourceEnded && !o.wantsPlayback && t.closed && !o.enqueueInProgress)
    }

    @Test func emptyEOFAndObserverClosureCannotResurrectGeneration() async throws {
        let t = Transport(); let o = try output(t)
        try o.finishEnqueuing()
        #expect(o.state == .ended)
        await #expect(throws: SampleBufferPCMOutput.Failure.finished) { try await o.enqueue([1]) }
        o.close()
        let t2 = Transport(); let o2 = try output(t2)
        o2.onChange = { o2.close() }
        try await o2.enqueue([1])
        #expect(o2.state == .closed && t2.closed && o2.queuedBufferCount == 0)
        o2.onChange = nil
    }

    @Test func errorAfterProducerEOFPreventsFalseCompletionAndStaleFailureIsFenced() async throws {
        let t = Transport(); let o = try output(t)
        defer { o.close() }
        try await o.enqueue([1, 2, 3]); try o.finishEnqueuing(); try o.play()
        #expect(t.monitoring && o.sourceEnded && o.state == .playing)
        t.advance(1)
        let staleFailure = t.onFailure
        t.onFailure?(NativeSampleBufferTransport.Failure.automaticallyFlushed(at: t.currentTime))
        #expect(o.state == .failed && t.closed && !o.wantsPlayback)
        t.advance(999)
        #expect(o.presentedFrames == 1 && o.state == .failed)
        o.close(); staleFailure?(NativeSampleBufferTransport.Failure.flushed)
        #expect(o.state == .closed)
        let t2 = Transport(); let o2 = try output(t2)
        defer { o2.close() }
        try await o2.enqueue([1]); try o2.finishEnqueuing(); try o2.play(); t2.advance(1)
        #expect(o2.state == .ended && !t2.monitoring)
        t2.onFailure?(NativeSampleBufferTransport.Failure.flushed)
        #expect(o2.state == .ended)
    }

    @Test(arguments: [0, 3, 9])
    func jointDrainWaitsForLongerStreamWithoutInventingPCM(audioFrames: Int) async throws {
        let t = Transport(); let o = try output(t)
        defer { o.close() }
        try o.requireAdditionalPresentation()
        if audioFrames > 0 { try await o.enqueue([Int16](repeating: 10, count: audioFrames)) }
        try o.finishEnqueuing()
        #expect(o.state != .ended)
        try o.commitAdditionalPresentation(through: CMTime(value: 6, timescale: 48000), finished: true)
        try o.play(); t.advance(4)
        #expect(o.state == .playing && o.presentedFrames == min(4, Int64(audioFrames)))
        t.advance(6)
        #expect(o.state == (audioFrames > 6 ? .playing : .ended))
        t.advance(9)
        #expect(o.state == .ended && o.writtenFrames == Int64(audioFrames))
        #expect(o.presentationTime == CMTime(value: Int64(max(6, audioFrames)), timescale: 48000))
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}

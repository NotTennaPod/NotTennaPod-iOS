import Foundation
import Testing
@testable import NotTennaPodCore

struct EncodedAudioQueueTests {
    @Test func consumedBackBufferStillLimitsLoadingUntilPresentationAllowsDiscard() throws {
        var queue = EncodedAudioQueue<Int>()
        for index in 0..<399 {
            #expect(try queue.shouldContinueLoading(at: 0, speed: 1))
            try queue.append(index, encodedByteCount: 32_768, timestampMicroseconds: Int64(index) * 1_000_000)
        }
        #expect(queue.allocatedBytes == PlaybackLoadControl.audioTargetBytes)
        #expect(queue.totalBytesWritten == PlaybackLoadControl.audioTargetBytes - 32_768)
        #expect(try !queue.shouldContinueLoading(at: 0, speed: 1))
        for index in 0..<350 { #expect(queue.next()?.packet == index) }
        #expect(queue.retainedCount == 399 && queue.unreadCount == 49)
        #expect(try !queue.shouldContinueLoading(at: 350_000_000, speed: 1))
        queue.retainBackBuffer(at: 350_000_000)
        #expect(queue.retainedCount == 349 && queue.readPosition == 300)
        #expect(queue.allocatedBytes == PlaybackLoadControl.audioTargetBytes - 50 * 32_768)
        #expect(try queue.shouldContinueLoading(at: 350_000_000, speed: 1))
        #expect(queue.bufferedMicroseconds(at: 350_000_000) == 48_000_000)
        #expect(queue.next()?.packet == 350)
    }

    @Test func startupUsesEncodedTimestampsInsteadOfReadOrPacketCount() throws {
        var queue = EncodedAudioQueue<Data>()
        let bytes = Data([0xA1, 0xB2, 0xC3])
        for time: Int64 in [-6500, 0, 999_999] {
            try queue.append(bytes, encodedByteCount: bytes.count, timestampMicroseconds: time)
        }
        #expect(try !queue.shouldStartPlayback(at: 0, speed: 1, rebuffering: false))
        try queue.append(bytes, encodedByteCount: bytes.count, timestampMicroseconds: 1_000_000)
        #expect(try queue.shouldStartPlayback(at: 0, speed: 1, rebuffering: false))
        #expect(try !queue.shouldStartPlayback(at: 0, speed: 1, rebuffering: true))
        #expect(queue.next()?.packet == bytes)
        #expect(queue.next()?.timestampMicroseconds == 0)
        #expect(try !queue.shouldStartPlayback(at: 0, speed: 1.5, rebuffering: false))
    }

    @Test func repeatedCompactionPreservesPacketOrderAndPartialAllocation() throws {
        var queue = EncodedAudioQueue<Int>()
        for index in 0..<5000 {
            try queue.append(index, encodedByteCount: 99, timestampMicroseconds: Int64(index))
            #expect(queue.next()?.packet == index)
            queue.discardConsumed()
            #expect(queue.retainedCount == 0 && queue.unreadCount == 0)
            #expect(queue.allocatedBytes == (queue.totalBytesWritten % 65_536 == 0 ? 0 : 65_536))
        }
        queue.reset()
        #expect(queue.totalBytesWritten == 0 && queue.allocatedBytes == 0)
        #expect(queue.largestQueuedTimestampMicroseconds == nil)
        #expect(try queue.shouldContinueLoading(at: 0, speed: 4))
    }

    @Test func discardAndResetReleaseOwnedPacketReferences() throws {
        final class Packet: Sendable {}
        var queue = EncodedAudioQueue<Packet>()
        var first: Packet? = Packet(), second: Packet? = Packet()
        weak var observedFirst = first, observedSecond = second
        try queue.append(try #require(first), encodedByteCount: 100, timestampMicroseconds: 0)
        try queue.append(try #require(second), encodedByteCount: 100, timestampMicroseconds: 1)
        first = nil; second = nil
        #expect(observedFirst != nil && observedSecond != nil)
        _ = queue.next()
        queue.discardConsumed()
        #expect(observedFirst == nil && observedSecond != nil)
        queue.reset()
        #expect(observedSecond == nil)
    }
}


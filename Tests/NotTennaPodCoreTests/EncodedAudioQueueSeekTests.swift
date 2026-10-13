import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct EncodedAudioQueueSeekTests {
    @Test func failedSeeksRewindWithoutLosingAdmissionAndNewSamplesRemainReadable() throws {
        var queue = EncodedAudioQueue<Int>()
        for index in 0..<10 {
            try queue.append(index, encodedByteCount: 1, timestampMicroseconds: Int64(index * 10), isKeyframe: index.isMultiple(of: 2))
        }
        let firstSeek = queue.seek(to: 45, allowTimeBeyondBuffer: false)
        #expect(firstSeek)
        #expect(queue.next()?.packet == 4 && queue.next()?.packet == 5)
        let beforeStart = queue.seek(to: -1, allowTimeBeyondBuffer: true)
        #expect(!beforeStart)
        #expect(queue.readIndex == 0 && queue.startTimeMicroseconds == 45 && queue.next()?.packet == 0)
        let beyondEnd = queue.seek(toSampleIndex: 12)
        #expect(!beyondEnd)
        #expect(queue.readIndex == 0 && queue.startTimeMicroseconds == 45)
        #expect(queue.seek(toSampleIndex: 10) && queue.next() == nil && queue.startTimeMicroseconds == .min)
        try queue.append(10, encodedByteCount: 1, timestampMicroseconds: 100)
        #expect(queue.next()?.packet == 10 && queue.readIndex == 11)
        #expect(queue.seek(to: 99, allowTimeBeyondBuffer: false) && queue.next()?.packet == 8)
        queue.discardConsumed()
        #expect(queue.firstIndex == 9 && queue.writeIndex == 11)
        #expect(!queue.seek(toSampleIndex: 8) && queue.readIndex == 9 && queue.startTimeMicroseconds == 99)
        #expect(queue.seek(toSampleIndex: 9) && queue.startTimeMicroseconds == .min && queue.next()?.packet == 9)
    }

    @Test func absoluteSeekIndicesSurviveStorageCompactionAndReset() throws {
        var queue = EncodedAudioQueue<Int>()
        for index in 0..<3000 { try queue.append(index, encodedByteCount: 99, timestampMicroseconds: Int64(index * 10)) }
        for _ in 0..<2000 { _ = queue.next() }
        queue.discardConsumed()
        #expect(queue.firstIndex == 2000 && queue.readIndex == 2000 && queue.writeIndex == 3000)
        #expect(queue.seek(toSampleIndex: 2050) && queue.next()?.packet == 2050)
        #expect(queue.seek(to: 20_025, allowTimeBeyondBuffer: false) && queue.next()?.packet == 2002)
        #expect(queue.seek(to: 20_025, allowTimeBeyondBuffer: false, mode: .firstSampleAtOrAfter) && queue.next()?.packet == 2003)
        #expect(!queue.seek(toSampleIndex: 1999) && queue.readIndex == 2000)
        queue.reset()
        #expect(queue.firstIndex == 0 && queue.readIndex == 0 && queue.writeIndex == 0 && queue.startTimeMicroseconds == .min)
    }

    @Test func zeroTargetCanUseRetainedBeginningEvenWithoutAZeroTimeCue() throws {
        // ProgressiveMediaPeriod tries the retained queue before consulting this
        // default seek map. Applying the cue point unconditionally loses the start.
        let timeline = MatroskaTimeline(durationMicroseconds: 8_008_000, primaryTrack: 1,
            cues: [1: [.init(timeMicroseconds: 4_981_000, clusterOffset: 51927, relativeOffset: 4)]], declaredCueOffset: 86250)
        var queue = EncodedAudioQueue<Int>()
        try queue.append(0, encodedByteCount: 100, timestampMicroseconds: 0)
        try queue.append(1, encodedByteCount: 100, timestampMicroseconds: 4_981_000)
        let buffered = queue.seek(to: 0, allowTimeBeyondBuffer: true)
        #expect(buffered && queue.next()?.packet == 0)
        #expect(timeline.defaultSeekPoints(at: 0).first == .init(timeMicroseconds: 4_981_000, clusterOffset: 51927))
        queue.discardConsumed()
        let outsideBuffer = queue.seek(to: 0, allowTimeBeyondBuffer: true)
        #expect(!outsideBuffer && queue.firstIndex == 1 && queue.readIndex == 1)
        #expect(queue.next()?.packet == 1)
    }
}

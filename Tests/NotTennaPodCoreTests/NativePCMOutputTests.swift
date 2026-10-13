import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor struct NativePCMOutputTests {
    @Test(arguments: [false, true])
    func refillBeforeFinalBufferEndsKeepsEverySample(pause: Bool) throws {
        let output = try NativePCMOutput(sampleRate: 48000, channels: 2, mode: .offline,
                                         bufferCapacity: 127, maximumQueuedBuffers: 4)
        defer { output.reset() }
        let packet = [Int16](repeating: 8192, count: 254)
        for _ in 0..<3 { try output.enqueue(packet) }
        try output.play()
        var samples = try output.renderOffline(frames: 63)
        if pause { output.pause(); try output.play() }
        samples += try output.renderOffline(frames: 127)
        samples += try output.renderOffline(frames: 127)
        #expect(output.renderedFrames == 317)
        try output.enqueue(packet)
        samples += try output.renderOffline(frames: 127)
        samples += try output.renderOffline(frames: 64)
        let identical = samples == [Float](repeating: 0.25, count: 1016)
        #expect(identical, "first zero sample: \(String(describing: samples.firstIndex(of: 0)))")
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            if ContinuousClock.now > limit { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func positionFollowsHeardAudioAndPlaysQueuedAudioInOrder() async throws {
        let output = try NativePCMOutput(sampleRate: 48_000, channels: 2, mode: .offline,
                                         bufferCapacity: 256, maximumQueuedBuffers: 2)
        defer { output.reset() }
        let first = [Int16](repeating: 1024, count: 512)
        let second = [Int16](repeating: -2048, count: 512)
        try output.enqueue(first)
        try output.enqueue(second)
        // Queued but not yet heard audio does not advance the position.
        #expect(output.renderedFrames == 0)
        try output.play()
        let result = try output.renderOffline(frames: 256)
        #expect(result == first.map { Float($0) / 32768 })
        #expect(output.renderedFrames == 256)
        try await wait { output.availableBufferCount > 0 }
        try output.enqueue(first)
        #expect(try output.renderOffline(frames: 256) == second.map { Float($0) / 32768 })
        #expect(try output.renderOffline(frames: 256) == first.map { Float($0) / 32768 })
        #expect(output.renderedFrames == 768)
        // A pull source can refill after starvation without resetting its media timeline.
        // Like the real owner, refill once the output reports room for another buffer.
        try await wait { output.availableBufferCount > 0 }
        try output.enqueue(second)
        #expect(try output.renderOffline(frames: 256) == second.map { Float($0) / 32768 })
        #expect(output.renderedFrames == 1024)
    }

    @Test func pauseFreezesContentClockAndResumeContinuesSameSamples() throws {
        let output = try NativePCMOutput(sampleRate: 48_000, channels: 1, mode: .offline, bufferCapacity: 256)
        defer { output.reset() }
        let input = (0..<256).map { Int16($0 * 32) }
        try output.enqueue(input)
        try output.play()
        #expect(try output.renderOffline(frames: 64) == input.prefix(64).map { Float($0) / 32768 })
        output.pause()
        let position = output.renderedFrames
        #expect(position == 64 && !output.wantsPlayback)
        #expect(!output.isEngineRunning)
        #expect(throws: NativePCMOutput.Failure.notPlaying) { try output.renderOffline(frames: 128) }
        #expect(output.renderedFrames == position)
        try output.play()
        #expect(try output.renderOffline(frames: 64) == input[64..<128].map { Float($0) / 32768 })
        #expect(output.renderedFrames == 128)
    }

    @Test(arguments: [127, 256, 257], [false, true])
    func seekResetNeverPlaysOldAudio(capacity: Int, paused: Bool) async throws {
        let output = try NativePCMOutput(sampleRate: 48000, channels: 2, mode: .offline,
                                         bufferCapacity: capacity, maximumQueuedBuffers: 4)
        defer { output.reset() }
        for cycle in 0..<4 {
            let old = [Int16](repeating: Int16(-8000 - cycle), count: capacity * 2)
            for _ in 0..<3 { try output.enqueue(old) }
            try output.play()
            _ = try output.renderOffline(frames: capacity)
            _ = try output.renderOffline(frames: capacity / 2)
            if paused { output.pause() }
            // One old completion is queued, while other old PCM remains unread.
            output.reset()
            #expect(output.renderedFrames == 0 && output.queuedBufferCount == 0)
            let current = [Int16](repeating: Int16(3000 + cycle), count: capacity * 2)
            try output.enqueue(current); try output.enqueue(current)
            try output.play()
            for _ in 0..<2 {
                let actual = try output.renderOffline(frames: capacity)
                let identical = actual == current.map { Float($0) / 32768 }
                #expect(identical, "capacity=\(capacity), paused=\(paused), generation=\(cycle)")
            }
            output.reset()
        }
    }

    @Test(arguments: [false, true], [Float(0.5), 1, 1.5, 4])
    func wholeEpisodeRendersAtRequestedSpeedWithoutLosingAudio(skipSilence: Bool, speed: Float) async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: skipSilence, speed: speed, maximumOutputFrames: 256)
        let output = try NativePCMOutput(sampleRate: stream.sampleRate, channels: stream.channels,
                                         mode: .offline, bufferCapacity: 256, maximumQueuedBuffers: 3)
        defer { output.reset() }
        var expected = input
        if skipSilence {
            var processor = try SilenceSkippingProcessor(sampleRate: 48_000, channels: 2)
            expected = try processor.process(input)
            expected += processor.finish()
        }
        let framesBeforeSpeed = expected.count / 2
        if speed != 1 {
            var processor = try PCMSpeedProcessor(sampleRate: 48_000, channels: 2, speed: speed)
            expected = try processor.process(expected) + processor.finish()
        }
        var ended = false
        func fill() async throws {
            while output.availableBufferCount > 0 && !ended {
                if let samples = try await stream.next() { try output.enqueue(samples) }
                else { ended = true }
            }
        }
        try await fill()
        #expect(output.renderedFrames == 0)
        try output.play()
        var rendered: [Float] = []
        var paused = false
        while rendered.count < expected.count {
            let frames = min(128, (expected.count - rendered.count) / 2)
            rendered += try output.renderOffline(frames: frames)
            if !paused {
                output.pause()
                #expect(output.renderedFrames == Int64(frames))
                #expect(throws: NativePCMOutput.Failure.notPlaying) { try output.renderOffline(frames: frames) }
                try output.play()
                paused = true
            }
            // The final buffer may be short: two buffer-capacities remaining does not
            // imply any buffer has completed. Wait only after earlier full buffers rendered.
            if !ended && output.scheduledFrames - output.renderedFrames <= 128 {
                try await wait { output.availableBufferCount > 0 }
                try await fill()
            }
        }
        #expect(rendered == expected.map { Float($0) / 32768 })
        #expect(output.renderedFrames == Int64(expected.count / 2))
        // Speed is real: the heard duration is the (silence-trimmed) media duration / speed, within 3%.
        let heard = Double(output.renderedFrames), intended = Double(framesBeforeSpeed) / Double(speed)
        #expect(abs(heard - intended) <= max(intended * 0.03, 960), "speed \(speed): \(heard) frames, expected \(intended)")
        let decoded = await stream.decodedFrames
        let skipped = await stream.skippedFrames
        #expect(decoded == 28_800)
        #expect(decoded == Int64(framesBeforeSpeed) + skipped)
        #expect(try await stream.next() == nil)
        await stream.cancel()
    }
}

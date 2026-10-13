import Foundation
import CoreMedia
import Testing
@testable import NotTennaPodCore

struct PCMParameterTransitionTests {
    private func processed(_ samples: ArraySlice<Int16>, speed: Float, skipSilence: Bool) throws -> [Int16] {
        var silence = skipSilence ? try SilenceSkippingProcessor(sampleRate: 48000, channels: 2) : nil
        var rate = abs(speed - 1) < Float(0.0001) ? nil
            : try PCMSpeedProcessor(sampleRate: 48000, channels: 2, speed: speed)
        var result: [Int16] = []
        for start in stride(from: samples.startIndex, to: samples.endIndex, by: 8192) {
            let input = Array(samples[start..<min(samples.endIndex, start + 8192)])
            let shortened = try silence?.process(input) ?? input
            result += try rate?.process(shortened) ?? shortened
        }
        let tail = silence?.finish() ?? []
        result += try rate?.process(tail) ?? tail
        result += rate?.finish() ?? []
        return result
    }

    @Test(arguments: [false, true], [Float(0.5), 1, 1.5, 4])
    func speedAndSkipSilenceChangeAppliesFromChangePointWithoutLosingAudio(skipSilence: Bool, speed: Float) async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: skipSilence, speed: speed, maximumOutputFrames: 127)
        let first = try #require(await stream.nextPacket())
        let newSpeed: Float = speed == 4 ? 0.5 : 4
        try await stream.setParameters(speed: newSpeed, skipSilence: !skipSilence)
        var packets = [first]
        while let packet = try await stream.nextPacket() { packets.append(packet) }
        let second = try #require(packets.first { $0.segment.id != first.segment.id })
        #expect(second.segment.parameters.speed == newSpeed && second.segment.parameters.skipSilence == !skipSilence)
        let before = packets.filter { $0.segment.id == first.segment.id }
        let after = packets.filter { $0.segment.id == second.segment.id }
        #expect(before.count + after.count == packets.count)
        #expect(try before.flatMap(\.samples) == processed(input[..<8192], speed: speed, skipSilence: skipSilence))
        #expect(try after.flatMap(\.samples) == processed(input[8192...], speed: newSpeed, skipSilence: !skipSilence))
        // Output is continuous: no gap or overlap at the change.
        var nextFrame: Int64 = 0
        for packet in packets {
            #expect(packet.outputStartFrame == nextFrame)
            nextFrame += Int64(packet.samples.count / 2)
        }
    }

    @Test(arguments: [false, true])
    func repeatedOrRevertedSettingsLeaveAudioUnchanged(changeBack: Bool) async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: false, maximumOutputFrames: 127)
        let first = try #require(await stream.nextPacket())
        if changeBack {
            try await stream.setParameters(speed: 2, skipSilence: true)
            try await stream.setParameters(speed: 3, skipSilence: false)
        }
        try await stream.setParameters(speed: 1, skipSilence: false)
        try await stream.setParameters(speed: 1, skipSilence: false)
        var packets = [first]
        while let packet = try await stream.nextPacket() { packets.append(packet) }
        #expect(packets.flatMap(\.samples) == input)
        #expect(packets.allSatisfy { $0.segment.parameters.speed == 1 && !$0.segment.parameters.skipSilence })
    }

    @Test func changeWhileDecodingKeepsAlreadyDecodedAudioAtOldSettings() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let decoder = try GateDecoder(url: url, blockOnRead: 2)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: 0.5, maximumOutputFrames: 65536)
        let pull = Task { try await stream.nextPacket() }
        await decoder.waitUntilBlocked()
        try await stream.setParameters(speed: 2, skipSilence: true)
        await decoder.release()
        let first = try #require(await pull.value)
        #expect(first.segment.parameters.speed == 0.5 && !first.segment.parameters.skipSilence)
        #expect(try first.samples == processed(input[..<8192], speed: 0.5, skipSilence: false))
        let second = try #require(await stream.nextPacket())
        #expect(second.segment.id != first.segment.id)
        #expect(second.segment.outputStartFrame == Int64(first.samples.count / 2))
        #expect(try second.samples == processed(input[8192...], speed: 2, skipSilence: true))
        #expect(try await stream.nextPacket() == nil)
    }

    @Test func invalidSpeedIsRejectedAndChangeAtEndAddsNoAudio() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: false, maximumOutputFrames: 65536)
        let packet = try #require(await stream.nextPacket())
        #expect(packet.samples == input)
        let original = await stream.segment
        await #expect(throws: PCMSpeedProcessor.Failure.invalidSpeed) {
            try await stream.setParameters(speed: .nan, skipSilence: true)
        }
        #expect(await stream.requestedParameters == original.parameters)
        try await stream.setParameters(speed: 2, skipSilence: true)
        #expect(try await stream.nextPacket() == nil)
    }

    @Test func latestOfRapidSpeedChangesWins() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: false, speed: 0.5, maximumOutputFrames: 127)
        let first = try #require(await stream.nextPacket())
        try await stream.setParameters(speed: 2, skipSilence: false)
        var oldSamples = first.samples
        var oldEnd: LocalPCMPlaybackStream.Packet?
        for _ in 0..<100 {
            let packet = try #require(await stream.nextPacket())
            #expect(packet.segment.id == first.segment.id)
            oldSamples += packet.samples
            if packet.samples.count < 254 { oldEnd = packet; break }
        }
        _ = try #require(oldEnd)
        try await stream.setParameters(speed: 4, skipSilence: true)
        await #expect(throws: PCMSpeedProcessor.Failure.invalidSpeed) {
            try await stream.setParameters(speed: .infinity, skipSilence: false)
        }
        #expect(await stream.requestedParameters.speed == 4)
        #expect(await stream.requestedParameters.skipSilence)
        var remaining: [Int16] = []
        while let packet = try await stream.nextPacket() {
            #expect(packet.segment.id != first.segment.id && packet.segment.parameters.speed == 4)
            remaining += packet.samples
        }
        #expect(try oldSamples == processed(input[..<8192], speed: 0.5, skipSilence: false))
        #expect(try remaining == processed(input[8192...], speed: 4, skipSilence: true))
    }

    @Test func requestAtExactLastPacketBoundaryDoesNotResetFinalStatistics() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: false, maximumOutputFrames: 64)
        let original = await stream.segment
        for _ in 0..<450 {
            let packet = try #require(await stream.nextPacket())
            #expect(packet.samples.count == 128 && packet.segment.id == original.id)
        }
        try await stream.setParameters(speed: 2, skipSilence: true)
        #expect(try await stream.nextPacket() == nil)
        #expect(await stream.segment == original)
        #expect(try await stream.progress.inputFrames == 28_800)
        #expect(try await stream.progress.outputFrames == 28_800)
    }

    @Test func speedChangeAfterSeekKeepsPositionContinuous() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, start: CMTime(value: 123, timescale: 1000),
                                                skipSilence: false, speed: 1.5, maximumOutputFrames: 127)
        let first = try #require(await stream.nextPacket())
        #expect(abs(first.segment.mediaStartFrame - 5904) <= 12_000 && first.segment.outputStartFrame == 0)
        try await stream.setParameters(speed: 0.5, skipSilence: true)
        var beforeFrames = Int64(first.samples.count / 2)
        var changed = false
        while let packet = try await stream.nextPacket() {
            if packet.segment.id == first.segment.id { beforeFrames += Int64(packet.samples.count / 2) }
            else {
                #expect(packet.segment.mediaStartFrame > first.segment.mediaStartFrame)
                #expect(packet.segment.outputStartFrame == beforeFrames)
                changed = true
            }
        }
        #expect(changed)
    }
}

/// The actual AVAudioFile decoder behind a single deterministic suspension, not a timing sleep.
actor GateDecoder: PCMDecoding {
    nonisolated let bufferState: PCMBufferState?
    nonisolated let sampleRate: Int
    nonisolated let channels: Int
    nonisolated let startFrame: Int64
    private let base: NativePCMDecoder
    private let blockOnRead: Int
    private var reads = 0
    private var entered = false
    private var cancelled = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?

    init(url: URL, blockOnRead: Int, bufferState: PCMBufferState? = nil) throws {
        self.bufferState = bufferState
        base = try NativePCMDecoder(url: url)
        sampleRate = base.sampleRate
        channels = base.channels
        startFrame = base.startFrame
        self.blockOnRead = blockOnRead
    }

    func next() async throws -> NativePCMDecoder.Packet? {
        reads += 1
        if reads == blockOnRead {
            await withCheckedContinuation { continuation in
                gate = continuation
                entered = true
                entryWaiter?.resume()
                entryWaiter = nil
            }
        }
        guard !cancelled else { throw NativePCMDecoder.Failure.cancelled }
        return try await base.next()
    }

    func waitUntilBlocked() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() { gate?.resume(); gate = nil }
    func cancel() async { cancelled = true; release(); await base.cancel() }
}

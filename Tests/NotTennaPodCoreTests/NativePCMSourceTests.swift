import AVFoundation
import Foundation
import NativePCMTransport
import Testing

@Suite(.serialized) @MainActor struct NativePCMSourceTests {
    @Test(arguments: [false, true], [false, true])
    func lateRefillPreservesExactPCMWithoutSchedulingDelays(pause: Bool, realtime: Bool) throws {
        let source = try #require(APPCMSource(sampleRate: 48000, channels: 2, capacityFrames: 508))
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        engine.attach(source.node)
        try engine.connectNode(source.node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(realtime ? .realtime : .offline, format: format, maximumFrameCount: 127)
        let renderBlock = engine.manualRenderingBlock
        defer { engine.stop() }
        let input = [Int16](repeating: 8192, count: 254)
        func enqueue() {
            #expect(input.withUnsafeBufferPointer { source.enqueue($0.baseAddress!, frames: 127) })
        }
        func render(_ frames: UInt32) throws -> [Float] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            if realtime {
                buffer.frameLength = frames
                var error: OSStatus = 0
                #expect(renderBlock(frames, buffer.mutableAudioBufferList, &error) == .success)
                #expect(error == 0)
            } else { #expect(try engine.renderOffline(frames, to: buffer) == .success) }
            return (0..<Int(buffer.frameLength)).flatMap { frame in
                (0..<2).map { buffer.floatChannelData![$0][frame] }
            }
        }
        for _ in 0..<3 { enqueue() }
        try engine.start()
        var samples = try render(63)
        if pause { engine.pause(); try engine.start() }
        samples += try render(127)
        samples += try render(127)
        #expect(source.consumedFrames == 317)
        enqueue()
        samples += try render(127)
        samples += try render(64)
        let identical = samples == [Float](repeating: 0.25, count: 1016)
        #expect(identical, "first zero sample: \(String(describing: samples.firstIndex(of: 0)))")
        #expect(source.consumedFrames == 508 && source.writtenFrames == 508 && source.underrunFrames == 0)
    }

    @Test(arguments: [1, 2, 6, 32], [1, 7, 127, 257])
    func capacityWrapAndUnderflowPreserveChannels(channels: Int, capacity: Int) throws {
        let source = try #require(APPCMSource(sampleRate: 48000, channels: UInt32(channels), capacityFrames: UInt32(capacity)))
        let graph = try SourceGraph(node: source.node, channels: channels, maximumFrames: 512)
        try graph.engine.start()
        var position = 0
        var missing = 0
        for pass in 0..<12 {
            let count = max(1, capacity - pass % min(capacity, 5))
            let samples = (0..<count * channels).map { sample in
                Int16(truncatingIfNeeded: (position * channels + sample) * 997 + 1)
            }
            #expect(samples.withUnsafeBufferPointer { source.enqueue($0.baseAddress!, frames: UInt32(count)) })
            // Insufficient capacity must reject atomically; it must not overwrite unread PCM.
            let tooLarge = [Int16](repeating: 1234, count: capacity * channels)
            #expect(!tooLarge.withUnsafeBufferPointer { source.enqueue($0.baseAddress!, frames: UInt32(capacity)) })
            #expect(source.writtenFrames == UInt64(position + count))
            let requested = count + pass % 3
            let actual = try graph.render(requested)
            let expected = samples.map { Float($0) / 32768 } + [Float](repeating: 0, count: (requested - count) * channels)
            let identical = actual == expected
            #expect(identical, "channels=\(channels), capacity=\(capacity), pass=\(pass)")
            position += count
            missing += requested - count
            #expect(source.consumedFrames == UInt64(position))
            #expect(source.underrunFrames == UInt64(missing))
        }
    }

    @Test func nodeRetainsItsOwnGenerationAfterControlOwnerDeallocates() throws {
        weak var owner: APPCMSource?
        let node = try autoreleasepool {
            let source = try #require(APPCMSource(sampleRate: 48000, channels: 1, capacityFrames: 8))
            owner = source
            let input = [Int16](repeating: -16384, count: 8)
            #expect(input.withUnsafeBufferPointer { source.enqueue($0.baseAddress!, frames: 8) })
            return source.node
        }
        #expect(owner == nil)
        let graph = try SourceGraph(node: node, channels: 1, maximumFrames: 8)
        try graph.engine.start()
        #expect(try graph.render(8) == [Float](repeating: -0.5, count: 8))
    }

    @Test func concurrentProducerAndRendererNeverReorderOrOverwriteUnreadSamples() async throws {
        let producer = try SourceProducer()
        let graph = try SourceGraph(node: await producer.node(), channels: 2, maximumFrames: 127)
        try graph.engine.start()
        let writing = Task { try await producer.writeAll() }
        defer { writing.cancel() }
        // This checks ordering/ownership, not whole-suite CPU throughput. Keep
        // a bounded stall guard, renewing it only when real media advances.
        var progressDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var consumed = 0
        while consumed < SourceProducer.totalFrames {
            try Task.checkCancellation()
            let actual = try graph.render(127)
            let next = await producer.consumedFrames()
            let count = next - consumed
            if count > 0 { progressDeadline = ContinuousClock.now.advanced(by: .seconds(3)) }
            try #require(ContinuousClock.now <= progressDeadline,
                "Concurrent PCM render stalled: consumed \(consumed)/\(SourceProducer.totalFrames) frames")
            #expect((0...127).contains(count))
            let expected = (0..<count * 2).map { Float(SourceProducer.sample(consumed * 2 + $0)) / 32768 }
                + [Float](repeating: 0, count: (127 - count) * 2)
            let identical = actual == expected
            #expect(identical, "source frame=\(consumed), returned source frames=\(count)")
            consumed = next
        }
        try await writing.value
        #expect(await producer.writtenFrames() == SourceProducer.totalFrames)
    }
}

@MainActor private final class SourceGraph {
    let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private let channels: Int
    init(node: AVAudioSourceNode, channels: Int, maximumFrames: Int) throws {
        self.channels = channels
        let tag = channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2
            ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
        format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        engine.attach(node)
        try engine.connectNode(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: UInt32(maximumFrames))
        try engine.connectNode(engine.mainMixerNode, to: engine.outputNode, format: format)
    }
    isolated deinit { engine.stop() }
    func render(_ frames: Int) throws -> [Float] {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        #expect(try engine.renderOffline(UInt32(frames), to: buffer) == .success)
        return (0..<Int(buffer.frameLength)).flatMap { frame in
            (0..<channels).map { buffer.floatChannelData![$0][frame] }
        }
    }
}

private actor SourceProducer {
    static let totalFrames = 120_000
    private let source: APPCMSource
    init() throws { source = try #require(APPCMSource(sampleRate: 48000, channels: 2, capacityFrames: 1024)) }
    func node() -> AVAudioSourceNode { source.node }
    func consumedFrames() -> Int { Int(source.consumedFrames) }
    func writtenFrames() -> Int { Int(source.writtenFrames) }
    static func sample(_ index: Int) -> Int16 { Int16(truncatingIfNeeded: index * 997 + 1) }
    func writeAll() async throws {
        var position = 0
        while position < Self.totalFrames {
            try Task.checkCancellation()
            let count = min(Self.totalFrames - position, 61 + position % 197)
            let samples = (0..<count * 2).map { Self.sample(position * 2 + $0) }
            if samples.withUnsafeBufferPointer({ source.enqueue($0.baseAddress!, frames: UInt32(count)) }) {
                position += count
            } else { await Task.yield() }
        }
    }
}

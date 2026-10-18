import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct NativeFLACSourceVariantsTests {
    private struct Manifest: Decodable {
        let files: [File]
        struct File: Decodable {
            let name: String, sha256: String
            let firstAudio: Int64
            let packets: [Packet]
        }
        struct Packet: Decodable { let pts: Int64, duration: Int64; let pos: String, size: String }
    }
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/FLACVariants"))
#else
        try #require(Bundle(for: FLACVariantFixtures.self).url(forResource: name, withExtension: nil, subdirectory: "FLACVariants"))
#endif
    }
    private func reference() throws -> [Int16] {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "tone.flac", withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        let url = try #require(Bundle(for: FLACVariantFixtures.self).url(forResource: "tone.flac", withExtension: nil))
#endif
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var samples = [Int16]()
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: UInt32(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            samples += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength))
        }
        return samples
    }

    @Test(arguments: [false, true], [false, true])
    func variableBlockSizeFLACSeekPlaysExactRemainingAudio(table: Bool, known: Bool) async throws {
        let data = try Data(contentsOf: fixture(table ? "variable-table.flac" : "variable.flac"))
        let timeline = try await NativeAudioSourceTimeline.read(input: Bytes(data, known: known), format: .flac)
        let target = timeline.seekable ? CMTime(value: 192017, timescale: 48000) : .zero
        let producer = NativeAudioPacketProducer(input: Bytes(data, known: known), timeline: timeline, format: .flac,
            flacStart: timeline.seekable ? target : nil)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, start: target)
        let first = Int(decoder.startFrame)
        // Unseekable sources start from the beginning; seekable ones near the target.
        #expect(abs(first - (target == .zero ? 0 : 192017)) <= 12000)
        var actual = [Int16]()
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: Int64(first + actual.count), timescale: 48000))
            actual += packet.samples
        }
        #expect(actual == Array(try reference().dropFirst(first)))
        await decoder.cancel()
    }

    @Test(arguments: [false, true])
    func indexedVariableBlockSizeFLACSeekPlaysExactRemainingAudio(table: Bool) async throws {
        let data = try Data(contentsOf: fixture(table ? "variable-table.flac" : "variable.flac"))
        let timeline = try await NativeAudioSourceTimeline.read(input: Bytes(data, known: true), format: .flac)
        let target = CMTime(value: 192017, timescale: 48000)
        let producer = NativeAudioPacketProducer(input: Bytes(data, known: true), timeline: timeline, format: .flac, indexedStart: target)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, start: target)
        let first = decoder.startFrame
        #expect(abs(first - 192017) <= 12000)
        var actual = [Int16]()
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: first + Int64(actual.count), timescale: 48000))
            actual += packet.samples
        }
        #expect(actual == Array(try reference().dropFirst(Int(first))))
        await decoder.cancel()
    }

    @Test(arguments: 0..<12)
    func malformedFLACPacketHeaderDoesNotSupplyTiming(scenario: Int) throws {
        let data = try Data(contentsOf: fixture("variable.flac"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixture("manifest.json")))
        let packet = try #require(manifest.files.first { $0.name == "variable.flac" }?.packets.first { $0.pts == 98304 })
        let offset = try #require(Int(packet.pos)), size = try #require(Int(packet.size))
        var header = data.subdata(in: offset..<(offset + size))
        // This independently mapped frame uses a four-byte sample number and
        // standard rate/block keys; its CRC follows at byte8.
        try #require(header[4] & 0xf8 == 0xf0)
        func crc(_ bytes: Data) -> UInt8 {
            var value: UInt8 = 0
            for byte in bytes {
                value ^= byte
                for _ in 0..<8 { value = value & 128 == 0 ? value &<< 1 : (value &<< 1) ^ 7 }
            }
            return value
        }
        switch scenario {
        case 0: header = Data(header.prefix(4))
        case 1: header = Data(header.prefix(8))
        case 2: header[0] = 0
        case 3: header[1] = 0xfa
        case 4: header[3] |= 1
        case 5: header[3] = 0xb8
        case 6: header[3] = 6
        case 7: header[4] = 0x80
        case 8: header[5] = 0
        case 9: header[2] &= 15
        case 10: header[8] ^= 1
        default:
            header[2] = (header[2] & 15) | 0x70
            header = Data(header.prefix(8)) + Data([255, 255])
            header.append(crc(header)) //65536 exceeds FLAC's maximum block size.
        }
        // For structural-invalid cases preserve a valid CRC, proving rejection
        // is not merely a side effect of the changed checksum.
        if (2...9).contains(scenario) { header[8] = crc(Data(header.prefix(8))) }
        #expect(throws: NativeAudioStreamParser.Failure.invalidPacket) {
            try header.withUnsafeBytes { try NativeFLACPacketTiming.frameCount(in: $0) }
        }
    }

    @Test(arguments: 0..<8, [false, true])
    func streamedVariableBlockSizeFLACSeeksAndReplaysOffline(configuration: Int, exactAdmission: Bool) async throws {
        let table = configuration & 1 != 0, known = configuration & 2 != 0, proxyEnabled = configuration & 4 != 0
        let data = try Data(contentsOf: fixture(table ? "variable-table.flac" : "variable.flac"))
        let credentials = FeedCredentials(username: "variable-flac", password: "fixture")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["ETag": "\"variable-flac\"",
                    "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], body: Data(data.dropFirst(offset)))
            }
            return .init(headers: ["Content-Type": "audio/flac", "ETag": "\"variable-flac\""], body: data,
                includeAutomaticContentLength: known)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("variable-flac-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SharedStreamingCache(directory: root)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://variable-flac.invalid/media")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials,
            cache: cache, maximumFrames: 1024)
        let target = CMTime(value: 192017, timescale: 48000)
        let decoder = try await source.makeDecoder(start: target, admission: exactAdmission ? .exactFrame : .wholeBuffer)
        let first = decoder.startFrame
        // Seekable sources land near the target; unseekable ones start at the beginning.
        #expect(abs(first - (table || known ? 192017 : 0)) <= 12000)
        #expect(decoder.sourceDurationMilliseconds == 8000 && decoder.sourceSeekable == (table || known))
        var actual = [Int16]()
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: first + Int64(actual.count), timescale: 48000))
            actual += packet.samples
        }
        #expect(actual == Array(try reference().dropFirst(Int(first))))
        await decoder.cancel()
        let count = server.requests.count
        server.stop()
        let replay = try await source.makeDecoder(start: target, admission: exactAdmission ? .exactFrame : .wholeBuffer)
        var repeated = [Int16]()
        while let packet = try await replay.next() { repeated += packet.samples }
        #expect(repeated == actual && server.requests.count == count)
        #expect(replay.sourceSeekable == (table || known))
        await replay.cancel()
    }

    private final class Bytes: MediaByteInput, @unchecked Sendable {
        let data: Data, known: Bool
        private let stopped = Mutex(false)
        init(_ data: Data, known: Bool) { self.data = data; self.known = known }
        var length: Int64? { known ? Int64(data.count) : nil }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func cancel() { stopped.withLock { $0 = true } }
        func checkFailure() throws { if stopped.withLock({ $0 }) { throw CancellationError() } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + maximumCount))
        }
    }
}
private final class FLACVariantFixtures: NSObject {}

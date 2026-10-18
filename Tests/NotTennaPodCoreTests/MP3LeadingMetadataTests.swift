import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// An MP3 whose audio follows large or repeated ID3v2 tags (cover art, chapter art, a v2.4 footer)
/// decodes exactly the audio of the same file without them, wherever reads happen to split the
/// tags and the first audio frames, and keeps the tag's required timing metadata (MLLT).
@Suite(.serialized) struct MP3LeadingMetadataTests {
    typealias Tags = LargeID3TagRoutingTests
    /// Cover art added before the fixture's MLLT frame, frame header included. 3,155,233 left only
    /// 250 audio bytes in the first parse across the tag's end; the others are controls.
    static let artSizes = [0, 1_048_577, 1_573_001, 3_145_728, 3_155_233, 4_194_231]
    static let frames = 1_440_000

    enum Footer: String, CaseIterable, Sendable {
        /// None; flag 0x10 with the footer after the declared body (ID3v2.4 PROTOCOL §15.2); the footer
        /// inside the declared body (the repository's older layout); the flag without a footer;
        /// a footer whose size does not match the header.
        case none, external, inBody, flagOnly, mismatched
    }
    /// The fixture's audio after its own MLLT tag enlarged by `art` bytes of cover art before the
    /// MLLT frame, with the chosen footer, optionally followed by an art-only tag and an empty tag.
    static func media(art: Int, footer: Footer = .none, repeated: Bool = false) throws -> Data {
        let original = try Data(contentsOf: Tags.fixture("playback-indexed-mllt-stereo-v4"))
        let size = original[6...9].reduce(0) { ($0 << 7) | Int($1) }
        let frames = original.subdata(in: 10..<(10 + size))
        let audio = original.dropFirst(10 + size)
        guard art > 0 || footer != .none || repeated else { return original }
        let art = art > 0 ? Tags.artwork(payload: art - 10, version: 4) : Data()
        var result = tag(art + frames, footer: footer)
        if repeated {
            result += tag(Tags.artwork(payload: 77_307, version: 4), footer: footer == .none ? .none : .external)
            result += tag(Data(), footer: .none)
        }
        return result + audio
    }
    static func tag(_ body: Data, footer: Footer) -> Data {
        let declared = body.count + (footer == .inBody ? 10 : 0)
        let flags: UInt8 = footer == .none ? 0 : 0x10
        let fields = Data([4, 0, flags]) + Data(Tags.size(declared, syncsafe: true))
        let mark = Data("3DI".utf8)
        switch footer {
        case .none, .flagOnly: return Data("ID3".utf8) + fields + body
        case .external: return Data("ID3".utf8) + fields + body + mark + fields
        case .inBody: return Data("ID3".utf8) + fields + body + mark + fields
        case .mismatched: return Data("ID3".utf8) + fields + body + mark + Data([4, 0, flags]) + Data(Tags.size(declared + 1, syncsafe: true))
        }
    }

    /// The untagged fixture's complete audio through the production MP3 source (1,441,152 encoded
    /// frames less the declared delay and padding).
    private static let cached = Mutex<[Int16]?>(nil)
    static func reference() async throws -> [Int16] {
        if let samples = cached.withLock({ $0 }) { return samples }
        let url = try Tags.fixture("playback-indexed-mllt-stereo-v4")
        let source = NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url))
        let decoder = try await source.makeDecoder(prepareSourceTimeline: true)
        var samples: [Int16] = []
        while let packet = try await decoder.next() { samples += packet.samples }
        await decoder.cancel()
        cached.withLock { $0 = samples }
        return samples
    }

    struct Decoded { var samples: [Int16] = []; var error: (any Error)?; var decoder: NativeMP3SourceDecoder? }
    private func drain(_ decoder: NativeMP3SourceDecoder) async -> Decoded {
        var result = Decoded(decoder: decoder)
        do { while let packet = try await decoder.next() { result.samples += packet.samples } } catch { result.error = error }
        await decoder.cancel()
        return result
    }
    private func expectComplete(_ decoded: Decoded, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let reference = try await Self.reference()
        #expect(decoded.error == nil && decoded.samples.count == Self.frames * 2 && decoded.samples == reference,
                "\(label): \(decoded.samples.count / 2) frames, \(String(describing: decoded.error))", sourceLocation: sourceLocation)
    }

    // MARK: - Startup lookahead after leading tags

    @Test func referenceIsTheWholeEpisode() async throws {
        let reference = try await Self.reference()
        #expect(reference.count == Self.frames * 2)
    }

    /// Downloaded and on the three remote routes (ranged with a validator; unranged with a length;
    /// chunked without either), the exact failing alignment and its control play every frame.
    @Test(arguments: [3_145_728, 3_155_233])
    func largeTagAlignmentPlaysEveryFrameLocallyAndRemotely(art: Int) async throws {
        let media = try Self.media(art: art)
        let url = URL.temporaryDirectory.appendingPathComponent("leading-tag-\(UUID()).mp3")
        try media.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let identified = try #require(try await LocalAudioBytes.openIdentified(url: url))
        #expect(identified.format == .mp3)
        let local = NativeMP3PlaybackSource(localURL: url, file: identified.file)
        let decoded = await drain(try await local.makeDecoder(prepareSourceTimeline: true))
        try await expectComplete(decoded, "local art \(art)")
        #expect(decoded.decoder?.sourceDurationMilliseconds == 30_024)
        for route in 0..<3 {
            let server = try await Self.server(media, route: route)
            defer { server.stop() }
            let directory = URL.temporaryDirectory.appendingPathComponent("leading-tag-remote-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = try SharedStreamingCache(directory: directory)
            let input = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache)
            #expect(input.format == .mp3)
            let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy(), cache: cache, preparedInput: input)
            let remote = await drain(try await source.makeDecoder(prepareSourceTimeline: true))
            try await expectComplete(remote, "route \(route) art \(art)")
            #expect(server.requests.count == 1, "route \(route): \(server.requests.count) requests")
        }
    }

    /// 0: ranges, length and a strong validator; 1: no ranges, with a length; 2: chunked, no
    /// length or validator.
    static func server(_ media: Data, route: Int) async throws -> LoopbackHTTPServer {
        try await LoopbackHTTPServer.start { request in
            switch route {
            case 0:
                if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                    return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"tag\"", "Accept-Ranges": "bytes",
                        "Content-Range": "bytes \(start)-\(media.count - 1)/\(media.count)"], body: media.subdata(in: start..<media.count))
                }
                return .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"tag\"", "Accept-Ranges": "bytes"], body: media)
            case 1:
                return .init(headers: ["Content-Type": "audio/mpeg"], body: media)
            default:
                var chunked = Data()
                for start in stride(from: 0, to: media.count, by: 32_749) {
                    let piece = media.subdata(in: start..<min(media.count, start + 32_749))
                    chunked += Data(String(piece.count, radix: 16).utf8) + Data("\r\n".utf8) + piece + Data("\r\n".utf8)
                }
                chunked += Data("0\r\n\r\n".utf8)
                return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: chunked,
                             includeAutomaticContentLength: false)
            }
        }
    }

    /// Parser and decoder alone, with every read the same size: the first audio after the tags
    /// gets its full startup lookahead however the reads fall, so the audio is exactly the original.
    @Test(arguments: artSizes, [137, 197, 1000, 4096, 32_768])
    func everyReadSizeDecodesExactlyTheOriginal(art: Int, chunk: Int) async throws {
        let decoded = try Self.parseAndDecode(Self.media(art: art), chunk: chunk)
        let reference = try await Self.reference()
        #expect(decoded.ended && decoded.samples == reference,
                "art \(art), \(chunk)-byte reads: \(decoded.samples.count / 2) frames, ended \(decoded.ended), \(String(describing: decoded.error))")
    }

    /// Repeated tags and footers, read in pieces that split every tag, footer and the first audio.
    @Test(arguments: [Footer.none, .external, .inBody, .flagOnly], [1, 7, 137, 1000, 4096])
    func repeatedTagsAndFootersDecodeExactlyTheOriginal(footer: Footer, chunk: Int) async throws {
        let media = try Self.media(art: chunk == 1 ? 70_001 : 1_573_001, footer: footer, repeated: true)
        let decoded = try Self.parseAndDecode(media, chunk: chunk)
        let reference = try await Self.reference()
        #expect(decoded.ended && decoded.samples == reference,
                "\(footer), \(chunk)-byte reads: \(decoded.samples.count / 2) frames, \(String(describing: decoded.error))")
    }

    static func parseAndDecode(_ media: Data, chunk: Int) throws -> (samples: [Int16], ended: Bool, error: (any Error)?) {
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        var decoder: NativeMP3PCMDecoder?
        defer { decoder?.close() }
        var samples: [Int16] = []
        do {
            func drain() throws {
                while let decoder {
                    switch try decoder.next() {
                    case .audio(let packet): samples += packet.samples
                    case .needsInput, .ended: return
                    }
                }
            }
            func consume(_ batches: [NativeMP3PacketParser.Batch]) throws {
                for batch in batches {
                    if decoder == nil { decoder = try NativeMP3PCMDecoder(format: batch.format, timing: batch.timing) }
                    try decoder!.accept(batch); try drain()
                }
            }
            for offset in stride(from: 0, to: media.count, by: chunk) {
                try consume(parser.append(media.subdata(in: offset..<min(offset + chunk, media.count))))
            }
            try consume(parser.finish())
            try #require(decoder).finish()
            try drain()
            return (samples, decoder?.isEnded == true, nil)
        } catch { return (samples, false, error) }
    }

    // MARK: - ID3v2.4 footer and the required MLLT

    /// The terminal MLLT frame survives a footer after the declared body (and the older in-body
    /// layout, a flag without a footer, a mismatched footer) at every read size, also when more
    /// tags follow: duration and a 20 s lookup come from it.
    @Test(arguments: Footer.allCases, [false, true])
    func footerKeepsTheRequiredMLLT(footer: Footer, repeated: Bool) throws {
        let media = try Self.media(art: 3_145_728, footer: footer, repeated: repeated)
        for cap in [1, 197, 4096] {
            let input = Tags.Recording(media, randomAccess: true, largestAt: { _ in cap })
            let required = try MP3RequiredID3Metadata.read(from: input, seeking: .timeMicroseconds(20_000_000), retainSeekTable: true)
            #expect(required?.durationMicroseconds == 30_024_000 && required?.seekPoint != nil && required?.seekTable != nil,
                    "\(footer)\(repeated ? " repeated" : ""), \(cap)-byte reads: \(String(describing: required?.durationMicroseconds))")
        }
    }

    /// With a spec-valid footer after a >1 MiB tag ending in MLLT: the whole episode, its MLLT
    /// duration, and 20 s seeks restored and within loaded audio, all the original audio.
    @Test(arguments: [false, true])
    func externalFooterPlaysSeeksAndKeepsTheMLLTDuration(repeated: Bool) async throws {
        let media = try Self.media(art: 3_145_728, footer: .external, repeated: repeated)
        let url = URL.temporaryDirectory.appendingPathComponent("footer-\(UUID()).mp3")
        try media.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let identified = try #require(try await LocalAudioBytes.openIdentified(url: url))
        #expect(identified.format == .mp3)
        let source = NativeMP3PlaybackSource(localURL: url, file: identified.file)
        let whole = await drain(try await source.makeDecoder(prepareSourceTimeline: true))
        try await expectComplete(whole, "footer\(repeated ? " repeated" : "")")
        #expect(whole.decoder?.sourceDurationMilliseconds == 30_024)
        for fresh in [true, false] {
            let item = fresh ? NativeMP3PlaybackSource(localURL: url, file: try LocalAudioBytes(url: url)) : source
            let sought = await drain(try await item.makeDecoder(start: CMTime(value: 20, timescale: 1), prepareSourceTimeline: true))
            let start = try #require(sought.decoder).startTime
            #expect(sought.error == nil && abs(start.seconds - 20) < 0.1 && sought.decoder?.sourceDurationMilliseconds == 30_024)
            // The complete rest of the episode, wherever exactly the seek landed.
            let reference = try await Self.reference()
            #expect(sought.samples == Array(reference.suffix(sought.samples.count)) && sought.samples.count > 9 * 48_000 * 2,
                    "\(fresh ? "restored" : "retained") seek: \(sought.samples.count / 2) frames")
        }
    }
}

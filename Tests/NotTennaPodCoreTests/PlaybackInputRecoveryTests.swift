import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(1))) struct PlaybackInputRecoveryTests {
    private func wave() throws -> Data {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "tone.wav", withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        let url = try #require(Bundle(for: InputRecoveryFixtures.self).url(forResource: "tone.wav", withExtension: nil))
#endif
        return try Data(contentsOf: url)
    }
    private func seed(_ bytes: Data, length: Int64, tag: String, cache: SharedStreamingCache, url: URL) throws {
        try cache.admit(.init(length: length, validation: .strongETag(tag)), for: url)
        let writer = try #require(try cache.beginWrite(for: url, at: 0, contentLength: length))
        try writer.append(bytes); try writer.finish()
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(condition())
    }

    @Test func exhaustedMalformedBodyIsRetiredAndSameURLRepairCanBeOpened() async throws {
        let media = try Data(contentsOf: FFmpegBufferedSeekReferenceTests.resource("video-multitrack.mp4", directory: "PlaybackDecoder"))
        let malformed = Data(repeating: 0, count: 128)
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("rejected-media-repair-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let first = Task { try await PCMRemoteInput.open(url: server.url, proxy: .init(), credentials: nil, cache: cache) }
        try await wait { server.heldRequestPaths.contains("/feed") }
        try server.respond(toPath: "/feed", with: .init(headers: ["ETag": "\"malformed\""], body: malformed))
        do { _ = try await first.value; Issue.record("Malformed zero body was admitted") }
        catch {
            // Preserve the native parser's original error, rather than exposing
            // the internal exhausted-probe classification to the application.
            guard case .native = error as? StreamingAudioTypeError else {
                Issue.record("Expected the zero-body native parser rejection: \(error)"); return
            }
        }
        // Retrying the same URL after the server is repaired plays the corrected file.
        let retry = Task { try await PCMRemoteInput.open(url: server.url, proxy: .init(), credentials: nil, cache: cache) }
        try await wait { server.heldRequestPaths.contains("/feed") }
        try server.respond(toPath: "/feed", with: .init(headers: ["ETag": "\"repaired\""], body: media))
        let recovered = try await retry.value
        defer { recovered.input.cancel(); recovered.relay.cancel() }
        let lease = recovered.makeReadLease(); defer { lease.cancel() }
        #expect(try lease.read(at: 0, maximumCount: 4096) == Data(media.prefix(4096)))
        #expect(server.requests.last?.headers["range"] == nil)
    }

    @Test(arguments: [false, true])
    func identificationRejectionRetiresOnlyOldPrefixAndExplicitRetryReadsFreshBytes(changedLength: Bool) async throws {
        let media = try wave()
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"] {
                #expect(range == "bytes=4-" && request.headers["if-range"] == "\"old\"")
                return .init(status: 206, headers: ["ETag": changedLength ? "\"old\"" : "\"new\"",
                    "Content-Range": "bytes 4-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(4)))
            }
            return .init(headers: ["Content-Type": "audio/wav", "ETag": "\"new\""], body: media)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("playback-identification-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        try seed(Data(media.prefix(4)), length: Int64(media.count + (changedLength ? 4 : 0)), tag: "\"old\"", cache: cache, url: server.url)
        do {
            let wrong = try await PCMRemoteInput.open(url: server.url, proxy: .init(), credentials: nil, cache: cache)
            wrong.input.cancel(); wrong.relay.cancel(); Issue.record("Changed representation was identified")
        } catch {
            if changedLength { #expect((error as? MediaDownloadError) == .invalidRange) }
            else { #expect((error as? URLError)?.code == .resourceUnavailable) }
        }
        // A changed file on the server is never spliced onto the old cached prefix;
        // an explicit retry downloads the new file from the start.
        let recovered = try await PCMRemoteInput.open(url: server.url, proxy: .init(), credentials: nil, cache: cache)
        defer { recovered.input.cancel(); recovered.relay.cancel() }
        let lease = recovered.makeReadLease(); defer { lease.cancel() }
        // Literal file bytes are an independent input oracle; no production decoder
        // output or representation metadata is used to construct expected bytes.
        #expect(try lease.read(at: 0, maximumCount: 4096) == Data(media.prefix(4096)))
        #expect(server.requests.count == 2 && server.requests.last?.headers["range"] == nil)
    }
}
private final class InputRecoveryFixtures: NSObject {}

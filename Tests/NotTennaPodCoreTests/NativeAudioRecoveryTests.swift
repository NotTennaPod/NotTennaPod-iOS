import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct NativeAudioRecoveryTests {
    private func wave() throws -> Data {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "tone.wav", withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        let url = try #require(Bundle(for: NativeRecoveryFixtures.self).url(forResource: "tone.wav", withExtension: nil))
#endif
        return try Data(contentsOf: url)
    }
    private func little(_ n: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
    private func replacement(_ data: Data) -> Data {
        var result = data
        // Same media samples at half the source rate: old metadata must not survive.
        result.replaceSubrange(24..<28, with: little(24000))
        result.replaceSubrange(28..<32, with: little(48000))
        return result
    }
    private func expected(_ data: Data, directory: URL) throws -> [Int16] {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var result: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            result += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount)))
        }
        return result
    }
    private func collect(_ decoder: any PCMDecoding) async throws -> [Int16] {
        var result: [Int16] = []
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: decoder.startFrame + Int64(result.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            result += packet.samples
        }
        return result
    }

    private func waitForLoad(_ condition: @Sendable () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    @MainActor @Test(arguments: [false, true], [8_000_001, 9_000_500])
    func seekPastEndFinishesEpisodeAndSeekBackPlays(proxyEnabled: Bool, targetMicroseconds: Int64) async throws {
        let media = try wave(), requests = Mutex<[String?]>([])
        let credentials = FeedCredentials(username: "native", password: "past-end")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let range = request.headers["range"]
            requests.withLock { $0.append(range) }
            if let range {
                #expect(request.headers["if-range"] == "\"stable\"")
                let offset = Int(range.dropFirst(6).dropLast())!
                return .init(status: 206, headers: ["ETag": "\"stable\"", "Content-Range": "bytes \(offset)-\(media.count - 1)/\(media.count)"],
                    body: Data(media.dropFirst(offset)))
            }
            return .init(headers: ["Content-Type": "audio/wav", "Content-Length": String(media.count), "ETag": "\"stable\""],
                body: Data(media.prefix(131072)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("native-past-end-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://native-past-end.invalid/audio.wav")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let initial = try await source.makeDecoder()
        let oldState = try #require(initial.bufferState)
        let target = CMTime(value: targetMicroseconds, timescale: 1_000_000)
        for _ in 0..<2 {
            let ended = try await source.makeDecoder(start: target)
            #expect(try await ended.next() == nil)
            #expect(ended.sourceDurationMilliseconds == 8000 && ended.sourceSeekable == true)
            let transport = SampleBufferPCMOutputTests.Transport()
            let stream = try LocalPCMPlaybackStream(decoder: ended, skipSilence: false, speed: 1.5)
            let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
            defer { session.close() }
            try await session.prepare()
            // The episode ends without an error and without playing anything.
            #expect(session.sourceEnded && session.state == .ended && session.failure == nil)
            #expect(transport.buffers.isEmpty && !transport.playing)
            #expect(session.sourceDurationMilliseconds == 8000 && session.sourceSeekable == true)
            await ended.cancel()
        }
        _ = oldState
        // Seeking exactly to the end plays nothing; seeking back plays the right audio.
        let boundary = try await source.makeDecoder(start: CMTime(value: 8, timescale: 1), admission: .exactFrame)
        #expect(try await boundary.next() == nil)
        await boundary.cancel()
        let resumed = try await source.makeDecoder(start: CMTime(value: 6, timescale: 1), admission: .exactFrame)
        #expect(abs(resumed.startFrame - 288000) <= 12000 && resumed.sourceDurationMilliseconds == 8000)
        #expect(try await collect(resumed) == Array(expected(media, directory: directory).dropFirst(Int(resumed.startFrame))))
        await resumed.cancel()
    }

    @Test(arguments: [false, true])
    func changedFileDuringReopenIsNotPlayedWithOldDuration(proxyEnabled: Bool) async throws {
        let original = try wave(), changed = replacement(original), reopenCount = Mutex(0)
        let credentials = FeedCredentials(username: "native", password: "concurrent-cache")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "audio/wav", "Content-Length": String(original.count), "ETag": "\"old\""],
                body: Data(original.prefix(131072)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("native-reopen-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://native-reopen-cache.invalid/audio.wav")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let fresh = HTTPMediaRepresentation(length: Int64(changed.count), validation: .strongETag("\"new\""))
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache, reopen: {
            // Deterministically interleave replacement after the owner's initial
            // generation check and load retirement, before actual identification.
            if reopenCount.withLock({ $0 += 1; return $0 == 1 }) {
                try cache.invalidate(for: url, matching: cache.representation(for: url), generation: cache.generation(for: url))
                try cache.admit(fresh, for: url)
                let writer = try #require(try cache.beginWrite(for: url, at: 0, contentLength: Int64(changed.count)))
                try writer.append(changed); try writer.finish()
            }
            return try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        })
        let initial = try await source.makeDecoder()
        #expect(initial.sampleRate == 48000 && initial.sourceDurationMilliseconds == 8000)
        do {
            let stale = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
            Issue.record("Changed cache admitted with old period duration: \(String(describing: stale.sourceDurationMilliseconds))")
            await stale.cancel()
        } catch { #expect((error as? URLError)?.code == .resourceUnavailable) }
        server.stop()
        let recovered = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        #expect(recovered.sampleRate == 24000 && recovered.sourceDurationMilliseconds == 16000)
        #expect(abs(recovered.startFrame - 96000) <= 6000)
        #expect(try await collect(recovered) == Array(expected(changed, directory: directory).dropFirst(Int(recovered.startFrame))))
        await recovered.cancel()
    }

    @Test(arguments: [false, true], ["recover", "cancel", "exhaust"])
    func seekOutsideBufferedAudioAfterNetworkErrorsRecoversOrReportsError(proxyEnabled: Bool, outcome: String) async throws {
        let media = try wave(), count = Mutex(0)
        let credentials = FeedCredentials(username: "native", password: "fresh-load")
        let proxyAuthorization = "Basic " + Data("proxy:captured".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"native-load\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let attempt = count.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                return .init(headers: ["Content-Type": "audio/wav", "Content-Length": String(media.count), "ETag": "\"stable\""],
                    body: Data(media.prefix(131072)), keepConnectionOpen: true)
            }
            if attempt <= (outcome == "exhaust" ? 8 : 5) { return .init(status: 503) }
            let offset = Int(request.headers["range"]?.dropFirst(6).dropLast() ?? "") ?? 0
            return .init(status: 206, headers: ["Content-Type": "audio/wav", "ETag": "\"stable\"",
                "Content-Range": "bytes \(offset)-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(offset)))
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("native-load-reset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "captured") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://native-load.invalid/audio.wav")! : server.url
        let gate = NativeLoadRetryGate(); defer { gate.cancelAll() }
        let retry = PCMSourceRetry(sleep: gate.sleep)
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache, retry: retry)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let initial = try await source.makeDecoder()
        let initialState = try #require(initial.bufferState)
        try await waitForLoad { remote.input.snapshot().waitingReaders > 0 && retry.snapshot.prepared }
        let connection = try #require(server.requests.lastIndex { !proxyEnabled || $0.headers["proxy-authorization"] == proxyAuthorization })
        try await server.appendResponseBody(Data(), toConnectionAt: connection, isFinal: true)
        try await waitForLoad { gate.waiting == 1 }
        for attempt in 2...4 {
            gate.advance()
            try await waitForLoad { gate.waiting == 1 && count.withLock { $0 } == attempt }
        }
        try #require(retry.currentError != nil)
        // Seeking within already loaded audio still works while the network fails.
        let retained = try await source.makeDecoder(start: CMTime(value: 1, timescale: 2), admission: .exactFrame)
        #expect(abs(retained.startFrame - 24000) <= 12000 && retained.sourceDurationMilliseconds == 8000)
        _ = initialState
        let replacing = Task { try await source.makeDecoder(start: CMTime(value: 6, timescale: 1), admission: .exactFrame) }
        defer { replacing.cancel() }
        try await waitForLoad { count.withLock { $0 } == 5 && gate.waiting == 1 }
        let replacement: NativeAudioSourceDecoder
        if outcome == "cancel" {
            replacing.cancel()
            await #expect(throws: CancellationError.self) { try await replacing.value }
            replacement = try await source.makeDecoder(start: CMTime(value: 6, timescale: 1), admission: .exactFrame)
        } else if outcome == "exhaust" {
            for attempt in 6...7 {
                gate.advance()
                try await waitForLoad { gate.waiting == 1 && count.withLock { $0 } == attempt }
            }
            gate.advance()
            // Persistent failure is reported as the server error, not a hang.
            await #expect(throws: MediaDownloadError.httpStatus(503)) { try await replacing.value }
            replacement = try await source.makeDecoder(start: CMTime(value: 6, timescale: 1), admission: .exactFrame)
        } else {
            gate.advance()
            replacement = try await replacing.value
        }
        #expect(abs(replacement.startFrame - 288000) <= 12000 && replacement.sourceDurationMilliseconds == 8000)
        #expect(try await collect(replacement) == Array(expected(media, directory: directory).dropFirst(Int(replacement.startFrame))))
        await replacement.cancel()
    }

    @Test(arguments: [false, true], ["cancel", "reject", "supersede"])
    func interruptedSeekInLiveStreamStillRecovers(proxyEnabled: Bool, outcome: String) async throws {
#if SWIFT_PACKAGE
        let fixture = try #require(Bundle.module.url(forResource: "tone.aac", withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        let fixture = try #require(Bundle(for: NativeRecoveryFixtures.self).url(forResource: "tone.aac", withExtension: nil))
#endif
        let live = try Data(contentsOf: fixture), recorded = replacement(try wave()), count = Mutex(0)
        let credentials = FeedCredentials(username: "native", password: "reopen")
        let proxyAuthorization = "Basic " + Data("proxy:captured".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"native-reopen\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let attempt = count.withLock { $0 += 1; return $0 }
            #expect(request.headers["range"] == nil)
            if attempt == 1 {
                return .init(headers: ["Content-Type": "application/octet-stream"], body: Data(live.prefix(32768)),
                    keepConnectionOpen: true, includeAutomaticContentLength: false)
            }
            if attempt == 2 {
                if outcome == "reject" {
                    return .init(headers: ["Content-Type": "application/octet-stream"], body: Data([0, 0]))
                }
                return .init(headers: ["Content-Type": "application/octet-stream"], body: Data(recorded.prefix(2)),
                    keepConnectionOpen: true, includeAutomaticContentLength: false)
            }
            return .init(headers: ["Content-Type": "audio/wav", "ETag": "\"recorded\""], body: recorded)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("native-reopen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "captured") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://native-reopen.invalid/audio")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let initial = try await source.makeDecoder()
        #expect(initial.sourceSeekable == false && initial.sourceDurationMilliseconds == nil)
        let initialState = try #require(initial.bufferState)
        let interrupted = Task { try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame) }
        defer { interrupted.cancel() }
        try await waitForLoad { count.withLock { $0 } == 2 }
        let recovered: NativeAudioSourceDecoder
        if outcome == "reject" {
            do { let unexpected = try await interrupted.value; await unexpected.cancel(); Issue.record("Invalid replacement was admitted") }
            catch { #expect((error as? StreamingAudioTypeError) == .unrecognized) }
            recovered = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        } else if outcome == "cancel" {
            interrupted.cancel()
            await #expect(throws: CancellationError.self) { try await interrupted.value }
            recovered = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        } else {
            recovered = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
            await #expect(throws: CancellationError.self) { try await interrupted.value }
        }
        _ = initialState
        #expect(recovered.startFrame == 0 && recovered.sampleRate == 24000)
        #expect(recovered.sourceSeekable == true && recovered.sourceDurationMilliseconds == 16000)
        #expect(try await collect(recovered) == expected(recorded, directory: directory))
        await recovered.cancel()
        server.stop()
        // Later seeks play offline from the loaded recording.
        let retained = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        #expect(abs(retained.startFrame - 96000) <= 6000)
        #expect(try await collect(retained) == Array(expected(recorded, directory: directory).dropFirst(Int(retained.startFrame))))
        await retained.cancel()
    }

    @Test(arguments: [false, true])
    func startupRetryUsesNewFilesDurationAndAudio(proxyEnabled: Bool) async throws {
        let original = try wave(), newMedia = replacement(original), count = Mutex(0)
        // WAV can be identified before this legal JUNK chunk is complete, but
        // source metadata and audio preparation cannot yet finish.
        var partial = Data(original.prefix(36)) + Data("JUNK".utf8) + little(8192)
        partial.replaceSubrange(4..<8, with: little(original.count - 8 + 8200))
        partial.append(Data(repeating: 0, count: 4096 - partial.count))
        let prefix = partial
        let credentials = FeedCredentials(username: "native", password: "captured")
        let authorization = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != authorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"native-recovery\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            #expect(request.headers["range"] == nil)
            let first = count.withLock { $0 += 1; return $0 == 1 }
            if first {
                return .init(headers: ["Content-Type": "audio/wav", "Transfer-Encoding": "chunked"],
                    body: Data("1000\r\n".utf8) + prefix + Data("\r\n".utf8), keepConnectionOpen: true)
            }
            return .init(headers: ["Content-Type": "audio/wav"], body: newMedia)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("native-startup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://native-startup.invalid/audio.wav")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let decoder = try await source.makeDecoder()
        #expect(decoder.sampleRate == 24000 && decoder.sourceDurationMilliseconds == 16000 && decoder.sourceSeekable == true)
        #expect(try await collect(decoder) == expected(newMedia, directory: directory))
        await decoder.cancel()
    }

    @Test(arguments: ["changed206", "changed200", "unchanged206"], [false, true])
    func seekAfterServerFileChangedNeverMixesOldAndNewAudio(response: String, proxyEnabled: Bool) async throws {
        let original = try wave(), newMedia = replacement(original), count = Mutex(0)
        let credentials = FeedCredentials(username: "native", password: "identity")
        let authorization = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let changed = response.hasPrefix("changed")
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != authorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"native-identity\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let attempt = count.withLock { $0 += 1; return $0 }
            let first = attempt == 1
            if first {
                return .init(headers: ["Content-Type": "audio/wav", "Content-Length": String(original.count), "ETag": "\"old\""],
                    body: Data(original.prefix(131072)), keepConnectionOpen: true)
            }
            let bytes = changed ? newMedia : original
            let full = response == "changed200" || request.headers["range"] == nil
            let start = full ? 0 : Int(request.headers["range"]!.dropFirst(6).dropLast())!
            return .init(status: full ? 200 : 206, headers: ["Content-Type": "audio/wav", "ETag": changed ? "\"new\"" : "\"old\"",
                "Content-Range": "bytes \(start)-\(bytes.count - 1)/\(bytes.count)"], body: Data(bytes.dropFirst(start)))
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("native-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://native-identity.invalid/audio.wav")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let old = try await source.makeDecoder()
        #expect(old.sampleRate == 48000 && old.sourceDurationMilliseconds == 8000 && count.withLock { $0 } == 1)
        // End this declared finite response early after successful preparation.
        // Its actual short-body failure wakes retry without an idle-timeout wait.
        let connection = try #require(server.requests.lastIndex { !proxyEnabled || $0.headers["proxy-authorization"] == authorization })
        try await server.appendResponseBody(Data(), toConnectionAt: connection, isFinal: true)
        if changed {
            do {
                let stale = try await source.makeDecoder(start: CMTime(value: 6, timescale: 1), admission: .exactFrame)
                await stale.cancel()
                Issue.record("Changed source used old audio metadata")
            } catch { #expect((error as? URLError)?.code == .resourceUnavailable) }
        }
        let decoder = try await source.makeDecoder(start: CMTime(value: 6, timescale: 1), admission: .exactFrame)
        let frames = Int64((changed ? 24000 : 48000) * 6)
        #expect(abs(decoder.startFrame - frames) <= frames / 24)
        #expect(decoder.sourceDurationMilliseconds == (changed ? 16000 : 8000))
        #expect(try await collect(decoder) == Array(expected(changed ? newMedia : original, directory: directory).dropFirst(Int(decoder.startFrame))))
        await decoder.cancel()
    }

    @Test func cancelledStartupCanBeRetriedAndPlays() async throws {
        let original = try wave(), newMedia = replacement(original), count = Mutex(0)
        var partial = Data(original.prefix(36)) + Data("JUNK".utf8) + little(8192)
        partial.replaceSubrange(4..<8, with: little(original.count - 8 + 8200))
        partial.append(Data(repeating: 0, count: 4096 - partial.count))
        let prefix = partial
        let server = try await LoopbackHTTPServer.start { _ in
            if count.withLock({ $0 += 1; return $0 == 1 }) {
                return .init(headers: ["Content-Type": "audio/wav", "Transfer-Encoding": "chunked"],
                    body: Data("1000\r\n".utf8) + prefix + Data("\r\n".utf8), keepConnectionOpen: true)
            }
            return .init(headers: ["Content-Type": "application/octet-stream", "Content-Length": String(newMedia.count)],
                body: Data(newMedia.prefix(2)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("native-startup-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let remote = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        let preparing = Task { try await source.makeDecoder() }
        defer { preparing.cancel() }
        let deadline = ContinuousClock.now + .seconds(12)
        while !(count.withLock({ $0 }) == 2 && remote.input.snapshot().waitingReaders > 0), ContinuousClock.now < deadline { await Task.yield() }
        try #require(count.withLock { $0 } == 2 && remote.input.snapshot().waitingReaders > 0)
        preparing.cancel()
        await #expect(throws: CancellationError.self) { try await preparing.value }
        try await server.appendResponseBody(Data(newMedia.dropFirst(2)), toConnectionAt: 1, isFinal: true)
        let decoder = try await source.makeDecoder()
        #expect(decoder.sampleRate == 24000 && decoder.sourceDurationMilliseconds == 16000)
        #expect(try await collect(decoder) == expected(newMedia, directory: directory))
        await decoder.cancel()
    }

    @Test func replacedCachedFilePlaysWithNewDurationAndAudio() async throws {
        let original = try wave(), newMedia = replacement(original)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/wav", "ETag": "\"old\""], body: original)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("native-generation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let remote = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        let source = try NativeAudioPlaybackSource(remote: remote, url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        let old = try await source.makeDecoder()
        #expect(try await collect(old) == expected(original, directory: directory))
        await old.cancel()
        try cache.invalidate(for: server.url, matching: cache.representation(for: server.url), generation: cache.generation(for: server.url))
        let fresh = HTTPMediaRepresentation(length: Int64(newMedia.count), validation: .strongETag("\"new\""))
        try cache.admit(fresh, for: server.url)
        let writer = try #require(try cache.beginWrite(for: server.url, at: 0, contentLength: Int64(newMedia.count)))
        try writer.append(newMedia); try writer.finish()
        server.stop()
        let recovered = try await source.makeDecoder(start: CMTime(value: 4, timescale: 1), admission: .exactFrame)
        #expect(recovered.sampleRate == 24000 && recovered.sourceDurationMilliseconds == 16000)
        #expect(abs(recovered.startFrame - 96000) <= 6000)
        #expect(try await collect(recovered) == Array(expected(newMedia, directory: directory).dropFirst(Int(recovered.startFrame))))
        await recovered.cancel()
    }
}
private final class NativeRecoveryFixtures: NSObject {}

private final class NativeLoadRetryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var cancelled: Set<UUID> = []
    private var history: [Int64] = []
    var delays: [Int64] { lock.withLock { history } }
    var waiting: Int { lock.withLock { held.count } }
    func sleep(_ milliseconds: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelled.remove(id) != nil { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                history.append(milliseconds); held.append((id, continuation))
                lock.unlock()
            }
        } onCancel: { self.cancel(id) }
    }
    func advance() {
        let next = lock.withLock { held.isEmpty ? nil : held.removeFirst().1 }
        next?.resume()
    }
    private func cancel(_ id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard let index = held.firstIndex(where: { $0.0 == id }) else { cancelled.insert(id); return nil }
            return held.remove(at: index).1
        }
        continuation?.resume(throwing: CancellationError())
    }
    func cancelAll() {
        let pending = lock.withLock { let values = held; held.removeAll(); return values }
        for (_, continuation) in pending { continuation.resume(throwing: CancellationError()) }
    }
}

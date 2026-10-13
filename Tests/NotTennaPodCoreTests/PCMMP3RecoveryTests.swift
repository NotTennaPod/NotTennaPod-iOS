import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PCMMP3RecoveryTests {
    enum Kind: CaseIterable { case xing, info, plain, mllt }
    private final class Transport: PCMVolumePresentationTransport {
        var currentTime = CMTime.zero
        var onTimeChanged: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        var playing = false, closed = false
        var buffers: [CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>] = []
        func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws { buffers.append(buffer) }
        func setRendererVolume(_ volume: Float) {}
        func setPlaying(_ playing: Bool, at time: CMTime) { self.playing = playing; currentTime = time }
        func observeEnd(_ time: CMTime) {}
        func finishEnqueuing() {}
        func stopMonitoring() {}
        func close() { closed = true; playing = false }
        func advance(milliseconds: Int64) {
            currentTime = CMTime(value: milliseconds, timescale: 1000); onTimeChanged?()
        }
    }
    private func media(_ kind: Kind) throws -> Data {
        let name = kind == .plain || kind == .mllt ? "playback-unknown-duration" : "playback-30sec"
#if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Fixtures")!
#else
        let url = Bundle(for: MP3RecoveryFixtures.self).url(forResource: name, withExtension: "mp3")!
#endif
        var bytes = try Data(contentsOf: url)
        if kind == .info { bytes.replaceSubrange(21..<25, with: Data("Info".utf8)) }
        if kind == .mllt { bytes = MP3RequiredID3MetadataTests.playbackTag() + bytes }
        return bytes
    }
    private func store(url: URL) async throws -> (FeedLibraryStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "MP3 source", episodes: [
            .init(identifier: "one", title: "Episode", media: .init(url: url.absoluteString,
                size: 0, durationMilliseconds: 12345))]), source: "https://example.test/feed",
            responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = .lightReduction }
        return (store, directory)
    }

    @Test(arguments: Kind.allCases, [false, true])
    func mp3SeekabilityDurationAndSavedStateFollowTheSource(kind: Kind, knownLength: Bool) async throws {
        let bytes = try media(kind)
        let server = try await LoopbackHTTPServer.start { _ in
            knownLength ? .init(headers: ["Content-Type": "audio/mpeg"], body: bytes)
                : .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                    body: Data("\(String(bytes.count, radix: 16))\r\n".utf8) + bytes + Data("\r\n0\r\n\r\n".utf8))
        }
        defer { server.stop() }
        let (store, directory) = try await store(url: server.url)
        defer { try? FileManager.default.removeItem(at: directory) }
        var outputs: [Transport] = []
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), makeFactory: {
            try PCMRecoveryFactory(mp3URL: $0, proxy: PodcastProxy(), makeTransport: {
                let output = Transport(); outputs.append(output); return output
            })
        }, positionTicker: PCMPlaybackEngineTests.Ticker(), now: { 5000 })
        defer { engine.unload() }
        let player = PlaybackCoordinator(store: store, engine: engine, clock: { Date(timeIntervalSince1970: 5) })
        let seekable = kind != .plain || knownLength
        let duration: Int32 = kind == .plain ? (knownLength ? 29900 : 30024) : kind == .mllt ? 30000 : 30040
        var stage = "prepare"
        do {
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused || player.phase == .failed }
            try #require(player.phase == .paused && outputs.count == 1)
            #expect(engine.reading?.sample.seekable == seekable)
            // EOF now resolves the unknown no-Xing period from the original
            // last packet PTS +10ms; seekability and saved feed duration differ.
            stage = "EOF source duration"
            func near(_ value: Int32?) -> Bool { abs(Int(value ?? 0) - Int(duration)) <= 50 }
            try await wait { near(engine.reading?.sample.durationMilliseconds) }
            #expect(near(engine.reading?.sample.durationMilliseconds))
            #expect(player.volumeAdaptation == .lightReduction && !outputs[0].playing)
            stage = "initial playback"
            try await player.play()
            try await wait { outputs[0].playing }
            outputs[0].advance(milliseconds: 100)
            try await player.pause()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
            // Only a seekable source's duration replaces the feed's saved duration.
            func savedDurationOK(_ saved: Int32?) -> Bool { seekable ? near(saved) : saved == 12345 }
            #expect(savedDurationOK(try await store.episode(id: 1)?.details.media?.durationMilliseconds))
            try await player.setSpeed(1.5)
            try await player.setSkipSilence(true)
            stage = "paused seek"
            try await player.seek(to: 4000)
            try await wait { outputs.count == 2 && engine.reading?.buffering == false }
            let position = try #require(engine.reading?.sample.positionMilliseconds)
            #expect(seekable ? (4000...4100).contains(position) : position == 0)
            #expect(engine.reading?.sample.seekable == seekable && engine.reading?.speed == 1.5)
            #expect(engine.reading?.skipSilence == true && player.volumeAdaptation == .lightReduction)
            // ProgressiveMediaPeriod.seekToUs resets initially-live loading, even after EOF.
            // Finite/MLLT sources retain their buffered load.
            #expect(outputs[0].closed && !outputs[1].playing)
            stage = "resumed playback"
            try await player.play()
            try await wait { outputs[1].playing }
            try await player.stop()
            #expect(savedDurationOK(try await store.episode(id: 1)?.details.media?.durationMilliseconds))
            engine.unload(); try await store.close()
            let reopened = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            #expect(savedDurationOK(try await reopened.episode(id: 1)?.details.media?.durationMilliseconds))
            try await reopened.close()
        } catch {
            print("MP3 recovery failure at \(stage), kind=\(kind), knownLength=\(knownLength), reading=\(String(describing: engine.reading)), outputs=\(outputs.count), playing=\(outputs.map(\.playing))")
            engine.unload(); try? await store.close(); throw error
        }
    }

    @Test(arguments: [false, true], [false, true])
    func unknownLengthMP3SeekAndRecoveryKeepPositionAndSettings(proxyEnabled: Bool, hasMLLT: Bool) async throws {
        // V2.4 native MLLT coverage complements the v2.3 persistent-store cases.
        let bytes = hasMLLT ? MP3RequiredID3MetadataTests.playbackTag(version: 4) + (try media(.plain)) : try media(.plain)
        let login = FeedCredentials(username: "mp3", password: "captured")
        let proxyAuth = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuth {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"source\""])
            }
            guard request.headers["authorization"] == login.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"source\""])
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                body: Data("\(String(bytes.count, radix: 16))\r\n".utf8) + bytes + Data("\r\n".utf8),
                keepConnectionOpen: true)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!,
            username: "proxy", password: "saved") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://mp3-recovery.invalid/audio.mp3")! : server.url
        let factory = try PCMRecoveryFactory(mp3URL: url, proxy: proxy, credentials: login,
            makeTransport: { NativeSampleBufferTransport(muted: true) })
        func acceptedRequests() -> [LoopbackHTTPServer.Request] {
            server.requests.filter { $0.headers["authorization"] == login.authorization(utf8: false)
                && (!proxyEnabled || $0.headers["proxy-authorization"] == proxyAuth) }
        }
        let initial = try await factory.make(positionMilliseconds: 4000,
            parameters: .init(speed: 1.5, skipSilence: true, volume: .lightReduction))
        #expect(initial.state == .idle && !initial.wantsPlayback)
        #expect(initial.sourceSeekable == hasMLLT)
        #expect(initial.sourceDurationMilliseconds == (hasMLLT ? 30000 : nil))
        #expect(!acceptedRequests().isEmpty)
        initial.close()
        let owner = PCMRecoverySession(positionMilliseconds: 4000,
            parameters: .init(speed: 1.5, skipSilence: true, volume: .lightReduction),
            lastPlayedMilliseconds: { 0 }, synchronizeStatistics: {}, factory: { position, parameters in
                try await factory.make(positionMilliseconds: position, parameters: parameters)
            })
        defer { owner.close() }
        try await owner.seekPaused(to: 4000)
        let firstPosition = try owner.positionMilliseconds
        #expect(hasMLLT ? (4000...4100).contains(firstPosition) : firstPosition == 0)
        #expect(owner.sourceSeekable == hasMLLT)
        #expect(owner.sourceDurationMilliseconds == (hasMLLT ? 30000 : nil))
        try owner.play()
        do {
            try await wait("initial native rendering") { try owner.positionMilliseconds > firstPosition + 500 }
        } catch {
            print("initial native rendering diagnostic: state=\(String(describing: owner.outputState)), failure=\(String(describing: owner.failure)), position=\(String(describing: try? owner.positionMilliseconds)), duration=\(String(describing: owner.sourceDurationMilliseconds))")
            throw error
        }
        try owner.pause()
        try owner.setVolumeAdaptation(.heavyReduction)
        try await owner.setParameters(speed: 2, skipSilence: false)
        try await owner.recoverPaused(to: 2000)
        let recoveredPosition = try owner.positionMilliseconds
        #expect(hasMLLT ? (2000...2100).contains(recoveredPosition) : recoveredPosition == 0)
        #expect(owner.outputState == .paused && owner.sourceSeekable == hasMLLT)
        #expect(owner.parameters == .init(speed: 2, skipSilence: false, volume: .heavyReduction))
        try owner.play()
        do {
            try await wait("recovered native rendering") { try owner.positionMilliseconds > recoveredPosition + 500 }
        } catch {
            print("recovered native rendering diagnostic: state=\(String(describing: owner.outputState)), failure=\(String(describing: owner.failure)), position=\(String(describing: try? owner.positionMilliseconds)), duration=\(String(describing: owner.sourceDurationMilliseconds))")
            throw error
        }
        try owner.pause()
    }

    private func wait(_ stage: String = "", _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        // Yielding alone can immediately reacquire MainActor in a tight loop.
        // Poll the actual native state without monopolizing its event delivery;
        // retain the same five-second deadline and outcome assertion.
        while try !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(try condition(), "\(stage)")
    }
}
private final class MP3RecoveryFixtures: NSObject {}

import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct LocalPlaybackAssetLoaderTests {
    private struct Fixture {
        let root, folder, file: URL
        let store: FeedLibraryStore
        let episode: LibraryEpisode
        let access: LocalPlaybackAccess
        let events: Events
    }
    private final class Events: Sendable {
        private let values = Mutex<[String]>([])
        func record(_ value: String) { values.withLock { $0.append(value) } }
        func count(_ value: String) -> Int { values.withLock { $0.filter { $0 == value }.count } }
    }
    private final class Gate: Sendable {
        private let state = Mutex(false)
        private let signal = DispatchSemaphore(value: 0)
        var entered: Bool { state.withLock { $0 } }
        func hold() { state.withLock { $0 = true }; signal.wait() }
        func release() { signal.signal() }
    }
    private func fixture(_ name: String = "tone.wav", opaque: Bool = false,
        customize: (inout LocalPlaybackAccess.Environment) -> Void = { _ in },
        _ body: (Fixture) async throws -> Void) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("LocalAsset-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("registered")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(Bundle.module.url(forResource: name, withExtension: nil,
            subdirectory: name.hasPrefix("playback-") ? "Fixtures" : "Fixtures/StreamingFormats"))
        let file = folder.appendingPathComponent(opaque ? "你好 # %.media" : name)
        try FileManager.default.copyItem(at: source, to: file)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let events = Events()
        var environment = LocalPlaybackAccess.Environment()
        environment.start = { _ in events.record("start"); return true }
        environment.stop = { _ in events.record("stop") }
        customize(&environment)
        do {
            let registration = try await store.registerLocalFolder(title: "Local", directoryIdentity: folder.absoluteString,
                bookmark: LocalFolderDocuments.makeBookmark(directory: folder))
            let size = Int64(try Data(contentsOf: file).count)
            let mime = name.hasSuffix("mp3") ? "audio/mpeg" : name.hasSuffix("m4a") ? "audio/mp4" : "audio/wav"
            _ = try await store.applyLocalFolderScan(.init(format: .rss, title: "Local", episodes: [
                .init(identifier: "local", title: "Local media", link: file.lastPathComponent,
                      media: .init(url: file.absoluteString, size: size, mimeType: mime))]), context: registration)
            _ = try await store.enqueue([1])
            let episode = try #require(try await store.episode(id: 1))
            try await body(Fixture(root: root, folder: folder, file: file, store: store, episode: episode,
                access: LocalPlaybackAccess(store: store, environment: environment), events: events))
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
    private func wait(_ check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !check(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(check())
    }
    private func decode(_ asset: AVAsset, start: Int64) async throws -> Data {
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        let provider = reader.outputProvider(for: output)
        reader.timeRange = CMTimeRange(start: CMTime(value: start, timescale: 1000), duration: CMTime(value: 1, timescale: 1))
        try reader.start()
        defer { reader.cancelReading() }
        var bytes = Data()
        while let sample = try await provider.next() {
            let data = try sample.withUnsafeSampleBuffer { buffer in
                let block = try #require(CMSampleBufferGetDataBuffer(buffer))
                var data = Data(count: CMBlockBufferGetDataLength(block))
                let status = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                #expect(status == kCMBlockBufferNoErr)
                return data
            }
            bytes.append(data)
        }
        try #require(reader.status == .completed, "\(String(describing: reader.error))")
        return bytes
    }

    @Test(arguments: ["tone.wav", "tone.m4a", "tone-tail.m4a"], [false, true])
    func realAssetDecodingAndSeekMatchNativeFileWithoutEscapingURL(name: String, opaque: Bool) async throws {
        try await fixture(name, opaque: opaque) { f in
            let document = try #require(try await f.access.open(episode: f.episode))
            defer { document.close() }
            let loader = LocalPlaybackAssetLoader(document: document)
            defer { loader.cancel() }
            #expect(!loader.asset.url.isFileURL && !loader.asset.url.absoluteString.contains(f.folder.path))
            let direct = AVURLAsset(url: f.file, options: AVPlayerPlaybackEngine.assetOptions(for: f.episode, url: f.file))
            let expectedDuration = try await direct.load(.duration)
            #expect(try await loader.asset.load(.duration) == expectedDuration)
            for position: Int64 in [0, 5000, 1000] {
                let expected = try await decode(direct, start: position)
                let actual = try await decode(loader.asset, start: position)
                #expect(!expected.isEmpty && actual == expected)
            }
            #expect(await loader.snapshot().failure == nil)
            #expect(try await f.store.episode(id: 1) == f.episode)
        }
    }

    @Test func assetShortReadsProduceTheSameDecodedAudio() async throws {
        try await fixture(customize: { environment in
            let read = environment.read
            environment.read = { file, offset, count in try read(file, offset, min(count, 997)) }
        }) { f in
            let document = try #require(try await f.access.open(episode: f.episode)); defer { document.close() }
            let loader = LocalPlaybackAssetLoader(document: document); defer { loader.cancel() }
            let expected = try await decode(AVURLAsset(url: f.file), start: 2000)
            #expect(try await decode(loader.asset, start: 2000) == expected)
        }
    }

    @Test func cancellingAssetDuringReadRetiresRequestsButAnotherAssetCanUseDocument() async throws {
        let gate = Gate(), first = Mutex(true)
        defer { gate.release() }
        try await fixture(customize: { environment in
            let read = environment.read
            environment.read = { file, offset, count in
                if first.withLock({ let value = $0; $0 = false; return value }) { gate.hold() }
                return try read(file, offset, count)
            }
        }) { f in
            let document = try #require(try await f.access.open(episode: f.episode)); defer { document.close() }
            let old = LocalPlaybackAssetLoader(document: document)
            let task = Task { try await old.asset.load(.duration) }; defer { task.cancel() }
            try await wait { gate.entered }; old.cancel(); gate.release()
            await #expect(throws: (any Error).self) { try await task.value }
            let state = await old.snapshot()
            #expect(state.cancelled && state.pendingRequests == 0)
            #expect(f.events.count("stop") == 0)
            let replacement = LocalPlaybackAssetLoader(document: document); defer { replacement.cancel() }
            #expect(try await replacement.asset.load(.duration).seconds == 8)
        }
    }

    @Test func AVPlayerLoadsMovedRegistrationSeeksAndPausesWithoutLosingGrant() async throws {
        try await fixture { f in
            try FileManager.default.moveItem(at: f.folder, to: f.root.appendingPathComponent("moved"))
            #expect(!FileManager.default.fileExists(atPath: f.file.path))
            let document = try #require(try await f.access.open(episode: f.episode)); defer { document.close() }
            let engine = AVPlayerPlaybackEngine(muted: true, localDocument: document)
            defer { engine.unload() }
            var failure: String?
            engine.onEvent = { if case .failed(_, let message) = $0 { failure = message } }
            engine.load(episode: f.episode, generation: UUID(), positionMilliseconds: 2000)
            try await wait { engine.reading?.isPrepared == true || failure != nil }
            try #require(failure == nil && engine.reading?.sample.positionMilliseconds == 2000)
            engine.seek(to: 5000, commandID: UUID())
            try await wait { engine.nativePlayer?.currentTime().seconds ?? 0 >= 5 }
            engine.play(commandID: UUID())
            try await wait { engine.nativePlayer?.currentTime().seconds ?? 0 > 5.15 }
            engine.pause(commandID: UUID())
            #expect(engine.nativePlayer?.rate == 0 && engine.reading?.sample.status == .paused)
            #expect(f.events.count("stop") == 0)
            let loader = try #require(engine.localSource)
            engine.unload()
            #expect(await loader.snapshot().cancelled)
            #expect(try await document.read(at: 0, maximumCount: 4) == Data("RIFF".utf8))
            document.close(); try await wait { f.events.count("stop") == 1 }
        }
    }

    private func application(_ f: Fixture, routes: Routes) -> ApplicationPlaybackEngine {
        let factory = PCMPlaybackFactory(cacheDirectory: f.root.appendingPathComponent("cache"),
            makeTransport: { NativeSampleBufferTransport(muted: true) })
        let engine = ApplicationPlaybackEngine(muted: true, source: { _ in throw PlaybackSourceError.invalidURL },
            localAccess: f.access, factories: factory, makePCMEngine: { factory, url in
                routes.processed += 1
                return PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(),
                    resolveFactory: { _, _ in factory }, source: { _ in url })
            })
        // The app's PlaybackCoordinator always binds listening statistics; the processed
        // engine refuses to prepare without them, as it would in the app.
        engine.bindStatistics(lastPlayed: { _ in 0 }, synchronize: { _ in })
        return engine
    }
    private final class Routes { var processed = 0 }

    @Test(arguments: ["playback-30sec.mp3", "tone.wav", "tone.m4a", "tone-tail.m4a"])
    func selectedApplicationRoutesPlaySeekRetireAndReopenRegisteredDocuments(name: String) async throws {
        try await fixture(name, opaque: true) { f in
            let routes = Routes()
            let engine = application(f, routes: routes)
            let coordinator = PlaybackCoordinator(store: f.store, engine: engine)
            defer { engine.unload() }
            try await coordinator.select(episodeID: 1, play: false)
            try await wait { coordinator.phase == .paused || coordinator.phase == .failed }
            try #require(coordinator.phase == .paused)
            // Registered local media of every supported format plays through the processed
            // engine, so skip silence is offered for it as on Android (ExoPlayer applies it to
            // any decoded audio).
            #expect(engine.supportsSkipSilence)
            #expect(routes.processed == 1)
            try await coordinator.play()
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 100 }
            try await coordinator.pause()
            let paused = engine.reading?.sample.positionMilliseconds
            #expect(paused != nil && f.events.count("stop") == 0)
            engine.seek(to: 3000, commandID: UUID())
            try await wait { engine.reading?.isPrepared == true && (engine.reading?.sample.positionMilliseconds ?? 0) >= 3000 }
            #expect(try await f.store.downloadJobs(activeOnly: false).isEmpty)
            #expect(try await f.store.queue().map(\.id) == [1])
            #expect(try await f.store.episode(id: 1)?.userState.isDownloaded == false)
            engine.unload(); try await wait { f.events.count("stop") == 1 }
            engine.load(episode: try #require(try await f.store.episode(id: 1)), generation: UUID(), positionMilliseconds: 1000)
            try await wait { engine.reading?.isPrepared == true }
            #expect(f.events.count("start") == 2 && f.events.count("stop") == 1)
            engine.unload(); try await wait { f.events.count("stop") == 2 }
        }
    }

    @Test func missingRegisteredMediaFailsSelectedLoadAndRecoveryReopensWithoutDownload() async throws {
        try await fixture { f in
            let saved = f.root.appendingPathComponent("saved.wav")
            try FileManager.default.moveItem(at: f.file, to: saved)
            let engine = application(f, routes: Routes())
            defer { engine.unload() }
            var failures = 0
            engine.onEvent = { if case .failed = $0 { failures += 1 } }
            engine.load(episode: f.episode, generation: UUID(), positionMilliseconds: 0)
            try await wait { failures == 1 && f.events.count("stop") == 1 }
            #expect(engine.reading == nil)
            #expect(try await f.store.downloadJobs(activeOnly: false).isEmpty)
            #expect(try await f.store.episode(id: 1) == f.episode)
            try FileManager.default.moveItem(at: saved, to: f.file)
            engine.load(episode: f.episode, generation: UUID(), positionMilliseconds: 0)
            try await wait { engine.reading?.isPrepared == true }
            #expect(failures == 1)
        }
    }

    @Test func registeredMP3ShortReadsPreserveNativeDecodedAudioAndDecoderReselection() async throws {
        try await fixture("playback-30sec.mp3", opaque: true, customize: { environment in
            let read = environment.read
            environment.read = { file, offset, count in try read(file, offset, min(count, 997)) }
        }) { f in
            let reference = try AVAudioFile(forReading: f.file)
            let rate = reference.processingFormat.sampleRate
            let document = try #require(try await f.access.open(episode: f.episode)); defer { document.close() }
            let file = try LocalAudioBytes(document: document)
            #expect(try await file.identify() == .mp3)
            let source = NativeMP3PlaybackSource(localURL: URL(string: "antennapod-local://test/media")!, file: file)
            // Short reads through the registered-folder grant must not change the audio:
            // the same decoder over the ordinary file is the control.
            let control = NativeMP3PlaybackSource(localURL: f.file, file: try LocalAudioBytes(url: f.file))
            for target: Int64 in [0, 5000, 0] {
                let direct = try await control.makeDecoder(start: CMTime(value: target, timescale: 1000), prepareSourceTimeline: true)
                var expected = [Int16]()
                while let packet = try await direct.next() { expected += packet.samples }
                await direct.cancel()
                let decoder = try await source.makeDecoder(start: CMTime(value: target, timescale: 1000), prepareSourceTimeline: true)
                var actual = [Int16]()
                while let packet = try await decoder.next() { actual += packet.samples }
                #expect(!actual.isEmpty && decoder.sourceSeekable == true)
                #expect(abs(decoder.startTime.seconds - Double(target) / 1000) <= 0.25)
                #expect(actual == expected)
                if target == 0 {
                    // The whole episode is decoded (within 50 ms of the file's length).
                    #expect(abs(Double(actual.count / decoder.channels) - Double(reference.length)) <= rate * 0.05)
                }
                await decoder.cancel()
                #expect(f.events.count("stop") == 0)
            }
            document.close(); try await wait { f.events.count("stop") == 1 }
        }
    }

    @Test func accessDeniedDuringIdentificationFailsWithoutFallbackOrDownloadAndCanReopen() async throws {
        let denied = Mutex(true)
        try await fixture(customize: { environment in
            let read = environment.read
            environment.read = { file, offset, count in
                if denied.withLock({ $0 }) { throw POSIXError(.EACCES) }
                return try read(file, offset, count)
            }
        }) { f in
            let routes = Routes()
            let engine = application(f, routes: routes)
            defer { engine.unload() }
            var failures = 0, ready = 0
            engine.onEvent = { if case .failed = $0 { failures += 1 }; if case .ready = $0 { ready += 1 } }
            engine.load(episode: f.episode, generation: UUID(), positionMilliseconds: 0)
            try await wait { failures == 1 && f.events.count("stop") == 1 }
            #expect(ready == 0 && engine.reading == nil && routes.processed == 0)
            #expect(try await f.store.downloadJobs(activeOnly: false).isEmpty)
            #expect(try await f.store.episode(id: 1) == f.episode)
            denied.withLock { $0 = false }
            engine.load(episode: f.episode, generation: UUID(), positionMilliseconds: 0)
            try await wait { engine.reading?.isPrepared == true }
            #expect(failures == 1 && ready == 1)
            engine.unload(); try await wait { f.events.count("stop") == 2 }
        }
    }

    @MainActor private final class AsyncGate {
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { waiting = true; continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private final class Backend: PlaybackEngine {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        var loaded = 0, unloaded = 0
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            loaded += 1
            reading = .init(generation: generation, sample: .init(positionMilliseconds: 0, durationMilliseconds: 8000, status: .paused))
            onEvent?(.ready(reading!))
        }
        func play(commandID: UUID) {}
        func pause(commandID: UUID) {}
        func seek(to positionMilliseconds: Int64, commandID: UUID) {}
        func setSpeed(_ speed: Float, commandID: UUID) throws {}
        func unload() { unloaded += 1; reading = nil }
    }

    @Test func latePreparedSelectionAndCurrentFailureRetireOnlyTheirOwnGrant() async throws {
        try await fixture { f in
            let first = try #require(try await f.access.open(episode: f.episode))
            let second = try #require(try await f.access.open(episode: f.episode))
            let gate = AsyncGate(), old = Backend(), current = Backend()
            var count = 0, ready = 0, failures = 0
            let engine = ApplicationPlaybackEngine(resolvePrepared: { _ in
                count += 1
                if count == 1 { return { await gate.hold(); return .init(engine: old, document: first) } }
                return { .init(engine: current, document: second) }
            })
            defer { engine.unload(); gate.release(); first.close(); second.close() }
            engine.onEvent = {
                if case .ready = $0 { ready += 1 }
                if case .failed = $0 { failures += 1 }
            }
            engine.load(episode: f.episode, generation: UUID(), positionMilliseconds: 0)
            try await wait { gate.waiting }
            let generation = UUID()
            engine.load(episode: f.episode, generation: generation, positionMilliseconds: 0)
            try await wait { current.loaded == 1 }
            #expect(f.events.count("stop") == 0)
            gate.release(); try await wait { old.unloaded == 1 && f.events.count("stop") == 1 }
            #expect(old.loaded == 0 && ready == 1 && failures == 0)
            #expect(try await second.read(at: 0, maximumCount: 4) == Data("RIFF".utf8))
            current.onEvent?(.failed(generation: generation, message: "decoder failed"))
            try await wait { f.events.count("stop") == 2 }
            #expect(current.unloaded == 1 && failures == 1 && engine.reading == nil)
        }
    }

    @Test func registrationChangedDuringFormatProbeCannotAttachPreparedBackend() async throws {
        let gate = Gate(), first = Mutex(true); defer { gate.release() }
        try await fixture(customize: { environment in
            let read = environment.read
            environment.read = { file, offset, count in
                if first.withLock({ let value = $0; $0 = false; return value }) { gate.hold() }
                return try read(file, offset, count)
            }
        }) { f in
            let engine = application(f, routes: Routes()); defer { engine.unload() }
            var failures = 0, ready = 0
            engine.onEvent = { if case .failed = $0 { failures += 1 }; if case .ready = $0 { ready += 1 } }
            engine.load(episode: f.episode, generation: UUID(), positionMilliseconds: 0)
            try await wait { gate.entered }
            _ = try await f.store.beginLocalFolderScan(feedID: 1)
            gate.release()
            try await wait { failures == 1 && f.events.count("stop") == 1 }
            #expect(ready == 0 && engine.reading == nil)
        }
    }

    @Test func unloadDuringFormatProbeCannotAttachLateEngineOrLeakGrant() async throws {
        let gate = Gate(); defer { gate.release() }
        try await fixture(customize: { environment in
            let read = environment.read
            environment.read = { file, offset, count in gate.hold(); return try read(file, offset, count) }
        }) { f in
            let engine = application(f, routes: Routes())
            var events = 0; engine.onEvent = { _ in events += 1 }
            engine.load(episode: f.episode, generation: UUID(), positionMilliseconds: 0)
            try await wait { gate.entered }; engine.unload(); gate.release()
            try await wait { f.events.count("stop") == 1 }
            #expect(events == 0 && engine.reading == nil)
        }
    }
}

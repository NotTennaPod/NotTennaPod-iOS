import AVFoundation
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct PlaybackVolumeTapTests {
    private enum Failure: Error { case timedOut }
    private final class Events {
        var ready: [PlaybackEngineReading] = []
        var failures: [String] = []
    }
    private func episode(file: URL) -> LibraryEpisode {
        var state = EpisodeUserState(); state.isDownloaded = true; state.localFileURL = file.path
        return LibraryEpisode(id: 1, details: .init(identifier: "one", title: "Volume test", media: .init(url: file.absoluteString, size: 0)), userState: state)
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            if ContinuousClock.now >= deadline { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func withEngine(_ body: (AVPlayerPlaybackEngine, Events) async throws -> Void) async throws {
        let engine = AVPlayerPlaybackEngine(muted: true)
        let events = Events()
        engine.onEvent = {
            if case .ready(let reading) = $0 { events.ready.append(reading) }
            if case .failed(_, let message) = $0 { events.failures.append(message) }
        }
        defer { engine.unload() }
        try await body(engine, events)
    }
    @Test func volumeMixProcessesActualDecodedAudioAndChangesWithoutRestartingPlayback() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Volume-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 8))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][index] = 0.01 * sin(Float(index) * 2 * .pi * 440 / 48000)
            }
        }
        do { let output = try AVAudioFile(forWriting: file, settings: format.settings); try output.write(from: buffer) }
        try await withEngine { engine, events in
            engine.measureVolumeForTesting = true
            engine.load(episode: episode(file: file), generation: UUID(), positionMilliseconds: 0)
            try engine.setVolumeAdaptation(.heavyReduction)
            try await wait { !events.ready.isEmpty || !events.failures.isEmpty }
            #expect(events.failures.isEmpty)
            let player = try #require(engine.nativePlayer)
            let tap = try #require(engine.volumeTap)
            engine.play(commandID: UUID())
            for setting in FeedVolumeAdaptation.displayOrder {
                try engine.setVolumeAdaptation(setting)
                for baseVolume: Float in [1, 0.1, 0.5, 1] {
                    let before = tap.processedFrames
                    try engine.setSleepTimerVolume(baseVolume)
                    do { try await wait { (tap.processedFrames > before && tap.measuredSetting == setting.rawValue
                        && tap.measuredBaseVolume == baseVolume) || tap.failure != noErr } }
                    catch {
                        Issue.record("Volume setting \(setting) frames=\(tap.processedFrames) error=\(tap.failure) measured=\(tap.measuredSetting) player=\(player.status.rawValue) time=\(player.currentTime().seconds) rate=\(player.rate)")
                        throw error
                    }
                    #expect(tap.failure == noErr && tap.processedFrames > 0)
                    let amplitude = setting.effect(baseVolume: baseVolume).amplitude
                    #expect(abs(tap.measuredPowerRatio - amplitude * amplitude) < 0.002)
                    #expect(engine.nativePlayer === player && engine.reading?.sample.status == .playing)
                }
            }
            engine.pause(commandID: UUID())
            try engine.setVolumeAdaptation(.off)
            #expect(player.rate == 0 && engine.reading?.sample.status == .paused)
        }
    }


    @Test(arguments: ["progressive", "playlist"])
    func authenticatedStreamingProcessesRealSamplesAndReplacementKeepsGain(mode: String) async throws {
        let login = FeedCredentials(username: "volume-listener", password: "fixture-secret")
        let data = try Data(contentsOf: fixture("playback-30sec", "mp3"))
        let folder = fixture("index", "m3u8", "StreamingHLS").deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let hls = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let server = try await LoopbackHTTPServer.start { request in
            guard request.headers["authorization"] == login.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"volume\""], body: Data())
            }
            if mode == "playlist" {
                let key = String(request.path.split(separator: "?")[0].split(separator: "/").last ?? "")
                if key == "feed" { return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: hls["index.m3u8"]!) }
                if let segment = hls[key] { return .init(headers: ["Content-Type": "video/mp2t"], body: segment) }
                return .init(status: 404)
            }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: data)
        }
        defer { server.stop() }
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in login })
        engine.measureVolumeForTesting = true
        defer { engine.unload() }
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { failures.append(message) } }
        let episode = LibraryEpisode(id: 1, details: .init(identifier: "remote", title: "Remote volume", media: .init(url: server.url.absoluteString, size: 0)))
        engine.load(episode: episode, generation: UUID(), positionMilliseconds: 0)
        try engine.setVolumeAdaptation(.lightReduction)
        try await wait { engine.reading != nil || !failures.isEmpty }
        engine.play(commandID: UUID())
        if mode == "playlist" {
            // HLS: the processing tap receives no samples on iOS 27 (0 frames with the mixed
            // and the concrete track, Duo 27.1), so the reduction is applied through AVPlayer's
            // own output volume, as Android applies attenuation. The tap cannot observe the
            // result there; the native output volume is what the listener hears.
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 300 || !failures.isEmpty }
            #expect(failures.isEmpty)
            let player = try #require(engine.nativePlayer)
            #expect(abs(player.volume - 0.5) < 0.001 && player.rate > 0)
            engine.pause(commandID: UUID())
            try engine.setVolumeAdaptation(.heavyReduction)
            #expect(abs(player.volume - 0.2) < 0.001 && engine.nativePlayer === player)
            // The sleep-timer fade combines with the feed reduction.
            try engine.setSleepTimerVolume(0.5)
            #expect(abs(player.volume - 0.1) < 0.001)
            try engine.setSleepTimerVolume(1)
            engine.play(commandID: UUID())
            let resumed = engine.reading?.sample.positionMilliseconds ?? 0
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > resumed + 300 || !failures.isEmpty }
            #expect(failures.isEmpty && abs(player.volume - 0.2) < 0.001)
            #expect(server.requests.contains { $0.headers["authorization"] == login.authorization(utf8: false) })
            // Sleep-timer expiry in the coordinator's order: the faded audio stops, then the volume is restored.
            try engine.setSleepTimerVolume(0.1)
            #expect(abs(player.volume - 0.02) < 0.001)
            engine.pause(commandID: UUID())
            #expect(player.rate == 0)
            try engine.setSleepTimerVolume(1)
            #expect(abs(player.volume - 0.2) < 0.001 && player.rate == 0 && engine.nativePlayer === player)
            // Boosts need sample access, which HLS does not provide on iOS: recorded gap.
            try engine.setVolumeAdaptation(.heavyBoost)
            #expect(player.volume == 1)
            return
        }
        try await wait { engine.volumeTap?.measuredSetting == FeedVolumeAdaptation.lightReduction.rawValue || !failures.isEmpty }
        #expect(failures.isEmpty)
        let tap = try #require(engine.volumeTap)
        // Light reduction halves the amplitude (power 0.25), within an inaudible 5%.
        #expect(tap.processedFrames > 0 && abs(tap.measuredPowerRatio - 0.25) < 0.0125)
        #expect((engine.httpSource == nil) == (mode == "playlist"))
        #expect(server.requests.contains { $0.headers["authorization"] == login.authorization(utf8: false) })
        let player = engine.nativePlayer
        engine.pause(commandID: UUID())
        try engine.setVolumeAdaptation(.heavyBoost)
        #expect(engine.reading?.sample.status == .paused && engine.nativePlayer === player)
        engine.play(commandID: UUID())
        try await wait { tap.measuredSetting == FeedVolumeAdaptation.heavyBoost.rawValue || !failures.isEmpty }
        #expect(failures.isEmpty && tap.measuredPowerRatio > 1 && tap.measuredPowerRatio <= 31.624)
    }
    /// The progressive/local AVPlayer route applies the whole gain in its tap at render time: every change
    /// (fade step, reduction, boost, enhancer off and on) is joined by the ramp, the enhancer envelope
    /// continues across changes, and a new stream starts afresh. Checked sample by sample against
    /// `VolumeOracle` (attenuation in PCM here), with non-interleaved float buffers as AVPlayer delivers them.
    @Test(arguments: [64, 512, 4096])
    func tapRampsEveryChangeAndKeepsTheEnvelope(callbackFrames: Int) throws {
        let script: [(FeedVolumeAdaptation, Float)] = [(.heavyBoost, 0.9), (.heavyBoost, 0.8), (.heavyBoost, 0.4), (.heavyBoost, 0.2),
            (.lightReduction, 1), (.mediumBoost, 1), (.off, 0.5), (.heavyBoost, 1), (.lightBoost, 1), (.heavyReduction, 1)]
        try expectTap(initial: (.heavyBoost, 1), changes: (1...10).map { (3_000 * $0, script[$0 % script.count].0, script[$0 % script.count].1) },
            resetAt: 30_000, callbackFrames: callbackFrames)
    }

    /// Changes arriving while an 882-frame join is still running, at and across callback boundaries: the
    /// enhancer off and on again mid-join, a pending target superseded before its join starts, a reduction
    /// and an enabled 0 mB target. Each running join completes; then the latest target joins.
    @Test(arguments: [64, 200, 1024])
    func tapCommandsDuringARunningJoinWaitForItThenTheLatestTargetJoins(callbackFrames: Int) throws {
        try expectTap(initial: (.heavyBoost, 1), changes: [
            (1_200, .off, 1), (1_500, .heavyBoost, 1), (1_700, .lightBoost, 1),
            (3_400, .heavyReduction, 1), (3_500, .heavyBoost, 0.4001), (3_900, .off, 1),
            (5_000, .mediumBoost, 0.9), (5_200, .mediumBoost, 0.55), (5_250, .heavyBoost, 1), (5_300, .heavyBoost, 0.8),
        ], callbackFrames: callbackFrames)
    }

    /// v just above 1 keeps the enhancer on at 0 mB (it compresses), on a new stream and across an
    /// existing envelope; v = 1 bypasses; 1 mB is the first positive target.
    @Test(arguments: [Float(0.4), 0.4001, 0.4006])
    func tapJustAboveUnityStillCompresses(baseVolume: Float) throws {
        try expectTap(initial: (.heavyBoost, baseVolume), changes: [], callbackFrames: 512, inputStart: 9_600, frames: 12_000)
        try expectTap(initial: (.heavyBoost, 1), changes: [(2_000, .heavyBoost, baseVolume), (5_000, .heavyBoost, 0.4),
            (7_000, .heavyBoost, baseVolume), (9_000, .heavyBoost, 0.4006)], resetAt: 10_000, callbackFrames: 256,
            inputStart: 9_600, frames: 12_000)
    }

    /// Runs `VolumeTapState` over `samples` in callbacks, storing each change before the first callback at or
    /// after its frame (as the tap reads its settings), and compares with the reference over the same history.
    private func expectTap(initial: (FeedVolumeAdaptation, Float), changes: [(Int, FeedVolumeAdaptation, Float)],
                           resetAt: Int? = nil, callbackFrames: Int, inputStart: Int = 0, frames: Int = 40_000,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
        let rate = 44_100, channels = 2
        let input: [Float] = VolumeControlledPCMTransportTests.samples[(inputStart * 2)..<((inputStart + frames) * 2)].map { Float($0) / 32768 }
        let state = VolumeTapState(setting: initial.0, baseVolume: initial.1, measure: false)
        let format = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        state.prepare(format)
        #expect(state.failure.load(ordering: .relaxed) == noErr, sourceLocation: sourceLocation)
        var commands: [(frame: Int64, command: VolumeOracle.Command)] = [(0, .init(v: initial.0.factor * initial.1))]
        var resets: Set<Int64> = []
        var output: [Float] = []
        var frame = 0, next = 0
        while frame + callbackFrames <= frames {
            while next < changes.count, changes[next].0 <= frame {
                let (_, setting, base) = changes[next]; next += 1
                state.setting.store(setting.rawValue, ordering: .releasing)
                state.baseVolume.store(base, ordering: .releasing)
                commands.append((Int64(frame), .init(v: setting.factor * base)))
            }
            let reset = resetAt.map { frame >= $0 } == true && resets.isEmpty // A new stream (seek): fresh envelope, no ramp.
            if reset { resets.insert(Int64(frame)) }
            var left = (0..<callbackFrames).map { input[(frame + $0) * channels] }
            var right = (0..<callbackFrames).map { input[(frame + $0) * channels + 1] }
            left.withUnsafeMutableBytes { l in
                right.withUnsafeMutableBytes { r in
                    let list = AudioBufferList.allocate(maximumBuffers: 2)
                    defer { free(list.unsafeMutablePointer) }
                    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                    state.process(list.unsafeMutablePointer, frames: callbackFrames, reset: reset)
                }
            }
            for index in 0..<callbackFrames { output += [left[index], right[index]] }
            frame += callbackFrames
        }
        #expect(state.failure.load(ordering: .relaxed) == noErr && next == changes.count, sourceLocation: sourceLocation)
        let reference = VolumeOracle.processedPCM(Array(input.prefix(output.count)), channels: channels, sampleRate: rate,
            commands: commands, attenuateInPCM: true, resets: resets)
        let worst = zip(output, reference).map { abs($0 - $1) }.max() ?? 1
        #expect(worst <= 1e-5, "tap output differs from the reference by \(worst)", sourceLocation: sourceLocation)
    }

    private func fixture(_ name: String, _ ext: String, _ subdirectory: String? = nil) -> URL {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory.map { "Fixtures/" + $0 } ?? "Fixtures")!
#else
        Bundle(for: VolumeTapFixtures.self).url(forResource: name, withExtension: ext, subdirectory: subdirectory)!
#endif
    }
}
private final class VolumeTapFixtures: NSObject {}

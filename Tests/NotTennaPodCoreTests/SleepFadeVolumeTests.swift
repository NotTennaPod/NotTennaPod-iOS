import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// Sleep-timer fades and Volume adaptation changes through the real coordinator, engine, processing and
/// production queue (1 s; 2 s at 8 kHz), observed at the renderer (`GainRecordingTransport`). The expected
/// commands come from the test alone (an independent model of Android's timer, the test's actions and the
/// frames presented and processed when each was made); the renderer must receive exactly those, and the
/// renderer value in force at each frame's presentation × the PCM must match `VolumeOracle` run over them.
/// The timer runs on its own ticks (one per second of output) to its last positive target and expiry;
/// gain never stops, flushes or re-times the renderer.
@MainActor @Suite(.serialized) struct SleepFadeVolumeTests {
    enum Timer: CaseIterable { case clock, episode }
    enum Action { case cancel, extend(Int64), shake, setting(FeedVolumeAdaptation), pause(ticks: Int), seekBack }

    /// Mono speech-like bursts with silent gaps, a loud sustained tone and quiet passages.
    static func fixture(rate: Int, seconds: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-fade-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fade-\(rate).wav")
        var random: UInt32 = 0x1234_5678
        let samples = (0..<(rate * seconds)).map { frame -> Int16 in
            let t = Double(frame) / Double(rate)
            let second = Int(t) % 6
            random = random &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: random)) / Double(Int32.max)
            let value: Double
            switch second {
            case 0, 1: value = 0.25 * abs(sin(.pi * 3 * t)) * (0.6 * sin(2 * .pi * 180 * t) + 0.4 * noise) // syllables
            case 2: value = t.truncatingRemainder(dividingBy: 1) < 0.6 ? 0.6 * sin(2 * .pi * 220 * t) : 0 // loud, then silence
            case 3: value = 0.02 * sin(2 * .pi * 300 * t)                                              // quiet
            case 4: value = t.truncatingRemainder(dividingBy: 1) < 0.5 ? 0 : 0.15 * noise              // silence, then noise
            default: value = 0.4 * sin(2 * .pi * 140 * t) * abs(sin(.pi * 2 * t))                       // vowels
            }
            return Int16(max(-1, min(1, value)) * 32767)
        }
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: Int) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func u32(_ value: Int) { u16(value); u16(value >> 16) }
        text("RIFF"); u32(36 + samples.count * 2); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        text("data"); u32(samples.count * 2)
        for sample in samples { u16(Int(UInt16(bitPattern: sample))) }
        try data.write(to: url)
        return url
    }

    /// Android's sleep timer as the service drives it (ClockSleepTimer / EpisodeSleepTimer and the
    /// `max(0.1, ms/10000)` fade of the last ten seconds), written here independently of the app's
    /// `SleepTimer`: the sleep volume the coordinator must command at each tick and action.
    struct TimerModel {
        enum Tick: Equatable { case none, fade(Float), expired }
        let clock: Bool, initial: Int64
        var remaining: Int64, lastTick: Int64
        var active = true
        /// The sleep volume in force (1 outside the fade and after a restore).
        var volume: Float
        /// The timer's own value, as shown (after a shake reset it shows the reset time while the volume is 1).
        var shown: Float
        static func fade(_ milliseconds: Int64) -> Float {
            milliseconds > 0 && milliseconds < 10_000 ? max(0.1, Float(milliseconds) / 10_000) : 1
        }
        init(clock: Bool, value: Int64, now: Int64) {
            self.clock = clock; initial = value; remaining = value; lastTick = now
            volume = clock ? Self.fade(value) : 1
            shown = volume
        }
        mutating func tick(now: Int64, position: Int64, duration: Int64) -> Tick {
            guard active else { return .none }
            let milliseconds: Int64
            if clock {
                let elapsed = now - lastTick
                lastTick = now
                guard elapsed <= 10_000 else { return .none } // A long gap only sets a new baseline.
                remaining -= elapsed
                milliseconds = remaining
            } else { milliseconds = remaining == 1 ? duration - position : remaining * 86_400_000 }
            if milliseconds <= 0 { active = false; volume = 1; return .expired }
            volume = Self.fade(milliseconds); shown = volume
            return .fade(volume)
        }
        mutating func extend(by value: Int64) { if active && remaining > 0 { remaining += value } }
        mutating func reset() { remaining = initial; volume = 1; shown = clock ? Self.fade(initial) : 1 }
        mutating func stop() { active = false; volume = 1 }
    }

    @MainActor final class Run {
        let url: URL, rate: Int, speed: Float, skip: Bool
        var factor: Float
        let store: FeedLibraryStore
        let engine: PCMPlaybackEngine
        let player: PlaybackCoordinator
        let ticker = PCMPlaybackEngineTests.Ticker()
        var now: Int64 = 1_700_000_000_000
        var transports: [GainRecordingTransport] = []
        var timer: TimerModel?
        var ticks = 0
        /// Media position each output started at (load, seek, resume rewind, recovery).
        var starts: [ObjectIdentifier: Int64] = [:]
        /// What the test commanded on each output, where: built from ticks and actions, never from the renderer.
        var expected: [ObjectIdentifier: [VolumeOracle.Expected]] = [:]
        var current: GainRecordingTransport { transports.last! }
        let queueBuffers: Int
        /// `v` the coordinator must be applying now: feed factor × sleep volume.
        var v: Float { factor * (timer?.volume ?? 1) }

        init(url: URL, rate: Int, speed: Float, skip: Bool, setting: FeedVolumeAdaptation) async throws {
            self.url = url; self.rate = rate; self.speed = speed; self.skip = skip; factor = setting.factor
            store = try FeedLibraryStore(url: url.deletingLastPathComponent().appendingPathComponent("library.sqlite"))
            _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Fade", episodes: [
                ParsedEpisode(identifier: "1", title: "Episode", media: ParsedMedia(url: "https://example.test/1.wav", size: 0))]),
                source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                validator: nil, permanentRedirectURL: nil))
            try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = setting }
            // The production queue size, as the factory computes it.
            var sizing = try PCMRecoveryFactory(url: url, makeTransport: { GainRecordingTransport() })
            sizing.minimumQueuedSeconds = PCMRecoveryFactory.productionQueuedSeconds
            queueBuffers = sizing.queuedBuffers(sampleRate: rate)
            var made: (@MainActor (GainRecordingTransport) -> Void)?
            engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), makeFactory: { url in
                var factory = try PCMRecoveryFactory(url: url, makeTransport: {
                    let transport = GainRecordingTransport(); made?(transport); return transport
                })
                factory.minimumQueuedSeconds = PCMRecoveryFactory.productionQueuedSeconds
                return factory
            }, source: { _ in url }, positionTicker: ticker, now: { 0 })
            var preferences = PlaybackPreferences()
            preferences.end.smartMarkAsPlayedSeconds = 0; preferences.speed = speed; preferences.skipSilence = skip
            let fixed = preferences
            var timeSource: (@MainActor () -> Date)?
            player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in fixed }, clock: { timeSource?() ?? Date() })
            timeSource = { [unowned self] in Date(timeIntervalSince1970: Double(self.now) / 1000) }
            made = { [unowned self] transport in
                let id = ObjectIdentifier(transport)
                self.starts[id] = Int64(self.engine.reading?.sample.positionMilliseconds ?? 0)
                // A new output starts with the value in force, before its first frame.
                self.expected[id] = [.init(v: self.v, processed: 0, presented: 0)]
                self.transports.append(transport)
            }
        }

        func close() async { engine.unload(); try? await store.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        func start(at position: Int64 = 0) async throws {
            try await player.select(episodeID: 1, play: position == 0)
            if position > 0 {
                try await wait { self.player.phase == .paused }
                try await player.seek(to: position)
                try await wait { self.engine.reading?.sample.positionMilliseconds == Int32(position) && self.engine.reading?.buffering == false }
                try await player.play()
            }
            try await wait { self.transports.last?.playing == true }
            #expect(starts[ObjectIdentifier(current)] == position)
            try await settle()
        }

        /// The output's refill is idle (queue full, source ended or stopped): until presentation advances,
        /// nothing more is processed, so a command made now applies from exactly `processedFrames`.
        func settle() async throws {
            let transport = current
            try await wait { transport.finished || !transport.playing || transport.queuedBufferCount >= self.queueBuffers }
        }

        /// Records that a command for `v` is made now on the current output.
        func commanded(_ value: Float? = nil) {
            let transport = current
            expected[ObjectIdentifier(transport)]!.append(.init(v: value ?? v, processed: transport.processedFrames,
                presented: transport.presentedFrames))
        }

        func startTimer(clock: Bool, value: Int64) async throws {
            try await settle()
            timer = TimerModel(clock: clock, value: value, now: now)
            commanded()
            try await player.startSleepTimer(mode: clock ? .minutes : .episodes, value: value)
            checkTimer()
        }

        /// Present one second of output in 4096-frame steps, keeping the queue refilled, then tick.
        /// Returns false once playback stopped (expiry, end, failure).
        func second() async throws -> Bool {
            let transport = current
            let target = transport.presentedFrames + Int64(rate)
            while transport.presentedFrames < target {
                try await settle()
                guard transport.playing, transport.presentedFrames < transport.processedFrames else { return false }
                transport.advance(to: min(target, transport.presentedFrames + 4096, transport.processedFrames))
            }
            try await settle()
            guard transport.playing else { return false }
            now += 1000; ticks += 1
            let reading = try #require(engine.reading)
            switch timer?.tick(now: now, position: Int64(reading.sample.positionMilliseconds),
                               duration: Int64(reading.sample.durationMilliseconds)) ?? .none {
            case .none: break
            case .fade: commanded()
            case .expired: commanded() // The restore, after the pause at this same point.
            }
            ticker.fire()
            try await player.awaitPendingOperations()
            checkTimer()
            return transport.playing
        }

        /// The coordinator's own timer state agrees with the model (a check of the model, not the renderer).
        func checkTimer(sourceLocation: SourceLocation = #_sourceLocation) {
            if let timer, timer.active {
                #expect(player.sleepTimer?.isActive == true && (player.sleepTimerValue?.volume ?? 1) == timer.shown,
                        "timer model \(timer.shown), coordinator \(player.sleepTimerValue?.volume ?? -1)", sourceLocation: sourceLocation)
            } else { #expect(player.sleepTimer == nil, sourceLocation: sourceLocation) }
        }

        /// The PCM before the volume stage of an output, from a fresh identical stream.
        func input(of transport: GainRecordingTransport, frames: Int) async throws -> [Int16] {
            let start = try #require(starts[ObjectIdentifier(transport)])
            let stream = try LocalPCMPlaybackStream(url: url, start: CMTime(value: start, timescale: 1000),
                skipSilence: skip, speed: speed, maximumOutputFrames: 4096)
            var samples: [Int16] = []
            while samples.count < frames + 4096, let packet = try await stream.nextPacket() { samples += packet.samples }
            await stream.cancel()
            return samples
        }

        func expectHeard(_ transport: GainRecordingTransport, input: [Int16]? = nil, label: String,
                         sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let frames = Int(transport.presentedFrames)
            let samples: [Int16]
            if let input { samples = input } else { samples = try await self.input(of: transport, frames: frames) }
            transport.expectHeard(input: samples, expected: expected[ObjectIdentifier(transport)] ?? [], frames: frames,
                label: label, sourceLocation: sourceLocation)
        }

        func wait(_ condition: @MainActor () -> Bool, line: Int = #line) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Timed out waiting (line \(line)): phase \(player.phase), \(transports.count) outputs, playing \(transports.last?.playing == true), presented \(transports.last?.presentedFrames ?? -1) of \(transports.last?.processedFrames ?? -1)")
                    throw CancellationError()
                }
                await Task.yield()
            }
        }
    }

    nonisolated static let modes: [(speed: Float, skip: Bool)] = [(1, false), (1, true), (1.75, false), (1.75, true), (3, false), (3, true)]

    @Test(arguments: [44_100, 8_000], Array(0..<modes.count))
    func fadesFollowAndroidThroughExpiry(rate: Int, mode: Int) async throws {
        let (speed, skip) = Self.modes[mode]
        let seconds = Int(14 * speed) + 6
        let url = try Self.fixture(rate: rate, seconds: seconds)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var inputs: [Int64: [Int16]] = [:] // The PCM before the volume stage does not depend on the setting.
        for timer in Timer.allCases {
            for setting in FeedVolumeAdaptation.displayOrder {
                let run = try await Run(url: try Self.copy(url), rate: rate, speed: speed, skip: skip, setting: setting)
                do { try await fade(run, timer: timer, seconds: seconds, inputs: &inputs, label: "\(rate) Hz \(speed)× skip \(skip) \(timer) \(setting)") }
                catch { await run.close(); throw error }
                await run.close()
            }
        }
    }

    private func fade(_ run: Run, timer: Timer, seconds: Int, inputs: inout [Int64: [Int16]], label: String) async throws {
        let duration = Int64(seconds) * 1000
        // Episode timers fade over the last ten seconds of media: start twelve output seconds before the end.
        try await run.start(at: timer == .episode ? max(0, duration - Int64(12 * Double(run.speed) * 1000)) : 0)
        try await run.startTimer(clock: timer == .clock, value: timer == .clock ? 11_000 : 1)
        var running = true
        while running && run.ticks < 20 { running = try await run.second() }
        let transport = run.current
        if timer == .episode {
            // The episode ends on its own; the timer then stops playback and restores the volume.
            try await run.wait { !transport.playing && !run.player.wantsPlayback }
            try await run.player.awaitPendingOperations()
            if run.timer?.active == true {
                #expect(transport.presentedFrames == transport.processedFrames, "\(label)")
                run.timer?.stop(); run.commanded()
            }
            #expect(run.player.sleepTimer == nil && !run.player.wantsPlayback, "\(label)")
        } else {
            #expect(run.ticks == 11 && run.player.phase == .paused && run.player.sleepTimer == nil, "\(label)")
        }
        // The audio stopped before the restore reached the renderer, and the last value heard was the last
        // positive fade step.
        let pause = try #require(transport.playingChanges.last)
        #expect(!pause.playing && pause.volumeChangesBefore == transport.volumes.count - 1, "\(label)")
        // Gain never stopped or restarted the renderer: one start, and stops only where playback stopped.
        let stop = transport.currentTime
        #expect(transport.playingChanges.filter(\.playing).count == 1, "\(label)")
        #expect(transport.playingChanges.filter { !$0.playing }.allSatisfy { $0.time == stop }, "\(label)")
        if timer == .episode && run.rate == 8_000 && run.speed == 3 && run.factor == 2.5 {
            // The 2 s queue at 3× holds 6 s of media: the final audio is queued while still boosted and
            // the later fade steps arrive after the final enqueue (renderer only).
            let final = transport.processedFrames
            let commands = run.expected[ObjectIdentifier(transport)] ?? []
            #expect(commands.last { $0.processed < final }.map { $0.v > 1 } == true, "\(label)")
            #expect(commands.contains { $0.processed == final && $0.v < 1 }, "\(label)")
        }
        let start = try #require(run.starts[ObjectIdentifier(transport)])
        if inputs[start] == nil { inputs[start] = try await run.input(of: transport, frames: Int(Double(seconds) / Double(run.speed) * Double(run.rate)) + run.rate) }
        try await run.expectHeard(transport, input: inputs[start], label: label)
    }

    /// Cancel, extend, shake-reset, setting changes in both directions (two before the first is heard),
    /// a pause in the fade, a seek, and resuming after expiry, at 1.75× with skip silence.
    @Test(arguments: [FeedVolumeAdaptation.heavyBoost, .lightBoost, .lightReduction])
    func changesInsideTheFadeAndResumeAfterExpiry(setting: FeedVolumeAdaptation) async throws {
        let scripts: [(String, [Int: [Action]])] = [
            ("cancel", [4: [.cancel]]),
            ("extend", [4: [.extend(3_000)]]),
            ("shake", [5: [.shake]]),
            ("settings", [1: [.setting(.heavyReduction)], 3: [.setting(.mediumBoost), .setting(.heavyBoost)], 6: [.setting(.off)]]),
            ("pause", [4: [.pause(ticks: 3)]]),
            ("seek", [5: [.seekBack]]),
        ]
        let fixture = try Self.fixture(rate: 44_100, seconds: 34)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        for (name, script) in scripts {
            let run = try await Run(url: try Self.copy(fixture), rate: 44_100, speed: 1.75, skip: true, setting: setting)
            do {
                try await run.start()
                // A setting change outside the fade, before the timer.
                if name == "settings" { try await change(run, to: .lightReduction); _ = try await run.second(); try await change(run, to: setting) }
                try await run.startTimer(clock: true, value: 9_000)
                var plays = 1
                var running = true
                while running && run.ticks < 24 {
                    running = try await run.second()
                    for action in script[run.ticks] ?? [] where running {
                        try await run.settle()
                        switch action {
                        case .cancel:
                            run.timer?.stop(); run.commanded()
                            try await run.player.disableSleepTimer()
                        case .extend(let value):
                            run.timer?.extend(by: value)
                            try await run.player.extendSleepTimer(by: value)
                        case .shake:
                            run.timer?.reset(); run.commanded()
                            try await run.player.resetSleepTimerAfterShake()
                        case .setting(let next): try await change(run, to: next)
                        case .pause(let ticks):
                            let before = run.transports.count
                            try await run.player.pause()
                            run.now += Int64(ticks) * 1000
                            try await run.player.play()
                            try await run.wait { run.current.playing }
                            // A resume may rewind (a new output); either way the renderer starts once more.
                            if run.transports.count == before { plays += 1 } else {
                                plays = 1
                                let old = run.transports[before - 1]
                                try await run.expectHeard(old, label: "\(name) before resume")
                            }
                            try await run.settle()
                        case .seekBack:
                            // Seek and recovery build a new output at the current value; check the old one first.
                            let old = run.current
                            try await run.expectHeard(old, label: "\(name) before seek")
                            let position = Int64(run.engine.reading?.sample.positionMilliseconds ?? 0)
                            try await run.player.seek(to: max(0, position - 2_000))
                            try await run.wait { run.transports.count == 2 && run.current.playing }
                            #expect(run.starts[ObjectIdentifier(run.current)] == max(0, position - 2_000))
                            plays = 1
                            try await run.settle()
                        }
                        run.checkTimer()
                    }
                }
                if run.player.sleepTimer == nil && run.player.phase == .paused {
                    // Resume after expiry: the restored renderer value with the queued gain history, then new audio.
                    plays += 1
                    try await run.player.play()
                    try await run.wait { run.current.playing }
                    for _ in 0..<3 { _ = try await run.second() }
                }
                let transport = run.current
                try await run.expectHeard(transport, label: "\(name) \(setting)")
                // Gain changes never stop and restart the renderer: it starts once per play command.
                #expect(transport.playingChanges.filter(\.playing).count <= plays, "\(name): \(transport.playingChanges.map(\.playing))")
            } catch { await run.close(); throw error }
            await run.close()
        }
    }

    private func change(_ run: Run, to setting: FeedVolumeAdaptation) async throws {
        try await run.settle()
        run.factor = setting.factor
        run.commanded()
        try await run.store.updatePreferences(feedID: 1) { $0.volumeAdaptation = setting }
        try await run.player.refreshVolumeAdaptation(feedID: 1)
    }

    private static func copy(_ url: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-fade-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

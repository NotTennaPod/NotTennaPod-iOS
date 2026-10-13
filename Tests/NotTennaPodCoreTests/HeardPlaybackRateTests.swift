import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// The speed and skip-silence a person hears
/// on the everyday route. A downloaded episode goes through the app's own routing
/// (`ApplicationPlaybackEngine`, `PCMPlaybackFactory`), its MP3/ADTS/MP4 decoders, the
/// speed/silence processors, volume stage and native sample-buffer renderer, driven by
/// `PlaybackCoordinator` commands. Only the renderer is wrapped, to keep a copy of the PCM
/// it is handed.
///
/// "Heard" is read from that PCM at the renderer's own clock. Each fixture names its own
/// content time (manifest in
/// `Fixtures/HeardRate`), so the measurement is independent of the app's position
/// arithmetic, and rates are taken against the wall clock: a wrong sample rate, a doubled or
/// missing speed stage or a renderer rate error all show up as the wrong speed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct HeardPlaybackRateTests {
    // MARK: Gap 1 — the chosen speed is the speed heard

    /// Android: `ExoPlayer.setPlaybackParameters(speed)` (ExoPlayerWrapper.setPlaybackParams)
    /// plays content at exactly the chosen rate with unchanged pitch. A person notices a
    /// few percent; the tolerance is 3 %.
    @Test(arguments: ["ticks.mp3", "ticks.aac", "ticks.m4a"])
    func chosenSpeedIsHeardThroughChangesAndSeek(file: String) async throws {
        try await withDownloadedEpisode(file, durationMilliseconds: 30_000, speed: 0.8, skipSilence: false, marker: .ticks) { harness in
            try await harness.player.select(episodeID: 1)
            try await harness.waitUntilAudible()
            try await harness.observe(3, phase: "0.8 start")
            try await harness.player.setSpeed(1.5, alsoGlobal: true)
            try await harness.observe(3, phase: "1.5 up")
            try await harness.player.setSpeed(2, alsoGlobal: true)
            try await harness.observe(3, phase: "2.0 up")
            try await harness.player.seek(to: 18_000)
            try await harness.waitUntilAudible(transport: 1)
            try await harness.observe(3, phase: "2.0 after seek")
            try await harness.player.setSpeed(0.8, alsoGlobal: true)
            try await harness.observe(3, phase: "0.8 down")
            harness.report(file)
            #expect(harness.recorders.count == 2 && harness.recorders.allSatisfy { $0.recordingProblem == nil })

            try harness.expectHeardRate(phase: "0.8 start", speed: 0.8, settle: 0.3)
            // A change applies after the audio already handed to the renderer (Android: the
            // AudioTrack buffer, up to 0.75 s); measure from one second of output after the tap.
            try harness.expectHeardRate(phase: "1.5 up", speed: 1.5, settle: 1)
            try harness.expectHeardRate(phase: "2.0 up", speed: 2, settle: 1)
            try harness.expectHeardRate(phase: "2.0 after seek", speed: 2, settle: 0.3)
            try harness.expectHeardRate(phase: "0.8 down", speed: 0.8, settle: 1)
            // The seek lands where asked: the new output starts at 18 s of content.
            let landing = try #require(harness.contentAtOutputStart(phase: "2.0 after seek"))
            #expect(abs(landing - 18) <= 0.25, "seek to 18 s is heard from \(landing) s")
            harness.expectShownPositionFollowsHeard()
        }
    }

    // MARK: Gap 9 — skip-silence shortens what is heard, position follows it

    /// `gaps.mp3`: these "speech" windows (content seconds) carry the rising tone; the rest
    /// (61 %) is digital silence. Recorded in the fixture manifest.
    static let speech: [(start: Double, end: Double)] = [(0, 1.2), (3.7, 4.7), (5.1, 6.1), (8.6, 9.6), (11.6, 12.4)]
    static let gapsDuration = 12.7

    /// Android: `ExoPlayer.setSkipSilenceEnabled(true)` (Media3PlaybackService, ExoPlayerWrapper)
    /// uses Media3 1.10.0 `SilenceSkippingAudioProcessor` with its defaults: a silence keeps a
    /// 25 ms fade-out and a 25 ms fade-in (half of its 50 ms mono buffer each) and 20 % of the
    /// rest (`DEFAULT_SILENCE_RETENTION_RATIO`), while sound is never removed.
    static func androidSkippingSeconds() -> Double {
        var silences: [Double] = []
        var previousEnd = 0.0
        for window in speech {
            if window.start > previousEnd { silences.append(window.start - previousEnd) }
            previousEnd = window.end
        }
        silences.append(gapsDuration - previousEnd)
        let sound = speech.map { $0.end - $0.start }.reduce(0, +)
        return sound + silences.map { 0.05 + 0.2 * ($0 - 0.05) }.reduce(0, +)
    }

    @Test func skipSilenceFinishesSoonerAndShownPositionFollowsHeard() async throws {
        var seconds: [Bool: Double] = [:]
        for skip in [false, true] {
            try await withDownloadedEpisode("gaps.mp3", durationMilliseconds: 12_700, speed: 1, skipSilence: skip, marker: .chirp) { harness in
                try await harness.player.select(episodeID: 1)
                try await harness.waitUntilAudible()
                seconds[skip] = try await harness.observeUntilFinished(phase: skip ? "skip" : "plain")
                harness.report("gaps.mp3 skip=\(skip)")
                // Sound is never removed: every speech window is heard in full.
                let sound = try #require(harness.recorders.first).loudSeconds()
                #expect(abs(sound - 5.0) <= 0.1, "skip \(skip): \(sound) s of speech heard, 5.0 s in the episode")
                harness.expectShownPositionFollowsHeard()
                harness.expectShownPositionWithinHeardSilence(speech: Self.speech)
                #expect(try await harness.store.episode(id: 1)?.userState.playState == .played)
            }
        }
        let plain = try #require(seconds[false]), skipping = try #require(seconds[true])
        #expect(abs(plain - Self.gapsDuration) <= 0.4, "without skipping the 12.7 s episode took \(plain) s")
        let android = Self.androidSkippingSeconds()
        print(String(format: "heard gaps.mp3: %.2f s without skipping, %.2f s with skipping, Android model %.2f s", plain, skipping, android))
        #expect(abs(skipping - android) <= 0.5, "with skipping it took \(skipping) s; Android's processor gives \(android) s")
        #expect(skipping <= plain * 0.6, "skipping \(skipping) s is not clearly shorter than \(plain) s")
    }

    /// A speed change while skipping silence: Media3's sink resets its skipped count when the new
    /// processors start, so until the new speed is heard Android's position falls back by all
    /// silence skipped so far. Here the shown position only moves forward, step by step through
    /// the whole episode on a hand-driven output clock, and ends at the episode's end.
    @Test func skipSilencePositionOnlyMovesForwardAcrossSpeedChange() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("heard-rate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("episode.mp3")
        try FileManager.default.copyItem(at: fixture("gaps.mp3"), to: media)
        var transports: [SampleBufferPCMOutputTests.Transport] = []
        let owner = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("cache"), makeTransport: {
            let transport = SampleBufferPCMOutputTests.Transport(); transports.append(transport); return transport
        })
        let session = try await owner.make(.local(media)).make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: true))
        defer { session.close() }
        let output = try #require(transports.first)
        try await session.prepare(); try session.play()
        var presented: Int64 = 0, shown: Int64 = 0, backwards: Int64 = 0, changed = false
        let deadline = ContinuousClock.now + .seconds(60)
        while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
            guard presented < session.writtenFrames else { try await Task.sleep(for: .milliseconds(1)); continue }
            presented = min(session.writtenFrames, presented + 441) // 10 ms of the 44.1 kHz output
            output.currentTime = CMTime(value: presented, timescale: 44_100); output.onTimeChanged?()
            let position = try #require(try session.mediaMicroseconds)
            backwards = max(backwards, shown - position)
            shown = max(shown, position)
            // After the first pause was skipped, during the second speech window.
            if !changed, position >= 4_000_000 { try await session.setParameters(speed: 1.5, skipSilence: true); changed = true }
        }
        try #require(session.state == .ended && session.failure == nil && changed)
        #expect(backwards <= 50_000, "the shown position went back by \(Double(backwards) / 1e6) s")
        #expect(abs(shown - 12_700_000) <= 250_000, "the episode ended at \(Double(shown) / 1e6) s of 12.7 s")
    }

    // MARK: helpers

    enum Marker { case ticks, chirp }

    struct Observation {
        let phase: String
        let wall: Double
        let transport: Int
        let output: Double
        let shown: Double?
        let buffering: Bool
    }

    @MainActor final class RecorderList { var values: [HeardAudioRecorder] = [] }

    @MainActor final class Harness {
        let store: FeedLibraryStore
        let player: PlaybackCoordinator
        let engine: ApplicationPlaybackEngine
        let marker: Marker
        let recorderList: RecorderList
        var recorders: [HeardAudioRecorder] { recorderList.values }
        private(set) var observations: [Observation] = []
        private let started = ContinuousClock.now

        init(store: FeedLibraryStore, player: PlaybackCoordinator, engine: ApplicationPlaybackEngine,
             recorders: RecorderList, marker: Marker) {
            self.store = store; self.player = player; self.engine = engine; recorderList = recorders; self.marker = marker
        }

        var wall: Double {
            let elapsed = ContinuousClock.now - started
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }

        /// Renderer clock and the position the coordinator would show, read together. The
        /// renderer's 10 ms time callback is delivered first, as it would be without host load,
        /// so a busy test machine cannot make the shown position look stale.
        func sample(_ phase: String) {
            guard let recorder = recorders.last else { return }
            recorder.onTimeChanged?()
            let reading = engine.reading
            observations.append(Observation(phase: phase, wall: wall, transport: recorders.count - 1,
                output: recorder.currentTime.seconds,
                shown: reading.map { Double($0.sample.positionMilliseconds) / 1000 },
                buffering: reading?.buffering ?? true))
        }

        func heard(_ observation: Observation) -> Double? {
            let recorder = recorders[observation.transport]
            switch marker {
            case .ticks: return recorder.tickContent(atOutputSeconds: observation.output)
            case .chirp: return recorder.chirpContent(atOutputSeconds: observation.output)
            }
        }

        func waitUntilAudible(transport: Int = 0) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if recorders.count == transport + 1, let reading = engine.reading, !reading.buffering,
                   reading.sample.status == .playing, (recorders.last?.currentTime.seconds ?? 0) > 0.05 { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("transport \(transport) never became audible; phase \(player.phase)")
            throw CancellationError()
        }

        func observe(_ seconds: Double, phase: String) async throws {
            let end = wall + seconds
            sample(phase)
            while wall < end {
                try await Task.sleep(for: .milliseconds(40))
                sample(phase)
            }
        }

        /// Observes until the episode finishes (the coordinator returns to idle) and returns the
        /// real time from its first rendered audio to its last. The renderer plays its output in
        /// real time, so that is the output's duration plus any stall, which shows as a change in
        /// the offset between the wall clock and the renderer clock (each read together).
        func observeUntilFinished(phase: String, timeout: Double = 25) async throws -> Double {
            let deadline = wall + timeout
            sample(phase)
            while player.phase != .idle, wall < deadline {
                try await Task.sleep(for: .milliseconds(40))
                if player.phase != .idle { sample(phase) }
            }
            try #require(player.phase == .idle, "\(phase): not finished after \(timeout) s")
            let recorder = try #require(recorders.first)
            try #require(recorders.count == 1 && recorder.recordingProblem == nil && recorder.sampleRate > 0)
            let rendered = Double(recorder.pcm.count) / recorder.sampleRate
            let playing = observations.filter { $0.phase == phase && $0.output > 0.05 && $0.output < rendered - 0.05 }
            let first = try #require(playing.first), last = try #require(playing.last)
            try #require(last.wall - first.wall > rendered / 2, "\(phase): too few observations while playing")
            return rendered + (last.wall - last.output) - (first.wall - first.output)
        }

        /// While silence is heard, the shown position stays inside that silence: after the
        /// speech just heard and before the next speech, within the tolerance.
        func expectShownPositionWithinHeardSilence(speech: [(start: Double, end: Double)], tolerance: Double = 0.25,
                                                   sourceLocation: SourceLocation = #_sourceLocation) {
            var lastHeard = 0.0, checked = 0
            defer { #expect(checked >= 10, "only \(checked) readings during heard silence", sourceLocation: sourceLocation) }
            for observation in observations where !observation.buffering {
                if let heard = heard(observation) { lastHeard = heard; continue }
                guard let shown = observation.shown,
                      let current = speech.lastIndex(where: { $0.start <= lastHeard + 0.05 }) else { continue }
                let previousEnd = speech[current].end
                let nextStart = current + 1 < speech.count ? speech[current + 1].start : Double.infinity
                // Only observations after the speech window ended (not its unmeasurable edges).
                guard observation.output > 0, lastHeard > speech[current].end - 0.2 else { continue }
                checked += 1
                #expect(shown >= previousEnd - tolerance && shown <= nextStart + tolerance,
                        "silence after \(previousEnd) s is heard but \(shown) s is shown (next speech \(nextStart) s)",
                        sourceLocation: sourceLocation)
            }
        }

        /// Playing readings of the phase from `settle` seconds of output after its start.
        private func steady(_ phase: String, settle: Double) -> [(Observation, Double)] {
            let all = observations.filter { $0.phase == phase }
            guard let transport = all.last?.transport,
                  let first = all.first(where: { $0.transport == transport }) else { return [] }
            return all.compactMap { observation in
                guard observation.transport == transport, observation.output >= first.output + settle, !observation.buffering,
                      let heard = heard(observation) else { return nil }
                return (observation, heard)
            }
        }

        /// Heard speed: content per second of rendered output (slope over the phase) times
        /// rendered output per wall-clock second (the renderer's clock against the wall clock,
        /// median over the intervals between readings, so a starved renderer on a busy test
        /// machine does not count as a slower speed).
        func heardRate(phase: String, settle: Double) -> Double? {
            let points = steady(phase, settle: settle)
            guard let content = Self.slope(points.map { ($0.0.output, $0.1) }) else { return nil }
            let clock = zip(points, points.dropFirst()).compactMap { a, b -> Double? in
                b.0.wall - a.0.wall > 0.01 ? (b.0.output - a.0.output) / (b.0.wall - a.0.wall) : nil
            }.sorted()
            guard !clock.isEmpty else { return nil }
            return content * clock[clock.count / 2]
        }

        func expectHeardRate(phase: String, speed: Double, settle: Double,
                             sourceLocation: SourceLocation = #_sourceLocation) throws {
            let points = steady(phase, settle: settle)
            try #require(points.count >= 20, "phase \(phase): only \(points.count) audible observations", sourceLocation: sourceLocation)
            let rate = try #require(heardRate(phase: phase, settle: settle), sourceLocation: sourceLocation)
            #expect(abs(rate / speed - 1) <= 0.03, "phase \(phase): heard \(rate)x, chosen \(speed)x", sourceLocation: sourceLocation)
        }

        /// Content heard at output time zero of the phase's transport (its first rendered audio).
        func contentAtOutputStart(phase: String) -> Double? {
            let points = steady(phase, settle: 0).map { ($0.0.output, $0.1) }
            guard let slope = Self.slope(points) else { return nil }
            let meanX = points.map(\.0).reduce(0, +) / Double(points.count)
            let meanY = points.map(\.1).reduce(0, +) / Double(points.count)
            return meanY - slope * meanX
        }

        func expectShownPositionFollowsHeard(tolerance: Double = 0.25, sourceLocation: SourceLocation = #_sourceLocation) {
            var worst: (Observation, Double)?
            var worstError = 0.0
            for observation in observations where !observation.buffering {
                guard let heard = heard(observation), let shown = observation.shown else { continue }
                if abs(shown - heard) > worstError { worstError = abs(shown - heard); worst = (observation, heard) }
            }
            #expect(worstError <= tolerance, "shown position differs from heard audio by \(worstError) s at \(String(describing: worst))",
                    sourceLocation: sourceLocation)
        }

        /// One summary line per run for the test log.
        func report(_ label: String, settle: Double = 1) {
            var phases: [String] = []
            for observation in observations where !phases.contains(observation.phase) { phases.append(observation.phase) }
            let rates = phases.map { phase in
                "\(phase) " + (heardRate(phase: phase, settle: settle).map { String(format: "%.3fx", $0) } ?? "-")
            }
            let errors = observations.compactMap { observation -> (Double, Observation)? in
                guard !observation.buffering, let heard = heard(observation), let shown = observation.shown else { return nil }
                return (shown - heard, observation)
            }
            let worst = errors.max { abs($0.0) < abs($1.0) }
            print("heard \(label): \(rates.joined(separator: ", ")); shown-vs-heard max " +
                  String(format: "%+.3f s over %d readings", worst?.0 ?? .nan, errors.count) +
                  " (\(worst?.1.phase ?? "-") at output \(String(format: "%.2f", worst?.1.output ?? .nan)) s)" +
                  "; recording \(recorders.compactMap(\.recordingProblem).first ?? "ok")")
        }

        static func slope(_ points: [(Double, Double)]) -> Double? {
            guard points.count >= 2 else { return nil }
            let n = Double(points.count)
            let mx = points.map(\.0).reduce(0, +) / n, my = points.map(\.1).reduce(0, +) / n
            let sxx = points.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
            guard sxx > 0 else { return nil }
            return points.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +) / sxx
        }
    }

    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/HeardRate"))
#else
        try #require(Bundle(for: HeardRateFixtures.self).url(forResource: name, withExtension: nil, subdirectory: "HeardRate"))
#endif
    }

    /// A fresh, isolated library with one downloaded episode, played through the app route.
    private func withDownloadedEpisode(_ file: String, durationMilliseconds: Int32, speed: Float, skipSilence: Bool,
                                       marker: Marker, _ body: (Harness) async throws -> Void) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("heard-rate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("episode-download." + (file as NSString).pathExtension)
        try FileManager.default.copyItem(at: fixture(file), to: media)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Heard", episodes: [
            .init(identifier: "one", title: "Episode", media: .init(url: "https://example.test/\(file)", size: 0,
                durationMilliseconds: durationMilliseconds))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
            validator: nil, permanentRedirectURL: nil))
        try await store.updateEpisode(id: 1) { $0.userState.isDownloaded = true; $0.userState.localFileURL = media.path }
        let recorders = RecorderList()
        let factories = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("streaming-cache", isDirectory: true),
            makeTransport: { let recorder = HeardAudioRecorder(); recorders.values.append(recorder); return recorder })
        let engine = ApplicationPlaybackEngine(muted: true, source: AVPlayerPlaybackEngine.mediaURL,
            localAccess: LocalPlaybackAccess(store: store), factories: factories, makePCMEngine: { factory, url in
                PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, _ in factory }, source: { _ in url })
            })
        let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
            var preferences = PlaybackPreferences()
            preferences.speed = speed; preferences.skipSilence = skipSilence
            return preferences
        })
        let harness = Harness(store: store, player: player, engine: engine, recorders: recorders, marker: marker)
        do { try await body(harness) }
        catch { engine.unload(); try? await store.close(); throw error }
        engine.unload()
        try await store.close()
    }
}

/// Wraps the app's native renderer and keeps the first channel of every PCM buffer it is
/// handed, by output frame, so a test can read what is audible at the renderer's clock.
@MainActor final class HeardAudioRecorder: PCMVolumePresentationTransport, VariableRatePresentationTransport {
    let native = NativeSampleBufferTransport(muted: true)
    private(set) var sampleRate = 0.0
    private(set) var pcm: [Float] = []
    private(set) var recordingProblem: String?
    private var ticks: (count: Int, onsets: [(output: Double, content: Double)])?
    var currentTime: CMTime { native.currentTime }
    var onTimeChanged: (@MainActor () -> Void)? {
        get { native.onTimeChanged }
        set { native.onTimeChanged = newValue }
    }
    var onFailure: (@MainActor (any Error) -> Void)? {
        get { native.onFailure }
        set { native.onFailure = newValue }
    }

    func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {
        record(buffer)
        try await native.enqueue(buffer)
    }
    func setPlaying(_ playing: Bool, at time: CMTime) { native.setPlaying(playing, at: time) }
    func setRate(_ rate: Float, at time: CMTime) { native.setRate(rate, at: time) }
    func setRendererVolume(_ volume: Float) { native.setRendererVolume(volume) }
    func observeEnd(_ time: CMTime) { native.observeEnd(time) }
    func finishEnqueuing() { native.finishEnqueuing() }
    func stopMonitoring() { native.stopMonitoring() }
    func close() { native.close() }

    private func record(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) {
        guard let format = buffer.formatDescription.audioStreamBasicDescription, format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel == 16, format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              format.mChannelsPerFrame > 0 else { recordingProblem = "unexpected sample format"; return }
        if sampleRate == 0 { sampleRate = format.mSampleRate }
        guard sampleRate == format.mSampleRate else { recordingProblem = "sample rate changed"; return }
        guard let bytes = buffer.content.withContiguousStorageIfAvailable({ Data($0) }) else {
            recordingProblem = "unreadable buffer"; return
        }
        let channels = Int(format.mChannelsPerFrame)
        let samples = PCMTestFixture.samples(bytes)
        let frames = samples.count / channels
        let start = Int((buffer.presentationTimeStamp.seconds * sampleRate).rounded())
        guard start >= 0 else { recordingProblem = "negative timestamp"; return }
        if pcm.count < start + frames { pcm += [Float](repeating: 0, count: start + frames - pcm.count) }
        for frame in 0..<frames { pcm[start + frame] = Float(samples[frame * channels]) / 32768 }
        ticks = nil
    }

    /// Seconds of rendered output that carry sound (5 ms blocks peaking above -12 dBFS).
    func loudSeconds() -> Double {
        let block = max(1, Int(sampleRate / 200))
        var loud = 0
        for start in stride(from: 0, to: pcm.count - block + 1, by: block)
        where pcm[start..<(start + block)].contains(where: { abs($0) > 0.25 }) { loud += 1 }
        return Double(loud * block) / sampleRate
    }

    /// Frequency from rising zero crossings (interpolated) within `range`.
    /// Codec noise near silence never counts: a crossing needs a swing below -0.05 first.
    private func frequency(_ range: Range<Int>) -> Double? {
        var first: Double?, last = 0.0, count = 0, armed = false
        for index in range.lowerBound..<(range.upperBound - 1) {
            if pcm[index] < -0.05 { armed = true }
            guard armed, pcm[index] < 0, pcm[index + 1] >= 0 else { continue }
            let crossing = Double(index) + Double(-pcm[index]) / Double(pcm[index + 1] - pcm[index])
            if first == nil { first = crossing }
            last = crossing; count += 1; armed = false
        }
        guard let first, count >= 3, last > first else { return nil }
        return Double(count - 1) * sampleRate / (last - first)
    }

    /// Onsets of the `ticks` fixture's bursts in the rendered output, with the content time
    /// each one names (burst i starts at 0.2 s × i and sounds at 300 Hz + 25 Hz × i).
    func tickOnsets() -> [(output: Double, content: Double)] {
        if let ticks, ticks.count == pcm.count { return ticks.onsets }
        let on: Float = 0.15, quiet: Float = 0.03
        let millisecond = max(1, Int(sampleRate / 1000))
        var bursts: [(output: Double, tick: Double)] = []
        var index = 0
        while index < pcm.count {
            guard abs(pcm[index]) > on else { index += 1; continue }
            // The burst lasts until 5 ms of quiet.
            var end = index
            while end + 5 * millisecond <= pcm.count, pcm[end..<(end + 5 * millisecond)].contains(where: { abs($0) >= quiet }) {
                end += millisecond
            }
            // An onset follows at least 25 ms of quiet (ignoring the 10 ms fade-in before it).
            let quietStart = index - 35 * millisecond, quietEnd = index - 10 * millisecond
            if quietStart >= 0, !pcm[quietStart..<quietEnd].contains(where: { abs($0) >= quiet }),
               end - index > 8 * millisecond,
               let hz = frequency((index + 3 * millisecond)..<(index + 3 * millisecond + (end - index) * 7 / 10)) {
                bursts.append((output: Double(index) / sampleRate, tick: (hz - 300) / 25))
            }
            index = max(end, index + 1)
        }
        // Pitch-preserving splicing of a 30 ms burst moves its measured pitch by up to about
        // one and a half steps, so a single burst cannot name its tick. Bursts are counted in
        // order instead, from the tick the whole output names: the median of every burst's
        // measured tick minus its count. (Losing audio is checked by other suites; here a lost
        // burst would only shift the count.)
        let offsets = bursts.enumerated().map { $0.element.tick - Double($0.offset) }.sorted()
        let anchor = offsets.isEmpty ? 0 : offsets[offsets.count / 2].rounded()
        let result = bursts.enumerated().map { k, burst in (output: burst.output, content: 0.2 * (Double(k) + anchor)) }
        ticks = (pcm.count, result)
        return result
    }

    /// Content heard at `seconds` of output, interpolated between the surrounding tick onsets.
    func tickContent(atOutputSeconds seconds: Double) -> Double? {
        let onsets = tickOnsets()
        guard let next = onsets.firstIndex(where: { $0.output > seconds }), next > 0 else { return nil }
        let before = onsets[next - 1], after = onsets[next]
        // Neighbouring ticks only (at most one missed), in content order.
        guard after.output - before.output < 0.6, after.content > before.content,
              after.content - before.content <= 0.41 else { return nil }
        return before.content + (seconds - before.output) / (after.output - before.output) * (after.content - before.content)
    }

    /// Content time named by the `gaps` fixture's rising tone (200 Hz + 100 Hz/s × t) in a
    /// 50 ms window centred on `seconds` of output; nil where that window is not entirely tone.
    func chirpContent(atOutputSeconds seconds: Double) -> Double? {
        guard sampleRate > 0, seconds.isFinite else { return nil }
        let half = Int(0.025 * sampleRate), center = Int((seconds * sampleRate).rounded())
        guard center - half >= 0, center + half <= pcm.count else { return nil }
        // Every 5 ms of the window peaks near the tone's level (-6 dBFS): none of it is a fade or silence.
        let block = max(1, (2 * half) / 10)
        guard stride(from: center - half, to: center + half - block + 1, by: block).allSatisfy({ start in
                  pcm[start..<(start + block)].contains(where: { abs($0) > 0.4 }) }),
              let hz = frequency((center - half)..<(center + half)) else { return nil }
        return (hz - 200) / 100
    }
}

private final class HeardRateFixtures: NSObject {}

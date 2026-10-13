// Adapts Media3 1.10.0 DefaultAudioSink, SonicAudioProcessor and Util time mapping.
// Copyright (C) 2016, 2017 The Android Open Source Project.
// Apache License 2.0; see NOTICE.md and Licenses/Apache-2.0.txt.

import CoreMedia

/// One coherent producer snapshot, captured on its serial executor. Never use these counters
/// alone as a playback position: mapping also requires the native presented-output frame.
public struct PCMProcessingProgress: Equatable, Sendable {
    public let speed: Float
    public let channels: Int
    public let inputFrames: Int64
    public let pendingInputFrames: Int64
    public let outputFrames: Int64
    public let skippedFrames: Int64
    public let speedProcessingActive: Bool

    public init(speed: Float, channels: Int, inputFrames: Int64, pendingInputFrames: Int64,
                outputFrames: Int64, skippedFrames: Int64, speedProcessingActive: Bool) throws {
        guard speed.isFinite, speed > 0, (1...32).contains(channels),
              inputFrames >= 0, pendingInputFrames >= 0, pendingInputFrames <= inputFrames,
              outputFrames >= 0, skippedFrames >= 0 else { throw PCMPlaybackClock.Failure.invalidProgress }
        self.speed = speed
        self.channels = channels
        self.inputFrames = inputFrames
        self.pendingInputFrames = pendingInputFrames
        self.outputFrames = outputFrames
        self.skippedFrames = skippedFrames
        self.speedProcessingActive = speedProcessingActive
    }

    /// The same snapshot with the skipped frames that have been heard by the presented output.
    func hearing(skippedFrames: Int64) throws -> PCMProcessingProgress {
        try PCMProcessingProgress(speed: speed, channels: channels, inputFrames: inputFrames,
            pendingInputFrames: pendingInputFrames, outputFrames: outputFrames, skippedFrames: skippedFrames,
            speedProcessingActive: speedProcessingActive)
    }

    /// SonicAudioProcessor uses measured processed-input/output after at least 1024 output
    /// bytes, and a truncating Double speed estimate before then. No sample-rate conversion.
    func mediaDuration(playoutMicroseconds: Int64) -> Int64 {
        guard speedProcessingActive else { return playoutMicroseconds }
        if outputFrames >= Int64((1024 + channels * 2 - 1) / (channels * 2)) {
            return MediaTimestampMath.scale(playoutMicroseconds, by: inputFrames - pendingInputFrames, over: outputFrames)
        }
        return MediaTimestampMath.truncate(Double(speed) * Double(playoutMicroseconds))
    }
}

/// Source-derived sink mapping for a constant PCM sample rate. Native output owns presentation,
/// the producer owns statistics, and this value owns parameter checkpoints. Replace on seek,
/// track/format replacement or output-timeline reset; never carry checkpoints across those.
public struct PCMPlaybackClock: Sendable {
    public enum Failure: Error, Equatable { case invalidConfiguration, invalidProgress, invalidCheckpoint, invalidOutput }
    private struct Checkpoint: Sendable {
        let mediaMicroseconds: Int64
        let outputMicroseconds: Int64
        let speed: Float
        var driftMicroseconds: Int64 = 0
    }
    public let sampleRate: Int
    private var current: Checkpoint
    private var checkpoints: [Checkpoint] = []
    // One small record per consumed parameter boundary, never PCM or per-frame history.
    // Keep for this output generation: a delayed renderer flush can name an older boundary.
    private var retiredCheckpoints: [Checkpoint] = []
    private var lastCheckpointFrame: Int64 = 0
    public var pendingCheckpointCount: Int { checkpoints.count }

    public init(sampleRate: Int, mediaMicroseconds: Int64, speed: Float) throws {
        guard (1...768_000).contains(sampleRate), mediaMicroseconds >= 0, speed.isFinite, speed > 0 else {
            throw Failure.invalidConfiguration
        }
        self.sampleRate = sampleRate
        current = Checkpoint(mediaMicroseconds: mediaMicroseconds, outputMicroseconds: 0, speed: speed)
    }

    /// Add only after old processors drain. This frame is the already-written output boundary,
    /// not the input decoder position or time the user pressed the speed control.
    public mutating func enqueueCheckpoint(outputFrame: Int64, mediaMicroseconds: Int64, speed: Float) throws {
        guard outputFrame >= lastCheckpointFrame, mediaMicroseconds >= 0, speed.isFinite, speed > 0 else {
            throw Failure.invalidCheckpoint
        }
        checkpoints.append(Checkpoint(mediaMicroseconds: mediaMicroseconds,
                                      outputMicroseconds: microseconds(frames: outputFrame), speed: speed))
        lastCheckpointFrame = outputFrame
    }

    /// Pass a coherent reading from one transport generation. `writtenFrames` excludes producer
    /// buffers not yet accepted by native output. This maps the sink; renderer/UI monotonicity,
    /// duration clamping and skipped-silence notifications belong to their respective owners.
    public mutating func position(presentedFrames: Int64, writtenFrames: Int64,
                                  progress: PCMProcessingProgress, presentationTime: CMTime? = nil,
                                  committedTimeline: PlaybackVideoTimeline? = nil) throws -> Int64 {
        guard presentedFrames >= 0, writtenFrames >= 0 else { throw Failure.invalidOutput }
        let output = microseconds(frames: min(presentedFrames, writtenFrames))
        while let first = checkpoints.first, output >= first.outputMicroseconds {
            retiredCheckpoints.append(current)
            current = checkpoints.removeFirst()
        }
        guard output >= current.outputMicroseconds else { throw Failure.invalidOutput }
        if let committedTimeline {
            let time = presentationTime ?? CMTime(value: min(presentedFrames, writtenFrames), timescale: Int32(sampleRate))
            let source = try committedTimeline.sourceTime(at: time)
            let converted = CMTimeConvertScale(source, timescale: 1_000_000, method: .roundTowardZero)
            guard converted.isNumeric else { throw Failure.invalidOutput }
            return converted.value
        }
        let elapsed = output - current.outputMicroseconds
        let estimate = current.speed == 1 ? elapsed
            : MediaTimestampMath.truncate((Double(elapsed) * Double(current.speed)).rounded(.toNearestOrAwayFromZero))
        let media: Int64
        if checkpoints.isEmpty {
            let actual = progress.mediaDuration(playoutMicroseconds: elapsed)
            current.driftMicroseconds = actual &- estimate
            media = current.mediaMicroseconds &+ actual
        } else {
            media = current.mediaMicroseconds &+ estimate &+ current.driftMicroseconds
        }
        // DefaultAudioSink adds the processor's cumulative skipped count as soon as silence is
        // processed, which runs ahead of queued audio. The playback session passes only the
        // skipped frames already heard in this segment (PCMHeardSkipLedger).
        return media &+ microseconds(frames: progress.skippedFrames)
    }

    /// Map a discarded output frame without rewinding the live clock. Older intervals retain
    /// their observed drift and queued-checkpoint rule; processor statistics retain the same
    /// current-snapshot semantics as position(). This is sink-position mapping, not a claim
    /// that a speed/silence processor can be restarted with identical sub-frame audio phase.
    public func recoveryPosition(presentedFrames: Int64, writtenFrames: Int64,
                                 progress: PCMProcessingProgress,
                                 committedTimeline: PlaybackVideoTimeline? = nil) throws -> Int64 {
        guard presentedFrames >= 0, writtenFrames >= 0 else { throw Failure.invalidOutput }
        let output = microseconds(frames: min(presentedFrames, writtenFrames))
        var recovery = self
        if output < current.outputMicroseconds {
            guard let index = retiredCheckpoints.lastIndex(where: { $0.outputMicroseconds <= output }) else {
                throw Failure.invalidOutput
            }
            recovery.current = retiredCheckpoints[index]
            recovery.checkpoints = Array(retiredCheckpoints.dropFirst(index + 1)) + [current] + checkpoints
        }
        return try recovery.position(presentedFrames: presentedFrames, writtenFrames: writtenFrames,
            progress: progress, committedTimeline: committedTimeline)
    }

    private func microseconds(frames: Int64) -> Int64 {
        MediaTimestampMath.scale(frames, by: 1_000_000, over: Int64(sampleRate))
    }
}

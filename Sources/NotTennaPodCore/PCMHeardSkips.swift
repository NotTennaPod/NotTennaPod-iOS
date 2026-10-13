/// Silence that skip-silence removed, placed at the processed-output frame where the removal
/// is heard. Media3's sink adds the processor's whole skipped count as soon as silence is
/// processed, so its shown position runs ahead of the audio still queued for output (up to
/// about four times the output buffer at the end of speech before a long pause). The shown and
/// saved position instead follows what is heard.
public struct PCMHeardSkip: Equatable, Sendable {
    /// Output frame where the owning parameter segment (clock checkpoint) begins.
    public let segmentOutputStart: Int64
    /// Output frame at which the removed silence would have been heard.
    public let outputFrame: Int64
    /// Removed source frames.
    public let frames: Int64
}

/// Places each removal of one segment's silence processor (a zero-output span at a frame of
/// its own output) on the processed output, through the speed processor's committed
/// input-to-output spans. Without speed processing the caller passes identity spans.
struct PCMHeardSkipMapper: Sendable {
    let segmentOutputStart: Int64
    private var pending: [(silenceFrame: Int64, frames: Int64)] = []

    init(segmentOutputStart: Int64) { self.segmentOutputStart = segmentOutputStart }

    mutating func appendSilence(_ spans: [PCMProcessingSpan]) {
        for span in spans where span.output.isEmpty && !span.input.isEmpty {
            pending.append((silenceFrame: span.output.lowerBound, frames: Int64(span.input.count)))
        }
    }

    /// Spans are in consumption order; a removal is placed once the speed processor has
    /// consumed the silence output up to it.
    mutating func consumeSpeed(_ spans: [PCMProcessingSpan]) -> [PCMHeardSkip] {
        var result: [PCMHeardSkip] = []
        for span in spans {
            while let first = pending.first, first.silenceFrame <= span.input.upperBound {
                let offset = max(0, first.silenceFrame - span.input.lowerBound)
                let mapped = span.input.isEmpty ? span.output.lowerBound : span.output.lowerBound
                    + MediaTimestampMath.scale(offset, by: Int64(span.output.count), over: Int64(span.input.count))
                result.append(.init(segmentOutputStart: segmentOutputStart, outputFrame: segmentOutputStart + mapped,
                                    frames: first.frames))
                pending.removeFirst()
            }
        }
        return result
    }

    /// A removal after the last consumed audio (a skipped-only tail) is heard at the end.
    mutating func finish(atOutputFrame frame: Int64) -> [PCMHeardSkip] {
        defer { pending.removeAll() }
        return pending.map { .init(segmentOutputStart: segmentOutputStart, outputFrame: frame, frames: $0.frames) }
    }
}

/// Per output generation: the skipped frames of the segment being heard, up to the frame
/// being heard. Segments begin where the clock's checkpoints begin, so the clock's segment
/// media start already includes all earlier segments' skipping.
struct PCMHeardSkipLedger: Sendable {
    private struct Segment: Sendable {
        let start: Int64
        var retired: Int64 = 0
        var skips: [(frame: Int64, frames: Int64)] = []
    }
    private var segments: [Segment] = []

    mutating func beginSegment(at start: Int64) {
        if segments.last?.start != start { segments.append(Segment(start: start)) }
    }

    mutating func append(_ skips: [PCMHeardSkip]) {
        for skip in skips {
            guard let index = segments.lastIndex(where: { $0.start == skip.segmentOutputStart }) else { continue }
            segments[index].skips.append((frame: skip.outputFrame, frames: skip.frames))
        }
    }

    func skippedFrames(heardThrough frame: Int64) -> Int64 {
        guard let segment = segments.last(where: { $0.start <= frame }) else { return 0 }
        var total = segment.retired
        for skip in segment.skips where skip.frame <= frame { total += skip.frames }
        return total
    }

    /// Bounded history: fold removals heard before `frame` into their segment's total and drop
    /// segments that ended before it. Recovery positions never precede the presented output by
    /// more than the renderer queue, far less than the retained window.
    mutating func retire(before frame: Int64) {
        guard let current = segments.lastIndex(where: { $0.start <= frame }) else { return }
        if current > 0 { segments.removeFirst(current) }
        let heard = segments[0].skips.prefix { $0.frame < frame }
        guard !heard.isEmpty else { return }
        segments[0].retired += heard.reduce(0) { $0 + $1.frames }
        segments[0].skips.removeFirst(heard.count)
    }
}

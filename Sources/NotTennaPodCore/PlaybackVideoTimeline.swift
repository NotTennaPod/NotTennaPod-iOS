import CoreMedia

/// CoreMedia's generic range mapper rounds fractional sample positions to a
/// nanosecond timebase. Mixing those results with exact PCM boundaries creates
/// artificial gaps. Preserve a reduced rational mapping whenever CMTime can
/// represent it, and return exact endpoints without interpolation.
enum PlaybackTimeMapping {
    static func map(_ time: CMTime, fromRange source: CMTimeRange, toRange target: CMTimeRange) -> CMTime {
        if time == source.start { return target.start }
        if time == source.end { return target.end }
        guard source.duration > .zero else { return target.start }
        let value = try? Rational(target.start) + (Rational(time) - Rational(source.start)) * Rational(target.duration) / Rational(source.duration)
        if let value, let numerator = Int64(exactly: value.n), let denominator = Int32(exactly: value.d) {
            return CMTime(value: numerator, timescale: denominator)
        }
        return CMTimeMapTimeFromRangeToRange(time, fromRange: source, toRange: target)
    }
    private struct Rational {
        let n: Int128, d: Int128
        init(_ time: CMTime) { self.init(Int128(time.value), Int128(time.timescale)) }
        init(_ numerator: Int128, _ denominator: Int128) {
            let divisor = Self.gcd(abs(numerator), abs(denominator))
            n = numerator / divisor; d = denominator / divisor
        }
        static func gcd(_ a: Int128, _ b: Int128) -> Int128 {
            var a = a, b = b
            while b != 0 { (a, b) = (b, a % b) }
            return max(1, a)
        }
        enum Failure: Error { case overflow }
        static func multiply(_ a: Int128, _ b: Int128) throws -> Int128 {
            let result = a.multipliedReportingOverflow(by: b)
            guard !result.overflow, result.partialValue != .min else { throw Failure.overflow }
            return result.partialValue
        }
        static func + (a: Self, b: Self) throws -> Self {
            let divisor = gcd(a.d, b.d)
            let left = try multiply(a.n, b.d / divisor), right = try multiply(b.n, a.d / divisor)
            let sum = left.addingReportingOverflow(right)
            guard !sum.overflow, sum.partialValue != .min else { throw Failure.overflow }
            return .init(sum.partialValue, try multiply(a.d, b.d / divisor))
        }
        static func - (a: Self, b: Self) throws -> Self { try a + .init(-b.n, b.d) }
        static func * (a: Self, b: Self) throws -> Self {
            let first = gcd(abs(a.n), b.d), second = gcd(abs(b.n), a.d)
            return .init(try multiply(a.n / first, b.n / second), try multiply(a.d / second, b.d / first))
        }
        static func / (a: Self, b: Self) throws -> Self { try a * .init(b.d, b.n) }
    }
}

/// A processor reports the exact ranges it consumed and emitted in its own frame
/// domains. Zero output denotes removed input; time-pitch overlap still mixes samples.
public struct PCMProcessingSpan: Equatable, Sendable {
    public let input: Range<Int64>
    public let output: Range<Int64>
    public init(input: Range<Int64>, output: Range<Int64>) { self.input = input; self.output = output }
}

/// Compose the silence processor's explicit retained/removed intervals with the
/// speed processor's contemporaneously committed consumption. Only unconsumed
/// silence spans remain resident; no whole-episode sample history is retained.
struct PCMVideoSpanComposer: Sendable {
    private var pending: [PCMProcessingSpan] = []
    let sourceAnchor: CMTime
    let outputAnchor: Int64
    let sampleRate: Int32
    mutating func appendSilence(_ spans: [PCMProcessingSpan]) {
        for span in spans {
            if let last = pending.last, last.input.upperBound == span.input.lowerBound,
               last.output.upperBound == span.output.lowerBound,
               (last.output.isEmpty && span.output.isEmpty ||
                last.input.count == last.output.count && span.input.count == span.output.count) {
                pending[pending.count - 1] = .init(input: last.input.lowerBound..<span.input.upperBound,
                    output: last.output.lowerBound..<span.output.upperBound)
            } else { pending.append(span) }
        }
    }
    var pendingSpanCount: Int { pending.count }

    mutating func consumeSpeed(_ spans: [PCMProcessingSpan]) -> [PlaybackVideoTimeline.Span] {
        var result: [PlaybackVideoTimeline.Span] = []
        for speed in spans {
            let input = range(speed.input)
            let output = range((speed.output.lowerBound + outputAnchor)..<(speed.output.upperBound + outputAnchor))
            while let silence = pending.first, silence.output.lowerBound <= speed.input.upperBound {
                if silence.output.isEmpty {
                    guard silence.output.lowerBound >= speed.input.lowerBound else { pending.removeFirst(); continue }
                    let point = PlaybackTimeMapping.map(time(silence.output.lowerBound), fromRange: input, toRange: output)
                    result.append(.init(source: shifted(silence.input), presentation: CMTimeRange(start: point, duration: .zero)))
                    pending.removeFirst(); continue
                }
                let lower = max(silence.output.lowerBound, speed.input.lowerBound)
                let upper = min(silence.output.upperBound, speed.input.upperBound)
                guard lower < upper else { break }
                let sourceLower = silence.input.lowerBound + lower - silence.output.lowerBound
                let sourceUpper = sourceLower + upper - lower
                let start = PlaybackTimeMapping.map(time(lower), fromRange: input, toRange: output)
                let end = PlaybackTimeMapping.map(time(upper), fromRange: input, toRange: output)
                result.append(.init(source: shifted(sourceLower..<sourceUpper), presentation: CMTimeRange(start: start, end: end)))
                if upper == silence.output.upperBound { pending.removeFirst() }
                else { pending[0] = .init(input: sourceUpper..<silence.input.upperBound, output: upper..<silence.output.upperBound); break }
            }
        }
        return result
    }

    /// Final skipped-only input has no speed input to trigger composition.
    mutating func finish(at outputFrame: Int64) -> [PlaybackVideoTimeline.Span] {
        var result: [PlaybackVideoTimeline.Span] = []
        while let span = pending.first, span.output.isEmpty {
            result.append(.init(source: shifted(span.input), presentation: CMTimeRange(start: time(outputFrame), duration: .zero)))
            pending.removeFirst()
        }
        return result
    }
    private func time(_ frame: Int64) -> CMTime { CMTime(value: frame, timescale: sampleRate) }
    private func range(_ frames: Range<Int64>) -> CMTimeRange { CMTimeRange(start: time(frames.lowerBound), end: time(frames.upperBound)) }
    private func shifted(_ frames: Range<Int64>) -> CMTimeRange {
        CMTimeRange(start: sourceAnchor + time(frames.lowerBound), duration: time(frames.upperBound - frames.lowerBound))
    }
}

/// Explicit producer-owned correspondence between source media and processed output.
/// This consumes committed spans; it never estimates silence locations from cumulative
/// skipped-frame counters. Replace on seek and retire old spans only after all consumers.
public struct PlaybackVideoTimeline: Sendable {
    public enum Failure: Error, Equatable { case invalidSpan, discontinuity, capacity, outsideTimeline }
    public struct Span: Sendable, Equatable {
        public let source: CMTimeRange
        public let presentation: CMTimeRange
        public init(source: CMTimeRange, presentation: CMTimeRange) {
            self.source = source; self.presentation = presentation
        }
    }
    public let maximumSpans: Int
    public private(set) var spans: [Span] = []

    public init(maximumSpans: Int = 4096) throws {
        guard maximumSpans > 0 else { throw Failure.capacity }
        self.maximumSpans = maximumSpans
    }

    /// Zero presentation duration explicitly removes the source interval.
    public mutating func append(_ span: Span, sourceDiscontinuity: Bool = false) throws {
        guard Self.valid(span.source), Self.valid(span.presentation),
              span.source.duration > .zero else { throw Failure.invalidSpan }
        if let previous = spans.last {
            guard (sourceDiscontinuity || previous.source.end == span.source.start),
                  previous.presentation.end == span.presentation.start else { throw Failure.discontinuity }
        }
        guard spans.count < maximumSpans else { throw Failure.capacity }
        spans.append(span)
    }

    public var sourceRange: CMTimeRange? {
        guard let first = spans.first, let last = spans.last else { return nil }
        return CMTimeRange(start: first.source.start, end: last.source.end)
    }
    public var presentationRange: CMTimeRange? {
        guard let first = spans.first, let last = spans.last else { return nil }
        return CMTimeRange(start: first.presentation.start, end: last.presentation.end)
    }

    /// Right-biased at cuts: the source playhead advances past removed silence.
    public func sourceTime(at presentationTime: CMTime) throws -> CMTime {
        guard presentationTime.isNumeric,
              let span = spans.last(where: { presentationTime >= $0.presentation.start && presentationTime <= $0.presentation.end }) else {
            throw Failure.outsideTimeline
        }
        if span.presentation.duration == .zero { return span.source.end }
        return PlaybackTimeMapping.map(presentationTime, fromRange: span.presentation, toRange: span.source)
    }

    /// Seeking into removed silence lands on its collapsed presentation boundary.
    public func presentationTime(at sourceTime: CMTime) throws -> CMTime {
        guard sourceTime.isNumeric,
              let span = spans.last(where: { sourceTime >= $0.source.start && sourceTime <= $0.source.end }) else {
            throw Failure.outsideTimeline
        }
        if span.presentation.duration == .zero { return span.presentation.start }
        return PlaybackTimeMapping.map(sourceTime, fromRange: span.source, toRange: span.presentation)
    }

    /// A decoded picture may cross a speed change or silence cut. Split only its
    /// presentation intervals; the decoder remains responsible for reference pictures.
    public func presentationRanges(for source: CMTimeRange) throws -> [CMTimeRange] {
        guard Self.valid(source), source.duration > .zero, let covered = sourceRange,
              source.start >= covered.start, source.end <= covered.end else { throw Failure.outsideTimeline }
        return spans.compactMap { span in
            guard span.presentation.duration > .zero else { return nil }
            let intersection = CMTimeRangeGetIntersection(source, otherRange: span.source)
            guard intersection.duration > .zero else { return nil }
            return CMTimeRange(
                start: PlaybackTimeMapping.map(intersection.start, fromRange: span.source, toRange: span.presentation),
                end: PlaybackTimeMapping.map(intersection.end, fromRange: span.source, toRange: span.presentation))
        }
    }

    /// The coordinator owns the recovery horizon. This never discards the span that
    /// contains the horizon or the terminal anchor, so mappings remain well-defined.
    public mutating func retire(before presentationTime: CMTime) {
        guard presentationTime.isNumeric else { return }
        while spans.count > 1 && spans[0].presentation.end < presentationTime { spans.removeFirst() }
    }

    private static func valid(_ range: CMTimeRange) -> Bool {
        range.start.isNumeric && range.start >= .zero && range.duration.isNumeric && range.duration >= .zero && range.end.isNumeric
    }
}

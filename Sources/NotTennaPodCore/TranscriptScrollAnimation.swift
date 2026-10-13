import Foundation

/// Release TranscriptDialogFragment + RecyclerView1.4 LinearSmoothScroller.
/// Coordinates are local points; a point corresponds to source dp. Local pixel
/// rounding preserves the source's integer scroll consumption without device DPI APIs.
public struct TranscriptScrollAnimation: Sendable {
    public struct Phase: Sendable {
        public enum Curve: Sendable { case linear, decelerating }
        public let from: Double
        public let to: Double
        public let duration: Double
        public let curve: Curve
    }
    public let initialOffset: Double
    public let targetOffset: Double
    public let phases: [Phase]
    private let maximum: Double
    private let scale: Double

    public init(offset: Double, targetTop: Double, targetBottom: Double, viewport: Double,
                maximum: Double, quick: Bool, pixelsPerPoint: Double) {
        let scale = max(1, pixelsPerPoint), maximum = max(0, maximum)
        self.scale = scale; self.maximum = maximum
        self.targetOffset = min(maximum, max(0, targetTop))
        var start = min(maximum, max(0, offset))
        var phases: [Phase] = []
        if quick {
            if targetBottom <= start { start = targetTop }
            else if targetTop >= start + viewport { start = targetBottom - viewport }
            else if targetBottom - targetTop > viewport || targetTop < start { start = targetTop }
            else if targetBottom > start + viewport { start = targetBottom - viewport }
            start = min(maximum, max(0, start))
        }
        self.initialOffset = start
        if !quick && (targetTop >= start + viewport || targetBottom <= start) {
            // LinearLayoutManager fills one extra viewport toward a smooth target.
            // Until that target is attached, LinearSmoothScroller seeks at constant speed.
            let attached = targetTop >= start + viewport ? max(start, targetTop - 2 * viewport)
                : min(start, targetBottom + viewport)
            if attached != start {
                phases.append(Phase(from: start, to: attached,
                    duration: abs(attached - start) * 6.25 / 1000, curve: .linear))
                start = attached
            }
        }
        if start != targetTop {
            let distancePixels = abs(targetTop - start) * scale
            let milliseconds = ceil(ceil(distancePixels * (quick ? 200 : 1000) / (160 * scale)) / 0.3356)
            phases.append(Phase(from: start, to: targetTop, duration: milliseconds / 1000, curve: .decelerating))
        }
        self.phases = phases
    }

    public func value(at elapsed: Double) -> (offset: Double, finished: Bool) {
        var time = max(0, elapsed)
        for phase in phases {
            if time < phase.duration {
                let fraction = time / phase.duration
                let progress = phase.curve == .linear ? fraction : 1 - (1 - fraction) * (1 - fraction)
                let raw = phase.from + (phase.to - phase.from) * progress
                let rounded = floor(raw * scale + 0.5) / scale
                let offset = min(maximum, max(0, rounded))
                // Android stops when integer consumption reaches the destination or a boundary.
                return (offset, floor(offset * scale + 0.5) == floor(targetOffset * scale + 0.5) || (raw >= maximum && phase.to > maximum) || (raw <= 0 && phase.to < 0))
            }
            time -= phase.duration
        }
        return (targetOffset, true)
    }
}

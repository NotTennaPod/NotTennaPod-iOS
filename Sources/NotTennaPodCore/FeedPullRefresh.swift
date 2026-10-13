import Foundation

/// SwipeRefreshLayout 1.0.0's nested-scroll/slingshot contract. The pinned
/// phone fixture's 300 physical-pixel trigger is 114.286 logical points.
public struct FeedPullRefresh: Equatable, Sendable {
    public static let referenceTrigger = 300.0 / 2.625
    public var triggerDistance: Double
    public private(set) var distance: Double = 0
    private var origin: Double = 0

    public init(triggerDistance: Double = referenceTrigger) {
        self.triggerDistance = max(1, triggerDistance)
    }
    public mutating func begin(translation: Double, scrollOffset: Double) {
        origin = translation + max(0, scrollOffset)
        distance = 0
    }
    public mutating func move(translation: Double) {
        distance = max(0, translation - origin)
    }
    public var shouldRefresh: Bool { distance > triggerDistance }
    public var geometry: Geometry { Geometry(distance: distance, trigger: triggerDistance) }

    public struct Geometry: Equatable, Sendable {
        public let offset: Double
        public let endTrim: Double
        public let arrowScale: Double
        public let rotation: Double
        public let opacity: Double
        init(distance: Double, trigger: Double) {
            let drag = min(1, max(0, distance / trigger))
            let adjusted = max(drag - 0.4, 0) * 5 / 3
            let tensionPart = max(0, min(distance - trigger, 128) / 64) / 4
            let tension = (tensionPart - tensionPart * tensionPart) * 2
            offset = -40 + 64 * drag + 128 * tension
            endTrim = min(0.8, adjusted * 0.8)
            arrowScale = min(1, adjusted)
            rotation = (-0.25 + 0.4 * adjusted + tension * 2) * 0.5
            opacity = distance < trigger ? 76.0 / 255 : 1
        }
    }
}

/// CircularProgressDrawable's 666ms finishing lap followed by 1332ms
/// expanding/shrinking laps. Angles are turns, independent of a render engine.
public struct FeedRefreshSpinner: Sendable {
    public struct Frame: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var arrowScale: Double
    }
    private let finishing: FeedPullRefresh.Geometry?
    public init(finishing: FeedPullRefresh.Geometry? = nil) {
        self.finishing = finishing.flatMap { $0.endTrim > 0 ? $0 : nil }
    }
    public func frame(at elapsed: Double) -> Frame {
        var time = max(0, elapsed), baseStart = 0.0, baseRotation = 0.0
        if let finishing {
            let target = floor(finishing.rotation / 0.8) + 1
            if time < 0.666 {
                let fraction = time / 0.666
                let rotation = finishing.rotation + (target - finishing.rotation) * fraction
                return Frame(start: (finishing.endTrim - 0.01) * fraction + rotation,
                             end: finishing.endTrim + rotation, arrowScale: finishing.arrowScale)
            }
            time -= 0.666
            baseStart = finishing.endTrim - 0.01; baseRotation = target
        }
        let cycles = floor(time / 1.332), fraction = time / 1.332 - cycles
        let start = baseStart + cycles * 0.78
        let rotation = baseRotation + (cycles + fraction) * 0.81
        if fraction < 0.5 {
            return Frame(start: start + rotation,
                         end: start + 0.79 * materialEase(fraction * 2) + 0.01 + rotation, arrowScale: 0)
        }
        let end = start + 0.79
        return Frame(start: end - (0.79 * (1 - materialEase((fraction - 0.5) * 2)) + 0.01) + rotation,
                     end: end + rotation, arrowScale: 0)
    }
    private func materialEase(_ value: Double) -> Double {
        // Material FastOutSlowIn cubic(0.4,0,0.2,1), solved for x.
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let t = (low + high) / 2, inverse = 1 - t
            let x = 3 * inverse * inverse * t * 0.4 + 3 * inverse * t * t * 0.2 + t * t * t
            if x < value { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }
}

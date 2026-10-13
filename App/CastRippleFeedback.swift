import UIKit

// Wave/sparkle equations adapted from Android16 RippleShader.java,
// copyright (C) 2021 The Android Open Source Project, Apache License2.0.
// The app keeps the original appearance using a small Core Graphics bitmap;
// no Android rendering engine or private Apple API is involved.
struct CastRippleSample {
    var progress: Float
    var noisePhase: Float // Android shader's millisecond phase, before /1000.
    var touch: CGPoint
}

struct CastRipplePattern {
    static let radius: CGFloat = 16
    private static func unit(_ value: Float) -> Float { min(1, max(0, value)) }
    private static func smooth(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = unit((value - low) / (high - low)); return t * t * (3 - 2 * t)
    }
    private static func circle(_ distance: Float, _ radius: Float, _ blur: Float = 1) -> Float {
        guard radius > 0 else { return 0 }
        return 1 - smooth(1 - blur / 2, 1 + blur / 2, distance / radius)
    }
    private struct Grid {
        let center: SIMD2<Float>, rotation: SIMD2<Float>, diameter: Float
        init(phase: Float, center: Float, speed: Float, angle: Float, rotation: Float, diameter: Float) {
            self.center = SIMD2<Float>(repeating: center) + phase * speed * SIMD2<Float>(cos(angle), sin(angle))
            self.rotation = SIMD2<Float>(cos(rotation), sin(rotation)); self.diameter = diameter
        }
        func value(_ point: SIMD2<Float>) -> Float {
            let delta = center - point
            // GLSL matrices are column-major: mat2(c,-s,s,c).
            var coord = SIMD2<Float>(rotation.x * delta.x + rotation.y * delta.y,
                                     -rotation.y * delta.x + rotation.x * delta.y) + center
            coord = SIMD2<Float>(coord.x - diameter * floor(coord.x / diameter), coord.y - diameter * floor(coord.y / diameter)) / 0.8
            let normalRadius = diameter / 0.8 * 0.5, radius = 0.65 * normalRadius
            coord -= SIMD2<Float>(repeating: normalRadius)
            return CastRipplePattern.circle(sqrt(coord.x * coord.x + coord.y * coord.y), radius, radius * 50)
        }
    }
    private struct Shader {
        let progress: Float, center: SIMD2<Float>, resolution: SIMD2<Float>, maxRadius: Float
        let fade: Float, sparkleFade: Float, offsets: SIMD4<Float>
        let first: Grid, second: Grid, third: Grid
        init(_ sample: CastRippleSample, origin: CGPoint, hotspotSize: CGSize, scale: CGFloat) {
            progress = sample.progress
            let density = Float(scale), mix = CastRipplePattern.unit(progress * 2)
            let touch = SIMD2<Float>(Float(sample.touch.x), Float(sample.touch.y)) * density
            let middle = SIMD2<Float>(Float(origin.x), Float(origin.y)) * density
            center = touch + (middle - touch) * mix
            resolution = SIMD2<Float>(Float(hotspotSize.width), Float(hotspotSize.height)) * density
            maxRadius = Float(CastRipplePattern.radius) * density * 2.3
            let fadeIn = CastRipplePattern.unit(progress / 0.13)
            fade = min(fadeIn, 1 - CastRipplePattern.unit((progress - 0.4) / 0.6))
            sparkleFade = min(fadeIn, 1 - CastRipplePattern.unit((progress - 0.4) / 0.1))
            let t = sample.noisePhase * 0.001
            offsets = SIMD4<Float>(sin(.pi * t), sin(.pi * (t + 0.35)), sin(.pi * (t + 0.7)), sin(.pi * (t + 1.05)))
            let phase = sample.noisePhase, turn = phase * Float.pi * 0.0078125
            first = Grid(phase: phase, center: 0.75, speed: 0.01, angle: 0.825, rotation: turn + 1.7 * .pi, diameter: 0.17)
            second = Grid(phase: phase, center: 0.3, speed: -0.0066, angle: 0.675, rotation: -turn + 2 * .pi, diameter: 0.2)
            third = Grid(phase: phase, center: 1.5, speed: -0.0066, angle: 0.525, rotation: turn + 2.75 * .pi, diameter: 0.275)
        }
        func alpha(_ point: SIMD2<Float>) -> Float {
            let delta = point - center, distance = sqrt(delta.x * delta.x + delta.y * delta.y)
            let currentRadius = maxRadius * progress
            let wave = CastRipplePattern.circle(distance, currentRadius) * fade * 0.2
            guard sparkleFade > 0 else { return wave }
            let thickness = 0.05 * maxRadius
            let ring = CastRipplePattern.unit(CastRipplePattern.circle(distance, currentRadius + thickness)
                - CastRipplePattern.circle(distance, max(0, currentRadius - thickness)))
            guard ring > 0 else { return wave }
            let uv = point * (SIMD2<Float>(repeating: 1) / resolution)
            let noiseScale = SIMD2<Float>(repeating: 2.1) / resolution
            let modulus = uv - SIMD2<Float>(floor(uv.x / noiseScale.x), floor(uv.y / noiseScale.y)) * noiseScale
            var n = uv - modulus
            n *= SIMD2<Float>(5.3987, 5.4421)
            n = SIMD2<Float>(n.x - floor(n.x), n.y - floor(n.y))
            n += SIMD2<Float>(repeating: n.y * (n.x + 21.5351) + n.x * (n.y + 14.3137))
            let xy = n.x * n.y
            let a = xy * 95.4307, b = xy * 75.04961
            let noise = (a - floor(a)) + (b - floor(b)) - 1
            var sparkles: Float = 0
            for index in 0..<4 {
                let value = noise + offsets[index], low = Float(index) * 0.1
                if value >= low && value < low + 0.05 { sparkles += 1 }
            }
            let coord = uv * 0.8
            let g1 = first.value(coord), g2 = second.value(coord), g3 = third.value(coord)
            let turbulence = CastRipplePattern.unit(0.45 + 0.8 * (g1 * g1 + g2 - g3) * 0.5)
            let effectAlpha: Float = 141.0 / 255
            let sparkle = CastRipplePattern.unit(sparkles) * effectAlpha * ring * sparkleFade * turbulence
            return wave + (effectAlpha - wave) * sparkle
        }
    }
    static func bounds(origin: CGPoint, scale: CGFloat) -> CGRect {
        let x = floor((origin.x - radius) * scale) / scale, y = floor((origin.y - radius) * scale) / scale
        return CGRect(x: x, y: y, width: ceil((origin.x + radius) * scale) / scale - x, height: ceil((origin.y + radius) * scale) / scale - y)
    }
    static func image(samples: [CastRippleSample], origin: CGPoint, hotspotSize: CGSize = CGSize(width: 18, height: 18), scale: CGFloat) -> UIImage? {
        guard !samples.isEmpty, scale.isFinite, scale > 0, hotspotSize.width > 0, hotspotSize.height > 0 else { return nil }
        let area = bounds(origin: origin, scale: scale)
        let width = Int((area.width * scale).rounded()), height = Int((area.height * scale).rounded()), shaders = samples.map { Shader($0, origin: origin, hotspotSize: hotspotSize, scale: scale) }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let point = SIMD2<Float>(Float(area.minX * scale) + Float(x) + 0.5,
                                         Float(area.minY * scale) + Float(y) + 0.5)
                var alpha: Float = 0
                for shader in shaders { let next = shader.alpha(point); alpha += next * (1 - alpha) }
                let byte = UInt8((unit(alpha) * 255).rounded()), offset = (y * width + x) * 4
                pixels[offset] = byte; pixels[offset+1] = byte; pixels[offset+2] = byte; pixels[offset+3] = byte
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}

@MainActor final class CastRippleFeedback: NSObject {
    private struct Session {
        let began: CFTimeInterval, touch: CGPoint
        var exitStart: CFTimeInterval?, exitFrom: Float = 0.5
        func progress(at time: CFTimeInterval) -> Float {
            if let exitStart, time >= exitStart { return min(1, exitFrom + (1 - exitFrom) * Float((time - exitStart) / 0.375)) }
            return 0.5 * CastRippleFeedback.ease(Float((time - began) / 0.450))
        }
    }
    weak var view: UIView?
    private var sessions: [Session] = []
    private var link: CADisplayLink?
    private var cached: UIImage?
    private var cachedKey: [Float] = []
    private var backgroundFrom: Float = 0, backgroundTo: Float = 0
    private var backgroundBegan: CFTimeInterval = 0
    private var backgroundState: [Bool] = []
    private func backgroundOpacity(at time: CFTimeInterval) -> Float {
        let progress = min(1, max(0, Float((time - backgroundBegan) / 0.080)))
        return backgroundFrom + (backgroundTo - backgroundFrom) * progress
    }
    func setBackground(focused: Bool, hovered: Bool, windowFocused: Bool, pressed: Bool,
                       time: CFTimeInterval = CACurrentMediaTime()) {
        let state = [focused, hovered, windowFocused, pressed]
        guard backgroundState != state else { return }; backgroundState = state
        if focused || hovered {
            guard !pressed else { return }
            // Patterned RippleDrawable restarts focus entry at zero, with an
            // 80ms linear transition and reduced emphasis in an inactive window.
            backgroundFrom = 0
            backgroundTo = focused ? (windowFocused ? 0.6 : 0.2) : 0.2
        } else {
            backgroundFrom = backgroundOpacity(at: time); backgroundTo = 0
        }
        backgroundBegan = time; scheduleFrames(); view?.setNeedsDisplay()
    }
    nonisolated private static func ease(_ x: Float) -> Float {
        let target = min(1, max(0, x)); var lo: Float = 0, hi: Float = 1, t: Float = 0
        for _ in 0..<18 {
            t = (lo + hi) / 2
            let curve = 3 * (1-t) * (1-t) * t * 0.4 + 3 * (1-t) * t * t * 0.2 + t * t * t
            if curve < target { lo = t } else { hi = t }
        }
        return 3 * (1-t) * t * t + t * t * t
    }
    func press(at point: CGPoint, time: CFTimeInterval = CACurrentMediaTime()) {
        sessions.removeAll { $0.progress(at: time) >= 1 }
        // Source permits a new ripple while running count <=10.
        if sessions.count <= 10 { sessions.append(Session(began: time, touch: point)) }
        scheduleFrames(); view?.setNeedsDisplay()
    }
    func release(time: CFTimeInterval = CACurrentMediaTime()) {
        for index in sessions.indices {
            let start = max(time, sessions[index].began + 0.450)
            let from = sessions[index].progress(at: start)
            sessions[index].exitStart = start; sessions[index].exitFrom = from
        }
        if !sessions.isEmpty { scheduleFrames(); view?.setNeedsDisplay() }
    }
    func reset() {
        link?.invalidate(); link = nil; sessions.removeAll(); cached = nil; cachedKey = []
        backgroundFrom = 0; backgroundTo = 0; backgroundState = []; view?.setNeedsDisplay()
    }
    private func scheduleFrames() {
        guard link == nil, view?.window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ link: CADisplayLink) {
        guard view?.window != nil else { reset(); return }
        let time = CACurrentMediaTime()
        sessions.removeAll { $0.progress(at: time) >= 1 }
        view?.setNeedsDisplay()
        if time >= backgroundBegan + 0.080, !sessions.contains(where: { $0.exitStart != nil || time < $0.began + 0.450 }) {
            link.invalidate(); self.link = nil
        }
    }
    func draw(in context: CGContext, origin: CGPoint, scale: CGFloat, time: CFTimeInterval = CACurrentMediaTime()) {
        let backgroundAlpha = floor(51 * backgroundOpacity(at: time) + 0.5) / 255
        if backgroundAlpha > 0 {
            context.saveGState(); context.setFillColor(UIColor.white.withAlphaComponent(CGFloat(backgroundAlpha)).cgColor)
            context.fillEllipse(in: CGRect(x: origin.x - 16, y: origin.y - 16, width: 32, height: 32))
            context.restoreGState()
        }
        let samples = sessions.compactMap { session -> CastRippleSample? in
            let progress = session.progress(at: time)
            guard progress < 1 else { return nil }
            // Source noise phase advances32ms over7s. At progress>=0.5 the
            // noise is fully gone; freeze its unused phase to reuse the bitmap.
            let noise = progress >= 0.5 ? 0 : Float(session.began * 1000 + min(7, max(0, time - session.began)) * (32.0 / 7))
            return .init(progress: progress, noisePhase: noise, touch: session.touch)
        }
        guard !samples.isEmpty else { cached = nil; cachedKey = []; return }
        let key = [Float(origin.x), Float(origin.y), Float(scale)] + samples.flatMap { [$0.progress, $0.noisePhase, Float($0.touch.x), Float($0.touch.y)] }
        if cachedKey != key { cached = CastRipplePattern.image(samples: samples, origin: origin, scale: scale); cachedKey = key }
        let area = CGRect(x: origin.x - 16, y: origin.y - 16, width: 32, height: 32)
        context.saveGState(); context.addEllipse(in: area); context.clip()
        cached?.draw(in: CastRipplePattern.bounds(origin: origin, scale: scale))
        context.restoreGState()
    }
}

import UIKit
import Testing
@testable import NotTennaPod

@MainActor @Suite(.serialized) struct PlayerLoadingIndicatorTests {
    /// While the player is collapsed its spinner is out of sight: the frame clock pauses and resumes.
    @Test func spinnerOutOfSightDoesNotRunItsFrameClock() async throws {
        try await withViewTestWindow { host, _ in
            let view = PlayerLoadingIndicator(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
            host.view.addSubview(view); defer { view.removeFromSuperview() }
            view.outOfSight = true
            view.startAnimating()
            #expect(view.isAnimating && view.clock?.isPaused != false)
            view.outOfSight = false
            #expect(UIAccessibility.isReduceMotionEnabled || view.clock?.isPaused == false)
            view.outOfSight = true
            #expect(view.clock?.isPaused != false)
            view.stopAnimating()
        }
    }

    @Test func renderedRingIsVisibleScaledAndHollowWhenResized() throws {
        let view = PlayerLoadingIndicator()
        view.overrideUserInterfaceStyle = .light
        view.startAnimating()
        for size in [CGSize(width:64,height:64),CGSize(width:80,height:64),CGSize(width:96,height:96)] {
            view.frame = CGRect(origin:.zero,size:size); view.layoutIfNeeded()
            view.render(at:1.333 / 2,reducedMotion:false)
            let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
            let image = UIGraphicsImageRenderer(size:size,format:format).image { view.layer.render(in:$0.cgContext) }
            let cg = try #require(image.cgImage)
            var bytes = [UInt8](repeating:0,count:cg.width * cg.height * 4)
            let context = try #require(CGContext(data:&bytes,width:cg.width,height:cg.height,bitsPerComponent:8,
                bytesPerRow:cg.width * 4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
            // A visible accent-coloured ring, centred, scaled to the view, with a clear centre.
            // (Approximate: exact radius/colour to the pixel is imperceptible.)
            var radii = [Double](), accent = 0
            for y in 0..<cg.height { for x in 0..<cg.width {
                let index = (y * cg.width + x) * 4
                guard bytes[index + 3] > 240 else { continue }
                let radius = hypot((Double(x)+0.5)/3-size.width/2,(Double(y)+0.5)/3-size.height/2)
                radii.append(radius)
                let alpha = Double(bytes[index + 3]) / 255
                if bytes[index] < 16 && abs(Double(bytes[index+1]) / alpha - 120) < 16 && abs(Double(bytes[index+2]) / alpha - 194) < 16 { accent += 1 }
            }}
            let side = min(size.width,size.height)
            #expect(radii.count > 100)
            #expect(Double(accent) >= Double(radii.count) * 0.95)
            #expect(abs(try #require(radii.min()) - side / 3) < 2)
            #expect(abs(try #require(radii.max()) - side * 5 / 12) < 2)
        }
        view.render(at:0,reducedMotion:true)
        let first = try #require(view.layer.sublayers?.first as? CAShapeLayer).path
        view.render(at:10,reducedMotion:true)
        #expect(first == (view.layer.sublayers?.first as? CAShapeLayer)?.path)
        view.stopAnimating(); #expect(view.isHidden); #expect(!view.isAnimating)
    }
    @Test func mountedMotionStopsAndResumesAcrossWindowAttachment() async throws {
        let controller = UIViewController()
        let window = UIWindow(frame:CGRect(x:0,y:0,width:320,height:600))
        window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let indicator = PlayerLoadingIndicator(frame:CGRect(x:20,y:30,width:64,height:64))
        controller.view.addSubview(indicator); indicator.startAnimating()
        let layer = try #require(indicator.layer.sublayers?.first as? CAShapeLayer)
        let initial = layer.path
        let deadline = ContinuousClock.now + .seconds(2)
        while layer.path == initial && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        #expect(layer.path != initial)
        indicator.removeFromSuperview()
        let detached = layer.path
        try await Task.sleep(for:.milliseconds(80))
        #expect(layer.path == detached)
        controller.view.addSubview(indicator)
        #expect(layer.path != detached)
        indicator.stopAnimating()
        #expect(indicator.isHidden)
    }
}

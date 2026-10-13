import UIKit
import Testing
@testable import NotTennaPod

@MainActor @Suite(.serialized)
struct PreferenceSwitchRenderingTests {
    @Test(arguments: [false, true])
    func roundedTrackLeavesParentVisibleAtCorners(dark: Bool) async throws {
        try await withViewTestWindow { host, _ in
            let canvas = UIView(frame: CGRect(x: 20, y: 20, width: 140, height: 90))
            canvas.overrideUserInterfaceStyle = dark ? .dark : .light
            canvas.backgroundColor = dark ? UIColor(red: 0.15, green: 0.2, blue: 0.25, alpha: 1)
                : UIColor(red: 0.85, green: 0.9, blue: 0.95, alpha: 1)
            host.view.addSubview(canvas)
            defer { canvas.removeFromSuperview() }
            let control = PreferenceSwitchView(frame: CGRect(x: 20, y: 20, width: 52, height: 32))
            canvas.addSubview(control)
            for enabled in [true, false] {
                control.alpha = enabled ? 1 : 0.38
                for on in [false, true] {
                    control.isOn = on
                    control.setNeedsDisplay(); canvas.layoutIfNeeded()
                    let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.preferredRange = .standard
                    let image = UIGraphicsImageRenderer(bounds: canvas.bounds, format: format).image { _ in
                        #expect(canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: true))
                    }
                    let background = try rgb(image, CGPoint(x: 10, y: 10))
                    for point in [CGPoint(x: 1, y: 1), CGPoint(x: 50, y: 1), CGPoint(x: 1, y: 30), CGPoint(x: 50, y: 30)] {
                        let corner = try rgb(image, control.convert(point, to: canvas))
                        #expect(zip(corner, background).allSatisfy { abs(Int($0) - Int($1)) <= 8 },
                                "dark=\(dark) enabled=\(enabled) on=\(on) corner=\(point)")
                    }
                    // The track still renders; transparent corners must not be
                    // achieved by hiding the whole switch or masking its thumb.
                    let thumb = CGPoint(x: on ? 38 : 16, y: 16)
                    #expect(try rgb(image, control.convert(thumb, to: canvas)) != background)
                }
            }
        }
    }

    private func rgb(_ image: UIImage, _ point: CGPoint) throws -> [UInt8] {
        let source = try #require(image.cgImage?.cropping(to: CGRect(x: floor(point.x * image.scale),
            y: floor(point.y * image.scale), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Array(bytes.prefix(3))
    }
}

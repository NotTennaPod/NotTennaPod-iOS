import UIKit
import XCTest
@testable import NotTennaPod

@MainActor final class CastRippleFeedbackTests: XCTestCase {
    private func render(_ feedback: CastRippleFeedback, at time: Double, center: CGPoint = CGPoint(x: 24, y: 24)) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 96, height: 48), format: format).image { renderer in
            Appearance.accent.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
            feedback.draw(in: renderer.cgContext, origin: center, scale: 3, time: time)
        }
    }
    private func red(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> Int {
        let source = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: x * 3, y: y * 3, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int(rgba[0])
    }
    func testFocusAndHoverShowBackgroundAndUnfocusOrResetClearsIt() throws {
        let feedback = CastRippleFeedback()
        feedback.setBackground(focused: true, hovered: false, windowFocused: true, pressed: false, time: 1)
        XCTAssertGreaterThan(try red(render(feedback, at: 1.5), x: 24, y: 14), 0, "Keyboard focus shows a highlight")
        feedback.setBackground(focused: true, hovered: false, windowFocused: false, pressed: false, time: 2)
        XCTAssertGreaterThan(try red(render(feedback, at: 2.5), x: 24, y: 14), 0, "Focus stays visible in an inactive window")
        feedback.setBackground(focused: false, hovered: false, windowFocused: true, pressed: false, time: 3)
        XCTAssertEqual(try red(render(feedback, at: 3.5), x: 24, y: 14), 0, "Losing focus clears the highlight")
        feedback.setBackground(focused: false, hovered: true, windowFocused: true, pressed: false, time: 4)
        XCTAssertGreaterThan(try red(render(feedback, at: 4.5), x: 24, y: 14), 0, "Pointer hover shows a highlight")
        feedback.setBackground(focused: true, hovered: false, windowFocused: true, pressed: true, time: 5.1)
        feedback.press(at: CGPoint(x: 24, y: 24), time: 5.1)
        XCTAssertGreaterThan(try red(render(feedback, at: 5.6), x: 24, y: 14), 0, "Press shows a ripple")
        feedback.reset(); XCTAssertEqual(try red(render(feedback, at: 6), x: 24, y: 14), 0)
    }
    func testQuickReleaseStillShowsRippleThenFadesAndFollowsThumb() throws {
        let control = UIView(), feedback = CastRippleFeedback(); feedback.view = control
        feedback.press(at: CGPoint(x: 24, y: 24), time: 1)
        feedback.release(time: 1.05)
        XCTAssertGreaterThan(try red(render(feedback, at: 1.44), x: 24, y: 14), 0, "A quick tap still shows its ripple")
        XCTAssertEqual(try red(render(feedback, at: 3), x: 24, y: 14), 0, "The ripple fades out after release")
        feedback.reset(); feedback.press(at: CGPoint(x: 24, y: 24), time: 2); feedback.release(time: 2.5)
        feedback.press(at: CGPoint(x: 24, y: 24), time: 2.51)
        // Live waves follow the current thumb position.
        let moved = render(feedback, at: 2.8, center: CGPoint(x: 72, y: 24))
        XCTAssertEqual(try red(moved, x: 24, y: 14), 0)
        XCTAssertGreaterThan(try red(moved, x: 72, y: 14), 0)
        feedback.reset(); XCTAssertEqual(try red(render(feedback, at: 2.8), x: 72, y: 14), 0)
    }
}

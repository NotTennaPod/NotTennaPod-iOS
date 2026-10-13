import UIKit
import Testing
@testable import NotTennaPod

@MainActor @Suite(.serialized)
struct SourceSingleChoiceShadowTests {
    @Test func visibleShadowFollowsPanelAfterResizing() async throws {
        let controller = SourceSingleChoiceController(title: "Volume adaptation", identifier: "shadowProbe",
            choices: ["Heavy reduction", "Light reduction", "No adaption", "Light boost", "Medium boost", "Heavy boost"].enumerated().map { (String($0.offset), $0.element) },
            selectedIndex: 2, onSelect: { _ in })
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.traitOverrides.preferredContentSizeCategory = .large
            // Isolate the actual source backdrop color, excluding different underlying content.
            controller.view.backgroundColor = UIColor(red: 169/255, green: 171/255, blue: 173/255, alpha: 1)
            let panel = try #require(controller.view.subviews.first { $0.accessibilityIdentifier == "shadowProbeContent" })
            // A dialog shadow is visible next to the panel (strongest below it) and fades
            // into the backdrop; its exact per-pixel profile is not user-visible.
            let distances: [CGFloat] = [1, 20]
            let backdrop = [169, 171, 173]
            for width: CGFloat in [410, 340, 410] {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.preferredRange = .standard
                let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
                    #expect(controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true))
                }
                let left = try distances.map { try rgb(image, CGPoint(x: panel.frame.minX - $0, y: panel.frame.midY)) }
                let bottom = try distances.map { try rgb(image, CGPoint(x: panel.frame.midX, y: panel.frame.maxY + $0)) }
                print("Dialog shadow width=\(width) left=\(left) bottom=\(bottom)")
                #expect(left.first![0] < left.last![0] - 5 && bottom.first![0] < bottom.last![0] - 10)
                #expect(bottom.first![0] <= left.first![0])
                for far in [left.last!, bottom.last!] { #expect(zip(far, backdrop).allSatisfy { abs($0 - $1) <= 8 }) }
                let outside = CGPoint(x: panel.frame.minX - 2, y: panel.frame.midY)
                #expect(controller.view.hitTest(outside, with: nil) === controller.view)
            }
            controller.view.frame.size.height = 0
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(panel.isHidden)
            #expect(controller.view.subviews.filter { !$0.isHidden }.allSatisfy { $0.frame == .zero })
        }
    }
    private func rgb(_ image: UIImage, _ point: CGPoint) throws -> [Int] {
        let source = try #require(image.cgImage?.cropping(to: CGRect(x: floor(point.x * 3), y: floor(point.y * 3), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }
}

import UIKit
import Testing
@testable import NotTennaPod

/// Source TextInputLayout: the floating hint aligns with the text and the outline
/// is interrupted around it, so no line runs through the label.
@MainActor @Suite(.serialized)
struct GpodderAuthenticationFieldRenderingTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark],
          [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft])
    func floatingHintClearsOutlineAndPreservesEditingStates(style: UIUserInterfaceStyle,
                                                           direction: UISemanticContentAttribute) async throws {
        try await withViewTestWindow { host, _ in
            let control = GpodderAuthenticationField(key: "synchronization_host_label", identifier: "renderedHost")
            host.view.addSubview(control)
            defer { control.removeFromSuperview() }
            control.overrideUserInterfaceStyle = style
            control.semanticContentAttribute = direction
            // A distinct surface detects painted-over gaps and missing transparency.
            control.backgroundColor = .magenta
            for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                control.traitOverrides.preferredContentSizeCategory = category
                control.updateTraitsIfNeeded()
                control.frame = CGRect(x: 0, y: 100, width: 600, height: control.intrinsicContentSize.height)
                for state in 0..<3 {
                    control.field.resignFirstResponder()
                    control.field.isEnabled = state != 1
                    control.text = state == 2 ? "" : "https://cloud.example.test"
                    if state == 2 { try #require(control.field.becomeFirstResponder()) }
                    control.setNeedsLayout(); control.layoutIfNeeded()
                    let outline = try #require(control.field.superview)
                    let hint = try #require(outline.subviews.compactMap { $0 as? UILabel }.first)
                    #expect(!hint.isHidden)
                    // The floating hint sits at the field's leading text edge (mirrored in RTL).
                    if direction == .forceRightToLeft {
                        #expect(abs(hint.frame.maxX - control.field.frame.maxX) < 1)
                    } else { #expect(abs(hint.frame.minX - control.field.frame.minX) < 1) }
                    let leftInset = control.field.frame.minX, rightInset = outline.bounds.maxX - control.field.frame.maxX
                    #expect(leftInset > 0 && abs(leftInset - rightInset) < 1, "Text has equal padding inside the outline")
                    #expect(hint.bounds.height >= hint.sizeThatFits(CGSize(width: hint.bounds.width, height: .greatestFiniteMagnitude)).height - 0.5)
                    // The outline is interrupted around the hint (no line through the label) and continues beyond it.
                    let pixels = try render(control)
                    let y = outline.frame.minY + 0.5
                    for x in [hint.frame.minX - 2, hint.frame.maxX + 2] {
                        #expect(pixels.isMagenta(x: x, y: y), "Floating hint must clear the outline at \(x), \(y), state \(state)")
                    }
                    for x in [hint.frame.minX - 12, hint.frame.maxX + 12] where x > 1 && x < outline.bounds.maxX - 1 {
                        #expect(!pixels.isMagenta(x: x, y: y), "Outline continues beyond the hint")
                    }
                    #expect(!pixels.isMagenta(x: 0.5, y: outline.frame.midY), "Outline is drawn")
                }
                control.field.resignFirstResponder(); control.field.isEnabled = true; control.text = ""
                control.setNeedsLayout(); control.layoutIfNeeded()
                let outline = try #require(control.field.superview)
                let hint = try #require(outline.subviews.compactMap { $0 as? UILabel }.first)
                #expect(hint.isHidden && control.field.attributedPlaceholder?.string == Appearance.text("synchronization_host_label"))
                let pixels = try render(control)
                #expect(!pixels.isMagenta(x: 20, y: outline.frame.minY + 0.5), "Empty unfocused field has a continuous outline")
            }
        }
    }

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        func isMagenta(x: CGFloat, y: CGFloat) -> Bool {
            let index = (Int(y * 3) * width + Int(x * 3)) * 4
            return bytes[index] > 250 && bytes[index + 1] < 5 && bytes[index + 2] > 250 && bytes[index + 3] > 250
        }
    }
    private func render(_ view: UIView) throws -> Pixels {
        @MainActor func display(_ layer: CALayer) {
            layer.displayIfNeeded(); layer.sublayers?.forEach(display)
        }
        display(view.layer)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image {
            view.layer.render(in: $0.cgContext)
        }
        let cg = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Pixels(bytes: bytes, width: cg.width)
    }
}

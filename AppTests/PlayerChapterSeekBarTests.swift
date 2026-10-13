import UIKit
import Testing
@testable import NotTennaPod

@MainActor
@Suite(.serialized)
struct PlayerChapterSeekBarTests {
    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let scale: CGFloat
        let origin: CGPoint
        func rgba(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            let offset = (Int((y - origin.y) * scale) * width + Int((x - origin.x) * scale)) * 4
            return Array(bytes[offset..<(offset + 4)])
        }
    }

    /// Draw the actual track implementation into an explicit RGBA surface. Thumb
    /// rendering is a separate UIImageView and cannot obscure the sampled track.
    private func pixels(_ bar: PlayerSeekBar) throws -> Pixels {
        let scale: CGFloat = 10
        let width = Int(bar.bounds.width * scale), height = Int(bar.bounds.height * scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bar.bounds.minX, y: -bar.bounds.minY)
            UIGraphicsPushContext(context)
            defer { UIGraphicsPopContext() }
            bar.draw(bar.bounds)
        }
        return Pixels(bytes: bytes, width: width, scale: scale, origin: bar.bounds.origin)
    }

    private func control() -> PlayerSeekBar {
        let bar = PlayerSeekBar()
        bar.frame = CGRect(x: 0, y: 0, width: 232, height: 24)
        bar.chapterFractions = [0, 0.25, 0.75]
        bar.value = 250
        return bar
    }

    /// True when the track has a transparent chapter divider within ~1.5 pt of `x`
    /// (position tolerance: a person cannot see a sub-point shift of the divider).
    private func hasGap(_ rendered: Pixels, near x: CGFloat, y: CGFloat) -> Bool {
        stride(from: x - 1.5, through: x + 1.5, by: 0.1).contains { rendered.rgba($0, y)[3] <= 16 }
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func chapterGapsPlayedAndUnplayedTrackAreVisible(style: UIUserInterfaceStyle) throws {
        let bar = control()
        bar.traitOverrides.userInterfaceStyle = style
        // This test invokes draw directly rather than awaiting UIKit's display pass.
        // Apply the pending trait override first, as UIView's SDK contract requires.
        bar.updateTraitsIfNeeded()
        try #require(bar.traitCollection.userInterfaceStyle == style)
        let rendered = try pixels(bar)
        // Played part: opaque accent colour (approximately; exact shade is imperceptible).
        let accent: [Int] = style == .dark ? [61, 139, 255] : [0, 120, 194]
        for x: CGFloat in [40, 80] {
            let pixel = rendered.rgba(x, 12)
            #expect(pixel[3] == 255 && zip(pixel.prefix(3), accent).allSatisfy { abs(Int($0) - $1) <= 16 }, "\(pixel)")
        }
        // Unplayed part: visible but translucent.
        for x: CGFloat in [145, 190] {
            let alpha = rendered.rgba(x, 12)[3]
            #expect(alpha > 60 && alpha < 200, "\(alpha)")
        }
        // Chapter dividers at 25 % and 75 %, none inside a chapter.
        #expect(hasGap(rendered, near: 65.4, y: 12) && hasGap(rendered, near: 165.4, y: 12))
        #expect(!hasGap(rendered, near: 40, y: 12) && !hasGap(rendered, near: 190, y: 12))
    }

    @Test
    func chapterHighlightFollowsCurrentProgressAndResetsAfterOneSecond() throws {
        var resets: [@MainActor @Sendable () -> Void] = []
        var delays: [Duration] = []
        let bar = PlayerSeekBar { delay, reset in delays.append(delay); resets.append(reset) }
        bar.frame = CGRect(x: 0, y: 0, width: 232, height: 24)
        bar.chapterFractions = [0, 0.25, 0.75]
        bar.value = 250
        // Idle: thin track. Highlight thickens only the current chapter (25–75 %).
        #expect(try pixels(bar).rgba(80, 10.2)[3] < 40)
        bar.highlightCurrentChapter()
        var rendered = try pixels(bar)
        #expect(rendered.rgba(80, 10.2)[3] > 200)
        #expect(rendered.rgba(40, 10.2)[3] < 40)
        #expect(delays == [.seconds(1)])
        resets[0]()
        #expect(try pixels(bar).rgba(80, 10.2)[3] < 40)
        // While pressed, the highlighted chapter follows the position.
        bar.isHighlighted = true
        #expect(try pixels(bar).rgba(80, 10.2)[3] > 200)
        bar.value = 425
        rendered = try pixels(bar)
        #expect(rendered.rgba(80, 10.2)[3] < 40)
        #expect(rendered.rgba(180, 10.2)[3] > 200)
        bar.isHighlighted = false
        #expect(try pixels(bar).rgba(180, 10.2)[3] < 40)
    }

    @Test
    func bufferedProgressIsVisibleAndNoChaptersMeansNoDividers() throws {
        let bar = control()
        bar.value = 0
        bar.secondaryValue = 250
        var rendered = try pixels(bar)
        let buffered = rendered.rgba(40, 12)[3], unbuffered = rendered.rgba(145, 12)[3]
        #expect(buffered > unbuffered + 30, "buffered \(buffered), unbuffered \(unbuffered)")
        #expect(abs(Int(rendered.rgba(80, 12)[3]) - Int(buffered)) <= 8)
        #expect(hasGap(rendered, near: 65.4, y: 12))
        bar.chapterFractions = []
        rendered = try pixels(bar)
        #expect(!hasGap(rendered, near: 65.4, y: 12) && !hasGap(rendered, near: 165.4, y: 12))
    }

    @Test(arguments: [CGFloat(132), 432, 832])
    func resizingKeepsDividersAtChapterPositionsAndRetainsValue(width: CGFloat) throws {
        let bar = control()
        bar.bounds = CGRect(x: 7, y: 3, width: width, height: 24)
        bar.layoutIfNeeded()
        let rendered = try pixels(bar)
        let trackStart = bar.bounds.minX + 16
        let boundary = trackStart + (width - 32) * 0.25
        #expect(hasGap(rendered, near: boundary - 0.6, y: bar.bounds.midY))
        #expect(rendered.rgba(trackStart + 5, bar.bounds.midY)[3] == 255)
        // The thumb still shows the retained position (half way) after the resize.
        #expect(abs((bar.subviews.first?.center.x ?? -1) - bar.bounds.midX) <= 1)
    }

    @Test
    func accessibilityActionsRetainTheirValueAndCompletionEvents() {
        let bar = control()
        var events: [String] = []
        bar.addAction(UIAction { _ in events.append("change") }, for: .valueChanged)
        bar.addAction(UIAction { _ in events.append("end") }, for: .editingDidEnd)
        bar.accessibilityIncrement()
        #expect(bar.value == 275 && bar.accessibilityValue == "55%")
        #expect(events == ["change", "end"])
        bar.accessibilityDecrement()
        #expect(bar.value == 250 && bar.accessibilityValue == "50%")
        bar.isEnabled = false
        bar.accessibilityIncrement()
        #expect(bar.value == 250 && events.count == 4)
        bar.isEnabled = true
        bar.value = 500
        bar.accessibilityIncrement()
        #expect(events.count == 4)
        #expect(bar.accessibilityTraits.contains(.adjustable))
    }

    /// Playback ticks set the same quantized values again; that must not repaint the track. Real changes still do.
    @Test
    func repeatedValuesDoNotRepaintAndChangesDo() {
        let bar = control()
        bar.secondaryValue = 300
        bar.layer.displayIfNeeded()
        #expect(!bar.layer.needsDisplay())
        bar.value = 250.2; bar.secondaryValue = 300; bar.chapterFractions = [0, 0.25, 0.75]
        #expect(!bar.layer.needsDisplay())
        #expect(bar.value == 250 && bar.accessibilityValue == "50%")
        bar.value = 251
        #expect(bar.layer.needsDisplay())
        bar.layer.displayIfNeeded()
        bar.secondaryValue = 301
        #expect(bar.layer.needsDisplay())
        bar.layer.displayIfNeeded()
        bar.chapterFractions = [0, 0.5]
        #expect(bar.layer.needsDisplay())
    }
}

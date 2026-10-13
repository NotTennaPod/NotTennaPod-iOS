import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct EpisodeMenuLayoutTests {
    /// Same frame as the Android capture within one point (`tolerance` pixels).
    private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
    @Test func actualOverflowAnchorMatchesSameStateSourceCaptures() {
        // Android captures: popup background, not the inset list. Six rows.
        let captures: [(CGFloat, CGSize, CGRect, Bool, CGRect, CGRect)] = [
            (2.625, CGSize(width: 1080, height: 2400), CGRect(x: 975, y: 152, width: 105, height: 126),
             false, CGRect(x: 555, y: 153, width: 515, height: 798),
             CGRect(x: 597, y: 174, width: 431, height: 126)),
            (2, CGSize(width: 1600, height: 2560), CGRect(x: 1504, y: 157, width: 80, height: 96),
             false, CGRect(x: 1184, y: 158, width: 392, height: 608),
             CGRect(x: 1216, y: 174, width: 328, height: 96)),
            (2.625, CGSize(width: 1080, height: 2400), CGRect(x: 0, y: 152, width: 105, height: 126),
             true, CGRect(x: 0, y: 153, width: 515, height: 798),
             CGRect(x: 42, y: 174, width: 431, height: 126))
        ]
        for (density, viewport, anchor, rtl, expected, expectedFirstRow) in captures {
            let layout = EpisodeMenuLayout(viewport: CGSize(width: viewport.width / density, height: viewport.height / density),
                overflowAnchor: CGRect(x: anchor.minX / density, y: anchor.minY / density,
                    width: anchor.width / density, height: anchor.height / density),
                titleWidths: Array(repeating: 120, count: 6), density: density, rightToLeft: rtl)
            func pixels(_ frame: CGRect) -> CGRect {
                CGRect(x: (frame.minX * density).rounded(), y: (frame.minY * density).rounded(),
                    width: (frame.width * density).rounded(), height: (frame.height * density).rounded())
            }
            #expect(near(pixels(layout.panel), expected, density))
            #expect(near(pixels(CGRect(origin: .zero, size: layout.contentSize)), CGRect(origin: .zero, size: expected.size), density))
            #expect(layout.rows.count == 6)
            // Compare all six row pitches and their 16dp inset control areas.
            // Text glyph bounds/vertical font metrics are a separate visual gate.
            for (index, row) in layout.rows.enumerated() {
                let actual = pixels(row.offsetBy(dx: layout.panel.minX, dy: layout.panel.minY))
                #expect(near(actual, expectedFirstRow.offsetBy(dx: 0, dy: CGFloat(index) * expectedFirstRow.height), density))
            }
        }
    }

    @Test func overflowRetainsAnchorAndClipsLongContentInConstrainedViewport() {
        for rtl in [false, true] {
            let layout = EpisodeMenuLayout(viewport: CGSize(width: 320, height: 240),
                overflowAnchor: CGRect(x: rtl ? 24 : 256, y: 48, width: 40, height: 48),
                titleWidths: Array(repeating: 500, count: 10), density: 3, rightToLeft: rtl)
            #expect(layout.panel.minX >= 0 && layout.panel.maxX <= 320)
            // Opens at the overflow button and fits the window; the long menu
            // scrolls instead of being cut off.
            #expect(abs(layout.panel.minY - (48 + 1.0 / 3)) <= 1)
            #expect(abs(layout.panel.maxY - 240) <= 1)
            #expect(abs(layout.contentSize.height - 496) <= 1)
            #expect(layout.contentSize.height > layout.panel.height)
        }
    }

    @Test func matchesOriginalMeasuredRowsWidthAndTrailingAnchor() {
        // Original09 popup [555,132][1070,804], five48dp rows, density2.625.
        // Vertical anchor is supplied from the capture, not claimed resolved.
        let d: CGFloat = 2.625
        let layout = EpisodeMenuLayout(viewport: CGSize(width: 1080/d, height: 2400/d),
            anchorY: 132/d, titleWidths: [110, 100, 105, 120, 50], density: d)
        func pixels(_ frame: CGRect) -> CGRect {
            CGRect(x: (frame.minX*d).rounded(), y: (frame.minY*d).rounded(),
                   width: (frame.width*d).rounded(), height: (frame.height*d).rounded())
        }
        // Compare the recorded integer raster coordinates, not binary floating
        // point addition order when joining parent and child fractional points.
        #expect(near(pixels(layout.panel), CGRect(x: 555, y: 132, width: 515, height: 672), d))
        for index in 0..<5 {
            #expect(near(pixels(layout.rows[index].offsetBy(dx: layout.panel.minX, dy: layout.panel.minY)),
                CGRect(x: 597, y: CGFloat(153 + 126*index), width: 431, height: 126), d))
        }
    }

    @Test func longLabelsConstrainedWindowsAndRTLKeepMeasurementsAndScrolling() {
        for width: CGFloat in [0, 100, 320, 393, 768, 1024] {
            for density: CGFloat in [1, 2.625, 3] {
                let normal = EpisodeMenuLayout(viewport: CGSize(width: width, height: 300), anchorY: 250,
                    titleWidths: Array(repeating: 800, count: 10), density: density)
                let rtl = EpisodeMenuLayout(viewport: CGSize(width: width, height: 300), anchorY: 250,
                    titleWidths: Array(repeating: 800, count: 10), density: density, rightToLeft: true)
                let actualWidth = (width * density).rounded() / density
                #expect(abs(normal.panel.minX + rtl.panel.maxX - actualWidth) <= 0.5)
                #expect(abs(normal.panel.width - rtl.panel.width) <= 0.5 && abs(normal.panel.height - rtl.panel.height) <= 0.5)
                #expect(normal.panel.minX >= 0 && normal.panel.maxX <= actualWidth)
                #expect(normal.contentSize.height > normal.panel.height)
                for row in normal.rows { #expect(row.width >= 0 && row.minX >= 0 && row.maxX <= normal.panel.width + 0.5) }
            }
        }
    }
}

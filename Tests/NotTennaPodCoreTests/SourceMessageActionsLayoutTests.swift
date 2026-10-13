import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct SourceMessageActionsLayoutTests {
    @Test func actionMinimumTracksMeasuredNormalAndLargeTextButtons() {
        // Material1.12.0 runtime at density2.625: button126/min231 px at
        // fontScale1, button143/min248 px at fontScale2. Padding stays unscaled.
        for (buttonPixels, minimumPixels) in [(126.0, 231.0), (143.0, 248.0)] {
            let layout = SourceMessageActionsLayout(width: 256, positiveTextWidth: 80,
                negativeTextWidth: 80, neutralTextWidth: 80, buttonHeight: buttonPixels / 2.625)
            #expect(layout.stacked)
            #expect(abs(layout.minimumHeight - minimumPixels / 2.625) < 1)
            #expect(layout.positive.height >= buttonPixels / 2.625)
            #expect(layout.minimumHeight < layout.height)
        }
    }

    @Test func recordedStreamingDialogRetainsAllThreeButtonAnchors() throws {
        // Android streaming-confirmation/05-confirmation, Pixel 8 at 2.625 px/dp.
        let density = 2.625
        let safe = CGRect(x: 0, y: 132 / density, width: 1080 / density, height: 2205 / density)
        let width = SourceDialogLayout.width(in: safe)
        let actions = SourceMessageActionsLayout(width: width, positiveTextWidth: 32,
                                                negativeTextWidth: 46, neutralTextWidth: 44)
        let dialog = SourceDialogLayout.message(available: safe, titleTextHeight: 29, textHeight: 157 / density,
                                               footerHeight: actions.height)
        #expect(!actions.stacked && abs(actions.height - 76) <= 0.5)
        let actual = [try #require(actions.neutral), try #require(actions.negative), actions.positive]
        let original = [CGRect(x: 154, y: 1337, width: 179, height: 126),
                        CGRect(x: 553, y: 1337, width: 184, height: 126),
                        CGRect(x: 758, y: 1337, width: 168, height: 126)]
        for (local, reference) in zip(actual, original) {
            let frame = local.offsetBy(dx: dialog.panel.minX, dy: dialog.panel.minY + dialog.footer.minY)
            for (a, b) in [(frame.minX, reference.minX), (frame.maxX, reference.maxX),
                           (frame.minY, reference.minY), (frame.maxY, reference.maxY)] {
                #expect(abs(a - b / density) < 1)
            }
        }
    }

    @Test func singleOKKeepsExistingErrorGeometry() {
        let actions = SourceMessageActionsLayout(width: 342, positiveTextWidth: 19)
        // Right-aligned OK button inside the footer, at least a 64x48 touch target (within 1 pt).
        let expected = CGRect(x: 254, y: 14, width: 64, height: 48)
        for (a, b) in [(actions.positive.minX, expected.minX), (actions.positive.maxX, expected.maxX),
                       (actions.positive.minY, expected.minY), (actions.positive.maxY, expected.maxY)] {
            #expect(abs(a - b) <= 1)
        }
        #expect(actions.negative == nil && actions.neutral == nil && abs(actions.height - 76) <= 1)
    }

    @Test func textGrowthAndRTLKeepActionsDistinctAndInsideTheFooter() {
        for width: CGFloat in [0, 40, 240, 342, 560] {
            for length: CGFloat in [30, 80, 250] {
                for count in 1...3 {
                    let ltr = SourceMessageActionsLayout(width: width, positiveTextWidth: length,
                        negativeTextWidth: count > 1 ? length : nil, neutralTextWidth: count > 2 ? length : nil)
                    let rtl = SourceMessageActionsLayout(width: width, positiveTextWidth: length,
                        negativeTextWidth: count > 1 ? length : nil, neutralTextWidth: count > 2 ? length : nil,
                        rightToLeft: true)
                    let left = [ltr.positive, ltr.negative, ltr.neutral].compactMap { $0 }
                    let right = [rtl.positive, rtl.negative, rtl.neutral].compactMap { $0 }
                    for (a, b) in zip(left, right) {
                        #expect(a.minX >= -0.5 && a.maxX <= width + 0.5)
                        #expect(a.minY >= -0.5 && a.maxY <= ltr.height + 0.5)
                        #expect(abs(a.minX - (width - b.maxX)) <= 0.5)
                        #expect(abs(a.width - b.width) <= 0.5 && abs(a.minY - b.minY) <= 0.5)
                    }
                    for first in left.indices {
                        for second in left.indices where first < second {
                            #expect(!left[first].intersects(left[second]))
                        }
                    }
                }
            }
        }
    }
}

import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct PlayerSeekLayoutTests {
    /// Layout is judged at the precision a person sees: half a point.
    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }
    @Test func trackMatchesAndroidChapterSeekBarAndAppCompatPadding() {
        let density: CGFloat = 2.625
        let bounds = CGRect(x: 0, y: 0, width: 1038 / density, height: 47 / density)
        let layout = PlayerSeekLayout(bounds: bounds, value: 100, scale: density)
        // A thin track inset symmetrically from both ends and vertically centred; the
        // progress fill is proportional to the value (100 of 500) and ends at the thumb.
        #expect(layout.track.minX > 0 && abs(layout.track.minX - (bounds.width - layout.track.maxX)) < 0.5)
        #expect(layout.track.height > 0 && layout.track.height <= 4)
        #expect(abs(layout.track.midY - bounds.midY) < 0.5)
        #expect(abs(layout.progress.width - layout.track.width / 5) < 0.5)
        #expect(near(layout.thumbCenter.x, layout.progress.maxX))
    }

    @Test func everyStepKeepsThumbAndProgressTogetherAcrossViewports() {
        for width: CGFloat in [48, 320, 386, 752, 1008] {
            for scale: CGFloat in [1, 2, 2.625, 3] {
                for step in 0...500 {
                    let layout = PlayerSeekLayout(bounds: CGRect(x: 8, y: 4, width: width, height: 18),
                                                  value: Float(step), scale: scale)
                    #expect(near(layout.thumbCenter.y, 13))
                    #expect(near(layout.progress.minX, layout.track.minX))
                    #expect(near(layout.progress.maxX, layout.thumbCenter.x))
                    #expect(layout.value(at: layout.thumbCenter.x) == Float(step))
                    #expect(layout.progress.width >= 0 && layout.progress.width <= layout.track.width)
                }
            }
        }
    }

    @Test func touchClampsAndRoundsToFiveHundredSteps() {
        let layout = PlayerSeekLayout(bounds: CGRect(x: 0, y: 0, width: 532, height: 18), value: 0)
        for (x, expected): (CGFloat, Float) in [(-100, 0), (16, 0), (16.49, 0), (16.5, 1),
                                               (266, 250), (515.49, 499), (515.5, 500), (532, 500), (1000, 500)] {
            #expect(layout.value(at: x) == expected)
        }
        for value: Float in [-1, 0, 0.49, 0.5, 250.49, 250.5, 499.5, 500, 1000] {
            #expect(PlayerSeekLayout.quantize(value) == min(500, max(0, value.rounded())))
        }
    }

    @Test func DegenerateBoundsAndInvalidValuesRemainFinite() {
        for width: CGFloat in [0, 1, 16, 31, 32] {
            let layout = PlayerSeekLayout(bounds: CGRect(x: 0, y: 0, width: width, height: 18), value: .nan)
            #expect(layout.track.width == 0)
            #expect(layout.progress.width == 0)
            #expect(layout.value(at: 100) == 0)
        }
        for value: Float in [.nan, .infinity, -.infinity] {
            #expect(PlayerSeekLayout.quantize(value) == 0)
        }
    }
}

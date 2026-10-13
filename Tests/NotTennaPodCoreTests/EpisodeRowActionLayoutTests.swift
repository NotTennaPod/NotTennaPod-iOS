import Testing
@testable import NotTennaPodCore

struct EpisodeRowActionLayoutTests {
    @Test func sourceGoneActionReleasesItsWidthAndMarginInBothDirections() {
        for rtl in [false, true] {
            let visible = EpisodeRowLayout(width: 402, titleHeight: 40, metadataHeight: 14, progressHeight: 0, draggable: false, rightToLeft: rtl)
            let hidden = EpisodeRowLayout(width: 402, titleHeight: 40, metadataHeight: 14, progressHeight: 0, draggable: false, showAction: false, rightToLeft: rtl)
            // Hiding the action button gives its space to the text, keeps the
            // cover where it was and the row height unchanged.
            let releasedWidth = Double(hidden.text.width) - Double(visible.text.width)
            #expect(abs(releasedWidth - 60) <= 0.5)
            #expect(hidden.action.width == 0)
            #expect(abs(hidden.cover.minX - visible.cover.minX) <= 0.5 && abs(hidden.cover.minY - visible.cover.minY) <= 0.5)
            #expect(abs(hidden.height - visible.height) <= 0.5)
            #expect(rtl ? abs(hidden.text.minX - 8) <= 0.5 : abs(hidden.text.maxX - 394) <= 0.5)
        }
    }
}

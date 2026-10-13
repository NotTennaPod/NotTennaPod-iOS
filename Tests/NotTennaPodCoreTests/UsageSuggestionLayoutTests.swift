import Foundation
import Testing
@testable import NotTennaPodCore

struct UsageSuggestionLayoutTests {
    /// Composition matches the recorded Android popup within 2 pt (not pixel-exact).
    @Test func measuredOriginalPopupFrames() throws {
        struct Capture: Decodable {
            struct Sample: Decodable { let offerStreaming: Bool; let anchorBottom: CGFloat; let bounds: [String: [Int]] }
            let referenceCommit: String
            let density, width, fontSize, fontUnits, fontAscent, fontDescent, fontTop, fontBottom: CGFloat
            let cases: [Sample]
        }
        let url = try #require(Bundle.module.url(forResource: "usage-suggestion-frames", withExtension: "json", subdirectory: "Fixtures"))
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
        #expect(capture.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(capture.cases.count == 3)
        let scale = capture.density
        for item in capture.cases {
            let layout = UsageSuggestionLayout(width: capture.width / scale, anchorBottom: item.anchorBottom / scale,
                messageLineHeight: capture.fontSize * (capture.fontAscent + capture.fontDescent) / capture.fontUnits,
                messageFontHeight: capture.fontSize * (capture.fontTop + capture.fontBottom) / capture.fontUnits,
                noTextWidth: 18, yesTextWidth: 24, offerStreaming: item.offerStreaming, scale: scale)
            for (name, frame) in ["card": layout.card, "arrow": layout.arrow, "message": layout.message, "no": layout.no, "yes": layout.yes] {
                let original = try #require(item.bounds[name]).map { CGFloat($0) / scale }
                let actual = [frame.minX, frame.minY, frame.maxX, frame.maxY]
                for (a, b) in zip(actual, original) {
                    #expect(abs(a - b) <= 2, "Original \(name), offerStream=\(item.offerStreaming)")
                }
            }
        }
    }

    @Test(arguments: [CGFloat(320), 402, 768, 1024], [CGFloat(1), 2, 2.625, 3])
    func mirroredCompositionAndOfferDirection(width: CGFloat, scale: CGFloat) {
        for offer in [false, true] {
            let ltr = UsageSuggestionLayout(width: width, anchorBottom: 200, messageLineHeight: 19, messageFontHeight: 21,
                noTextWidth: 20, yesTextWidth: 28, offerStreaming: offer, scale: scale)
            let rtl = UsageSuggestionLayout(width: width, anchorBottom: 200, messageLineHeight: 19, messageFontHeight: 21,
                noTextWidth: 20, yesTextWidth: 28, offerStreaming: offer, rightToLeft: true, scale: scale)
            #expect(abs(ltr.card.midX - rtl.card.midX) < 0.5 && abs(ltr.message.midX - rtl.message.midX) < 0.5)
            #expect(abs(ltr.arrow.midX + rtl.arrow.midX - width) < 0.5)
            #expect(abs(ltr.no.minX + rtl.no.maxX - width) < 0.5)
            #expect(abs(ltr.yes.minX + rtl.yes.maxX - width) < 0.5)
            #expect(ltr.card.insetBy(dx: -0.5, dy: -0.5).contains(ltr.no) && ltr.card.insetBy(dx: -0.5, dy: -0.5).contains(ltr.yes))
            #expect(ltr.message.maxY < ltr.no.minY)
            // No before Yes, side by side without overlap.
            #expect(ltr.no.maxX <= ltr.yes.minX + 0.5 && !ltr.no.insetBy(dx: 0.5, dy: 0.5).intersects(ltr.yes))
        }
    }

    @Test func overshootPreservesSourceStartEndDurationCurve() {
        #expect(UsageSuggestionLayout.presentationScale(at: -1) == 0.5)
        #expect(UsageSuggestionLayout.presentationScale(at: 0) == 0.5)
        #expect(UsageSuggestionLayout.presentationScale(at: 1) == 1)
        #expect(UsageSuggestionLayout.presentationScale(at: 2) == 1)
        #expect(UsageSuggestionLayout.presentationScale(at: 0.6) > 1)
    }
}

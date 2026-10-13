import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct SourceDialogLayoutTests {
    /// Dialog geometry is compared within 1 pt of the Android captures, not to the exact fraction.
    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
    @Test func sourceRuntimeMinimumAndPreferredWidthsAcrossConfigurations() {
        // Independent Android3.12.1/API36 original-dialog and inherited-measurement captures.
        for (size, minimum, preferred): (CGSize, CGFloat, CGFloat) in [
            (CGSize(width: 640, height: 960), 464, 532),
            (CGSize(width: 960, height: 640), 480, 532),
            (CGSize(width: 834, height: 1210), 552, 532),
            (CGSize(width: 960, height: 1280), 643, 532),
            (CGSize(width: 1280, height: 960), 528, 532)
        ] {
            let available = CGRect(origin: .zero, size: size)
            #expect(near(SourceDialogLayout.width(in: available), minimum))
            #expect(near(SourceDialogLayout.preferredContentWidth(in: available), preferred))
            #expect(near(SourceDialogLayout.width(in: available, desiredContentWidth: preferred), max(minimum, preferred)))
        }
        // The large landscape trace first offers449 points for the square body;
        // its later minimum-width pass widens the original clock to480.
        let landscape = CGRect(x: 0, y: 43, width: 960, height: 573)
        #expect(near(SourceDialogLayout.width(in: landscape, configurationSize: CGSize(width: 960, height: 640),
                                              desiredContentWidth: 449), 480))
        let configuration = CGSize(width: 834, height: 1210)
        for height: CGFloat in [100, 600, 1150] {
            let available = CGRect(x: 31, y: 20, width: 796, height: height)
            #expect(near(SourceDialogLayout.width(in: available, configurationSize: configuration), 525))
            #expect(near(SourceDialogLayout.preferredContentWidth(in: available, configurationSize: configuration), 532))
        }
        // The large resource predates the sw600 override; regular phones use320.
        #expect(near(SourceDialogLayout.preferredContentWidth(in: CGRect(x: 0, y: 0, width: 500, height: 800)), 392))
        #expect(near(SourceDialogLayout.preferredContentWidth(in: CGRect(x: 0, y: 0, width: 402, height: 874)), 272))
    }
    @Test func customBodyOwnsItsPaddingAndDoesNotGetTheMessageDivider() {
        let available = CGRect(x: 0, y: 0, width: 402, height: 874)
        for textHeight: CGFloat in [29, 44, 90] {
            let custom = SourceDialogLayout.custom(available: available, titleTextHeight: textHeight, bodyHeight: 100)
            let message = SourceDialogLayout.message(available: available, titleTextHeight: textHeight, textHeight: 100)
            #expect(near(message.title.height - custom.title.height, 16))
            #expect(near(custom.title.height, 18 + max(32, textHeight)))
            #expect(near(custom.body.height, 100) && near(message.body.height, 100))
            #expect(near(custom.footer.height, 76) && near(message.footer.height, 76))
        }
        let custom = SourceDialogLayout.custom(available: available, titleTextHeight: nil, bodyHeight: 40)
        #expect(near(custom.title.height, 0) && near(custom.body.height, 48))
        #expect(near(SourceDialogLayout.custom(available: available, titleTextHeight: nil, bodyHeight: 100).body.height, 100))
    }
    @Test func individualChoiceHeightsKeepTheCompleteListExtent() {
        // Source choice rows have48 minimum but expand for wrapped labels.
        let rows: [CGFloat] = [48, 48, 91, 48, 126, 48, 170]
        let full = SourceDialogLayout.singleChoice(available: CGRect(x: 0, y: 0, width: 400, height: 1000),
            titleTextHeight: 29, rowHeights: rows)
        #expect(near(full.body.height, 579)) // Every row fits; none is cut to the 48 pt minimum.
        #expect(near(full.title.height, 66) && near(full.footer.height, 76))
        let short = SourceDialogLayout.singleChoice(available: CGRect(x: 0, y: 0, width: 400, height: 300),
            titleTextHeight: 29, rowHeights: rows)
        #expect(near(short.body.height, 110) && near(short.footer.height, 76))
        #expect(near(short.body.maxY, short.footer.minY))
    }
    @Test func singleChoiceMatchesOriginalRuntimePanelAndEveryRow() {
        // Independent API 36 hierarchy, default-page/06-home-choice: density 2.625.
        // Compare logical coordinates within 1 dp for Android integer-pixel rounding.
        let density = 2.625
        let available = CGRect(x: 0, y: 132 / density, width: 1080 / density, height: (2337 - 132) / density)
        let layout = SourceDialogLayout.singleChoice(available: available, titleTextHeight: 29, rowHeight: 48, count: 7)
        #expect(abs(layout.panel.minY - 606 / density) < 1)
        #expect(abs(layout.panel.maxY - 1862 / density) < 1)
        #expect(abs(layout.panel.minX - 91 / density) < 1)
        #expect(abs(layout.panel.maxX - 989 / density) < 1)
        for (index, top) in [780, 906, 1032, 1158, 1284, 1410, 1536].enumerated() {
            #expect(abs(layout.panel.minY + layout.body.minY + CGFloat(index) * 48 - CGFloat(top) / density) < 1)
        }
        #expect(abs(layout.panel.minY + layout.footer.minY - 1662 / density) < 1)
    }
    @Test func messageMatchesOriginalErrorTitleBodyAndActionAnchors() {
        // Independent playback-error/08-retry-expanded hierarchy, API 36 at 2.625 density.
        // The measured message height is an input, not a Swift text-rendering baseline.
        let density = 2.625
        let available = CGRect(x: 0, y: 132 / density, width: 1080 / density, height: (2337 - 132) / density)
        let layout = SourceDialogLayout.message(available: available, titleTextHeight: 29, textHeight: 1270 / density)
        for (actual, expected) in [(layout.panel.minX, 91.0), (layout.panel.maxX, 989),
                                   (layout.panel.minY, 412), (layout.panel.maxY, 2056),
                                   (layout.panel.minY + layout.title.maxY, 586),
                                   (layout.panel.minY + layout.body.maxY, 1856)] {
            #expect(abs(actual - expected / density) < 1)
        }
        let button = CGRect(x: layout.panel.maxX - 88,
                            y: layout.panel.minY + layout.footer.minY + (layout.footer.height - 48) / 2,
                            width: 64, height: 48)
        for (actual, expected) in [(button.minX, 758.0), (button.minY, 1893),
                                   (button.maxX, 926), (button.maxY, 2019)] {
            #expect(abs(actual - expected / density) < 1)
        }
    }
    @Test func titlelessMessageKeepsTopPaddingAndLongErrorPinsTitleAndAction() {
        let available = CGRect(x: 0, y: 62, width: 402, height: 778)
        let titleless = SourceDialogLayout.message(available: available, titleTextHeight: nil, textHeight: 40)
        #expect(near(titleless.title.height, 0))
        #expect(near(titleless.body.height, 58)) // Source textSpacerNoTitle:18, not dialogPreferredPadding:24.
        let long = SourceDialogLayout.message(available: available, titleTextHeight: 80, textHeight: 5000)
        #expect(near(long.title.height, 114))
        #expect(near(long.footer.height, 76))
        #expect(long.body.height < 5000)
        #expect(near(long.panel.height, available.height - 48))
    }
    @Test func matchesRecordedPhoneAlertWidthAndCentersInSystemInsets() {
        let density = 2.625
        let available = CGRect(x: 0, y: 132 / density, width: 1080 / density, height: (2337 - 132) / density)
        let layout = SourceDialogLayout(available: available, titleHeight: 52, bodyHeight: 504)
        // Original 02-customize parentPanel spans x=91..989; logical rounding differs <1 dp.
        #expect(abs(layout.panel.minX - 91 / density) < 1)
        #expect(abs(layout.panel.maxX - 989 / density) < 1)
        #expect(abs(layout.panel.midY - (403 + 2065) / 2 / density) < 1)
    }
    @Test func longBodiesScrollInsidePinnedTitleAndActionsAcrossConstrainedWindows() {
        for width in [CGFloat(0), 100, 320, 402, 800, 1366] {
            for height in [CGFloat(0), 80, 320, 874, 1024] {
                for body in [CGFloat(0), 64, 336, 5000] {
                    let available = CGRect(x: 20, y: 30, width: width, height: height)
                    let layout = SourceDialogLayout(available: available, titleHeight: 52, bodyHeight: body)
                    #expect(layout.panel.width >= 0 && layout.panel.height >= 0)
                    #expect(layout.body.height >= 0 && layout.footer.height >= 0)
                    #expect(near(layout.title.maxY, layout.body.minY) && near(layout.body.maxY, layout.footer.minY))
                    #expect(near(layout.footer.maxY, layout.panel.height))
                    #expect(layout.panel.height <= height + 0.5)
                    if height >= 176 { #expect(near(layout.footer.height, 76)) }
                }
            }
        }
    }
}

import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct SourceMessageViewportLayoutTests {
    /// Layout is judged at the precision a person sees: half a point.
    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }
    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
    }
    private func near(_ a: SourceDialogLayout, _ b: SourceDialogLayout) -> Bool {
        near(a.panel, b.panel) && near(a.title, b.title) && near(a.body, b.body) && near(a.footer, b.footer)
    }
    @Test func measuredWidthSurvivesKeyboardOcclusionAndSyntheticOverflowHeight() {
        // Width belongs to the real unoccluded presentation. A short keyboard
        // viewport and a very tall measured body must not reclassify that window.
        for width: CGFloat in [342, 464, 552, 643] {
            for height: CGFloat in [0, 100, 300, 900] {
                let available = CGRect(x: 31, y: 20, width: 834, height: height)
                let message = SourceMessageViewportLayout(available: available, titleTextHeight: 80,
                    bodyHeight: 4000, customBody: true, footerHeight: 76, minimumFooterHeight: 76,
                    minimumBodyHeight: 48, minimumActionHeight: 48, panelWidth: width)
                let choice = SourceMessageViewportLayout.singleChoice(available: available, titleTextHeight: 80,
                    rowHeights: [4000], footerHeight: 76, minimumFooterHeight: 76,
                    minimumBodyHeight: 48, minimumActionHeight: 48, panelWidth: width)
                for layout in [message, choice] {
                    #expect(near(layout.panel.width, width))
                    #expect(near(layout.content.panel.width, width))
                    #expect(near(layout.content.body.width, width))
                    #expect(near(layout.content.footer.width, width))
                    #expect(near(layout.panel.midX, available.midX))
                }
            }
        }
    }
    @Test func choicesPreserveTheirOwnAllocationAndExpandOnlyWhenStarved() {
        for rows: [CGFloat] in [[], [20], [48, 95, 60, 48, 180]] {
            for height: CGFloat in [130, 260, 900] {
                let available = CGRect(x: 19, y: 7, width: 342, height: height)
                let ordinary = SourceDialogLayout.singleChoice(available: available, titleTextHeight: 29,
                    rowHeights: rows, footerHeight: 76, minimumFooterHeight: 76)
                let viewport = SourceMessageViewportLayout.singleChoice(available: available, titleTextHeight: 29,
                    rowHeights: rows, footerHeight: 76, minimumFooterHeight: 76,
                    minimumBodyHeight: 24, minimumActionHeight: 48)
                #expect(near(viewport.panel, ordinary.panel))
                if height == 130 {
                    #expect(viewport.scrollsWholeContent)
                    #expect(near(viewport.content.title.height, 66))
                    #expect(near(viewport.content.body.height, rows.reduce(0, +)))
                    #expect(near(viewport.content.footer.height, 76))
                } else {
                    #expect(!viewport.scrollsWholeContent)
                    #expect(near(viewport.content, ordinary))
                }
            }
        }
    }
    @Test func preservesUsableSourceAllocationIncludingPartiallyExpandedActions() {
        for height: CGFloat in [250, 400, 900] {
            for body: CGFloat in [20, 4000] {
                let available = CGRect(x: 41, y: 63, width: 320, height: height)
                let layout = SourceMessageViewportLayout(available: available, titleTextHeight: 29,
                    bodyHeight: body, customBody: false, footerHeight: 172, minimumFooterHeight: 88,
                    minimumBodyHeight: 20, minimumActionHeight: 48)
                #expect(!layout.scrollsWholeContent)
                #expect(near(layout.content, .message(available: available, titleTextHeight: 29, textHeight: body,
                    footerHeight: 172, minimumFooterHeight: 88)))
                #expect(near(layout.panel, layout.content.panel))
            }
        }
    }

    @Test func starvationExpandsContentWithoutExceedingPhysicalViewport() {
        for title: CGFloat? in [nil, 29, 96] {
            for custom in [false, true] {
                for height: CGFloat in [0, 80, 130] {
                    let available = CGRect(x: 41, y: 63, width: 320, height: height)
                    let layout = SourceMessageViewportLayout(available: available, titleTextHeight: title,
                        bodyHeight: 4000, customBody: custom, footerHeight: 172, minimumFooterHeight: 88,
                        minimumBodyHeight: custom ? 48 : 38, minimumActionHeight: 48)
                    #expect(layout.scrollsWholeContent)
                    #expect(near(layout.panel.height, max(0, height - 48)))
                    #expect(near(layout.panel.midY, available.midY))
                    let expectedBodyHeight: CGFloat = 4000 + (!custom && title == nil ? 18 : 0)
                    #expect(near(layout.content.body.height, expectedBodyHeight))
                    #expect(near(layout.content.footer.height, 172))
                    #expect(near(layout.content.title.maxY, layout.content.body.minY))
                    #expect(near(layout.content.body.maxY, layout.content.footer.minY))
                }
            }
        }
    }

    @Test func thresholdUsesMeasuredTextAndActionsRatherThanDeviceOrWholeBody() {
        // Title66 + footer88 + body26: a20-point line remains readable.
        let available = CGRect(x: 0, y: 0, width: 320, height: 228)
        func make(bodyMinimum: CGFloat, actionMinimum: CGFloat) -> SourceMessageViewportLayout {
            .init(available: available, titleTextHeight: 29, bodyHeight: 4000, customBody: false,
                  footerHeight: 172, minimumFooterHeight: 88,
                  minimumBodyHeight: bodyMinimum, minimumActionHeight: actionMinimum)
        }
        #expect(!make(bodyMinimum: 20, actionMinimum: 48).scrollsWholeContent)
        #expect(make(bodyMinimum: 40, actionMinimum: 48).scrollsWholeContent)
        #expect(make(bodyMinimum: 20, actionMinimum: 96).scrollsWholeContent)
    }
}

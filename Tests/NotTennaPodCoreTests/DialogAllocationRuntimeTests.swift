import Foundation
import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct DialogAllocationRuntimeTests {
    private struct Sample: Decodable {
        let id: String
        let titleHeight, bodyHeight, actionHeight, actionMinimum: CGFloat
        let maximumHeight, panelHeight, actualTitle, actualBody, actualActions: CGFloat
        let sourceOverflow: Bool
    }

    @Test func matchesMeasuredAndroidAllocationWhereChildrenFitThePanel() throws {
        let url = try #require(Bundle.module.url(forResource: "dialog-allocation-runtime", withExtension: "json", subdirectory: "Fixtures"))
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
        #expect(samples.count == 240)
        #expect(samples.filter { $0.sourceOverflow }.count == 48)
        #expect(samples.filter { !$0.sourceOverflow }.count == 192)
        for sample in samples where !sample.sourceOverflow {
            // Use captured pixels as abstract layout units, with the measured
            // content sizes as inputs. This tests allocation, not typography.
            let layout = SourceDialogLayout(available: CGRect(x: 0, y: 0, width: 400,
                height: sample.maximumHeight + 48), titleHeight: sample.titleHeight,
                bodyHeight: sample.bodyHeight, footerHeight: sample.actionHeight,
                minimumFooterHeight: sample.actionMinimum)
            // Space is shared between title, scrolling body and buttons as on
            // Android (within one layout unit; sub-unit rounding is invisible).
            #expect(abs(layout.panel.height - sample.panelHeight) <= 1, "\(sample.id): panel")
            #expect(abs(layout.title.height - sample.actualTitle) <= 1, "\(sample.id): title")
            #expect(abs(layout.body.height - sample.actualBody) <= 1, "\(sample.id): body")
            #expect(abs(layout.footer.height - sample.actualActions) <= 1, "\(sample.id): actions")
        }
    }
}

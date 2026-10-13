import Testing
@testable import NotTennaPod

@MainActor struct DownloadLogSheetMotionTests {
    @Test func nestedDirectionExpandsAndCollapsesBeforeHiding() {
        var sheet = DownloadLogSheetMotion()
        sheet.resize(height: 900, visible: 700)
        #expect(sheet.offset == 200)
        sheet.begin(); #expect(sheet.move(by: -80) == -80)
        #expect(sheet.finish(velocity: 0, nested: true) == .expanded)
        #expect(sheet.offset == 0)
        sheet.begin(); sheet.move(by: 80)
        #expect(sheet.finish(velocity: 2000, nested: true) == .collapsed)
        #expect(sheet.offset == 200) // A fling above the collapsed stop cannot hide it.
        sheet.begin(); sheet.move(by: 360)
        #expect(sheet.finish(velocity: 0, nested: true) == .hidden)
    }
    @Test func upwardTravelIsConsumedOnlyUntilExpandedAndCancellationSettlesAtPosition() {
        var sheet = DownloadLogSheetMotion()
        sheet.resize(height: 900, visible: 700)
        sheet.begin()
        #expect(sheet.move(by: -250) == -200) // Remaining50 belongs to the list.
        #expect(sheet.move(by: -50) == 0)
        #expect(sheet.finish(velocity: -1000, nested: true, cancelled: true) == .expanded)
        #expect(sheet.offset == 0)
        sheet.begin(); sheet.move(by: -80)
        #expect(sheet.finish(velocity: -50, nested: false) == .expanded)
        sheet.begin(); sheet.move(by: 60)
        #expect(sheet.finish(velocity: 50, nested: false) == .collapsed)
    }
    @Test func resizingPreservesStopAndRelativeDragProgressIncludingShortContent() {
        var sheet = DownloadLogSheetMotion()
        sheet.resize(height: 900, visible: 700); sheet.begin(); sheet.move(by: -100)
        sheet.resize(height: 600, visible: 300)
        #expect(sheet.offset == 150)
        #expect(sheet.finish(velocity: 0, nested: true) == .expanded)
        sheet.resize(height: 320, visible: 320)
        #expect(sheet.offset == 0 && sheet.stop == .expanded)
        sheet.begin()
        sheet.resize(height: 900, visible: 700)
        #expect(sheet.offset == 0)
        sheet.move(by: 300)
        sheet.resize(height: 600, visible: 300)
        #expect(abs(sheet.offset - (300 + 300.0 / 7)) < 0.001)
        #expect(sheet.finish(velocity: 0, nested: true, cancelled: true) == .collapsed)
    }
}

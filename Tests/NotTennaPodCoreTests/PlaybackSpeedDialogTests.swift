import Foundation
import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct PlaybackSpeedDialogTests {
    @Test func addUsesSliderValueRatherThanRoundedLabelOrRawCurrentSpeed() throws {
        var state = PlaybackSpeedDialogState(speed: 1.234, presets: [1, 1.25, 1.5])
        #expect(state.displayedSpeed == 1.234 && state.progress == 15 && state.currentSliderSpeed == 1.25)
        #expect(try !state.addCurrent())
        #expect(state.step(1) == 1.3)
        #expect(try state.addCurrent())
        #expect(state.selection.presets == [1, 1.25, 1.3, 1.5])
        state.remove(1.3)
        #expect(state.displayedSpeed == 1.3 && state.selection.presets == [1, 1.25, 1.5])
        state.receive(speed: 1.234)
        #expect(state.displayedSpeed == 1.234)
    }
    @Test func everySliderStepAndRepeatedBoundaryButtonsMatchSource() {
        var state = PlaybackSpeedDialogState(speed: 1, presets: [])
        for value in -2...72 {
            #expect(state.move(to: value) == Float(min(70, max(0, value)) + 10) / 20)
        }
        #expect(state.step(1) == 4 && state.step(1) == 4)
        state.move(to: 0)
        #expect(state.step(-1) == 0.5 && state.step(-1) == 0.5)
        #expect(PlaybackSpeedDialogState.text(1.25, locale: Locale(identifier: "de_DE")) == "1,25")
    }
    @Test func originalThreeAndFourPresetGeometryRetainsBottomCheckboxAnchor() {
        let density = 2.625
        let size = CGSize(width: 1080 / density, height: 2400 / density)
        let three = PlaybackSpeedDialogLayout(size: size, topInset: 132 / density, bottomInset: 24, count: 3, scale: density)
        let four = PlaybackSpeedDialogLayout(size: size, topInset: 132 / density, bottomInset: 24, count: 4, scale: density)
        for layout in [three, four] {
            // Bottom sheet on screen: -/slider/+ row, then the preset grid, then the skip-silence checkbox.
            #expect(abs(layout.sheet.maxY - size.height) < 0.5 && layout.sheet.minY >= 0)
            #expect(layout.decrease.maxX <= layout.slider.minX + 0.5 && layout.slider.maxX <= layout.increase.minX + 0.5)
            #expect(layout.decrease.minY < layout.presets[0].minY && layout.presets.last!.maxY <= layout.silence.minY + 0.5)
            #expect(layout.silence.maxY <= layout.sheet.height + 0.5)
            #expect(layout.presets.allSatisfy { $0.minX >= 0 && $0.maxX <= size.width })
        }
        // Three presets share one row; a fourth wraps to a new row and the sheet grows upwards
        // while the checkbox stays anchored at the same place on screen.
        #expect(three.presets.allSatisfy { abs($0.minY - three.presets[0].minY) < 0.5 })
        #expect(four.presets[3].minY > four.presets[0].minY)
        #expect(four.sheet.minY < three.sheet.minY)
        #expect(abs(three.sheet.minY + three.silence.minY - four.sheet.minY - four.silence.minY) < 0.5)
    }
    @Test func fixedGridOrderMirrorsWithoutLosingPresetsAndLongContentRemainsScrollable() {
        for count in [0, 1, 3, 4, 30, 100] {
            for width: CGFloat in [320, 402, 768, 1366] {
                let size = CGSize(width: width, height: 400)
                let left = PlaybackSpeedDialogLayout(size: size, topInset: 50, bottomInset: 34, count: count)
                let right = PlaybackSpeedDialogLayout(size: size, topInset: 50, bottomInset: 34, count: count, rightToLeft: true)
                #expect(left.sheet.height <= 350 && left.contentHeight >= left.sheet.height)
                #expect(left.presets.count == count && right.presets.count == count)
                for index in 0..<count {
                    #expect(abs(left.presets[index].minX + right.presets[index].maxX - width) < 0.001)
                    #expect(left.presets[index].minY == right.presets[index].minY)
                }
            }
        }
    }
}

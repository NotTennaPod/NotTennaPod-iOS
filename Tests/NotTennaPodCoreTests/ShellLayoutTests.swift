import Foundation
import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct ShellLayoutTests {
    /// Layout is judged at the precision a person sees: half a point.
    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }
    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
    }
    @Test func queueInformationMatchesRecordedAndroidOverlapAndKeepsPlayerAnchored() {
        // Original default-page/15: info_bar [0,268][1080,311], density 2.625.
        let density = 2.625
        let size = CGSize(width: 1080 / density, height: 2400 / density)
        let ordinary = ShellLayout(size: size, topInset: 132 / density, bottomInset: 24, playerVisible: true, bottomNavigation: false)
        let queue = ShellLayout(size: size, topInset: 132 / density, bottomInset: 24, playerVisible: true, bottomNavigation: false, informationHeight: 16.4)
        #expect(abs(queue.information.minY - 268 / density) < 1)
        #expect(abs(queue.information.maxY - 311 / density) < 1)
        #expect(abs(queue.content.minY - (queue.information.maxY + 8)) < 1)
        #expect(near(queue.miniPlayer, ordinary.miniPlayer) && near(queue.navigation, ordinary.navigation))
        for height in [0.0, 40, 80, 160, 874] {
            let small = ShellLayout(size: CGSize(width: 200, height: height), topInset: 30, bottomInset: 20, playerVisible: true, informationHeight: 100)
            #expect(small.information.height >= 0 && small.information.maxY <= small.miniPlayer.minY)
            #expect(small.content.height >= 0 && small.content.maxY <= small.miniPlayer.minY)
        }
    }
    @Test func matchesRecordedAndroidHomeRegions() throws {
        let density = 2.625
        let layout = ShellLayout(size: CGSize(width: 1080 / density, height: 2400 / density), topInset: 74 / density, bottomInset: 24)
        // Within 1 pt of the recorded Android regions.
        #expect(abs(layout.toolbar.minY - 74 / density) < 1)
        #expect(abs(layout.toolbar.maxY - 242 / density) < 1)
        for index in 0..<5 {
            let frame = try #require(layout.navigationItem(at: index, count: 5))
            #expect(abs(frame.minX - Double(index * 216) / density) < 1)
            #expect(abs(frame.minY - 2169 / density) < 1)
            #expect(abs(frame.maxY - 2337 / density) < 1)
        }
    }

    /// Android's `bottom_padding` strip: the bar and, without bottom navigation, the mini player end above the
    /// device's bottom inset, capped at Android's 24 dp gesture strip (the iPhone's 34 pt keeps 24).
    @Test func barsEndAboveAndroidsBottomStrip() {
        for (inset, strip) in [(0.0, 0.0), (20, 20), (24, 24), (34, 24)] {
            let size = CGSize(width: 402, height: 874)
            let navigation = ShellLayout(size: size, topInset: 62, bottomInset: inset, playerVisible: true)
            #expect(near(navigation.bottomInset.height, strip) && near(navigation.bottomInset.maxY, 874))
            #expect(near(navigation.navigation.maxY, 874 - strip))
            let drawer = ShellLayout(size: size, topInset: 62, bottomInset: inset, playerVisible: true, bottomNavigation: false)
            #expect(near(drawer.miniPlayer.maxY, 874 - strip))
        }
    }

    @Test func resizingAndInsetsNeverOverlapOrLeaveNavigationGaps() throws {
        for width in [0.0, 200, 320, 393, 411.428571, 768, 1024, 1366] {
            for height in [0.0, 80, 400, 852, 1024] {
                for top in [0.0, 32, 62] {
                    for bottom in [0.0, 24, 34] {
                        let layout = ShellLayout(size: CGSize(width: width, height: height), topInset: top, bottomInset: bottom)
                        #expect(layout.toolbar.maxY <= layout.content.minY + 0.01)
                        #expect(layout.content.maxY <= layout.navigation.minY + 0.01)
                        #expect(layout.navigation.maxY <= layout.bottomInset.minY + 0.01)
                        #expect(abs(layout.bottomInset.maxY - CGFloat(height)) < 0.5)
                        for count in 1...5 {
                            let frames = try (0..<count).map { try #require(layout.navigationItem(at: $0, count: count)) }
                            #expect(abs(frames.last!.maxX - width) < 0.5)
                            for index in 1..<count { #expect(abs(frames[index - 1].maxX - frames[index].minX) < 0.5) }
                        }
                    }
                }
            }
        }
    }

    @Test func mirrorsNavigationWithoutChangingLogicalOrder() throws {
        let layout = ShellLayout(size: CGSize(width: 400, height: 800), topInset: 40, bottomInset: 20)
        #expect(abs((layout.navigationItem(at: 0, count: 5, rightToLeft: true)?.minX ?? -100) - 320) < 0.5)
        #expect(abs((layout.navigationItem(at: 4, count: 5, rightToLeft: true)?.minX ?? -100) - 0) < 0.5)
        #expect(layout.navigationItem(at: -1, count: 5) == nil)
        #expect(layout.navigationItem(at: 5, count: 5) == nil)
        #expect(layout.navigationItem(at: 0, count: 0) == nil)
    }
}

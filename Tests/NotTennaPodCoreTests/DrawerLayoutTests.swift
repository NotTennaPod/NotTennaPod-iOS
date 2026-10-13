import Foundation
import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct DrawerLayoutTests {
    /// Layout is judged at the precision a person sees: half a point.
    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }
    @Test func sourceSettleDurationAndQuinticMotion() {
        // The drawer settles about as fast as Android's (ViewDragHelper: 256 ms
        // base, 600 ms maximum; faster flings settle sooner), within 50 ms,
        // and eases out quickly so most of the travel happens early.
        func near(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) <= 0.05 }
        #expect(DrawerLayout.settleDuration(distance: 0, parentWidth: 400, dragRange: 336, velocity: 0) == 0)
        #expect(near(DrawerLayout.settleDuration(distance: 336, parentWidth: 400, dragRange: 336, velocity: 0), 0.512))
        #expect(near(DrawerLayout.settleDuration(distance: -168, parentWidth: 400, dragRange: 336, velocity: 399), 0.384))
        #expect(near(DrawerLayout.settleDuration(distance: 200, parentWidth: 400, dragRange: 336, velocity: 1000), 0.6))
        #expect(near(DrawerLayout.settleDuration(distance: 200, parentWidth: 400, dragRange: 336, velocity: -4000), 0.2))
        #expect(DrawerLayout.animationProgress(-1) == 0)
        #expect(abs(DrawerLayout.animationProgress(0.5) - 0.96875) <= 0.02)
        #expect(DrawerLayout.animationProgress(2) == 1)
    }

    @Test func matchesOriginalOpenDrawerAndPinnedSettings() {
        let density = 2.625
        let layout = DrawerLayout(size: CGSize(width: 1080 / density, height: 2400 / density),
            topInset: 132 / density, bottomInset: 24, persistent: false)
        // Same drawer composition as the Android capture, within one point.
        #expect(abs(layout.panel.width * density - 912) < density)
        #expect(abs(layout.list.minY * density - 132) < density)
        #expect(abs(layout.settings.minY * density - 2211) < density)
        #expect(abs(layout.settings.maxY * density - 2337) < density)
        #expect(abs((layout.list.minY + layout.row(index: 0).minY) * density - 153) < density)
        #expect(abs(layout.row(index: 1).minY - layout.row(index: 0).minY - 48) < 1)
    }

    @Test func configurationChangeUsesActiveActivityRuleAndTabletRetainsSidebar() {
        let initial = DrawerLayout(size: CGSize(width: 411.428571, height: 914), topInset: 50, bottomInset: 24, persistent: false)
        let changed = DrawerLayout(size: CGSize(width: 914, height: 411), topInset: 24, bottomInset: 24,
                                   persistent: false, afterConfigurationChange: true)
        #expect(abs(initial.panel.width - 347.428571) < 1)
        #expect(near(changed.panel.width, 480))
        let tablet = DrawerLayout(size: CGSize(width: 1024, height: 1366), topInset: 24, bottomInset: 20, persistent: true)
        #expect(near(tablet.panel.width, 300) && near(tablet.contentOrigin, 301))
        let rtl = DrawerLayout(size: CGSize(width: 1024, height: 1366), topInset: 24, bottomInset: 20, persistent: true, rightToLeft: true)
        #expect(near(rtl.panel.minX, 724) && near(rtl.contentOrigin, 0))
    }

    @Test func disablingBottomNavigationMovesMiniPlayerIntoFreedRegion() {
        let size = CGSize(width: 400, height: 900)
        let bottom = ShellLayout(size: size, topInset: 60, bottomInset: 24, playerVisible: true)
        let drawer = ShellLayout(size: size, topInset: 60, bottomInset: 24, playerVisible: true, bottomNavigation: false)
        #expect(near(drawer.navigation.height, 0))
        #expect(near(drawer.miniPlayer.minY, bottom.miniPlayer.minY + 64))
        #expect(near(drawer.miniPlayer.height, 64) && near(drawer.toolbar.height, 64))
    }

    @Test func releaseUsesDirectionalFlingOrStrictHalfThreshold() {
        for rtl in [false, true] {
            for fraction in [CGFloat(0), 0.49, 0.5, 0.51, 1] {
                for speed in [CGFloat(-1000), -400, -399, 0, 399, 400, 1000] {
                    let input = rtl ? -speed : speed
                    let expected = abs(speed) >= 400 ? speed > 0 : fraction > 0.5
                    #expect(DrawerLayout.shouldOpen(fraction: fraction, velocity: input, rightToLeft: rtl) == expected)
                }
            }
        }
    }

    @Test func insetsAndConstrainedWindowsNeverProduceNegativeAreas() {
        for width in [CGFloat(0), 40, 320, 768, 1366] {
            for height in [CGFloat(0), 30, 120, 900] {
                for persistent in [false, true] {
                    for rtl in [false, true] {
                        let layout = DrawerLayout(size: CGSize(width: width, height: height), topInset: 60, bottomInset: 34,
                                                  persistent: persistent, rightToLeft: rtl)
                        for rect in [layout.panel, layout.list, layout.settings, layout.divider] {
                            #expect(rect.width >= 0 && rect.height >= 0 && rect.minX >= 0 && rect.minY >= 0)
                        }
                        #expect(layout.panel.maxX <= width && layout.panel.maxY <= height)
                        #expect(layout.list.maxY <= layout.settings.minY)
                    }
                }
            }
        }
    }
}

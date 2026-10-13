import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct ToolbarLayoutTests {
    /// Frames are compared within a hair / 1 pt; exact float equality is not a user-visible property.
    private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.5) -> Bool { abs(a - b) <= tolerance }
    private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 1) -> Bool {
        near(a.minX, b.minX, tolerance) && near(a.minY, b.minY, tolerance) && near(a.maxX, b.maxX, tolerance) && near(a.maxY, b.maxY, tolerance)
    }
    @Test func downloadsSearchPrecedesHistoryAndOverflowInBothDirections() {
        for rtl in [false, true] {
            let layout = ToolbarLayout(size: CGSize(width: 320, height: 64), hasNavigation: true,
                hasOverflow: true, rightToLeft: rtl, hasPrimaryAction: true, hasSecondaryAction: true)
            #expect(near(layout.secondaryAction.width, 48, 1) && near(layout.primaryAction.width, 48, 1))
            if rtl {
                #expect(near(layout.overflow.maxX, layout.primaryAction.minX))
                #expect(near(layout.primaryAction.maxX, layout.secondaryAction.minX))
                #expect(near(layout.secondaryAction.maxX, layout.title.minX))
            } else {
                #expect(near(layout.title.maxX, layout.secondaryAction.minX))
                #expect(near(layout.secondaryAction.maxX, layout.primaryAction.minX))
                #expect(near(layout.primaryAction.maxX, layout.overflow.minX))
            }
        }
    }
    @Test func websiteStaysImmediatelyBeforeOverflowAndMirrorsWithIt() {
        for width: CGFloat in [320, 393, 768, 1024] {
            for density: CGFloat in [1, 2, 2.625, 3] {
                for rtl in [false, true] {
                    let layout = ToolbarLayout(size: CGSize(width: width, height: 64), hasNavigation: true,
                        hasOverflow: true, density: density, rightToLeft: rtl, hasPrimaryAction: true)
                    #expect(near(layout.primaryAction.width, 48, 1))
                    #expect(near(layout.primaryAction.height, layout.overflow.height))
                    #expect(near(layout.primaryAction.minY, layout.overflow.minY))
                    if rtl {
                        #expect(near(layout.primaryAction.minX, layout.overflow.maxX))
                        #expect(near(layout.title.minX, layout.primaryAction.maxX))
                    } else {
                        #expect(near(layout.primaryAction.maxX, layout.overflow.minX))
                        #expect(near(layout.title.maxX, layout.primaryAction.minX))
                    }
                }
            }
        }
    }

    @Test func controlsMatchOriginalEpisodeToolbarPixels() {
        // first-journey/08-episode/hierarchy.xml: toolbar [0,74][1080,242].
        // Back [0,84][147,231]; overflow [975,94][1080,220], density 2.625.
        let density: CGFloat = 2.625
        let layout = ToolbarLayout(size: CGSize(width: 1080 / density, height: 168 / density),
            hasNavigation: true, hasOverflow: true, density: density)
        #expect(near(layout.navigation, CGRect(x: 0, y: 10 / density, width: 147 / density, height: 147 / density)))
        #expect(near(layout.overflow, CGRect(x: 975 / density, y: 20 / density, width: 105 / density, height: 126 / density)))
        #expect(near(layout.title.minX, 72, 1) && near(layout.title.maxX, layout.overflow.minX))
    }

    @Test func titleKeepsSourceLeadingInsetAndUsesAvailableSpace() {
        let home = ToolbarLayout(size: CGSize(width: 400, height: 64), hasNavigation: false, hasOverflow: false)
        #expect(near(home.title, CGRect(x: 16, y: 0, width: 368, height: 64)))
        let child = ToolbarLayout(size: CGSize(width: 400, height: 64), hasNavigation: true, hasOverflow: false)
        #expect(near(child.title, CGRect(x: 72, y: 0, width: 312, height: 64)))
    }

    @Test func mirroringAndConstrainedWindowsPreserveControlAnchors() {
        for width: CGFloat in [0, 40, 80, 200, 393, 768, 1024] {
            for height: CGFloat in [0, 24, 56, 64] {
                for density: CGFloat in [1, 2, 2.625, 3] {
                    for navigation in [false, true] {
                        for overflow in [false, true] {
                            let normal = ToolbarLayout(size: CGSize(width: width, height: height), hasNavigation: navigation, hasOverflow: overflow, density: density)
                            let mirrored = ToolbarLayout(size: CGSize(width: width, height: height), hasNavigation: navigation, hasOverflow: overflow, density: density, rightToLeft: true)
                            let actualWidth = (width * density).rounded() / density
                            for (a, b) in zip([normal.navigation, normal.title, normal.overflow], [mirrored.navigation, mirrored.title, mirrored.overflow]) {
                                #expect(a.width >= 0 && a.height >= 0 && a.minX >= 0 && a.maxX <= actualWidth + 0.001)
                                #expect(a.minY >= 0 && a.maxY <= height + 0.001)
                                #expect(near(a.minX + b.maxX, actualWidth))
                                #expect(near(a.width, b.width) && near(a.height, b.height) && near(a.minY, b.minY))
                            }
                            #expect(normal.navigation.maxX <= normal.overflow.minX)
                        }
                    }
                }
            }
        }
    }
}

import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct PlayerLayoutTests {
    /// Layout is judged at the precision a person sees: half a point.
    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }
    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
    }
    @Test func miniPlayerMatchesRecordedAndroidBounds() {
        let density = 2.625
        let width = 1080 / density
        let layout = MiniPlayerLayout(width: width, scale: density)
        // Android composition: square cover at the leading edge, text beside it, Play at the
        // trailing edge, and a full-width progress bar under the row (60 dp row, 157 px here).
        #expect(abs(layout.cover.minX) < 0.5 && abs(layout.cover.width - layout.cover.height) < 0.5)
        #expect(abs(layout.cover.height - 157 / density) < 2)
        #expect(layout.cover.maxX <= layout.text.minX && layout.text.maxX <= layout.play.minX + 0.5)
        #expect(abs(layout.play.maxX - width) < 0.5)
        #expect(abs(layout.progress.minX) < 0.5 && abs(layout.progress.width - width) < 0.5)
        #expect(layout.progress.minY >= layout.cover.maxY - 0.5 && layout.progress.minY >= layout.play.maxY - 0.5)
        let shell = ShellLayout(size: CGSize(width: width, height: 2400 / density),
                                topInset: 74 / density, bottomInset: 24, playerVisible: true)
        // The mini player sits directly above the bottom navigation, below the content.
        #expect(abs(shell.miniPlayer.maxY - shell.navigation.minY) < 0.5)
        #expect(near(shell.content.maxY, shell.miniPlayer.minY))
    }

    @Test func miniPlayerMirrorsAndResizesWithoutStealingPlayHitArea() {
        for width in [0.0, 30, 100, 320, 402, 768, 1024] as [CGFloat] {
            for height in [0.0, 3, 64] as [CGFloat] {
                for ratio in [0.5, 1, 2, 4] as [CGFloat] {
                    let normal = MiniPlayerLayout(width: width, height: height, artworkAspectRatio: ratio)
                    let mirrored = MiniPlayerLayout(width: width, height: height, artworkAspectRatio: ratio, rightToLeft: true)
                    #expect(near(normal.open.maxX, normal.play.minX))
                    #expect(near(normal.play.maxX, width))
                    #expect(normal.cover.width <= 96)
                    #expect(normal.cover.maxX <= normal.text.minX + 0.5)
                    #expect(normal.text.maxX <= normal.play.minX + 0.5)
                    #expect(near(normal.progress.maxY, height))
                    for (left, right) in [(normal.cover, mirrored.cover), (normal.text, mirrored.text), (normal.play, mirrored.play)] {
                        #expect(near(right.minX, width - left.maxX))
                        #expect(near(right.width, left.width) && near(right.height, left.height))
                    }
                }
            }
        }
    }

    @Test func sheetFadeMatchesAndroidThresholds() {
        for (offset, mini, toolbar) in [(-1.0, 1.0, 0.0), (0, 1, 0), (0.2, 1, 0), (0.3, 0.5, 0),
                                        (0.4, 0, 0), (0.6, 0, 0), (0.7, 0, 0.5), (0.8, 0, 1), (1, 0, 1), (2, 0, 1)] {
            let transition = PlayerSheetTransition(expansion: offset)
            #expect(abs(transition.miniPlayerAlpha - mini) <= 0.02)
            #expect(abs(transition.toolbarAlpha - toolbar) <= 0.02)
        }
    }

    @Test func upwardFlingExpandsWithoutRequiringHalfHeightTravel() {
        for expansion in [0.0, 0.05, 0.49, 0.5, 0.51, 0.95, 1] {
            #expect(PlayerSheetTransition.expandsAfterRelease(expansion: expansion, velocity: CGSize(width: 0, height: -100)))
            #expect(!PlayerSheetTransition.expandsAfterRelease(expansion: expansion, velocity: CGSize(width: 0, height: 100)))
            #expect(PlayerSheetTransition.expandsAfterRelease(expansion: expansion, velocity: .zero) == (expansion > 0.5))
            #expect(PlayerSheetTransition.expandsAfterRelease(expansion: expansion, velocity: CGSize(width: 200, height: 100)) == (expansion > 0.5))
        }
    }

    @Test func playerKeepsControlsAnchoredAndCoverSquareAsTextWraps() {
        for width in [320.0, 402, 768, 1024] as [CGFloat] {
            for height in [600.0, 810, 1024] as [CGFloat] {
                for textHeight in [24.0, 48] as [CGFloat] {
                    let layout = PlayerLayout(size: CGSize(width: width, height: height), topInset: 62,
                                              podcastHeight: textHeight, titleHeight: textHeight, timeHeight: 18)
                    #expect(near(layout.play.midX, width / 2))
                    #expect(near(layout.play.maxY, height - 24))
                    #expect(near(layout.play.minX - layout.rewind.maxX, 12))
                    #expect(near(layout.forward.minX - layout.play.maxX, 12))
                    #expect(near(layout.artwork.width, layout.artwork.height))
                    if width <= height {
                        #expect(near(layout.artwork.midX, width / 2))
                        #expect(layout.artwork.maxY <= layout.podcast.minY + 0.5)
                    } else {
                        #expect(layout.artwork.maxX <= layout.podcast.minX + 0.5)
                        #expect(near(layout.artwork.midY, layout.pager.height / 2))
                    }
                    #expect(near(layout.podcast.maxY, layout.title.minY))
                    #expect(layout.title.maxY < layout.shownotes.minY)
                    #expect(near(layout.pager.maxY + 12, layout.seek.minY))
                    #expect(near(layout.toolbar.maxY, layout.pager.minY))
                }
            }
        }
    }

    @Test func chapterGroupsShareCoverDetailsRowAndRetainNoChapterAnchors() throws {
        let size = CGSize(width: 402, height: 810)
        let plain = PlayerLayout(size: size, topInset: 62, podcastHeight: 24, titleHeight: 48, timeHeight: 18)
        let chapters = PlayerLayout(size: size, topInset: 62, podcastHeight: 24, titleHeight: 48, timeHeight: 18, hasChapters: true)
        let control = try #require(chapters.chapterControl)
        #expect(plain.chapterControl == nil)
        // Without chapters the Show notes button is centred under the title; with chapters it
        // shares that row with the equally wide Chapters button, the pair centred together.
        #expect(abs(plain.shownotes.midX - size.width / 2) < 0.5 && plain.shownotes.minY > plain.title.maxY)
        #expect(abs(chapters.shownotes.minY - control.minY) < 0.5 && chapters.shownotes.maxX <= control.minX)
        #expect(abs(chapters.shownotes.width - control.width) < 0.5)
        #expect(abs((chapters.shownotes.minX + control.maxX) / 2 - size.width / 2) < 0.5)
        #expect(control.minY > chapters.title.maxY && abs(control.minY - plain.shownotes.minY) < 0.5)
        #expect(near(chapters.podcast.maxY, chapters.title.minY))
        #expect(near(chapters.artwork, plain.artwork) && near(chapters.title, plain.title))
        #expect(near(chapters.seek, plain.seek) && near(chapters.play, plain.play) && near(chapters.toolbar, plain.toolbar))
    }

    @Test func landscapeCentersArtworkAndTextGroupInSeparateEqualColumns() throws {
        let layout = PlayerLayout(size: CGSize(width: 800, height: 500), topInset: 24,
                                  podcastHeight: 24, titleHeight: 48, timeHeight: 18, hasChapters: true)
        let control = try #require(layout.chapterControl)
        // Square artwork centred in the left half; podcast, title and the button row in the right half.
        #expect(abs(layout.artwork.width - layout.artwork.height) < 0.5)
        #expect(layout.artwork.minX >= 0 && layout.artwork.maxX <= 400 && abs(layout.artwork.midX - 200) < 10)
        #expect(abs(layout.artwork.midY - layout.pager.height / 2) < 0.5)
        for frame in [layout.podcast, layout.title, layout.shownotes, control] {
            #expect(frame.minX >= 400 && frame.maxX <= 800)
        }
        #expect(layout.podcast.maxY <= layout.title.minY + 0.5 && layout.title.maxY < layout.shownotes.minY)
        #expect(abs(layout.shownotes.minY - control.minY) < 0.5 && layout.shownotes.maxX <= control.minX)
        #expect(abs((layout.shownotes.minX + control.maxX) / 2 - 600) < 10)
        #expect(abs((layout.podcast.minY + control.maxY) / 2 - layout.pager.height / 2) < 0.5)
    }

    @Test func chapterGroupsMirrorWithinCurrentColumnsAndShrinkForNarrowSpace() throws {
        for size in [CGSize(width: 320, height: 810), CGSize(width: 402, height: 810),
                     CGSize(width: 600, height: 400), CGSize(width: 1024, height: 768)] {
            let normal = PlayerLayout(size: size, topInset: 24, podcastHeight: 24, titleHeight: 48,
                                      timeHeight: 18, hasChapters: true)
            let rtl = PlayerLayout(size: size, topInset: 24, podcastHeight: 24, titleHeight: 48,
                                   timeHeight: 18, hasChapters: true, rightToLeft: true)
            let normalChapter = try #require(normal.chapterControl), rtlChapter = try #require(rtl.chapterControl)
            for (left, right) in [(normal.artwork, rtl.artwork), (normal.podcast, rtl.podcast),
                                  (normal.title, rtl.title), (normal.shownotes, rtl.shownotes),
                                  (normalChapter, rtlChapter)] {
                #expect(near(right.minX, size.width - left.maxX))
                #expect(near(right.width, left.width) && near(right.height, left.height) && near(right.minY, left.minY))
            }
            #expect(near(normalChapter.minX - normal.shownotes.maxX, 16))
            #expect(near(rtl.shownotes.minX - rtlChapter.maxX, 16))
            #expect(near(normalChapter.width, normal.shownotes.width) && normalChapter.width <= 150.5)
            #expect(normal.shownotes.minX >= normal.title.minX + 15.5)
            #expect(normalChapter.maxX <= normal.title.maxX - 15.5)
            #expect(near(rtl.seek, normal.seek) && near(rtl.play, normal.play))
        }
    }

    @Test func chapterCoverReflowsWithAvailableBoundsWithoutChangingTransportAnchors() throws {
        for size in [CGSize(width: 402, height: 810), CGSize(width: 810, height: 402),
                     CGSize(width: 600, height: 810), CGSize(width: 1000, height: 810)] {
            let plain = PlayerLayout(size: size, topInset: 24, podcastHeight: 24, titleHeight: 24, timeHeight: 18)
            let chapters = PlayerLayout(size: size, topInset: 24, podcastHeight: 24, titleHeight: 24,
                                        timeHeight: 18, hasChapters: true)
            let control = try #require(chapters.chapterControl)
            #expect(near(control.minY, chapters.shownotes.minY) && control.maxY <= chapters.pager.height - 7.5)
            #expect(near(chapters.play, plain.play) && near(chapters.seek, plain.seek) && near(chapters.pager, plain.pager))
            #expect(near(chapters.artwork.width, chapters.artwork.height))
            if size.width > size.height {
                #expect(chapters.artwork.maxX <= chapters.podcast.minX + 0.5)
            } else {
                #expect(chapters.artwork.maxY <= chapters.podcast.minY + 0.5)
                #expect(near(control.maxY, chapters.pager.height - 8))
            }
        }
    }

    @Test func hidingPlayerRestoresContentWithoutMovingNavigation() {
        for height in [0.0, 80, 200, 800] as [CGFloat] {
            let size = CGSize(width: 402, height: height)
            let hidden = ShellLayout(size: size, topInset: 62, bottomInset: 34)
            let visible = ShellLayout(size: size, topInset: 62, bottomInset: 34, playerVisible: true)
            #expect(near(hidden.navigation, visible.navigation))
            #expect(near(hidden.content.maxY, visible.miniPlayer.maxY))
            #expect(near(visible.content.maxY, visible.miniPlayer.minY))
            #expect(visible.miniPlayer.height >= 0 && visible.miniPlayer.height <= 64)
            #expect(visible.toolbar.maxY <= visible.miniPlayer.minY)
        }
    }
}

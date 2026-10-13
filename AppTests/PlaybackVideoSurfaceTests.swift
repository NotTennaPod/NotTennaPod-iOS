import UIKit
import AVFoundation
import Testing
@testable import NotTennaPod

/// Expectations come from VideoPlayerControlsView and video_player_controls.xml,
/// plus the native requirement to retain the same session during window changes.
@MainActor @Suite(.serialized) struct PlaybackVideoSurfaceTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id { return view as? T }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }

    @Test func sourceTimeSeekRemainsIndependentOfSpeedDisplayAndAccessibility() throws {
        let view = PlaybackVideoView(frame: CGRect(x: 0, y: 0, width: 420, height: 820))
        view.update(position: 30_000, duration: 120_000, playing: false, buffering: false,
                    seekable: true, speed: 2, remaining: true, respectsSpeed: true)
        view.setControlsVisible(true)
        defer { view.cancelAutoHide() }
        let position: UILabel = try #require(find("videoPosition", in: view))
        let duration: UIButton = try #require(find("videoDuration", in: view))
        let seek: PlayerSeekBar = try #require(find("videoSeek", in: view))
        #expect(position.text == "00:00:15")
        #expect(duration.currentTitle == "-00:00:45")
        #expect(seek.value == 125)
        #expect(seek.accessibilityLabel == "Go to this position")
        #expect(seek.accessibilityTraits.contains(.adjustable))
        #expect(seek.accessibilityValue == "25%")
        var sought: [Int64] = []
        view.seekTo = { sought.append($0) }
        seek.accessibilityIncrement()
        #expect(sought == [36_000])
        seek.accessibilityDecrement()
        #expect(sought == [36_000, 30_000])
        view.update(position: 30_000, duration: 0, playing: true, buffering: true,
                    seekable: false, speed: 2, remaining: false, respectsSpeed: false)
        #expect(!seek.isEnabled)
        seek.accessibilityIncrement()
        #expect(sought.count == 2)
        #expect(view.playButton.accessibilityLabel == "Pause")
    }

    @Test func sourceDoubleTapHalvesAndButtonsDeliverOnlyTheirTransportAction() {
        let view = PlaybackVideoView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        var commands: [String] = []
        view.rewind = { commands.append("rewind") }; view.forward = { commands.append("forward") }
        view.playPause = { commands.append("toggle") }
        #expect(!view.controlsVisible)
        view.handleSurfaceTap(at: CGPoint(x: 300, y: 400), time: 1)
        #expect(view.controlsVisible && commands.isEmpty)
        view.handleSurfaceTap(at: CGPoint(x: 300, y: 400), time: 1.2)
        #expect(!view.controlsVisible && commands == ["forward"])
        view.handleSurfaceTap(at: CGPoint(x: 100, y: 400), time: 2)
        view.handleSurfaceTap(at: CGPoint(x: 100, y: 400), time: 2.2)
        #expect(commands == ["forward", "rewind"])
        view.setControlsVisible(true)
        view.playButton.sendActions(for: .touchUpInside)
        #expect(commands == ["forward", "rewind", "toggle"])
        #expect(view.controlsVisible)
        view.cancelAutoHide()
    }

    @Test func originalToolbarAndTransportStayReachableWithAsymmetricInsetsAndResize() async throws {
        try await withViewTestWindow { host, window in
            let controller = UIViewController(), view = PlaybackVideoView()
            controller.view = view; controller.overrideUserInterfaceStyle = .dark
            host.addChild(controller); host.view.addSubview(view); controller.didMove(toParent: host)
            defer { view.cancelAutoHide(); controller.willMove(toParent: nil); view.removeFromSuperview(); controller.removeFromParent() }
            view.update(position: 17_000, duration: 120_000, playing: false, buffering: false,
                        seekable: true, speed: 1, remaining: false, respectsSpeed: false)
            view.updateActions(favorite: true, timer: false, canShare: true)
            view.setControlsVisible(true)
            let layer = AVSampleBufferDisplayLayer()
            view.attach(layer, aspect: 16.0 / 9)
            let seek: PlayerSeekBar = try #require(find("videoSeek", in: view))
            let widths = Set([min(340, host.view.bounds.width), min(600, host.view.bounds.width), host.view.bounds.width])
            for width in widths {
                for inset in [UIEdgeInsets(top: 0, left: 31, bottom: 0, right: 7), .init(top: 0, left: 7, bottom: 0, right: 31)] {
                    view.frame = CGRect(x: 0, y: 0, width: width, height: host.view.bounds.height)
                    controller.additionalSafeAreaInsets = inset
                    view.setNeedsLayout(); view.layoutIfNeeded()
                    let buttons = [view.backButton, view.favoriteButton, view.timerButton, view.shareButton, view.moreButton,
                                   view.rewindButton, view.playButton, view.forwardButton]
                    for button in buttons {
                        let frame = button.convert(button.bounds, to: window)
                        #expect(window.bounds.contains(frame))
                        #expect(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) === button)
                        #expect(button.currentImage != nil)
                    }
                    #expect(view.favoriteButton.frame.maxX <= view.timerButton.frame.minX + 0.5)
                    #expect(view.timerButton.frame.maxX <= view.shareButton.frame.minX + 0.5)
                    #expect(view.shareButton.frame.maxX <= view.moreButton.frame.minX + 0.5)
                    #expect(view.rewindButton.frame.maxX <= view.playButton.frame.minX + 0.5)
                    #expect(view.playButton.frame.maxX <= view.forwardButton.frame.minX + 0.5, "rewind \(view.rewindButton.frame) play \(view.playButton.frame) forward \(view.forwardButton.frame) in \(view.bounds)")
                    #expect(view.displayLayer === layer)
                    #expect(seek.value == 71) // 17/120 of the source's 500-step seek range.
                    #expect(view.favoriteButton.accessibilityTraits.contains(.selected))
                    #expect(abs(layer.bounds.width / layer.bounds.height - 16.0 / 9) < 0.001)
                    let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
                    }
                    Attachment.record(try #require(image.pngData()), named: "video-controls-\(Int(width))-left\(Int(inset.left)).png")
                }
            }
            view.attach(layer, aspect: 16.0 / 9, rotationDegrees: 90); view.layoutIfNeeded()
            #expect(view.displayLayer === layer && seek.value == 71)
            #expect(abs(layer.affineTransform().b - 1) < 0.001)
            for rotation in [0.0, 90, 180, 270] {
                view.attach(layer, aspect: 16.0 / 9, rotationDegrees: rotation); view.layoutIfNeeded()
                #expect(view.bounds.insetBy(dx: -0.01, dy: -0.01).contains(layer.frame))
                #expect(view.displayLayer === layer && seek.value == 71)
            }
            view.attach(nil)
            #expect(layer.superlayer == nil)
        }
    }

    @Test func hiddenControlsAreExcludedFromAccessibilityAndErrorRestoresThem() throws {
        let view = PlaybackVideoView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(view.playButton.superview?.accessibilityElementsHidden == true)
        view.showError("Playback failed")
        #expect(view.controlsVisible)
        #expect(view.playButton.superview?.accessibilityElementsHidden == false)
        let error: UILabel = try #require(find("videoError", in: view))
        #expect(error.text == "Playback failed" && !error.isHidden)
        view.showError(nil)
        #expect(error.isHidden)
        view.cancelAutoHide()
    }
    @Test func sourceAutoHideDelayDoesNotHideAnError() async throws {
        try #require(!UIAccessibility.isVoiceOverRunning, "This timing fixture requires VoiceOver off; accessibility keeps controls visible")
        let view = PlaybackVideoView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let shown = ContinuousClock.now
        view.setControlsVisible(true)
        let deadline = shown + .seconds(5)
        while view.controlsVisible && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.controlsVisible)
        #expect(shown.duration(to: ContinuousClock.now) >= .milliseconds(2500))
        view.showError("Playback failed")
        try await Task.sleep(for: .milliseconds(2700))
        #expect(view.controlsVisible)
        view.cancelAutoHide()
    }

}

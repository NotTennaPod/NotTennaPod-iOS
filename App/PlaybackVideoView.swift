import UIKit
import AVFoundation
import NotTennaPodCore

/// Source VideoPlayerControlsView composition. Presentation belongs to the shared session.
@MainActor final class PlaybackVideoView: UIView, UIGestureRecognizerDelegate {
    var playPause: (() -> Void)?, rewind: (() -> Void)?, forward: (() -> Void)?
    var back: (() -> Void)?, favorite: (() -> Void)?, timer: (() -> Void)?
    var share: ((UIView) -> Void)?, overflow: ((UIView) -> Void)?
    var seekTo: ((Int64) -> Void)?, toggleRemaining: (() -> Void)?
    var editInterval: ((PlaybackIntervalDirection) -> Void)?
    var controlsChanged: (() -> Void)?
    private let picture = UIView(), toolbar = UIView(), transport = UIView(), bottom = UIView()
    private let preview = Appearance.label(nil, size: 24)
    private let position = Appearance.label("00:00:00", size: 14)
    private let duration = UIButton(type: .custom)
    private let seek = PlayerSeekBar()
    private let loading = PlayerLoadingIndicator()
    private let problem = Appearance.label(nil, size: 16)
    private let skipImage = UIImageView()
    private var sourceDuration: Int64 = 0
    private var displaySpeed: Float = 1
    private var respectsSpeed = false
    private var autoHide: Task<Void, Never>?
    /// Android VideoPlayerControlsView AUTO_HIDE_DELAY_MS (2.5 s). DEBUG UI journeys may lengthen it with
    /// `-test-video-controls-autohide-ms`: XCUITest's own latency per tap on a loaded Simulator can exceed 2.5 s, so
    /// its taps landed after the controls hid (Duo). PlaybackVideoSurfaceTests checks the 2.5 s delay.
    static let autoHideDelay: Duration = {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-test-video-controls-autohide-ms"), index + 1 < arguments.count,
           let milliseconds = Int(arguments[index + 1]), milliseconds > 0 { return .milliseconds(milliseconds) }
#endif
        return .milliseconds(2500)
    }()
    private var lastTap: TimeInterval?
    private(set) var controlsVisible = false
    private(set) weak var displayLayer: AVSampleBufferDisplayLayer?
    private var videoRotation: CGFloat = 0
    private var videoAspect: CGFloat?
    private(set) lazy var backButton = icon("abc_ic_ab_back_material", "toolbar_back_button_content_description", "videoBack") { [weak self] in self?.back?() }
    private(set) lazy var favoriteButton = icon("ic_star_border", "add_to_favorite_label", "videoFavorite") { [weak self] in self?.favorite?() }
    private(set) lazy var timerButton = icon("ic_sleep", "set_sleeptimer_label", "videoSleepTimer") { [weak self] in self?.timer?() }
    private(set) lazy var shareButton: UIButton = icon("ic_share", "share_label", "videoShare") { [weak self] in guard let self else { return }; share?(shareButton) }
    private(set) lazy var moreButton: UIButton = icon("dots_vertical", "overflow_more", "videoMore") { [weak self] in guard let self else { return }; overflow?(moreButton) }
    private(set) lazy var rewindButton = icon("ic_fast_rewind_video_white", "rewind_label", "videoRewind") { [weak self] in self?.rewind?() }
    private(set) lazy var playButton = icon("ic_play_video_white", "play_label", "videoPlay") { [weak self] in self?.playPause?() }
    private(set) lazy var forwardButton = icon("ic_fast_forward_video_white", "fast_forward_label", "videoForward") { [weak self] in self?.forward?() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; accessibilityIdentifier = "videoPlayer"
        picture.backgroundColor = .black; picture.isUserInteractionEnabled = false; picture.clipsToBounds = true
        [picture, toolbar, transport, bottom, preview, loading, problem, skipImage].forEach(addSubview)
        toolbar.backgroundColor = .black.withAlphaComponent(144.0 / 255)
        bottom.backgroundColor = toolbar.backgroundColor
        [backButton, favoriteButton, timerButton, shareButton, moreButton].forEach(toolbar.addSubview)
        [rewindButton, playButton, forwardButton].forEach(transport.addSubview)
        [position, duration, seek].forEach(bottom.addSubview)
        position.textColor = .white; position.font = Appearance.font(14, medium: true)
        position.accessibilityIdentifier = "videoPosition"
        duration.titleLabel?.font = position.font; duration.setTitleColor(.white, for: .normal)
        duration.accessibilityIdentifier = "videoDuration"; duration.contentHorizontalAlignment = .right
        duration.addAction(UIAction { [weak self] _ in self?.toggleRemaining?(); self?.resetAutoHide() }, for: .touchUpInside)
        seek.accessibilityIdentifier = "videoSeek"; seek.accessibilityLabel = Appearance.text("go_to_position_label")
        seek.addAction(UIAction { [weak self] _ in self?.previewSeek() }, for: .valueChanged)
        seek.addAction(UIAction { [weak self] _ in self?.finishSeek() }, for: .editingDidEnd)
        preview.backgroundColor = UIColor(white: 0.2, alpha: 0.9); preview.textColor = .white
        preview.textAlignment = .center; preview.layer.cornerRadius = 8; preview.clipsToBounds = true
        preview.isHidden = true; preview.accessibilityIdentifier = "videoSeekPreview"
        loading.accessibilityIdentifier = "videoLoading"
        problem.textColor = .white; problem.numberOfLines = 0; problem.textAlignment = .center
        problem.accessibilityIdentifier = "videoError"; problem.isHidden = true
        skipImage.isHidden = true; skipImage.isUserInteractionEnabled = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapSurface(_:)))
        tap.delegate = self; addGestureRecognizer(tap)
        rewindButton.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(editRewind(_:))))
        forwardButton.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(editForward(_:))))
        rewindButton.accessibilityCustomActions = [.init(name: Appearance.text("pref_rewind")) { [weak self] _ in self?.editInterval?(.rewind); return true }]
        forwardButton.accessibilityCustomActions = [.init(name: Appearance.text("pref_fast_forward")) { [weak self] _ in self?.editInterval?(.forward); return true }]
        NotificationCenter.default.addObserver(self, selector: #selector(voiceOverChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        setControlsVisible(UIAccessibility.isVoiceOverRunning)
    }
    @objc private func voiceOverChanged() {
        if UIAccessibility.isVoiceOverRunning { setControlsVisible(true) } else { resetAutoHide() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { autoHide?.cancel() }
    private func icon(_ image: String, _ key: String, _ id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .custom)
        button.setImage(UIImage(named: image), for: .normal); button.tintColor = .white
        button.accessibilityLabel = Appearance.text(key); button.accessibilityIdentifier = id
        button.addAction(UIAction { [weak self] _ in action(); self?.resetAutoHide() }, for: .touchUpInside)
        return button
    }
    func attach(_ layer: AVSampleBufferDisplayLayer?, aspect: Double? = nil, rotationDegrees: Double = 0) {
        if displayLayer !== layer {
            displayLayer?.removeFromSuperlayer(); displayLayer = layer
            if let layer { picture.layer.addSublayer(layer); layer.videoGravity = .resizeAspect }
        }
        videoAspect = aspect.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil }
        videoRotation = rotationDegrees.isFinite ? CGFloat(rotationDegrees * .pi / 180) : 0
        // Metadata geometry already applies non-square pixels. Fitting the raw
        // pixel-buffer aspect a second time would incorrectly letterbox it.
        displayLayer?.videoGravity = videoAspect == nil ? .resizeAspect : .resize
        setNeedsLayout()
    }
    func update(position value: Int64, duration length: Int64, playing: Bool, buffering: Bool,
                seekable: Bool, speed: Float, remaining: Bool, respectsSpeed: Bool) {
        sourceDuration = max(0, length); displaySpeed = speed; self.respectsSpeed = respectsSpeed
        position.text = time(value)
        duration.setTitle((remaining ? "-" : "") + time(remaining ? max(0, length - value) : length), for: .normal)
        duration.accessibilityLabel = Appearance.durationDescription(remaining ? "remaining_time" : "chapter_duration", milliseconds: Int32(clamping: remaining ? max(0, length - value) : length))
        if !seek.isTracking { seek.value = length > 0 ? Float(Double(value) / Double(length) * 500) : 0 }
        seek.isEnabled = seekable && length > 0
        playButton.setImage(UIImage(named: playing ? "ic_pause_video_white" : "ic_play_video_white"), for: .normal)
        playButton.accessibilityLabel = Appearance.text(playing ? "pause_label" : "play_label")
        if buffering { loading.startAnimating() } else { loading.stopAnimating() }
        setNeedsLayout()
    }
    func updateActions(favorite selected: Bool, timer active: Bool, canShare: Bool) {
        favoriteButton.setImage(UIImage(named: selected ? "ic_star" : "ic_star_border"), for: .normal)
        favoriteButton.accessibilityLabel = Appearance.text(selected ? "remove_from_favorite_label" : "add_to_favorite_label")
        favoriteButton.accessibilityTraits = selected ? [.button, .selected] : .button
        timerButton.setImage(UIImage(named: active ? "ic_sleep_off" : "ic_sleep"), for: .normal)
        timerButton.accessibilityLabel = Appearance.text(active ? "sleep_timer_label" : "set_sleeptimer_label")
        shareButton.isHidden = !canShare; setNeedsLayout()
    }
    func showError(_ text: String?) {
        problem.text = text; problem.isHidden = text == nil
        if text != nil { setControlsVisible(true); loading.stopAnimating() }
    }
    func setControlsVisible(_ visible: Bool) {
        controlsVisible = visible
        [toolbar, transport, bottom].forEach { $0.isHidden = !visible; $0.accessibilityElementsHidden = !visible }
        if visible { resetAutoHide() } else { cancelAutoHide() }
        controlsChanged?()
    }
    func resetAutoHide() {
        cancelAutoHide()
        guard controlsVisible, !UIAccessibility.isVoiceOverRunning, problem.isHidden else { return }
        autoHide = Task { [weak self] in
            do { try await Task.sleep(for: Self.autoHideDelay) } catch { return }
            self?.setControlsVisible(false)
        }
    }
    func cancelAutoHide() { autoHide?.cancel(); autoHide = nil }
    func handleSurfaceTap(at point: CGPoint, time: TimeInterval) {
        if let lastTap, time >= lastTap, time - lastTap < 0.3 {
            let isForward = point.x > bounds.midX
            if isForward { forward?() } else { rewind?() }
            setControlsVisible(false); animateSkip(forward: isForward)
        } else { setControlsVisible(!controlsVisible) }
        lastTap = time
    }
    @objc private func tapSurface(_ gesture: UITapGestureRecognizer) { handleSurfaceTap(at: gesture.location(in: self), time: CACurrentMediaTime()) }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let current = target, current !== self {
            if current === toolbar || current === transport || current === bottom || current is UIControl { return false }
            target = current.superview
        }
        return true
    }
    @objc private func editRewind(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began { cancelAutoHide(); editInterval?(.rewind) } }
    @objc private func editForward(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began { cancelAutoHide(); editInterval?(.forward) } }
    private func time(_ value: Int64) -> String {
        let ms = PlaybackSpeed.displayTime(Int32(clamping: max(0, value)), speed: displaySpeed, respectsSpeed: respectsSpeed)
        return EpisodeRowPresentation.time(ms)
    }
    private func previewSeek() {
        cancelAutoHide(); preview.isHidden = false
        preview.text = time(Int64(Double(seek.value) / 500 * Double(sourceDuration))); setNeedsLayout()
    }
    private func finishSeek() {
        let value = Int64(Double(seek.value) / 500 * Double(sourceDuration))
        preview.isHidden = true; seekTo?(value); resetAutoHide()
    }
    private func animateSkip(forward: Bool) {
        skipImage.layer.removeAllAnimations(); skipImage.transform = .identity; skipImage.alpha = 1
        skipImage.image = UIImage(named: forward ? "ic_fast_forward_video_white" : "ic_fast_rewind_video_white")
        skipImage.frame = CGRect(x: forward ? max(0, bounds.width - 208) : 64, y: bounds.midY - 40, width: 80, height: 80)
        skipImage.isHidden = false
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.8, animations: {
            self.skipImage.alpha = 0; self.skipImage.transform = CGAffineTransform(scaleX: 2, y: 2)
        }, completion: { [weak self] _ in self?.skipImage.isHidden = true })
    }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let displayLayer {
            let aspect = videoAspect ?? (bounds.width / max(1, bounds.height))
            let sine = abs(sin(videoRotation)), cosine = abs(cos(videoRotation))
            let height = min(bounds.width / max(0.001, aspect * cosine + sine),
                             bounds.height / max(0.001, aspect * sine + cosine))
            let width = height * aspect
            displayLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: videoRotation))
        }
        CATransaction.commit()
        let safe = bounds.inset(by: safeAreaInsets), rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: safe.minY + 56)
        backButton.frame = CGRect(x: rtl ? safe.maxX - 56 : safe.minX, y: safe.minY, width: 56, height: 56)
        let trailing = [moreButton, shareButton, timerButton, favoriteButton].filter { !$0.isHidden }
        var edge = rtl ? safe.minX : safe.maxX
        for button in trailing {
            let width: CGFloat = button === moreButton ? 40 : 48
            button.frame = CGRect(x: rtl ? edge : edge - width, y: safe.minY + 4, width: width, height: 48)
            edge += rtl ? width : -width
        }
        let step = min(96, max(0, safe.width - 32) / 3), buttonSize = min(80, step)
        transport.frame = CGRect(x: safe.midX - step * 1.5, y: safe.midY - buttonSize / 2, width: step * 3, height: buttonSize)
        for (index, button) in [rewindButton, playButton, forwardButton].enumerated() {
            button.frame = CGRect(x: CGFloat(index) * step + (step - buttonSize) / 2, y: 0, width: buttonSize, height: buttonSize)
            button.imageView?.contentMode = .scaleAspectFit
        }
        position.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        duration.titleLabel?.font = position.font
        let rowHeight = max(50, position.font.lineHeight + 24)
        bottom.frame = CGRect(x: 0, y: max(toolbar.frame.maxY, safe.maxY - rowHeight), width: bounds.width, height: rowHeight + safeAreaInsets.bottom)
        let labelWidth = min(max(72, position.intrinsicContentSize.width, duration.intrinsicContentSize.width), safe.width / 3)
        position.frame = CGRect(x: safe.minX + 8, y: 8, width: labelWidth, height: rowHeight - 16)
        duration.frame = CGRect(x: safe.maxX - labelWidth - 8, y: 0, width: labelWidth, height: rowHeight)
        seek.frame = CGRect(x: position.frame.maxX, y: 0, width: max(0, duration.frame.minX - position.frame.maxX), height: rowHeight)
        let size = preview.sizeThatFits(CGSize(width: max(1, safe.width - 48), height: 100))
        preview.frame = CGRect(x: safe.midX - (size.width + 48) / 2, y: bottom.frame.minY - size.height - 20, width: size.width + 48, height: size.height + 8)
        loading.frame = CGRect(x: safe.midX - 32, y: safe.midY - 32, width: 64, height: 64)
        problem.frame = CGRect(x: safe.minX + 24, y: toolbar.frame.maxY + 8, width: max(0, safe.width - 48), height: max(0, bottom.frame.minY - toolbar.frame.maxY - 16))
    }
}

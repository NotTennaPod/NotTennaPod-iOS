import UIKit
import NotTennaPodCore

@MainActor
final class EpisodeDownloadButton: UIButton {
    private let icon = UIImageView()
    private let ring = DownloadRingView()
    /// Home cards draw the action on an accent circle (source `horizontal_itemlist_item.xml`).
    var iconTint: UIColor = Appearance.foreground { didSet { icon.tintColor = iconTint } }
    /// Home card style: the ring (white) appears only while downloading, as on the source card.
    var cardStyle = false { didSet { ring.drawsIdleCircle = !cardStyle; ring.strokeColor = cardStyle ? .white : nil } }

    init(episodeID: Int64, action: @escaping () -> Void) {
        super.init(frame: .zero)
        accessibilityIdentifier = "episode-action-\(episodeID)"
        icon.contentMode = .scaleAspectFit
        icon.tintColor = Appearance.foreground
        [icon, ring].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(episode: LibraryEpisode, job: LibraryDownloadJob?, progress: MediaDownloadProgress?, playing: Bool = false,
                localFeed: Bool = false, streamOverDownload: Bool = false, prefersDelete: Bool = false) {
        if prefersDelete && episode.userState.isDownloaded {
            isHidden = episode.details.media == nil; isEnabled = true
            icon.image = UIImage(named: "ic_delete"); accessibilityLabel = Appearance.text("delete_label")
            accessibilityValue = nil; ring.update(0, indeterminate: false)
            return
        }
        let percent: Int
        if let progress, let expected = progress.expected, expected > 0 {
            percent = Int(min(100, max(0, Double(progress.received) / Double(expected) * 100)))
        } else { percent = 0 }
        let presentation = EpisodeRowPresentation(episode: episode, currentlyPlaying: playing, localFeed: localFeed, downloading: job != nil,
                                                  queuedDownload: job?.state == .waiting, downloadPercent: percent,
                                                  streamOverDownload: streamOverDownload)
        isHidden = episode.details.media == nil
        isEnabled = [.download, .cancelDownload, .playLocal, .play, .pause, .stream].contains(presentation.action)
        let downloading = presentation.action == .cancelDownload
        let imageName: String, label: String
        switch presentation.action {
        case .pause: (imageName, label) = ("ic_pause", "pause_label")
        case .playLocal, .play: (imageName, label) = ("ic_play_24dp", "play_label")
        case .cancelDownload: (imageName, label) = ("ic_cancel", "cancel_download_label")
        case .stream: (imageName, label) = ("ic_stream", "stream_label")
        case .download, .markPlayed: (imageName, label) = ("ic_download", "download_label")
        }
        icon.image = UIImage(named: imageName)
        accessibilityLabel = Appearance.text(label)
        accessibilityValue = downloading ? "\(percent)%" : nil
        ring.update(presentation.downloadProgress, indeterminate: presentation.downloadIndeterminate)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
        ring.frame = CGRect(x: bounds.midX - 20, y: bounds.midY - 20, width: 40, height: 40)
    }
}

@MainActor
final class DownloadRingView: UIView {
    @MainActor private final class Tick: NSObject {
        weak var view: DownloadRingView?
        @objc func step() { view?.step() }
    }
    private var percentage: Float?
    private var target: Float = 0
    private var indeterminate = false
    private var displayLink: CADisplayLink?
    private let tick = Tick()

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        tick.view = self
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { displayLink?.invalidate() }

    func update(_ value: Float, indeterminate: Bool, animated: Bool = true) {
        let drawn = (percentage, self.indeterminate)
        if percentage == nil || !animated { percentage = value }
        target = value
        self.indeterminate = indeterminate
        // Rows are updated on every playback/download tick; repaint only when the drawing changes
        // (the animation steps towards `target` and repaints itself).
        if percentage != drawn.0 || indeterminate != drawn.1 { setNeedsDisplay() }
        animateIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { displayLink?.invalidate(); displayLink = nil }
        else { animateIfNeeded() }
    }

    private func animateIfNeeded() {
        guard window != nil, displayLink == nil, abs((percentage ?? 0) - target) > 0.005 else { return }
        let link = CADisplayLink(target: tick, selector: #selector(Tick.step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func step() {
        let value = percentage ?? 0
        let difference = target - value
        if abs(difference) <= 0.005 { displayLink?.invalidate(); displayLink = nil; return }
        let speed: Float = abs(difference) < 0.1 && difference > 0 ? 0.006 : 0.02
        percentage = value + min(speed, abs(difference)) * (difference > 0 ? 1 : -1)
        setNeedsDisplay()
    }

    var drawsIdleCircle = true { didSet { if drawsIdleCircle != oldValue { setNeedsDisplay() } } }
    var strokeColor: UIColor? { didSet { if strokeColor != oldValue { setNeedsDisplay() } } }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let padding = bounds.height * 0.08
        let circle = bounds.insetBy(dx: padding, dy: padding)
        guard drawsIdleCircle || indeterminate || (percentage ?? 0) >= 0.005 else { return }
        context.setStrokeColor((strokeColor ?? Appearance.foreground).cgColor)
        context.setLineWidth(bounds.height * 0.03)
        let scale = max(1, window?.screen.scale ?? traitCollection.displayScale)
        context.setLineDash(phase: 0, lengths: indeterminate ? [5 / scale, 5 / scale] : [])
        context.strokeEllipse(in: circle)
        if let percentage, percentage >= 0.005, percentage <= 0.995 {
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(padding)
            context.setLineCap(.round)
            context.addArc(center: CGPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                           startAngle: -.pi / 2, endAngle: -.pi / 2 + CGFloat(percentage) * 2 * .pi, clockwise: false)
            context.strokePath()
        }
    }
}

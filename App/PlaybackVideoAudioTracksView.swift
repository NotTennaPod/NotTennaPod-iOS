import UIKit
import NotTennaPodCore

/// PlaybackControlsDialog's supported-track chip row, backed by the selected session.
@MainActor final class PlaybackVideoAudioTracksView: UIView, SourceMessageBodyViewport {
    var minimumMessageViewportHeight: CGFloat { 80 }
    private let playback: PlaybackCoordinator
    private let failure: (Error) -> Void
    private let episodeID: Int64?
    private var renderedPresentationID: UUID?
    private let scroll = UIScrollView()
    private let errorLabel = Appearance.label(nil, size: 14)
    private var buttons: [UIButton] = []
    private var tracks: [PlaybackMediaTrack] = []
    private var events: Task<Void, Never>?
    private var selecting = false
    init(playback: PlaybackCoordinator, failure: @escaping (Error) -> Void) {
        self.playback = playback; self.failure = failure; episodeID = playback.episode?.id
        super.init(frame: .zero)
        accessibilityIdentifier = "videoAudioTracks"
        scroll.showsHorizontalScrollIndicator = false; scroll.contentInsetAdjustmentBehavior = .never
        addSubview(scroll); addSubview(errorLabel); errorLabel.textColor = Appearance.foreground
        errorLabel.numberOfLines = 0; errorLabel.isHidden = true; errorLabel.accessibilityIdentifier = "videoAudioTrackError"
        update()
        events = Task { [weak self, playback] in
            for await _ in playback.events() { guard let self, !Task.isCancelled else { return }; update() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { events?.cancel() }
    private func update() {
        let presentation = playback.episode?.id == episodeID ? playback.videoPresentation : nil
        let sessionID = presentation?.mediaPresentationID
        let current = presentation?.mediaTracks.filter { $0.kind == .audio } ?? []
        if current != tracks || sessionID != renderedPresentationID {
            renderedPresentationID = sessionID
            tracks = current; buttons.forEach { $0.removeFromSuperview() }
            buttons = current.enumerated().map { index, track in
                let button = UIButton(type: .custom)
                let label = track.title.flatMap { $0.isEmpty ? nil : $0 } ?? track.language.flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(index + 1)"
                button.setTitle(label, for: .normal); button.setTitleColor(Appearance.foreground, for: .normal)
                button.accessibilityIdentifier = "videoAudioTrack-\(track.id)"
                button.layer.cornerRadius = 8; button.layer.borderWidth = 1
                button.addAction(UIAction { [weak self] _ in self?.select(track.id, presentationID: sessionID) }, for: .touchUpInside)
                scroll.addSubview(button); return button
            }
        }
        for (index, button) in buttons.enumerated() {
            let selected = tracks[index].id == playback.videoPresentation?.selectedAudioTrackID
            button.backgroundColor = selected ? Appearance.selected : .clear
            button.layer.borderColor = selected ? UIColor.clear.cgColor : Appearance.secondary.cgColor
            button.setImage(selected ? UIImage(named: "ic_check") : nil, for: .normal)
            button.tintColor = Appearance.foreground; button.isEnabled = !selecting && sessionID != nil
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
        setNeedsLayout()
    }
    private func select(_ id: Int32, presentationID: UUID?) {
        guard !selecting, let presentationID, playback.episode?.id == episodeID,
              playback.videoPresentation?.mediaPresentationID == presentationID else { return }; selecting = true; errorLabel.isHidden = true; update()
        Task { [weak self, playback, episodeID] in
            guard playback.episode?.id == episodeID, playback.videoPresentation?.mediaPresentationID == presentationID else {
                self?.selecting = false; self?.update(); return
            }
            do {
                try await playback.selectAudioTrack(id: id)
                guard let self else { return }; selecting = false; update()
            } catch is CancellationError {
                self?.selecting = false; self?.update()
            } catch {
                guard let self else { return }; selecting = false
                errorLabel.text = Appearance.text("playback_error_generic"); errorLabel.isHidden = false
                update(); failure(error)
                UIAccessibility.post(notification: .announcement, argument: errorLabel.text)
            }
        }
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: errorLabel.isHidden ? 80 : 128) }
    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 80)
        var x: CGFloat = 16
        for button in buttons {
            button.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
            let width = max(48, button.intrinsicContentSize.width + 32)
            button.frame = CGRect(x: x, y: 16, width: width, height: max(40, (button.titleLabel?.font.lineHeight ?? 20) + 16)); x += width + 16
        }
        scroll.contentSize = CGSize(width: max(bounds.width, x), height: 80)
        errorLabel.frame = CGRect(x: 16, y: 80, width: max(0, bounds.width - 32), height: 48)
    }
}

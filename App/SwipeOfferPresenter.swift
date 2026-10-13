import UIKit
import NotTennaPodCore

/// Presentation owns one visible offer. The library coordinator independently
/// owns every mark's cleanup; replacing/dismissing this view never cancels it.
@MainActor final class SwipeOfferPresenter {
    private enum Kind { case mark(UUID), queue(EpisodeQueueRemovalReceipt), history(EpisodeHistoryRemovalReceipt) }
    private final class Offer {
        let id: UUID, kind: Kind
        var requestedUndo = false
        var finished = false
        init(id: UUID, kind: Kind) { self.id = id; self.kind = kind }
    }
    private weak var host: UIView?
    private let store: FeedLibraryStore
    private let coordinator: EpisodeSwipeCoordinator
    private let actionTimeout: () -> Duration?
    private let voiceOverRunning: () -> Bool
    private var current: Offer?
    private(set) var snackbar: Snackbar?
    var onWillShow: (() -> Void)?
    var onError: ((any Error) -> Void)?
    var onQueueChange: ((LibraryQueueChange) -> Void)?
    /// History changed (removal or Undo): the list reloads, like `PlaybackHistoryEvent`.
    var onHistoryChange: (() -> Void)?
    var region: () -> CGRect
    var wide: () -> Bool

    init(host: UIView, store: FeedLibraryStore, coordinator: EpisodeSwipeCoordinator,
         actionTimeout: @escaping () -> Duration?, region: @escaping () -> CGRect, wide: @escaping () -> Bool,
         voiceOverRunning: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning }) {
        self.host = host; self.store = store; self.coordinator = coordinator
        self.actionTimeout = actionTimeout; self.region = region; self.wide = wide
        self.voiceOverRunning = voiceOverRunning
    }
    isolated deinit {
        snackbar?.onDismiss = nil
        snackbar?.dismiss(animated: false)
        if let current, !current.requestedUndo {
            let store = store, coordinator = coordinator
            switch current.kind {
            case .mark(let id): Task { await coordinator.endOffer(operationID: id) }
            case .queue(let receipt): Task { await store.releaseQueueRemoval(receipt) }
            case .history(let receipt): Task { await store.releaseHistoryRemoval(receipt) }
            }
        }
    }
    func receive(_ event: EpisodeSwipeCoordinator.Event) {
        switch event {
        case .committed(let commit):
            guard let message = commit.message else { return }
            let text = message.quantity.map { Appearance.quantity(message.rawValue, count: Int64($0)) } ?? Appearance.text(message.rawValue)
            show(.init(id: commit.operationID, kind: .mark(commit.operationID)), message: text)
        case .failed(_, _, let error): onError?(error)
        case .undone, .cleanupFinished: break
        }
    }
    func removeQueue(episodeID: Int64, offersUndo: Bool) async {
        do {
            let result = try await store.removeFromQueueWithUndo(episodeID)
            onQueueChange?(result.change)
            guard let receipt = result.receipt else { return }
            if offersUndo && host?.window != nil {
                show(.init(id: receipt.operationID, kind: .queue(receipt)),
                    message: Appearance.quantity("removed_from_queue_message", count: 1))
            } else { await store.releaseQueueRemoval(receipt) }
        } catch { onError?(error) }
    }
    /// `RemoveFromHistorySwipeAction`: "Removed from history" + Undo, which writes the original date back.
    func removeHistory(episodeID: Int64, offersUndo: Bool) async {
        do {
            let receipt = try await store.removeFromPlaybackHistoryWithUndo(episodeID)
            onHistoryChange?()
            guard let receipt else { return }
            if offersUndo && host?.window != nil {
                show(.init(id: receipt.operationID, kind: .history(receipt)), message: Appearance.text("removed_history_label"))
            } else { await store.releaseHistoryRemoval(receipt) }
        } catch { onError?(error) }
    }
    func relayout() { snackbar?.place(in: region(), wide: wide()) }
    func dismiss() { let bar = snackbar; if let current { finish(current) }; bar?.dismiss(animated: false) }

    private func show(_ offer: Offer, message: String) {
        let previous = snackbar
        if let current { finish(current) }
        previous?.dismiss(animated: false)
        guard let host, host.window != nil else { release(offer); return }
        onWillShow?()
        current = offer
        let bar = Snackbar(message: message,
            action: .init(title: Appearance.text("undo"), identifier: "inboxSwipeUndo", perform: { [weak self] in self?.undo(offer) }),
            actionTimeout: actionTimeout(), retainUnvisitedForVoiceOver: true, voiceOverRunning: voiceOverRunning)
        bar.accessibilityIdentifier = "inboxSwipeSnackbar"
        bar.onDismiss = { [weak self] in
            self?.finish(offer)
        }
        bar.onNeedsLayout = { [weak self] in self?.relayout() }
        snackbar = bar; host.addSubview(bar); relayout(); bar.appear()
    }
    private func undo(_ offer: Offer) {
        guard current?.id == offer.id, !offer.requestedUndo else { return }
        offer.requestedUndo = true
        switch offer.kind {
        case .mark(let id):
            // This call consumes/cancels synchronously, before UIKit returns to
            // its run loop. Coordinator events carry persistence/error results.
            _ = coordinator.beginUndo(operationID: id)
        case .queue(let receipt):
            let store = store
            Task { [weak self] in
                do {
                    let result = try await store.undoQueueRemoval(receipt)
                    if let change = result.change { self?.onQueueChange?(change) }
                } catch {
                    self?.onError?(error)
                    // No hidden retry after a consumed visible action.
                    await store.releaseQueueRemoval(receipt)
                }
            }
        case .history(let receipt):
            let store = store
            Task { [weak self] in
                do {
                    let result = try await store.undoHistoryRemoval(receipt)
                    if result.status == .restored { self?.onHistoryChange?() }
                } catch {
                    self?.onError?(error)
                    await store.releaseHistoryRemoval(receipt)
                }
            }
        }
    }
    private func finish(_ offer: Offer) {
        guard !offer.finished else { return }
        offer.finished = true
        if current?.id == offer.id { current = nil; snackbar = nil }
        if !offer.requestedUndo { release(offer) }
    }
    private func release(_ offer: Offer) {
        let store = store, coordinator = coordinator
        switch offer.kind {
        case .mark(let id): Task { await coordinator.endOffer(operationID: id) }
        case .queue(let receipt): Task { await store.releaseQueueRemoval(receipt) }
        case .history(let receipt): Task { await store.releaseHistoryRemoval(receipt) }
        }
    }
}

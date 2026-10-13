import UIKit
import NotTennaPodCore

/// Adapts the configured list routes (Inbox, Episodes, Favorites and a podcast's list, plus Queue and History) to
/// existing recipients. App integration supplies normal download/list/notice handlers and captured guarded targets.
@MainActor final class SwipeRecipient {
    private let preferences: SwipePreferenceStore
    private let screen: SwipeScreen
    private let coordinator: EpisodeSwipeCoordinator
    private let offers: SwipeOfferPresenter
    private let configure: () -> Void
    private let ordinary: (SwipeDecision, EpisodeActionModel, EpisodeMediaDeletionTarget?) async -> Void
    init(preferences: SwipePreferenceStore, screen: SwipeScreen,
         coordinator: EpisodeSwipeCoordinator, offers: SwipeOfferPresenter,
         configure: @escaping () -> Void, ordinary: @escaping (SwipeDecision, EpisodeActionModel, EpisodeMediaDeletionTarget?) async -> Void) {
        self.preferences = preferences; self.screen = screen; self.coordinator = coordinator
        self.offers = offers; self.configure = configure; self.ordinary = ordinary
    }
    func configuration(direction: EpisodeSwipeDirection, item: EpisodeListItem, filter: FeedEpisodeFilter) -> EpisodeRowSwipe.Configuration? {
        switch preferences.gesture(on: screen, direction: direction) {
        case .disabled: nil
        case .configure: .init(action: nil, removes: false)
        case .action(let action): .init(inboxAction: action, removes: action.removesRow(item: item, filter: filter))
        }
    }
    func perform(direction: EpisodeSwipeDirection, model: EpisodeActionModel,
                 filter: FeedEpisodeFilter, target: EpisodeMediaDeletionTarget?, item: EpisodeListItem? = nil) async {
        switch preferences.gesture(on: screen, direction: direction) {
        case .disabled: return
        case .configure: configure()
        case .action(let action):
            let decision = action.decision(item: item ?? model.snapshot(), filter: filter)
            switch decision.recipient {
            case .markWithUndo:
                _ = await coordinator.perform(model: model, action: action == .removeInbox ? .removeInbox : .togglePlayed,
                    target: target, offersUndo: decision.undo != nil)
            case .list(.removeQueue):
                await offers.removeQueue(episodeID: model.episodeID, offersUndo: decision.undo == .queuePosition)
            case .removeHistory:
                await offers.removeHistory(episodeID: model.episodeID, offersUndo: decision.undo == .historyDate)
            case .none: break
            default: await ordinary(decision, model, target)
            }
        }
    }
}

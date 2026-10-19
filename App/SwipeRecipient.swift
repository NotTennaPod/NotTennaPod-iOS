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
        await accept(direction: direction, model: model, filter: filter, target: target, item: item)?()
    }
    /// What a swipe in `direction` does, settled now (the configured action and its decision for the captured model,
    /// filter and target); nil when the gesture is disabled. The result performs it, whenever it is called.
    func accept(direction: EpisodeSwipeDirection, model: EpisodeActionModel, filter: FeedEpisodeFilter,
                target: EpisodeMediaDeletionTarget?, item: EpisodeListItem? = nil) -> (@MainActor () async -> Void)? {
        switch preferences.gesture(on: screen, direction: direction) {
        case .disabled: return nil
        case .configure: return { [configure] in configure() }
        case .action(let action):
            let decision = action.decision(item: item ?? model.snapshot(), filter: filter)
            return { [coordinator, offers, ordinary] in
                switch decision.recipient {
                case .markWithUndo(let mark):
                    // The state settled at acceptance, not a toggle of whatever the episode is when it runs.
                    _ = await coordinator.perform(model: model, action: mark == .removeInbox ? .removeInbox
                        : mark == .markPlayed ? .markPlayed : .markUnplayed, target: target, offersUndo: decision.undo != nil)
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
}

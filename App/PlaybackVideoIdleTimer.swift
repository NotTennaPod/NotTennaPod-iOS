import UIKit

/// Native counterpart of the source activity's FLAG_KEEP_SCREEN_ON. Multiple
/// transitioning surfaces cannot restore the app's prior setting prematurely.
@MainActor enum PlaybackVideoIdleTimer {
    private static var owners: Set<UUID> = []
    private static var previousValue = false
    static func acquire(_ owner: UUID) {
        guard !owners.contains(owner) else { return }
        if owners.isEmpty { previousValue = UIApplication.shared.isIdleTimerDisabled }
        owners.insert(owner)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    static func release(_ owner: UUID) {
        guard owners.remove(owner) != nil else { return }
        if owners.isEmpty { UIApplication.shared.isIdleTimerDisabled = previousValue }
    }
}

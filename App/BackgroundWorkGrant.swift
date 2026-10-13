import UIKit
import NotTennaPodCore

/// UIKit's background task as the app's one `BackgroundWorkGrant` uses it (the grant's rules are in the core type).
@MainActor final class UIKitBackgroundTime: BackgroundTimeProviding {
    private var tasks: [Int: UIBackgroundTaskIdentifier] = [:]
#if DEBUG
    /// The hub bridge's name for the grant held (`HubBridge`).
    private var hubLeases: [Int: String] = [:]
#endif
    private var next = 0

    var isInBackground: Bool { UIApplication.shared.applicationState == .background }

    func begin(expired: @escaping @MainActor () -> Void) -> Int? {
        let expiration: @Sendable () -> Void = { MainActor.assumeIsolated { expired() } }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "NotTennaPod background work", expirationHandler: expiration)
        guard identifier != .invalid else { return nil }
        next += 1
        tasks[next] = identifier
#if DEBUG
        hubLeases[next] = HubBridge.shared?.leaseTaken(kind: "background-work-grant", expire: expiration)
#endif
        return next
    }

    func end(_ grant: Int, expired: Bool) {
        guard let identifier = tasks.removeValue(forKey: grant) else { return }
#if DEBUG
        if let hubLease = hubLeases.removeValue(forKey: grant) {
            if expired { HubBridge.shared?.leaseEnded(hubLease, state: "expired") }
            HubBridge.shared?.leaseEnded(hubLease, state: "released")
        }
#endif
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

extension AppDelegate {
    /// The participants that hold the grant for the app's lifetime, in the order they are told: synchronization,
    /// a server library's exchange, downloads, then a manual refresh. While the app is in the background, pending
    /// synchronization starts at once instead of after the 20 s debounce; when a scene becomes active the source delays
    /// apply again and paused transfers continue. When the time ends, the outbox and the sync request stay pending, a
    /// partial download stays for Range resume and no attempt is counted, and a manual refresh stops with its saved
    /// request kept (nothing is marked as failed); it runs again when the app is active.
    func makeBackgroundWorkGrant() -> BackgroundWorkGrant {
        BackgroundWorkGrant(time: UIKitBackgroundTime(), participants: [
            .init(hasWork: { [weak self] in
                switch self?.synchronization?.state {
                case .waiting?, .running?: true
                default: false
                }
            }, park: { [weak self] in self?.synchronization?.suspend() },
               changed: { [weak self] background in self?.synchronization?.setExpedited(background) }),
            // A server library's exchange; while a server-sync background task of its own runs, that task's
            // time covers it, so the grant's refusal or exhaustion never stops it.
            .serverSync({ [weak self] in self?.serverSync }, inWindow: { [weak self] in self?.serverSyncWindows.isEmpty == false }),
            // A download parked until saved state can be read holds no background time.
            .init(hasWork: { [weak self] in self?.downloads?.hasProcessWork == true },
                  park: { [weak self] in self?.downloadRouter?.pauseForegroundTransfers() },
                  changed: { [weak self] background in if !background { self?.downloadRouter?.resumeForegroundTransfers() } }),
            .manualRefresh { [weak self] in self?.manualRefresh },
        ])
    }
}

import UserNotifications

@MainActor
public protocol EpisodeNotificationAuthorization: Sendable {
    func isAuthorized() async -> Bool
    func request() async throws -> Bool
}

/// Uses the public OS authorization API only on an explicit settings action.
/// Provisional permission may deliver quietly; requesting never opts into it.
@MainActor
public final class NativeNotificationAuthorization: EpisodeNotificationAuthorization {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) { self.center = center }

    public func isAuthorized() async -> Bool {
        Self.permitsNotifications((await center.notificationSettings()).authorizationStatus)
    }

    public func request() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    static func permitsNotifications(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional: true
        case .denied, .notDetermined: false
        #if os(iOS)
        case .ephemeral: true
        #endif
        @unknown default: false
        }
    }
}

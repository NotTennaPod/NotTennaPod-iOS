import Foundation
import UserNotifications

/// The part of the system notification center the publisher uses; tests substitute a recording center,
/// so they need no notification permission on the device.
@MainActor public protocol SynchronizationNotificationCenter: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func post(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}
extension UNUserNotificationCenter: SynchronizationNotificationCenter {
    public func authorizationStatus() async -> UNAuthorizationStatus { await notificationSettings().authorizationStatus }
    /// The request is built for this call and not used afterwards.
    public func post(_ request: UNNotificationRequest) async throws {
        nonisolated(unsafe) let request = request
        try await add(request)
    }
}

@MainActor public final class NativeSynchronizationNotifications: SynchronizationNotificationPublishing {
    public nonisolated static let category = "synchronization-error"
    public nonisolated static let errorIdentifier = "synchronization-error"
    public nonisolated static let authenticationIdentifier = "synchronization-authentication-error"
    private let center: any SynchronizationNotificationCenter
    private nonisolated static let removalQueue = DispatchQueue(label: "AntennaPod.SynchronizationNotifications", qos: .utility)
    public init(center: any SynchronizationNotificationCenter = UNUserNotificationCenter.current()) { self.center = center }
    public func isAuthorized() async -> Bool {
        NativeNotificationAuthorization.permitsNotifications(await center.authorizationStatus())
    }
    public func publishError(title: String, body: String) async throws {
        try Task.checkCancellation()
        try await center.post(Self.request(title: title, body: body))
    }
    public func clearErrors() async {
        let ids = [Self.errorIdentifier, Self.authenticationIdentifier]
        if center is UNUserNotificationCenter {
            // UserNotifications answers these removals with a synchronous call to the notification
            // service. On the main actor an unresponsive service (seen on the iOS 27.0 iPhone Simulator)
            // froze the app after every successful sync; clearing is best-effort, so it runs off
            // the main thread and does not hold up the sync result.
            Self.removalQueue.async {
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: ids)
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
            return
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    public static func request(title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.categoryIdentifier = category
        content.interruptionLevel = .active; content.sound = .default
        return UNNotificationRequest(identifier: errorIdentifier, content: content, trigger: nil)
    }
    public nonisolated static func opensApplication(identifier: String, category: String) -> Bool {
        category == Self.category && [errorIdentifier, authenticationIdentifier].contains(identifier)
    }
}

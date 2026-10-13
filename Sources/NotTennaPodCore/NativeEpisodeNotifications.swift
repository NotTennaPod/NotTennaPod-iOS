import Foundation
import UserNotifications

/// The part of the system notification center the new-episode adapter uses. Tests and the UI-test fixture
/// substitute a recording center, so what the app posts and how it routes is checked without the
/// system permission prompt (which the iOS 27.0 iPhone Simulator never shows).
@MainActor public protocol EpisodeNotificationCenter: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Identifiers of requests still waiting for delivery.
    func pendingIdentifiers() async -> [String]
    /// Identifiers of notifications currently shown in Notification Center.
    func deliveredIdentifiers() async -> [String]
    func post(_ request: UNNotificationRequest) async throws
}
extension UNUserNotificationCenter: EpisodeNotificationCenter {
    public func pendingIdentifiers() async -> [String] { await pendingNotificationRequests().map(\.identifier) }
    public func deliveredIdentifiers() async -> [String] { await deliveredNotifications().map { $0.request.identifier } }
}

/// Native delivery adapter. A dedicated summary item preserves Inbox navigation;
/// iOS also owns thread presentation. The additional Inbox summary card is a
/// deliberate platform adaptation.
@MainActor
public final class NativeEpisodeNotifications: EpisodeNotificationPublishing {
    public nonisolated static let category = "new-episodes"
    private let center: any EpisodeNotificationCenter
    private let directory: URL
    public init(center: any EpisodeNotificationCenter = UNUserNotificationCenter.current(),
                directory: URL = FileManager.default.temporaryDirectory) {
        self.center = center; self.directory = directory
    }
    public func isAuthorized() async -> Bool {
        NativeNotificationAuthorization.permitsNotifications(await center.authorizationStatus())
    }
    public func existingIdentifiers() async -> Set<String> {
        let pending = await center.pendingIdentifiers()
        // Pending can become delivered between reads. Reading pending first
        // avoids losing that transition and accidentally alerting a second time.
        let delivered = await center.deliveredIdentifiers()
        return Set(delivered + pending)
    }
    public func publish(_ publication: EpisodeNotificationPublication) async throws {
        try Task.checkCancellation()
        let folder = directory.appendingPathComponent("EpisodeNotification-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var attachment: UNNotificationAttachment?
        if let bytes = publication.artwork {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("cover.png")
                try bytes.write(to: file, options: .atomic)
                attachment = try UNNotificationAttachment(identifier: "podcast-artwork", url: file,
                    options: [UNNotificationAttachmentOptionsThumbnailClippingRectKey:
                                ["X": 0, "Y": 0, "Width": 1, "Height": 1]])
            } catch { /* Missing or invalid artwork must not suppress the notification. */ }
        }
        try Task.checkCancellation()
        try await center.post(Self.request(for: publication, attachment: attachment))
    }
    public static func request(for publication: EpisodeNotificationPublication,
                               attachment: UNNotificationAttachment? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = publication.title; content.body = publication.body
        content.threadIdentifier = EpisodeNotificationPublication.group
        content.categoryIdentifier = category
        content.interruptionLevel = publication.alerts ? .active : .passive
        content.sound = publication.alerts ? .default : nil
        switch publication.destination {
        case .feed(let id): content.userInfo = ["feedID": String(id)]
        case .inbox: content.userInfo = ["destination": "inbox"]
        }
        if let attachment { content.attachments = [attachment] }
        return UNNotificationRequest(identifier: publication.identifier, content: content, trigger: nil)
    }
    public nonisolated static func destination(identifier: String, category: String,
                                              userInfo: [AnyHashable: Any]) -> EpisodeNotificationDestination? {
        guard category == Self.category else { return nil }
        if identifier == EpisodeNotificationPublication.summaryID, userInfo["destination"] as? String == "inbox" { return .inbox }
        if let raw = userInfo["feedID"] as? String, let id = Int64(raw), id > 0,
           identifier == EpisodeNotificationPublication.feedID(id) { return .feed(id) }
        return nil
    }
}

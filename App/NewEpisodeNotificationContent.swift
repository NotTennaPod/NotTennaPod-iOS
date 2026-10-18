import UIKit
import NotTennaPodCore

/// Original plural wording; the native adapter owns presentation, not decisions.
@MainActor enum NewEpisodeNotificationContent {
    nonisolated static var text: EpisodeNotificationDelivery.Text {
        .init(title: { count in String.localizedStringWithFormat(NSLocalizedString("new_episode_notification_title", comment: ""), count) },
              message: { count, title in String.localizedStringWithFormat(NSLocalizedString("new_episode_notification_message", comment: ""), count, title) },
              summary: NSLocalizedString("new_episode_notification_group_text", comment: ""))
    }

    static func artwork(_ candidate: NewEpisodeNotification, store: FeedLibraryStore) async throws -> Data? {
        guard let identity = candidate.imageURL, !identity.isEmpty else { return nil }
        if identity.hasPrefix(GenerativeCoverPattern.artworkPrefix) {
            let format = UIGraphicsImageRendererFormat(); format.scale = 3
            return UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).pngData { renderer in
                EpisodeArtworkView.drawPattern(model: identity, context: renderer.cgContext, size: CGSize(width: 128, height: 128), scale: 3)
            }
        }
        let bytes: Data?
        if URL(string: identity)?.isFileURL == true {
            bytes = try await LocalFolderArtworkReader(store: store).read(feedID: candidate.feedID, identity: identity)
        } else if let url = URL(string: identity), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            // The covers the screens show: on the phone already, or downloaded once for both.
            bytes = await ArtworkImageCache.remoteSource(identity)
        } else { return nil }
        try Task.checkCancellation()
        guard let bytes, let image = UIImage(data: bytes), image.size.width > 0, image.size.height > 0 else { return nil }
        // Source128dp square center crop. A384px result serves all supported
        // display densities; UIImage drawing applies embedded orientation.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let size: CGFloat = 384
        let factor = max(size / image.size.width, size / image.size.height)
        let result = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            image.draw(in: CGRect(x: (size - image.size.width * factor) / 2, y: (size - image.size.height * factor) / 2,
                                  width: image.size.width * factor, height: image.size.height * factor))
        }
        return result.pngData()
    }
}

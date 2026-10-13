import Foundation
import GoogleCast
import NotTennaPodCore

/// Wire metadata used by the pinned Android ApMediaItemConverter. Media identity
/// is separate from the receiver's fetch URL and the sender's local playback URL.
/// Route admission must supply the receiver URL; this codec makes no network request.
@MainActor enum CastMediaItemCodec {
    static let mediaIDKey = "media_id"
    static let localFileURLKey = "local_file_url"
    static let loadIDKey = "org.nottennapod.app.load_id"
    /// The server library a load came from (PROTOCOL §15.4): local IDs repeat across libraries, so a receiver's media
    /// is adopted only by the library that loaded it. Absent for the standalone library, whose loads are unchanged.
    static let libraryIDKey = "org.nottennapod.app.library_id"

    struct Item: Equatable {
        var contentURL: String?
        var mediaID: String?
        var localPlaybackURL: String?
        var title: String?
        var subtitle: String?
        var artworkURL: URL?
        /// A server library's ID; nil for the standalone library.
        var libraryID: String?
    }

    static func encode(_ item: Item, loadID: UUID? = nil) -> GCKMediaQueueItem {
        let metadata = GCKMediaMetadata(metadataType: .generic)
        if let title = item.title { metadata.setString(title, forKey: kGCKMetadataKeyTitle) }
        if let subtitle = item.subtitle { metadata.setString(subtitle, forKey: kGCKMetadataKeySubtitle) }
        if let id = item.mediaID, !id.isEmpty { metadata.setString(id, forKey: mediaIDKey) }
        if let local = item.localPlaybackURL { metadata.setString(local, forKey: localFileURLKey) }
        if let loadID { metadata.setString(loadID.uuidString, forKey: loadIDKey) }
        if let library = item.libraryID, !library.isEmpty { metadata.setString(library, forKey: libraryIDKey) }
        if let artwork = item.artworkURL { metadata.addImage(GCKImage(url: artwork, width: 0, height: 0)) }
        // Android supplies an empty content ID when no stream URL is present. Do
        // not replace it with a downloaded file URI that a receiver cannot fetch.
        let information = GCKMediaInformationBuilder(contentID: item.contentURL ?? "")
        information.metadata = metadata
        let queueItem = GCKMediaQueueItemBuilder()
        queueItem.mediaInformation = information.build()
        // The iOS4.8.6 builder produces false by default at runtime, unlike the
        // Android MediaQueueItem.Builder. The load request separately owns the
        // current item's play/pause intent during a transfer.
        queueItem.autoplay = true
        return queueItem.build()
    }

    static func decode(_ information: GCKMediaInformation?) -> Item {
        guard let information else { return Item() }
        let contentURL = information.contentURL?.absoluteString ?? information.contentID
        let metadata = information.metadata
        return Item(contentURL: contentURL, mediaID: metadata?.string(forKey: mediaIDKey),
                    localPlaybackURL: metadata?.string(forKey: localFileURLKey) ?? contentURL,
                    title: metadata?.string(forKey: kGCKMetadataKeyTitle),
                    subtitle: metadata?.string(forKey: kGCKMetadataKeySubtitle),
                    artworkURL: (metadata?.images().first as? GCKImage)?.url,
                    libraryID: metadata?.string(forKey: libraryIDKey))
    }

    /// Capture this while handling the SDK status callback, before session unload
    /// discards its idle reason. Stopped, interrupted and error are not completion.
    static func hasPlaybackJustFinished(state: GCKMediaPlayerState, idleReason: GCKMediaPlayerIdleReason) -> Bool {
        state == .idle && idleReason == .finished
    }
}

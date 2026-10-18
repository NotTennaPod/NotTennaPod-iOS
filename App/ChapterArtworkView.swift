import UIKit
import NotTennaPodCore

/// Chapter images keep the ordinary cover visible as the cover-page thumbnail.
/// Dialog chapter images use the source placeholder instead of that thumbnail.
@MainActor final class ChapterArtworkView: UIView {
    private let image = UIImageView()
    private let fallback: EpisodeArtworkView?
    private let radius: CGFloat
    /// The picture's load, if one runs (tests wait for it).
    private(set) var request: Task<Void, Never>?

    init(reference: String?, episode: LibraryEpisode, feed: LibraryFeed?, library: FeedLibraryStore,
         access: EpisodeChapterAccess, coverFallback: Bool) {
        radius = coverFallback ? 16 : 4
        fallback = coverFallback || reference?.isEmpty != false ? EpisodeArtworkView(feed:feed,episode:episode,library:library,presentation:coverFallback ? .chapterCover : .chapterRow) : nil
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = coverFallback ? .clear : UIColor(white:191/255,alpha:1)
        if let fallback {
            addSubview(fallback)
            fallback.onArtworkChange = { [weak self] in self?.backgroundColor = .clear }
        }
        image.layer.cornerRadius = radius; image.clipsToBounds = true
        image.contentMode = .scaleAspectFit; addSubview(image)
        guard let reference, !reference.isEmpty else { return }
        // Chapter images go through the shared cover cache, shrunk and decoded off the main thread: the
        // player and the chapters list asked for every image again at full size each time it was shown.
        let pixels = coverFallback ? 1200 : 400
        let embedded = EmbeddedChapterImage(url: reference)
        // A streamed episode's picture is read from the network once for every size it is shown at. It is kept in
        // memory only: nothing proves that a copy kept on disk would still match media replaced at the same address.
        let mediaURL = episode.details.media?.url
        let streamed = embedded != nil && !episode.userState.isDownloaded
            && mediaURL.flatMap(URL.init(string:)).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } == true
        // A picture in a downloaded or folder file is shown from memory at once and read again from the file, which
        // can be replaced at the same path (a new download, a changed folder file).
        let embeddedKey = streamed ? "chapter|\(mediaURL ?? "")|\(episode.details.media?.size ?? 0)|\(reference)"
            : "chapter|\(episode.id)|\(episode.userState.localFileURL ?? "")|\(episode.userState.downloadDate?.timeIntervalSince1970 ?? 0)|\(mediaURL ?? "")|\(episode.details.media?.size ?? 0)|\(reference)"
        if let cached = ArtworkImageCache.image(embedded == nil ? reference : embeddedKey, maxPixels: pixels) {
            show(cached)
            if embedded == nil || streamed { return }
        }
        request = Task { [weak self] in
            do {
                let decoded: UIImage?
                if let embedded, streamed {
                    decoded = await ArtworkImageCache.cachedImage(key: embeddedKey, maxPixels: pixels, persist: false) {
                        // The mobile-updates rules of covers: Android's ChapterImageModelLoader fetches these without the
                        // "Cover images" check, but here they keep the same mobile-data protection as every picture.
                        var budget = MobileImageAccess.byteLimit, restricted = false
                        if let allowance = ArtworkImageCache.fetchAllowance {
                            guard let limit = try await allowance() else { return nil }
                            // Its length is known before any byte is read: over the network's picture limit it waits.
                            guard embedded.length <= limit.bytes else { throw ArtworkTooLarge(restricted: limit.restricted) }
                            budget = limit.bytes; restricted = limit.restricted
                        }
                        do { return try await access.artwork(embedded, episode: episode, budget: budget) }
                        catch is FeedBodyLimitExceeded { throw ArtworkTooLarge(restricted: restricted) }
                    }
                } else if let embedded {
                    guard let bytes = try await access.artwork(embedded, episode: episode) else { return }
                    try Task.checkCancellation()
                    decoded = await ArtworkImageCache.decode(bytes, maxPixels: pixels)
                    if let decoded { ArtworkImageCache.store(decoded, source: embeddedKey, maxPixels: pixels) }
                    else { ArtworkImageCache.remove(source: embeddedKey, maxPixels: pixels) }
                } else if let url = URL(string: reference), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    decoded = await ArtworkImageCache.remoteImage(reference, maxPixels: pixels)
                } else { decoded = nil }
                try Task.checkCancellation()
                guard let decoded else { return }
                self?.show(decoded)
            } catch { /* Source retains thumbnail/placeholder when image loading fails. */ }
        }
    }
    private func show(_ decoded: UIImage) {
        image.image = decoded; fallback?.isHidden = true
        backgroundColor = .clear; layer.cornerRadius = 0; setNeedsLayout()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { request?.cancel() }
    func cancelLoading() { request?.cancel(); request = nil; fallback?.cancelLoading() }
    override func layoutSubviews() { super.layoutSubviews(); fallback?.frame = bounds; image.frame = image.image.map { EpisodeArtworkView.fittedFrame(size:$0.size,in:bounds) } ?? bounds }
}

import UIKit
import NotTennaPodCore

/// Chapter images keep the ordinary cover visible as the cover-page thumbnail.
/// Dialog chapter images use the source placeholder instead of that thumbnail.
@MainActor final class ChapterArtworkView: UIView {
    private let image = UIImageView()
    private let fallback: EpisodeArtworkView?
    private let radius: CGFloat
    private var request: Task<Void, Never>?

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
        let embeddedKey = "chapter|\(episode.id)|\(episode.userState.localFileURL ?? "")|\(episode.details.media?.url ?? "")|\(reference)"
        if let cached = ArtworkImageCache.image(EmbeddedChapterImage(url: reference) == nil ? reference : embeddedKey, maxPixels: pixels) {
            show(cached); return
        }
        request = Task { [weak self] in
            do {
                let decoded: UIImage?
                if let embedded = EmbeddedChapterImage(url: reference) {
                    guard let bytes = try await access.artwork(embedded, episode: episode) else { return }
                    try Task.checkCancellation()
                    decoded = await ArtworkImageCache.decode(bytes, maxPixels: pixels)
                    if let decoded { ArtworkImageCache.store(decoded, source: embeddedKey, maxPixels: pixels) }
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

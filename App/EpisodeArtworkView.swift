import UIKit
import ImageIO
import CryptoKit
import NotTennaPodCore

final class EpisodeArtworkView: UIView {
    enum Presentation { case standard, chapterRow, chapterCover
        var cornerRadius: CGFloat? { switch self { case .standard: nil; case .chapterRow: 4; case .chapterCover: 16 } }
    }
    private let presentation: Presentation
    /// App-owned network policy shared by every screen and notification cover.
    static var remoteLoader: (@MainActor (URL) async throws -> (Data, URLResponse))?
    static func loadRemote(_ url: URL) async throws -> (Data, URLResponse) {
        if let remoteLoader { return try await remoteLoader(url) }
        return try await URLSession.shared.data(from: url)
    }
    /// Also called at once when set after the cover was already shown from the cache.
    var onArtworkChange: (() -> Void)? { didSet { if displayedSource != nil { onArtworkChange?() } } }
    private let maxPixels: Int
    private var model: String?
    /// The image location now shown (primary or fallback); nil while the placeholder shows.
    private(set) var displayedSource: String?
    private let image = UIImageView()
    private let placeholder: UILabel
    private var request: Task<Void, Never>?

    /// `surface` and `useEpisodeCover` pick the image per "Use episode cover"; the defaults are
    /// the episode's own image with the podcast image as fallback.
    convenience init(feed: LibraryFeed?, episode: LibraryEpisode, library: FeedLibraryStore?, presentation: Presentation = .standard,
                     surface: EpisodeCoverSurface = .feedEpisodeList, useEpisodeCover: Bool = true) {
        let reader = library.map(EpisodeArtworkReader.init(store:))
        let folderReader = library.map(LocalFolderArtworkReader.init(store:))
        let cover = EpisodeArtworkSelection.cover(for: surface, episode: episode, feed: feed, useEpisodeCover: useEpisodeCover)
        self.init(source: cover.primary,
                  fallback: presentation == .chapterRow ? nil : cover.fallback, title: feed?.title, presentation:presentation,
                  localArtwork: { try await reader?.read(episode: episode) },
                  folderArtwork: { identity in
                      guard let feed else { return nil }
                      return try await folderReader?.read(feedID: feed.id, identity: identity)
                  })
    }

    init(source: String?, fallback: String?, title: String?, presentation: Presentation = .standard,
         localArtwork: (@Sendable () async throws -> Data?)? = nil,
         folderArtwork: (@Sendable (String) async throws -> Data?)? = nil) {
        self.presentation = presentation
        // Tiles and rows are at most ~130 pt wide (about 400 px); the full player cover needs more.
        maxPixels = presentation == .chapterCover ? 1200 : 400
        placeholder = Appearance.label(title, size: 14)
        super.init(frame: .zero)
        backgroundColor = presentation == .chapterCover ? .clear : UIColor(white:191/255,alpha:1)
        placeholder.isHidden = presentation != .standard
        image.layer.cornerRadius = presentation.cornerRadius ?? 0
        image.clipsToBounds = presentation != .standard
        placeholder.textAlignment = .center
        placeholder.numberOfLines = 3
        placeholder.lineBreakMode = .byTruncatingTail
        image.contentMode = .scaleAspectFit
        addSubview(placeholder)
        addSubview(image)
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: EpisodeArtworkView, _: UITraitCollection) in view.setNeedsLayout() }
        if let first = [source, fallback].compactMap({ $0 }).first, let cached = ArtworkImageCache.image(first, maxPixels: maxPixels) {
            image.image = cached; placeholder.isHidden = true; displayedSource = first
            if presentation != .standard { backgroundColor = .clear }
            return
        }
        let pixels = maxPixels
        request = Task { [weak self] in
            for value in [source, fallback].compactMap({ $0 }) {
                if Task.isCancelled { return }
                if value.hasPrefix(EpisodeArtworkSelection.embeddedPrefix) {
                    do {
                        guard let bytes = try await localArtwork?() else { continue }
                        try Task.checkCancellation()
                        guard let decoded = await ArtworkImageCache.decode(bytes, maxPixels: pixels) else { continue }
                        try Task.checkCancellation()
                        self?.image.image = decoded
                        self?.placeholder.isHidden = true
                        self?.artworkLoaded(value)
                        return
                    } catch is CancellationError { return }
                    catch { continue }
                }
                if value.hasPrefix(GenerativeCoverPattern.artworkPrefix) {
                    self?.model = value
                    self?.placeholder.isHidden = true
                    self?.artworkLoaded(value)
                    return
                }
                guard let url = URL(string: value) else { continue }
                if url.isFileURL {
                    do {
                        guard let bytes = try await folderArtwork?(value) else { continue }
                        try Task.checkCancellation()
                        guard let decoded = await ArtworkImageCache.decode(bytes, maxPixels: pixels) else { continue }
                        try Task.checkCancellation()
                        self?.image.image = decoded
                        self?.placeholder.isHidden = true
                        self?.artworkLoaded(value)
                        return
                    } catch is CancellationError { return }
                    catch { continue }
                }
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                let loaded = await ArtworkImageCache.remoteImage(value, maxPixels: pixels)
                if Task.isCancelled { return }
                guard let loaded else { continue }
                self?.image.image = loaded
                self?.placeholder.isHidden = true
                self?.artworkLoaded(value)
                return
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { request?.cancel() }
    func cancelLoading() { request?.cancel(); request = nil }
    private func artworkLoaded(_ source: String) {
        displayedSource = source
        if presentation != .standard { backgroundColor = .clear }
        setNeedsLayout(); onArtworkChange?()
    }
    static func fittedFrame(size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width/size.width,bounds.height/size.height)
        let fitted = CGSize(width:size.width*scale,height:size.height*scale)
        return CGRect(x:bounds.midX-fitted.width/2,y:bounds.midY-fitted.height/2,width:fitted.width,height:fitted.height)
    }
    /// A generated cover is drawn once per size into the image view: overriding `draw(_:)` gave every
    /// cover view, photo or not, its own bitmap and a drawing pass after each layout.
    private var generatedSize: (CGSize, CGFloat)?
    override func layoutSubviews() {
        super.layoutSubviews()
        if let model {
            let scale = traitCollection.displayScale
            if generatedSize.map({ $0.0 != bounds.size || $0.1 != scale }) ?? true {
                generatedSize = (bounds.size, scale)
                image.image = bounds.width > 0 && bounds.height > 0 ? Self.generatedImage(model: model, size: bounds.size, scale: scale) : nil
            }
        }
        image.frame = presentation != .standard && image.image != nil ? Self.fittedFrame(size:image.image!.size,in:bounds) : bounds
        placeholder.frame = bounds.insetBy(dx: 2, dy: 2)
    }
    private static func generatedImage(model: String, size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            drawPattern(model: model, context: renderer.cgContext, size: size, scale: scale)
        }
    }
    func artwork(size: CGSize, scale: CGFloat) -> UIImage? {
        if let model {
            guard size.width > 0, size.height > 0 else { return nil }
            return Self.generatedImage(model: model, size: size, scale: scale)
        }
        return image.image
    }
    static func drawPattern(model: String, context: CGContext, size: CGSize, scale: CGFloat) {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0 else { return }
        let pattern = GenerativeCoverPattern(model: model, width: width, height: height)
        context.saveGState()
        context.scaleBy(x: 1 / scale, y: 1 / scale)
        context.setShouldAntialias(false)
        for line in pattern.lines {
            func channel(_ shift: UInt32) -> CGFloat {
                let grey = CGFloat((line.color >> shift) & 255) / 255
                return line.tint == 0 ? grey : grey * CGFloat((line.tint >> shift) & 255) / 255
            }
            context.setStrokeColor(UIColor(red: channel(16), green: channel(8), blue: channel(0), alpha: 1).cgColor)
            context.setLineWidth(CGFloat(line.width))
            context.setLineCap(.butt)
            context.move(to: CGPoint(x: CGFloat(line.x1), y: CGFloat(line.y1)))
            context.addLine(to: CGPoint(x: CGFloat(line.x2), y: CGFloat(line.y2)))
            context.strokePath()
        }
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor.clear.cgColor, UIColor(white: 0, alpha: 85.0 / 255).cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: CGFloat(height)), options: [])
        }
        context.restoreGState()
    }
}

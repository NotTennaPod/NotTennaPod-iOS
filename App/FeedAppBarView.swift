import UIKit
import NotTennaPodCore

/// Source app-bar layers. The scroll owner supplies its offset; header and
/// artwork parallax are independent of the body and pinned toolbar.
@MainActor
final class FeedAppBarView: UIView {
    let header: SubscribedFeedHeaderView
    private let background = UIImageView()
    private var renderTask: Task<Void, Never>?
    private var renderID = UUID()
    private var renderedSize = CGSize.zero
    private let tint: UInt32
    var toolbarHeight: CGFloat = 56
    var fullHeaderHeight: CGFloat = 156
    var collapse: CGFloat = 0
    init(header: SubscribedFeedHeaderView, information: Bool) {
        self.header = header; tint = information ? 130 : 102
        super.init(frame: .zero)
        accessibilityIdentifier = "feedAppBar"
        clipsToBounds = true
        background.accessibilityIdentifier = "feedBackground"
        background.backgroundColor = UIColor.black.withAlphaComponent(128 / 255)
        background.contentMode = .scaleToFill
        addSubview(background); addSubview(header)
        header.onArtworkChange = { [weak self] in self?.renderArtwork() }
        registerForTraitChanges([UITraitDisplayScale.self]) { (bar: FeedAppBarView, _) in bar.renderArtwork() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { renderTask?.cancel() }
    func waitForArtwork() async { await renderTask?.value }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Child parallax multipliers are .6 for artwork and the Material
        // default .5 for the included header. Parent translation is -collapse.
        let height = toolbarHeight + fullHeaderHeight
        background.frame = CGRect(x: 0, y: -collapse * 0.4, width: bounds.width, height: height)
        header.frame = CGRect(x: 0, y: toolbarHeight - collapse * 0.5, width: bounds.width, height: fullHeaderHeight)
        let size = CGSize(width: bounds.width, height: height)
        if renderedSize != size { renderedSize = size; renderArtwork() }
    }
    /// Finished header backgrounds by cover, size and tint: every redraw of a podcast page builds a
    /// new bar, and blurring again took 120–280 ms and showed the dark placeholder until it finished.
    /// Only covers whose location fixes their pixels are kept (web covers, as `ArtworkImageCache`, and
    /// generated covers); local-folder and embedded covers can change on disk.
    private static let blurred: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 8; cache.totalCostLimit = 32 * 1024 * 1024; return cache
    }()
    private func blurKey(width: Int, height: Int, scale: CGFloat) -> NSString? {
        guard let source = header.artworkSource,
              source.hasPrefix("https://") || source.hasPrefix("http://") || source.hasPrefix(GenerativeCoverPattern.artworkPrefix)
        else { return nil }
        return "\(width)x\(height)@\(scale)|\(tint)|\(source)" as NSString
    }
    private func renderArtwork() {
        renderTask?.cancel()
        let request = UUID(); renderID = request
        let size = CGSize(width: bounds.width, height: toolbarHeight + fullHeaderHeight)
        let scale = traitCollection.displayScale
        let width = max(1, Int(size.width * scale) / 2)
        let height = max(1, Int(size.height * scale) * width / max(1, Int(size.width * scale)))
        let key = size.width > 0 && size.height > 0 ? blurKey(width: width, height: height, scale: scale) : nil
        if let key, let cached = Self.blurred.object(forKey: key) {
            background.backgroundColor = UIColor.black.withAlphaComponent(128 / 255)
            background.image = cached; renderTask = nil
            return
        }
        guard let image = header.artwork(size: size, scale: scale), let input = image.cgImage,
              size.width > 0, size.height > 0 else {
            background.image = nil
            // The source ImageView background and missing-image placeholder
            // both use #80000000; preserve their combined opacity.
            background.backgroundColor = UIColor.black.withAlphaComponent(1 - pow(127.0 / 255, 2))
            return
        }
        background.backgroundColor = UIColor.black.withAlphaComponent(128 / 255)
        let tint = tint
        renderTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                FeedBackgroundRenderer.render(input, width: width, height: height, tint: tint)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, renderID == request else { return }
            let finished = result.map { UIImage(cgImage: $0) }
            if let key, let finished { Self.blurred.setObject(finished, forKey: key, cost: width * height * 4) }
            background.image = finished
        }
    }
}

/// Core Graphics performs source-size rasterization; pure Swift performs the
/// independently verified blur. No UIKit work runs on the render worker.
nonisolated enum FeedBackgroundRenderer {
    static func render(_ source: CGImage, width: Int, height: Int, tint: UInt32) -> CGImage? {
        guard width > 0, height > 0, width <= 8192, height <= 8192, !Task.isCancelled else { return nil }
        let count = width * height
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: bitmap) else { return false }
            context.interpolationQuality = .none
            // Preserve FastBlurTransformation's actual source rectangle. Its
            // non-square artwork behavior needs runtime evidence before change.
            let drawnHeight = width * source.width / max(1, source.height)
            context.draw(source, in: CGRect(x: 0, y: height - drawnHeight, width: width, height: drawnHeight))
            return true
        }
        guard drawn, !Task.isCancelled else { return nil }
        var pixels = [UInt32](repeating: 0, count: count)
        for index in 0..<count {
            let offset = index * 4, alpha = UInt32(bytes[offset + 3])
            func channel(_ n: Int) -> UInt32 { alpha == 0 ? 0 : min(255, UInt32(bytes[offset + n]) * 255 / alpha) }
            pixels[index] = channel(0) << 16 | channel(1) << 8 | channel(2)
        }
        guard let blurred = FeedArtworkBlur.apply(pixels, width: width, height: height), !Task.isCancelled else { return nil }
        for (index, pixel) in blurred.enumerated() {
            let offset = index * 4
            bytes[offset] = UInt8(((pixel >> 16) & 255) * tint / 255)
            bytes[offset + 1] = UInt8(((pixel >> 8) & 255) * tint / 255)
            bytes[offset + 2] = UInt8((pixel & 255) * tint / 255)
            bytes[offset + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmap), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }
}

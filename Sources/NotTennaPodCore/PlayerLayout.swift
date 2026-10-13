import CoreGraphics

public struct PlayerLayout: Equatable, Sendable {
    public let toolbar: CGRect
    public let pager: CGRect
    public let artwork: CGRect
    public let podcast: CGRect
    public let title: CGRect
    public let shownotes: CGRect
    public let chapterControl: CGRect?
    public let seek: CGRect
    public let times: CGRect
    public let play: CGRect
    public let rewind: CGRect
    public let forward: CGRect
    public let speed: CGRect
    public let skip: CGRect

    public init(size: CGSize, topInset: CGFloat, podcastHeight: CGFloat, titleHeight: CGFloat,
                timeHeight: CGFloat, scale: CGFloat = 1,
                hasChapters: Bool = false, rightToLeft: Bool = false) {
        let scale = max(1, scale)
        func dp(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let width = max(0, size.width), height = max(0, size.height)
        toolbar = CGRect(x: 0, y: max(0, topInset), width: width, height: dp(64))
        let controlsY = height - dp(24) - dp(64)
        play = CGRect(x: (width - dp(64)) / 2, y: controlsY, width: dp(64), height: dp(64))
        let smallY = controlsY + dp(8)
        rewind = CGRect(x: play.minX - dp(12) - dp(48), y: smallY, width: dp(48), height: dp(48))
        forward = CGRect(x: play.maxX + dp(12), y: smallY, width: dp(48), height: dp(48))
        speed = rewind.offsetBy(dx: -dp(12) - dp(48), dy: 0)
        skip = forward.offsetBy(dx: dp(12) + dp(48), dy: 0)
        times = CGRect(x: dp(24), y: controlsY - dp(4) - timeHeight, width: max(0, width - 2 * dp(24)), height: max(0, timeHeight))
        seek = CGRect(x: dp(8), y: times.minY - dp(4) - dp(18), width: max(0, width - 2 * dp(8)), height: dp(18))
        pager = CGRect(x: 0, y: toolbar.maxY, width: width, height: max(0, seek.minY - dp(12) - toolbar.maxY))
        let content = CGRect(x: dp(8), y: dp(8), width: max(0, width - 2 * dp(8)),
                             height: max(0, pager.height - 2 * dp(8)))
        let podcastHeight = max(0, podcastHeight), titleHeight = max(0, titleHeight)
        let textColumn: CGRect
        let holder: CGRect
        let buttonsY: CGFloat
        if width > height {
            // CoverFragment places equal-weight artwork/text columns side by
            // side, with the details row inside the centered text column.
            let columnWidth = content.width / 2
            textColumn = CGRect(x: rightToLeft ? content.minX : content.minX + columnWidth,
                                y: content.minY, width: columnWidth, height: content.height)
            holder = CGRect(x: rightToLeft ? content.minX + columnWidth : content.minX,
                            y: content.minY, width: columnWidth, height: content.height)
            let groupHeight = podcastHeight + titleHeight + dp(32) + dp(36)
            buttonsY = textColumn.midY + groupHeight / 2 - dp(36)
        } else {
            textColumn = content
            buttonsY = max(content.minY, content.maxY - dp(36))
            let holderBottom = buttonsY - dp(32) - titleHeight - podcastHeight
            holder = CGRect(x: content.minX, y: content.minY, width: content.width,
                            height: max(0, holderBottom - content.minY))
        }
        // Each group has 8dp horizontal margins inside the row's 8dp padding.
        // The source's weighted groups can shrink when the available column
        // cannot accommodate both nominal 150dp widths.
        let gap = hasChapters ? dp(16) : 0
        let count: CGFloat = hasChapters ? 2 : 1
        let groupWidth = min(dp(150), max(0, (textColumn.width - dp(32) - gap) / count))
        let totalWidth = count * groupWidth + gap
        let leadingX = textColumn.midX - totalWidth / 2
        let trailingX = leadingX + groupWidth + gap
        shownotes = CGRect(x: hasChapters && rightToLeft ? trailingX : leadingX,
                           y: buttonsY, width: groupWidth, height: dp(36))
        chapterControl = hasChapters ? CGRect(x: rightToLeft ? leadingX : trailingX,
                                             y: buttonsY, width: groupWidth, height: dp(36)) : nil
        // configureForOrientation replaces the XML text-container parameters,
        // removing its vertical margins. Only the title's 32dp margin remains.
        title = CGRect(x: textColumn.minX, y: buttonsY - dp(32) - titleHeight,
                       width: textColumn.width, height: titleHeight)
        podcast = CGRect(x: textColumn.minX, y: title.minY - podcastHeight,
                         width: textColumn.width, height: podcastHeight)
        let side = max(0, min(holder.width - dp(64), holder.height))
        artwork = CGRect(x: holder.midX - side / 2, y: holder.midY - side / 2, width: side, height: side)
    }
}

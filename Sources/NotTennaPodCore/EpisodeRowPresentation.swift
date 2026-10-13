import Foundation
import Synchronization

public struct EpisodeRowPresentation: Equatable, Sendable {
    public enum Indicator: String, Equatable, Sendable { case inbox, video, favorite, queue }
    public enum Action: Equatable, Sendable { case markPlayed, pause, playLocal, play, cancelDownload, stream, download }

    public let indicators: [Indicator]
    public let opacity: Double
    public let action: Action
    public let actionVisible: Bool
    public let activated: Bool
    public let duration: String?
    public let position: String?
    public let progressPercent: Int?
    public let downloadProgress: Float
    public let downloadIndeterminate: Bool

    public init(episode: LibraryEpisode, inQueue: Bool = false, queueScreen: Bool = false,
                currentlyPlaying: Bool = false, activelyPlaying: Bool = false, localFeed: Bool = false,
                downloading: Bool = false, queuedDownload: Bool = false, downloadPercent: Int = 0,
                streamOverDownload: Bool = false, showRemainingTime: Bool = false, locale: Locale = .current) {
        var indicators: [Indicator] = []
        if episode.userState.playState == .new { indicators.append(.inbox) }
        if episode.details.media?.mimeType?.hasPrefix("video") == true { indicators.append(.video) }
        if episode.userState.isFavorite { indicators.append(.favorite) }
        if inQueue && !queueScreen { indicators.append(.queue) }
        self.indicators = indicators
        opacity = episode.userState.playState == .played ? 0.5 : 1
        guard let media = episode.details.media else {
            action = .markPlayed
            actionVisible = episode.userState.playState != .played
            activated = false
            duration = nil
            position = nil
            progressPercent = nil
            downloadProgress = 0
            downloadIndeterminate = false
            return
        }
        activated = currentlyPlaying
        actionVisible = true
        if currentlyPlaying { action = .pause }
        else if localFeed { action = .playLocal }
        else if episode.userState.isDownloaded { action = .play }
        else if downloading { action = .cancelDownload }
        else { action = streamOverDownload ? .stream : .download }
        downloadProgress = downloading ? max(Float(downloadPercent) * 0.01, 0.01) : (episode.userState.isDownloaded ? 1 : 0)
        downloadIndeterminate = downloading && queuedDownload
        let inProgress = activelyPlaying || episode.userState.positionMilliseconds > 0
        if inProgress {
            position = Self.time(episode.userState.positionMilliseconds, locale: locale)
            let percent = 100 * Double(episode.userState.positionMilliseconds) / Double(media.durationMilliseconds)
            progressPercent = percent.isNaN ? 0 : Int(min(100, max(0, percent)))
        } else { position = nil; progressPercent = nil }
        if media.durationMilliseconds > 0 {
            let remaining = max(media.durationMilliseconds &- episode.userState.positionMilliseconds, 0)
            duration = inProgress && showRemainingTime
                ? (remaining > 0 ? "-" : "") + Self.time(remaining, locale: locale)
                : Self.time(media.durationMilliseconds, locale: locale)
        } else { duration = nil }
    }

    /// Formatters are configured once per locale and form (creating a date formatter for every
    /// row was a fifth of a row's cost in long lists). Formatting with a configured formatter is thread-safe.
    private static let formatters = Mutex<[String: Formatter]>([:])
    private static func formatter<F: Formatter>(_ key: String, _ make: () -> F) -> F {
        formatters.withLock { cache in
            if let cached = cache[key] as? F { return cached }
            let created = make()
            cache[key] = created
            return created
        }
    }

    public static func time(_ milliseconds: Int32, locale: Locale = .current) -> String {
        guard milliseconds > 0 else { return "00:00:00" }
        let seconds = Int(milliseconds / 1_000)
        let formatter = formatter("time|\(locale.identifier)") { () -> NumberFormatter in
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.minimumIntegerDigits = 2
            formatter.maximumFractionDigits = 0
            return formatter
        }
        return [seconds / 3_600, (seconds / 60) % 60, seconds % 60]
            .map { formatter.string(from: NSNumber(value: $0)) ?? String($0) }.joined(separator: ":")
    }

    public static func publicationDate(_ date: Date?, now: Date = Date(), locale: Locale = .current,
                                       timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let template = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMd" : "yMMMd"
        let formatter = formatter("date|\(locale.identifier)|\(timeZone.identifier)|\(template)") { () -> DateFormatter in
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        return formatter.string(from: date)
    }

    public static func fileSize(_ bytes: Int64, locale: Locale = .current) -> String {
        guard bytes > 0 else { return "" }
        var amount = Float(bytes)
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        var index = 0
        while amount > 900 && index < units.count - 1 { amount /= 1_000; index += 1 }
        let digits = index == 0 || amount >= 10 ? 0 : (amount < 1 ? 2 : 1)
        let formatter = formatter("size|\(locale.identifier)|\(digits)") { () -> NumberFormatter in
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
            formatter.roundingMode = .halfUp
            return formatter
        }
        return (formatter.string(from: NSNumber(value: amount)) ?? String(amount)) + " " + units[index]
    }
}

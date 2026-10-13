import Foundation

/// The original prefMobileUpdateTypes set. Unknown members survive individual edits.
@MainActor
public final class MobileNetworkPreferenceStore {
    public enum Use: String, CaseIterable, Sendable {
        case images, streaming, feedRefresh = "feed_refresh", sync
        case episodeDownload = "episode_download", autoDownload = "auto_download"
    }

    public private(set) var allowed: Set<String>
    private let file: URL
    private var hasStoredValue: Bool
    public var onChange: (() -> Void)?

    public init(file: URL) throws {
        self.file = file
        let data = try SavedState.contents(of: file)
        hasStoredValue = data != nil
        allowed = try data.map { try JSONDecoder().decode(Set<String>.self, from: $0) } ?? [Use.images.rawValue]
    }

    /// Downloads XML initializes this distinct first-entry default only if unset.
    public func initializeSettingsDefaults() throws {
        if !hasStoredValue { try updateAllowed([Use.images.rawValue, Use.sync.rawValue]) }
    }

    /// A confirmed source multi-choice dialog replaces the set; individual edits preserve unknown members.
    public func updateAllowed(_ values: Set<String>) throws {
        try JSONEncoder().encode(values.sorted()).write(to: file, options: .atomic)
        allowed = values; hasStoredValue = true; onChange?()
    }

    public func allows(_ use: Use) -> Bool { allowed.contains(use.rawValue) }

    public func setAllowed(_ use: Use, _ enabled: Bool) throws {
        var changed = allowed
        if enabled { changed.insert(use.rawValue) } else { changed.remove(use.rawValue) }
        try updateAllowed(changed)
    }
}

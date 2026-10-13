import Foundation

@MainActor
public final class DownloadPreferenceStore {
    public private(set) var value: DownloadPreferences
    private let file: URL
    public var onRefreshIntervalChange: (() -> Void)?

    public init(file: URL) throws {
        self.file = file
        if let data = try SavedState.contents(of: file) {
            value = try JSONDecoder().decode(DownloadPreferences.self, from: data)
        } else { value = DownloadPreferences() }
    }

    public func update(_ value: DownloadPreferences) throws {
        let changed = self.value.refreshIntervalMinutes != value.refreshIntervalMinutes
        let data = try JSONEncoder().encode(value)
        try data.write(to: file, options: .atomic)
        self.value = value
        if changed { onRefreshIntervalChange?() }
    }
}

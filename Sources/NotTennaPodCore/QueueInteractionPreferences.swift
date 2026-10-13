import Foundation

public struct QueueInteractionPreferences: Codable, Equatable, Sendable {
    public var locked: Bool
    public var showLockWarning: Bool
    /// `prefQueueKeepSorted` (default off).
    public var keepSorted: Bool
    /// `prefQueueKeepSortedOrder`: the Android enum name, saved on every Sort-sheet tap even while
    /// Keep sorted is off. Read through `keepSortedOrder` (missing or unknown → `DATE_NEW_OLD`).
    public var keepSortedOrderName: String?
    public init(locked: Bool = false, showLockWarning: Bool = true, keepSorted: Bool = false, keepSortedOrderName: String? = nil) {
        self.locked = locked; self.showLockWarning = showLockWarning
        self.keepSorted = keepSorted; self.keepSortedOrderName = keepSortedOrderName
    }
    public var keepSortedOrder: QueueSortOrder { QueueSortOrder(storedValue: keepSortedOrderName) }
    /// The order automatic re-sorting uses, or nil while Keep sorted is off.
    public var activeKeepSortedOrder: QueueSortOrder? { keepSorted ? keepSortedOrder : nil }
    private enum CodingKeys: String, CodingKey { case locked, showLockWarning, keepSorted, keepSortedOrderName }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        locked = try values.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        showLockWarning = try values.decodeIfPresent(Bool.self, forKey: .showLockWarning) ?? true
        keepSorted = try values.decodeIfPresent(Bool.self, forKey: .keepSorted) ?? false
        keepSortedOrderName = try values.decodeIfPresent(String.self, forKey: .keepSortedOrderName)
    }
}

@MainActor public final class QueueInteractionPreferenceStore: JSONPreferenceStore<QueueInteractionPreferences> {
    public init(file: URL) throws { try super.init(file: file, defaultValue: .init()) }
    public func confirmLock(doNotShowAgain: Bool) throws {
        var next = value; next.locked = true; next.showLockWarning = !doNotShowAgain; try update(next)
    }
    public func toggleWithoutWarning() throws {
        var next = value; next.locked.toggle(); try update(next)
    }
    /// `QueueSortDialog.onSelectionChanged`: both values are saved on every change.
    public func setKeepSorted(_ keepSorted: Bool, order: QueueSortOrder) throws {
        var next = value; next.keepSorted = keepSorted; next.keepSortedOrderName = order.rawValue; try update(next)
    }
}

public extension QueueInsertionSettings {
    /// The library's insertion settings from the stored preferences (absent stores read as defaults).
    init(download: DownloadPreferences?, queue: QueueInteractionPreferences?, locale: Locale = .current) {
        self.init(location: download?.enqueueLocation ?? .back, keepSortedOrder: queue?.activeKeepSortedOrder, locale: locale)
    }
}

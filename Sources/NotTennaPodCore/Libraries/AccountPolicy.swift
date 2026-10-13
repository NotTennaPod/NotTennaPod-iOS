import Foundation

/// Where the account-level policies are kept (PROTOCOL §15.4, §7.2, §7.5).
@MainActor public protocol AccountPolicyBacking: AnyObject {
    /// The global "new episodes" action; nil when it was never chosen.
    var newEpisodesAction: NewEpisodesAction? { get }
    var enqueueLocation: EnqueueLocation { get }
    var keepSorted: Bool { get }
    /// The stored Keep sorted order, saved even while Keep sorted is off.
    var keepSortedOrder: QueueSortOrder { get }
    func setNewEpisodesAction(_ action: NewEpisodesAction) throws
    func setEnqueueLocation(_ location: EnqueueLocation) throws
    func setKeepSorted(_ keepSorted: Bool, order: QueueSortOrder) throws
}

public enum AccountPolicyError: Error, Equatable, Sendable { case unavailable }

/// The account-level policies: the global "new episodes" action, the enqueue location, and Keep sorted with its
/// order. The screens and the library graph read and write them only through this facade, so the same screens
/// show the same wording whichever library is open; only the source changes.
///
/// The standalone library's source is today's JSON values (`DownloadPreferences.newEpisodesAction` and
/// `.enqueueLocation`, `QueueInteractionPreferences.keepSorted` and `.keepSortedOrderName`), read and written
/// exactly as before. A server library's source (its account records with its pending local changes, writes
/// recorded as `account.set_discovery_policy` and `account.set_queue_policy`) is another `AccountPolicyBacking`;
/// it never touches those JSON values.
@MainActor public final class AccountPolicy {
    public let backing: any AccountPolicyBacking

    public init(backing: any AccountPolicyBacking) { self.backing = backing }

    /// The standalone library's policies, in the download and queue-interaction preference files. A missing store
    /// reads as the defaults and cannot be changed.
    public static func standalone(download: DownloadPreferenceStore?, queue: QueueInteractionPreferenceStore?) -> AccountPolicy {
        AccountPolicy(backing: StandaloneAccountPolicy(download: download, queue: queue))
    }

    /// A server library before its account records are kept on the device (they arrive with recording and
    /// exchange): the defaults, and no changes. It never reads or writes the standalone library's preference files.
    public static func awaitingAccountRecords() -> AccountPolicy {
        AccountPolicy(backing: StandaloneAccountPolicy(download: nil, queue: nil))
    }

    /// The global "new episodes" action, Inbox until one is chosen.
    public var newEpisodesAction: NewEpisodesAction { backing.newEpisodesAction ?? .inbox }
    public var enqueueLocation: EnqueueLocation { backing.enqueueLocation }
    public var keepSorted: Bool { backing.keepSorted }
    public var keepSortedOrder: QueueSortOrder { backing.keepSortedOrder }
    /// The order automatic re-sorting uses, or nil while Keep sorted is off.
    public var activeKeepSortedOrder: QueueSortOrder? { keepSorted ? keepSortedOrder : nil }
    /// Where the library places every addition to the queue.
    public func queueInsertionSettings(locale: Locale = .current) -> QueueInsertionSettings {
        QueueInsertionSettings(location: enqueueLocation, keepSortedOrder: activeKeepSortedOrder, locale: locale)
    }

    public func setNewEpisodesAction(_ action: NewEpisodesAction) throws { try backing.setNewEpisodesAction(action) }
    public func setEnqueueLocation(_ location: EnqueueLocation) throws { try backing.setEnqueueLocation(location) }
    /// Both values are saved on every change (`QueueSortDialog.onSelectionChanged`).
    public func setKeepSorted(_ keepSorted: Bool, order: QueueSortOrder) throws { try backing.setKeepSorted(keepSorted, order: order) }
}

/// The standalone library's account-level policies: today's preference files, unchanged.
@MainActor public final class StandaloneAccountPolicy: AccountPolicyBacking {
    private let download: DownloadPreferenceStore?
    private let queue: QueueInteractionPreferenceStore?

    public init(download: DownloadPreferenceStore?, queue: QueueInteractionPreferenceStore?) {
        self.download = download; self.queue = queue
    }

    public var newEpisodesAction: NewEpisodesAction? { download?.value.newEpisodesAction }
    public var enqueueLocation: EnqueueLocation { download?.value.enqueueLocation ?? .back }
    public var keepSorted: Bool { queue?.value.keepSorted ?? false }
    public var keepSortedOrder: QueueSortOrder { queue?.value.keepSortedOrder ?? QueueSortOrder(storedValue: nil) }

    public func setNewEpisodesAction(_ action: NewEpisodesAction) throws {
        guard let download else { throw AccountPolicyError.unavailable }
        var value = download.value; value.newEpisodesAction = action; try download.update(value)
    }

    public func setEnqueueLocation(_ location: EnqueueLocation) throws {
        guard let download else { throw AccountPolicyError.unavailable }
        var value = download.value; value.enqueueLocation = location; try download.update(value)
    }

    public func setKeepSorted(_ keepSorted: Bool, order: QueueSortOrder) throws {
        guard let queue else { throw AccountPolicyError.unavailable }
        try queue.setKeepSorted(keepSorted, order: order)
    }
}

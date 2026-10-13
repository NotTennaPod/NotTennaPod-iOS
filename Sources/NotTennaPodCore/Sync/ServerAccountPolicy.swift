import Foundation

/// A server library's account-level policies behind the `AccountPolicy` facade (PROTOCOL §15.4): the
/// account records with this library's pending changes, read once and kept in memory for the screens. A change
/// shows at once and is recorded through the store (`account.set_discovery_policy`, `account.set_queue_policy`)
/// in order; a change the store refuses is reverted to what the store holds. It never touches the standalone
/// library's preference files. The library graph uses it for a server library.
@MainActor public final class ServerAccountPolicyBacking: AccountPolicyBacking {
    private let store: FeedLibraryStore
    private var values: ServerAccountPolicyValues
    private var writes: Task<Void, Never>?
    /// The last change the store refused, if any.
    public private(set) var lastError: (any Error)?

    public init(store: FeedLibraryStore, values: ServerAccountPolicyValues) {
        self.store = store; self.values = values
    }

    /// The policies of the store's server library.
    public static func load(store: FeedLibraryStore) async throws -> ServerAccountPolicyBacking {
        guard let values = try await store.serverAccountPolicies() else { throw ServerRecordingError.notAServerLibrary }
        return ServerAccountPolicyBacking(store: store, values: values)
    }

    public var newEpisodesAction: NewEpisodesAction? { values.newEpisodesAction }
    public var enqueueLocation: EnqueueLocation { values.enqueueLocation }
    public var keepSorted: Bool { values.keepSorted }
    public var keepSortedOrder: QueueSortOrder { values.keepSortedOrder }

    public func setNewEpisodesAction(_ action: NewEpisodesAction) throws {
        values.newEpisodesAction = action
        record(.newEpisodesAction(action))
    }

    public func setEnqueueLocation(_ location: EnqueueLocation) throws {
        values.enqueueLocation = location
        record(.enqueueLocation(location))
    }

    /// `random` turns Keep sorted off, as Android does (PROTOCOL §7.6).
    public func setKeepSorted(_ keepSorted: Bool, order: QueueSortOrder) throws {
        values.keepSorted = keepSorted && order != .random
        values.keepSortedOrder = order
        record(.sorting(keepSorted: keepSorted, order: order))
    }

    /// Returns once every change made so far has been recorded or reverted.
    public func settle() async { await writes?.value }

    /// The account's records changed (another device, or Force full synchronization): the values are read again,
    /// after this device's own changes in flight (they show through their pending overlays).
    public func reload() async {
        await settle()
        if let current = try? await store.serverAccountPolicies() { values = current }
    }

    private func record(_ change: ServerAccountPolicyChange) {
        let previous = writes, store = store
        writes = Task { [weak self] in
            await previous?.value
            do { try await store.setServerAccountPolicy(change) }
            catch { await self?.revert(after: error) }
        }
    }

    private func revert(after error: any Error) async {
        lastError = error
        if let current = try? await store.serverAccountPolicies() { values = current }
    }
}

extension ServerAccountPolicyValues {
    /// A server library's policies read through its own read-only connection, for the library graph to build the
    /// facade before anything uses it. Nil for a standalone library or one that cannot be read.
    public static func read(database url: URL) -> ServerAccountPolicyValues? {
        guard let connection = try? LibrarySQLite(readingOnly: url) else { return nil }
        defer { try? connection.close() }
        return try? connection.transaction(write: false) {
            guard let account = try connection.rows("SELECT account_id FROM ntp_library WHERE id = 1").first?.first?.text else { return nil }
            return try read(connection, accountID: account)
        }
    }

    /// The account records with this library's pending changes (the latest pending value of each property).
    static func read(_ database: LibrarySQLite, accountID: String) throws -> ServerAccountPolicyValues {
        var values = ServerAccountPolicyValues()
        func record(_ group: String) throws -> ContractJSON? {
            // A record a recovery holds as this library had it is read in place of the base.
            if let held = (try? database.rows("SELECT value FROM ntp_recovery_holds WHERE entity = 'account' AND id = ? AND field_group = ?",
                                              [.text(accountID), .text(group)]))?.first {
                return try held[0].data.map { try ContractJSON.decode($0) }
            }
            guard let row = try database.rows("SELECT value FROM ntp_records WHERE entity = 'account' AND id = ? AND field_group = ?",
                                              [.text(accountID), .text(group)]).first, let data = row[0].data else { return nil }
            return try ContractJSON.decode(data)
        }
        var properties: [String: ContractJSON] = [:]
        if let discovery = try record("discovery_policy") { properties["new_episodes_action"] = discovery["new_episodes_action"] }
        if let queue = try record("queue_policy") {
            properties["enqueue_location"] = queue["enqueue_location"]
            if let keep = queue["keep_sorted"], let order = queue["sort_order"] { properties["sorting"] = ["keep_sorted": keep, "sort_order": order] }
        }
        for row in try database.rows("SELECT property, value FROM ntp_overlays WHERE entity = 'account' AND id = ? AND kind = 'register' ORDER BY clock",
                                     [.text(accountID)]) {
            guard case .text(let property) = row[0], let data = row[1].data else { continue }
            properties[property] = try ContractJSON.decode(data)
        }
        switch properties["new_episodes_action"]?.stringValue {
        case "inbox": values.newEpisodesAction = .inbox
        case "queue": values.newEpisodesAction = .queue
        case "nothing": values.newEpisodesAction = .nothing
        default: break
        }
        switch properties["enqueue_location"]?.stringValue {
        case "front": values.enqueueLocation = .front
        case "after_current": values.enqueueLocation = .afterCurrentlyPlaying
        case "random": values.enqueueLocation = .random
        default: values.enqueueLocation = .back
        }
        if let sorting = properties["sorting"] {
            values.keepSorted = sorting["keep_sorted"]?.boolValue ?? false
            values.keepSortedOrder = QueueSortOrder(storedValue: sorting["sort_order"]?.stringValue?.uppercased())
        }
        return values
    }
}

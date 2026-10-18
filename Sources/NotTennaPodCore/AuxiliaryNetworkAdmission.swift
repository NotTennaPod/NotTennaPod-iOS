import Foundation
import Synchronization

/// Whether a remote fetch of auxiliary content (a transcript, chapter JSON, a streamed episode's chapter list) may run
/// on the current network, mapped to the Mobile updates options, and the most bytes it may take. Local and cached
/// content never asks. Android's own transcript and chapter loaders don't check the network; following "Cover images"
/// for small metadata is a deliberate adaptation of `NetworkUtils.isEpisodeHeadDownloadAllowed`.
public final class AuxiliaryNetworkAdmission: Sendable {
    public enum Use: Hashable, Sendable {
        /// Transcripts and external chapter JSON: "Cover images".
        case smallMetadata
        /// A streamed episode's chapter list, read from its media: "Streaming", or Once consent for that episode.
        case streamedMedia
    }

    /// An admitted fetch: its byte budget, whether the network was restricted, and whether it was admitted only because
    /// the network was unrestricted (then it must stop when a metered or Low Data network appears; `perform`).
    public struct Allowance: Equatable, Sendable {
        public let bytes: Int
        public let restricted: Bool
        public let pathLocked: Bool
        public init(bytes: Int, restricted: Bool, pathLocked: Bool) {
            self.bytes = bytes; self.restricted = restricted; self.pathLocked = pathLocked
        }

        /// A path-locked request may use neither an expensive nor a constrained network.
        public func constrain(_ request: inout URLRequest) {
            guard pathLocked else { return }
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
        }
    }

    /// What a deferred fetch waits for: its permission, or (over the restricted-network budget) an unrestricted network,
    /// which a permission alone never releases.
    public enum Wake: Hashable, Sendable {
        case permitted(Use, episodeID: Int64? = nil)
        case unrestricted
    }

    /// Restricted networks (cellular, a hotspot, Low Data Mode, offline or not yet known): every use.
    public static let restrictedByteLimit = 5 * 1024 * 1024
    /// Unrestricted networks: transcripts and chapter JSON.
    public static let smallMetadataByteLimit = 20 * 1024 * 1024
    /// Unrestricted networks: a streamed chapter list, held in memory when the server ignores Range.
    public static let streamedMediaByteLimit = 16 * 1024 * 1024

    /// Without a source every fetch is admitted on an unrestricted budget (tests, and screens built without the app).
    public static let unrestricted = AuxiliaryNetworkAdmission(source: nil)

    private struct Source: Sendable {
        let network: DownloadNetworkMonitor
        let preferences: MobileNetworkPreferenceStore
        let onceAdmittedEpisodeID: @MainActor @Sendable () -> Int64?
    }
    private let source: Source?
    private let listeners = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])
    /// Test-visible: how many times a parked `wait` rechecked and stayed parked.
    private let parkedChecks = Mutex(0)
    var parkedCheckCount: Int { parkedChecks.withLock { $0 } }

    public convenience init(network: DownloadNetworkMonitor = .shared, preferences: MobileNetworkPreferenceStore,
                            onceAdmittedEpisodeID: @escaping @MainActor @Sendable () -> Int64? = { nil }) {
        self.init(source: Source(network: network, preferences: preferences, onceAdmittedEpisodeID: onceAdmittedEpisodeID))
    }

    private init(source: Source?) { self.source = source }

    /// The Mobile updates options changed (`MobileNetworkPreferenceStore.onChange`): parked waits recheck.
    public func preferencesChanged() {
        for listener in listeners.withLock({ Array($0.values) }) { listener.yield() }
    }

    /// The allowance for a fetch now, or nil when it may not run on this network. Waits for the first network
    /// observation; until then nothing is admitted.
    public func allowance(_ use: Use, episodeID: Int64? = nil) async throws -> Allowance? {
        guard let source else { return Self.unrestrictedAllowance(use) }
        let state = try await source.network.observedState()
        return await Self.allowance(use, episodeID: episodeID, state: state, source: source)
    }

    /// Whether the network is unrestricted now (after the first observation): what a fetch over the restricted budget
    /// waits for.
    public func isUnrestricted() async throws -> Bool {
        guard let source else { return true }
        return !Self.restricted(try await source.network.observedState())
    }

    /// A Cast relay through the phone: "Streaming", an unrestricted network, or Once consent for this episode.
    public func streamingRelay(_ episodeID: Int64) async throws -> Bool {
        try await allowance(.streamedMedia, episodeID: episodeID) != nil
    }

    /// Returns once `condition` holds. It subscribes to network and option changes first, then checks the current
    /// state, then rechecks the current state on every change (never inferring it from the change itself).
    public func wait(until condition: Wake) async throws {
        guard let source else { return }
        let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners.withLock { $0[id] = signal }
        defer { _ = listeners.withLock { $0.removeValue(forKey: id) } }
        let networkChanges = source.network.changes()
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { for await _ in networkChanges { signal.yield() } }
            if await holds(condition, source: source) { return }
            parkedChecks.withLock { $0 += 1 }
            for await _ in signals {
                try Task.checkCancellation()
                if await holds(condition, source: source) { return }
                parkedChecks.withLock { $0 += 1 }
            }
            throw CancellationError()
        }
    }

    /// Runs an admitted fetch. Path-locked work runs for its whole life under `DownloadNetworkMonitor.perform(under:
    /// .unmetered)`: any metered or Low Data revision after entry, even one already reverted, ends it with
    /// `DownloadNetworkInterruption` (a denial, never a result). A network that changed since `allowance` refuses on
    /// entry, before any request.
    public func perform<Value: Sendable>(_ allowance: Allowance,
                                         _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard let source, allowance.pathLocked else { return try await operation() }
        guard let state = source.network.current, !Self.restricted(state) else { throw DownloadNetworkInterruption.constraintsChanged }
        return try await source.network.perform(under: .unmetered, operation: operation)
    }

    private func holds(_ condition: Wake, source: Source) async -> Bool {
        guard let state = source.network.current else { return false }
        switch condition {
        case .unrestricted: return !Self.restricted(state)
        case .permitted(let use, let episodeID):
            return await Self.allowance(use, episodeID: episodeID, state: state, source: source) != nil
        }
    }

    private static func allowance(_ use: Use, episodeID: Int64?, state: DownloadNetworkState, source: Source) async -> Allowance? {
        let restricted = restricted(state)
        let permitted: Bool = await MainActor.run {
            switch use {
            case .smallMetadata: return source.preferences.allows(.images)
            case .streamedMedia:
                return source.preferences.allows(.streaming) || (episodeID != nil && source.onceAdmittedEpisodeID() == episodeID)
            }
        }
        if restricted && !permitted { return nil }
        if restricted { return Allowance(bytes: restrictedByteLimit, restricted: true, pathLocked: false) }
        return Allowance(bytes: unrestrictedAllowance(use).bytes, restricted: false, pathLocked: !permitted)
    }

    private static func unrestrictedAllowance(_ use: Use) -> Allowance {
        Allowance(bytes: use == .smallMetadata ? smallMetadataByteLimit : streamedMediaByteLimit, restricted: false, pathLocked: false)
    }

    /// Offline counts as restricted.
    private static func restricted(_ state: DownloadNetworkState) -> Bool { !state.connected || state.restricted }
}

/// An auxiliary fetch that may not run now; it is retried when `wake` holds, and is never cached as a result.
public struct AuxiliaryNetworkDenied: Error, Equatable, Sendable {
    public let wake: AuxiliaryNetworkAdmission.Wake
    public init(wake: AuxiliaryNetworkAdmission.Wake) { self.wake = wake }
}

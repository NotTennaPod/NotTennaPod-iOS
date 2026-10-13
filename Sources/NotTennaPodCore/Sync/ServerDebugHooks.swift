import Foundation
#if DEBUG
import Synchronization

/// DEBUG only: what the acceptance hub's bridge observes inside the store and the exchange (the app's
/// `-test-hub-bridge`, `-test-sync-crash-at` and `-test-sync-clock-offset-ms`, `App/HubBridge.swift`). Nothing here
/// changes what the store or the exchange does: the observer is told, and only the recorder's action clock moves.
/// Release builds compile none of it.
public enum ServerDebugHooks {
    /// A playback save, after its transaction committed.
    public struct Save: Sendable {
        public var episodeID: Int64
        public var positionMilliseconds: Int32
        public var durable: Bool
        public var serverLibrary: Bool
    }

    /// A fact the recorder exported to the outbox, after its transaction committed (the listening
    /// exports are the `session.*` ones).
    public struct Export: Sendable {
        public var opID: String
        public var type: String
        public var installSeq: Int64
        public var authorID: String
    }

    public struct Observer: Sendable {
        /// Called at each named crash point of the exchange before its own test hook; it may never return (the
        /// bridge kills the process there once the hub has its receipt).
        public var crashPoint: @Sendable (String) -> Void
        public var saved: @Sendable (Save) -> Void
        public var exported: @Sendable ([Export]) -> Void

        public init(crashPoint: @escaping @Sendable (String) -> Void, saved: @escaping @Sendable (Save) -> Void,
                    exported: @escaping @Sendable ([Export]) -> Void) {
            self.crashPoint = crashPoint; self.saved = saved; self.exported = exported
        }
    }

    private static let state = Mutex<(observer: Observer?, clockOffset: Int64)>((nil, 0))

    public static func install(_ observer: Observer?) { state.withLock { $0.observer = observer } }

    /// `-test-sync-clock-offset-ms`: moves the recorder's action clock (`client_time`) only; never the wall clock of
    /// rows, playback, retries or time-outs.
    public static func setActionClockOffset(milliseconds: Int64) { state.withLock { $0.clockOffset = milliseconds } }

    static var observer: Observer? { state.withLock { $0.observer } }
    static var actionClockOffset: Int64 { state.withLock { $0.clockOffset } }
}
#endif

/// The recorder's action clock: the time a fact's `client_time` says the person acted.
enum ServerActionClock {
    static func time(of date: Date) -> Date {
#if DEBUG
        date.addingTimeInterval(Double(ServerDebugHooks.actionClockOffset) / 1_000)
#else
        date
#endif
    }
}

extension ServerSyncEngine {
    /// The hook a crash point calls: the tests' `crashPoint`, and in DEBUG the hub bridge's observer first.
    var stepCrashPoint: (@Sendable (String) throws -> Void)? {
#if DEBUG
        if let observe = ServerDebugHooks.observer?.crashPoint {
            let hook = crashPoint
            return { point in
                observe(point)
                try hook?(point)
            }
        }
#endif
        return crashPoint
    }
}

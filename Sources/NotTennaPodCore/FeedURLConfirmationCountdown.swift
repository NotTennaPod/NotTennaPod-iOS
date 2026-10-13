import Foundation

/// EditUrlSettingsDialog's fifteen-second guard. Uses elapsed time, so delayed
/// callbacks or suspension cannot extend the countdown by counting timer ticks.
@MainActor
public final class FeedURLConfirmationCountdown {
    public enum State: Equatable, Sendable {
        case idle, waiting(Int), ready
        public var canConfirm: Bool { self == .ready }
        public func title(ok: String, locale: Locale = .current) -> String {
            guard case .waiting(let seconds) = self else { return ok }
            let formatter = NumberFormatter()
            formatter.locale = locale; formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false; formatter.maximumFractionDigits = 0
            return ok + " (" + (formatter.string(from: NSNumber(value: seconds)) ?? String(seconds)) + ")"
        }
    }
    public typealias Now = @MainActor @Sendable () -> Duration
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public private(set) var state: State = .idle
    public var onChange: ((State) -> Void)?
    private let now: Now
    private let sleep: Sleep
    private var deadline: Duration = .zero
    private var generation = UUID()
    private var pending: Task<Void, Never>?

    public init(now: @escaping Now, sleep: @escaping Sleep) { self.now = now; self.sleep = sleep }
    public convenience init() {
        let origin = ContinuousClock.now
        self.init(now: { origin.duration(to: .now) }, sleep: { try await Task.sleep(for: $0) })
    }
    deinit { pending?.cancel() }

    /// The source onTick uses integer milliseconds/1000 + 1. At an exact
    /// fifteen-second boundary its first label can therefore briefly be16.
    public static func state(remaining: Duration) -> State {
        guard remaining > .zero else { return .ready }
        return .waiting(Int(min(15, remaining.components.seconds)) + 1)
    }

    @discardableResult
    public func start() -> Task<Void, Never> {
        pending?.cancel()
        let token = UUID(), sleep = sleep
        generation = token; deadline = now() + .seconds(15)
        let task = Task { [weak self] in
            while !Task.isCancelled, let delay = self?.step(token: token) {
                do { try await sleep(delay) } catch { return }
            }
        }
        pending = task
        // Reusing a completed countdown must revoke confirmation immediately,
        // before the first asynchronous tick is delivered. Ownership is already
        // stored in case this notification starts or cancels another countdown.
        publish(.idle)
        return task
    }
    public func cancel() {
        generation = UUID(); pending?.cancel(); pending = nil
        publish(.idle)
    }
    private func step(token: UUID) -> Duration? {
        guard token == generation else { return nil }
        let remaining = deadline - now()
        let next = Self.state(remaining: remaining)
        if next.canConfirm { pending = nil }
        publish(next)
        guard token == generation, !next.canConfirm else { return nil }
        return min(.seconds(1), remaining)
    }
    private func publish(_ next: State) {
        guard state != next else { return }
        state = next; onChange?(next)
    }
}

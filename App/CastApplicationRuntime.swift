import Foundation
import NotTennaPodCore
import GoogleCast

struct CastGroupMember: Equatable {
    let id: String
    var name: String
    var volume: Float
    var muted = false
    var hasVariableVolume = true
}

/// Keep surviving rows in place and prepend newly reported members. SDK order
/// supplies the otherwise unordered Android additions; never sort by name.
struct CastGroupMembers {
    private(set) var values: [CastGroupMember] = []
    mutating func replace(_ incoming: [CastGroupMember]) {
        var seen = Set<String>()
        let unique = incoming.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        let old = Set(values.map(\.id)), lookup = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
        values = unique.filter { !old.contains($0.id) } + values.compactMap { lookup[$0.id] }
    }
    mutating func update(_ member: CastGroupMember) {
        replace(values.filter { $0.id != member.id } + [member])
    }
    mutating func remove(_ id: String) { values.removeAll { $0.id == id } }
}

struct CastConnectionState: Equatable {
    enum Phase { case disconnected, connecting, connected }
    var phase: Phase = .disconnected
    var identity: CastSessionIdentity?
    var name = ""
    var volume: Float = 1
    var muted = false
    var hasVariableVolume = true
    // Both the pinned MediaRouter2 conversion and inspected Cast provider
    // advertise false. A receiver SDK disconnect API alone is not this UI capability.
    var canDisconnect = false
    var members: [CastGroupMember] = []
}

@MainActor protocol CastApplicationSession: AnyObject {
    var state: CastConnectionState { get }
    var onEvent: ((CastSessionEvent) -> Void)? { get set }
    var onChange: (() -> Void)? { get set }
    func start()
    func makeDiscovery() -> any CastDeviceDiscovery
    func end(stopReceiver: Bool) -> Bool
    func setVolume(_ value: Float, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation
    func setMemberVolume(_ value: Float, memberID: String, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation
    /// The connected receiver has media loaded (any player state). Read for the library switch's activation rule.
    var receiverHasMedia: Bool { get }
}

extension CastApplicationSession {
    /// Sessions that cannot read the receiver's media status count a connected receiver as holding media.
    var receiverHasMedia: Bool { state.phase == .connected }
}

/// Whether a Cast session was connected when the app last ran (the Google Cast SDK
/// starts at the first Cast button tap, or at launch only to resume such a session).
@MainActor final class CastSessionMemory {
    private let load: () -> Bool
    private let save: (Bool) -> Void
    var wasActive: Bool { load() }
    func remember(_ active: Bool) { if active != load() { save(active) } }
    init(load: @escaping () -> Bool, save: @escaping (Bool) -> Void) { self.load = load; self.save = save }
    /// Kept in memory only; `wasActive` starts the session at launch as before (tests and fixture sessions).
    convenience init(wasActive: Bool = true) {
        var value = wasActive
        self.init(load: { value }, save: { value = $0 })
    }
    static func defaults(_ defaults: UserDefaults = .standard, key: String = "castSessionWasActive") -> CastSessionMemory {
        .init(load: { defaults.bool(forKey: key) }, save: { defaults.set($0, forKey: key) })
    }
}

/// One application owner supplies canonical media access to every session and
/// shares connection state across scenes without making screen lifetimes own it.
@MainActor final class CastApplicationRuntime {
    private let session: any CastApplicationSession
    private let player: PlaybackCoordinator
    private let routes: RoutedPlaybackEngine
    private let media: CastMediaAccessOwner
    private var observers: [UUID: (CastConnectionState) -> Void] = [:]
    private var problemObservers: [UUID: (String) -> Void] = [:]
    private var choosers: [WeakChooser] = []
    private var volumeRequest: (any CastRequestCancellation)?
    private var volumeRevision = UUID()
    private final class MemberRequest {
        var token: (any CastRequestCancellation)?
    }
    private var memberRequests: [String: MemberRequest] = [:]
    private var startup: Task<Void, Never>?
    private let memory: CastSessionMemory
    private var restored = false, sessionWanted = false
    /// Launch work done (the player restored); the SDK may still be waiting for first use.
    var sessionReady: Bool { restored }
    private(set) var sessionStarted = false
    private var ending = Set<CastSessionIdentity>()
    private var stopping = Set<CastSessionIdentity>()
    private(set) var state = CastConnectionState()
    private lazy var receiver = CastReceiverSessionController(player: player, routes: routes, mediaAccess: media, library: media.library,
        prepareMedia: { [media] in try await media.prepare($0) }, onProblem: { [weak self] in self?.report($0) })
    private final class WeakChooser {
        weak var value: CastDeviceChooser?
        init(_ value: CastDeviceChooser) { self.value = value }
    }

    init(session: any CastApplicationSession, player: PlaybackCoordinator, routes: RoutedPlaybackEngine,
         media: CastMediaAccessOwner, memory: CastSessionMemory = .init()) {
        self.session = session; self.player = player; self.routes = routes; self.media = media; self.memory = memory
        session.onEvent = { [weak self] in self?.receive($0) }
        session.onChange = { [weak self] in self?.refresh() }
    }
    isolated deinit { startup?.cancel(); volumeRequest?.cancel(); for request in memberRequests.values { request.token?.cancel() } }
    func start() {
        guard startup == nil else { return }
        startup = Task { [weak self] in
            guard let self else { return }
            do { try await player.restore() } catch { report(error.localizedDescription) }
            guard !Task.isCancelled else { return }
            _ = receiver
            restored = true
            // The SDK (and its network monitoring) starts only to resume a session the person was casting to;
            // otherwise at the first Cast button tap (`makeChooser`).
            if sessionWanted || memory.wasActive { startSession() }
        }
    }
    private func startSession() {
        sessionWanted = true
        guard restored, !sessionStarted else { return }
        sessionStarted = true
        session.start(); refresh()
    }
    /// The library graph is being torn down: session events no longer reach this graph's player or routes.
    func retire() {
        session.onEvent = nil; session.onChange = nil
    }
    /// PROTOCOL §15.4: a library switch waits while a Cast session is connecting, or connected with media loaded on
    /// the receiver (or its status still being read), because a new library graph would adopt that media by its
    /// local ID. A connected receiver without media, or no session, does not hold it.
    var blocksLibrarySwitch: Bool {
        switch state.phase {
        case .disconnected: false
        case .connecting: true
        case .connected: session.receiverHasMedia || receiver.isRestoring
        }
    }
    func observe(_ change: @escaping (CastConnectionState) -> Void,
                 problem: @escaping (String) -> Void) -> CastChooserCancellation {
        let id = UUID(); observers[id] = change; problemObservers[id] = problem
        change(state)
        return CastChooserCancellation { [weak self] in self?.observers[id] = nil; self?.problemObservers[id] = nil }
    }
    func makeChooser() -> CastDeviceChooser {
        startSession()
        let chooser = CastDeviceChooser(discovery: session.makeDiscovery())
        choosers.removeAll { $0.value == nil }; choosers.append(WeakChooser(chooser))
        return chooser
    }
    private func refresh() {
        var next = session.state
        if let id = next.identity, ending.contains(id) { next.phase = .disconnected }
        guard next != state else { return }
        for (id, request) in memberRequests where next.identity != state.identity || next.phase != .connected
            || !next.members.contains(where: { $0.id == id && $0.hasVariableVolume }) {
            memberRequests[id] = nil; request.token?.cancel()
        }
        state = next
        for observer in Array(observers.values) { observer(next) }
    }
    private func receive(_ event: CastSessionEvent) {
        switch event {
        case .connected(let snapshot, _):
            ending.remove(snapshot.identity); memory.remember(true)
        case .ending(let snapshot):
            ending.insert(snapshot.identity)
        case .ended(let identity, _):
            if stopping.remove(identity) != nil { media.receiverStopped(deviceID: identity.deviceID) }
            memory.remember(false)
        case .startFailed: memory.remember(false)
        default: break
        }
        receiver.receive(event)
        switch event {
        case .connected:
            for chooser in choosers { chooser.value?.routeSelected() }
        case .startFailed(let identity, _):
            for chooser in choosers { chooser.value?.selectionFailed(id: identity.deviceID) }
        default: break
        }
        refresh()
    }
    func end(stopReceiver: Bool) {
        guard let identity = state.identity, state.phase == .connected, stopReceiver || state.canDisconnect else { return }
        receiver.setStoppingReceiver(identity, stopping: stopReceiver)
        if stopReceiver { stopping.insert(identity) }
        if !session.end(stopReceiver: stopReceiver) {
            receiver.setStoppingReceiver(identity, stopping: false); stopping.remove(identity)
            report(Appearance.text("cast_end_failed"))
        }
    }
    func setVolume(_ value: Float) {
        guard state.phase == .connected, state.hasVariableVolume, value.isFinite else { return }
        volumeRequest?.cancel()
        let revision = UUID(); volumeRevision = revision
        let request = session.setVolume(min(1, max(0, value))) { [weak self] result in
            guard let self, volumeRevision == revision else { return }
            if case .failed(let message) = result { report(message) }
            refresh()
        }
        volumeRequest = request
    }
    func setMemberVolume(_ value: Float, memberID: String) {
        guard state.phase == .connected, let identity = state.identity, value.isFinite,
              state.members.contains(where: { $0.id == memberID && $0.hasVariableVolume }) else { return }
        let previous = memberRequests.removeValue(forKey: memberID); previous?.token?.cancel()
        let request = MemberRequest(); memberRequests[memberID] = request
        let token = session.setMemberVolume(min(1, max(0, value)), memberID: memberID) { [weak self, weak request] outcome in
            guard let self, let request, memberRequests[memberID] === request, state.identity == identity,
                  state.phase == .connected else { return }
            memberRequests[memberID] = nil
            if case .failed(let message) = outcome { report(message) }
            refresh()
        }
        if memberRequests[memberID] === request { request.token = token }
        else { token.cancel() }
    }
    private func report(_ message: String) {
        for observer in Array(problemObservers.values) { observer(message) }
    }
}

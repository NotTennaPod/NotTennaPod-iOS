import Foundation

struct CastDiscoveredDevice: Equatable, Identifiable {
    enum Icon: String { case generic = "cast_device", tv = "cast_tv", speaker = "cast_speaker", group = "cast_group" }
    let id: String
    let name: String
    var icon: Icon = .generic
    var connectionDescription: String? = nil
}

@MainActor protocol CastDeviceDiscovery: AnyObject {
    var devices: [CastDiscoveredDevice] { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
    func select(id: String) -> Bool
}

@MainActor final class CastChooserCancellation {
    private var cancelAction: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { cancelAction = cancel }
    func cancel() { cancelAction?(); cancelAction = nil }
    isolated deinit { cancel() }
}

@MainActor protocol CastChooserClock {
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> CastChooserCancellation
}

@MainActor struct ContinuousCastChooserClock: CastChooserClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> CastChooserCancellation {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(max(0, delay))) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return CastChooserCancellation { task.cancel() }
    }
}

/// MediaRouter1.8.1's classic chooser: throttled list updates, then 5s/15s empty
/// states. Discovery is scoped to the presentation, not the player lifetime.
@MainActor final class CastDeviceChooser {
    enum Phase { case searching, wifiHint, noDevices, routes }
    private(set) var phase: Phase = .searching
    private(set) var devices: [CastDiscoveredDevice] = []
    private(set) var selecting = Set<String>()
    private(set) var isActive = false
    var onChange: (() -> Void)?
    var onSelected: (() -> Void)?
    private let discovery: any CastDeviceDiscovery
    private let clock: any CastChooserClock
    private var lastUpdate: TimeInterval?
    private var update: CastChooserCancellation?
    private var timeout: CastChooserCancellation?
    private var generation = UUID()

    init(discovery: any CastDeviceDiscovery, clock: any CastChooserClock = ContinuousCastChooserClock()) {
        self.discovery = discovery; self.clock = clock
    }
    isolated deinit { stop() }

    func start() {
        guard !isActive else { return }
        generation = UUID(); isActive = true; lastUpdate = nil
        discovery.onChange = { [weak self] in self?.refresh() }
        discovery.start()
        refresh()
    }
    func stop() {
        guard isActive else { return }
        isActive = false; generation = UUID()
        update?.cancel(); update = nil; timeout?.cancel(); timeout = nil
        discovery.onChange = nil; discovery.stop()
    }
    private func refresh() {
        guard isActive else { return }
        update?.cancel(); update = nil
        let remaining = max(0, 0.3 - (clock.now - (lastUpdate ?? -.infinity)))
        if remaining == 0 { applyDevices() }
        else {
            let captured = generation
            update = clock.schedule(after: remaining) { [weak self] in
                guard let self, isActive, generation == captured else { return }
                applyDevices()
            }
        }
    }
    private func applyDevices() {
        lastUpdate = clock.now; update = nil
        timeout?.cancel(); timeout = nil
        // Stable case-insensitive UTF-16 ordering; no natural/numeric or locale
        // collation. Java compares simple upper-then-lower character mappings.
        devices = discovery.devices.enumerated().sorted {
            let lhs = Self.sortKey($0.element.name), rhs = Self.sortKey($1.element.name)
            return lhs == rhs ? $0.offset < $1.offset : lhs.lexicographicallyPrecedes(rhs)
        }.map(\.element)
        selecting.removeAll()
        phase = devices.isEmpty ? .searching : .routes
        if devices.isEmpty { scheduleHint() }
        onChange?()
    }
    private static func sortKey(_ text: String) -> [UInt16] {
        text.utf16.map { unit in
            guard let scalar = UnicodeScalar(unit) else { return unit }
            let uppercase = Array(scalar.properties.uppercaseMapping.utf16)
            let upper = uppercase.count == 1 ? uppercase[0] : unit
            // Unicode full lowercase expands dotted I; Java's simple map is i.
            if upper == 0x130 { return 0x69 }
            guard let scalar = UnicodeScalar(upper) else { return upper }
            let lowercase = Array(scalar.properties.lowercaseMapping.utf16)
            return lowercase.count == 1 ? lowercase[0] : upper
        }
    }
    private func scheduleHint() {
        let captured = generation
        timeout = clock.schedule(after: 5) { [weak self] in
            guard let self, isActive, generation == captured, devices.isEmpty else { return }
            phase = .wifiHint; onChange?()
            timeout = clock.schedule(after: 15) { [weak self] in
                guard let self, isActive, generation == captured, devices.isEmpty else { return }
                phase = .noDevices
                stop()
                onChange?()
            }
        }
    }
    func select(id: String) {
        guard isActive, devices.contains(where: { $0.id == id }) else { return }
        selecting.insert(id); onChange?()
        if !discovery.select(id: id) { selectionFailed(id: id) }
    }
    func selectionFailed(id: String) {
        guard isActive else { return }
        selecting.remove(id); onChange?()
    }
    /// Delivered by the application's Cast session owner, including selection
    /// from another sender; selection itself must never synthesize success.
    func routeSelected() {
        guard isActive else { return }
        stop(); onSelected?()
    }
}

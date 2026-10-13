import GoogleCast

/// Scene choosers share a single SDK scan. Only the last owner restores the
/// discovery state that preceded the first chooser.
@MainActor final class CastDiscoveryActivity {
    private let begin: () -> Void
    private let end: () -> Void
    private var owners = 0
    init(begin: @escaping () -> Void, end: @escaping () -> Void) { self.begin = begin; self.end = end }
    convenience init(manager: GCKDiscoveryManager) {
        var previous: (active: Bool, passive: Bool)?
        self.init(begin: {
            previous = (manager.discoveryActive, manager.passiveScan)
            manager.passiveScan = false; manager.startDiscovery()
        }, end: {
            guard let state = previous else { return }
            manager.passiveScan = state.passive
            if !state.active { manager.stopDiscovery() }
            previous = nil
        })
    }
    func acquire() -> CastChooserCancellation {
        owners += 1
        if owners == 1 { begin() }
        return CastChooserCancellation { [self] in
            owners -= 1
            if owners == 0 { end() }
        }
    }
}

/// The configured Cast provider filters for the application's receiver. Default
/// and Bluetooth routes never enter this provider's device list.
@MainActor final class GoogleCastDeviceDiscovery: NSObject, CastDeviceDiscovery,
    @preconcurrency GCKDiscoveryManagerListener {
    var onChange: (() -> Void)?
    private let manager: GCKDiscoveryManager
    private let sessions: GCKSessionManager
    private var observing = false
    private let activity: CastDiscoveryActivity
    private var scan: CastChooserCancellation?
    init(manager: GCKDiscoveryManager, sessions: GCKSessionManager, activity: CastDiscoveryActivity) {
        self.manager = manager; self.sessions = sessions
        self.activity = activity
        super.init()
    }
    isolated deinit { stop() }
    var devices: [CastDiscoveredDevice] {
        (0..<manager.deviceCount).map { index in
            let device = manager.device(at: index)
            let icon: CastDiscoveredDevice.Icon
            switch device.type {
            case .TV: icon = .tv
            case .speaker: icon = .speaker
            case .speakerGroup: icon = .group
            default: icon = .generic
            }
            let session = sessions.currentCastSession
            let selected = session?.device.uniqueID == device.uniqueID
                && (session?.connectionState == .connected || session?.connectionState == .connecting)
            return .init(id: device.uniqueID, name: device.friendlyName ?? "", icon: icon,
                connectionDescription: selected ? device.statusText : nil)
        }
    }
    func start() {
        guard !observing else { return }
        observing = true
        manager.add(self)
        scan = activity.acquire()
    }
    func stop() {
        guard observing else { return }
        observing = false; manager.remove(self)
        scan?.cancel(); scan = nil
    }
    func select(id: String) -> Bool {
        guard observing, let device = manager.device(withUniqueID: id) else { return false }
        return sessions.startSession(with: device)
    }
    func didUpdateDeviceList() { if observing { onChange?() } }
    func didHaveDiscoveredDeviceWhenStartingDiscovery() { if observing { onChange?() } }
}

import Foundation
import NotTennaPodCore
import GoogleCast

#if DEBUG
/// Controlled receiver status for real-window gesture journeys. It uses no LAN
/// receiver and does not claim to exercise SDK discovery or media handoff.
@MainActor final class CastGroupTestSession: CastApplicationSession {
    private let identity = CastSessionIdentity(deviceID: "group-fixture", sessionID: "fixture-session")
    var state = CastConnectionState()
    var onEvent: ((CastSessionEvent) -> Void)?
    var onChange: (() -> Void)?
    func start() {
        state = .init(phase: .connected, identity: identity, name: "Whole home", volume: 0.4,
            members: [.init(id: "office", name: "Office 1", volume: 0.2, hasVariableVolume: false),
                      .init(id: "kitchen", name: "Kitchen", volume: 0.3)]
                + (2...5).map { .init(id: "speaker-\($0)", name: "Speaker \($0)", volume: Float($0) / 10) })
        onChange?()
    }
    func makeDiscovery() -> any CastDeviceDiscovery { EmptyCastTestDiscovery() }
    func end(stopReceiver: Bool) -> Bool {
        state = .init(); onEvent?(.ended(identity, message: nil)); onChange?(); return true
    }
    func setVolume(_ value: Float, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation {
        state.volume = value; completion(.completed); onChange?(); return NoCastRequest()
    }
    func setMemberVolume(_ value: Float, memberID: String, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation {
        guard let index = state.members.firstIndex(where: { $0.id == memberID }), state.members[index].hasVariableVolume else {
            completion(.superseded); return NoCastRequest()
        }
        state.members[index].volume = value; completion(.completed); onChange?(); return NoCastRequest()
    }
}
#endif

#if DEBUG
/// Isolates UI journeys from nearby receivers while exercising real SDK startup.
@MainActor final class EmptyCastTestDiscovery: CastDeviceDiscovery {
    let devices: [CastDiscoveredDevice] = []
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
    func select(id: String) -> Bool { false }
}
#endif

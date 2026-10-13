import Foundation
import NotTennaPodCore
import GoogleCast

@MainActor final class GoogleCastApplicationSession: NSObject, CastApplicationSession,
    @preconcurrency GCKSessionManagerListener, @preconcurrency GCKCastDeviceStatusListener {
    var onEvent: ((CastSessionEvent) -> Void)?
    var onChange: (() -> Void)?
    /// Created when the session starts (first Cast tap, or launch to resume a session), not with the app.
    private lazy var context: GCKCastContext = {
        if !GCKCastContext.isSharedInstanceInitialized() { GCKCastContext.setSharedInstanceWith(Self.options()) }
        return GCKCastContext.sharedInstance()
    }()
    private var events: CastSessionEventSource?
    private var started = false
    private var groupSession: GCKCastSession?
    private var groupIdentity: CastSessionIdentity?
    private var groupMembers = CastGroupMembers()
    private var groupDevices: [String: GCKMultizoneDevice] = [:]
    private var groupStatusRequest: (any CastRequestCancellation)?
    private lazy var discoveryActivity = CastDiscoveryActivity(manager: context.discoveryManager)
    #if DEBUG
    var testingEmptyDiscovery = false
    #endif
    /// Google's Default Media Receiver (`kGCKDefaultMediaReceiverApplicationID`). Android uses AntennaPod's own registered
    /// receiver `BEBC1DB1`; NotTennaPod does not use AntennaPod's receiver.
    static let applicationID = "CC1AD845"

    static func options() -> GCKCastOptions {
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: applicationID))
        // A custom chooser starts discovery at the user's tap. The SDK's default
        // Cast UI is not part of this application's source-derived composition.
        options.disableDiscoveryAutostart = true
        options.startDiscoveryAfterFirstTapOnCastButton = false
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        options.suspendSessionsWhenBackgrounded = true
        return options
    }
    override init() { super.init() }
    isolated deinit {
        if started { context.sessionManager.remove(self) }
        groupSession?.remove(self); groupStatusRequest?.cancel()
    }
    func start() {
        guard !started else { return }; started = true
        context.sessionManager.add(self)
        events = CastSessionEventSource(manager: context.sessionManager) { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected(let snapshot, _):
                bindGroup(context.sessionManager.currentCastSession, identity: snapshot.identity)
            case .ending(let snapshot), .suspended(let snapshot, _):
                if groupIdentity == snapshot.identity { bindGroup(nil, identity: nil) }
            case .ended(let identity, _), .startFailed(let identity, _):
                if groupIdentity == identity { bindGroup(nil, identity: nil) }
            }
            onEvent?(event); onChange?()
        }
        events?.deliverExistingSession()
    }
    var state: CastConnectionState {
        guard started, let session = context.sessionManager.currentCastSession else { return .init() }
        let phase: CastConnectionState.Phase = session.connectionState == .connected ? .connected
            : session.connectionState == .connecting ? .connecting : .disconnected
        return .init(phase: phase, identity: .init(deviceID: session.device.uniqueID,
            sessionID: session.sessionID ?? "unstarted-\(ObjectIdentifier(session))"),
            name: session.device.friendlyName ?? "", volume: session.currentDeviceVolume,
            muted: session.currentDeviceMuted, hasVariableVolume: session.traits?.isFixedVolume() != true,
            members: acceptsGroup(session) ? groupMembers.values : [])
    }
    var receiverHasMedia: Bool {
        guard started, let session = context.sessionManager.currentCastSession, session.connectionState == .connected,
              let status = session.remoteMediaClient?.mediaStatus else { return false }
        return status.mediaInformation != nil || (status.playerState != .idle && status.playerState != .unknown)
    }
    func makeDiscovery() -> any CastDeviceDiscovery {
        #if DEBUG
        if testingEmptyDiscovery { return EmptyCastTestDiscovery() }
        #endif
        return GoogleCastDeviceDiscovery(manager: context.discoveryManager, sessions: context.sessionManager, activity: discoveryActivity)
    }
    func end(stopReceiver: Bool) -> Bool { context.sessionManager.endSessionAndStopCasting(stopReceiver) }
    func setVolume(_ value: Float, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation {
        guard let session = context.sessionManager.currentCastSession else {
            completion(.failed(Appearance.text("cast_not_connected")))
            return NoCastRequest()
        }
        return GoogleCastRequest(session.setDeviceVolume(value), completion: completion)
    }
    private func acceptsGroup(_ session: GCKCastSession) -> Bool {
        session === groupSession && session.connectionState == .connected
            && groupIdentity == CastSessionIdentity(deviceID: session.device.uniqueID, sessionID: session.sessionID ?? "")
    }
    private func bindGroup(_ session: GCKCastSession?, identity: CastSessionIdentity?) {
        groupSession?.remove(self); groupStatusRequest?.cancel(); groupStatusRequest = nil
        groupMembers = .init(); groupDevices = [:]; groupSession = nil; groupIdentity = nil
        guard let session, let identity, session.connectionState == .connected,
              session.device.uniqueID == identity.deviceID, session.sessionID == identity.sessionID else { return }
        groupSession = session; groupIdentity = identity; session.add(self)
        if session.device.hasCapabilities(.multizoneGroup) || session.device.hasCapabilities(.dynamicGroup)
            || session.device.hasCapabilities(.multiChannelGroup) {
            groupStatusRequest = GoogleCastRequest(session.requestMultizoneStatus(), completion: { _ in })
        }
    }
    private func member(_ device: GCKMultizoneDevice) -> CastGroupMember {
        .init(id: device.deviceID, name: device.friendlyName ?? "", volume: device.volumeLevel, muted: device.muted,
              hasVariableVolume: !device.hasCapabilities(.masterOrFixedVolume) && !device.hasCapabilities(.attenuationOrFixedVolume))
    }
    func castSession(_ castSession: GCKCastSession, didReceive multizoneStatus: GCKMultizoneStatus) {
        guard acceptsGroup(castSession) else { return }
        groupDevices = [:]
        for device in multizoneStatus.devices where !device.deviceID.isEmpty { groupDevices[device.deviceID] = device }
        groupMembers.replace(multizoneStatus.devices.map(member)); onChange?()
    }
    func castSession(_ castSession: GCKCastSession, didAdd device: GCKMultizoneDevice) {
        updateMember(device, session: castSession)
    }
    func castSession(_ castSession: GCKCastSession, didUpdate device: GCKMultizoneDevice) {
        updateMember(device, session: castSession)
    }
    private func updateMember(_ device: GCKMultizoneDevice, session: GCKCastSession) {
        guard acceptsGroup(session), !device.deviceID.isEmpty else { return }
        groupDevices[device.deviceID] = device; groupMembers.update(member(device)); onChange?()
    }
    func castSession(_ castSession: GCKCastSession, didRemoveMultizoneDeviceWithID deviceID: String) {
        guard acceptsGroup(castSession) else { return }
        groupDevices[deviceID] = nil; groupMembers.remove(deviceID); onChange?()
    }
    func setMemberVolume(_ value: Float, memberID: String, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation {
        guard let session = groupSession, acceptsGroup(session), let device = groupDevices[memberID],
              member(device).hasVariableVolume, value.isFinite else {
            completion(.superseded); return NoCastRequest()
        }
        return GoogleCastRequest(session.setDeviceVolume(min(1, max(0, value)), for: device), completion: completion)
    }
    func sessionManager(_ manager: GCKSessionManager, willStart session: GCKCastSession) { onChange?() }
    func sessionManager(_ manager: GCKSessionManager, session: GCKSession, didUpdate device: GCKDevice) { onChange?() }
    func sessionManager(_ manager: GCKSessionManager, castSession session: GCKCastSession,
                        didReceiveDeviceVolume volume: Float, muted: Bool) { onChange?() }
}

@MainActor final class NoCastRequest: CastRequestCancellation { func cancel() {} }

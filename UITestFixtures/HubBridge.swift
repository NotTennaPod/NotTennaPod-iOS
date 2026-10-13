#if DEBUG
import Darwin
import Foundation
import NotTennaPodCore
import Synchronization
import UIKit

/// DEBUG: the app bridge of the acceptance hub (PROTOCOL §16), for the hub
/// (`TestSupport/Servers/serve-ntp-server-fixture.py`). Launch arguments, like the other `-test-*` ones:
/// - `-test-hub-bridge <url>` (the hub's `…/bridge`): reports to the hub the exchange's crash points reached, the
///   playback saves journaled and the facts the recorder exports, and the background leases taken, expired and
///   released (`BackgroundWorkGrant`, the periodic refresh's, the server library's two background tasks). On the hub's
///   command it calls a held lease's production expiration handler, or runs the production background refresh handler
///   (`AppDelegate.launchPeriodicRefresh`) or a server-sync task's (`AppDelegate.runServerSyncInBackground`, refresh or
///   processing); no test code stands in for any of them, only a lease for the `BGTask`.
/// - `-test-sync-crash-at <point>`: the first time the exchange reaches that crash point, the bridge reports it and,
///   once the hub answers with its receipt, the process kills itself with SIGKILL, where it stands (inside the
///   step's transaction for a unit's points): no cleanup, no close. Without the hub's receipt it carries on.
/// - `-test-sync-clock-offset-ms <n>`: moves the recorder's action clock (`client_time`) only.
@MainActor final class HubBridge {
    private(set) static var shared: HubBridge?

    nonisolated let session = UUID().uuidString
    private let poster: Poster
    private weak var app: AppDelegate?
    private var leases: [String: (kind: String, expire: () -> Void)] = [:]
    private var leaseOrder: [String] = []
    private var leaseCount = 0

    /// Reads the launch arguments at launch, before the first library graph starts.
    static func start(arguments: [String], app: AppDelegate) {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let offset = value("-test-sync-clock-offset-ms").flatMap(Int64.init) {
            ServerDebugHooks.setActionClockOffset(milliseconds: offset)
        }
        guard shared == nil, let address = value("-test-hub-bridge"), let base = URL(string: address) else { return }
        let bridge = HubBridge(base: base, app: app)
        shared = bridge
        let crashAt = value("-test-sync-crash-at")
        bridge.poster.post("hello", ["session": bridge.session, "pid": Int(getpid()), "crash_at": crashAt,
                                     "library": value("-test-library-id"),
                                     "clock_offset_ms": value("-test-sync-clock-offset-ms").flatMap(Int64.init)])
        ServerDebugHooks.install(bridge.observer(crashAt: crashAt))
        bridge.pollCommands()
    }

    private init(base: URL, app: AppDelegate) {
        poster = Poster(base: base)
        self.app = app
    }

    // MARK: - Reports

    nonisolated private func observer(crashAt: String?) -> ServerDebugHooks.Observer {
        let poster = poster, session = session
        let fired = Mutex(false)
        return .init(crashPoint: { point in
            let armed = point == crashAt && fired.withLock { already in
                defer { already = true }
                return !already
            }
            guard armed else {
                poster.post("events", ["session": session, "kind": "crash_point", "point": point, "armed": false])
                return
            }
            // Every earlier report reaches the hub first; the kill waits for the hub's receipt.
            if let answer = poster.postAndWait("crash", ["session": session, "point": point]), answer["receipt"] != nil {
                kill(getpid(), SIGKILL)
            }
        }, saved: { save in
            poster.post("events", ["session": session, "kind": "save", "episode_id": save.episodeID,
                                   "position_ms": Int(save.positionMilliseconds), "durable": save.durable,
                                   "server_library": save.serverLibrary])
        }, exported: { exports in
            for export in exports {
                poster.post("events", ["session": session, "kind": "export", "op_id": export.opID, "type": export.type,
                                       "install_seq": export.installSeq, "author": export.authorID])
            }
        })
    }

    /// A production background lease was taken; `expire` is its production expiration handler.
    func leaseTaken(kind: String, expire: @escaping () -> Void) -> String {
        leaseCount += 1
        let id = "\(kind)-\(leaseCount)"
        leases[id] = (kind, expire)
        leaseOrder.append(id)
        poster.post("events", ["session": session, "kind": "lease", "lease": id, "lease_kind": kind, "state": "taken"])
        return id
    }

    /// The lease expired (its handler ran) or was released (ended, or completed with `success`).
    func leaseEnded(_ id: String, state: String, success: Bool? = nil) {
        if state == "released" {
            leases[id] = nil
            leaseOrder.removeAll { $0 == id }
        }
        poster.post("events", ["session": session, "kind": "lease", "lease": id,
                               "lease_kind": id.components(separatedBy: "-").dropLast().joined(separator: "-"),
                               "state": state, "success": success])
    }

    // MARK: - Commands

    private func pollCommands() {
        let poster = poster, session = session
        Task { [weak self] in
            var after = 0
            while self != nil {
                guard let commands = await poster.commands(session: session, after: after) else {
                    // The hub is away (between runs): ask again shortly.
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                for command in commands {
                    after = max(after, command.id)
                    let result = self?.run(command.name, command.args) ?? ["ok": false, "error": "the bridge is gone"]
                    poster.post("commands/\(command.id)/done", result)
                }
            }
        }
    }

    private func run(_ name: String, _ args: [String: Any]) -> [String: Any] {
        switch name {
        case "expire_lease":
            // The lease named, else the latest held of the kind named, else the latest held.
            let kind = args["kind"] as? String
            let id = (args["lease"] as? String) ?? leaseOrder.last { kind == nil || leases[$0]?.kind == kind }
            guard let id, let lease = leases[id] else { return ["ok": false, "error": "no background lease is held"] }
            lease.expire()
            return ["ok": true, "result": ["lease": id, "lease_kind": lease.kind]]
        case "run_background_refresh":
            guard let app else { return ["ok": false, "error": "no app"] }
            let lease = HubBridgeRefreshLease(bridge: self)
            app.launchPeriodicRefresh(lease)
            return ["ok": true, "result": ["lease": lease.id]]
        case "run_server_sync":
            // The server library's background tasks: `refresh` (BGAppRefresh) or `processing` (BGProcessing).
            guard let app else { return ["ok": false, "error": "no app"] }
            let work = args["work"] as? String ?? "refresh"
            guard work == "refresh" || work == "processing" else { return ["ok": false, "error": "unknown work \(work)"] }
            let lease = HubBridgeServerSyncLease(bridge: self, kind: "server-sync-\(work)")
            app.runServerSyncInBackground(lease, work: work == "refresh" ? .refresh : .processing)
            return ["ok": true, "result": ["lease": lease.id]]
        default:
            return ["ok": false, "error": "unknown command \(name)"]
        }
    }
}

/// The lease a hub-started background refresh runs with: iOS's `BGTask` cannot be made, so this stands in for the
/// task object only. The handler it is given to, and the expiration handler the runtime sets on it, are production's.
@MainActor final class HubBridgeRefreshLease: PeriodicRefreshBackgroundLease {
    var expiration: (@MainActor () -> Void)?
    private(set) var id = ""

    init(bridge: HubBridge) {
        id = bridge.leaseTaken(kind: "periodic-refresh") { [weak self] in self?.expiration?() }
    }

    func complete(success: Bool) {
        expiration = nil
        HubBridge.shared?.leaseEnded(id, state: "released", success: success)
    }
}

/// The lease a hub-started server-sync background task runs with, standing in for its `BGTask` only; the handler it
/// is given to, and the expiration handler that handler sets on it, are production's.
@MainActor final class HubBridgeServerSyncLease: ServerSyncBackgroundLeasing {
    var expiration: (@MainActor () -> Void)?
    private(set) var id = ""
    private var completed = false

    init(bridge: HubBridge, kind: String) {
        id = bridge.leaseTaken(kind: kind) { [weak self] in self?.expiration?() }
    }

    func complete(success: Bool) {
        guard !completed else { return }
        completed = true
        expiration = nil
        HubBridge.shared?.leaseEnded(id, state: "released", success: success)
    }
}

/// The bridge's HTTP: reports in order on one serial queue, outside any proxy, never through the app's own sessions.
private final class Poster: Sendable {
    let base: URL
    let queue = DispatchQueue(label: "org.nottennapod.app.hub-bridge")
    let session: URLSession

    init(base: URL) {
        self.base = base
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    private func encode(_ body: [String: Any?]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })) ?? Data("{}".utf8)
    }

    func post(_ path: String, _ body: [String: Any?]) {
        let data = encode(body)
        queue.async { _ = self.send(path, data) }
    }

    /// After every earlier report; nil when the hub did not answer.
    func postAndWait(_ path: String, _ body: [String: Any?]) -> [String: Any]? {
        let data = encode(body)
        return queue.sync { send(path, data) }
    }

    private func send(_ path: String, _ data: Data) -> [String: Any]? {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let answer = Mutex<Data?>(nil)
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { answer.withLock { $0 = data } }
            done.signal()
        }.resume()
        done.wait()
        return answer.withLock { $0 }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func commands(session id: String, after: Int) async -> [(id: Int, name: String, args: [String: Any])]? {
        var components = URLComponents(url: base.appendingPathComponent("commands"), resolvingAgainstBaseURL: false)
        components?.queryItems = [.init(name: "session", value: id), .init(name: "after", value: String(after)),
                                  .init(name: "timeout", value: "20")]
        guard let url = components?.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["commands"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let id = item["id"] as? Int, let name = item["command"] as? String else { return nil }
            return (id, name, item["args"] as? [String: Any] ?? [:])
        }
    }
}
#endif

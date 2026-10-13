import Foundation

/// Draft login state belongs to the dialog; durable host/account changes belong
/// to the shared accounts owner. Closing the dialog never undoes a committed step.
@MainActor
public final class GpodderAuthenticationFlow {
    public enum Stage: Equatable, Sendable { case host, credentials, devices, finish }
    public private(set) var stage: Stage = .host
    public private(set) var busy = false
    public private(set) var error: String?
    public private(set) var host = ""
    public private(set) var username = ""
    public private(set) var devices: [SynchronizationDevice] = []
    public private(set) var selectedDevice: SynchronizationDevice?
    public private(set) var connectedEpoch: UUID?
    public private(set) var suggestedDeviceName = ""
    public var onChange: (@MainActor () -> Void)?

    private let accounts: SynchronizationAccounts
    private let deviceModel: String
    private var epoch: UUID?
    private var password = ""
    private var client: SynchronizationHTTPClient?
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var cancelled = false

    public init(accounts: SynchronizationAccounts, deviceModel: String) {
        self.accounts = accounts; self.deviceModel = deviceModel
    }

    public func proceed(host: String) async {
        guard stage == .host, !host.isEmpty else { return }
        await perform {
            let expected = try await self.accounts.authenticationEpoch()
            let epoch = try await self.accounts.prepareGpodderAuthentication(host: host, expectedEpoch: expected)
            try Task.checkCancellation()
            self.epoch = epoch; self.host = host; self.stage = .credentials
        }
    }

    public func login(username: String, password: String) async {
        guard stage == .credentials, !busy, !cancelled else { return }
        // This is the release's explicit blacklist, not a stricter inferred grammar.
        if username.contains(where: { "!@#$%&*()+=|<>?{}[]~".contains($0) }) {
            error = "Usernames may only contain letters, digits, hyphens and underscores."
            onChange?(); return
        }
        await perform {
            try await self.requireCurrentEpoch()
            let client = try await self.accounts.gpodderAuthenticationClient(host: self.host, username: username, password: password)
            try await client.login()
            let devices = try await client.devices()
            try await self.requireCurrentEpoch()
            self.client = client; self.username = username; self.password = password; self.devices = devices
            let base = "NotTennaPod on " + self.deviceModel
            var name = base, number = 1
            while self.containsDevice(name: name) { name = base + " (\(number))"; number += 1 }
            self.suggestedDeviceName = name; self.stage = .devices
        }
    }

    public func choose(device: SynchronizationDevice) async {
        guard stage == .devices, devices.contains(device) else { return }
        await perform { try await self.commit(device) }
    }

    public func createDevice(name: String) async {
        guard stage == .devices, !containsDevice(name: name), let client else { return }
        await perform {
            try await self.requireCurrentEpoch()
            let id = Self.deviceID(for: name)
            try await client.configureDevice(id: id, caption: name, type: "mobile")
            try await self.commit(.init(id: id, caption: name, type: "mobile", subscriptions: 0))
        }
    }

    public func cancel() {
        cancelled = true; operation?.cancel(); operation = nil; operationID = nil
        password = ""; client = nil; busy = false; onChange?()
    }

    public static func deviceID(for name: String) -> String {
        // Java replaceAll matches Unicode code points; ASCII alphanumerics alone
        // survive, including one underscore for each non-ASCII code point.
        String(name.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            if (65...90).contains(value) { return Character(UnicodeScalar(value + 32)!) }
            if (97...122).contains(value) || (48...57).contains(value) { return Character(scalar) }
            return "_"
        })
    }

    private func containsDevice(name: String) -> Bool {
        let id = Self.deviceID(for: name)
        return devices.contains { $0.id.utf16.elementsEqual(id.utf16) || $0.caption.utf16.elementsEqual(name.utf16) }
    }

    private func requireCurrentEpoch() async throws {
        try Task.checkCancellation()
        guard let epoch, try await accounts.authenticationEpoch() == epoch else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func commit(_ device: SynchronizationDevice) async throws {
        try await requireCurrentEpoch()
        guard let epoch else { throw CancellationError() }
        let account = SynchronizationAccount(backend: .gpodder, host: host, username: username, device: device.id)
        let installedEpoch = try await accounts.connect(account, password: password, fullSync: false, expectedEpoch: epoch)
        try Task.checkCancellation()
        connectedEpoch = installedEpoch; selectedDevice = device; stage = .finish; password = ""; client = nil
    }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) async {
        guard !busy, !cancelled else { return }
        busy = true; error = nil; onChange?()
        guard !cancelled else { return }
        let id = UUID()
        operationID = id
        let task = Task { @MainActor in
            do { try await body() }
            catch { if !self.cancelled { self.error = self.message(for: error) } }
            if !self.cancelled { self.busy = false; self.onChange?() }
        }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if operationID == id { operation = nil; operationID = nil }
    }

    private func message(for error: any Error) -> String {
        // Never display arbitrary transport/server descriptions: they can embed
        // credential-bearing requests or echo submitted secrets.
        if error is CancellationError { return "Synchronization failed" }
        if let error = error as? SynchronizationError {
            switch error {
            case .invalidHost: return URLError(.badURL).localizedDescription
            case .authentication: return "Wrong username or password"
            case .httpStatus(let status):
                let address = host.contains("://") ? host : "https://" + host
                let baseHost = URLComponents(string: address)?.host ?? "invalid-hostname"
                if status >= 500 { return "\(baseHost) is currently unavailable (code \(status))" }
                // URLSession exposes the status code, not HTTP/1's optional wire
                // reason phrase. Preserve the application's template and supply
                // the native transport's localized status description.
                return "Unable to connect to \(baseHost) (code \(status): \(HTTPURLResponse.localizedString(forStatusCode: status)))"
            case .invalidResponse: return URLError(.cannotParseResponse).localizedDescription
            default: break
            }
        }
        if let error = error as? URLError { return URLError(error.code).localizedDescription }
        return URLError(.unknown).localizedDescription
    }
}

import Foundation

@MainActor
public final class NextcloudAuthenticationFlow {
    public private(set) var busy = false
    public private(set) var host = ""
    public private(set) var error: String?
    public private(set) var connectedEpoch: UUID?
    public private(set) var pendingSession: NextcloudAuthenticationSession?
    public var onChange: (@MainActor () -> Void)?

    private let accounts: SynchronizationAccounts
    private let openBrowser: @MainActor (URL) async -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var cancelled = false

    public init(accounts: SynchronizationAccounts,
                openBrowser: @escaping @MainActor (URL) async -> Bool,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.accounts = accounts; self.openBrowser = openBrowser; self.sleep = sleep
    }

    public func start(host: String) async {
        await perform(host: host) {
            let epoch = try await self.accounts.authenticationEpoch()
            let client = try await self.accounts.nextcloudAuthenticationClient(host: host)
            let challenge = try await client.start()
            try await self.requireCurrentEpoch(epoch)
            let session = NextcloudAuthenticationSession(rawHost: host, token: challenge.token,
                endpoint: challenge.endpoint, expectedEpoch: epoch)
            self.pendingSession = session; self.onChange?()
            try Task.checkCancellation()
            guard await self.openBrowser(challenge.login) else { throw NextcloudAuthenticationError.browserUnavailable }
            try await self.finish(client: client, session: session)
        }
    }

    /// Securely restored token/endpoint skips the start request and browser.
    public func resume(session: NextcloudAuthenticationSession) async {
        await perform(host: session.rawHost) {
            try await self.requireCurrentEpoch(session.expectedEpoch)
            let client = try await self.accounts.nextcloudAuthenticationClient(host: session.rawHost)
            self.pendingSession = session; self.onChange?()
            try await self.finish(client: client, session: session)
        }
    }

    public func cancel() {
        cancelled = true; operation?.cancel(); operation = nil; operationID = nil
        pendingSession = nil; busy = false; onChange?()
    }

    private func finish(client: NextcloudAuthenticationClient, session: NextcloudAuthenticationSession) async throws {
        try await requireCurrentEpoch(session.expectedEpoch)
        let credentials = try await client.authorize(session, sleep: sleep)
        try await requireCurrentEpoch(session.expectedEpoch)
        let account = SynchronizationAccount(backend: .nextcloud, host: credentials.server, username: credentials.username)
        let epoch = try await accounts.connect(account, password: credentials.password, fullSync: true,
            expectedEpoch: session.expectedEpoch)
        try Task.checkCancellation()
        connectedEpoch = epoch
    }

    private func requireCurrentEpoch(_ expected: UUID) async throws {
        try Task.checkCancellation()
        guard try await accounts.authenticationEpoch() == expected else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func perform(host: String, body: @escaping @MainActor () async throws -> Void) async {
        guard !busy, !cancelled, connectedEpoch == nil else { return }
        self.host = host; busy = true; error = nil; onChange?()
        guard !cancelled else { return }
        let id = UUID(); operationID = id
        let task = Task { @MainActor in
            do { try await body() }
            catch { if !self.cancelled { self.error = Self.message(for: error) } }
            if !self.cancelled {
                self.pendingSession = nil; self.busy = false; self.onChange?()
            }
        }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if operationID == id { operation = nil; operationID = nil }
    }

    private static func message(for error: any Error) -> String {
        // Provider and transport errors can echo tokens/passwords. Display only
        // recognized codes and local text; the view adds the source's advice.
        if error is CancellationError { return "Synchronization failed" }
        if let error = error as? NextcloudAuthenticationError {
            switch error {
            case .timedOut: return URLError(.timedOut).localizedDescription
            case .browserUnavailable: return URLError(.unsupportedURL).localizedDescription
            }
        }
        if let error = error as? SynchronizationError {
            switch error {
            case .invalidHost: return URLError(.badURL).localizedDescription
            case .invalidResponse: return URLError(.cannotParseResponse).localizedDescription
            case .httpStatus(let status): return "Return code \(status)"
            default: break
            }
        }
        if let error = error as? URLError { return URLError(error.code).localizedDescription }
        return URLError(.unknown).localizedDescription
    }
}

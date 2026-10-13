import Foundation

/// The sign-in dialog's draft state (PROTOCOL §15.4), modelled on the gpodder.net flow: the server
/// address, then the credentials. Nothing durable happens here; the confirmed attachment or resume does that.
@MainActor public final class ServerSignInFlow {
    public enum Stage: Equatable, Sendable { case host, credentials }
    public private(set) var stage: Stage
    public private(set) var busy = false
    public private(set) var error: (any Error)?
    public private(set) var address: ServerAddress?
    /// A kept library's username, offered again by "Log in".
    public let suggestedUsername: String?
    /// The kept library whose "Log in" this is: that one resumes if the account is its own.
    public let libraryID: String?
    public var onChange: (@MainActor () -> Void)?

    private let accounts: ServerAccounts
    private var info: ServerInfo?
    private var operation: Task<Void, Never>?
    private var cancelled = false

    /// Starts at the address, or at the credentials for a known address (a kept library's "Log in").
    public init(accounts: ServerAccounts, address: ServerAddress? = nil, username: String? = nil, library: String? = nil) {
        self.accounts = accounts; self.address = address; suggestedUsername = username; libraryID = library
        stage = address == nil ? .host : .credentials
    }

    /// Android's "Password and data are not encrypted!" for plain HTTP outside Tailscale.
    public var showsEncryptionWarning: Bool { address?.showsEncryptionWarning ?? false }

    /// Step 1: `GET /v1/info` at the entered address.
    public func proceed(host: String) async {
        guard stage == .host else { return }
        await perform {
            guard let address = ServerAddress(entered: host) else { throw ServerClientError.invalidAddress }
            let info = try await self.accounts.info(address)
            try Task.checkCancellation()
            self.address = address; self.info = info; self.stage = .credentials
        }
    }

    /// Steps 2–4: the sign-in; the result is confirmed by the person before anything is stored.
    public func login(username: String, password: String) async -> ServerPendingSignIn? {
        guard stage == .credentials, let address, !username.isEmpty else { return nil }
        var result: ServerPendingSignIn?
        await perform {
            let info: ServerInfo
            if let known = self.info { info = known } else { info = try await self.accounts.info(address) }
            self.info = info
            result = try await self.accounts.signIn(address, info: info, username: username, password: password, library: self.libraryID)
            try Task.checkCancellation()
        }
        return cancelled ? nil : result
    }

    public func cancel() {
        cancelled = true; operation?.cancel(); operation = nil; busy = false; onChange?()
    }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) async {
        guard !busy, !cancelled else { return }
        busy = true; error = nil; onChange?()
        let task = Task { @MainActor in
            do { try await body() } catch { if !self.cancelled && !(error is CancellationError) { self.error = error } }
            if !self.cancelled { self.busy = false; self.onChange?() }
        }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

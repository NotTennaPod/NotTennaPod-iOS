import Foundation

/// One dialog's draft/test lifetime. Committed settings belong to the app store.
@MainActor public final class ProxySettingsSession {
    public enum Status: Equatable, Sendable { case none, checking, succeeded, failed(String) }
    public private(set) var draft: ProxySettingsDraft
    public private(set) var status: Status = .none
    public private(set) var errors: [ProxySettingsDraft.Field: String]
    public private(set) var testSuccessful: Bool
    public var isTesting: Bool { work != nil }
    public var onChange: (() -> Void)?
    private let preferences: ProxyPreferenceStore
    private let test: @Sendable (PodcastProxy) async throws -> Void
    private var work: Task<Void, Never>?
    private var revision = UUID()

    public init(preferences: ProxyPreferenceStore, test: @escaping @Sendable (PodcastProxy) async throws -> Void) {
        self.preferences = preferences; self.test = test
        draft = ProxySettingsDraft(preferences.value)
        errors = draft.errors; testSuccessful = draft.kind == .direct
    }
    deinit { work?.cancel() }

    public func edit(_ value: ProxySettingsDraft) {
        let typeChanged = draft.kind != value.kind
        if draft.host != value.host { errors[.host] = nil }
        if draft.port != value.port { errors[.port] = nil }
        draft = value
        invalidate()
        testSuccessful = typeChanged && value.kind == .direct
        onChange?()
    }
    public func selectType(_ kind: PodcastProxy.Kind) {
        var value = draft; value.kind = kind; edit(value)
        testSuccessful = kind == .direct; onChange?()
    }
    public func cancel() { invalidate() }
    private func invalidate() { revision = UUID(); work?.cancel(); work = nil }

    @discardableResult public func verify() -> Task<Void, Never> {
        invalidate(); testSuccessful = false
        errors = draft.errors
        guard errors.isEmpty else { onChange?(); return Task {} }
        // A typed zero is a test destination, whereas an empty port uses8080.
        // Do not accidentally test8080 and authorize a different entered port.
        if !draft.port.isEmpty, Int32(draft.port) == 0 {
            status = .failed(URLError(.cannotConnectToHost).localizedDescription)
            onChange?(); return Task {}
        }
        status = .checking
        let token = revision, snapshot = draft, test = test
        // Source test uses the typed empty password; stored preferences normalize
        // empty strings separately. Keep this difference visible to recipients.
        var candidate = snapshot.configuration
        if !snapshot.username.isEmpty { candidate.password = snapshot.password }
        let configuration = candidate
        let task = Task { [weak self] in
            let outcome: Status
            do { try await test(configuration); try Task.checkCancellation(); outcome = .succeeded }
            catch is CancellationError { return }
            catch { outcome = .failed(error.localizedDescription) }
            guard let self, revision == token, draft == snapshot else { return }
            status = outcome; testSuccessful = outcome == .succeeded; work = nil; onChange?()
        }
        work = task; onChange?(); return task
    }

    @discardableResult public func save() throws -> Bool {
        guard testSuccessful else { return false }
        // A disabled DIRECT port can contain overflow text retained from a prior
        // type. Its safe normalization prevents the confirmed original exception.
        try preferences.update(draft.configuration, reinitializeShared: true)
        invalidate(); return true
    }

    public func reset() throws {
        invalidate(); draft.clearFields(); errors = [:]
        // Runtime-confirmed source defect: clearing retained DIRECT fields
        // requests a test that then throws constructing Proxy(DIRECT,address).
        // DIRECT requires no proxy test; retain immediate Reset persistence.
        testSuccessful = draft.kind == .direct
        try preferences.update(draft.configuration, reinitializeShared: false)
        onChange?()
    }
}

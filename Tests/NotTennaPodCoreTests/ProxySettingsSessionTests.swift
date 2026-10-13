import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct ProxySettingsSessionTests {
    @Test func directSaveAndResetHaveDistinctDurableEffectsAndCancelDoesNotSaveDraft() async throws {
        let persistence = Memory(), preferences = try ProxyPreferenceStore(persistence: persistence)
        var effects: [Bool] = []; preferences.onChange = { _, reinitialize in effects.append(reinitialize) }
        let session = ProxySettingsSession(preferences: preferences, test: { _ in })
        #expect(session.testSuccessful)
        var draft = session.draft; draft.kind = .http; draft.host = "localhost"; draft.port = "8080"
        draft.username = "fixture-user"; draft.password = "fixture-secret"
        session.edit(draft); session.cancel()
        #expect(preferences.value == PodcastProxy() && effects.isEmpty)
        session.edit(draft)
        #expect(try session.save() == false)
        await session.verify().value
        #expect(session.testSuccessful && preferences.value == PodcastProxy())
        #expect(try session.save())
        #expect(preferences.value == draft.configuration && effects == [true])
        let reopened = try ProxyPreferenceStore(persistence: persistence)
        let reset = ProxySettingsSession(preferences: reopened, test: { _ in })
        reopened.onChange = { _, reinitialize in effects.append(reinitialize) }
        #expect(!reset.testSuccessful)
        try reset.reset(); reset.cancel()
        #expect(try ProxyPreferenceStore(persistence: persistence).value == PodcastProxy(kind: .http))
        #expect(effects == [true, false])
    }
    @Test func storageFailureDoesNotPublishUncommittedConfiguration() throws {
        let persistence = Memory(), preferences = try ProxyPreferenceStore(persistence: persistence)
        var count = 0; preferences.onChange = { _, _ in count += 1 }
        persistence.fail.withLock { $0 = true }
        #expect(throws: URLError.self) { try preferences.update(.init(kind: .http, host: "localhost"), reinitializeShared: true) }
        #expect(preferences.value == PodcastProxy() && count == 0)
    }
    @Test func editingDuringTestCannotAuthorizeUntestedFieldsEvenIfCancelledTestReturnsSuccess() async throws {
        let preferences = try ProxyPreferenceStore(persistence: Memory()), gate = Gate()
        let session = ProxySettingsSession(preferences: preferences, test: { try await gate.wait($0) })
        var draft = session.draft; draft.kind = .http; draft.host = "localhost"
        session.edit(draft)
        let task = session.verify()
        while await gate.pending == false { await Task.yield() }
        draft.host = "example.com"; session.edit(draft)
        await gate.release(); await task.value
        #expect(session.testSuccessful == false)
        #expect(try session.save() == false)
        #expect(preferences.value == PodcastProxy())
    }
    @Test func invalidHostAndOverflowNeverStartNetworkAndDirectSaveCannotCrash() async throws {
        let calls = Mutex(0), preferences = try ProxyPreferenceStore(persistence: Memory())
        let session = ProxySettingsSession(preferences: preferences, test: { _ in calls.withLock { $0 += 1 } })
        var draft = session.draft; draft.kind = .http; draft.port = "9999999999999999999"
        session.edit(draft); await session.verify().value
        #expect(calls.withLock { $0 } == 0 && session.errors.count == 2)
        draft.kind = .direct; session.edit(draft)
        #expect(try session.save())
        #expect(preferences.value.port == 0)
    }
    @Test func directResetRemainsSavableAndExplicitZeroCannotTestDefaultPort() async throws {
        let persistence = Memory(), preferences = try ProxyPreferenceStore(persistence: persistence)
        let calls = Mutex(0)
        try preferences.update(.init(kind: .direct, host: "localhost", port: 8080), reinitializeShared: true)
        let session = ProxySettingsSession(preferences: preferences, test: { _ in calls.withLock { $0 += 1 } })
        try session.reset()
        #expect(session.testSuccessful && preferences.value == PodcastProxy())
        #expect(try session.save())
        var draft = session.draft; draft.kind = .http; draft.host = "localhost"; draft.port = "0"
        session.edit(draft); await session.verify().value
        #expect(session.errors.isEmpty && !session.testSuccessful && !session.isTesting)
        #expect(calls.withLock { $0 } == 0)
        if case .failed = session.status {} else { Issue.record("Zero must fail, not authorize port8080") }
        draft.port = ""; session.edit(draft); await session.verify().value
        #expect(session.testSuccessful && calls.withLock { $0 } == 1)
    }
    private final class Memory: ProxyPreferencePersistence {
        let data = Mutex<PodcastProxy?>(nil), fail = Mutex(false)
        func load() -> PodcastProxy? { data.withLock { $0 } }
        func save(_ configuration: PodcastProxy) throws {
            if fail.withLock({ $0 }) { throw URLError(.cannotWriteToFile) }
            data.withLock { $0 = configuration }
        }
    }
    private actor Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var pending: Bool { continuation != nil }
        func wait(_ configuration: PodcastProxy) async throws { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
}

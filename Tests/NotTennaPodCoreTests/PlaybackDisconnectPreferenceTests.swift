import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct PlaybackDisconnectPreferenceTests {
    private final class Preference { var enabled = true }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }

    @Test func settingChangesApplyAtDisconnectWithoutReconstructingPlayback() async throws {
        let preference = Preference()
        let session = PlaybackRecoveryControllerTests.Session()
        let activation = AudioSessionActivationController(driver: PCMPlaybackEngineTests.Driver())
        let controller = PlaybackRecoveryController(session: session, activation: activation,
            pauseOnDisconnectProvider: { preference.enabled }, now: { 1000 })
        defer { controller.close() }
        try controller.play()
        try await wait { session.playing }
        preference.enabled = false
        controller.receive(.routeChanged(reason: 2))
        #expect(session.playing && controller.wantsPlayback && !controller.isSuppressed)
        #expect(session.plays == 1 && session.seeks.isEmpty)
        preference.enabled = true
        controller.receive(.routeChanged(reason: 2))
        #expect(!session.playing && !controller.wantsPlayback)
        controller.receive(.routeChanged(reason: 1))
        controller.receive(.resumptionRecommended(true))
        #expect(!session.playing && !controller.wantsPlayback && session.plays == 1)
    }

    @Test(arguments: [false, true])
    func livePolicyPreservesTransientSuppressionAndManualIntent(manualPause: Bool) async throws {
        let preference = Preference()
        let session = PlaybackRecoveryControllerTests.Session()
        session.positionMilliseconds = 0; session.lastPlayedMilliseconds = 0
        let activation = AudioSessionActivationController(driver: PCMPlaybackEngineTests.Driver())
        let controller = PlaybackRecoveryController(session: session, activation: activation,
            pauseOnDisconnectProvider: { preference.enabled }, now: { 1000 })
        defer { controller.close() }
        try controller.play(); try await wait { session.playing }
        controller.receive(.interrupted(reason: 0))
        if manualPause { try controller.pause() }
        preference.enabled = false
        controller.receive(.interrupted(reason: 4))
        #expect(controller.isSuppressed && !session.playing)
        #expect(controller.wantsPlayback == !manualPause)
        controller.receive(.resumptionRecommended(true))
        try await wait { !controller.isSuppressed && (manualPause || session.playing) }
        #expect(controller.wantsPlayback == !manualPause && session.playing == !manualPause)
        #expect(session.seeks.isEmpty)
    }
}

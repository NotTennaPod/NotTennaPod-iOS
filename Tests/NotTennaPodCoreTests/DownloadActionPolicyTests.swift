import Foundation
import Testing
@testable import NotTennaPodCore

@Suite
struct DownloadActionPolicyTests {
    private let now: Int64 = 1_700_000_000_999

    private func decision(_ policy: DownloadActionPolicy, at time: Int64, allowed: Bool = false,
                          restricted: Bool = true, vpn: Bool = false) -> DownloadActionPolicy.Decision {
        policy.decision(hasMedia: true, downloaded: false, downloading: false, allowMobile: allowed,
                        restrictedNetwork: restricted, vpnOverWiFi: vpn, nowMilliseconds: time)
    }

    @Test func initialTapPromptsOnlyForRestrictedDisallowedNetwork() {
        let policy = DownloadActionPolicy()
        #expect(decision(policy, at: now) == .confirmation(showVPNAdvice: false))
        #expect(decision(policy, at: now, vpn: true) == .confirmation(showVPNAdvice: true))
        #expect(decision(policy, at: now, allowed: true, vpn: true) == .request(ignoreConstraints: false, showMobileNotice: false))
        #expect(decision(policy, at: now, restricted: false, vpn: true) == .request(ignoreConstraints: false, showMobileNotice: false))
    }

    @Test func missingCompletedAndAlreadyDownloadingMediaNeverPromptOrRequest() {
        for hasMedia in [false, true] {
            for downloaded in [false, true] {
                for downloading in [false, true] {
                    guard !hasMedia || downloaded || downloading else { continue }
                    for choice in [DownloadActionPolicy.Choice.none, .now, .later] {
                        var policy = DownloadActionPolicy()
                        _ = policy.confirm(choice, nowMilliseconds: now)
                        #expect(policy.decision(hasMedia: hasMedia, downloaded: downloaded, downloading: downloading,
                                                allowMobile: true, restrictedNetwork: true, vpnOverWiFi: true,
                                                nowMilliseconds: now) == .ignored)
                    }
                }
            }
        }
    }

    @Test func anywayBypassUsesWholeSecondsAndStrictFiveMinuteExpiry() {
        var policy = DownloadActionPolicy()
        #expect(policy.confirm(.now, nowMilliseconds: now) == .request(ignoreConstraints: true, showMobileNotice: false))
        #expect(policy.bypassTimeSeconds == 1_700_000_000)
        #expect(decision(policy, at: now) == .request(ignoreConstraints: true, showMobileNotice: true))
        #expect(decision(policy, at: 1_700_000_299_999) == .request(ignoreConstraints: true, showMobileNotice: true))
        #expect(decision(policy, at: 1_700_000_300_000) == .confirmation(showVPNAdvice: false))
        #expect(decision(policy, at: 1_700_000_600_000) == .confirmation(showVPNAdvice: false))
    }

    @Test func laterBypassQueuesConstrainedWorkWithoutNoticeAndDoesNotExtendOnTap() {
        var policy = DownloadActionPolicy()
        #expect(policy.confirm(.later, nowMilliseconds: now) == .request(ignoreConstraints: false, showMobileNotice: false))
        #expect(decision(policy, at: now + 200_000) == .request(ignoreConstraints: false, showMobileNotice: false))
        #expect(policy.bypassTimeSeconds == 1_700_000_000)
        #expect(decision(policy, at: 1_700_000_300_000) == .confirmation(showVPNAdvice: false))
    }

    /// "Allow this time" covers only what is asked within its five minutes. Android keeps the choice after it expires,
    /// so a later download asked for on Wi-Fi may continue over mobile data; that costs data and is not copied.
    @Test func allowThisTimeDoesNotApplyToALaterRequestOnWiFi() {
        var policy = DownloadActionPolicy()
        _ = policy.confirm(.now, nowMilliseconds: now)
        #expect(decision(policy, at: now + 600_000, restricted: false) == .request(ignoreConstraints: false, showMobileNotice: false))
        #expect(decision(policy, at: now + 600_000, allowed: true) == .request(ignoreConstraints: false, showMobileNotice: false))
        #expect(decision(policy, at: now + 600_000) == .confirmation(showVPNAdvice: false))
        #expect(decision(policy, at: now + 299_000, restricted: false) == .request(ignoreConstraints: true, showMobileNotice: true),
                "within the window it still applies")
    }

    @Test func cancellationKeepsPreviousChoiceAndNewConfirmationReplacesIt() {
        var policy = DownloadActionPolicy()
        _ = policy.confirm(.now, nowMilliseconds: now)
        let before = policy
        #expect(policy.confirm(.none, nowMilliseconds: now + 600_000) == .ignored)
        #expect(policy == before)
        _ = policy.confirm(.later, nowMilliseconds: now + 600_000)
        #expect(decision(policy, at: now + 650_000) == .request(ignoreConstraints: false, showMobileNotice: false))
        #expect(policy.bypassTimeSeconds == 1_700_000_600)
    }

    @Test func clockRollbackAndProcessRestartFollowStaticSourceState() {
        var policy = DownloadActionPolicy()
        _ = policy.confirm(.now, nowMilliseconds: now)
        #expect(decision(policy, at: now - 86_400_000) == .request(ignoreConstraints: true, showMobileNotice: true))
        #expect(decision(DownloadActionPolicy(), at: now + 1_000) == .confirmation(showVPNAdvice: false))
        #expect(decision(DownloadActionPolicy(), at: 299_999) == .request(ignoreConstraints: false, showMobileNotice: false))
        #expect(decision(DownloadActionPolicy(), at: 300_000) == .confirmation(showVPNAdvice: false))
    }

    @Test func requestWarningAndWorkConstraintHaveDifferentCellularRules() {
        let cases: [(DownloadNetworkState, Bool, Bool, Bool)] = [
            (.init(connected: false, metered: false, cellular: false), false, false, false),
            (.init(connected: false, metered: true, cellular: false), true, false, false),
            (.init(connected: true, metered: false, cellular: false), false, true, true),
            (.init(connected: true, metered: true, cellular: false), true, true, false),
            (.init(connected: true, metered: true, cellular: true), true, true, false),
            (.init(connected: true, metered: false, cellular: true), true, true, true)
        ]
        for (network, restricted, connectedAllowed, unmeteredAllowed) in cases {
            #expect(network.restricted == restricted)
            #expect(DownloadNetworkConstraint.connected.permits(network) == connectedAllowed)
            #expect(DownloadNetworkConstraint.unmetered.permits(network) == unmeteredAllowed)
        }
    }

    @Test func monitorReleasesEligibleWaitersAndCancellationDoesNotRequireNetworkChange() async throws {
        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        #expect(monitor.current == nil)
        let connected = Task { try await monitor.waitUntilPermitted(.connected) }
        let unmetered = Task { try await monitor.waitUntilPermitted(.unmetered) }
        defer { connected.cancel(); unmetered.cancel() }
        monitor.update(.init(connected: true, metered: true, cellular: true))
        try await connected.value
        #expect(monitor.current?.restricted == true)
        unmetered.cancel()
        await #expect(throws: CancellationError.self) { try await unmetered.value }
        monitor.update(.init(connected: true, metered: false, cellular: false))
        try await monitor.waitUntilPermitted(.unmetered)
    }

    @Test func monitorCancellationAndPathUpdateRaceDoesNotStrandWaiters() async throws {
        for _ in 0..<100 {
            let monitor = DownloadNetworkMonitor(startMonitoring: false)
            let task = Task { try await monitor.waitUntilPermitted(.unmetered) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { task.cancel() }
                group.addTask { monitor.update(.init(connected: true, metered: false, cellular: false)) }
            }
            do { try await task.value }
            catch is CancellationError { }
        }
    }
}

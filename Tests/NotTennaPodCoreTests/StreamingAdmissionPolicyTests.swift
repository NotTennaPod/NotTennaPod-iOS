import Foundation
import Testing
@testable import NotTennaPodCore

struct StreamingAdmissionPolicyTests {
    typealias Policy = StreamingAdmissionPolicy
    struct Inputs: Sendable {
        let needsStreaming: Bool
        let allowed: Bool
        let casting: Bool
    }
    static let allInputs = [false, true].flatMap { needsStreaming in
        [false, true].flatMap { allowed in
            [false, true].map { Inputs(needsStreaming: needsStreaming, allowed: allowed, casting: $0) }
        }
    }
    private let remote = Policy.Media(id: 2, needsStreaming: true)

    @Test func unchangedJavaAdmissionGuardsMatchAllEightyInputs() throws {
        struct Case: Decodable {
            let kind: String
            let remote, allowed, casting, blocked: Bool
            let once, remainingOnce, present: Bool?
            let state: Int?
        }
        let url = try #require(Bundle.module.url(forResource: "streaming-admission-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        #expect(cases.count == 80)
        for row in cases {
            var policy = Policy()
            if row.kind == "load" {
                if row.once == true {
                    _ = policy.loadedMedia(remote, streamingAllowed: false, isCasting: false)
                    _ = policy.play(isConfirmationItem: true, currentMedia: nil, state: .ready,
                                    streamingAllowed: false, isCasting: false)
                    policy.willLoadEpisode()
                }
                let result = policy.loadedMedia(.init(id: 2, needsStreaming: row.remote),
                                                 streamingAllowed: row.allowed, isCasting: row.casting)
                #expect(result == (row.blocked ? .confirm(mediaID: 2) : .proceed))
                #expect(policy.allowStreamingThisTime == row.remainingOnce)
            } else {
                let states: [Policy.PlayerState] = [.idle, .buffering, .ready, .ended]
                let state = try #require(row.state)
                let result = policy.play(isConfirmationItem: false,
                    currentMedia: row.present == true ? .init(id: 2, needsStreaming: row.remote) : nil,
                    state: states[state - 1], streamingAllowed: row.allowed, isCasting: row.casting)
                #expect(result == (row.blocked ? .confirm(mediaID: 2) : .proceed))
            }
        }
    }

    @Test func reselectingFromMiniPlayerWarnsAgainAfterCancel() {
        // Captures 12–14 and ExternalPlayerFragment -> PlaybackServiceStarter:
        // mini Play reselects the episode because the current item is confirmation.
        var policy = Policy()
        _ = policy.loadedMedia(remote, streamingAllowed: false, isCasting: false)
        policy.willLoadEpisode()
        #expect(policy.loadedMedia(remote, streamingAllowed: false, isCasting: false) == .confirm(mediaID: 2))
        #expect(!policy.allowStreamingThisTime)
    }

    @Test func servicePlayConsumesPendingWithoutPersistentPermission() {
        // Source handleStreamingConfirmation: service Play (e.g. the Once callback)
        // accepts the pending item. Mini-player Play uses a separate reselect path.
        // Admission does not enqueue/select; those effects belong to the shared owner.
        var policy = Policy()
        policy.willLoadEpisode()
        #expect(policy.loadedMedia(remote, streamingAllowed: false, isCasting: false) == .confirm(mediaID: 2))
        #expect(policy.pendingMediaID == 2 && !policy.allowStreamingThisTime)
        // Dismissing a dialog does not call any policy method or revoke the pending item.
        #expect(policy.play(isConfirmationItem: true, currentMedia: nil, state: .ready,
                            streamingAllowed: false, isCasting: false) == .reload(mediaID: 2))
        #expect(policy.pendingMediaID == nil && policy.allowStreamingThisTime)
        policy.willLoadEpisode()
        #expect(policy.loadedMedia(remote, streamingAllowed: false, isCasting: false) == .proceed)
        #expect(!policy.allowStreamingThisTime)
        // Capture 12: ready paused stream on cellular requires confirmation on resume.
        #expect(policy.play(isConfirmationItem: false, currentMedia: remote, state: .ready,
                            streamingAllowed: false, isCasting: false) == .confirm(mediaID: 2))
    }

    // New-load and existing-item admission for every input are the 8 "load" and
    // 64 "play" rows of the Android oracle above.

    @Test(arguments: Self.allInputs)
    func oneTimePermissionIsConsumedByAnyAdmittedLoad(_ input: Inputs) {
        let (needsStreaming, allowed, casting) = (input.needsStreaming, input.allowed, input.casting)
        var policy = Policy()
        _ = policy.loadedMedia(remote, streamingAllowed: false, isCasting: false)
        #expect(policy.play(isConfirmationItem: true, currentMedia: nil, state: .idle,
                            streamingAllowed: allowed, isCasting: casting) == .reload(mediaID: 2))
        policy.willLoadEpisode()
        #expect(policy.loadedMedia(.init(id: 9, needsStreaming: needsStreaming), streamingAllowed: allowed,
                                   isCasting: casting) == .proceed)
        #expect(!policy.allowStreamingThisTime)
        #expect(policy.loadedMedia(remote, streamingAllowed: false, isCasting: false) == .confirm(mediaID: 2))
    }

    @Test func replacingPendingMediaCannotAuthorizeAnObsoleteConfirmation() {
        var policy = Policy()
        _ = policy.loadedMedia(remote, streamingAllowed: false, isCasting: false)
        policy.willLoadEpisode()
        #expect(policy.pendingMediaID == nil)
        #expect(policy.play(isConfirmationItem: true, currentMedia: nil, state: .ready,
                            streamingAllowed: false, isCasting: false) == .proceed)
        #expect(!policy.allowStreamingThisTime)
        #expect(policy.loadedMedia(.init(id: 3, needsStreaming: true), streamingAllowed: false,
                                   isCasting: false) == .confirm(mediaID: 3))
        #expect(policy.play(isConfirmationItem: true, currentMedia: nil, state: .ready,
                            streamingAllowed: false, isCasting: false) == .reload(mediaID: 3))
    }

    @Test func stalePendingIDDoesNotBypassAnOrdinaryItemAndPersistentPermissionAllowsResume() {
        var policy = Policy()
        _ = policy.loadedMedia(remote, streamingAllowed: false, isCasting: false)
        #expect(policy.play(isConfirmationItem: false, currentMedia: nil, state: .idle,
                            streamingAllowed: false, isCasting: false) == .proceed)
        #expect(!policy.allowStreamingThisTime && policy.pendingMediaID == 2)
        policy.willLoadEpisode()
        #expect(policy.loadedMedia(remote, streamingAllowed: true, isCasting: false) == .proceed)
        #expect(policy.play(isConfirmationItem: false, currentMedia: remote, state: .ready,
                            streamingAllowed: true, isCasting: false) == .proceed)
    }
}

// Adapts Media3 1.10.0 focus, suppression and button rules.
// Copyright (C) 2016, 2018 The Android Open Source Project; Apache License 2.0.
// Active service rewind behavior derives from AntennaPod 3.12.1 (GPL-3.0).
// See NOTICE.md and the corresponding licenses.

/// Active AntennaPod/Media3 speech-audio rules for a prepared local player. This separates
/// requested playback from transient suppression; OS notification mapping is a separate layer.
public struct PlaybackFocusPolicy: Sendable {
    public enum Event: Sendable {
        case requestPlay(granted: Bool), requestPause
        case gained, lost, lostTemporarily, lostTemporarilyCanDuck
        case audioBecomingNoisy, routeConnected
    }
    public enum PlaybackState: Sendable { case idle, buffering, ready, ended }
    public struct Transition: Equatable, Sendable {
        public let playWhenReady: Bool
        public let suppressed: Bool
        /// Active service applies its rewind helper whenever transient suppression clears,
        /// even when a manual pause or permanent loss means audio will remain paused.
        public let rewindAfterTransientLoss: Bool
        public var shouldRender: Bool { playWhenReady && !suppressed }

        /// The active listener casts the native position to Java int before applying the
        /// rewind helper, then compares its result with the original long position.
        public func rewindPosition(positionMilliseconds: Int64, lastPlayedMilliseconds: Int64,
                                   nowMilliseconds: Int64) -> Int64? {
            guard rewindAfterTransientLoss else { return nil }
            let target = Int64(PlaybackTiming.positionAfterPause(
                positionMilliseconds: Int32(truncatingIfNeeded: positionMilliseconds),
                lastPlayedMilliseconds: lastPlayedMilliseconds, nowMilliseconds: nowMilliseconds))
            return target == positionMilliseconds ? nil : target
        }
    }
    private enum Focus: Sendable { case notRequested, absent, held, transient }
    private var focus: Focus
    public private(set) var playWhenReady: Bool
    public private(set) var suppressed = false
    /// The application may refresh this setting without replacing focus state.
    public private(set) var pauseOnDisconnect: Bool

    public mutating func setPauseOnDisconnect(_ enabled: Bool) { pauseOnDisconnect = enabled }

    public init(playWhenReady: Bool = false, pauseOnDisconnect: Bool = true) {
        self.playWhenReady = playWhenReady
        self.pauseOnDisconnect = pauseOnDisconnect
        focus = playWhenReady ? .held : .notRequested
    }

    public func shouldShowPlayButton(state: PlaybackState) -> Bool {
        !playWhenReady || suppressed || state == .idle || state == .ended
    }

    @discardableResult public mutating func apply(_ event: Event) -> Transition {
        let wasSuppressed = suppressed
        switch event {
        case .requestPlay(let granted):
            let allowed = focus == .held || granted
            focus = allowed ? .held : .absent
            playWhenReady = allowed
            suppressed = false
        case .requestPause:
            playWhenReady = false
            suppressed = focus == .transient
        case .gained:
            focus = .held
            suppressed = false
        case .lost:
            focus = .absent
            playWhenReady = false
            suppressed = false
        case .lostTemporarily, .lostTemporarilyCanDuck:
            // The active player declares SPEECH: Media3 pauses, never attenuates it to 20%.
            focus = .transient
            suppressed = true
        case .audioBecomingNoisy:
            if pauseOnDisconnect {
                playWhenReady = false
                suppressed = focus == .transient
            }
        case .routeConnected:
            // Reconnect preference consumers belong to the disabled legacy service. No
            // corresponding active Media3 handler was found; runtime confirmation is open.
            break
        }
        return Transition(playWhenReady: playWhenReady, suppressed: suppressed,
                          rewindAfterTransientLoss: wasSuppressed && !suppressed)
    }
}

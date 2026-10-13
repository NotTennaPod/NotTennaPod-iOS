import Foundation
import CoreMedia
import CoreVideo
import AVFoundation

public struct PlaybackVideoGeometry: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixelAspectRatio: Double
    public let rotationDegrees: Double
    public init(width: Int, height: Int, pixelAspectRatio: Double = 1, rotationDegrees: Double = 0) {
        self.width = width; self.height = height
        self.pixelAspectRatio = pixelAspectRatio; self.rotationDegrees = rotationDegrees
    }
}

public struct PlaybackMediaTrack: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case audio, video }
    public let id: Int32
    public let kind: Kind
    public let title: String?
    public let language: String?
    public let codec: String
    public let videoGeometry: PlaybackVideoGeometry?
    public init(id: Int32, kind: Kind, title: String? = nil, language: String? = nil,
                codec: String, videoGeometry: PlaybackVideoGeometry? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.language = language
        self.codec = codec; self.videoGeometry = videoGeometry
    }
}

public enum PlaybackTrackSelectionError: Error { case unsupported, invalidTrack }

@MainActor public protocol PlaybackVideoPresenting: PlaybackEngine {
    var videoDisplayLayer: AVSampleBufferDisplayLayer? { get }
    var videoPictureInPicture: PlaybackVideoPictureInPicture? { get }
    /// Changes for each committed local source session; nil during replacement or remote playback.
    var mediaPresentationID: UUID? { get }
    var mediaTracks: [PlaybackMediaTrack] { get }
    var selectedAudioTrackID: Int32? { get }
    var selectedVideoTrackID: Int32? { get }
    func selectAudioTrack(id: Int32, commandID: UUID) throws
}
public extension PlaybackVideoPresenting {
    var mediaPresentationID: UUID? { nil }
    var mediaTracks: [PlaybackMediaTrack] { [] }
    var selectedAudioTrackID: Int32? { nil }
    var selectedVideoTrackID: Int32? { nil }
    func selectAudioTrack(id: Int32, commandID: UUID) throws { throw PlaybackTrackSelectionError.unsupported }
}

public struct PlaybackEngineReading: Equatable, Sendable {
    public var generation: UUID
    public var commandID: UUID
    public var sample: PlaybackSample
    public var buffering: Bool
    public var speed: Float
    public var skipSilence: Bool
    /// Pre-ready facts can update intent, but their duration/seekability are not prepared media measurements.
    public var isPrepared: Bool

    public init(generation: UUID, commandID: UUID? = nil, sample: PlaybackSample, buffering: Bool = false, speed: Float = 1,
                skipSilence: Bool = false, isPrepared: Bool = true) {
        self.generation = generation
        self.commandID = commandID ?? generation
        self.sample = sample
        self.buffering = buffering
        self.speed = speed
        self.skipSilence = skipSilence
        self.isPrepared = isPrepared
    }
}

public enum PlaybackEngineEvent: Sendable {
    case ready(PlaybackEngineReading)
    case stateChanged(PlaybackEngineReading)
    case position(PlaybackEngineReading)
    /// Final reading of a consumed source period before its clock restarts at zero.
    /// This is not a user seek or an episode completion.
    case timelineReset(PlaybackEngineReading)
    case ended(PlaybackEngineReading)
    case failed(generation: UUID, message: String)
    /// The system's media services were reset (or lost): every audio object of this generation is invalid and the
    /// engine has closed them. Final reading, paused. Not a playback failure: the item stays selected and paused,
    /// and only a later explicit Play builds new objects (Apple QA1749: no reactivation without the person).
    case mediaServicesReset(PlaybackEngineReading)
}

@MainActor
public protocol PlaybackEngine: AnyObject {
    /// May expose pre-ready intent; a ready event establishes prepared media. Play/Pause
    /// must be accepted during preparation, and readiness must preserve the latest intent.
    var reading: PlaybackEngineReading? { get }
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)? { get set }
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64)
    func play(commandID: UUID)
    func pause(commandID: UUID)
    func seek(to positionMilliseconds: Int64, commandID: UUID)
    func setSpeed(_ speed: Float, commandID: UUID) throws
    func unload()
}

public enum PlaybackSpeedError: Error, Equatable, Sendable { case invalidSpeed }

/// State already playing outside this engine. Adoption attaches observation and
/// accounting; it must not reload, seek, or change the external play/pause intent.
public struct PlaybackExternalState: Sendable {
    public var sample: PlaybackSample
    public var buffering: Bool
    public var speed: Float
    public init(sample: PlaybackSample, buffering: Bool = false, speed: Float = 1) {
        self.sample = sample; self.buffering = buffering; self.speed = speed
    }
}

@MainActor public protocol PlaybackExternalStateAdopting: PlaybackEngine {
    /// Another sender replaced the observed item. Explicit Play must reselect
    /// this application's episode even if its last known intent was playing.
    var requiresExplicitReload: Bool { get }
    func adopt(episode: LibraryEpisode, generation: UUID, state: PlaybackExternalState) throws
}
public extension PlaybackExternalStateAdopting { var requiresExplicitReload: Bool { false } }

/// Engines that hold playback during an audio-session interruption (a phone call) and resume it by themselves
/// when the interruption ends. Read-only: the library switch waits while such a resumption is pending (PROTOCOL §15.4).
/// The resumption is kept until the interruption's end or a command of the person (Pause, Play, Stop); the app
/// coming to the foreground does not end it. A change of this value is reported as a state change.
@MainActor public protocol PlaybackInterruptionReporting: PlaybackEngine {
    /// Playback is wanted but held by an interruption that will resume it.
    var resumesAfterInterruption: Bool { get }
}

/// Only engines with a real silence processor adopt this capability.
@MainActor public protocol PlaybackSilenceControlling: PlaybackEngine {
    var supportsSkipSilence: Bool { get }
    func setSkipSilence(_ enabled: Bool, commandID: UUID)
}

public extension PlaybackSilenceControlling {
    var supportsSkipSilence: Bool { true }
}

public enum PlaybackSilenceError: Error, Equatable, Sendable { case unsupportedEngine }

/// A remote route, or a local item that only AVPlayer can play, may retain the
/// processor's preference without applying it. This does not advertise silence
/// processing on that route.
@MainActor public protocol PlaybackSilencePreferenceRetaining: PlaybackEngine {
    var retainsSkipSilencePreference: Bool { get }
}

/// Engines that can keep the app's audio session while one item replaces another (a queue handoff or an
/// episode switch), as Media3 keeps audio focus across the items of one player. Only a session already
/// held is kept; nothing is newly activated.
@MainActor public protocol PlaybackSessionReserving: PlaybackEngine {
    /// The next `unload` keeps the audio session for the following `load`, whose item inherits it (left
    /// paused, it keeps it until it plays or stops).
    func reserveSessionForNextItem()
    /// No item took the reservation (the replacement was cancelled or failed): release the session
    /// unless an engine still wants it.
    func cancelSessionReservation()
}

@MainActor protocol PlaybackStatisticsConsumer: AnyObject {
    func bindStatistics(lastPlayed: @escaping @MainActor (UUID) -> Int64,
                        synchronize: @escaping @MainActor (UUID) async throws -> Void)
}

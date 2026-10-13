import Foundation
import CoreMedia

public struct PlaybackSystemIdentity: Equatable, Sendable {
    public let episodeID: Int64
    public let selectionID: UUID
}

public enum PlaybackSystemCommand: Equatable, Sendable {
    case play, pause, toggle, stop, next, restart
    case seek(milliseconds: Int64)
    case skip(seconds: Int32, direction: PlaybackIntervalDirection)
    case rate(Float)
}

public struct PlaybackSystemSnapshot: Equatable, Sendable {
    public let identity: PlaybackSystemIdentity
    public let title: String
    public let positionMilliseconds: Int64
    public let durationMilliseconds: Int64?
    public let rate: Float
    public let defaultRate: Float
    public let wantsPlayback: Bool
    public let canSeek: Bool
    public let canSkip: Bool
    public let canChangeRate: Bool
    public let canPlay: Bool
    public let isVideo: Bool
}

/// App-lifetime observation and cancellation, with no player/audio-session owner.
/// Command admission is checked again inside the coordinator's serial queue.
@MainActor public final class PlaybackSystemControls {
    private let playback: PlaybackCoordinator
    private var observation: Task<Void, Never>?
    private var lifetime = UUID()
    private var boundPictureInPicture: PlaybackVideoPictureInPicture?
    private var videoSeekTask: Task<Void, any Error>?
    private var boundVideoIdentity: PlaybackCoordinator.VideoCommandIdentity?

    public private(set) var isActive = false
    public var onChange: (@MainActor (PlaybackSystemSnapshot?) -> Void)?
    public var snapshot: PlaybackSystemSnapshot? { playback.systemSnapshot }

    public init(playback: PlaybackCoordinator) { self.playback = playback }

    public func start() {
        guard !isActive else { return }
        isActive = true
        let events = playback.events()
        observation = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled, let self else { return }
                self.refreshVideoCommands()
                self.onChange?(self.snapshot)
            }
        }
        refreshVideoCommands()
        onChange?(snapshot)
    }

    public func stop() {
        isActive = false; lifetime = UUID()
        observation?.cancel(); observation = nil
        clearVideoCommands()
        videoSeekTask?.cancel(); videoSeekTask = nil
        onChange?(nil)
    }

    @discardableResult public func perform(_ command: PlaybackSystemCommand,
        for identity: PlaybackSystemIdentity) async throws -> Bool {
        guard isActive else { return false }
        let expectedLifetime = lifetime
        return try await playback.performSystemCommand(command, for: identity, isCurrent: { [weak self] in
            self?.isActive == true && self?.lifetime == expectedLifetime
        })
    }

    private func clearVideoCommands() {
        boundPictureInPicture?.onSetPlaying = nil
        boundPictureInPicture?.onSeekSourceTime = nil
        boundPictureInPicture = nil
        boundVideoIdentity = nil
    }

    private func refreshVideoCommands() {
        let identity = playback.videoCommandIdentity
        let pictureInPicture = playback.videoPresentation?.videoPictureInPicture
        guard identity != boundVideoIdentity || pictureInPicture !== boundPictureInPicture else { return }
        clearVideoCommands()
        guard isActive, let identity, let pictureInPicture else { return }
        boundVideoIdentity = identity
        boundPictureInPicture = pictureInPicture
        let expectedLifetime = lifetime
        let isCurrent: @MainActor () -> Bool = { [weak self, weak pictureInPicture] in
            guard let self, let pictureInPicture else { return false }
            return self.isActive && self.lifetime == expectedLifetime
                && self.playback.videoCommandIdentity == identity
                && self.playback.videoPresentation?.videoPictureInPicture === pictureInPicture
        }
        pictureInPicture.onSetPlaying = { [weak self, weak pictureInPicture] playing in
            guard let self, isCurrent() else { return }
            Task { @MainActor [weak self, weak pictureInPicture] in
                guard let self else { return }
                do {
                    _ = try await self.playback.performSystemCommand(playing ? .play : .pause,
                        for: identity.selection, isCurrent: isCurrent)
                } catch { pictureInPicture?.onFailure?(error) }
            }
        }
        pictureInPicture.onSeekSourceTime = { [weak self] time in
            guard let self, isCurrent(), time.isNumeric, time >= .zero else { throw CancellationError() }
            let converted = CMTimeConvertScale(time, timescale: 1_000, method: .roundTowardZero)
            guard converted.isNumeric else { throw CancellationError() }
            let milliseconds = converted.value
            self.videoSeekTask?.cancel()
            let playback = self.playback
            let task = Task { @MainActor [weak self] in
                try await playback.seekFromPictureInPicture(to: milliseconds, identity: identity,
                    isCurrent: { [weak self] in self?.isActive == true && self?.lifetime == expectedLifetime })
            }
            self.videoSeekTask = task
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
    }

    isolated deinit {
        observation?.cancel()
        videoSeekTask?.cancel()
        boundPictureInPicture?.onSetPlaying = nil
        boundPictureInPicture?.onSeekSourceTime = nil
    }
}

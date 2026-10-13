import AVFoundation
import Foundation

/// Reads the ready item timeline without rendering audio or activating an audio session.
/// AVAsset metadata duration omits padding included by the original player for some files.
@MainActor final class PreparedMediaDuration {
    enum Failure: Error { case preparationFailed }
    private var player: AVPlayer?
    private var observations: [NSKeyValueObservation] = []
    private var completion: CheckedContinuation<Int64, any Error>?
    private var finished = false

    static func read(_ url: URL, contentType: String?) async throws -> Int64 {
        let probe = PreparedMediaDuration()
        let options = contentType.map { [AVURLAssetOverrideMIMETypeKey: $0] }
        let asset = AVURLAsset(url: url, options: options)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard try await asset.load(.isPlayable) else { throw Failure.preparationFailed }
            try Task.checkCancellation()
            return try await probe.prepare(asset)
        } onCancel: {
            Task { @MainActor in probe.finish(.failure(CancellationError())) }
        }
    }

    private func prepare(_ asset: AVURLAsset) async throws -> Int64 {
        guard !finished else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { completion in
            self.completion = completion
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            self.player = player
            observations = [
                item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.inspect() }
                },
                item.observe(\.duration, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.inspect() }
                },
                player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.inspect() }
                }
            ]
        }
    }

    private func inspect() {
        guard !finished, let player else { return }
        if player.status == .failed { finish(.failure(player.error ?? Failure.preparationFailed)); return }
        guard let item = player.currentItem else { return }
        if item.status == .failed { finish(.failure(item.error ?? Failure.preparationFailed)); return }
        guard item.status == .readyToPlay, item.duration.isNumeric else { return }
        let milliseconds = CMTimeConvertScale(item.duration, timescale: 1000, method: .roundTowardZero).value
        finish(.success(milliseconds))
    }

    private func finish(_ result: Result<Int64, any Error>) {
        guard !finished else { return }
        finished = true
        observations.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        let completion = completion
        self.completion = nil
        completion?.resume(with: result)
    }
}

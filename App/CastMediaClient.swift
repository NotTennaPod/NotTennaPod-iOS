import Foundation
import GoogleCast

@MainActor struct CastRemoteSnapshot {
    var mediaID: String?
    var loadID: String?
    var mediaSessionID: Int
    var positionMilliseconds: Int32
    var durationMilliseconds: Int32
    var state: GCKMediaPlayerState
    var idleReason: GCKMediaPlayerIdleReason = .none
    var speed: Float = 1
    var seekable = true
    var contentURL: String?
    /// The server library that loaded the media (`CastMediaItemCodec.libraryIDKey`); nil for the standalone library.
    var libraryID: String? = nil
}

@MainActor enum CastMediaCommand {
    case load(GCKMediaLoadRequestData), play, pause, seek(Int64), speed(Float), volume(Float), stop, status
}

@MainActor enum CastRequestOutcome {
    case completed, superseded
    case failed(String)
}

@MainActor protocol CastRequestCancellation: AnyObject { func cancel() }

/// SDK boundary; test clients drive actual command acknowledgements and incoming
/// status independently. Media fetching remains on the receiver, outside this API.
@MainActor protocol CastMediaClient: AnyObject {
    var snapshot: CastRemoteSnapshot? { get }
    var onStatus: (@MainActor () -> Void)? { get set }
    func send(_ command: CastMediaCommand, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation
}

@MainActor final class GoogleCastRequest: NSObject, CastRequestCancellation, @preconcurrency GCKRequestDelegate {
    private let request: GCKRequest
    private var completion: (@MainActor (CastRequestOutcome) -> Void)?
    init(_ request: GCKRequest, completion: @escaping @MainActor (CastRequestOutcome) -> Void) {
        self.request = request; self.completion = completion
        super.init()
        request.delegate = self
        if !request.inProgress {
            if let error = request.error { finish(.failed(error.localizedDescription)) }
            else { finish(.completed) }
        }
    }
    isolated deinit { cancel() }
    func cancel() {
        completion = nil; request.delegate = nil
        if request.inProgress { request.cancel() }
    }
    private func finish(_ outcome: CastRequestOutcome) {
        let callback = completion
        completion = nil; request.delegate = nil
        callback?(outcome)
    }
    func requestDidComplete(_ request: GCKRequest) { finish(.completed) }
    func request(_ request: GCKRequest, didFailWithError error: GCKError) { finish(.failed(error.localizedDescription)) }
    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) { finish(.superseded) }
}

@MainActor final class GoogleCastMediaClient: NSObject, CastMediaClient, @preconcurrency GCKRemoteMediaClientListener {
    private let client: GCKRemoteMediaClient
    var onStatus: (@MainActor () -> Void)?
    init(_ client: GCKRemoteMediaClient) {
        self.client = client
        super.init()
        client.add(self)
    }
    isolated deinit { client.remove(self) }
    var snapshot: CastRemoteSnapshot? {
        guard let status = client.mediaStatus else { return nil }
        let metadata = status.mediaInformation?.metadata
        return CastRemoteSnapshot(mediaID: metadata?.string(forKey: CastMediaItemCodec.mediaIDKey),
            loadID: metadata?.string(forKey: CastMediaItemCodec.loadIDKey), mediaSessionID: status.mediaSessionID,
            positionMilliseconds: Self.milliseconds(client.approximateStreamPosition()),
            durationMilliseconds: Self.milliseconds(status.mediaInformation?.streamDuration ?? 0),
            state: status.playerState, idleReason: status.idleReason, speed: status.playbackRate,
            seekable: status.isMediaCommandSupported(kGCKMediaCommandSeek),
            contentURL: status.mediaInformation?.contentURL?.absoluteString ?? status.mediaInformation?.contentID,
            libraryID: metadata?.string(forKey: CastMediaItemCodec.libraryIDKey))
    }
    private static func milliseconds(_ seconds: TimeInterval) -> Int32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int32(min(Double(Int32.max), seconds * 1000))
    }
    func send(_ command: CastMediaCommand, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation {
        let request: GCKRequest
        switch command {
        case .load(let data): request = client.loadMedia(with: data)
        case .play: request = client.play()
        case .pause: request = client.pause()
        case .seek(let milliseconds):
            let options = GCKMediaSeekOptions()
            options.interval = Double(milliseconds) / 1000
            options.relative = false; options.resumeState = .unchanged
            request = client.seek(with: options)
        case .speed(let speed): request = client.setPlaybackRate(speed)
        case .volume(let volume): request = client.setStreamVolume(volume)
        case .stop: request = client.stop()
        case .status: request = client.requestStatus()
        }
        return GoogleCastRequest(request, completion: completion)
    }
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) { onStatus?() }
}
